// lib/services/ai_hint_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;

enum AiProvider { gemini, openai, none }

class AiHintService {
  static const _geminiBase =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  /// Generates per-option hint explanations for a quiz question.
  ///
  /// Returns a decoded JSON [Map] on success, or `null` on failure / no provider.
  /// Expected shape for MC/TF:
  ///   {"A": {"verdict": "wrong"|"correct", "explanation": "..."}, ...}
  /// Expected shape for SA:
  ///   {"hint": "...", "explanation": "..."}
  static Future<Map<String, dynamic>?> generateHints({
    required String questionText,
    required String questionType,
    required List<String> options,
    required String? correctAnswer,
    required AiProvider provider,
    required String apiKey,
  }) async {
    if (provider == AiProvider.none || apiKey.trim().isEmpty) return null;
    final prompt = _buildPrompt(
      questionText: questionText,
      questionType: questionType,
      options: options,
      correctAnswer: correctAnswer,
    );
    try {
      final raw = provider == AiProvider.gemini
          ? await _callGemini(prompt, apiKey)
          : await _callOpenAI(prompt, apiKey);
      if (raw == null || raw.trim().isEmpty) return null;
      // Strip markdown code fences if present
      final cleaned = raw
          .replaceAll(RegExp(r'^```json\s*', multiLine: true), '')
          .replaceAll(RegExp(r'^```\s*', multiLine: true), '')
          .trim();
      return jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static String _buildPrompt({
    required String questionText,
    required String questionType,
    required List<String> options,
    required String? correctAnswer,
  }) {
    final optionsList = options.isNotEmpty
        ? options.asMap().entries.map((e) {
            final letter = String.fromCharCode(65 + e.key); // A, B, C...
            return '"$letter": "${e.value}"';
          }).join(', ')
        : '';

    final formatHint = questionType == 'short_answer'
        ? '{"hint":"Think about...","explanation":"The correct answer should..."}'
        : () {
            final keys = options.isNotEmpty
                ? options.asMap().keys.map((i) => String.fromCharCode(65 + i)).toList()
                : ['True', 'False'];
            return '{${keys.map((k) => '"$k":{"verdict":"wrong or correct","explanation":"..."}').join(',')}}';
          }();

    return '''You are a teacher's assistant. Write concise 1-2 sentence explanations (max 40 words each) for each answer option of the quiz question below. Respond ONLY with a valid JSON object. No markdown, no extra text.

Question: "$questionText"
Type: $questionType${optionsList.isNotEmpty ? '\nOptions: {$optionsList}' : ''}${correctAnswer != null ? '\nCorrect answer: "$correctAnswer"' : ''}

Required JSON format: $formatHint''';
  }

  static Future<String?> _callGemini(String prompt, String apiKey) async {
    final url = Uri.parse('$_geminiBase?key=$apiKey');
    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'responseMimeType': 'application/json',
              'temperature': 0.4,
            },
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = body['candidates'] as List?;
      if (candidates != null && candidates.isNotEmpty) {
        return candidates[0]['content']['parts'][0]['text'] as String?;
      }
    }
    return null;
  }

  static Future<String?> _callOpenAI(String prompt, String apiKey) async {
    final url = Uri.parse('https://api.openai.com/v1/chat/completions');
    final response = await http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': 'gpt-4o-mini',
            'messages': [
              {'role': 'user', 'content': prompt}
            ],
            'response_format': {'type': 'json_object'},
            'max_tokens': 600,
            'temperature': 0.4,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['choices'][0]['message']['content'] as String?;
    }
    return null;
  }
}
