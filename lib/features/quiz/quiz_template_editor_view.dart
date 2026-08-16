// lib/features/quiz/quiz_template_editor_view.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import '../../database/asura_repository.dart';
import 'quiz_question_editor_dialog.dart';

class QuizTemplateEditorView extends StatefulWidget {
  final String templateId;

  const QuizTemplateEditorView({super.key, required this.templateId});

  @override
  State<QuizTemplateEditorView> createState() =>
      _QuizTemplateEditorViewState();
}

class _QuizTemplateEditorViewState extends State<QuizTemplateEditorView> {
  Map<String, dynamic>? _template;
  List<Map<String, dynamic>> _questions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final templates = await AsuraRepository.getAllQuizTemplates();
    final tpl = templates.firstWhere(
      (t) => t['id'] == widget.templateId,
      orElse: () => {},
    );
    final qs = await AsuraRepository.getTemplateQuestions(widget.templateId);
    if (mounted) {
      setState(() {
        _template = tpl.isEmpty ? null : tpl;
        _questions = qs;
        _loading = false;
      });
    }
  }

  Future<void> _addQuestion() async {
    final result = await QuizQuestionEditorDialog.show(context);
    if (result != null) {
      final q = Map<String, dynamic>.from(result);
      q['template_id'] = widget.templateId;
      q['order_index'] = _questions.length;
      await AsuraRepository.insertTemplateQuestion(q);
      await _load();
    }
  }

  Future<void> _editQuestion(Map<String, dynamic> question) async {
    final result = await QuizQuestionEditorDialog.show(context, initial: question);
    if (result != null) {
      await AsuraRepository.updateTemplateQuestion(question['id'] as String, result);
      await _load();
    }
  }

  Future<void> _deleteQuestion(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Question?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      await AsuraRepository.deleteTemplateQuestion(id);
      await _load();
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final item = _questions.removeAt(oldIndex);
    _questions.insert(newIndex, item);
    setState(() {});
    // Persist new order
    for (int i = 0; i < _questions.length; i++) {
      await AsuraRepository.updateTemplateQuestion(
        _questions[i]['id'] as String,
        {'order_index': i},
      );
    }
  }

  String _typeLabel(String type) => switch (type) {
        'multiple_choice' => 'MC',
        'true_false' => 'T/F',
        'short_answer' => 'SA',
        _ => type,
      };

  Color _typeColor(String type) => switch (type) {
        'multiple_choice' => Colors.blue,
        'true_false' => Colors.green,
        'short_answer' => Colors.orange,
        _ => Colors.grey,
      };

  List<String> _parseOptions(dynamic raw) {
    if (raw is String && raw.isNotEmpty) {
      try { return (jsonDecode(raw) as List).cast<String>(); } catch (_) {}
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Loading…')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_template == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Template not found')),
        body: const Center(child: Text('Template not found.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_template!['title'] as String,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text('${_questions.length} question${_questions.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Question'),
        onPressed: _addQuestion,
      ),
      body: _questions.isEmpty
          ? const Center(
              child: Text(
                'No questions yet.\nTap "Add Question" to get started.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ReorderableListView.builder(
              padding:
                  const EdgeInsets.only(left: 12, right: 12, top: 12, bottom: 80),
              onReorderItem: _reorder,
              itemCount: _questions.length,
              itemBuilder: (ctx, i) {
                final q = _questions[i];
                final type = q['question_type'] as String? ?? 'multiple_choice';
                final opts = _parseOptions(q['options']);
                final correct = q['correct_answer'] as String?;
                return Card(
                  key: ValueKey(q['id']),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: _typeColor(type).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _typeLabel(type),
                            style: TextStyle(
                                color: _typeColor(type),
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    title: Text(
                      '${i + 1}. ${q['question_text']}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (opts.isNotEmpty)
                          Text(
                            opts.asMap().entries.map((e) {
                              final letter = String.fromCharCode(65 + e.key);
                              final isCorrect = type == 'multiple_choice'
                                  ? correct == letter
                                  : correct == e.value;
                              return '${isCorrect ? '✓' : ' '} $letter. ${e.value}';
                            }).join('  '),
                            style: const TextStyle(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (correct != null && type == 'true_false')
                          Text('Answer: $correct',
                              style: const TextStyle(
                                  color: Colors.green, fontSize: 11)),
                        if (q['hints'] != null)
                          Row(
                            children: const [
                              Icon(Icons.auto_awesome,
                                  size: 11, color: Colors.blue),
                              SizedBox(width: 3),
                              Text('AI hints ready',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.blue)),
                            ],
                          ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _editQuestion(q),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 20, color: Colors.red),
                          onPressed: () =>
                              _deleteQuestion(q['id'] as String),
                        ),
                        const Icon(Icons.drag_handle, color: Colors.grey),
                      ],
                    ),
                    isThreeLine: true,
                  ),
                );
              },
            ),
    );
  }
}
