import 'dart:convert';

Map<String, dynamic>? parseJoinedSessionPayload(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final nested = decoded['session'];
      if (nested is Map<String, dynamic>) {
        return nested;
      }
      return decoded;
    }
  } catch (_) {}
  return null;
}
