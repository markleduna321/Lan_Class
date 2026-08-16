import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:asuratech_lan_classroom/services/ai_assistant_service.dart';

void main() {
  group('buildAssistantContext', () {
    test('includes classroom and material details from the local repository', () {
      final context = buildAssistantContext(
        [
          {
            'classroom_id': 'room-1',
            'classroom_name': 'Networking 101',
            'original_name': 'Lecture 1.pdf',
            'mime_type': 'application/pdf',
          },
          {
            'classroom_id': 'room-2',
            'classroom_name': 'Biology',
            'original_name': 'Intro.pdf',
            'mime_type': 'application/pdf',
          },
        ],
        studentMaterials: [
          {
            'classroom_id': 'room-2',
            'classroom_name': 'Biology',
            'original_name': 'Lab Guide.pdf',
            'mime_type': 'application/pdf',
          },
        ],
      );

      expect(context, contains('Networking 101'));
      expect(context, contains('Lecture 1.pdf'));
      expect(context, contains('Lab Guide.pdf'));
      expect(context, contains('Use only the classroom materials above'));
    });

    test('returns an empty-state message when no materials exist', () {
      final context = buildAssistantContext([]);
      expect(context, contains('No classroom materials were found'));
    });
  });

  group('AiAssistantService contract helpers', () {
    test('builds a Laravel-compatible payload using remote classroom and material ids', () {
      final payload = AiAssistantService.buildAssistantPayload(
        prompt: 'Summarize the lesson',
        materials: [
          {
            'classroom_id': 'classroom-remote-id',
            'classroom_name': 'Networking 101',
            'original_name': 'Lecture 1.pdf',
            'mime_type': 'application/pdf',
            'material_id': 'material-remote-id',
            'storage_path': '/storage/materials/lecture-1.pdf',
            'download_url': 'https://example.com/material.pdf',
          },
        ],
        studentMaterials: [],
        allowWebSearch: false,
        conversationHistory: [
          {'role': 'user', 'content': 'What is this lesson about?'},
          {'role': 'assistant', 'content': 'It covers networking basics.'},
        ],
      );

      final materialPayload = (payload['materials'] as List).first as Map<String, dynamic>;
      expect(payload['prompt'], 'Summarize the lesson');
      expect(materialPayload['classroom_id'], 'classroom-remote-id');
      expect(materialPayload['material_id'], 'material-remote-id');
      expect(materialPayload.containsKey('storage_path'), isFalse);
      expect(materialPayload.containsKey('download_url'), isFalse);
      expect(payload['conversationHistory'], hasLength(2));
    });
  });

  group('AiAssistantService quiz helpers', () {
    test('parses a structured mock quiz payload from the assistant reply', () {
      final quiz = AiAssistantService.parseQuizPayload(
        '{"questions":[{"question":"What is the capital of France?","options":["London","Paris","Rome"],"correctAnswer":"Paris","hint":"It is a city in Europe.","explanation":"Paris is the capital of France."}]}',
      );

      expect(quiz, hasLength(1));
      expect(quiz.first['question'], contains('capital of France'));
      expect(quiz.first['options'], hasLength(3));
      expect(quiz.first['correctAnswer'], 'Paris');
    });

    test('parses plain-text multiple-choice quiz replies into progressive quiz items', () {
      const reply = '''
1. What is the role of the motherboard in a computer?
a) To store data permanently
b) To act as the central hub connecting all components
c) To process data like a brain
d) To power the computer

Answer: b
Hint: Think about which part connects everything.
Explanation: The motherboard connects and lets components communicate.

2. Which analogy is used to describe the CPU in the material?
a) A bookshelf
b) A skeleton
c) A master chef
d) A desk
''';

      final quiz = AiAssistantService.parseQuizPayload(reply);

      expect(quiz, hasLength(2));
      expect(quiz.first['question'], contains('motherboard'));
      expect((quiz.first['options'] as List), hasLength(4));
      expect(quiz.first['correctAnswer'], contains('central hub'));
      expect(quiz.first['hint'], contains('connects'));
    });

    test('parses compact JSON-like quiz replies into progressive quiz items', () {
      const reply = '{"questions":[{"question":"What is the primary function of the motherboard in a computer?","options":["To process data and perform calculations","To hold every component in place and carry signals between them","To store large amounts of data permanently","To display visual information on the screen"],"correctAnswer":"To hold every component in place and carry signals between them","hint":"Think of the motherboard as the central hub.","explanation":"It connects components and enables communication."}]}' ;

      final quiz = AiAssistantService.parseQuizPayload(reply);

      expect(quiz, hasLength(1));
      expect(quiz.first['question'], contains('motherboard'));
      expect((quiz.first['options'] as List), hasLength(4));
      expect(quiz.first['correctAnswer'], contains('carry signals'));
    });

    test('does not parse fallback text that only contains placeholder template shape', () {
      const fallback = 'The AI Helper is temporarily unavailable right now, but based on your available materials you can still ask questions once the service is back. Return ONLY JSON with this exact shape: {"questions":[{"question":"...","options":["...","...","...","..."],"correctAnswer":"...","hint":"...","explanation":"..."}]}."';

      final quiz = AiAssistantService.parseQuizPayload(fallback);

      expect(quiz, isEmpty);
    });

    test('builds a local mock quiz when backend is unavailable', () {
      final quiz = AiAssistantService.buildLocalMockQuiz(topic: 'Computer Hardware');

      expect(quiz, hasLength(5));
      expect(quiz.first['question'], contains('Computer Hardware'));
      expect((quiz.first['options'] as List), hasLength(4));
      expect(quiz.first['correctAnswer'], isNotEmpty);
    });
  });

  group('AiAssistantService guard rules', () {
    test('describes login-page HTML as a sign-in issue', () {
      final response = http.Response(
        '<html><body><div>login page</div></body></html>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

      expect(
        AiAssistantService.describeResponseIssue(response),
        contains('sign in'),
      );
    });

    test('allows material-related questions when classroom materials are available', () {
      final message = AiAssistantService.validatePrompt(
        'Explain the main idea of the lecture notes about networking',
        materials: [
          {
            'classroom_name': 'Networking 101',
            'original_name': 'Lecture 1.pdf',
          },
        ],
        studentMaterials: [],
      );

      expect(message, isNull);
    });

    test('rejects unrelated questions that are not about the classroom materials', () {
      final message = AiAssistantService.validatePrompt(
        'What is the weather in Manila today?',
        materials: [
          {
            'classroom_name': 'Networking 101',
            'original_name': 'Lecture 1.pdf',
          },
        ],
        studentMaterials: [],
      );

      expect(message, contains('only help with questions related to the classroom materials'));
    });

    test('allows follow-up confirmation prompts when prior conversation context exists', () {
      final message = AiAssistantService.validatePrompt(
        'yes, I want that summary',
        materials: [
          {
            'classroom_name': 'Networking 101',
            'original_name': 'Lecture 1.pdf',
          },
        ],
        studentMaterials: [],
        conversationHistory: [
          {'role': 'assistant', 'content': 'I can summarize Lecture 1.pdf. Would you like me to do that?'},
        ],
      );

      expect(message, isNull);
    });

    test('reports an auth failure clearly when the backend returns 401', () {
      final response = http.Response(
        '{"message":"Unauthenticated."}',
        401,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

      expect(
        AiAssistantService.describeResponseIssue(response),
        contains('sign in'),
      );
    });

    test('builds a helpful fallback reply when the backend returns a server error', () {
      final reply = AiAssistantService.buildLocalFallbackReply(
        'Summarize the lesson notes',
        [
          {'original_name': 'Lecture 1.pdf'},
          {'original_name': 'Lab Guide.pdf'},
        ],
        [],
      );

      expect(reply, contains('temporarily unavailable'));
      expect(reply, contains('Lecture 1.pdf'));
      expect(reply, contains('Lab Guide.pdf'));
    });
  });
}
