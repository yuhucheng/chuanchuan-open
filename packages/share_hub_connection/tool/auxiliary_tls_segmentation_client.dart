// Diagnostic-only client for an owned loopback TLS byte relay. Never pairs.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final origin = args.length == 2 ? Uri.tryParse(args[0]) : null;
  final port = args.length == 2 ? int.tryParse(args[1]) : null;
  if (origin == null ||
      origin.scheme != 'https' ||
      origin.host.isEmpty ||
      origin.userInfo.isNotEmpty ||
      origin.hasQuery ||
      origin.hasFragment ||
      origin.port < 1 ||
      origin.port > 65535 ||
      (origin.path.isNotEmpty && origin.path != '/') ||
      port == null ||
      port < 1 ||
      port > 65535) {
    stderr.writeln('Expected an HTTPS origin and owned loopback port.');
    exitCode = 64;
    return;
  }
  final report = <String, Object?>{
    'tlsValidated': false,
    'healthVerified': false,
    'pairingVerified': false,
    'relayVerified': false,
    'dartVersion': Platform.version.split(' ').first,
  };
  Socket? tcp;
  SecureSocket? tls;
  var stage = 'tcp';
  try {
    tcp = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(seconds: 5),
    );
    stage = 'tls';
    // The relay forwards encrypted bytes only. Certificate, hostname and
    // default TLS policy stay at this client; no certificate callback or ALPN
    // padding is installed.
    final secured = tls = await SecureSocket.secure(
      tcp,
      host: origin.host,
    ).timeout(const Duration(seconds: 8));
    report['tlsValidated'] = true;
    stage = 'health';
    secured.write(
      'GET /health HTTP/1.1\r\nHost: ${origin.authority}\r\n'
      'Connection: close\r\n\r\n',
    );
    await secured.flush();
    final bytes = <int>[];
    await (() async {
      await for (final chunk in secured) {
        if (bytes.length + chunk.length > 8192) {
          throw const FormatException('health response exceeds limit');
        }
        bytes.addAll(chunk);
      }
    })().timeout(const Duration(seconds: 8));
    final response = utf8.decode(bytes);
    final boundary = response.indexOf('\r\n\r\n');
    if (boundary < 0) throw const FormatException('invalid health response');
    final body = jsonDecode(response.substring(boundary + 4));
    report['healthVerified'] =
        (response.startsWith('HTTP/1.0 200 ') ||
            response.startsWith('HTTP/1.1 200 ')) &&
        body is Map &&
        body['status'] == 'ok';
  } catch (error) {
    report['stage'] = stage;
    report['errorType'] = error.runtimeType.toString();
    if (error is SocketException) report['errno'] = error.osError?.errorCode;
    if (error is TlsException) report['errno'] = error.osError?.errorCode;
  } finally {
    tls?.destroy();
    tcp?.destroy();
  }
  if (report['healthVerified'] != true) exitCode = 1;
  stdout.writeln(jsonEncode(report));
}
