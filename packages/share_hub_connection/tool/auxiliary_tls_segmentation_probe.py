"""Compare unchanged Dart TLS ClientHello bytes with whole/split first writes.

Diagnostic only: an owned ephemeral loopback relay forwards to the HTTPS
origin. Dart still validates its certificate and hostname. No TLS termination,
keys, credentials, pairing, TURN allocation or production transport changes.
"""
import argparse
from datetime import datetime, timezone
import json
import ipaddress
from pathlib import Path
import re
import selectors
import shutil
import socket
import subprocess
import threading
import time
from urllib.parse import urlsplit


def https_origin(value):
    try:
        if any(ord(char) <= 32 or ord(char) == 127 for char in value):
            raise ValueError()
        url = urlsplit(value)
        port = url.port if url.port is not None else 443
        if (url.scheme != 'https' or not url.hostname or url.username is not None
                or url.password is not None or '?' in value or '#' in value
                or url.path not in ('', '/') or not 1 <= port <= 65535):
            raise ValueError()
        hostname = url.hostname.encode('idna').decode('ascii')
        try:
            address = ipaddress.ip_address(hostname)
            authority = f'[{hostname}]' if address.version == 6 else hostname
        except ValueError:
            if not re.fullmatch(r'[A-Za-z0-9.-]+', hostname):
                raise ValueError()
            authority = hostname
        if url.port is not None:
            authority += f':{port}'
    except ValueError:
        raise argparse.ArgumentTypeError('Expected an HTTPS origin without credentials or extra path') from None
    return 'https://' + authority + url.path


class ByteRelay:
    def __init__(self, host, port, split):
        self.host, self.target_port, self.split = host, port, split
        self.metadata = {}
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(5)
        self.port = self.listener.getsockname()[1]
        self.client = self.remote = None
        self.finished = threading.Event()
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self._forward, daemon=True)
        self.thread.start()

    @staticmethod
    def _close(sock):
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()

    def close(self):
        self.stopping.set()
        self._close(self.client)
        self._close(self.remote)
        self._close(self.listener)
        self.thread.join(10)
        if self.thread.is_alive():
            raise RuntimeError('relay did not terminate')

    def _read(self, count):
        data = b''
        while len(data) < count:
            chunk = self.client.recv(count - len(data))
            if not chunk:
                raise ValueError('incomplete ClientHello')
            data += chunk
        return data

    def _stream(self):
        # One owner handles both sockets, avoiding blocking read/write contention
        # on a shared socket and preserving half-close replies.
        with selectors.DefaultSelector() as ready:
            ready.register(self.client, selectors.EVENT_READ, self.remote)
            ready.register(self.remote, selectors.EVENT_READ, self.client)
            deadline = time.monotonic() + 8
            while ready.get_map() and not self.stopping.is_set():
                events = ready.select(timeout=0.1)
                if not events:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('relay I/O timed out')
                    continue
                deadline = time.monotonic() + 8
                for key, _ in events:
                    source, destination = key.fileobj, key.data
                    try:
                        chunk = source.recv(8192)
                    except OSError as error:
                        if source is self.remote and not self.stopping.is_set():
                            self.metadata['remoteReadErrorType'] = type(error).__name__
                            self.metadata['remoteReadErrno'] = error.errno
                        raise
                    if chunk:
                        destination.sendall(chunk)
                    else:
                        ready.unregister(source)
                        try:
                            destination.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass

    def _forward(self):
        try:
            self.client, _ = self.listener.accept()
            self.client.settimeout(8)
            self.remote = socket.create_connection((self.host, self.target_port), timeout=8)
            self.remote.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            try:
                self.metadata['remoteTcpMss'] = self.remote.getsockopt(socket.IPPROTO_TCP, socket.TCP_MAXSEG)
            except (AttributeError, OSError):
                self.metadata['remoteTcpMss'] = None  # Optional on Windows.
            header = self._read(5)
            length = int.from_bytes(header[3:5], 'big')
            if header[0] != 22 or not 4 <= length <= 8192:
                raise ValueError('unsupported first TLS record')
            hello = header + self._read(length)
            if hello[5] != 1 or int.from_bytes(hello[6:9], 'big') != length - 4:
                raise ValueError('unsupported ClientHello framing')
            self.metadata['clientHelloRecordBytes'] = len(hello)
            if self.split:
                self.remote.sendall(hello[:100])
                time.sleep(0.03)
                self.remote.sendall(hello[100:])
            else:
                self.remote.sendall(hello)
            self._stream()
        except (OSError, ValueError) as error:
            if not self.stopping.is_set():
                self.metadata['relayErrorType'] = type(error).__name__
        finally:
            self.stopping.set()
            self._close(self.remote)
            self._close(self.client)
            self._close(self.listener)
            self.finished.set()


def probe(origin, dart, split):
    url = urlsplit(origin)
    relay = ByteRelay(url.hostname, url.port or 443, split)
    try:
        run = subprocess.run([
            dart, str(Path(__file__).with_name('auxiliary_tls_segmentation_client.dart')),
            origin, str(relay.port),
        ], capture_output=True, text=True, timeout=25)
        report = json.loads(run.stdout)
        if (report.get('pairingVerified') is not False or report.get('relayVerified') is not False
                or run.returncode not in (0, 1)):
            raise ValueError('invalid Dart diagnostic result')
        return {'case': 'split_100_bytes' if split else 'unsplit',
                'observedAtUtc': datetime.now(timezone.utc).isoformat(),
                'exitCode': run.returncode, 'metadata': relay.metadata, 'report': report}
    finally:
        relay.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', required=True, type=https_origin)
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    dart = shutil.which(args.dart)
    if not dart:
        parser.error('Dart runtime was not found')
    if Path(dart).suffix.lower() in ('.bat', '.cmd'):
        native = Path(dart).parent / 'cache/dart-sdk/bin/dart.exe'
        if not native.is_file():
            parser.error('Pass the native Dart executable to --dart')
        dart = str(native)  # No implicit command shell for Windows batch files.
    try:
        results = [probe(args.origin, dart, split) for split in (False, True, False, True)]
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(json.dumps({'errorType': type(error).__name__, 'diagnosticOnly': True,
                          'pairingVerified': False, 'relayVerified': False}))
        return 1
    print(json.dumps({'diagnosticOnly': True, 'normalTransportReady': False,
                      'scope': 'ClientHello segmentation comparison; not pairing, TURN or root-cause proof',
                      'results': results}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
