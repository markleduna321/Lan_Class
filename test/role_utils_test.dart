import 'package:flutter_test/flutter_test.dart';
import 'package:asuratech_lan_classroom/features/auth/role_utils.dart';

void main() {
  group('normalizePersistedRole', () {
    test('preserves presenter role values', () {
      expect(normalizePersistedRole('presenter'), 'presenter');
      expect(normalizePersistedRole('teacher'), 'presenter');
    });

    test('preserves audience role values', () {
      expect(normalizePersistedRole('audience'), 'audience');
      expect(normalizePersistedRole('student'), 'audience');
    });

    test('defaults unknown roles to audience', () {
      expect(normalizePersistedRole(null), 'audience');
      expect(normalizePersistedRole(''), 'audience');
      expect(normalizePersistedRole('admin'), 'audience');
    });
  });

  group('normalizeApiRole', () {
    test('maps app roles to web roles', () {
      expect(normalizeApiRole('presenter'), 'teacher');
      expect(normalizeApiRole('audience'), 'student');
      expect(normalizeApiRole('teacher'), 'teacher');
      expect(normalizeApiRole('student'), 'student');
    });
  });

  group('extractRoleFromApiPayload', () {
    test('reads role from common API field names', () {
      expect(extractRoleFromApiPayload({'role': 'presenter'}), 'presenter');
      expect(extractRoleFromApiPayload({'user_type': 'teacher'}), 'presenter');
      expect(extractRoleFromApiPayload({'account_type': 'student'}), 'audience');
      expect(extractRoleFromApiPayload({'is_teacher': true}), 'presenter');
      expect(extractRoleFromApiPayload({'is_teacher': false}), 'audience');
    });

    test('returns null when the API payload does not contain a role', () {
      expect(extractRoleFromApiPayload({'name': 'Juan'}), null);
      expect(extractRoleFromApiPayload(null), null);
    });
  });

  group('extractReputationFromApiPayload', () {
    test('reads reputation from the new API shape', () {
      expect(extractReputationFromApiPayload({'reputation': 42}), 42);
      expect(extractReputationFromApiPayload({'aura': 7}), 7);
      expect(extractReputationFromApiPayload({}), null);
    });
  });
}
