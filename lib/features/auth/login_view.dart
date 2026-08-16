// lib/features/auth/login_view.dart

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../../database/asura_repository.dart';
import '../../services/cloud_api_service.dart';
import 'role_utils.dart';
import 'user_model.dart';
import '../classroom/main_app_shell.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _signInOnline = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _prefillStoredCredentials();
  }

  /// Pre-fill with the last-used local credentials so the user doesn't
  /// have to retype them on every app restart.
  Future<void> _prefillStoredCredentials() async {
    const storage = FlutterSecureStorage();
    final email = await storage.read(key: 'ACTIVE_USER_EMAIL');
    final password = await storage.read(key: 'ACTIVE_USER_PASSWORD');
    if (!mounted) return;
    if (email != null) _emailController.text = email;
    if (password != null) _passwordController.text = password;
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final email = _emailController.text.trim().toLowerCase();
      final password = _passwordController.text;

      Map<String, dynamic>? user = await AsuraRepository.validateLogin(
        email,
        password,
      );

      CloudAuthResult? cloudResult;

      // Local-first, then cloud fallback for returning users on fresh devices.
      if (user == null) {
        final cloudLogin = await CloudApiService.loginWithError(email, password);
        if (cloudLogin.result == null) {
          if (!mounted) return;
          setState(() {
            _errorMessage = cloudLogin.error.isNotEmpty
                ? cloudLogin.error
                : 'Invalid email or password. Please try again.';
            _isLoading = false;
          });
          return;
        }

        cloudResult = cloudLogin.result;
        user = await _upsertCloudUserToLocal(
          email: email,
          password: password,
          cloudUser: cloudResult!.user,
        );
      } else {
        final cloudLogin = await CloudApiService.loginWithError(email, password);
        if (cloudLogin.result != null) {
          cloudResult = cloudLogin.result;
          user = await _upsertCloudUserToLocal(
            email: email,
            password: password,
            cloudUser: cloudResult!.user,
          );
        }
      }

      if (!mounted || user == null) return;

      // Optional explicit online link for users who signed in locally.
      if (_signInOnline) {
        final result = cloudResult ?? await CloudApiService.login(email, password);
        if (result != null) {
          await AsuraRepository.updateUserRemoteId(
            user['id'] as String,
            result.user['id'].toString(),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Local sign-in succeeded. Online link failed — check your credentials.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }

      final nameParts = <String>[
        (user['first_name'] as String?)?.trim().isNotEmpty == true
            ? (user['first_name'] as String).trim()
            : 'User',
        if ((user['middle_name'] as String?)?.trim().isNotEmpty == true)
          (user['middle_name'] as String).trim(),
        if ((user['last_name'] as String?)?.trim().isNotEmpty == true)
          (user['last_name'] as String).trim(),
      ];

      const storage = FlutterSecureStorage();
      final normalizedRole = normalizePersistedRole(user['role'] as String?);
      await storage.write(key: 'ACTIVE_USER_UUID', value: user['id'] as String);
      await storage.write(key: 'ACTIVE_USER_ROLE', value: normalizedRole);
      await storage.write(key: 'ACTIVE_USER_NAME', value: nameParts.join(' '));
      await storage.write(key: 'ACTIVE_USER_EMAIL', value: user['email'] as String);
      await storage.write(key: 'ACTIVE_USER_PASSWORD', value: password);

      final role = normalizedRole == 'presenter' ? UserRole.presenter : UserRole.audience;

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => MainAppShell(userRole: role)),
      );
    } catch (_) {
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
        _isLoading = false;
      });
    }
  }

  Future<Map<String, dynamic>?> _upsertCloudUserToLocal({
    required String email,
    required String password,
    required Map<String, dynamic> cloudUser,
  }) async {
    final existing = await AsuraRepository.getUserByEmail(email);
    final nameParts = _splitName(
      (cloudUser['name'] as String?) ??
          '${cloudUser['first_name'] ?? ''} ${cloudUser['last_name'] ?? ''}',
    );

    final firstName = (cloudUser['first_name'] as String?)?.trim().isNotEmpty == true
        ? (cloudUser['first_name'] as String).trim()
        : (nameParts.$1.isNotEmpty
            ? nameParts.$1
            : ((existing?['first_name'] as String?)?.trim().isNotEmpty == true
                ? (existing!['first_name'] as String).trim()
                : 'User'));

    final lastName = (cloudUser['last_name'] as String?)?.trim().isNotEmpty == true
        ? (cloudUser['last_name'] as String).trim()
        : (nameParts.$3.isNotEmpty
            ? nameParts.$3
            : ((existing?['last_name'] as String?)?.trim().isNotEmpty == true
                ? (existing!['last_name'] as String).trim()
                : ''));

    final middleName = (cloudUser['middle_name'] as String?)?.trim().isNotEmpty == true
        ? (cloudUser['middle_name'] as String).trim()
        : (nameParts.$2.isNotEmpty ? nameParts.$2 : (existing?['middle_name'] as String?));

    final apiRole = extractRoleFromApiPayload(cloudUser);
    final normalizedRole = _normalizeRole(cloudUser['role']) ??
        apiRole ??
        ((existing?['role'] as String?)?.trim().isNotEmpty == true
            ? (existing!['role'] as String)
            : 'audience');
    final cloudReputation = extractReputationFromApiPayload(cloudUser);

    final localId = (existing?['id'] as String?) ?? const Uuid().v4();

    final merged = <String, dynamic>{
      ...?existing,
      'id': localId,
      'first_name': firstName,
      'last_name': lastName,
      'middle_name': middleName,
      'email': email,
      'password_hash': AsuraRepository.hashPassword(password),
      'role': normalizedRole,
      'remote_id': cloudUser['id']?.toString(),
      'is_synced': 1,
      'aura_score': cloudReputation ??
          (cloudUser['aura_score'] as num?)?.toInt() ??
          (cloudUser['aura'] as num?)?.toInt() ??
          (existing?['aura_score'] ?? 0),
    };

    await AsuraRepository.upsertUser(merged);
    return await AsuraRepository.getUserById(localId);
  }

  (String, String, String) _splitName(String raw) {
    final parts = raw
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();

    if (parts.isEmpty) return ('', '', '');
    if (parts.length == 1) return (parts.first, '', '');
    if (parts.length == 2) return (parts.first, '', parts.last);
    return (
      parts.first,
      parts.sublist(1, parts.length - 1).join(' '),
      parts.last,
    );
  }

  String? _normalizeRole(dynamic rawRole) {
    final roleText = rawRole?.toString();
    final value = normalizePersistedRole(roleText);
    return value == 'audience' && (roleText?.trim().isEmpty ?? true) ? null : value;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign In'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),

                const Icon(Icons.lock_person_rounded, size: 72, color: Color(0xFF1E3A8A)),
                const SizedBox(height: 20),
                const Text(
                  'Welcome Back',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Sign in to your AsuraTECH account.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 40),

                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email Address',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                ),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _login(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) => (v == null || v.isEmpty) ? 'Password is required' : null,
                ),

                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      border: Border.all(color: Colors.red.shade200),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_errorMessage!, style: const TextStyle(color: Colors.red))),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 32),

                SwitchListTile(
                  value: _signInOnline,
                  onChanged: (v) => setState(() => _signInOnline = v),
                  title: const Text('Also sign in online'),
                  subtitle: const Text('Links this account to the configured server.'),
                  secondary: const Icon(Icons.cloud_outlined),
                  contentPadding: EdgeInsets.zero,
                ),

                const SizedBox(height: 8),

                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: const Color(0xFF1E3A8A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _isLoading ? null : _login,
                  child: _isLoading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                        )
                      : const Text('Sign In', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),

                const SizedBox(height: 20),

                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      "Don't have an account? Register here",
                      style: TextStyle(color: Color(0xFF1E3A8A)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
