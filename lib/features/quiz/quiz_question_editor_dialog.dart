// lib/features/quiz/quiz_question_editor_dialog.dart
//
// Bottom-sheet question editor used in both template editor and room quiz editor.
// Returns a Map<String, dynamic> on save:
//   {question_text, question_type, options (JSON string), correct_answer, hints (JSON string), points}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../../services/ai_hint_service.dart';

class QuizQuestionEditorDialog extends StatefulWidget {
  /// Pass existing question data to edit, or null to create new.
  final Map<String, dynamic>? initial;

  const QuizQuestionEditorDialog({super.key, this.initial});

  /// Opens as a modal bottom sheet and returns the question map or null.
  static Future<Map<String, dynamic>?> show(
      BuildContext context, {Map<String, dynamic>? initial}) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuizQuestionEditorDialog(initial: initial),
    );
  }

  @override
  State<QuizQuestionEditorDialog> createState() =>
      _QuizQuestionEditorDialogState();
}

class _QuizQuestionEditorDialogState extends State<QuizQuestionEditorDialog> {
  static const _storage = FlutterSecureStorage();

  final _textController = TextEditingController();
  String _questionType = 'multiple_choice';
  final List<TextEditingController> _optionControllers = [];
  String? _correctAnswer; // letter key for MC/TF, null for SA
  Map<String, dynamic>? _hints;
  int _points = 1;
  bool _generatingHints = false;

  // MC: max 6 options minimum 2
  // TF: fixed options True / False
  static const _tfOptions = ['True', 'False'];

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    if (d != null) {
      _textController.text = d['question_text'] as String? ?? '';
      _questionType = d['question_type'] as String? ?? 'multiple_choice';
      _points = (d['points'] as int?) ?? 1;
      _correctAnswer = d['correct_answer'] as String?;
      final hintsRaw = d['hints'];
      if (hintsRaw is String && hintsRaw.isNotEmpty) {
        try { _hints = jsonDecode(hintsRaw) as Map<String, dynamic>; } catch (_) {}
      } else if (hintsRaw is Map) {
        _hints = hintsRaw.cast<String, dynamic>();
      }
      // Load MC options
      if (_questionType == 'multiple_choice') {
        final optsRaw = d['options'];
        List<String> opts = [];
        if (optsRaw is String && optsRaw.isNotEmpty) {
          try { opts = (jsonDecode(optsRaw) as List).cast<String>(); } catch (_) {}
        } else if (optsRaw is List) {
          opts = optsRaw.cast<String>();
        }
        for (final o in opts) {
          _optionControllers.add(TextEditingController(text: o));
        }
      }
    }
    // Ensure at least 2 MC option fields
    while (_questionType == 'multiple_choice' && _optionControllers.length < 2) {
      _optionControllers.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    for (final c in _optionControllers) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _mcOptions =>
      _optionControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();

  List<String> get _effectiveOptions =>
      _questionType == 'true_false' ? _tfOptions : _mcOptions;

  String _letterForIndex(int i) => String.fromCharCode(65 + i);

  void _setType(String type) {
    setState(() {
      _questionType = type;
      _correctAnswer = null;
      _hints = null;
      if (type == 'multiple_choice' && _optionControllers.length < 2) {
        while (_optionControllers.length < 2) {
          _optionControllers.add(TextEditingController());
        }
      }
    });
  }

  Future<void> _generateHints() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the question text first.')));
      return;
    }
    final providerStr = await _storage.read(key: 'AI_PROVIDER');
    final apiKey = await _storage.read(key: 'AI_API_KEY') ?? '';
    final provider = AiProvider.values.firstWhere(
        (p) => p.name == providerStr, orElse: () => AiProvider.none);

    if (provider == AiProvider.none) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Configure an AI provider in Settings first.'),
          ),
        );
      }
      return;
    }

    setState(() => _generatingHints = true);

    final result = await AiHintService.generateHints(
      questionText: text,
      questionType: _questionType,
      options: _effectiveOptions,
      correctAnswer: _correctAnswer,
      provider: provider,
      apiKey: apiKey,
    );

    if (mounted) {
      setState(() {
        _generatingHints = false;
        if (result != null) {
          _hints = result;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Hints generated!'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('AI generation failed. Check your API key in Settings.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      });
    }
  }

  void _save() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Question text cannot be empty.')));
      return;
    }
    if (_questionType == 'multiple_choice') {
      if (_mcOptions.length < 2) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter at least 2 options.')));
        return;
      }
      if (_correctAnswer == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mark the correct answer.')));
        return;
      }
    }
    if (_questionType == 'true_false' && _correctAnswer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select True or False as the correct answer.')));
      return;
    }

    final id = widget.initial?['id'] as String? ?? const Uuid().v4();
    final optionsStr = _questionType == 'multiple_choice'
        ? jsonEncode(_mcOptions)
        : _questionType == 'true_false'
            ? jsonEncode(_tfOptions)
            : null;
    final hintsStr = _hints != null ? jsonEncode(_hints) : null;

    Navigator.of(context).pop({
      'id': id,
      'question_text': text,
      'question_type': _questionType,
      'options': optionsStr,
      'correct_answer': _correctAnswer,
      'hints': hintsStr,
      'points': _points,
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Text(
                      widget.initial == null ? 'New Question' : 'Edit Question',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                    const Spacer(),
                    TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel')),
                    const SizedBox(width: 4),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E3A8A),
                          foregroundColor: Colors.white),
                      onPressed: _save,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Question type selector
                      _buildTypeSelector(),
                      const SizedBox(height: 16),
                      // Question text
                      TextField(
                        controller: _textController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Question',
                          hintText: 'Enter your question here...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Options (MC or TF)
                      if (_questionType == 'multiple_choice')
                        _buildMcOptions(),
                      if (_questionType == 'true_false')
                        _buildTfOptions(),
                      if (_questionType == 'short_answer')
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Students will type their answer. '
                            'Short answer questions are not auto-scored.',
                            style:
                                TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ),
                      const SizedBox(height: 8),
                      // Points
                      Row(
                        children: [
                          const Text('Points:',
                              style: TextStyle(fontWeight: FontWeight.w500)),
                          const SizedBox(width: 12),
                          DropdownButton<int>(
                            value: _points,
                            items: [1, 2, 3, 5].map((v) => DropdownMenuItem(
                              value: v,
                              child: Text('$v'),
                            )).toList(),
                            onChanged: (v) =>
                                setState(() => _points = v ?? 1),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Generate hints button
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed:
                                  _generatingHints ? null : _generateHints,
                              icon: _generatingHints
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.auto_awesome_outlined,
                                      size: 18),
                              label: Text(_generatingHints
                                  ? 'Generating…'
                                  : _hints != null
                                      ? 'Regenerate Hints'
                                      : 'Generate AI Hints'),
                            ),
                          ),
                        ],
                      ),
                      if (_hints != null) ...[
                        const SizedBox(height: 8),
                        _buildHintsPreview(),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypeSelector() {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(
            value: 'multiple_choice',
            label: Text('Multiple Choice'),
            icon: Icon(Icons.radio_button_checked, size: 16)),
        ButtonSegment(
            value: 'true_false',
            label: Text('True/False'),
            icon: Icon(Icons.toggle_on, size: 16)),
        ButtonSegment(
            value: 'short_answer',
            label: Text('Short Answer'),
            icon: Icon(Icons.short_text, size: 16)),
      ],
      selected: {_questionType},
      onSelectionChanged: (s) => _setType(s.first),
    );
  }

  Widget _buildMcOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Options',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        const SizedBox(height: 8),
        ...List.generate(_optionControllers.length, (i) {
          final letter = _letterForIndex(i);
          final isCorrect = _correctAnswer == letter;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => setState(() => _correctAnswer = letter),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor:
                        isCorrect ? Colors.green : Colors.grey.shade200,
                    child: Text(
                      letter,
                      style: TextStyle(
                          color: isCorrect ? Colors.white : Colors.black87,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _optionControllers[i],
                    decoration: InputDecoration(
                      hintText: 'Option $letter',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                if (_optionControllers.length > 2)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: Colors.red, size: 20),
                    onPressed: () => setState(() {
                      _optionControllers.removeAt(i);
                      if (_correctAnswer == letter) _correctAnswer = null;
                    }),
                  ),
              ],
            ),
          );
        }),
        if (_optionControllers.length < 6)
          TextButton.icon(
            onPressed: () => setState(
                () => _optionControllers.add(TextEditingController())),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Option'),
          ),
        if (_correctAnswer == null)
          const Text(
            'Tap a letter circle to mark the correct answer.',
            style: TextStyle(color: Colors.orange, fontSize: 12),
          ),
      ],
    );
  }

  Widget _buildTfOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Correct Answer',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        const SizedBox(height: 8),
        Row(
          children: _tfOptions.map((opt) {
            final isCorrect = _correctAnswer == opt;
            return Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ChoiceChip(
                label: Text(opt),
                selected: isCorrect,
                selectedColor: Colors.green.shade100,
                onSelected: (_) =>
                    setState(() => _correctAnswer = opt),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildHintsPreview() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.auto_awesome, size: 14, color: Colors.blue),
              SizedBox(width: 4),
              Text('AI Hints Preview',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.blue)),
            ],
          ),
          const SizedBox(height: 6),
          ..._hints!.entries.map((e) {
            final val = e.value;
            final explanation =
                val is Map ? val['explanation'] as String? ?? '' : val.toString();
            final verdict = val is Map ? val['verdict'] as String? : null;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    verdict == 'correct' ? Icons.check_circle : Icons.cancel,
                    size: 14,
                    color:
                        verdict == 'correct' ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${e.key}: $explanation',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
