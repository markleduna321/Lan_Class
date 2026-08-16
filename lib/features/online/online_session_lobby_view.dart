// lib/features/online/online_session_lobby_view.dart
//
// Phase 4 — Online Session Lobby (Student)
// Mirrors StudentLobbyView but connects via Reverb WebSocket instead of LAN.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../../database/asura_repository.dart';
import '../../services/cloud_api_service.dart';
import '../../services/online_session_service.dart';
import 'online_quiz_player_view.dart';
import 'online_session_view.dart';
import 'room_join_utils.dart';
import 'session_chat_panel.dart';

enum _SessionState { joining, active, ended, offline }

class OnlineSessionLobbyView extends StatefulWidget {
  final String classroomRemoteId;
  final String classroomName;
  final String sessionId; // empty string = no active session (browse-only mode)

  const OnlineSessionLobbyView({
    super.key,
    required this.classroomRemoteId,
    required this.classroomName,
    this.sessionId = '',
  });

  @override
  State<OnlineSessionLobbyView> createState() => _OnlineSessionLobbyViewState();
}

class _OnlineSessionLobbyViewState extends State<OnlineSessionLobbyView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  _SessionState _sessionState = _SessionState.joining;
  Timer? _pollTimer;
  bool _viewerActive = false;
  bool _presentationActive = false; // a presentation viewer route is on top
  String _studentName = 'Student';
  String _studentId   = '';
  List<Map<String, dynamic>> _materials = [];
  List<Map<String, dynamic>> _quizResults = [];
  bool _dataLoaded = false;

  // Chat state (Phase 6)
  bool _showChat = false;

  // Raise hand state (Phase 7)
  bool _handRaised  = false;
  bool _handBusy    = false;
  bool _calledOn    = false;

  // Active quiz from polling
  Map<String, dynamic>? _currentQuiz;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _init();
  }

  Future<void> _init() async {
    const storage = FlutterSecureStorage();
    _studentName = await storage.read(key: 'ACTIVE_USER_NAME') ?? 'Student';
    _studentId   = await storage.read(key: 'ONLINE_USER_ID') ?? _studentName;
    await _joinRoomAndLoadMaterials();
    _loadQuizResults();
    if (widget.sessionId.isNotEmpty) {
      _startPolling();
    } else {
      // Opened without an active session — browse materials and past results.
      if (mounted) setState(() => _sessionState = _SessionState.offline);
    }
  }

  Future<void> _joinRoomAndLoadMaterials() async {
    if (!mounted) return;

    final joinResponse = await CloudApiService.post(
      '/api/classrooms/${widget.classroomRemoteId}/join',
      {},
    );

    if (!mounted) return;

    if (joinResponse != null && joinResponse.statusCode == 200) {
      final session = parseJoinedSessionPayload(joinResponse.body);
      if (session != null && session['id'] != null) {
        if (mounted) {
          setState(() {
            _sessionState = _SessionState.active;
            _dataLoaded = false;
          });
        }
      }
    }

    await _loadMaterials();
  }

  Future<void> _loadMaterials() async {
    final response = await CloudApiService.get(
        '/api/classrooms/${widget.classroomRemoteId}/materials');
    if (!mounted) return;
    if (response != null && response.statusCode == 200) {
      try {
        final decoded = jsonDecode(response.body);
        final List<dynamic> raw =
            decoded is List ? decoded : (decoded['data'] as List? ?? []);
        setState(() {
          _materials = raw.cast<Map<String, dynamic>>();
          _dataLoaded = true;
        });
      } catch (_) {}
    } else {
      setState(() => _dataLoaded = true);
    }
  }

  Future<void> _loadQuizResults() async {
    // Load locally stored quiz results associated with this online session
    // (reuses the same table as LAN — online quiz player also stores locally)
    final results = await AsuraRepository.getStudentQuizResultsByHost(
        'online:${widget.classroomRemoteId}', widget.classroomRemoteId);
    if (mounted) setState(() => _quizResults = results);
  }

  void _startPolling() {
    _poll(); // immediate first check
    _pollTimer = Timer.periodic(const Duration(seconds: 6), (_) => _poll());
  }

  Future<void> _poll() async {
    if (!mounted) return;
    // Use the public active-session endpoint — works without auth for students.
    // GET /api/sessions/{id} is teacher-only (Protected).
    final response = await CloudApiService.get(
        '/api/classrooms/${widget.classroomRemoteId}/active-session');
    if (!mounted) return;

    if (response == null) return; // network error — keep polling

    if (response.statusCode == 404 || response.statusCode == 410) {
      // No active session for this classroom — teacher ended the session.
      // 404 = not found, 410 = gone (session was deleted)
      if (mounted) setState(() => _sessionState = _SessionState.ended);
      _pollTimer?.cancel();
      return;
    }

    if (response.statusCode != 200) return;

    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      // Unwrap {"session": {...}} envelope if present
      data = (decoded['session'] as Map<String, dynamic>?) ?? decoded;
    } catch (_) {
      return;
    }

    final status = data['status'] as String? ?? 'active';
    if (status == 'ended' || status == 'closed') {
      // Session was explicitly ended or marked as closed
      if (mounted) setState(() => _sessionState = _SessionState.ended);
      _pollTimer?.cancel();
      return;
    }

    if (mounted && _sessionState != _SessionState.active) {
      setState(() => _sessionState = _SessionState.active);
    }

    // Check for active quiz broadcast. The broadcast payload identifies the
    // quiz by `quiz_id` (not `id`), so normalise before comparing.
    final quiz = data['current_quiz'] as Map<String, dynamic>?
        ?? data['active_quiz'] as Map<String, dynamic>?;
    final quizId    = quiz?['quiz_id'] ?? quiz?['id'];
    final currentId = _currentQuiz?['quiz_id'] ?? _currentQuiz?['id'];
    if (quiz != null && quizId != currentId && !_viewerActive) {
      setState(() => _currentQuiz = quiz);
      _navigateToQuiz(quiz);
    } else if (quiz == null && _currentQuiz != null) {
      if (mounted) setState(() => _currentQuiz = null);
    }

    // Check for active slide/presentation broadcast.
    final slide = data['current_slide'] as Map<String, dynamic>?
        ?? data['current_file'] as Map<String, dynamic>?;
    if (slide != null && !_viewerActive) {
      _navigateToViewer(slide);
    } else if (slide == null && _presentationActive && mounted) {
      // Teacher stopped presenting — close the presentation viewer so the
      // student returns to the lobby instead of getting stuck on the slide.
      _presentationActive = false;
      // Safely pop only if there are routes in the stack
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  // ── Raise Hand (Phase 7) ──────────────────────────────────────────────────

  Future<void> _toggleHand() async {
    if (_handBusy) return;
    setState(() => _handBusy = true);
    final myKey = _studentId.isNotEmpty ? _studentId : _studentName;
    final raised = !_handRaised;
    bool ok;
    if (raised) {
      ok = await OnlineSessionService.raiseHand(
          widget.sessionId, myKey, _studentName);
    } else {
      ok = await OnlineSessionService.lowerHand(widget.sessionId, myKey);
    }
    if (mounted) {
      setState(() {
        if (ok) {
          _handRaised = raised;
          if (raised) _calledOn = false;
        }
        _handBusy = false;
      });
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  Future<void> _navigateToViewer(Map<String, dynamic> fileData) async {
    if (_viewerActive) return;
    _viewerActive = true;

    final url   = (fileData['url'] as String?) ??
        (fileData['file_url'] as String?) ?? '';
    final title = (fileData['filename'] as String?) ??
        (fileData['original_name'] as String?) ?? 'Presentation';
    final mime  = (fileData['mime_type'] as String?) ?? 'application/pdf';

    if (!mounted || url.isEmpty) {
      _viewerActive = false;
      return;
    }

    if (mime == 'application/pdf') {
      _presentationActive = true;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _OnlinePresenterView(
            title: title,
            url: url,
            sessionId: widget.sessionId,
          ),
        ),
      );
    } else if (mime.startsWith('image/')) {
      _presentationActive = true;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _OnlineImageView(title: title, url: url),
        ),
      );
    }

    _viewerActive = false;
    _presentationActive = false;
    if (mounted) setState(() {});
  }

  Future<void> _navigateToQuiz(Map<String, dynamic> quizData) async {
    if (_viewerActive) return;
    _viewerActive = true;

    if (!mounted) {
      _viewerActive = false;
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnlineQuizPlayerView(
          sessionId:         widget.sessionId,
          classroomRemoteId: widget.classroomRemoteId,
          studentId:         _studentId.isNotEmpty ? _studentId : _studentName,
          studentName:       _studentName,
          quizData:          quizData,
        ),
      ),
    );

    _viewerActive = false;
    await _loadQuizResults();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _joinVideoSession() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnlineSessionView(
          sessionId:     widget.sessionId,
          classroomName: widget.classroomName,
          isTeacher:     false,
          myId:          _studentId.isNotEmpty ? _studentId : _studentName,
          myName:        _studentName,
        ),
      ),
    );
    // Video call ended — check if video session is still signalled active
    // (teacher might have ended it while in the call)
  }
  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.classroomName,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const Text('Online Session',
                style: TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.amber,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(icon: Icon(Icons.folder_open, size: 16), text: 'Materials'),
            Tab(icon: Icon(Icons.quiz_outlined, size: 16), text: 'Quizzes'),
          ],
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _buildStatusBanner(),
              // Video call banner hidden — Jitsi disabled for now.
              // if (_videoSessionActive) _buildVideoSessionBanner(),
              Expanded(
                child: !_dataLoaded
                    ? const Center(child: CircularProgressIndicator())
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildMaterialsTab(),
                          _buildQuizResultsTab(),
                        ],
                      ),
              ),
            ],
          ),
          // Chat panel overlay
          if (_showChat)
            Positioned(
              left: 0, right: 0, bottom: 0,
              height: MediaQuery.of(context).size.height * 0.55,
              child: SessionChatPanel(
                sessionId: widget.sessionId,
                myId:      _studentId.isNotEmpty ? _studentId : _studentName,
                myName:    _studentName,
                isTeacher: false,
                onClose:   () => setState(() => _showChat = false),
              ),
            ),

          // Called-on banner (Phase 7)
          if (_calledOn)
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
                          'The teacher has called on you!',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _calledOn = false),
                        child: const Icon(Icons.close,
                            color: Colors.white70, size: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      // Chat and raise-hand only make sense during a live session
      floatingActionButton: widget.sessionId.isEmpty
          ? null
          : Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Raise hand FAB (Phase 7)
          FloatingActionButton.small(
            heroTag: 'lobby_hand_fab',
            onPressed: _handBusy ? null : _toggleHand,
            backgroundColor: _handRaised
                ? Colors.amber.shade700
                : Colors.grey.shade800,
            child: _handBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Icon(
                    _handRaised ? Icons.pan_tool : Icons.pan_tool_outlined,
                    color: Colors.white,
                    size: 18,
                  ),
          ),
          const SizedBox(height: 8),
          // Chat FAB
          FloatingActionButton.small(
            heroTag: 'lobby_chat_fab',
            onPressed: () => setState(() => _showChat = !_showChat),
            backgroundColor:
                _showChat ? Colors.amber : const Color(0xFF1E3A8A),
            child: Icon(
              _showChat ? Icons.close : Icons.chat_bubble_outline,
              color: Colors.white,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // VIDEO SESSION BANNER
  // ---------------------------------------------------------------------------

  // Video banner hidden — video calls disabled for now.
  // ignore: unused_element
  Widget _buildVideoSessionBanner() {
    return Container(
      width: double.infinity,
      color: Colors.deepPurple.shade600,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.videocam, color: Colors.white, size: 16),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Teacher has started a video session!',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
            ),
          ),
          ElevatedButton(
            onPressed: _joinVideoSession,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.deepPurple.shade700,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              textStyle: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.bold),
            ),
            child: const Text('Join Video'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // STATUS BANNER
  // ---------------------------------------------------------------------------

  Widget _buildStatusBanner() {
    Color bg;
    IconData icon;
    String text;

    switch (_sessionState) {
      case _SessionState.joining:
        bg   = Colors.orange.shade700;
        icon = Icons.cloud_sync;
        text = 'Joining session…';
      case _SessionState.active:
        bg   = Colors.green.shade600;
        icon = Icons.cloud_done;
        text = 'In session — waiting for instructor';
      case _SessionState.ended:
        bg   = Colors.grey.shade700;
        icon = Icons.cloud_off;
        text = 'Session has ended';
      case _SessionState.offline:
        bg   = Colors.blueGrey.shade600;
        icon = Icons.folder_open;
        text = 'No active session — browsing materials & quiz results';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (_sessionState == _SessionState.joining)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 2),
            )
          else
            Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style:
                    const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 1 – MATERIALS
  // ---------------------------------------------------------------------------

  Widget _buildMaterialsTab() {
    if (_materials.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 16),
              Text('No materials uploaded yet.',
                  style: TextStyle(
                      color: Colors.grey.shade500, fontSize: 15)),
              const SizedBox(height: 8),
              Text(
                'Files shared by the instructor during\na live session appear here.',
                style: TextStyle(
                    color: Colors.grey.shade400, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _materials.length,
      itemBuilder: (_, i) {
        final m    = _materials[i];
        final name = (m['original_name'] as String?) ?? 'File';
        final url  = (m['url'] as String?)
            ?? (m['file_url'] as String?)
            ?? (m['path'] as String?)
            ?? '';
        final mime = (m['mime_type'] as String?) ?? '';
        final size = (m['size_bytes'] as int?) ?? 0;

        IconData fileIcon;
        Color iconColor;
        if (mime.contains('pdf')) {
          fileIcon  = Icons.picture_as_pdf;
          iconColor = Colors.red;
        } else if (mime.startsWith('image/')) {
          fileIcon  = Icons.image;
          iconColor = Colors.teal;
        } else {
          fileIcon  = Icons.description;
          iconColor = Colors.blue;
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: iconColor.withValues(alpha: 0.1),
              child: Icon(fileIcon, color: iconColor),
            ),
            title: Text(name,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14),
                overflow: TextOverflow.ellipsis),
            subtitle: size > 0
                ? Text(_formatSize(size),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey))
                : null,
            trailing: url.isNotEmpty
                ? const Icon(Icons.open_in_new,
                    size: 18, color: Colors.grey)
                : null,
            onTap: url.isNotEmpty
                ? () => _navigateToViewer({
                      'url': url,
                      'filename': name,
                      'mime_type': mime,
                    })
                : null,
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 2 – QUIZ RESULTS
  // ---------------------------------------------------------------------------

  Widget _buildQuizResultsTab() {
    if (_quizResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.quiz_outlined,
                  size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 16),
              Text('No quiz results yet.',
                  style: TextStyle(
                      color: Colors.grey.shade500, fontSize: 15)),
              const SizedBox(height: 8),
              Text('Completed quizzes will appear here.',
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _quizResults.length,
      itemBuilder: (_, i) {
        final r     = _quizResults[i];
        final title = (r['quiz_title'] as String?) ?? 'Quiz';
        final score = (r['score'] as int?) ?? 0;
        final total = (r['scorable_total'] as int?) ?? 1;
        final pct   = total > 0 ? score / total : 0.0;

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: pct.clamp(0.0, 1.0),
                  backgroundColor: Colors.grey.shade200,
                  color: pct >= 0.75
                      ? Colors.green
                      : pct >= 0.5
                          ? Colors.orange
                          : Colors.red,
                ),
                const SizedBox(height: 4),
                Text('$score / $total',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// ---------------------------------------------------------------------------
// Network PDF Viewer for online presentations
// ---------------------------------------------------------------------------

class _OnlinePresenterView extends StatefulWidget {
  final String title;
  final String url;
  final String sessionId;

  const _OnlinePresenterView({
    required this.title,
    required this.url,
    required this.sessionId,
  });

  @override
  State<_OnlinePresenterView> createState() => _OnlinePresenterViewState();
}

class _OnlinePresenterViewState extends State<_OnlinePresenterView> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title,
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      body: SfPdfViewer.network(widget.url),
    );
  }
}

// ---------------------------------------------------------------------------
// Network Image Viewer
// ---------------------------------------------------------------------------

class _OnlineImageView extends StatelessWidget {
  final String title;
  final String url;

  const _OnlineImageView({required this.title, required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title,
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) {
              if (progress == null) return child;
              return const Center(child: CircularProgressIndicator());
            },
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image,
                  size: 64, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }
}
