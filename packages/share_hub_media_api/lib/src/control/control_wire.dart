import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

/// Internal flat control profile parser. Nested objects are rejected; scalar
/// fields and string arrays are checked by each message's exact schema.
Map<String, dynamic> controlObject(String body, {required int maximumBytes}) {
  if (body.length > maximumBytes || utf8.encode(body).length > maximumBytes) {
    throw const SessionFailure('message_limit');
  }
  try {
    final keys = <String>{};
    for (var index = 0; index < body.length; index++) {
      if (body.codeUnitAt(index) != 34) continue;
      final start = index++;
      while (index < body.length && body.codeUnitAt(index) != 34) {
        if (body.codeUnitAt(index) == 92) index++;
        index++;
      }
      if (index >= body.length) throw const FormatException();
      var next = index + 1;
      while (next < body.length && ' \t\r\n'.contains(body[next])) {
        next++;
      }
      if (next < body.length && body[next] == ':') {
        final key = jsonDecode(body.substring(start, index + 1)) as String;
        if (!keys.add(key)) throw const FormatException();
      }
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    if (decoded.values.any(
      (value) =>
          value is Map ||
          (value is List && value.any((item) => item is! String)),
    )) {
      throw const FormatException();
    }
    return decoded;
  } on FormatException {
    throw const SessionFailure('invalid_message');
  }
}
