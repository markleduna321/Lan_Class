class AiConfig {
  static const String sharedHelperApiKey = String.fromEnvironment(
    'AI_HELPER_SHARED_KEY',
    defaultValue: '',
  );

  static String? get sharedHelperApiKeyOrNull {
    final value = sharedHelperApiKey.trim();
    return value.isEmpty ? null : value;
  }
}
