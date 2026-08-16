import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'cloud_api_service.dart';

class AiAssistantService {
  static const _rateLimitWindowSeconds = 60;
  static const _maxRequestsPerWindow = 8;
  static final List<int> _requestTimestamps = <int>[];

  static Map<String, dynamic> buildAssistantPayload({
    required String prompt,
    required List<Map<String, dynamic>> materials,
    required List<Map<String, dynamic>> studentMaterials,
    required bool allowWebSearch,
    List<Map<String, dynamic>> conversationHistory = const [],
    String? context,
    String? supplementalContext,
  }) {
    return buildAssistantPayloadImpl(
      prompt: prompt,
      materials: materials,
      studentMaterials: studentMaterials,
      allowWebSearch: allowWebSearch,
      conversationHistory: conversationHistory,
      context: context,
      supplementalContext: supplementalContext,
    );
  }

  static Future<String?> sendMessage({
    required String prompt,
    required String apiKey,
    required List<Map<String, dynamic>> materials,
    required List<Map<String, dynamic>> studentMaterials,
    bool allowWebSearch = false,
    List<Map<String, dynamic>> conversationHistory = const [],
  }) async {
    final guardMessage = validatePrompt(
      prompt,
      materials: materials,
      studentMaterials: studentMaterials,
      conversationHistory: conversationHistory,
    );
    if (guardMessage != null) {
      return guardMessage;
    }

    if (!await _canProceed()) {
      return 'The AI Helper is temporarily rate limited. Please wait a minute and try again.';
    }

    final isLoggedIn = await CloudApiService.isLinked;
    if (!isLoggedIn) {
      return 'Please sign in to your online account before using the AI Helper.';
    }

    String? supplementalContext;
    if (allowWebSearch) {
      supplementalContext = await _fetchWebRelevance(prompt);
    }

    final context = buildAssistantContext(materials, studentMaterials: studentMaterials);
    final payload = buildAssistantPayload(
      prompt: prompt,
      materials: materials,
      studentMaterials: studentMaterials,
      allowWebSearch: allowWebSearch,
      conversationHistory: conversationHistory,
      context: context,
      supplementalContext: supplementalContext,
    );

    var response = await CloudApiService.post(
      '/api/ai-helper',
      payload,
      timeout: const Duration(seconds: 90),
    );

    // One retry — transient network drops are common on mobile data.
    response ??= await CloudApiService.post(
      '/api/ai-helper',
      payload,
      timeout: const Duration(seconds: 90),
    );

    if (response == null) {
      return 'The AI Helper could not reach the server. Check your internet connection and try again.';
    }

    debugPrint('AI Helper response ${response.statusCode}: ${response.body}');

    if (response.statusCode == 401 || response.statusCode == 403) {
      return describeResponseIssue(response);
    }

    if (response.statusCode != 200) {
      final fallback = buildLocalFallbackReply(
        prompt,
        materials,
        studentMaterials,
      );
      return fallback;
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return describeResponseIssue(response);
      }

      final content = decoded['reply'] as String?;
      if (content == null || content.trim().isEmpty) {
        return 'The AI Helper returned an empty reply. Please try again.';
      }
      return content.trim();
    } catch (_) {
      return describeResponseIssue(response);
    }
  }

  static String describeResponseIssue(http.Response response) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final bodyPreview = response.body.trimLeft();
    final normalizedBody = bodyPreview.toLowerCase();
    final looksLikeHtml = contentType.contains('text/html') || bodyPreview.startsWith('<');
    final looksLikeLoginPage = looksLikeHtml &&
        (normalizedBody.contains('/login') || normalizedBody.contains('login page') || normalizedBody.contains('sign in'));

    if (response.statusCode == 401 || response.statusCode == 403 || looksLikeLoginPage) {
      return 'Please sign in to your online account before using the AI Helper.';
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final message = decoded['message'] as String?;
        if (message != null && message.trim().isNotEmpty) {
          return message.trim();
        }
        final reply = decoded['reply'] as String?;
        if (reply != null && reply.trim().isNotEmpty) {
          return reply.trim();
        }
      }
    } catch (_) {}

    if (looksLikeHtml) {
      return 'The AI Helper could not reach a valid reply from the web backend. Please sign in and try again.';
    }

    return 'The AI Helper could not generate an answer right now (${response.statusCode}).';
  }

  static List<Map<String, dynamic>> parseQuizPayload(String content) {
    final cleaned = content
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .trim();

    final normalizedLower = cleaned.toLowerCase();
    if (normalizedLower.contains('temporarily unavailable right now')) {
      debugPrint('[AI Helper Quiz] Service reported as unavailable');
      return const [];
    }

    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('[AI Helper Quiz] Decoded response is not a Map: ${decoded.runtimeType}');
        return const [];
      }

      final questions = decoded['questions'];
      if (questions is! List) {
        debugPrint('[AI Helper Quiz] "questions" field is not a List: ${questions.runtimeType}');
        return const [];
      }

      final normalized = questions
          .whereType<Map<String, dynamic>>()
          .map((question) {
            final questionText = question['question']?.toString() ?? '';
            final rawOptions = question['options'];
            final options = rawOptions is List
                ? rawOptions.map((option) => option.toString().trim()).where((option) => option.isNotEmpty).toList()
                : <String>[];
            final fallbackCorrect = options.isNotEmpty ? options.first : '';

            return {
              'question': questionText,
              'options': options,
              'correctAnswer': question['correctAnswer']?.toString().trim().isNotEmpty == true
                  ? question['correctAnswer']?.toString().trim()
                  : fallbackCorrect,
              'hint': question['hint']?.toString() ?? 'Review the key point from the lesson before answering.',
              'explanation': question['explanation']?.toString() ?? 'Check your selected answer against the lesson context.',
            };
          })
            .where(_isValidQuizQuestion)
          .toList();

      debugPrint('[AI Helper Quiz] Successfully parsed ${normalized.length} valid questions from JSON');
      if (normalized.isNotEmpty) {
        return normalized;
      }
    } catch (e) {
      debugPrint('[AI Helper Quiz] JSON parsing error: $e');
      // Fall through to plain-text parsing.
    }

    final jsonLike = _parseJsonLikeQuiz(cleaned);
    if (jsonLike.isNotEmpty) {
      debugPrint('[AI Helper Quiz] Parsed ${jsonLike.length} questions via regex');
      return jsonLike;
    }

    final plainText = _parsePlainTextQuiz(cleaned);
    if (plainText.isNotEmpty) {
      debugPrint('[AI Helper Quiz] Parsed ${plainText.length} questions via plain text');
      return plainText;
    }

    debugPrint('[AI Helper Quiz] Failed to parse any questions from response. Content: ${cleaned.substring(0, 200.clamp(0, cleaned.length))}');
    return const [];
  }

  static List<Map<String, dynamic>> _parseJsonLikeQuiz(String content) {
    final objectMatches = RegExp(r'\{\s*"question"\s*:\s*"(.*?)"\s*,\s*"options"\s*:\s*\[(.*?)\]\s*,\s*"correctAnswer"\s*:\s*"(.*?)"(.*?)\}', dotAll: true)
        .allMatches(content);

    final questions = <Map<String, dynamic>>[];

    for (final match in objectMatches) {
      final questionText = (match.group(1) ?? '').replaceAll(r'\"', '"').trim();
      final optionsBlock = match.group(2) ?? '';
      final correctAnswer = (match.group(3) ?? '').replaceAll(r'\"', '"').trim();
      final trailing = match.group(4) ?? '';

      final options = RegExp(r'"(.*?)"')
          .allMatches(optionsBlock)
          .map((optionMatch) => (optionMatch.group(1) ?? '').replaceAll(r'\"', '"').trim())
          .where((option) => option.isNotEmpty)
          .toList();

      if (questionText.isEmpty || options.length < 2) continue;

      final hintMatch = RegExp(r'"hint"\s*:\s*"(.*?)"', dotAll: true).firstMatch(trailing);
      final explanationMatch = RegExp(r'"explanation"\s*:\s*"(.*?)"', dotAll: true).firstMatch(trailing);

      questions.add({
        'question': questionText,
        'options': options,
        'correctAnswer': correctAnswer.isNotEmpty ? correctAnswer : options.first,
        'hint': ((hintMatch?.group(1) ?? 'Review the lesson section related to this item.').replaceAll(r'\"', '"')).trim(),
        'explanation': ((explanationMatch?.group(1) ?? 'Use the material context to validate the correct choice.').replaceAll(r'\"', '"')).trim(),
      });
    }

    return questions.where(_isValidQuizQuestion).toList();
  }

  static List<Map<String, dynamic>> _parsePlainTextQuiz(String content) {
    final lines = content.split('\n').map((line) => line.trim()).toList();
    final questions = <Map<String, dynamic>>[];

    String? currentQuestion;
    List<String> currentOptions = <String>[];
    String? answerToken;
    String hint = 'Review the lesson section related to this item.';
    String explanation = 'Use the material context to validate the correct choice.';

    void flushCurrent() {
      if (currentQuestion == null || currentQuestion.isEmpty || currentOptions.length < 2) {
        return;
      }

      String correctAnswer = currentOptions.first;
      final normalizedAnswer = (answerToken ?? '').trim();
      if (normalizedAnswer.isNotEmpty) {
        if (RegExp(r'^[a-dA-D]$').hasMatch(normalizedAnswer)) {
          final index = normalizedAnswer.toLowerCase().codeUnitAt(0) - 'a'.codeUnitAt(0);
          if (index >= 0 && index < currentOptions.length) {
            correctAnswer = currentOptions[index];
          }
        } else {
          final match = currentOptions.where((option) => option.toLowerCase() == normalizedAnswer.toLowerCase()).toList();
          if (match.isNotEmpty) {
            correctAnswer = match.first;
          }
        }
      }

      questions.add({
        'question': currentQuestion,
        'options': List<String>.from(currentOptions),
        'correctAnswer': correctAnswer,
        'hint': hint,
        'explanation': explanation,
      });
    }

    for (final line in lines) {
      if (line.isEmpty) continue;

      final questionMatch = RegExp(r'^\d+[\.)]\s+(.+)$').firstMatch(line);
      if (questionMatch != null) {
        flushCurrent();
        currentQuestion = (questionMatch.group(1) ?? '').trim();
        currentOptions = <String>[];
        answerToken = null;
        hint = 'Review the lesson section related to this item.';
        explanation = 'Use the material context to validate the correct choice.';
        continue;
      }

      if (currentQuestion == null) continue;

      final optionMatch = RegExp(r'^[a-dA-D][\)\.]\s+(.+)$').firstMatch(line);
      if (optionMatch != null) {
        final optionText = (optionMatch.group(1) ?? '').trim();
        if (optionText.isNotEmpty) {
          currentOptions.add(optionText);
        }
        continue;
      }

      final answerMatch = RegExp(r'^(?:answer|correct answer)\s*[:\-]\s*(.+)$', caseSensitive: false).firstMatch(line);
      if (answerMatch != null) {
        answerToken = (answerMatch.group(1) ?? '').trim();
        continue;
      }

      final hintMatch = RegExp(r'^hint\s*[:\-]\s*(.+)$', caseSensitive: false).firstMatch(line);
      if (hintMatch != null) {
        final value = (hintMatch.group(1) ?? '').trim();
        if (value.isNotEmpty) hint = value;
        continue;
      }

      final explanationMatch = RegExp(r'^(?:explanation|why)\s*[:\-]\s*(.+)$', caseSensitive: false).firstMatch(line);
      if (explanationMatch != null) {
        final value = (explanationMatch.group(1) ?? '').trim();
        if (value.isNotEmpty) explanation = value;
      }
    }

    flushCurrent();
    return questions.where(_isValidQuizQuestion).toList();
  }

  static bool _isValidQuizQuestion(Map<String, dynamic> question) {
    final questionText = (question['question'] as String?)?.trim() ?? '';
    final options = (question['options'] as List?)?.map((option) => option.toString().trim()).toList() ?? <String>[];
    final correctAnswer = (question['correctAnswer'] as String?)?.trim() ?? '';

    if (!_isMeaningfulText(questionText)) return false;
    if (!_isMeaningfulText(correctAnswer)) return false;
    if (options.length < 2) return false;

    final meaningfulOptions = options.where(_isMeaningfulText).toList();
    if (meaningfulOptions.length < 2) return false;

    return true;
  }

  static bool _isMeaningfulText(String value) {
    final cleaned = value.trim();
    if (cleaned.isEmpty) return false;
    if (cleaned == '...') return false;
    if (cleaned.replaceAll('.', '').isEmpty) return false;
    return RegExp(r'[A-Za-z0-9]').hasMatch(cleaned);
  }

  static String buildQuickActionReply(String action, String prompt) {
    switch (action.toLowerCase()) {
      case 'summary':
        return 'Here is a concise summary of the materials you shared:\n\n- Key ideas: focus on the main concepts, definitions, and takeaways.\n- Study tip: review the material in short chunks and connect each section to the lesson goal.\n- Next step: ask me for a mock quiz or a deeper explanation.';
      case 'quiz':
        return jsonEncode({
          'questions': [
            {
              'question': prompt.isNotEmpty ? prompt : 'What is the main idea of this lesson?',
              'options': ['Main idea', 'Supporting detail', 'Background context', 'Example only'],
              'correctAnswer': 'Main idea',
              'hint': 'Look for the central takeaway the lesson is teaching.',
              'explanation': 'The main idea is the broad point the lesson is trying to communicate.',
            }
          ],
        });
      default:
        return 'I can help with a quick summary or a mock quiz.';
    }
  }

  static List<Map<String, dynamic>> buildLocalMockQuiz({
    required String topic,
    int questionCount = 5,
  }) {
    final normalizedTopic = _normalizeTopicLabel(topic);
    final lowerTopic = normalizedTopic.toLowerCase();

    final bool isHardware = lowerTopic.contains('hardware');
    final bool isSoftware = lowerTopic.contains('software');
    final bool isNetwork = lowerTopic.contains('network');
    final bool isDatabase = lowerTopic.contains('database') || lowerTopic.contains('sql');
    final bool isProgramming =
        lowerTopic.contains('program') || lowerTopic.contains('coding') || lowerTopic.contains('algorithm');

    final templates = isHardware
        ? _hardwareQuizTemplates(normalizedTopic)
        : isSoftware
            ? _softwareQuizTemplates(normalizedTopic)
            : isNetwork
                ? _networkQuizTemplates(normalizedTopic)
                : isDatabase
                    ? _databaseQuizTemplates(normalizedTopic)
                    : isProgramming
                        ? _programmingQuizTemplates(normalizedTopic)
                        : _genericConceptQuizTemplates(normalizedTopic);

    final count = questionCount < 1 ? 1 : (questionCount > 50 ? 50 : questionCount);
    
    // Safety check: ensure templates is not empty
    if (templates.isEmpty) {
      debugPrint('[AI Helper] ERROR: No templates found for topic "$normalizedTopic"');
      return _genericConceptQuizTemplates(normalizedTopic).take(count).toList();
    }
    
    if (count <= templates.length) {
      return templates.take(count).toList();
    }

    // Expand by cycling through templates when more questions are needed
    final expanded = <Map<String, dynamic>>[];
    for (var i = 0; i < count; i++) {
      final base = templates[i % templates.length];
      final cycle = (i ~/ templates.length) + 1;
      final cycleMarker = cycle > 1 ? ' (Practice set $cycle)' : '';
      expanded.add({
        ...base,
        'question': '${base['question']}$cycleMarker',
      });
    }
    return expanded;
  }

  static String _normalizeTopicLabel(String topic) {
    if (topic.trim().isEmpty) return 'this lesson topic';

    var label = topic.trim();
    label = label.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '');
    label = label.replaceAll(RegExp(r'[_\-]+'), ' ');
    label = label.replaceAll(RegExp(r'\(\d+\)'), ' ');
    label = label.replaceAll(RegExp(r'\s+'), ' ').trim();

    return label.isEmpty ? 'this lesson topic' : label;
  }

  static List<Map<String, dynamic>> _hardwareQuizTemplates(String topic) {
    return [
      {
        'question': 'In $topic, what best describes computer hardware?',
        'options': [
          'The physical parts of a computer system',
          'Only the applications installed on a device',
          'A cloud service for online storage only',
          'A method for encrypting files',
        ],
        'correctAnswer': 'The physical parts of a computer system',
        'hint': 'Think about components you can physically touch.',
        'explanation': 'Hardware refers to tangible components like CPU, RAM, motherboard, and storage devices.',
      },
      {
        'question': 'Which component mainly executes instructions and performs calculations?',
        'options': ['CPU', 'Monitor', 'Keyboard', 'Power cable'],
        'correctAnswer': 'CPU',
        'hint': 'It is often called the brain of the computer.',
        'explanation': 'The CPU processes instructions and handles arithmetic and logical operations.',
      },
      {
        'question': 'What is the primary role of RAM in a hardware system?',
        'options': [
          'Temporary working memory for active tasks',
          'Permanent long-term archival storage',
          'Power distribution to all components',
          'Physical network routing between devices',
        ],
        'correctAnswer': 'Temporary working memory for active tasks',
        'hint': 'It clears when the computer is powered off.',
        'explanation': 'RAM stores data temporarily so the CPU can quickly access active programs and files.',
      },
      {
        'question': 'Which hardware part connects major components and enables communication between them?',
        'options': ['Motherboard', 'Mouse', 'Webcam', 'Speaker'],
        'correctAnswer': 'Motherboard',
        'hint': 'It is the main board inside the computer case.',
        'explanation': 'The motherboard is the central platform that links CPU, RAM, storage, and peripherals.',
      },
      {
        'question': 'How do SSDs generally compare with HDDs for most systems?',
        'options': [
          'SSDs are usually faster for read/write performance',
          'HDDs are always faster in all tasks',
          'They have identical access speeds',
          'SSDs cannot store operating systems',
        ],
        'correctAnswer': 'SSDs are usually faster for read/write performance',
        'hint': 'Consider which storage has no moving mechanical parts.',
        'explanation': 'SSDs use flash memory, giving lower latency and faster data access than typical HDDs.',
      },
    ];
  }

  static List<Map<String, dynamic>> _softwareQuizTemplates(String topic) {
    return [
      {
        'question': 'In $topic, what best defines software?',
        'options': [
          'Programs and instructions that tell hardware what to do',
          'Only external input devices',
          'Physical chips on a motherboard',
          'A type of storage cable',
        ],
        'correctAnswer': 'Programs and instructions that tell hardware what to do',
        'hint': 'Software is intangible and runs on hardware.',
        'explanation': 'Software includes operating systems and applications that control hardware behavior.',
      },
      {
        'question': 'Which type of software manages computer resources and hardware access?',
        'options': ['Operating system', 'Spreadsheet document', 'Image file', 'Presentation slide'],
        'correctAnswer': 'Operating system',
        'hint': 'It acts as the main interface between users and hardware.',
        'explanation': 'The operating system handles process, memory, storage, and device management.',
      },
      {
        'question': 'What is application software primarily designed for?',
        'options': [
          'Helping users perform specific tasks',
          'Replacing physical hardware',
          'Generating electrical power',
          'Creating internet cabling',
        ],
        'correctAnswer': 'Helping users perform specific tasks',
        'hint': 'Think of word processors, browsers, and editors.',
        'explanation': 'Application software focuses on user-oriented tasks like writing, browsing, and communication.',
      },
      {
        'question': 'Why are software updates important?',
        'options': [
          'They improve security, fix bugs, and add features',
          'They physically clean computer components',
          'They eliminate the need for an operating system',
          'They convert hardware into software',
        ],
        'correctAnswer': 'They improve security, fix bugs, and add features',
        'hint': 'Updates often include patches for vulnerabilities.',
        'explanation': 'Regular updates maintain stability and protect systems from known security issues.',
      },
      {
        'question': 'What is the relationship between software and hardware?',
        'options': [
          'Software instructs hardware operations',
          'Hardware writes all software automatically',
          'They are completely unrelated',
          'Software can run without any hardware',
        ],
        'correctAnswer': 'Software instructs hardware operations',
        'hint': 'One provides instructions; the other executes them physically.',
        'explanation': 'Hardware executes the commands and logic defined by software.',
      },
    ];
  }

  static List<Map<String, dynamic>> _networkQuizTemplates(String topic) {
    return [
      {
        'question': 'In $topic, what is the core purpose of a computer network?',
        'options': [
          'To connect devices for communication and resource sharing',
          'To replace all hardware components',
          'To permanently store files offline only',
          'To compile programming code automatically',
        ],
        'correctAnswer': 'To connect devices for communication and resource sharing',
        'hint': 'Networks enable devices to exchange data.',
        'explanation': 'A network links devices so users can share data, services, and internet access.',
      },
      {
        'question': 'Which device commonly directs packets between different networks?',
        'options': ['Router', 'Monitor', 'Printer', 'Keyboard'],
        'correctAnswer': 'Router',
        'hint': 'It selects paths for data between networks.',
        'explanation': 'Routers forward packets between networks using routing tables.',
      },
      {
        'question': 'What does an IP address primarily identify?',
        'options': [
          'A device location on a network',
          'A user password for login',
          'A file name on disk',
          'A CPU clock speed',
        ],
        'correctAnswer': 'A device location on a network',
        'hint': 'It is used so data knows where to go.',
        'explanation': 'IP addresses uniquely identify endpoints in network communication.',
      },
      {
        'question': 'What is the main role of DNS in networking?',
        'options': [
          'Translate domain names to IP addresses',
          'Compress image files',
          'Build hardware circuits',
          'Store operating system kernels',
        ],
        'correctAnswer': 'Translate domain names to IP addresses',
        'hint': 'It maps human-friendly names to machine-usable addresses.',
        'explanation': 'DNS resolves names like example.com to routable IP addresses.',
      },
      {
        'question': 'Which practice improves network security the most for user accounts?',
        'options': [
          'Use strong passwords and multi-factor authentication',
          'Share passwords with all teammates',
          'Disable all software updates',
          'Keep default admin credentials forever',
        ],
        'correctAnswer': 'Use strong passwords and multi-factor authentication',
        'hint': 'Layered account protection reduces unauthorized access.',
        'explanation': 'Strong credentials plus MFA greatly lower account compromise risk.',
      },
    ];
  }

  static List<Map<String, dynamic>> _databaseQuizTemplates(String topic) {
    return [
      {
        'question': 'In $topic, what is a database best described as?',
        'options': [
          'An organized collection of data for efficient access',
          'A physical network cable standard',
          'A CPU instruction set',
          'A graphics rendering engine',
        ],
        'correctAnswer': 'An organized collection of data for efficient access',
        'hint': 'Think of structure, retrieval, and management of information.',
        'explanation': 'Databases store and organize data so applications can query and update it reliably.',
      },
      {
        'question': 'What is SQL mainly used for?',
        'options': [
          'Querying and managing relational data',
          'Physically assembling hardware',
          'Encoding audio files',
          'Driving display brightness',
        ],
        'correctAnswer': 'Querying and managing relational data',
        'hint': 'It is the standard language for relational databases.',
        'explanation': 'SQL supports selecting, inserting, updating, and deleting structured records.',
      },
      {
        'question': 'What is the purpose of a primary key in a table?',
        'options': [
          'Uniquely identify each row',
          'Encrypt all column values',
          'Replace indexes completely',
          'Store image attachments only',
        ],
        'correctAnswer': 'Uniquely identify each row',
        'hint': 'No two records should share it.',
        'explanation': 'Primary keys ensure entity uniqueness and support relationships between tables.',
      },
      {
        'question': 'Why are indexes added to database tables?',
        'options': [
          'To speed up query performance on searched columns',
          'To delete duplicate tables automatically',
          'To replace backup systems',
          'To prevent data types from being used',
        ],
        'correctAnswer': 'To speed up query performance on searched columns',
        'hint': 'They reduce scan work for frequent lookups.',
        'explanation': 'Indexes help the database find matching rows faster, especially in large tables.',
      },
      {
        'question': 'What is normalization mainly intended to reduce?',
        'options': [
          'Data redundancy and update anomalies',
          'Disk power consumption only',
          'CPU voltage fluctuations',
          'Display resolution settings',
        ],
        'correctAnswer': 'Data redundancy and update anomalies',
        'hint': 'It improves consistency by structuring related data properly.',
        'explanation': 'Normalization organizes schema to minimize repeated data and inconsistent updates.',
      },
    ];
  }

  static List<Map<String, dynamic>> _programmingQuizTemplates(String topic) {
    return [
      {
        'question': 'In $topic, what is an algorithm?',
        'options': [
          'A step-by-step procedure to solve a problem',
          'A hardware storage device',
          'A monitor resolution standard',
          'A network cable category',
        ],
        'correctAnswer': 'A step-by-step procedure to solve a problem',
        'hint': 'Think of ordered instructions.',
        'explanation': 'Algorithms define clear logic that programs follow to produce expected outputs.',
      },
      {
        'question': 'Why are variables used in programming?',
        'options': [
          'To store and update values during execution',
          'To replace all control flow statements',
          'To physically power computer hardware',
          'To secure network traffic by default',
        ],
        'correctAnswer': 'To store and update values during execution',
        'hint': 'Variables hold data that can be reused and changed.',
        'explanation': 'Variables represent named memory locations for program state and calculations.',
      },
      {
        'question': 'What is the purpose of conditional statements?',
        'options': [
          'Execute different code paths based on conditions',
          'Create hardware components automatically',
          'Disable all program input',
          'Eliminate the need for functions',
        ],
        'correctAnswer': 'Execute different code paths based on conditions',
        'hint': 'They help programs make decisions.',
        'explanation': 'Conditionals evaluate expressions and branch logic accordingly.',
      },
      {
        'question': 'Why are functions useful in programming?',
        'options': [
          'They promote reuse and organize logic into smaller units',
          'They remove the need for testing',
          'They only make code longer',
          'They prevent all runtime errors',
        ],
        'correctAnswer': 'They promote reuse and organize logic into smaller units',
        'hint': 'Modular code is easier to maintain.',
        'explanation': 'Functions encapsulate behavior, improving readability, testability, and maintainability.',
      },
      {
        'question': 'What does debugging mainly involve?',
        'options': [
          'Finding and fixing defects in code',
          'Formatting storage drives physically',
          'Replacing a network router chassis',
          'Changing monitor brightness settings',
        ],
        'correctAnswer': 'Finding and fixing defects in code',
        'hint': 'It focuses on root-cause analysis of incorrect behavior.',
        'explanation': 'Debugging identifies logic or runtime issues and validates corrective changes.',
      },
    ];
  }

  static List<Map<String, dynamic>> _genericConceptQuizTemplates(String topic) {
    return [
      {
        'question': 'What best describes the core idea of $topic?',
        'options': [
          'A set of related concepts that explain the topic',
          'A random list of disconnected trivia',
          'Only a file format and nothing else',
          'A physical object with no theory',
        ],
        'correctAnswer': 'A set of related concepts that explain the topic',
        'hint': 'Focus on meaning and relationships, not isolated facts.',
        'explanation': 'Most lessons define concepts and show how those concepts work together.',
      },
      {
        'question': 'Which study approach helps understand $topic more deeply?',
        'options': [
          'Connect definitions with practical examples',
          'Memorize headings only',
          'Skip unfamiliar terms',
          'Ignore diagrams and context',
        ],
        'correctAnswer': 'Connect definitions with practical examples',
        'hint': 'Application strengthens conceptual understanding.',
        'explanation': 'Examples make abstract terms concrete and easier to recall.',
      },
      {
        'question': 'What should you do first when a concept in $topic is unclear?',
        'options': [
          'Break it down and review foundational terms',
          'Skip it permanently',
          'Assume it is never tested',
          'Replace it with unrelated content',
        ],
        'correctAnswer': 'Break it down and review foundational terms',
        'hint': 'Start from basics, then rebuild the bigger idea.',
        'explanation': 'Foundational understanding makes advanced concepts much easier to process.',
      },
      {
        'question': 'Why is self-testing useful for $topic?',
        'options': [
          'It reveals weak areas and improves recall',
          'It removes the need to study',
          'It guarantees perfect scores without review',
          'It replaces all lesson materials',
        ],
        'correctAnswer': 'It reveals weak areas and improves recall',
        'hint': 'Practice questions provide feedback on what to revisit.',
        'explanation': 'Frequent retrieval practice improves retention and guides focused review.',
      },
      {
        'question': 'What is a good final review strategy before an exam on $topic?',
        'options': [
          'Summarize key points and check misconceptions',
          'Read only the first paragraph once',
          'Avoid checking incorrect answers',
          'Rely entirely on guessing',
        ],
        'correctAnswer': 'Summarize key points and check misconceptions',
        'hint': 'Review should target clarity and correction.',
        'explanation': 'Consolidating key ideas and fixing errors improves exam readiness.',
      },
    ];
  }

  static String buildLocalFallbackReply(
    String prompt,
    List<Map<String, dynamic>> materials,
    List<Map<String, dynamic>> studentMaterials,
  ) {
    final trimmedPrompt = prompt.trim();
    final available = <String>[];

    for (final material in [...materials, ...studentMaterials]) {
      final name = material['original_name']?.toString().trim();
      if (name != null && name.isNotEmpty && !available.contains(name)) {
        available.add(name);
      }
    }

    if (available.isEmpty) {
      return 'The AI Helper is temporarily unavailable, but your classroom materials are ready for review when the service is back.';
    }

    final materialList = available.take(3).join(', ');
    return 'The AI Helper is temporarily unavailable right now, but based on your available materials ($materialList), you can still ask questions about $materialList once the service is back. $trimmedPrompt';
  }

  static String? validatePrompt(
    String prompt, {
    required List<Map<String, dynamic>> materials,
    required List<Map<String, dynamic>> studentMaterials,
    List<Map<String, dynamic>> conversationHistory = const [],
  }) {
    final normalized = prompt.trim().toLowerCase();
    if (normalized.isEmpty) {
      return 'Please ask a question about your classroom materials.';
    }

    final hasMaterials = materials.isNotEmpty || studentMaterials.isNotEmpty;
    if (!hasMaterials) {
      return 'I can only help with questions related to the classroom materials available in this app.';
    }

    final materialTerms = <String>[
      'material',
      'lecture',
      'lesson',
      'chapter',
      'topic',
      'document',
      'classroom',
      'room',
      'assignment',
      'quiz',
      'notes',
      'study',
      'module',
      'content',
      'exam',
      'homework',
      'video',
      'slide',
      'summary',
      'summarize',
      'summaries',
    ];

    final unrelatedTerms = <String>[
      'weather',
      'news',
      'stock',
      'sports',
      'movie',
      'song',
      'travel',
      'restaurant',
      'joke',
      'who are you',
      'what is your name',
      'tell me a story',
      'write code',
      'play music',
      'translate',
      'solve',
      'math problem',
      'capital of',
      'capital',
    ];

    final mentionsMaterial = materialTerms.any(normalized.contains);
    final hasConversationContext = conversationHistory.isNotEmpty;
    final isShortFollowUp = normalized.length <= 30 &&
        (normalized.startsWith('yes') ||
            normalized.startsWith('no') ||
            normalized.startsWith('continue') ||
            normalized.startsWith('go on') ||
            normalized.startsWith('do that') ||
            normalized.startsWith('that one') ||
            normalized.startsWith('that pdf') ||
            normalized.startsWith('that document') ||
            normalized.startsWith('the same') ||
            normalized.startsWith('more'));
    final isLikelyUnrelated = unrelatedTerms.any(normalized.contains) && !mentionsMaterial && !(hasConversationContext && isShortFollowUp);
    if (isLikelyUnrelated) {
      return 'I can only help with questions related to the classroom materials available here.';
    }

    return null;
  }

  static Future<bool> _canProceed() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final windowStart = now - (_rateLimitWindowSeconds * 1000);
    _requestTimestamps.removeWhere((timestamp) => timestamp < windowStart);

    if (_requestTimestamps.length >= _maxRequestsPerWindow) {
      return false;
    }

    _requestTimestamps.add(now);
    return true;
  }

  static Future<String?> _fetchWebRelevance(String prompt) async {
    try {
      final query = Uri.encodeComponent(prompt.trim());
      final response = await http.get(
        Uri.parse('https://duckduckgo.com/html/?q=$query'),
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) return null;
      final body = response.body;
      final matches = RegExp(r'<a[^>]+class="result__a"[^>]*>(.*?)</a>', dotAll: true)
          .allMatches(body)
          .map((match) => _stripHtml(match.group(1) ?? ''))
          .where((value) => value.isNotEmpty)
          .take(2)
          .toList();

      if (matches.isEmpty) return null;
      return matches.join(' | ');
    } catch (_) {
      return null;
    }
  }

  static String _stripHtml(String input) {
    return input
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

Map<String, dynamic> buildAssistantPayloadImpl({
  required String prompt,
  required List<Map<String, dynamic>> materials,
  required List<Map<String, dynamic>> studentMaterials,
  required bool allowWebSearch,
  List<Map<String, dynamic>> conversationHistory = const [],
  String? context,
  String? supplementalContext,
}) {
  final normalizedHistory = conversationHistory
      .where((entry) {
        final role = entry['role']?.toString().toLowerCase();
        return role == 'user' || role == 'assistant';
      })
      .map((entry) {
        final role = entry['role']?.toString().toLowerCase();
        final content = entry['content']?.toString() ?? '';
        return {
          'role': role ?? 'user',
          'content': content,
        };
      })
      .take(12)
      .toList();

  final normalizedMaterials = materials
      .where((material) {
        final classroomId = material['classroom_id']?.toString().trim();
        final materialId = material['material_id']?.toString().trim();
        return classroomId != null && classroomId.isNotEmpty && materialId != null && materialId.isNotEmpty;
      })
      .map((material) => {
            'classroom_id': material['classroom_id']?.toString(),
            'material_id': material['material_id']?.toString(),
            'classroom_name': material['classroom_name']?.toString(),
            'original_name': material['original_name']?.toString(),
            'mime_type': material['mime_type']?.toString(),
          })
      .toList();

  final normalizedStudentMaterials = studentMaterials
      .where((material) {
        final classroomId = material['classroom_id']?.toString().trim();
        final materialId = material['material_id']?.toString().trim();
        return classroomId != null && classroomId.isNotEmpty && materialId != null && materialId.isNotEmpty;
      })
      .map((material) => {
            'classroom_id': material['classroom_id']?.toString(),
            'material_id': material['material_id']?.toString(),
            'classroom_name': material['classroom_name']?.toString(),
            'original_name': material['original_name']?.toString(),
            'mime_type': material['mime_type']?.toString(),
          })
      .toList();

  return {
    'prompt': prompt.trim(),
    'materials': normalizedMaterials,
    'studentMaterials': normalizedStudentMaterials,
    'allowWebSearch': allowWebSearch,
    'conversationHistory': normalizedHistory,
    if (context != null && context.trim().isNotEmpty) 'context': context.trim(),
    if (supplementalContext != null && supplementalContext.trim().isNotEmpty) 'supplementalContext': supplementalContext.trim(),
  };
}

String buildAssistantContext(
  List<Map<String, dynamic>> materials, {
  List<Map<String, dynamic>> studentMaterials = const [],
}) {
  final allMaterials = <Map<String, dynamic>>[];
  allMaterials.addAll(materials);
  allMaterials.addAll(studentMaterials);

  debugPrint('[AI Helper Context] Total materials: ${allMaterials.length} (${materials.length} classroom + ${studentMaterials.length} student)');

  if (allMaterials.isEmpty) {
    debugPrint('[AI Helper Context] WARNING: No materials found!');
    return '''No classroom materials were found. Tell the student to open a room or upload materials first. If the user asks a question, say you cannot answer because no classroom materials are available yet.''';
  }

  final buffer = StringBuffer();
  buffer.writeln('Use only the classroom materials above. Do not invent facts.');
  buffer.writeln('Available materials:');
  for (final material in allMaterials) {
    final classroomName = material['classroom_name']?.toString() ?? 'Unknown classroom';
    final materialName = material['original_name']?.toString() ?? 'Untitled material';
    buffer.writeln('- $classroomName :: $materialName');
  }
  return buffer.toString();
}
