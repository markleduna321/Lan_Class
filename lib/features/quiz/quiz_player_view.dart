// lib/features/quiz/quiz_player_view.dart
//
// Student-facing quiz screen. Receives quiz data from the lobby on QUIZ_START.
// Submits answers via HTTP POST to the teacher's server.
// Listens for QUIZ_ENDED via WS — auto-submits partial answers and pops.
// Saves results locally so the lobby Quiz Results tab can show history.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../database/asura_repository.dart';
import 'quiz_submission_result.dart';

class QuizPlayerView extends StatefulWidget {
  final String hostIp;
  final int port;
  final String studentName;
  final String classroomId;
  final Map<String, dynamic> quizData; // {quiz_id, title, questions:[...]}

  const QuizPlayerView({
    super.key,
    required this.hostIp,
    required this.port,
    required this.studentName,
    required this.classroomId,
    required this.quizData,
  });

  @override
  State<QuizPlayerView> createState() => _QuizPlayerViewState();
}

class _QuizPlayerViewState extends State<QuizPlayerView> {
  late final List<Map<String, dynamic>> _questions;
  final Map<String, String?> _answers = {}; // question_id → answer
  int _currentIndex = 0;
  bool _submitted = false;
  bool _submitting = false;
  Map<String, dynamic>? _serverResult;
  String? _errorMessage;
  WebSocketChannel? _quizWs;

  @override
  void initState() {
    super.initState();
    final raw = widget.quizData['questions'];
    if (raw is List) {
      _questions = raw.cast<Map<String, dynamic>>();
    } else {
      _questions = [];
    }
    _listenForQuizEnd();
  }

  @override
  void dispose() {
    try { _quizWs?.sink.close(); } catch (_) {}
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // WS listener — only used to receive QUIZ_ENDED from teacher
  // ---------------------------------------------------------------------------

  void _listenForQuizEnd() {
    try {
      _quizWs = WebSocketChannel.connect(
          Uri.parse('ws://${widget.hostIp}:${widget.port}'));
      _quizWs!.stream.listen(
        (raw) {
          try {
            final data = jsonDecode(raw as String) as Map<String, dynamic>;
            if (data['event'] == 'QUIZ_ENDED' && !_submitted && mounted) {
              _autoSubmitAndExit();
            }
          } catch (_) {}
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Auto-submit when teacher ends quiz (partial answers, unanswered = wrong)
  // ---------------------------------------------------------------------------

  Future<void> _autoSubmitAndExit() async {
    if (_submitted || _submitting) return;
    setState(() => _submitting = true);

    try { await _quizWs?.sink.close(); } catch (_) {}
    _quizWs = null;

    final answers = _questions.map((q) => {
          'question_id': q['id'],
          'answer': _answers[q['id']] ?? '',
        }).toList();

    try {
      final response = await http
          .post(
            Uri.parse(
                'http://${widget.hostIp}:${widget.port}/quiz-submit'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'quiz_id': widget.quizData['quiz_id'],
              'student_name': widget.studentName,
              'answers': answers,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final parsed = resolveQuizSubmissionResult(
          responseBody: response.body,
          questions: _questions,
          answers: answers,
        );
        await _saveResultLocally(parsed);
      } else {
        await _saveResultLocally(
            {'score': 0, 'scorable_total': 0, 'results': []});
      }
    } catch (_) {
      await _saveResultLocally(
          {'score': 0, 'scorable_total': 0, 'results': []});
    }

    if (mounted) Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _saveResultLocally(Map<String, dynamic> serverResult) async {
    final score = serverResult['score'] as int? ?? 0;
    final total = serverResult['scorable_total'] as int? ?? 0;
    final results =
        (serverResult['results'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final enriched = results.map((r) {
      final qId = r['question_id'] as String? ?? '';
      Map<String, dynamic> question = {};
      for (final q in _questions) {
        if ((q['id'] as String?) == qId) { question = q; break; }
      }
      return <String, dynamic>{
        ...r,
        'question_text': question['question_text'] as String? ??
            question['text'] as String? ?? '',
      };
    }).toList();

    await AsuraRepository.insertStudentQuizResult({
      'id': const Uuid().v4(),
      'host_ip': widget.hostIp,
      'classroom_id': widget.classroomId,
      'quiz_id': widget.quizData['quiz_id'] as String? ?? '',
      'quiz_title': widget.quizData['title'] as String? ?? 'Quiz',
      'score': score,
      'scorable_total': total,
      'total_questions': _questions.length,
      'taken_at': DateTime.now().toIso8601String(),
      'answers_json': jsonEncode(enriched),
    });
  }

  Map<String, dynamic> get _currentQuestion => _questions[_currentIndex];

  bool get _currentAnswered =>
      _answers[_currentQuestion['id']] != null;

  bool get _allAnswered =>
      _questions.every((q) => _answers[q['id']] != null);

  void _selectAnswer(String answer) {
    setState(() {
      _answers[_currentQuestion['id']] = answer;
    });
  }

  void _nextQuestion() {
    if (_currentIndex < _questions.length - 1) {
      setState(() => _currentIndex++);
    }
  }

  void _prevQuestion() {
    if (_currentIndex > 0) {
      setState(() => _currentIndex--);
    }
  }

  Future<void> _submit() async {
    if (!_allAnswered) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Please answer all questions before submitting.'),
        ),
      );
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    // Close the quiz-end listener WS before submitting
    try { await _quizWs?.sink.close(); } catch (_) {}
    _quizWs = null;

    final answers = _questions.map((q) => {
          'question_id': q['id'],
          'answer': _answers[q['id']] ?? '',
        }).toList();

    try {
      final response = await http
          .post(
            Uri.parse(
                'http://${widget.hostIp}:${widget.port}/quiz-submit'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'quiz_id': widget.quizData['quiz_id'],
              'student_name': widget.studentName,
              'answers': answers,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final result = resolveQuizSubmissionResult(
          responseBody: response.body,
          questions: _questions,
          answers: answers,
        );
        await _saveResultLocally(result);
        setState(() {
          _submitted = true;
          _submitting = false;
          _serverResult = result;
        });
      } else {
        setState(() {
          _submitting = false;
          _errorMessage = 'Server error: ${response.statusCode}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorMessage = 'Could not reach the teacher\'s device. '
              'Make sure you are on the same network.';
        });
      }
    }
  }

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
    if (_submitted && _serverResult != null) {
      return _buildResultsScreen();
    }
    return _buildQuizScreen();
  }

  Widget _buildQuizScreen() {
    final q = _currentQuestion;
    final type = q['type'] as String? ?? 'multiple_choice';
    final rawOptions = q['options'];
    List<String> options = [];
    if (rawOptions is List) {
      options = rawOptions.cast<String>();
    }

    final totalQuestions = _questions.length;
    final answered = _answers.values.where((v) => v != null).length;
    final progress = (answered / totalQuestions).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.quizData['title'] as String? ?? 'Quiz'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(6),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.white30,
            valueColor:
                const AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
      ),
      body: Column(
        children: [
          // Question number navigation dots
          Container(
            color: const Color(0xFF1E3A8A).withValues(alpha: 0.05),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  'Q${_currentIndex + 1} / $totalQuestions',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E3A8A)),
                ),
                const Spacer(),
                ...List.generate(totalQuestions, (i) {
                  final isAnswered =
                      _answers[_questions[i]['id']] != null;
                  final isCurrent = i == _currentIndex;
                  return GestureDetector(
                    onTap: () => setState(() => _currentIndex = i),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isCurrent
                            ? const Color(0xFF1E3A8A)
                            : isAnswered
                                ? Colors.green
                                : Colors.grey.shade300,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Question text
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A8A).withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      q['question_text'] as String? ??
                          q['text'] as String? ?? '',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Answer options
                  if (type == 'multiple_choice' || type == 'true_false')
                    ...List.generate(options.length, (i) {
                      final letter = String.fromCharCode(65 + i);
                      final isSelected = _answers[q['id']] == letter;
                      return _OptionTile(
                        letter: letter,
                        text: options[i],
                        selected: isSelected,
                        onTap: () => _selectAnswer(letter),
                      );
                    }),

                  if (type == 'short_answer')
                    TextField(
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Type your answer here…',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) => setState(
                          () => _answers[q['id']] = val),
                      controller: TextEditingController(
                          text: _answers[q['id']] ?? ''),
                    ),

                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(_errorMessage!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),

          // Navigation footer
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (_currentIndex > 0)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                      onPressed: _prevQuestion,
                    ),
                  const Spacer(),
                  if (_currentIndex < _questions.length - 1)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E3A8A),
                          foregroundColor: Colors.white),
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Next'),
                      onPressed: _currentAnswered ? _nextQuestion : null,
                    )
                  else
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white),
                      icon: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.send),
                      label: Text(_submitting ? 'Submitting…' : 'Submit'),
                      onPressed: (_submitting || !_allAnswered)
                          ? null
                          : _submit,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsScreen() {
    final result = _serverResult!;
    final score = result['score'] as int? ?? 0;
    final total = result['scorable_total'] as int? ?? 0;
    final results = (result['results'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        [];

    final pct =
        total > 0 ? ((score / total) * 100).toStringAsFixed(0) : '--';
    final color = total > 0 && score / total >= 0.7
        ? Colors.green
        : total > 0 && score / total >= 0.4
            ? Colors.orange
            : Colors.red;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.quizData['title'] as String? ?? 'Results'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Score card
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: 0.8),
                  color.withValues(alpha: 0.5)
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Text(
                  total > 0 ? '$score / $total' : '${_questions.length} answered',
                  style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
                if (total > 0) ...[
                  Text('$pct% correct',
                      style: const TextStyle(
                          fontSize: 20, color: Colors.white70)),
                ],
                const SizedBox(height: 8),
                Text(
                  total > 0
                      ? score == total
                          ? 'Perfect score!'
                          : score / total >= 0.7
                              ? 'Great job!'
                              : score / total >= 0.4
                                  ? 'Keep practicing!'
                                  : 'Review the material.'
                      : 'Submitted!',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text('Question Review',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 12),
          ...results.asMap().entries.map((entry) {
            final i = entry.key;
            final r = entry.value;
            final qId = r['question_id'] as String? ?? '';
            final question = _questions.firstWhere(
                (q) => (q['id'] as String?) == qId,
                orElse: () => {});
            final qText = question['question_text'] as String? ??
                question['text'] as String? ?? 'Question ${i + 1}';
            final yourAnswer = r['your_answer'] as String?;
            final isCorrect = r['is_correct'] as bool?;
            final correctAnswer = r['correct_answer'] as String?;
            final hintsRaw = r['hints'];
            Map<String, dynamic>? hints;
            if (hintsRaw is Map) {
              hints = hintsRaw.cast<String, dynamic>();
            }

            return _ReviewCard(
              index: i + 1,
              questionText: qText,
              yourAnswer: yourAnswer,
              correctAnswer: correctAnswer,
              isCorrect: isCorrect,
              hints: hints,
            );
          }),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E3A8A),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back to Lobby'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Supporting widgets
// ---------------------------------------------------------------------------

class _OptionTile extends StatelessWidget {
  final String letter;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  const _OptionTile({
    required this.letter,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? const Color(0xFF1E3A8A) : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
          color: selected
              ? const Color(0xFF1E3A8A).withValues(alpha: 0.08)
              : Colors.white,
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor:
                  selected ? const Color(0xFF1E3A8A) : Colors.grey.shade200,
              child: Text(
                letter,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
          ],
        ),
      ),
    );
  }
}

class _ReviewCard extends StatefulWidget {
  final int index;
  final String questionText;
  final String? yourAnswer;
  final String? correctAnswer;
  final bool? isCorrect;
  final Map<String, dynamic>? hints;

  const _ReviewCard({
    required this.index,
    required this.questionText,
    this.yourAnswer,
    this.correctAnswer,
    this.isCorrect,
    this.hints,
  });

  @override
  State<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends State<_ReviewCard> {
  bool _showHints = false;

  @override
  Widget build(BuildContext context) {
    final isScored = widget.isCorrect != null;
    final correct = widget.isCorrect ?? false;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: isScored
                ? CircleAvatar(
                    backgroundColor: (correct ? Colors.green : Colors.red)
                        .withValues(alpha: 0.15),
                    child: Icon(
                      correct ? Icons.check : Icons.close,
                      color: correct ? Colors.green : Colors.red,
                    ),
                  )
                : const CircleAvatar(
                    backgroundColor: Color(0xFFEEEEEE),
                    child: Icon(Icons.short_text, color: Colors.grey),
                  ),
            title: Text(
              '${widget.index}. ${widget.questionText}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.yourAnswer != null)
                  Text('Your answer: ${widget.yourAnswer}',
                      style: TextStyle(
                          color: isScored
                              ? correct
                                  ? Colors.green
                                  : Colors.red
                              : Colors.black87)),
                if (!correct &&
                    widget.correctAnswer != null &&
                    isScored)
                  Text('Correct: ${widget.correctAnswer}',
                      style: const TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.w500)),
              ],
            ),
            isThreeLine: widget.correctAnswer != null,
          ),
          if (widget.hints != null)
            Padding(
              padding:
                  const EdgeInsets.only(left: 16, right: 16, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _showHints = !_showHints),
                    icon: Icon(
                        _showHints
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18),
                    label: Text(
                        _showHints ? 'Hide Hints' : 'Show AI Hints'),
                  ),
                  if (_showHints)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: widget.hints!.entries.map((e) {
                          final val = e.value;
                          final verdict = val is Map
                              ? val['verdict'] as String?
                              : null;
                          final explanation = val is Map
                              ? val['explanation'] as String? ?? ''
                              : val.toString();
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  verdict == 'correct'
                                      ? Icons.check_circle
                                      : Icons.cancel,
                                  size: 14,
                                  color: verdict == 'correct'
                                      ? Colors.green
                                      : Colors.red,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: RichText(
                                    text: TextSpan(
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: Colors.black87),
                                      children: [
                                        TextSpan(
                                          text: '${e.key}: ',
                                          style: const TextStyle(
                                              fontWeight:
                                                  FontWeight.bold),
                                        ),
                                        TextSpan(text: explanation),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
