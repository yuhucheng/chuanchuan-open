// Read-only transport preflight. No registration, code lookup or TURN request.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final endpoint = args.length == 1 ? Uri.tryParse(args.single) : null;
  if (endpoint == null ||
      endpoint.scheme != 'https' ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      (endpoint.path.isNotEmpty && endpoint.path != '/') ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    stderr.writeln(
      'Usage: dart run tool/auxiliary_health_probe.dart https://host:port',
    );
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
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  var stage = 'connect';
  try {
    // Same default certificate validation as the normal auxiliary transport.
    // Never accept a bad certificate or replace TLS with plaintext HTTP.
    final request = await client
        .getUrl(endpoint.resolve('/health'))
        .timeout(const Duration(seconds: 10));
    report['tlsValidated'] = true;
    stage = 'response';
    final response = await request.close().timeout(const Duration(seconds: 10));
    report['httpStatus'] = response.statusCode;
    stage = 'body';
    final bytes = <int>[];
    await (() async {
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 4096) {
          throw const FormatException('health response exceeds limit');
        }
        bytes.addAll(chunk);
      }
    })().timeout(const Duration(seconds: 10));
    final body = jsonDecode(utf8.decode(bytes));
    report['healthVerified'] =
        response.statusCode == 200 && body is Map && body['status'] == 'ok';
    if (report['healthVerified'] != true) exitCode = 1;
  } catch (error) {
    report['stage'] = stage;
    report['errorType'] = error.runtimeType.toString();
    if (error is SocketException) report['errno'] = error.osError?.errorCode;
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
  // Do not echo response data, URLs, credentials or raw exception messages.
  stdout.writeln(jsonEncode(report));
}
