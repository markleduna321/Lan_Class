// lib/services/cloud_api_service.dart
//
// Phase 1 — Account Linking & API Client
// Manages all HTTP communication with the Laravel backend.
// All methods are static; token lifecycle is handled via FlutterSecureStorage.

import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Result type returned by auth methods.
typedef CloudAuthResult = ({String token, Map<String, dynamic> user});

/// Richer login result that carries the server error message on failure.
typedef CloudLoginVerbose = ({CloudAuthResult? result, String error});

class CloudApiService {
  static const _storage = FlutterSecureStorage();

  // -----------------------------------------------------------------------
  // Secure storage keys
  // -----------------------------------------------------------------------
  static const kBaseUrl      = 'ONLINE_BASE_URL';
  static const kToken        = 'ONLINE_TOKEN';
  static const kOnlineUserId = 'ONLINE_USER_ID';
  static const kOnlineName   = 'ONLINE_USER_NAME';

  /// The fixed backend server for this app.
  static const serverBaseUrl = 'https://itcomm.asuratechsolutions.com';

  // -----------------------------------------------------------------------
  // Configuration
  // -----------------------------------------------------------------------

  /// Always returns the hard-coded server URL.
  static Future<String> getBaseUrl() async => serverBaseUrl;

  /// No-op — the server URL is fixed. Kept for API compatibility.
  static Future<void> setBaseUrl(String url) async {}

  /// True when a Sanctum token is present in storage.
  static Future<bool> get isLinked async {
    final token = await _storage.read(key: kToken);
    return token != null && token.isNotEmpty;
  }

  /// Returns the stored Laravel user ID, or null if not linked.
  static Future<String?> getOnlineUserId() async {
    return await _storage.read(key: kOnlineUserId);
  }

  /// Returns the stored online display name, or null if not linked.
  static Future<String?> getOnlineName() async {
    return await _storage.read(key: kOnlineName);
  }

  // -----------------------------------------------------------------------
  // Auth — Login
  // -----------------------------------------------------------------------

  /// POST /api/auth/login
  /// Returns a [CloudAuthResult] on success, or null on failure / network error.
  static Future<CloudAuthResult?> login(String email, String password) async {
    try {
      final base = await getBaseUrl();
      if (base.isEmpty) return null;

      final response = await http
          .post(
            Uri.parse('$base/api/auth/login'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['token'] as String;
        final user  = data['user']  as Map<String, dynamic>;

        await _persistToken(token, user);
        return (token: token, user: user);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// POST /api/auth/login — like [login] but returns the server error message
  /// on failure instead of plain null, so the UI can show a specific reason.
  static Future<CloudLoginVerbose> loginWithError(
      String email, String password) async {
    try {
      final base = await getBaseUrl();
      final response = await http
          .post(
            Uri.parse('$base/api/auth/login'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data  = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['token'] as String;
        final user  = data['user']  as Map<String, dynamic>;
        await _persistToken(token, user);
        return (result: (token: token, user: user), error: '');
      }

      // Extract server-provided message (Laravel returns {"message":"..."})
      String serverMsg = 'Server error (${response.statusCode})';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        serverMsg = (body['message'] as String?) ?? serverMsg;
      } catch (_) {}
      return (result: null, error: serverMsg);
    } on TimeoutException {
      return (result: null, error: 'Connection timed out. Check your network.');
    } catch (_) {
      return (result: null, error: 'Network error. Check your connection.');
    }
  }

  // -----------------------------------------------------------------------
  // Auth — Register
  // -----------------------------------------------------------------------

  /// POST /api/auth/register
  /// [userData] should contain: name, email, password, password_confirmation, role.
  /// Returns a [CloudAuthResult] on success, or null on failure / network error.
  static Future<CloudAuthResult?> register(Map<String, dynamic> userData) async {
    try {
      final base = await getBaseUrl();
      if (base.isEmpty) return null;

      final response = await http
          .post(
            Uri.parse('$base/api/auth/register'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(userData),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['token'] as String;
        final user  = data['user']  as Map<String, dynamic>;

        await _persistToken(token, user);
        return (token: token, user: user);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Auth — Logout
  // -----------------------------------------------------------------------

  /// POST /api/auth/logout  (best-effort — clears local token regardless)
  static Future<void> logout() async {
    try {
      final base  = await getBaseUrl();
      final token = await _storage.read(key: kToken);
      if (base.isNotEmpty && token != null) {
        await http
            .post(
              Uri.parse('$base/api/auth/logout'),
              headers: {
                'Accept': 'application/json',
                'Authorization': 'Bearer $token',
              },
            )
            .timeout(const Duration(seconds: 10));
      }
    } catch (_) {}

    await _clearToken();
  }

  // -----------------------------------------------------------------------
  // Generic authenticated requests (used by later phases)
  // -----------------------------------------------------------------------

  /// GET [endpoint] with Bearer token. Returns null on network error.
  static Future<http.Response?> get(String endpoint) async {
    try {
      final base  = await getBaseUrl();
      final token = await _storage.read(key: kToken);
      return await http
          .get(
            Uri.parse('$base$endpoint'),
            headers: {
              'Accept': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return null;
    }
  }

  /// Fetches the authenticated user's profile from /api/user/profile.
  /// Returns the decoded profile payload or null when unavailable.
  static Future<Map<String, dynamic>?> getCurrentProfile() async {
    final response = await get('/api/user/profile');
    if (response == null || response.statusCode != 200) return null;

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// POST [endpoint] with JSON [body] and Bearer token. Returns null on network error.
  /// [timeout] can be raised for slow endpoints such as AI generation.
  static Future<http.Response?> post(
      String endpoint, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 15)}) async {
    try {
      final base  = await getBaseUrl();
      final token = await _storage.read(key: kToken);
      return await http
          .post(
            Uri.parse('$base$endpoint'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  /// PATCH [endpoint] with JSON [body] and Bearer token. Returns null on network error.
  static Future<http.Response?> patch(
      String endpoint, Map<String, dynamic> body) async {
    try {
      final base  = await getBaseUrl();
      final token = await _storage.read(key: kToken);
      return await http
          .patch(
            Uri.parse('$base$endpoint'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  static Future<void> _persistToken(
      String token, Map<String, dynamic> user) async {
    await _storage.write(key: kToken, value: token);
    await _storage.write(
        key: kOnlineUserId, value: user['id'].toString());
    await _storage.write(
        key: kOnlineName,
        value: (user['name'] as String?) ?? '');
  }

  static Future<void> _clearToken() async {
    await _storage.delete(key: kToken);
    await _storage.delete(key: kOnlineUserId);
    await _storage.delete(key: kOnlineName);
  }
}
