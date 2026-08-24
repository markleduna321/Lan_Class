import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../database/asura_repository.dart';
import '../../services/ai_assistant_service.dart';

class AiAssistantView extends StatefulWidget {
  const AiAssistantView({super.key});

  @override
  State<AiAssistantView> createState() => _AiAssistantViewState();
}

class _AiAssistantViewState extends State<AiAssistantView> {
  static const _storage = FlutterSecureStorage();
  static const _savedClassroomsKey = 'saved_classrooms_v2';
  static const List<int> _questionCountPresets = <int>[5, 10, 15, 20];

  final _controller = TextEditingController();
  final _questionCountController = TextEditingController();
  final List<_ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _allowWebSearch = false;
  String _apiKey = '';
  List<Map<String, dynamic>> _quizQuestions = const [];
  int _quizIndex = 0;
  String? _selectedOption;
  bool _showAnswer = false;
  bool _quizCompleted = false;
  int _score = 0;
  final List<bool> _answers = [];
  bool _showTopicPicker = false;
  bool _showSummaryPicker = false;
  bool _useAllTopics = true;
  final Set<String> _selectedTopics = <String>{};
  bool _useAllSummaryTopics = true;
  final Set<String> _selectedSummaryTopics = <String>{};
  List<String> _availableTopics = const [];
  Map<String, List<String>> _topicsByRoom = const {};
  bool _awaitingQuizResponse = false;
  String _pendingQuizTopic = 'all topics';
  int _pendingQuizQuestionCount = 5;
  int _selectedQuestionCount = 5;

  @override
  void initState() {
    super.initState();
    _messages.add(const _ChatMessage(
      text: 'I can help you study from the materials available in your joined classrooms. Ask me about a topic, a lecture, or a document summary.',
      isUser: false,
    ));
    _loadConfiguration();
  }

  @override
  void dispose() {
    _controller.dispose();
    _questionCountController.dispose();
    super.dispose();
  }

  Future<void> _loadConfiguration() async {
    final fallbackKey = await _storage.read(key: 'AI_API_KEY');
    if (mounted) {
      setState(() => _apiKey = fallbackKey ?? '');
    }
  }

  Future<void> _sendMessage({String? overridePrompt}) async {
    final prompt = (overridePrompt ?? _controller.text).trim();
    if (prompt.isEmpty || _isLoading) return;

    setState(() {
      _messages.add(_ChatMessage(text: prompt, isUser: true));
      _controller.clear();
      _isLoading = true;
    });

    final classrooms = await AsuraRepository.getAllClassrooms();
    final savedRooms = await _loadSavedRooms();
    if (classrooms.isEmpty) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No classrooms found. Please create or join a classroom first.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final materials = <Map<String, dynamic>>[];
    final studentMaterials = <Map<String, dynamic>>[];

    for (final classroom in classrooms) {
      final classroomId = classroom['id']?.toString();
      if (classroomId == null || classroomId.isEmpty) continue;
      // The backend resolves ids against ITS database — on synced devices the
      // local UUIDs differ from the server ids, so prefer remote ids.
      final classroomRemoteId =
          classroom['remote_id']?.toString().isNotEmpty == true
              ? classroom['remote_id'].toString()
              : classroomId;

      final classroomMaterials = await AsuraRepository.getMaterialsForClassroom(classroomId);
      for (final material in classroomMaterials) {
        final localMaterialId = material['id']?.toString() ?? '';
        final remoteMaterialId = material['remote_id']?.toString() ?? '';
        final materialSource = material['remote_url']?.toString() ??
            material['file_url']?.toString() ??
            material['url']?.toString() ??
            material['file_path']?.toString() ?? '';
        materials.add({
          'classroom_id': classroomRemoteId,
          'classroom_name': classroom['name']?.toString() ?? 'Classroom',
          'original_name': material['original_name']?.toString() ?? 'Material',
          'mime_type': material['mime_type']?.toString() ?? 'application/octet-stream',
          'material_id': remoteMaterialId.isNotEmpty ? remoteMaterialId : localMaterialId,
          'storage_path': material['file_path']?.toString() ?? material['storage_path']?.toString() ?? '',
          'download_url': materialSource,
        });
      }
    }

    for (final room in savedRooms) {
      final hostIp = room['ip']?.toString() ?? '';
      if (hostIp.isEmpty) continue;
      // Prefer the published room's server id so the backend can resolve it.
      final roomRemoteId = room['remoteId']?.toString().isNotEmpty == true
          ? room['remoteId'].toString()
          : (room['classroomId']?.toString().isNotEmpty == true
              ? room['classroomId'].toString()
              : hostIp);

      final studentMaterialRows = await AsuraRepository.getStudentMaterials(hostIp);
      for (final studentMaterial in studentMaterialRows) {
        final studentMaterialId = studentMaterial['id']?.toString();
        final localPath = studentMaterial['local_path']?.toString() ?? '';
        studentMaterials.add({
          'classroom_id': roomRemoteId,
          'classroom_name': room['roomName']?.toString().isNotEmpty == true
              ? room['roomName']?.toString()
              : 'Classroom',
          'original_name': studentMaterial['original_name']?.toString() ?? 'Material',
          'mime_type': studentMaterial['mime_type']?.toString() ?? 'application/octet-stream',
          'material_id': studentMaterialId ?? '',
          'storage_path': localPath,
          'download_url': localPath,
        });
      }
    }

    // Debug log for troubleshooting
    debugPrint('[AI Helper] Loaded ${materials.length} classroom materials + ${studentMaterials.length} student materials');
    for (final m in materials.take(5)) {
      debugPrint('[AI Helper] material "${m['original_name']}" — classroom_id=${m['classroom_id']}, material_id=${m['material_id']}');
    }

    final expectingQuizResponse = _awaitingQuizResponse;
    final reply = await AiAssistantService.sendMessage(
      prompt: prompt,
      apiKey: _apiKey,
      materials: materials,
      studentMaterials: studentMaterials,
      allowWebSearch: _allowWebSearch,
      conversationHistory: _messages
          .where((message) => !message.isUser || message.text.isNotEmpty)
          .map((message) => {
                'role': message.isUser ? 'user' : 'assistant',
                'content': message.text,
              })
          .toList(),
    );

    if (!mounted) return;
    final replyText = reply ?? 'I could not generate an answer. Please sign in and try again.';
    final parsedQuiz = expectingQuizResponse ? AiAssistantService.parseQuizPayload(replyText) : const <Map<String, dynamic>>[];

    // Debug logging for quiz parsing
    if (expectingQuizResponse) {
      debugPrint('[AI Helper] Quiz parsing: got ${parsedQuiz.length} questions from AI response');
    }

    setState(() {
      _isLoading = false;
      _awaitingQuizResponse = false;

      if (parsedQuiz.isNotEmpty) {
        final completedQuiz = _completeQuizQuestionSet(
          parsedQuiz,
          topic: _pendingQuizTopic,
          requestedCount: _pendingQuizQuestionCount,
        );

        _quizQuestions = completedQuiz;
        _quizIndex = 0;
        _selectedOption = null;
        _showAnswer = false;
        _quizCompleted = false;
        _score = 0;
        _answers.clear();
        _showTopicPicker = false;
        final supplemented = completedQuiz.length > parsedQuiz.length;
        _messages.add(_ChatMessage(
          text: supplemented
              ? 'Mock quiz is ready. The AI returned ${parsedQuiz.length} question(s), so I added local practice items to complete $_pendingQuizQuestionCount questions.'
              : 'Mock quiz is ready. Choose an answer and tap Answer to reveal the hint, then continue to Next.',
          isUser: false,
        ));
      } else if (expectingQuizResponse) {
        // Quiz was expected but parsing returned 0 questions
        // Try local fallback quiz regardless of AI response  
        debugPrint('[AI Helper] Quiz parsing failed, using local fallback');
        _quizQuestions = AiAssistantService.buildLocalMockQuiz(
          topic: _pendingQuizTopic,
          questionCount: _pendingQuizQuestionCount,
        );
        _quizIndex = 0;
        _selectedOption = null;
        _showAnswer = false;
        _quizCompleted = false;
        _score = 0;
        _answers.clear();
        _showTopicPicker = false;
        final reason = replyText.length > 140
            ? '${replyText.substring(0, 140)}…'
            : replyText;
        _messages.add(_ChatMessage(
          text: 'The AI reply could not be used ($reason). '
              'I started a local practice quiz with ${_quizQuestions.length} questions on $_pendingQuizTopic instead.',
          isUser: false,
        ));
      } else {
        // Not a quiz request, just show the AI response
        _messages.add(_ChatMessage(
          text: replyText,
          isUser: false,
        ));
      }
    });
  }

  Future<List<Map<String, dynamic>>> _loadSavedRooms() async {
    final raw = await _storage.read(key: _savedClassroomsKey);
    if (raw == null || raw.isEmpty) return const <Map<String, dynamic>>[];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  List<Map<String, dynamic>> _completeQuizQuestionSet(
    List<Map<String, dynamic>> baseQuiz, {
    required String topic,
    required int requestedCount,
  }) {
    if (requestedCount <= 0) return baseQuiz;
    if (baseQuiz.length >= requestedCount) {
      return baseQuiz.take(requestedCount).toList();
    }

    final needed = requestedCount - baseQuiz.length;
    final localFill = AiAssistantService.buildLocalMockQuiz(
      topic: topic,
      questionCount: requestedCount,
    );

    final existingQuestions = baseQuiz
        .map((q) => (q['question']?.toString().trim().toLowerCase() ?? ''))
        .where((q) => q.isNotEmpty)
        .toSet();

    final extras = <Map<String, dynamic>>[];
    for (final item in localFill) {
      final key = item['question']?.toString().trim().toLowerCase() ?? '';
      if (key.isEmpty || existingQuestions.contains(key)) continue;
      extras.add(item);
      if (extras.length >= needed) break;
    }

    final combined = <Map<String, dynamic>>[];
    combined.addAll(baseQuiz);
    combined.addAll(extras);
    return combined.take(requestedCount).toList();
  }

  Future<void> _handleQuickAction(String action) async {
    if (_isLoading) return;

    final topics = await _loadAvailableTopics();

    if (action.toLowerCase() == 'quiz') {
      if (!mounted) return;
      setState(() {
        _showSummaryPicker = false;
        _showTopicPicker = true;
        _availableTopics = topics;
        _useAllTopics = true;
        _selectedTopics.clear();
        _selectedQuestionCount = 5;
        _questionCountController.clear();
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _showTopicPicker = false;
      _showSummaryPicker = true;
      _availableTopics = topics;
      _useAllSummaryTopics = true;
      _selectedSummaryTopics.clear();
    });
  }

  Future<List<String>> _loadAvailableTopics() async {
    final classrooms = await AsuraRepository.getAllClassrooms();
    final savedRooms = await _loadSavedRooms();
    final byRoom = <String, Set<String>>{};

    for (final classroom in classrooms) {
      final classroomId = classroom['id']?.toString();
      if (classroomId == null || classroomId.isEmpty) continue;
      final roomName = classroom['name']?.toString().trim().isNotEmpty == true
          ? classroom['name'].toString().trim()
          : 'Classroom';

      final materials = await AsuraRepository.getMaterialsForClassroom(classroomId);
      for (final material in materials) {
        final name = material['original_name']?.toString().trim();
        if (name != null && name.isNotEmpty) {
          byRoom.putIfAbsent(roomName, () => <String>{}).add(name);
        }
      }
    }

    for (final room in savedRooms) {
      final hostIp = room['ip']?.toString() ?? '';
      if (hostIp.isEmpty) continue;
      final roomName = room['roomName']?.toString().trim().isNotEmpty == true
          ? room['roomName'].toString().trim()
          : 'Joined Room';

      final studentMaterials = await AsuraRepository.getStudentMaterials(hostIp);
      for (final studentMaterial in studentMaterials) {
        final name = studentMaterial['original_name']?.toString().trim();
        if (name != null && name.isNotEmpty) {
          byRoom.putIfAbsent(roomName, () => <String>{}).add(name);
        }
      }
    }

    final grouped = <String, List<String>>{
      for (final entry in byRoom.entries) entry.key: entry.value.toList()..sort(),
    };
    if (mounted) {
      setState(() => _topicsByRoom = grouped);
    } else {
      _topicsByRoom = grouped;
    }

    final flat = byRoom.values.expand((names) => names).toSet().toList()..sort();
    return flat;
  }

  /// Topics grouped into per-room expandable folders so long material lists
  /// stay navigable.
  Widget _buildRoomTopicFolders({
    required Set<String> selected,
    required void Function(String topic, bool selected) onToggle,
  }) {
    if (_topicsByRoom.isEmpty) {
      return Text('No materials found yet.',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 13));
    }
    final roomNames = _topicsByRoom.keys.toList()..sort();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: roomNames.map((room) {
        final topics = _topicsByRoom[room] ?? const [];
        final selectedInRoom = topics.where(selected.contains).length;
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              leading: const Icon(Icons.folder, color: Color(0xFF1E3A8A), size: 20),
              title: Text(room,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: Text(
                selectedInRoom > 0
                    ? '${topics.length} material(s) • $selectedInRoom selected'
                    : '${topics.length} material(s)',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: topics
                      .map((topic) => FilterChip(
                            label: Text(topic,
                                style: const TextStyle(fontSize: 12)),
                            selected: selected.contains(topic),
                            onSelected: (value) => onToggle(topic, value),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _launchSummary() async {
    if (_isLoading) return;
    final hasSelection = _useAllSummaryTopics || _selectedSummaryTopics.isNotEmpty;
    if (!hasSelection) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at least one material or choose All topics.')),
      );
      return;
    }

    final selected = _useAllSummaryTopics
        ? _availableTopics
        : (_selectedSummaryTopics.toList()..sort());

    setState(() => _showSummaryPicker = false);

    final prompt = _useAllSummaryTopics
        ? 'Summarize the most important points from all available materials.'
        : 'Summarize these materials only: ${selected.join(', ')}. Focus on key concepts, definitions, and likely quiz points.';
    await _sendMessage(overridePrompt: prompt);
  }

  Future<void> _launchMockQuiz() async {
    if (_isLoading) return;

    final customCount = int.tryParse(_questionCountController.text.trim());
    final requestedCount = customCount != null && customCount > 0 ? customCount : _selectedQuestionCount;
    final clampedCount = requestedCount.clamp(1, 30);
    final hasTopicSelection = _useAllTopics || _selectedTopics.isNotEmpty;
    if (!hasTopicSelection) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at least one topic or choose All topics.')),
      );
      return;
    }

    final selectedTopicList = _useAllTopics
        ? _availableTopics
        : _selectedTopics.toList()..sort();
    final topicSummary = _useAllTopics
        ? 'all topics'
        : selectedTopicList.join(', ');

    setState(() {
      _showTopicPicker = false;
      _awaitingQuizResponse = true;
      _pendingQuizTopic = topicSummary;
      _pendingQuizQuestionCount = clampedCount;
      _quizQuestions = const [];
      _quizIndex = 0;
      _selectedOption = null;
      _showAnswer = false;
      _quizCompleted = false;
      _score = 0;
      _answers.clear();
    });

    final topicPrompt = _useAllTopics
        ? 'Create a $clampedCount-question multiple-choice mock quiz covering all available materials. Return ONLY JSON with this exact shape: {"questions":[{"question":"...","options":["...","...","...","..."],"correctAnswer":"...","hint":"...","explanation":"..."}]}. Use real question text and never use placeholder ellipses.'
        : 'Create a $clampedCount-question multiple-choice mock quiz focused on these topics: ${selectedTopicList.join(', ')}. Return ONLY JSON with this exact shape: {"questions":[{"question":"...","options":["...","...","...","..."],"correctAnswer":"...","hint":"...","explanation":"..."}]}. Use real question text and never use placeholder ellipses.';

    await _sendMessage(overridePrompt: topicPrompt);
  }

  void _selectOption(String option) {
    if (_showAnswer) return;
    setState(() => _selectedOption = option);
  }

  void _revealAnswer() {
    if (_selectedOption == null || _showAnswer) return;

    final question = _quizQuestions[_quizIndex];
    final correctAnswer = question['correctAnswer']?.toString() ?? '';
    final isCorrect = _selectedOption == correctAnswer;

    setState(() {
      _showAnswer = true;
      if (isCorrect) {
        _score += 1;
      }
      _answers.add(isCorrect);
    });
  }

  void _goToNextQuestion() {
    if (_quizIndex + 1 >= _quizQuestions.length) {
      setState(() {
        _quizCompleted = true;
        _selectedOption = null;
        _showAnswer = false;
      });
      return;
    }

    setState(() {
      _quizIndex += 1;
      _selectedOption = null;
      _showAnswer = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'AI Helper',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch.adaptive(
                        value: _allowWebSearch,
                        onChanged: (value) => setState(() => _allowWebSearch = value),
                      ),
                      const SizedBox(width: 4),
                      const Text('Broader web search'),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return Align(
                    alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.all(12),
                      constraints: const BoxConstraints(maxWidth: 720),
                      decoration: BoxDecoration(
                        color: message.isUser ? const Color(0xFF1E3A8A) : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        message.text,
                        style: TextStyle(color: message.isUser ? Colors.white : Colors.black87),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_showTopicPicker)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.all(14),
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.55,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: SingleChildScrollView(
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Choose quiz scope', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 6),
                    const Text('Select all topics or choose one or more specific topics.'),
                    const SizedBox(height: 10),
                    FilterChip(
                      label: const Text('All topics'),
                      selected: _useAllTopics,
                      onSelected: (selected) {
                        setState(() {
                          _useAllTopics = selected;
                          if (selected) {
                            _selectedTopics.clear();
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    _buildRoomTopicFolders(
                      selected: _selectedTopics,
                      onToggle: (topic, selected) {
                        setState(() {
                          _useAllTopics = false;
                          if (selected) {
                            _selectedTopics.add(topic);
                          } else {
                            _selectedTopics.remove(topic);
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    const Text('Question count', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _questionCountPresets
                          .map((count) => ChoiceChip(
                                label: Text('$count'),
                                selected: _selectedQuestionCount == count,
                                onSelected: (_) {
                                  setState(() {
                                    _selectedQuestionCount = count;
                                    _questionCountController.clear();
                                  });
                                },
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _questionCountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Or enter custom count (1-30)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _launchMockQuiz,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Start progressive quiz'),
                    ),
                  ],
                  ),
                ),
              ),
            if (_showSummaryPicker)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.all(14),
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.55,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: SingleChildScrollView(
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Choose summary scope', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 6),
                    const Text('Select all materials or choose one or more specific materials.'),
                    const SizedBox(height: 10),
                    FilterChip(
                      label: const Text('All topics'),
                      selected: _useAllSummaryTopics,
                      onSelected: (selected) {
                        setState(() {
                          _useAllSummaryTopics = selected;
                          if (selected) {
                            _selectedSummaryTopics.clear();
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    _buildRoomTopicFolders(
                      selected: _selectedSummaryTopics,
                      onToggle: (topic, selected) {
                        setState(() {
                          _useAllSummaryTopics = false;
                          if (selected) {
                            _selectedSummaryTopics.add(topic);
                          } else {
                            _selectedSummaryTopics.remove(topic);
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _launchSummary,
                      icon: const Icon(Icons.summarize),
                      label: const Text('Generate summary'),
                    ),
                  ],
                  ),
                ),
              ),
            if (_quizQuestions.isNotEmpty && _quizCompleted)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF3),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.green.shade300),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Quiz complete', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 6),
                    Text('You scored $_score out of ${_quizQuestions.length}.', style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 6),
                    Text(
                      'Correct answers: ${_answers.where((answer) => answer).length} • Incorrect answers: ${_answers.where((answer) => !answer).length}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: () => setState(() {
                            _quizCompleted = false;
                            _quizIndex = 0;
                            _selectedOption = null;
                            _showAnswer = false;
                            _score = 0;
                            _answers.clear();
                          }),
                          child: const Text('Try again'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => setState(() {
                            _quizQuestions = const [];
                            _quizCompleted = false;
                            _quizIndex = 0;
                            _selectedOption = null;
                            _showAnswer = false;
                            _score = 0;
                            _answers.clear();
                          }),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (_quizQuestions.isNotEmpty && !_quizCompleted)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Question ${_quizIndex + 1} of ${_quizQuestions.length}',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE0F2FE),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text('Score $_score'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _quizQuestions[_quizIndex]['question']?.toString() ?? '',
                          style: const TextStyle(fontSize: 15),
                        ),
                        const SizedBox(height: 8),
                        ...((_quizQuestions[_quizIndex]['options'] as List?) ?? []).map((option) {
                          final optionText = option.toString();
                          final isSelected = _selectedOption == optionText;
                          final correctAnswer =
                              _quizQuestions[_quizIndex]['correctAnswer']?.toString() ?? '';
                          final isCorrectOption = optionText == correctAnswer;

                          // After reveal: correct option green, wrong selection red.
                          Color? background;
                          Color border = Colors.grey.shade400;
                          if (_showAnswer && isCorrectOption) {
                            background = const Color(0xFFDCFCE7);
                            border = const Color(0xFF16A34A);
                          } else if (_showAnswer && isSelected && !isCorrectOption) {
                            background = const Color(0xFFFEE2E2);
                            border = const Color(0xFFDC2626);
                          } else if (isSelected) {
                            background = const Color(0xFFDBEAFE);
                            border = const Color(0xFF2563EB);
                          }

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                backgroundColor: background,
                                disabledBackgroundColor: background,
                                side: BorderSide(color: border),
                              ),
                              onPressed: _showAnswer ? null : () => _selectOption(optionText),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(optionText,
                                          style: TextStyle(
                                              color: _showAnswer
                                                  ? Colors.black87
                                                  : null)),
                                    ),
                                    if (_showAnswer && isCorrectOption)
                                      const Icon(Icons.check_circle,
                                          size: 18, color: Color(0xFF16A34A)),
                                    if (_showAnswer && isSelected && !isCorrectOption)
                                      const Icon(Icons.cancel,
                                          size: 18, color: Color(0xFFDC2626)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }),
                        if (_selectedOption != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_showAnswer)
                                  Builder(builder: (context) {
                                    final correct = _selectedOption ==
                                        (_quizQuestions[_quizIndex]['correctAnswer']?.toString() ?? '');
                                    return Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: correct
                                            ? const Color(0xFFECFDF3)
                                            : const Color(0xFFFEF2F2),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                            color: correct
                                                ? const Color(0xFF86EFAC)
                                                : const Color(0xFFFECACA)),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(
                                                  correct
                                                      ? Icons.check_circle
                                                      : Icons.cancel,
                                                  size: 16,
                                                  color: correct
                                                      ? const Color(0xFF16A34A)
                                                      : const Color(0xFFDC2626)),
                                              const SizedBox(width: 6),
                                              Text(correct ? 'Correct!' : 'Incorrect',
                                                  style: TextStyle(
                                                      fontWeight: FontWeight.w700,
                                                      color: correct
                                                          ? const Color(0xFF166534)
                                                          : const Color(0xFF991B1B))),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            'Correct answer: ${_quizQuestions[_quizIndex]['correctAnswer']?.toString() ?? ''}',
                                            style: const TextStyle(fontWeight: FontWeight.w700),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(_quizQuestions[_quizIndex]['hint']?.toString() ?? ''),
                                          const SizedBox(height: 4),
                                          Text(_quizQuestions[_quizIndex]['explanation']?.toString() ?? ''),
                                        ],
                                      ),
                                    );
                                  }),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    FilledButton(
                                      onPressed: _showAnswer
                                          ? _goToNextQuestion
                                          : (_selectedOption == null ? null : _revealAnswer),
                                      child: Text(_showAnswer ? 'Next' : 'Answer'),
                                    ),
                                    const SizedBox(width: 8),
                                    if (_showAnswer)
                                      TextButton(
                                        onPressed: _goToNextQuestion,
                                        child: const Text('Skip'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: CircularProgressIndicator(),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Ask about the topic or materials in your joined rooms',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    enabled: !_isLoading,
                    tooltip: 'Quick actions',
                    onSelected: _handleQuickAction,
                    itemBuilder: (context) => const [
                      PopupMenuItem<String>(
                        value: 'summary',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.summarize),
                          title: Text('Summary'),
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'quiz',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.quiz_rounded),
                          title: Text('Mock Test'),
                        ),
                      ),
                    ],
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEF2FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: const Icon(Icons.add, color: Color(0xFF1E3A8A)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _isLoading ? null : _sendMessage,
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMessage {
  final String text;
  final bool isUser;

  const _ChatMessage({required this.text, required this.isUser});
}
