// lib/features/quiz/quiz_results_view.dart
//
// Teacher-facing live results view for an active or closed quiz.
// Shows per-student scores and per-question correct-rate bars.

import 'package:flutter/material.dart';
import '../../database/asura_repository.dart';

class QuizResultsView extends StatefulWidget {
  final String quizId;
  final String quizTitle;

  const QuizResultsView({
    super.key,
    required this.quizId,
    required this.quizTitle,
  });

  @override
  State<QuizResultsView> createState() => _QuizResultsViewState();
}

class _QuizResultsViewState extends State<QuizResultsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<Map<String, dynamic>> _scores = [];
  List<Map<String, dynamic>> _questions = [];
  List<Map<String, dynamic>> _responses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final scores = await AsuraRepository.getQuizScoreSummary(widget.quizId);
    final responses = await AsuraRepository.getResponsesForQuiz(widget.quizId);
    final questions = await AsuraRepository.getRoomQuizQuestions(widget.quizId);
    if (mounted) {
      final normalizedScores = <Map<String, dynamic>>[];
      for (final row in scores) {
        normalizedScores.add({
          'student_name': row['student_name'] as String? ?? 'Unknown',
          'student_ip': row['student_ip'] as String? ?? '',
          'total_answers': row['total_answers'] as int? ?? 0,
          'correct_count': row['correct_count'] as int? ?? 0,
          'submitted_at': row['submitted_at'],
        });
      }
      setState(() {
        _scores = normalizedScores;
        _responses = responses;
        _questions = questions;
        _loading = false;
      });
    }
  }

  /// Per-question stats: { question_id → {correct, total} }
  Map<String, Map<String, int>> _buildPerQuestionStats() {
    final stats = <String, Map<String, int>>{};
    for (final r in _responses) {
      final qId = r['question_id'] as String;
      stats.putIfAbsent(qId, () => {'correct': 0, 'total': 0});
      stats[qId]!['total'] = (stats[qId]!['total'] ?? 0) + 1;
      if ((r['is_correct'] as int?) == 1) {
        stats[qId]!['correct'] = (stats[qId]!['correct'] ?? 0) + 1;
      }
    }
    return stats;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.quizTitle,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold)),
            const Text('Live Results', style: TextStyle(fontSize: 12)),
          ],
        ),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'Leaderboard', icon: Icon(Icons.leaderboard, size: 16)),
            Tab(text: 'Per Question', icon: Icon(Icons.bar_chart, size: 16)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildLeaderboard(),
                _buildPerQuestion(),
              ],
            ),
    );
  }

  Widget _buildLeaderboard() {
    if (_scores.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_empty, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('No submissions yet.',
                style: TextStyle(color: Colors.grey, fontSize: 16)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _scores.length,
        itemBuilder: (ctx, i) {
          final s = _scores[i];
          final correct = (s['correct_count'] as int?) ?? 0;
          final total = (s['total_answers'] as int?) ?? 0;
          final pct = total > 0 ? correct / total : 0.0;
          final color = pct >= 0.7
              ? Colors.green
              : pct >= 0.4
                  ? Colors.orange
                  : Colors.red;

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    color.withValues(alpha: 0.15),
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.bold),
                ),
              ),
              title: Text(s['student_name'] as String? ?? 'Unknown',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${s['student_ip']}  •  Last: ${_fmtDate(s['submitted_at'] as String?)}'),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                ],
              ),
              trailing: Text(
                '$correct/$total',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: color),
              ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }

  Widget _buildPerQuestion() {
    if (_questions.isEmpty) {
      return const Center(
        child: Text('No questions found.',
            style: TextStyle(color: Colors.grey)),
      );
    }
    final stats = _buildPerQuestionStats();

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _questions.length,
      itemBuilder: (ctx, i) {
        final q = _questions[i];
        final qId = q['id'] as String;
        final qStats = stats[qId];
        final correct = qStats?['correct'] ?? 0;
        final total = qStats?['total'] ?? 0;
        final pct = total > 0 ? correct / total : 0.0;
        final type = q['question_type'] as String? ?? '';

        Color color = Colors.blue;
        if (total > 0) {
          color = pct >= 0.7
              ? Colors.green
              : pct >= 0.4
                  ? Colors.orange
                  : Colors.red;
        }

        // SA answers list
        final saAnswers = type == 'short_answer'
            ? _responses
                .where((r) => r['question_id'] == qId)
                .map((r) =>
                    '${r['student_name']}: ${r['answer'] ?? '(blank)'}')
                .toList()
            : <String>[];

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Q${i + 1}. ${q['question_text']}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                if (type != 'short_answer') ...[
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: pct,
                            minHeight: 12,
                            backgroundColor: Colors.grey.shade200,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(color),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        total > 0
                            ? '$correct/$total (${(pct * 100).toStringAsFixed(0)}%)'
                            : 'No answers',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: color),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    total > 0
                        ? '$correct student${correct == 1 ? '' : 's'} answered correctly'
                        : 'No submissions yet',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey),
                  ),
                ] else ...[
                  // Short-answer list
                  Text('${saAnswers.length} response${saAnswers.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
                  ...saAnswers.map((a) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '• $a',
                          style: const TextStyle(fontSize: 13),
                        ),
                      )),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _fmtDate(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}
