// lib/features/online/online_session_view.dart
//
// Online Session View (non-video)
// Keeps quiz/chat/hand-raise controls and session events.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../database/asura_repository.dart';
import '../../services/online_session_service.dart';
import 'online_quiz_player_view.dart';
import 'session_chat_panel.dart';

class OnlineSessionView extends StatefulWidget {
  final String sessionId;
  final String classroomName;
  final bool isTeacher;
  final String myId;
  final String myName;

  /// Teacher only: local classroom ID used to load quizzes from SQLite.
  final String classroomId;

  const OnlineSessionView({
    super.key,
    required this.sessionId,
    required this.classroomName,
    required this.isTeacher,
    required this.myId,
    required this.myName,
    this.classroomId = '',
  });

  @override
  State<OnlineSessionView> createState() => _OnlineSessionViewState();
}

class _OnlineSessionViewState extends State<OnlineSessionView> {
  // ── Subscriptions ────────────────────────────────────────────────────────
  StreamSubscription<Map<String, dynamic>>? _sigSub;

  // ── Loading / error state ─────────────────────────────────────────────────
  bool _joining = true;
  String? _errorMessage;

  // ── Quiz (teacher) ────────────────────────────────────────────────────────
  bool _quizActive    = false;
  bool _quizBusy      = false;

  // ── Hand-raise ────────────────────────────────────────────────────────────
  bool _handRaised = false;
  bool _handBusy   = false;
  bool _calledOn   = false;
  bool _showHands  = false;
  final List<Map<String, dynamic>> _handQueue = [];

  // ── Chat ──────────────────────────────────────────────────────────────────
  bool _showChat = false;

  // ── Phase 8 hybrid ────────────────────────────────────────────────────────
  int _lanParticipantCount = 0;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // 1. Subscribe to Reverb session events (quiz, hand, chat, end)
    _sigSub = OnlineSessionService.instance.eventStream
        .listen(_handleSessionEvent);

    // 2. Touch join endpoint so backend registers participant/session state.
    final joinData =
        await OnlineSessionService.joinSession(widget.sessionId);
    if (!mounted) return;

    if (joinData == null) {
      setState(() {
        _joining = false;
        _errorMessage =
            'Could not load session info.\nCheck your connection and try again.';
      });
      return;
    }

    setState(() => _joining = false);
  }

  // ── Session event handler ─────────────────────────────────────────────────

  void _handleSessionEvent(Map<String, dynamic> event) async {
    if (!mounted) return;
    final type = event['event'] as String? ?? '';

    // Legacy signaling events are ignored in non-video mode.
    if (type.startsWith('WEBRTC_') || type == 'MUTE_COMMAND') return;

    switch (type) {
      case 'VIDEO_SESSION_ENDED':
        if (!widget.isTeacher && mounted) Navigator.pop(context);

      case 'QUIZ_START':
        if (!widget.isTeacher && mounted && !_quizActive) {
          _quizActive = true;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => OnlineQuizPlayerView(
                sessionId:         widget.sessionId,
                classroomRemoteId: widget.sessionId,
                studentId:         widget.myId,
                studentName:       widget.myName,
                quizData:          event,
              ),
            ),
          );
          if (mounted) setState(() => _quizActive = false);
        } else if (widget.isTeacher && mounted) {
          setState(() {
            _quizActive = true;
          });
        }

      case 'QUIZ_ENDED':
        if (mounted) {
          setState(() {
            _quizActive = false;
          });
        }

      case 'HAND_UPDATE':
        if (widget.isTeacher && mounted) {
          final queue = (event['queue'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          setState(() {
            _handQueue
              ..clear()
              ..addAll(queue);
          });
        }

      case 'CALLED_ON':
        if (!widget.isTeacher && mounted) {
          setState(() {
            _calledOn   = true;
            _handRaised = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('The teacher has called on you!'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 4),
            ),
          );
        }

      case 'PARTICIPANT_UPDATE':
        final source = event['source'] as String?;
        if (source == 'lan' && widget.isTeacher && mounted) {
          setState(() => _lanParticipantCount =
              (event['total_lan'] as int?) ?? _lanParticipantCount);
        }
    }
  }

  // ── Hand raise (student) ──────────────────────────────────────────────────

  Future<void> _toggleHand() async {
    if (_handBusy) return;
    setState(() => _handBusy = true);
    final raised = !_handRaised;
    final ok = raised
        ? await OnlineSessionService.raiseHand(
            widget.sessionId, widget.myId, widget.myName)
        : await OnlineSessionService.lowerHand(
            widget.sessionId, widget.myId);
    if (mounted) {
      setState(() {
        if (ok) _handRaised = raised;
        _handBusy = false;
        if (ok && raised) _calledOn = false;
      });
    }
  }

  // ── Call on student (teacher) ─────────────────────────────────────────────

  Future<void> _callOn(String studentId) async {
    await OnlineSessionService.callOnStudent(widget.sessionId, studentId);
    if (mounted) {
      setState(() {
        _handQueue.removeWhere((e) => e['id'] == studentId);
        if (_handQueue.isEmpty) _showHands = false;
      });
    }
  }

  // ── Quiz (teacher) ────────────────────────────────────────────────────────

  Future<void> _showQuizPicker() async {
    if (widget.classroomId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Open the video session from the dashboard to launch quizzes.')),
      );
      return;
    }

    setState(() => _quizBusy = true);
    final quizzes = await AsuraRepository.getRoomQuizzesForClassroom(
        widget.classroomId);
    setState(() => _quizBusy = false);
    if (!mounted) return;

    if (quizzes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No quizzes found for this classroom.')),
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        minChildSize: 0.3,
        expand: false,
        builder: (_, scroll) => Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('Launch a Quiz',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: quizzes.length,
                itemBuilder: (_, i) {
                  final q = quizzes[i];
                  return ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFF1E3A8A),
                      child:
                          Icon(Icons.quiz, color: Colors.white, size: 18),
                    ),
                    title: Text(q['title'] as String? ?? 'Quiz'),
                    subtitle: Text(q['description'] as String? ?? ''),
                    trailing: const Icon(Icons.send, size: 18),
                    onTap: () {
                      Navigator.pop(ctx);
                      _launchQuiz(q);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchQuiz(Map<String, dynamic> quiz) async {
    setState(() => _quizBusy = true);
    final questions =
        await AsuraRepository.getRoomQuizQuestions(quiz['id'] as String);
    setState(() => _quizBusy = false);

    // Correct answers are withheld so students cannot read them from the payload.
    final quizData = {
      'quiz_id':   quiz['id'],
      'title':     quiz['title'],
      'questions': questions
          .map((q) => {
                'id':      q['id'],
                'text':    q['question_text'] ?? '',
                'type':    q['question_type'] ?? 'multiple_choice',
                'options': q['options'] is String
                    ? jsonDecode(q['options'] as String)
                    : q['options'],
                'points':  q['points'] ?? 1,
              })
          .toList(),
    };

    await OnlineSessionService.broadcastEvent(
        widget.sessionId, 'QUIZ_START', quizData);

    if (mounted) {
      setState(() {
        _quizActive = true;
      });
    }
  }

  Future<void> _endQuiz() async {
    await OnlineSessionService.broadcastEvent(
        widget.sessionId, 'QUIZ_ENDED', {});
    if (mounted) {
      setState(() {
        _quizActive = false;
      });
    }
  }

  // ── Leave ─────────────────────────────────────────────────────────────────

  Future<void> _leave() async {
    if (widget.isTeacher) {
      await OnlineSessionService.broadcastEvent(
          widget.sessionId,
          'VIDEO_SESSION_ENDED',
          {'sessionId': widget.sessionId});
    }
    if (mounted) Navigator.pop(context);
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _sigSub?.cancel();
    super.dispose();
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_joining) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 20),
              Text(
                'Joining ${widget.classroomName}\u2026',
                style: const TextStyle(
                    color: Colors.white60, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          title: Text(widget.classroomName),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_off, color: Colors.red, size: 60),
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Go Back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.grey.shade900,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.classroomName,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold)),
            Text(
              widget.isTeacher
                  ? 'Video Session \u2014 Broadcasting'
                  : 'Video Session',
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
          ],
        ),
        actions: [
          // Teacher: raised-hand queue button
          if (widget.isTeacher)
            Stack(
              alignment: Alignment.topRight,
              children: [
                IconButton(
                  onPressed: () =>
                      setState(() => _showHands = !_showHands),
                  icon: Icon(
                    Icons.pan_tool,
                    color: _handQueue.isNotEmpty
                        ? Colors.amber
                        : (_showHands ? Colors.amber : Colors.white60),
                  ),
                ),
                if (_handQueue.isNotEmpty)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      child: Text(
                        '${_handQueue.length}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
              ],
            ),

          // Chat toggle
          IconButton(
            onPressed: () =>
                setState(() => _showChat = !_showChat),
            icon: Icon(
              _showChat ? Icons.chat : Icons.chat_bubble_outline,
              color: _showChat ? Colors.amber : Colors.white70,
            ),
          ),

          // Leave / End button
          TextButton.icon(
            onPressed: _leave,
            icon: Icon(
              widget.isTeacher ? Icons.stop_circle : Icons.logout,
              color: Colors.red.shade400,
              size: 18,
            ),
            label: Text(
              widget.isTeacher ? 'End Video' : 'Leave',
              style: TextStyle(
                  color: Colors.red.shade400, fontSize: 13),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildInMeetingBody(),

          // Teacher: raised-hand queue panel
          if (widget.isTeacher && _showHands)
            Positioned(
              top: 0, right: 0, bottom: 0, width: 220,
              child: _buildHandsPanel(),
            ),

          // Student: called-on banner
          if (!widget.isTeacher && _calledOn)
            Positioned(
              top: 12, left: 16, right: 16,
              child: Material(
                color: Colors.green.shade700,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.record_voice_over,
                          color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'You have been called on \u2014 speak now!',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      GestureDetector(
                        onTap: () =>
                            setState(() => _calledOn = false),
                        child: const Icon(Icons.close,
                            color: Colors.white70, size: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Chat panel overlay
          if (_showChat)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: MediaQuery.of(context).size.height * 0.55,
              child: SessionChatPanel(
                sessionId: widget.sessionId,
                myId:      widget.myId,
                myName:    widget.myName,
                isTeacher: widget.isTeacher,
                onClose:   () => setState(() => _showChat = false),
              ),
            ),
        ],
      ),
    );
  }

  // ── In-meeting body ───────────────────────────────────────────────────────

  Widget _buildInMeetingBody() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.video_call, color: Colors.white24, size: 72),
          const SizedBox(height: 16),
          const Text(
            'Meeting in progress',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            widget.classroomName,
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
          if (widget.isTeacher) ...[
            if (_lanParticipantCount > 0) ...[
              const SizedBox(height: 4),
              Text(
                '$_lanParticipantCount LAN '
                'student${_lanParticipantCount > 1 ? 's' : ''} connected',
                style: const TextStyle(
                    color: Colors.white38, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            if (_quizActive)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      Colors.orange.withValues(alpha: 0.15),
                  border:
                      Border.all(color: Colors.orange, width: 1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.quiz,
                        color: Colors.orange, size: 18),
                    const SizedBox(width: 8),
                    const Text('Quiz active',
                        style: TextStyle(
                            color: Colors.orange, fontSize: 13)),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: _endQuiz,
                      child: const Text('End Quiz',
                          style: TextStyle(color: Colors.orange)),
                    ),
                  ],
                ),
              )
            else
              OutlinedButton.icon(
                onPressed: _quizBusy ? null : _showQuizPicker,
                icon: _quizBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            color: Colors.white54, strokeWidth: 2))
                    : const Icon(Icons.quiz_outlined, size: 16),
                label: const Text('Launch Quiz'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white30),
                ),
              ),
          ] else ...[
            // Student: hand raise
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _handBusy ? null : _toggleHand,
              icon: Icon(
                _handRaised
                    ? Icons.front_hand
                    : Icons.front_hand_outlined,
                size: 16,
                color: _handRaised ? Colors.amber : Colors.white60,
              ),
              label: Text(
                _handRaised ? 'Lower Hand' : 'Raise Hand',
                style: TextStyle(
                    color:
                        _handRaised ? Colors.amber : Colors.white60),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                    color: _handRaised
                        ? Colors.amber
                        : Colors.white30),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Hands panel (teacher) ─────────────────────────────────────────────────

  Widget _buildHandsPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        border: const Border(
            left: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 8),
            child: Row(
              children: [
                const Icon(Icons.pan_tool,
                    color: Colors.amber, size: 16),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('Hand Queue',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13)),
                ),
                IconButton(
                  onPressed: () =>
                      setState(() => _showHands = false),
                  icon: const Icon(Icons.close,
                      color: Colors.white54, size: 18),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          if (_handQueue.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No hands raised.',
                  style: TextStyle(
                      color: Colors.white38, fontSize: 12)),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _handQueue.length,
                itemBuilder: (_, i) {
                  final student = _handQueue[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.pan_tool,
                        color: Colors.amber, size: 18),
                    title: Text(
                      student['name'] as String? ?? 'Student',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13),
                    ),
                    trailing: TextButton(
                      onPressed: () => _callOn(
                          student['id'] as String? ?? ''),
                      child: const Text('Call',
                          style: TextStyle(fontSize: 12)),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}