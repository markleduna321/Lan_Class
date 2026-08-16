import 'dart:convert';

Map<String, dynamic> resolveQuizSubmissionResult({
  required String? responseBody,
  required List<Map<String, dynamic>> questions,
  required List<Map<String, dynamic>> answers,
}) {
  if (responseBody == null || responseBody.trim().isEmpty) {
    return _buildFallbackResult(questions: questions, answers: answers);
  }

  try {
    final decoded = jsonDecode(responseBody);
    if (decoded is Map<String, dynamic>) {
      final hasScoreFields = decoded.containsKey('score') ||
          decoded.containsKey('scorable_total') ||
          decoded.containsKey('results');
      if (hasScoreFields) {
        return decoded;
      }
    }
  } catch (_) {}

  return _buildFallbackResult(questions: questions, answers: answers);
}

Map<String, dynamic> _buildFallbackResult({
  required List<Map<String, dynamic>> questions,
  required List<Map<String, dynamic>> answers,
}) {
  int score = 0;
  int scorableTotal = 0;
  final results = <Map<String, dynamic>>[];

  for (final answerEntry in answers) {
    final questionId = answerEntry['question_id'] as String? ?? '';
    final givenAnswer = (answerEntry['answer'] as String? ?? '').trim().toLowerCase();

    final question = questions.firstWhere(
      (q) => (q['id'] as String?) == questionId,
      orElse: () => {},
    );

    if (question.isEmpty) continue;

    final questionType = question['question_type'] as String? ??
        question['type'] as String? ?? '';
    final correctAnswer = question['correct_answer'] as String?;
    final isScored = questionType == 'multiple_choice' || questionType == 'true_false';

    bool? isCorrect;
    if (isScored && correctAnswer != null) {
      scorableTotal++;
      isCorrect = givenAnswer == correctAnswer.trim().toLowerCase();
      if (isCorrect == true) score++;
    }

    results.add({
      'question_id': questionId,
      'your_answer': answerEntry['answer'],
      'is_correct': isCorrect,
      'correct_answer': correctAnswer,
      'hints': question['hints'],
    });
  }

  return {
    'score': score,
    'scorable_total': scorableTotal,
    'results': results,
  };
}
