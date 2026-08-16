import 'package:flutter_test/flutter_test.dart';
import 'package:asuratech_lan_classroom/features/online/room_join_utils.dart';

void main() {
  group('parseJoinedSessionPayload', () {
    test('returns the nested session object from a joined-classroom response', () {
      const body = '{"message":"Joined classroom successfully.","session":{"id":"session-123","status":"active","channel":"session.session-123"}}';

      final result = parseJoinedSessionPayload(body);

      expect(result, isNotNull);
      expect(result!['id'], 'session-123');
      expect(result['status'], 'active');
    });

    test('falls back to a flat payload when no session wrapper exists', () {
      const body = '{"id":"session-456","status":"active"}';

      final result = parseJoinedSessionPayload(body);

      expect(result, isNotNull);
      expect(result!['id'], 'session-456');
    });

    test('returns null for invalid payloads', () {
      final result = parseJoinedSessionPayload('not-json');

      expect(result, isNull);
    });
  });
}
