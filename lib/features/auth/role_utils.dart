class RoleUtils {
  static String normalizePersistedRole(String? role) {
    final normalized = role?.trim().toLowerCase();
    if (normalized == 'presenter' || normalized == 'teacher') {
      return 'presenter';
    }
    if (normalized == 'audience' || normalized == 'student') {
      return 'audience';
    }
    return 'audience';
  }

  static String normalizeApiRole(String? role) {
    final normalized = normalizePersistedRole(role);
    return normalized == 'presenter' ? 'teacher' : 'student';
  }

  static String? extractRoleFromApiPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;

    final directRole = payload['role']?.toString();
    if (directRole != null && directRole.trim().isNotEmpty) {
      return normalizePersistedRole(directRole);
    }

    final userType = payload['user_type']?.toString();
    if (userType != null && userType.trim().isNotEmpty) {
      return normalizePersistedRole(userType);
    }

    final accountType = payload['account_type']?.toString();
    if (accountType != null && accountType.trim().isNotEmpty) {
      return normalizePersistedRole(accountType);
    }

    final isTeacher = payload['is_teacher'];
    if (isTeacher is bool) {
      return isTeacher ? 'presenter' : 'audience';
    }

    return null;
  }

  static int? extractReputationFromApiPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;

    int? parseInt(dynamic value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value.trim());
      return null;
    }

    // Prefer explicit aura score fields first; some endpoints also return a
    // separate forum "reputation" score that should not override aura_score.
    final auraScore = parseInt(payload['aura_score']);
    if (auraScore != null) return auraScore;

    final profile = payload['profile'];
    if (profile is Map<String, dynamic>) {
      final nestedAuraScore = parseInt(profile['aura_score']);
      if (nestedAuraScore != null) return nestedAuraScore;
      final nestedAura = parseInt(profile['aura']);
      if (nestedAura != null) return nestedAura;
      final nestedReputation = parseInt(profile['reputation']);
      if (nestedReputation != null) return nestedReputation;
    }

    final user = payload['user'];
    if (user is Map<String, dynamic>) {
      final nestedAuraScore = parseInt(user['aura_score']);
      if (nestedAuraScore != null) return nestedAuraScore;
      final nestedAura = parseInt(user['aura']);
      if (nestedAura != null) return nestedAura;
      final nestedReputation = parseInt(user['reputation']);
      if (nestedReputation != null) return nestedReputation;
    }

    final aura = parseInt(payload['aura']);
    if (aura != null) return aura;

    final reputation = parseInt(payload['reputation']);
    if (reputation != null) return reputation;

    final score = parseInt(payload['score']);
    if (score != null) return score;

    return null;
  }
}

String normalizePersistedRole(String? role) => RoleUtils.normalizePersistedRole(role);
String normalizeApiRole(String? role) => RoleUtils.normalizeApiRole(role);
String? extractRoleFromApiPayload(Map<String, dynamic>? payload) =>
    RoleUtils.extractRoleFromApiPayload(payload);
int? extractReputationFromApiPayload(Map<String, dynamic>? payload) =>
    RoleUtils.extractReputationFromApiPayload(payload);
