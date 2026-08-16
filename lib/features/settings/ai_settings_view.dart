// lib/features/settings/ai_settings_view.dart

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../services/ai_hint_service.dart';

class AiSettingsView extends StatefulWidget {
  final bool isTeacher;

  const AiSettingsView({super.key, this.isTeacher = false});

  @override
  State<AiSettingsView> createState() => _AiSettingsViewState();
}

class _AiSettingsViewState extends State<AiSettingsView> {
  static const _storage = FlutterSecureStorage();

  AiProvider _provider = AiProvider.none;
  final _keyController = TextEditingController();
  bool _obscureKey = true;
  bool _isSaving = false;
  bool _isTesting = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final providerStr = await _storage.read(key: 'AI_PROVIDER');
    final key = await _storage.read(key: 'AI_API_KEY');
    setState(() {
      _provider = AiProvider.values.firstWhere(
        (p) => p.name == providerStr,
        orElse: () => AiProvider.none,
      );
      _keyController.text = key ?? '';
    });
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    await _storage.write(key: 'AI_PROVIDER', value: _provider.name);
    await _storage.write(key: 'AI_API_KEY', value: _keyController.text.trim());
    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AI settings saved.')),
      );
    }
  }

  Future<void> _testKey() async {
    setState(() {
      _isTesting = true;
      _testResult = null;
    });
    final result = await AiHintService.generateHints(
      questionText: 'What is 2 + 2?',
      questionType: 'multiple_choice',
      options: ['A. 3', 'B. 4', 'C. 5'],
      correctAnswer: 'B',
      provider: _provider,
      apiKey: _keyController.text.trim(),
    );
    if (mounted) {
      setState(() {
        _isTesting = false;
        _testResult = result != null
            ? 'Connection successful!'
            : 'Test failed. Check your API key and provider selection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Hint Settings'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (!widget.isTeacher) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: const Text(
                'Teachers can configure shared AI settings. Students can use their own API key for personal AI access.',
                style: TextStyle(color: Colors.blue, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 16),
          ],
          const Text(
            'AI Provider',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          _ProviderCard(
            label: 'Gemini 1.5 Flash (Google)',
            subtitle: 'Free tier available — get key at aistudio.google.com',
            icon: Icons.auto_awesome,
            selected: _provider == AiProvider.gemini,
            onTap: () => setState(() => _provider = AiProvider.gemini),
          ),
          const SizedBox(height: 8),
          _ProviderCard(
            label: 'GPT-4o mini (OpenAI)',
            subtitle: 'Paid — get key at platform.openai.com',
            icon: Icons.chat_bubble_outline,
            selected: _provider == AiProvider.openai,
            onTap: () => setState(() => _provider = AiProvider.openai),
          ),
          const SizedBox(height: 8),
          _ProviderCard(
            label: 'None (manual hints only)',
            subtitle: 'Disable AI hint generation',
            icon: Icons.block,
            selected: _provider == AiProvider.none,
            onTap: () => setState(() => _provider = AiProvider.none),
          ),
          const SizedBox(height: 24),
          if (widget.isTeacher) ...[
            const Text(
              'Shared AI Helper key (teacher-only)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'The shared key is stored in the app configuration and is not shown here.',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 16),
          ],
          if (widget.isTeacher && _provider != AiProvider.none) ...[
            const Text(
              'Quiz Helper API Key (BYOK, teacher use)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _keyController,
              obscureText: _obscureKey,
              decoration: InputDecoration(
                hintText: 'Paste your optional quiz-helper API key here',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _isTesting ? null : _testKey,
              icon: _isTesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.science_outlined),
              label: const Text('Test Connection'),
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 8),
              Text(
                _testResult!,
                style: TextStyle(
                  color: _testResult!.startsWith('Connection')
                      ? Colors.green.shade700
                      : Colors.red.shade700,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
          if (widget.isTeacher)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E3A8A),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Save Settings'),
            ),
          const SizedBox(height: 16),
          const Text(
            'API keys are stored securely on this device and are never transmitted '
            'over the LAN. They are only used to contact the AI provider directly.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ProviderCard({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? const Color(0xFF1E3A8A) : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? const Color(0xFF1E3A8A).withValues(alpha: 0.05)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(icon,
                color: selected ? const Color(0xFF1E3A8A) : Colors.grey),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? const Color(0xFF1E3A8A)
                              : Colors.black87)),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle,
                  color: Color(0xFF1E3A8A)),
          ],
        ),
      ),
    );
  }
}
