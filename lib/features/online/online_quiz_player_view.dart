// lib/features/online/online_quiz_player_view.dart
//
// Phase 6 — Online Quiz Player
// Like QuizPlayerView but submits answers via the Laravel REST API
// (POST /api/sessions/{id}/quiz/submit) instead of the LAN HTTP server.
// Listens to OnlineSessionService.eventStream for QUIZ_ENDED (auto-submit).
// Saves results locally using 'online:{classroomRemoteId}' as the host key.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../database/asura_repository.dart';
import '../../services/cloud_api_service.dart';
import '../../services/online_session_service.dart';
import '../quiz/quiz_submission_result.dart';

class OnlineQuizPlayerView extends StatefulWidget {
  final String sessionId;
  final String classroomRemoteId;
  final String studentId;
  final String studentName;

  /// Same structure as QuizPlayerView:
  /// { quiz_id, title, questions: [{id, question_text|text, type, options?, correct_answer}] }
  final Map<String, dynamic> quizData;

  const OnlineQuizPlayerView({
    super.key,
    required this.sessionId,
    required this.classroomRemoteId,
    required this.studentId,
    required this.studentName,
    required this.quizData,
  });

  @override
  State<OnlineQuizPlayerView> createState() => _OnlineQuizPlayerViewState();
}

class _OnlineQuizPlayerViewState extends State<OnlineQuizPlayerView> {
  late final List<Map<String, dynamic>> _questions;
  final Map<String, String?> _answers = {}; // question_id → answer
  int  _currentIndex = 0;
  bool _submitted    = false;
  bool _submitting   = false;
  Map<String, dynamic>? _serverResult;
  String? _errorMessage;

  StreamSubscription<Map<String, dynamic>>? _eventSub;

  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    final raw = widget.quizData['questions'];
    _questions = raw is List ? raw.cast<Map<String, dynamic>>() : [];

    // Listen for QUIZ_ENDED from Reverb WS
    _eventSub = OnlineSessionService.instance.eventStream.listen((event) {
      if (event['event'] == 'QUIZ_ENDED' && !_submitted && mounted) {
        _autoSubmitAndExit();
      }
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Auto-submit on QUIZ_ENDED
  // ---------------------------------------------------------------------------

  Future<void> _autoSubmitAndExit() async {
    if (_submitted || _submitting) return;
    setState(() => _submitting = true);

    final answers = _questions
        .map((q) => {'question_id': q['id'], 'answer': _answers[q['id']] ?? ''})
        .toList();

    try {
      final response = await CloudApiService.post(
        '/api/sessions/${widget.sessionId}/quiz/submit',
        _buildSubmissionPayload(answers),
      );
      if (response != null && (response.statusCode == 200 || response.statusCode == 201)) {
        final parsed = resolveQuizSubmissionResult(
          responseBody: response.body,
          questions: _questions,
          answers: answers,
        );
        await _saveResultLocally(parsed);
      } else {
        await _saveResultLocally({'score': 0, 'scorable_total': 0, 'results': []});
      }
    } catch (_) {
      await _saveResultLocally({'score': 0, 'scorable_total': 0, 'results': []});
    }

    if (mounted) Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------------------
  // Manual submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (!_allAnswered) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please answer all questions before submitting.'),
      ));
      return;
    }

    setState(() {
      _submitting  = true;
      _errorMessage = null;
    });

    final answers = _questions
        .map((q) => {'question_id': q['id'], 'answer': _answers[q['id']] ?? ''})
        .toList();

    try {
      final response = await CloudApiService.post(
        '/api/sessions/${widget.sessionId}/quiz/submit',
        _buildSubmissionPayload(answers),
      );

      if (!mounted) return;

      if (response != null && (response.statusCode == 200 || response.statusCode == 201)) {
        final result = resolveQuizSubmissionResult(
          responseBody: response.body,
          questions: _questions,
          answers: answers,
        );
        await _saveResultLocally(result);
        setState(() {
          _submitted    = true;
          _submitting   = false;
          _serverResult = result;
        });
      } else {
        setState(() {
          _submitting  = false;
          _errorMessage = 'Server error: ${response?.statusCode ?? 'no response'}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting  = false;
          _errorMessage = 'Could not reach the server. Check your internet connection.';
        });
      }
    }
  }

  /// Carries both the documented (`student_id`/`answers`) and the legacy
  /// (`user_id`/`responses`) field names so either backend build accepts it.
  Map<String, dynamic> _buildSubmissionPayload(
      List<Map<String, dynamic>> answers) {
    return {
      'quiz_id':      widget.quizData['quiz_id'],
      'quiz_title':   widget.quizData['title'] ?? 'Quiz',
      'student_id':   widget.studentId,
      'student_name': widget.studentName,
      'user_id':      widget.studentId,
      'user_name':    widget.studentName,
      'answers':      answers,
      'responses':    answers
          .map((a) => {
                'question_id': a['question_id'],
                'answer': a['answer'],
                'response': a['answer'],
              })
          .toList(),
    };
  }

  // ---------------------------------------------------------------------------
  // Save results locally (same structure as QuizPlayerView)
  // ---------------------------------------------------------------------------

  Future<void> _saveResultLocally(Map<String, dynamic> serverResult) async {
    final score  = serverResult['score']         as int? ?? 0;
    final total  = serverResult['scorable_total'] as int? ?? 0;
    final raw    = serverResult['results']        as List? ?? [];
    final results = raw.cast<Map<String, dynamic>>();

    final enriched = results.map((r) {
      final qId = r['question_id'] as String? ?? '';
      Map<String, dynamic> question = {};
      for (final q in _questions) {
        if ((q['id'] as String?) == qId) {
          question = q;
          break;
        }
      }
      return <String, dynamic>{
        ...r,
        'question_text': question['question_text'] as String? ??
            question['text']         as String? ?? '',
      };
    }).toList();

    await AsuraRepository.insertStudentQuizResult({
      'id':              const Uuid().v4(),
      'host_ip':         'online:${widget.classroomRemoteId}',
      'classroom_id':    widget.classroomRemoteId,
      'quiz_id':         widget.quizData['quiz_id'] as String? ?? '',
      'quiz_title':      widget.quizData['title']   as String? ?? 'Quiz',
      'score':           score,
      'scorable_total':  total,
      'total_questions': _questions.length,
      'taken_at':        DateTime.now().toIso8601String(),
      'answers_json':    jsonEncode(enriched),
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic> get _currentQuestion => _questions[_currentIndex];

  bool get _currentAnswered =>
      _answers[_currentQuestion['id']] != null;

  bool get _allAnswered =>
      _questions.every((q) => _answers[q['id']] != null);

  void _selectAnswer(String answer) =>
      setState(() => _answers[_currentQuestion['id']] = answer);

  void _next() {
    if (_currentIndex < _questions.length - 1) {
      setState(() => _currentIndex++);
    }
  }

  void _prev() {
    if (_currentIndex > 0) setState(() => _currentIndex--);
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.quizData['title'] as String? ?? 'Quiz'),
          backgroundColor: const Color(0xFF1E3A8A),
          foregroundColor: Colors.white,
        ),
        body: const Center(child: Text('No questions in this quiz.')),
      );
    }
    if (_submitted && _serverResult != null) return _buildResultsScreen();
    return _buildQuizScreen();
  }

  // ---------------------------------------------------------------------------

  Widget _buildQuizScreen() {
    final q    = _currentQuestion;
    final type = q['type'] as String? ?? 'multiple_choice';
    final opts = (q['options'] as List?)?.cast<String>() ?? [];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.quizData['title'] as String? ?? 'Quiz',
            style: const TextStyle(fontSize: 15)),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_currentIndex + 1) / _questions.length,
            backgroundColor: Colors.white24,
            color: Colors.amber,
          ),
        ),
      ),
      body: Column(
        children: [
          // Question counter
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Text(
                  'Question ${_currentIndex + 1} of ${_questions.length}',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '${_answers.values.where((v) => v != null).length}/${_questions.length} answered',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),

          // Question card
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A8A).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: const Color(0xFF1E3A8A).withValues(alpha: 0.25)),
                    ),
                    child: Text(
                      q['question_text'] as String? ??
                          q['text']          as String? ?? '',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (type == 'identification') ...[
                    TextField(
                      onChanged: _selectAnswer,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Your answer',
                        hintText: 'Type your answer here',
                      ),
                    ),
                  ] else if (type == 'true_false') ...[
                    _buildOptionTile('True'),
                    const SizedBox(height: 8),
                    _buildOptionTile('False'),
                  ] else ...[
                    ...opts.map((opt) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _buildOptionTile(opt),
                        )),
                  ],

                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(_errorMessage!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),

          // Navigation + Submit
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (_currentIndex > 0)
                    OutlinedButton.icon(
                      onPressed: _prev,
                      icon: const Icon(Icons.arrow_back, size: 16),
                      label: const Text('Back'),
                    ),
                  const Spacer(),
                  if (_currentIndex < _questions.length - 1)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E3A8A),
                          foregroundColor: Colors.white),
                      onPressed: _currentAnswered ? _next : null,
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: const Text('Next'),
                    )
                  else
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade600,
                          foregroundColor: Colors.white),
                      onPressed: _submitting ? null : _submit,
                      icon: _submitting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.check, size: 16),
                      label: Text(_submitting ? 'Submitting…' : 'Submit'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionTile(String option) {
    final selected = _answers[_currentQuestion['id']] == option;
    return GestureDetector(
      onTap: () => _selectAnswer(option),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF1E3A8A).withValues(alpha: 0.1)
              : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF1E3A8A) : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? const Color(0xFF1E3A8A) : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(option,
                  style: TextStyle(
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.normal)),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Results screen
  // ---------------------------------------------------------------------------

  Widget _buildResultsScreen() {
    final score  = _serverResult!['score']          as int? ?? 0;
    final total  = _serverResult!['scorable_total']  as int? ?? 0;
    final pct    = total > 0 ? score / total : 0.0;
    final results = (_serverResult!['results'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        [];

    // Online quizzes ship without an answer key, so there is nothing to score against.
    final unscored = total == 0;

    Color scoreColor;
    String grade;
    if (unscored) { scoreColor = const Color(0xFF1E3A8A); grade = 'Answers Submitted'; }
    else if (pct >= 0.9) { scoreColor = Colors.green; grade = 'Excellent!'; }
    else if (pct >= 0.75) { scoreColor = Colors.green.shade600; grade = 'Good Job!'; }
    else if (pct >= 0.5) { scoreColor = Colors.orange; grade = 'Keep Practicing'; }
    else { scoreColor = Colors.red; grade = 'Needs Improvement'; }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quiz Results'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Score card
            Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(grade,
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: scoreColor)),
                    const SizedBox(height: 12),
                    if (unscored) ...[
                      Icon(Icons.cloud_done, size: 44, color: scoreColor),
                      const SizedBox(height: 8),
                      Text(
                        '${_questions.length} answer(s) sent to your teacher.\n'
                        'Your score will be released after review.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ] else ...[
                      Text('$score / $total',
                          style: TextStyle(
                              fontSize: 40,
                              fontWeight: FontWeight.bold,
                              color: scoreColor)),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: pct.clamp(0.0, 1.0),
                        backgroundColor: Colors.grey.shade200,
                        color: scoreColor,
                        minHeight: 8,
                      ),
                      const SizedBox(height: 4),
                      Text('${(pct * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 13)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Per-question breakdown
            ...results.map((r) {
              final isCorrect = r['is_correct'] as bool? ?? false;
              final questionText = r['question_text'] as String? ??
                  r['question'] as String? ?? '';
              final yourAnswer    = r['your_answer']    as String? ?? '';
              final correctAnswer = r['correct_answer'] as String? ?? '';

              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isCorrect
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    radius: 18,
                    child: Icon(
                      isCorrect ? Icons.check : Icons.close,
                      color: isCorrect ? Colors.green : Colors.red,
                      size: 18,
                    ),
                  ),
                  title: Text(questionText,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your answer: $yourAnswer',
                          style: TextStyle(
                              color: isCorrect ? Colors.green : Colors.red,
                              fontSize: 12)),
                      if (!isCorrect)
                        Text('Correct: $correctAnswer',
                            style: const TextStyle(
                                color: Colors.green, fontSize: 12)),
                    ],
                  ),
                  isThreeLine: !isCorrect,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
