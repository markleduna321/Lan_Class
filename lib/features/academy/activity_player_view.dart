// lib/features/academy/activity_player_view.dart
//
// Runs a single lesson activity: fill_blank, code_write, or quiz.
// Pops `true` once the server marks the submission as passed.

import 'package:flutter/material.dart';
import '../../services/course_api_service.dart';
import 'course_models.dart';

const _kBrand = Color(0xFF1E3A8A);

class ActivityPlayerView extends StatefulWidget {
  final CourseActivity activity;

  const ActivityPlayerView({super.key, required this.activity});

  @override
  State<ActivityPlayerView> createState() => _ActivityPlayerViewState();
}

class _ActivityPlayerViewState extends State<ActivityPlayerView> {
  late final List<TextEditingController> _blankControllers;
  late final TextEditingController _codeController;
  final Map<int, String> _quizAnswers = {};

  bool _loading = true;
  bool _submitting = false;
  ActivitySubmission? _submission;

  @override
  void initState() {
    super.initState();
    final activity = widget.activity;
    _blankControllers = List.generate(
      activity.blanksCount,
      (_) => TextEditingController(),
    );
    _codeController = TextEditingController(text: activity.starterCode);
    _restorePriorAttempt();
  }

  @override
  void dispose() {
    for (final c in _blankControllers) {
      c.dispose();
    }
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _restorePriorAttempt() async {
    final submission =
        await CourseApiService.fetchActivitySubmission(widget.activity.id);
    if (!mounted) return;
    setState(() {
      _submission = submission;
      _loading = false;
    });
  }

  bool get _passed => _submission?.passed ?? widget.activity.isPassed;

  bool get _canSubmit {
    if (_submitting || _passed) return false;
    switch (widget.activity.type) {
      case 'fill_blank':
        return _blankControllers.every((c) => c.text.trim().isNotEmpty);
      case 'code_write':
        return _codeController.text.trim().isNotEmpty;
      case 'quiz':
        return _quizAnswers.length == widget.activity.questions.length;
      default:
        return false;
    }
  }

  Map<String, dynamic> _buildBody() {
    final activity = widget.activity;
    switch (activity.type) {
      case 'fill_blank':
        return {
          'answers': _blankControllers.map((c) => c.text.trim()).toList(),
        };
      case 'code_write':
        return {'code': _codeController.text};
      case 'quiz':
        return {
          'answers': List.generate(
            activity.questions.length,
            (i) => _quizAnswers[i] ?? '',
          ),
        };
      default:
        return const {};
    }
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final result = await CourseApiService.submitActivity(
      activityId: widget.activity.id,
      body: _buildBody(),
    );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (result.submission != null) _submission = result.submission;
    });

    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error), backgroundColor: Colors.red),
      );
      return;
    }

    if (result.submission == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Submission received. Refreshing your result…'),
          backgroundColor: Colors.blue,
        ),
      );
    } else if (_passed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Activity passed.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final activity = widget.activity;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _passed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(activity.typeLabel,
              style: const TextStyle(fontSize: 15)),
          backgroundColor: _kBrand,
          foregroundColor: Colors.white,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 110),
                children: [
                  Text(activity.title,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.bold)),
                  if (activity.instructions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(activity.instructions,
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: Colors.grey.shade700)),
                  ],
                  const SizedBox(height: 20),
                  if (_submission != null) _buildFeedback(_submission!),
                  ..._buildActivityBody(activity),
                ],
              ),
        bottomNavigationBar: _loading
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _passed ? Colors.green : _kBrand,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _passed
                        ? () => Navigator.pop(context, true)
                        : (_canSubmit ? _submit : null),
                    icon: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : Icon(_passed ? Icons.check_circle : Icons.send),
                    label: Text(_passed
                        ? 'Passed — go back'
                        : (_submitting ? 'Checking…' : 'Submit answer')),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildFeedback(ActivitySubmission submission) {
    final passed = submission.passed;
    final color = passed ? Colors.green : Colors.orange;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(passed ? Icons.check_circle : Icons.info_outline,
              color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(passed ? 'Passed' : 'Not passed yet',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: color)),
                if (submission.feedback.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(submission.feedback,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActivityBody(CourseActivity activity) {
    switch (activity.type) {
      case 'fill_blank':
        return _buildFillBlank(activity);
      case 'code_write':
        return _buildCodeWrite(activity);
      case 'quiz':
        return _buildQuiz(activity);
      default:
        return [
          Text('This activity type is not supported in the app yet.',
              style: TextStyle(color: Colors.grey.shade600)),
        ];
    }
  }

  List<Widget> _buildFillBlank(CourseActivity activity) {
    return List.generate(activity.blanksCount, (i) {
      final hint = i < activity.blanksHints.length ? activity.blanksHints[i] : null;
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: _blankControllers[i],
          enabled: !_passed,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Blank ${i + 1}',
            hintText: hint,
            helperText: hint == null ? null : 'Hint: $hint',
            border: const OutlineInputBorder(),
          ),
        ),
      );
    });
  }

  List<Widget> _buildCodeWrite(CourseActivity activity) {
    return [
      if (activity.language.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Chip(
            label: Text(activity.language,
                style: const TextStyle(fontSize: 11)),
            backgroundColor: _kBrand.withValues(alpha: 0.08),
          ),
        ),
      TextField(
        controller: _codeController,
        enabled: !_passed,
        maxLines: 12,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
      ),
      if (activity.testCases.isNotEmpty) ...[
        const SizedBox(height: 20),
        Text('Test cases',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        ...activity.testCases.map(
          (t) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'input: ${t.input}   →   expected: ${t.expected}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ],
    ];
  }

  List<Widget> _buildQuiz(CourseActivity activity) {
    return List.generate(activity.questions.length, (i) {
      final question = activity.questions[i];
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${i + 1}. ${question.text}',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ...question.choices.map((choice) {
              final selected = _quizAnswers[i] == choice;
              return GestureDetector(
                onTap: _passed
                    ? null
                    : () => setState(() => _quizAnswers[i] = choice),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: selected
                        ? _kBrand.withValues(alpha: 0.08)
                        : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected ? _kBrand : Colors.grey.shade300,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                        color: selected ? _kBrand : Colors.grey,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(choice)),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      );
    });
  }
}
