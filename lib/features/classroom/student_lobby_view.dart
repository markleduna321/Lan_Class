// lib/features/classroom/student_lobby_view.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:open_filex/open_filex.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../database/asura_repository.dart';
import '../../services/cloud_api_service.dart';
import '../online/online_session_lobby_view.dart';
import '../presentation/presentation_viewer_view.dart';
import '../quiz/quiz_player_view.dart';

enum _ConnStatus { disconnected, connecting, connected }

class StudentLobbyView extends StatefulWidget {
  final String hostIp;
  /// Optional human-readable name shown in the app bar.
  final String roomLabel;
  /// Classroom ID from the teacher's beacon (used to identify the room).
  final String classroomId;
  /// Laravel remote classroom ID (if student saved this room from online browser).
  final String classroomRemoteId;

  const StudentLobbyView({
    super.key,
    required this.hostIp,
    this.roomLabel = '',
    this.classroomId = '',
    this.classroomRemoteId = '',
  });

  @override
  State<StudentLobbyView> createState() => _StudentLobbyViewState();
}

class _StudentLobbyViewState extends State<StudentLobbyView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  _ConnStatus _status = _ConnStatus.disconnected;
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _viewerActive = false; // guard: prevent reconnect loop while viewer is open

  String _studentName = 'Student';
  List<Map<String, dynamic>> _materials = [];
  List<Map<String, dynamic>> _sessions = [];
  List<Map<String, dynamic>> _quizResults = [];
  bool _dataLoaded = false;
  bool _sessionRecorded = false;

  // Online session detection
  /// The effective remoteId to use for online-session polling.
  /// Starts as [widget.classroomRemoteId] and may be resolved from the cloud
  /// when the student joined this room via LAN scan before it was published.
  String _resolvedRemoteId = '';
  Map<String, dynamic>? _onlineSessionData;
  Timer? _onlineCheckTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _init();
  }

  Future<void> _init() async {
    const storage = FlutterSecureStorage();
    _studentName = await storage.read(key: 'ACTIVE_USER_NAME') ?? 'Student';
    // Seed the resolvedRemoteId from the widget prop first.
    _resolvedRemoteId = widget.classroomRemoteId;
    await _loadLocalData();
    _tryConnect();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_status == _ConnStatus.disconnected && !_viewerActive && mounted) {
        _tryConnect();
      }
    });
    // Try to resolve the remoteId from the cloud if we don't have one yet,
    // then start the online-session poll once the lookup finishes.
    await _resolveRemoteId();
    _startOnlineSessionCheck();
  }

  Future<void> _loadLocalData() async {
    final mats = await AsuraRepository.getStudentMaterials(widget.hostIp);
    final sess = await AsuraRepository.getStudentSessionsByIp(widget.hostIp);
    final quizRes =
        await AsuraRepository.getStudentQuizResultsByHost(
            widget.hostIp, widget.classroomId);
    if (mounted) {
      setState(() {
        _materials = mats;
        _sessions = sess;
        _quizResults = quizRes;
        _dataLoaded = true;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Resolve remote classroom ID from the cloud (for LAN-only saved rooms)
  // ---------------------------------------------------------------------------

  /// If we already have a remoteId (from the widget or the beacon), skip this.
  /// Otherwise query the public classroom list and match by local classroomId
  /// or room name so we can start polling for online sessions.
  Future<void> _resolveRemoteId() async {
    // Already have the id — nothing to do.
    if (_resolvedRemoteId.isNotEmpty) return;
    // No local classroomId to match against — can't resolve.
    if (widget.classroomId.isEmpty && widget.roomLabel.isEmpty) return;

    try {
      final response = await CloudApiService.get('/api/classrooms');
      if (response == null || response.statusCode != 200) return;
      final body = jsonDecode(response.body);
      final List<dynamic> classrooms =
          body is List ? body : (body['data'] as List? ?? []);

      for (final raw in classrooms) {
        final c = raw as Map<String, dynamic>;
        final serverId = c['id']?.toString() ?? '';
        // Match by the local classroom ID stored in the beacon payload
        final serverLocalId = c['local_id']?.toString() ?? '';
        // Match by room name as fallback
        final serverName = (c['name'] as String?) ?? '';

        if ((widget.classroomId.isNotEmpty &&
                serverLocalId == widget.classroomId) ||
            (widget.roomLabel.isNotEmpty && serverName == widget.roomLabel)) {
          if (serverId.isNotEmpty && mounted) {
            setState(() => _resolvedRemoteId = serverId);
            // Persist the resolved remoteId back so the scan result is not
            // lost next time — we update the saved-classrooms list.
            _persistResolvedRemoteId(serverId);
          }
          return;
        }
      }
    } catch (_) {
      // Network unavailable — polling won't start; that's acceptable.
    }
  }

  /// Writes the resolved remoteId back into the persisted saved-classrooms
  /// list so the next time the student opens this room the lookup is skipped.
  Future<void> _persistResolvedRemoteId(String remoteId) async {
    const storage = FlutterSecureStorage();
    const key = 'saved_classrooms_v2';
    try {
      final raw = await storage.read(key: key);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      bool changed = false;
      for (final entry in list) {
        final entryIp = (entry['ip'] as String?) ?? '';
        final entryId = (entry['classroomId'] as String?) ?? '';
        final entryRemote = (entry['remoteId'] as String?) ?? '';
        // Only update entries that belong to this room and lack a remoteId.
        if (entryRemote.isEmpty &&
            entryIp == widget.hostIp &&
            (entryId == widget.classroomId || widget.classroomId.isEmpty)) {
          entry['remoteId'] = remoteId;
          changed = true;
        }
      }
      if (changed) {
        await storage.write(key: key, value: jsonEncode(list));
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // WebSocket connection management
  // ---------------------------------------------------------------------------

  void _tryConnect() {
    if (_status != _ConnStatus.disconnected || !mounted || _viewerActive) return;
    setState(() => _status = _ConnStatus.connecting);

    try {
      _channel =
          WebSocketChannel.connect(Uri.parse('ws://${widget.hostIp}:8080'));
      _channel!.sink.add(jsonEncode({
        'event': 'HANDSHAKE',
        'from': 'student',
        'name': _studentName,
      }));
      _channel!.stream.listen(
        _handleMessage,
        onError: (_) => _handleDisconnect(),
        onDone: () => _handleDisconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _handleMessage(dynamic raw) async {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (data['event'] as String?) {
        case 'HANDSHAKE_ACK':
          if (mounted) setState(() => _status = _ConnStatus.connected);
          // Record this session locally (once per day per classroom)
          if (!_sessionRecorded) {
            _sessionRecorded = true;
            await _recordSession();
          }
          // Jump straight to viewer if a presentation is already running
          final cf = data['current_file'] as Map<String, dynamic>?;
          if (cf != null && mounted) await _navigateToViewer(cf);
          // Jump to quiz if one is already active
          final cq = data['current_quiz'] as Map<String, dynamic>?;
          if (cq != null && mounted) await _navigateToQuiz(cq);

        case 'FILE_PRESENTATION_START':
          if (mounted) await _navigateToViewer(data);

        case 'QUIZ_START':
          if (mounted) await _navigateToQuiz(data);

        case 'PRESENTATION_ENDED':
          _handleDisconnect();
      }
    } catch (_) {}
  }

  void _handleDisconnect() {
    _channel = null;
    _sessionRecorded = false;
    if (mounted) setState(() => _status = _ConnStatus.disconnected);
  }

  Future<void> _recordSession() async {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    await AsuraRepository.insertStudentSession({
      'id': '${widget.hostIp}_$date', // one entry per day per classroom
      'classroom_ip': widget.hostIp,
      'joined_at': now.toIso8601String(),
      'session_date': date,
    });
    await _loadLocalData();
  }

  // ---------------------------------------------------------------------------
  // Navigate to the presentation viewer
  // ---------------------------------------------------------------------------

  Future<void> _navigateToViewer(Map<String, dynamic> fileData) async {
    if (_viewerActive) return; // already navigating — ignore duplicate events
    _viewerActive = true;
    _reconnectTimer?.cancel(); // pause reconnect timer while viewer is open

    // Close the lobby's WS so the viewer can open its own cleanly.
    // (Two open connections from the same device = duplicate attendance record.)
    final ch = _channel;
    _channel = null;
    _sessionRecorded = false;
    setState(() => _status = _ConnStatus.disconnected);
    try {
      await ch?.sink.close();
    } catch (_) {}

    if (!mounted) {
      _viewerActive = false;
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PresentationViewerView(
          isTeacher: false,
          documentTitle:
              fileData['filename'] as String? ?? 'Presentation',
          hostIp: widget.hostIp,
          autoPopOnDisconnect: true,
          initialFileData: fileData,
        ),
      ),
    );

    // Presentation ended — resume lobby
    _viewerActive = false;
    if (mounted) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_status == _ConnStatus.disconnected && !_viewerActive && mounted) {
          _tryConnect();
        }
      });
      await _loadLocalData();
      _tryConnect();
    }
  }

  // ---------------------------------------------------------------------------
  // Navigate to the quiz player
  // ---------------------------------------------------------------------------

  Future<void> _navigateToQuiz(Map<String, dynamic> quizData) async {
    if (_viewerActive) return;
    _viewerActive = true;
    _reconnectTimer?.cancel();

    // Close lobby WS while in quiz
    final ch = _channel;
    _channel = null;
    _sessionRecorded = false;
    setState(() => _status = _ConnStatus.disconnected);
    try { await ch?.sink.close(); } catch (_) {}

    if (!mounted) { _viewerActive = false; return; }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QuizPlayerView(
          hostIp: widget.hostIp,
          port: 8080,
          studentName: _studentName,
          classroomId: widget.classroomId,
          quizData: quizData,
        ),
      ),
    );

    _viewerActive = false;
    if (mounted) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_status == _ConnStatus.disconnected && !_viewerActive && mounted) {
          _tryConnect();
        }
      });
      await _loadLocalData();
      _tryConnect();
    }
  }

  // ---------------------------------------------------------------------------
  // Online session detection (only active when a remote classroom ID is known)
  // ---------------------------------------------------------------------------

  void _startOnlineSessionCheck() {
    if (_resolvedRemoteId.isEmpty) return;
    _onlineCheckTimer?.cancel();
    _checkOnlineSession(); // immediate check
    _onlineCheckTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkOnlineSession());
  }

  Future<void> _checkOnlineSession() async {
    if (_resolvedRemoteId.isEmpty) return;
    final response = await CloudApiService.get(
        '/api/classrooms/$_resolvedRemoteId/active-session');
    if (!mounted) return;
    if (response != null && response.statusCode == 200) {
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() => _onlineSessionData = data);
      } catch (_) {}
    } else {
      setState(() => _onlineSessionData = null);
    }
  }

  Future<void> _joinOnlineSession() async {
    final session = _onlineSessionData;
    if (session == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator  = Navigator.of(context);

    // Unwrap session if server returns {"session": {...}}
    final Map<String, dynamic> s =
        (session['session'] as Map<String, dynamic>?) ?? session;
    final sessionId = s['id']?.toString() ?? '';

    if (sessionId.isEmpty) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Online session info incomplete.')),
        );
      }
      return;
    }

    await navigator.push(
      MaterialPageRoute(
        builder: (_) => OnlineSessionLobbyView(
          classroomRemoteId: _resolvedRemoteId,
          classroomName: widget.roomLabel,
          sessionId: sessionId,
        ),
      ),
    );

    // Re-check session state after returning from online lobby
    _checkOnlineSession();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _onlineCheckTimer?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _tabController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final label = widget.roomLabel.isNotEmpty
        ? widget.roomLabel
        : 'Classroom';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            Text(widget.hostIp,
                style:
                    const TextStyle(fontSize: 11, color: Colors.white70)),
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
            Tab(
                icon: Icon(Icons.calendar_today, size: 16),
                text: 'My Attendance'),
            Tab(icon: Icon(Icons.quiz_outlined, size: 16), text: 'Quizzes'),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildStatusBanner(),
          if (_onlineSessionData != null) _buildOnlineSessionBanner(),
          Expanded(
            child: !_dataLoaded
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildMaterialsTab(),
                      _buildAttendanceTab(),
                      _buildQuizResultsTab(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // STATUS BANNER
  // ---------------------------------------------------------------------------

  Widget _buildOnlineSessionBanner() {
    return Container(
      width: double.infinity,
      color: Colors.blue.shade700,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.cloud_done, color: Colors.white, size: 16),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Online session is now live!',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: _joinOnlineSession,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(70, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: Colors.white,
              foregroundColor: Colors.blue.shade800,
            ),
            child: const Text('Join Online',
                style:
                    TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    Color bg;
    IconData icon;
    String text;

    switch (_status) {
      case _ConnStatus.connected:
        bg = Colors.green.shade600;
        icon = Icons.wifi;
        text = 'Connected — waiting for instructor to start a presentation';
      case _ConnStatus.connecting:
        bg = Colors.orange.shade700;
        icon = Icons.wifi_find;
        text = 'Connecting to ${widget.hostIp}…';
      case _ConnStatus.disconnected:
        bg = Colors.grey.shade700;
        icon = Icons.wifi_off;
        text = 'Host offline — browsing saved content';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (_status == _ConnStatus.connecting)
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
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          if (_status == _ConnStatus.disconnected)
            TextButton(
              onPressed: _tryConnect,
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(50, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Retry',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 1 – DOWNLOADED MATERIALS
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
              Text('No downloaded materials yet.',
                  style: TextStyle(
                      color: Colors.grey.shade500, fontSize: 15)),
              const SizedBox(height: 8),
              Text(
                'Materials shared during a live presentation\nwill appear here for offline access.',
                style:
                    TextStyle(color: Colors.grey.shade400, fontSize: 13),
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
        final mat = _materials[i];
        final name =
            (mat['original_name'] as String?) ?? (mat['filename'] as String);
        final mime = (mat['mime_type'] as String?) ?? '';
        final localPath = mat['local_path'] as String?;
        final sizeKb =
            (((mat['size_bytes'] as int?) ?? 0) / 1024).round();

        IconData fileIcon;
        Color iconColor;
        if (mime.contains('pdf')) {
          fileIcon = Icons.picture_as_pdf;
          iconColor = Colors.red;
        } else if (mime.startsWith('image/')) {
          fileIcon = Icons.image;
          iconColor = Colors.blue;
        } else {
          fileIcon = Icons.insert_drive_file;
          iconColor = Colors.grey;
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: iconColor.withValues(alpha: 0.1),
              child: Icon(fileIcon, color: iconColor),
            ),
            title: Text(name,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: Text(
                sizeKb > 0 ? '$sizeKb KB' : 'Downloaded',
                style: const TextStyle(fontSize: 11)),
            trailing: localPath != null
                ? IconButton(
                    icon: const Icon(Icons.open_in_new,
                        color: Color(0xFF1E3A8A)),
                    onPressed: () => OpenFilex.open(localPath),
                  )
                : null,
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 2 – MY ATTENDANCE
  // ---------------------------------------------------------------------------

  Widget _buildAttendanceTab() {
    if (_sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_note, size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 16),
              Text('No attendance records yet.',
                  style: TextStyle(
                      color: Colors.grey.shade500, fontSize: 15)),
              const SizedBox(height: 8),
              Text(
                'Your attendance is saved automatically\neach time you connect to this classroom.',
                style:
                    TextStyle(color: Colors.grey.shade400, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline,
                  color: Colors.green, size: 18),
              const SizedBox(width: 6),
              Text('${_sessions.length} session(s) attended',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: _sessions.length,
            itemBuilder: (_, i) {
              final s = _sessions[i];
              final dateStr = s['session_date'] as String;
              final joinedAt = s['joined_at'] as String?;

              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                child: ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A8A).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        _dayNum(dateStr),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E3A8A),
                        ),
                      ),
                    ),
                  ),
                  title: Text(_formatDate(dateStr),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: joinedAt != null
                      ? Text('Joined at ${_formatTime(joinedAt)}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey))
                      : null,
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: const Text('Present',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.green,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 3 – QUIZ RESULTS
  // ---------------------------------------------------------------------------

  Widget _buildQuizResultsTab() {
    if (_quizResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.quiz_outlined, size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 16),
              Text('No quizzes taken yet.',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 15)),
              const SizedBox(height: 8),
              Text(
                'Your scores will appear here after your teacher\nlaunches a quiz during a live session.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _quizResults.length,
      itemBuilder: (_, i) {
        final r = _quizResults[i];
        final score = (r['score'] as int?) ?? 0;
        final total = (r['scorable_total'] as int?) ?? 0;
        final totalQ = (r['total_questions'] as int?) ?? 0;
        final pct = total > 0 ? score / total : 0.0;
        final color = total > 0
            ? (pct >= 0.7 ? Colors.green : pct >= 0.4 ? Colors.orange : Colors.red)
            : Colors.blue;
        final title = r['quiz_title'] as String? ?? 'Quiz';
        final takenAt = r['taken_at'] as String?;

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _showQuizResultDetail(r),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Text(
                      total > 0
                          ? '${(pct * 100).toStringAsFixed(0)}%'
                          : '$totalQ',
                      style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: total > 0 ? pct : 0,
                            minHeight: 5,
                            backgroundColor: Colors.grey.shade200,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(color),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          total > 0
                              ? '$score/$total correct  •  ${_formatTime(takenAt ?? '')}'
                              : '$totalQ questions  •  ${_formatTime(takenAt ?? '')}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showQuizResultDetail(Map<String, dynamic> result) {
    final answersRaw = result['answers_json'] as String?;
    List<Map<String, dynamic>> answers = [];
    if (answersRaw != null) {
      try {
        answers =
            (jsonDecode(answersRaw) as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    final score = (result['score'] as int?) ?? 0;
    final total = (result['scorable_total'] as int?) ?? 0;
    final title = result['quiz_title'] as String? ?? 'Quiz';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18)),
                    ),
                    if (total > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E3A8A).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('$score / $total',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1E3A8A))),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: answers.isEmpty
                    ? const Center(child: Text('No answer details available.'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: answers.length,
                        itemBuilder: (_, i) {
                          final a = answers[i];
                          final isCorrect = a['is_correct'] as bool?;
                          final isScored = isCorrect != null;
                          final qText = a['question_text'] as String? ?? 'Question ${i + 1}';
                          final yourAnswer = a['your_answer'] as String?;
                          final correctAnswer = a['correct_answer'] as String?;
                          final hintsRaw = a['hints'];
                          Map<String, dynamic>? hints;
                          if (hintsRaw is Map) {
                            hints = hintsRaw.cast<String, dynamic>();
                          }

                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (isScored)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                              right: 8, top: 2),
                                          child: Icon(
                                            isCorrect
                                                ? Icons.check_circle
                                                : Icons.cancel,
                                            color: isCorrect
                                                ? Colors.green
                                                : Colors.red,
                                            size: 18,
                                          ),
                                        ),
                                      Expanded(
                                        child: Text(
                                          '${i + 1}. $qText',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  if (yourAnswer != null &&
                                      yourAnswer.isNotEmpty)
                                    Text(
                                      'Your answer: $yourAnswer',
                                      style: TextStyle(
                                          color: isScored
                                              ? (isCorrect
                                                  ? Colors.green
                                                  : Colors.red)
                                              : Colors.black87,
                                          fontSize: 13),
                                    ),
                                  if (isScored &&
                                      isCorrect == false &&
                                      correctAnswer != null)
                                    Text(
                                      'Correct: $correctAnswer',
                                      style: const TextStyle(
                                          color: Colors.green,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500),
                                    ),
                                  if (hints != null) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.blue.shade50,
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: hints.entries.map((e) {
                                          final val = e.value;
                                          final explanation = val is Map
                                              ? val['explanation'] as String? ?? ''
                                              : val.toString();
                                          return Text(
                                            '${e.key}: $explanation',
                                            style: const TextStyle(
                                                fontSize: 12),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  String _dayNum(String iso) {
    try {
      return DateTime.parse(iso).day.toString();
    } catch (_) {
      return '?';
    }
  }

  String _formatDate(String iso) {
    try {
      final d = DateTime.parse(iso);
      const months = [
        '',
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December'
      ];
      const days = [
        '',
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday'
      ];
      return '${days[d.weekday]}, ${months[d.month]} ${d.day}, ${d.year}';
    } catch (_) {
      return iso;
    }
  }

  String _formatTime(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
      final m = d.minute.toString().padLeft(2, '0');
      return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
    } catch (_) {
      return '';
    }
  }
}
