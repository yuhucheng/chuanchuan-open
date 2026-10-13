import argparse
from pathlib import Path
import socket
import sys
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] /
                      'packages/share_hub_connection/tool'))
from auxiliary_tls_segmentation_probe import ByteRelay, https_origin


class EchoPeer:
    def __init__(self, expected_bytes):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(3)
        self.port = self.listener.getsockname()[1]
        self.seen = b''
        self.expected_bytes = expected_bytes
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        connection = None
        try:
            connection, _ = self.listener.accept()
            connection.settimeout(3)
            while len(self.seen) < self.expected_bytes:
                chunk = connection.recv(self.expected_bytes - len(self.seen))
                if not chunk:
                    break
                self.seen += chunk
            connection.sendall(b'opaque reply fixture')
        except OSError:
            pass
        finally:
            if connection:
                connection.close()
            self.listener.close()

    def close(self):
        self.thread.join(5)
        assert not self.thread.is_alive()


class SegmentationTests(unittest.TestCase):
    def test_origin_rejects_credentials_paths_and_empty_query_markers(self):
        for origin in ('http://example.invalid', 'https://secret@example.invalid',
                       'https://example.invalid/extra', 'https://example.invalid?',
                       'https://example.invalid#', 'https://example.invalid:0',
                       'https://example.invalid:99999', 'https://example&invalid',
                       'https://exam\nple.invalid'):
            with self.subTest(origin=origin):
                with self.assertRaises(argparse.ArgumentTypeError) as caught:
                    https_origin(origin)
                self.assertNotIn('secret', str(caught.exception))
        self.assertEqual(https_origin('https://example.invalid:8443'),
                         'https://example.invalid:8443')

    def test_whole_and_split_preserve_both_directions_and_following_records(self):
        body = b'\x01' + (240).to_bytes(3, 'big') + b'x' * 240
        hello = b'\x16\x03\x01' + len(body).to_bytes(2, 'big') + body
        following = b'\x17\x03\x03\x00\x06opaque'
        wire = hello + following
        for split in (False, True):
            with self.subTest(split=split):
                peer = EchoPeer(len(wire))
                relay = ByteRelay('127.0.0.1', peer.port, split)
                client = socket.create_connection(('127.0.0.1', relay.port), timeout=3)
                try:
                    client.sendall(wire)
                    reply = b''
                    while chunk := client.recv(1024):
                        reply += chunk
                    self.assertEqual(reply, b'opaque reply fixture')
                    self.assertEqual(peer.seen, wire)
                    self.assertEqual(relay.metadata['clientHelloRecordBytes'], len(hello))
                finally:
                    client.close()
                    relay.close()
                    peer.close()
                self.assertTrue(relay.finished.is_set())
                self.assertFalse(relay.thread.is_alive())

    def test_non_clienthello_is_rejected_before_forwarding_bytes(self):
        peer = EchoPeer(9)
        relay = ByteRelay('127.0.0.1', peer.port, True)
        client = socket.create_connection(('127.0.0.1', relay.port), timeout=3)
        try:
            client.sendall(b'\x17\x03\x03\x00\x04data')
            try:
                while client.recv(1024):
                    pass
            except OSError:
                pass
        finally:
            client.close()
            relay.close()
            peer.close()
        self.assertEqual(peer.seen, b'')
        self.assertEqual(relay.metadata['relayErrorType'], 'ValueError')


if __name__ == '__main__':
    unittest.main()
