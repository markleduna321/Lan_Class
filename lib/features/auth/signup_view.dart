// lib/features/auth/signup_view.dart

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../database/asura_repository.dart';
import '../../services/cloud_api_service.dart';
import 'role_utils.dart';
import 'user_model.dart';
import '../classroom/main_app_shell.dart';

class SignupView extends StatefulWidget {
  final UserRole chosenRole;

  const SignupView({super.key, required this.chosenRole});

  @override
  State<SignupView> createState() => _SignupViewState();
}

class _SignupViewState extends State<SignupView> {
  final _formKey = GlobalKey<FormState>();
  final _pageController = PageController();
  int _currentStepIndex = 0;

  // Controllers: Page 1 (Personal Info)
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _middleNameController = TextEditingController();
  final _professionController = TextEditingController();
  final _specialtiesController = TextEditingController();

  // Controllers: Page 2 (Security Matrix)
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  // Password Live State Evaluation Flags
  bool _hasMinLength = false;
  bool _hasUppercase = false;
  bool _hasLowercase = false;
  bool _hasNumber = false;
  bool _hasSpecialChar = false;
  bool _isPasswordMatching = false;
  bool _isSubmitting = false;
  bool _registerOnline = false;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_validatePasswordRules);
    _confirmPasswordController.addListener(_validatePasswordMatch);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _middleNameController.dispose();
    _professionController.dispose();
    _specialtiesController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _validatePasswordRules() {
    final text = _passwordController.text;
    setState(() {
      _hasMinLength = text.length >= 8;
      _hasUppercase = text.contains(RegExp(r'[A-Z]'));
      _hasLowercase = text.contains(RegExp(r'[a-z]'));
      _hasNumber = text.contains(RegExp(r'[0-9]'));
      _hasSpecialChar = text.contains(RegExp(r'[!@#\$&*~%^()_+=|<>?:{}-]'));
    });
    _validatePasswordMatch(); // Re-evaluate match state if master changes
  }

  void _validatePasswordMatch() {
    setState(() {
      _isPasswordMatching = _passwordController.text.isNotEmpty &&
          _passwordController.text == _confirmPasswordController.text;
    });
  }

  bool _isPasswordFullyValid() {
    return _hasMinLength && _hasUppercase && _hasLowercase && _hasNumber && _hasSpecialChar;
  }

  void _navigateToNextPage() {
    if (_formKey.currentState!.validate()) {
      if (_currentStepIndex == 0) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
        setState(() => _currentStepIndex = 1);
      } else {
        _executeFinalRegistration();
      }
    }
  }

  void _navigateToPreviousPage() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    setState(() => _currentStepIndex = 0);
  }

  void _executeFinalRegistration() async {
    if (!_isPasswordFullyValid() || !_isPasswordMatching || _isSubmitting) return;
    setState(() => _isSubmitting = true);

    const secureStorage = FlutterSecureStorage();
    const uuidFactory = Uuid();
    final String generatedUserUuid = uuidFactory.v4();
    final String email = _emailController.text.trim().toLowerCase();

    // Guard: reject duplicate emails
    final existing = await AsuraRepository.getUserByEmail(email);
    if (!mounted) return;
    if (existing != null) {
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An account with this email already exists. Please log in instead.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Persist to local database
    final parts = [
      _firstNameController.text.trim(),
      if (_middleNameController.text.trim().isNotEmpty) _middleNameController.text.trim(),
      _lastNameController.text.trim(),
    ];
    final fullName = parts.join(' ');

    await AsuraRepository.insertUser({
      'id': generatedUserUuid,
      'first_name': _firstNameController.text.trim(),
      'last_name': _lastNameController.text.trim(),
      'middle_name': _middleNameController.text.trim().isNotEmpty
          ? _middleNameController.text.trim()
          : null,
      'email': email,
      'password_hash': AsuraRepository.hashPassword(_passwordController.text),
      'profession': _professionController.text.trim().isNotEmpty
          ? _professionController.text.trim()
          : null,
      'specialties': _specialtiesController.text.trim().isNotEmpty
          ? _specialtiesController.text.trim()
          : null,
      'role': widget.chosenRole.name,
      'aura_score': 0,
      'is_synced': 0,
    });

    // Persist session tokens
    await secureStorage.write(key: 'ACTIVE_USER_UUID', value: generatedUserUuid);
    await secureStorage.write(key: 'ACTIVE_USER_ROLE', value: widget.chosenRole.name);
    await secureStorage.write(key: 'ACTIVE_USER_NAME', value: fullName);
    await secureStorage.write(key: 'ACTIVE_USER_EMAIL', value: email);
    await secureStorage.write(key: 'ACTIVE_USER_PASSWORD', value: _passwordController.text);

    // Optionally create a matching online account (non-blocking)
    if (_registerOnline) {
      final result = await CloudApiService.register({
        'name': fullName,
        'email': email,
        'password': _passwordController.text,
        'password_confirmation': _passwordController.text,
        'role': normalizeApiRole(widget.chosenRole.name),
      });
      if (result != null) {
        await AsuraRepository.updateUserRemoteId(
          generatedUserUuid,
          result.user['id'].toString(),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Local account created. Online registration failed — check your credentials.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => MainAppShell(userRole: widget.chosenRole),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPresenter = widget.chosenRole == UserRole.presenter;

    return Scaffold(
      appBar: AppBar(
        title: Text(isPresenter ? 'Presenter Setup ($_currentStepIndex/1)' : 'Audience Setup ($_currentStepIndex/1)'),
        leading: _currentStepIndex == 1 
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _navigateToPreviousPage)
            : null,
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(), // Force navigation strictly via buttons
            children: [
              _buildPageOnePersonalInfo(isPresenter),
              _buildPageTwoSecurityCredentials(),
            ],
          ),
        ),
      ),
    );
  }

  // --- PAGE 1: PERSONAL INFORMATION ---
  Widget _buildPageOnePersonalInfo(bool isPresenter) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Personal Details', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 8),
          const Text('Provide your legal parameters to establish class profiles.'),
          const SizedBox(height: 24),
          TextFormField(
            controller: _firstNameController,
            decoration: const InputDecoration(labelText: 'First Name *', border: OutlineInputBorder()),
            validator: (value) => value!.isEmpty ? 'First name is required' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _middleNameController,
            decoration: InputDecoration(labelText: isPresenter ? 'Middle Name (Optional)' : 'Middle Name *', border: const OutlineInputBorder()),
            validator: (value) => (!isPresenter && value!.isEmpty) ? 'Middle name is required for validation' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _lastNameController,
            decoration: const InputDecoration(labelText: 'Last Name *', border: OutlineInputBorder()),
            validator: (value) => value!.isEmpty ? 'Last name is required' : null,
          ),
          if (isPresenter) ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _professionController,
              decoration: const InputDecoration(labelText: 'Profession * (e.g., Solutions Architect)', border: OutlineInputBorder()),
              validator: (value) => value!.isEmpty ? 'Profession is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _specialtiesController,
              decoration: const InputDecoration(labelText: 'Specialties * (e.g., Networking, IT Infrastructure)', border: OutlineInputBorder()),
              validator: (value) => value!.isEmpty ? 'Specialties criteria required' : null,
            ),
          ],
          const SizedBox(height: 32),
          ElevatedButton(
            style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            onPressed: _navigateToNextPage,
            child: const Text('Continue to Security', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  // --- PAGE 2: SECURITY & LIVE VALIDATIONS ---
  Widget _buildPageTwoSecurityCredentials() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Security Parameters', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 8),
          const Text('Secure your access profile credentials below.'),
          const SizedBox(height: 24),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email Address *', border: OutlineInputBorder()),
            validator: (value) => !value!.contains('@') ? 'Enter a valid email' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password *', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          
          // Live Dynamic Password Requirement Text Layout Block
          _buildValidationRuleRow('At least 8 characters', _hasMinLength),
          _buildValidationRuleRow('At least 1 uppercase letter (A-Z)', _hasUppercase),
          _buildValidationRuleRow('At least 1 lowercase letter (a-z)', _hasLowercase),
          _buildValidationRuleRow('At least 1 number (0-9)', _hasNumber),
          _buildValidationRuleRow('At least 1 special character (e.g., @, #, \$)', _hasSpecialChar),
          
          const SizedBox(height: 16),
          TextFormField(
            controller: _confirmPasswordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Confirm Password *', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          
          // Live Match Validator Row
          Row(
            children: [
              Icon(
                _isPasswordMatching ? Icons.check_circle : Icons.cancel,
                color: _isPasswordMatching ? Colors.green : Colors.red,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                _isPasswordMatching ? 'Passwords match perfectly.' : 'Passwords do not match yet.',
                style: TextStyle(color: _isPasswordMatching ? Colors.green : Colors.red, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          
          const SizedBox(height: 24),

          // --- ONLINE REGISTRATION TOGGLE ---
          SwitchListTile(
            value: _registerOnline,
            onChanged: (v) => setState(() => _registerOnline = v),
            title: const Text('Also register online'),
            subtitle: const Text('Creates a matching account on the configured server.'),
            secondary: const Icon(Icons.cloud_outlined),
            contentPadding: EdgeInsets.zero,
          ),

          const SizedBox(height: 16),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16), 
              backgroundColor: (_isPasswordFullyValid() && _isPasswordMatching) ? Theme.of(context).colorScheme.primary : Colors.grey, 
              foregroundColor: Colors.white, 
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
            ),
            onPressed: (_isPasswordFullyValid() && _isPasswordMatching && !_isSubmitting) ? _navigateToNextPage : null,
            child: _isSubmitting
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('Complete Registration', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  Widget _buildValidationRuleRow(String ruleText, bool isValid) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        children: [
          Icon(isValid ? Icons.check : Icons.close, color: isValid ? Colors.green : Colors.red, size: 16),
          const SizedBox(width: 8),
          Text(ruleText, style: TextStyle(color: isValid ? Colors.green : Colors.red, fontSize: 12, fontWeight: isValid ? FontWeight.w500 : FontWeight.normal)),
        ],
      ),
    );
  }
}