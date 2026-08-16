// lib/features/classroom/teacher_dashboard_view.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';

import 'package:uuid/uuid.dart';
import '../../database/asura_repository.dart';
import '../../services/lan_server_isolate.dart';
import '../../services/lan_server_messages.dart';
import '../../services/online_session_service.dart';
import '../../services/cloud_api_service.dart';
import '../online/online_session_view.dart';
import '../presentation/presentation_viewer_view.dart';
import 'dart:io';
import '../../services/lan_scanner_service.dart';
import '../quiz/room_quiz_list_view.dart';
import '../quiz/quiz_results_view.dart';
import 'attendance_log_view.dart';
import 'materials_library_view.dart';

class TeacherDashboardView extends StatefulWidget {
  final String classroomId;
  final String classroomName;
  final String classroomSchedule;
  /// When true the LAN server UI is hidden and only the online session
  /// controls (quiz, materials, session start/end) are shown.
  final bool isOnlineOnly;

  const TeacherDashboardView({
    super.key,
    required this.classroomId,
    required this.classroomName,
    this.classroomSchedule = '',
    this.isOnlineOnly = false,
  });

  @override
  State<TeacherDashboardView> createState() => _TeacherDashboardViewState();
}

class _TeacherDashboardViewState extends State<TeacherDashboardView> {
  StreamSubscription<LanServerUpdate>? _serverSubscription;
  
  bool _isRoomActive = false;
  String _serverAddress = "Offline";
  int _connectedStudentsCount = 0;

  /// Cached browser web client HTML (served at GET / by the LAN server).
  String? _webClientHtml;

  // Active quiz tracking
  String? _activeQuizId;
  String? _activeQuizTitle;
  int _quizSubmissions = 0;

  /// Maps student IP → attendance record ID for the current session,
  /// so we can stamp disconnected_at when they leave.
  final Map<String, String> _activeAttendanceIds = {};

  // Online session
  String? _classroomRemoteId; // null = not published yet
  String? _onlineSessionId;
  Map<String, dynamic>? _onlineSessionData; // full response (ws_url, channel, etc.)
  int _onlineParticipantCount = 0;
  bool _onlineSessionStarting = false;
  Timer? _onlineParticipantPollTimer;

  // Phase 8 — Hybrid Mode
  bool _hybridMode     = false;
  bool _hybridStarting = false;

  @override
  void initState() {
    super.initState();
    _loadClassroomRemoteId();

    // 1. Check if the server is already running in the background Singleton
    _isRoomActive = LanServerIsolateManager.instance.isServerRunning;

    // 2. Subscribe to the live event stream coming from the background Isolate
    _serverSubscription = LanServerIsolateManager.instance.serverEvents.listen((update) {
      if (!mounted) return;
      
      setState(() {
        if (update is ServerStateChangedUpdate) {
          _isRoomActive = update.isRunning;
          if (!update.isRunning) {
            _serverAddress = "Offline";
          }
          // Don't overwrite with 0.0.0.0 — keep the real IP set by _toggleRoomState
          if (update.errorMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Network Error: ${update.errorMessage}'), backgroundColor: Colors.red),
            );
          }
        } else if (update is StudentConnectedUpdate) {
          _connectedStudentsCount = update.totalConnectedCount;
          // Record attendance when a named HANDSHAKE arrives
          if (update.isDisconnect) {
            _recordDisconnect(update.studentIp);
          } else if (update.studentName != null &&
              update.studentName!.isNotEmpty) {
            _recordAttendance(update.studentName!, update.studentIp);
          }
        } else if (update is QuizSubmissionUpdate) {
          _quizSubmissions++;
          // Persist all per-question responses
          final now = DateTime.now().toIso8601String();
          for (final r in update.results) {
            AsuraRepository.insertQuizResponse({
              'id': const Uuid().v4(),
              'quiz_id': update.quizId,
              'question_id': r['question_id'],
              'student_name': update.studentName,
              'student_ip': update.studentIp,
              'answer': r['your_answer'],
              'is_correct': (r['is_correct'] == true) ? 1 : 0,
              'submitted_at': now,
            });
          }
        }
      });
    });
  }

  @override
  void dispose() {
    _serverSubscription?.cancel();
    _onlineParticipantPollTimer?.cancel();
    OnlineSessionService.stopLanBridge(); // Phase 8
    super.dispose();
  }

  Future<void> _loadClassroomRemoteId() async {
    final cls =
        await AsuraRepository.getClassroomById(widget.classroomId);
    if (mounted && cls != null) {
      setState(() => _classroomRemoteId = cls['remote_id'] as String?);
    }
  }

  Future<String> _getRealIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false, // Ignore 127.0.0.1
      );

      for (var interface in interfaces) {
        // FILTER: Only look for interfaces that start with 'wlan' (Wi-Fi/Hotspot)
        // or 'eth' (Ethernet). Virtual interfaces often have different names.
        if (interface.name.toLowerCase().contains('wlan') || 
            interface.name.toLowerCase().contains('eth')) {
          for (var addr in interface.addresses) {
            return addr.address; // Return the first real physical IP found
          }
        }
      }
      
      // Fallback: If no 'wlan' interface is found, return the first non-loopback
      return interfaces.first.addresses.first.address;
      
    } catch (e) {
      debugPrint('IP lookup failed: $e');
      return "192.168.43.1"; // Final fallback
    }
  }

  void _toggleRoomState() async {
    if (_isRoomActive) {
      LanServerIsolateManager.instance.stopServer();
      LanScannerService.stopBeacon();
    } else {
      final String realIp = await _getRealIp();
      final html = await _loadWebClient();

      await LanServerIsolateManager.instance.initializeAndStart(
        hostIp: "0.0.0.0",
        port: 8080,
        webClientHtml: html,
      );

      LanScannerService.startBeacon(
        realIp,
        classroomId: widget.classroomId,
        classroomName: widget.classroomName,
        classroomSchedule: widget.classroomSchedule,
        // Include online remote_id if this room is published, so students
        // scanning via LAN can detect the active online session too.
        remoteId: _classroomRemoteId ?? '',
      );

      setState(() {
        _serverAddress = "http://$realIp:8080";
      });
    }
  }

  /// Loads (and caches) the browser web client HTML from assets.
  Future<String?> _loadWebClient() async {
    if (_webClientHtml != null) return _webClientHtml;
    try {
      _webClientHtml =
          await rootBundle.loadString('assets/lan_web/index.html');
    } catch (_) {
      _webClientHtml = null;
    }
    return _webClientHtml;
  }

  /// Rasterizes each page of [pdfPath] to a PNG in a temp dir so browser
  /// viewers get page-accurate slides via GET /slide/{index}.
  /// Returns (dir, pageCount) or (null, 0) on failure / non-PDF.
  Future<(String?, int)> _rasterizePdfForBrowser(String pdfPath) async {
    try {
      final bytes = await File(pdfPath).readAsBytes();
      final cacheRoot = await getTemporaryDirectory();
      final outDir = Directory(
          '${cacheRoot.path}/lan_slides/${const Uuid().v4()}');
      await outDir.create(recursive: true);

      int index = 0;
      await for (final page in Printing.raster(bytes, dpi: 110)) {
        final png = await page.toPng();
        await File('${outDir.path}/slide_$index.png').writeAsBytes(png);
        index++;
      }
      if (index == 0) return (null, 0);
      return (outDir.path, index);
    } catch (_) {
      return (null, 0);
    }
  }


  void _recordAttendance(String studentName, String studentIp) {
    final now = DateTime.now();
    final sessionDate =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final id = const Uuid().v4();
    _activeAttendanceIds[studentIp] = id;
    AsuraRepository.insertAttendance({
      'id': id,
      'classroom_id': widget.classroomId,
      'student_name': studentName,
      'student_ip': studentIp,
      'joined_at': now.toIso8601String(),
      'session_date': sessionDate,
    });
  }

  void _recordDisconnect(String studentIp) {
    final id = _activeAttendanceIds[studentIp];
    if (id != null) {
      AsuraRepository.updateAttendanceDisconnect(
          id, DateTime.now().toIso8601String());
      _activeAttendanceIds.remove(studentIp);
    }
  }

  // ---------------------------------------------------------------------------
  // MATERIAL PICKER
  // ---------------------------------------------------------------------------

  Future<void> _showMaterialPickerSheet() async {
    final materials =
        await AsuraRepository.getMaterialsForClassroom(widget.classroomId);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.75,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Icon(Icons.co_present, color: Color(0xFF1E3A8A)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Select material to present',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Divider(),
              if (materials.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      Icon(Icons.folder_open,
                          size: 56, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text('No materials uploaded yet.',
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 14)),
                      const SizedBox(height: 4),
                      Text('Upload files in the Materials Library first.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.grey.shade400, fontSize: 12)),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    itemCount: materials.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final m = materials[index];
                      final mime = m['mime_type'] as String;
                      return ListTile(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        tileColor: Colors.grey.shade50,
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: _colorForMime(mime).withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_iconForMime(mime),
                              color: _colorForMime(mime), size: 22),
                        ),
                        title: Text(
                          m['original_name'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        subtitle: Text(
                          _formatSize(m['size_bytes'] as int),
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey),
                        ),
                        trailing: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E3A8A),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: const Text('Present',
                              style: TextStyle(fontSize: 12)),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _launchPresentation(m);
                          },
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

  void _launchPresentation(Map<String, dynamic> material) async {
    final filePath  = material['file_path'] as String;
    final filename  = material['filename'] as String;
    final mimeType  = material['mime_type'] as String;
    final sizeBytes = material['size_bytes'] as int;
    final remoteUrl = material['remote_url'] as String?;

    // For PDFs, rasterize pages so browser viewers (TV/laptop) get page-accurate
    // slides. This runs on the main isolate; show a brief preparing indicator.
    String? slideDir;
    int slideCount = 0;
    if (mimeType == 'application/pdf') {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Preparing slides for browser viewers…')),
            ],
          ),
        ),
      );
      final (dir, count) = await _rasterizePdfForBrowser(filePath);
      slideDir = dir;
      slideCount = count;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    // LAN broadcast (includes rasterized slides for browser clients)
    LanServerIsolateManager.instance.serveFile(
      filePath: filePath,
      filename: filename,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      slideDir: slideDir,
      slideCount: slideCount,
    );

    // Online broadcast (if session is active and material is synced)
    if (_onlineSessionId != null && remoteUrl != null && remoteUrl.isNotEmpty) {
      OnlineSessionService.broadcastEvent(_onlineSessionId!, 'SLIDE_START', {
        'url': remoteUrl,
        'filename': material['original_name'] ?? filename,
        'mime_type': mimeType,
      });
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PresentationViewerView(
          isTeacher: true,
          documentTitle: material['original_name'] as String,
          pdfFilePath: filePath,
          mimeType: mimeType,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // QUIZ LAUNCHER
  // ---------------------------------------------------------------------------

  Future<void> _showQuizPickerSheet() async {
    final quizzes = await AsuraRepository.getRoomQuizzesForClassroom(
        widget.classroomId);
    final draftQuizzes = quizzes.where((q) => q['status'] != 'active').toList();
    if (!mounted) return;

    if (draftQuizzes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('No quizzes ready. Create one first.'),
        action: SnackBarAction(
          label: 'Open Quizzes',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RoomQuizListView(
                classroomId: widget.classroomId,
                classroomName: widget.classroomName,
              ),
            ),
          ),
        ),
      ));
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Launch Quiz',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: draftQuizzes.length,
                  itemBuilder: (_, i) {
                    final q = draftQuizzes[i];
                    return ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Color(0xFF1E3A8A),
                        child: Icon(Icons.quiz, color: Colors.white),
                      ),
                      title: Text(q['title'] as String),
                      subtitle: Text(q['description'] as String? ?? ''),
                      trailing: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _launchQuiz(q);
                        },
                        child: const Text('Launch'),
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

  Future<void> _launchQuiz(Map<String, dynamic> quiz) async {
    final quizId = quiz['id'] as String;
    final quizTitle = quiz['title'] as String;
    final questions =
        await AsuraRepository.getRoomQuizQuestions(quizId);
    if (questions.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Add at least one question to this quiz first.')));
      }
      return;
    }

    await AsuraRepository.updateRoomQuizStatus(quizId, 'active');
    setState(() {
      _activeQuizId = quizId;
      _activeQuizTitle = quizTitle;
      _quizSubmissions = 0;
    });

    // Serialise full question list for the isolate
    final questionsJson = jsonEncode(questions
        .map((q) => {
              'id': q['id'],
              'question_text': q['question_text'],
              'question_type': q['question_type'],
              'options': q['options'],
              'correct_answer': q['correct_answer'],
              'hints': q['hints'],
              'points': q['points'] ?? 1,
            })
        .toList());

    LanServerIsolateManager.instance.startQuiz(
      quizId: quizId,
      quizTitle: quizTitle,
      questionsJson: questionsJson,
    );

    // Hybrid / online-active: also broadcast QUIZ_START to online students
    if (_onlineSessionId != null) {
      final onlineQs = questions.map((q) => {
        'id':      q['id'],
        'text':    q['question_text'] ?? '',
        'type':    q['question_type'] ?? 'multiple_choice',
        'options': q['options'] != null
            ? (q['options'] is String
                ? jsonDecode(q['options'] as String)
                : q['options'])
            : null,
        'points':  q['points'] ?? 1,
      }).toList();
      await OnlineSessionService.broadcastEvent(_onlineSessionId!, 'QUIZ_START', {
        'quiz_id':   quizId,
        'title':     quizTitle,
        'questions': onlineQs,
      });
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Quiz "$quizTitle" launched to all students.'),
        backgroundColor: Colors.green,
      ));
    }
  }

  Future<void> _stopQuiz() async {
    if (_activeQuizId == null) return;
    LanServerIsolateManager.instance.stopQuiz();
    // Hybrid / online-active: also broadcast QUIZ_ENDED to online students
    if (_onlineSessionId != null) {
      await OnlineSessionService.broadcastEvent(_onlineSessionId!, 'QUIZ_ENDED', {});
    }
    await AsuraRepository.updateRoomQuizStatus(_activeQuizId!, 'closed');
    if (mounted) {
      final qId = _activeQuizId!;
      final qTitle = _activeQuizTitle ?? 'Quiz';
      setState(() {
        _activeQuizId = null;
        _activeQuizTitle = null;
        _quizSubmissions = 0;
      });
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              QuizResultsView(quizId: qId, quizTitle: qTitle),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // ONLINE SESSION CONTROLS
  // ---------------------------------------------------------------------------

  Future<void> _startOnlineSession() async {
    if (_classroomRemoteId == null) return;
    setState(() => _onlineSessionStarting = true);

    // If a session already exists, try to end it first (cleanup from previous crash/bug)
    if (_onlineSessionId != null) {
      try {
        await OnlineSessionService.endSession(_onlineSessionId!);
      } catch (_) {
        // Ignore cleanup errors
      }
    }

    final session = await OnlineSessionService.createSession(_classroomRemoteId!);
    if (!mounted) return;
    setState(() => _onlineSessionStarting = false);

    if (session != null) {
      setState(() {
        _onlineSessionId   = session['id']?.toString();
        _onlineSessionData = session;
        _onlineParticipantCount = 0;
      });
      _startParticipantPolling();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Online session started. Students can now join online.'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      // Clear state on failure so teacher can retry
      setState(() {
        _onlineSessionId   = null;
        _onlineSessionData = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to start online session. Check your connection.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _endOnlineSession() async {
    if (_onlineSessionId == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End Online Session'),
        content: const Text('This will disconnect all online students.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End Session'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Broadcast end event to all students (best effort)
    try {
      await OnlineSessionService.broadcastEvent(
          _onlineSessionId!, 'PRESENTATION_ENDED', {});
    } catch (_) {
      // Broadcast may fail, but we still need to end the session
    }

    // Ensure session is ended on backend
    final sessionId = _onlineSessionId!;
    try {
      await OnlineSessionService.endSession(sessionId);
    } catch (_) {
      // Ignore errors
    }

    _onlineParticipantPollTimer?.cancel();
    if (mounted) {
      setState(() {
        _onlineSessionId   = null;
        _onlineSessionData = null;
        _onlineParticipantCount = 0;
      });
    }
  }

  void _startParticipantPolling() {
    _onlineParticipantPollTimer?.cancel();
    _onlineParticipantPollTimer =
        Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_onlineSessionId == null) return;
      final participants =
          await OnlineSessionService.getParticipants(_onlineSessionId!);
      if (mounted) {
        setState(() => _onlineParticipantCount = participants.length);
      }
    });
  }

  // _startVideo is disabled while Jitsi video calls are turned off.
  // ignore: unused_element
  Future<void> _startVideo() async {
    if (_onlineSessionId == null || _onlineSessionData == null) return;

    // Connect teacher to Reverb WS so session events (quiz, hand-raise, etc.)
    // arrive via the event stream while in the video call.
    if (!OnlineSessionService.instance.isConnected) {
      final rawWs    = _onlineSessionData!['ws_url'] as String?;
      final channel  = _onlineSessionData!['channel'] as String?;
      final resolvedWs = await OnlineSessionUrlHelper.getWsUrl(
          serverProvidedUrl: rawWs);
      if (resolvedWs.isNotEmpty && channel != null) {
        await OnlineSessionService.instance.connectToSession(
          wsUrl:       resolvedWs,
          channelName: channel,
        );
      }
    }

    if (!mounted) return;

    final teacherIdRaw   = await CloudApiService.getOnlineUserId();
    final teacherNameRaw  = await CloudApiService.getOnlineName();

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnlineSessionView(
          sessionId:     _onlineSessionId!,
          classroomName: widget.classroomName,
          isTeacher:     true,
          myId:          teacherIdRaw   ?? 'teacher',
          myName:        teacherNameRaw ?? widget.classroomName,
          classroomId:   widget.classroomId,
        ),
      ),
    );

    // Disconnect WS on return; teacher only needs it during the video call
    OnlineSessionService.instance.disconnect();
  }

  // ---------------------------------------------------------------------------
  // HYBRID MODE (Phase 8)
  // ---------------------------------------------------------------------------

  /// Starts both LAN and Online sessions simultaneously.
  // _startHybridMode kept for Hybrid mode teardown path; suppress lint.
  // ignore: unused_element
  Future<void> _startHybridMode() async {
    if (_classroomRemoteId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Publish this classroom online first to enable Hybrid Mode.'),
          ),
        );
      }
      return;
    }

    setState(() => _hybridStarting = true);

    // 1. Start LAN (if not already running)
    if (!_isRoomActive) {
      final String realIp = await _getRealIp();
      final html = await _loadWebClient();
      await LanServerIsolateManager.instance.initializeAndStart(
        hostIp: '0.0.0.0',
        port: 8080,
        webClientHtml: html,
      );
      LanScannerService.startBeacon(
        realIp,
        classroomId: widget.classroomId,
        classroomName: widget.classroomName,
        classroomSchedule: widget.classroomSchedule,
        remoteId: _classroomRemoteId ?? '',
      );
      if (mounted) setState(() => _serverAddress = 'http://$realIp:8080');
    }

    // 2. Start Online session (if not already running)
    if (_onlineSessionId == null) {
      final session =
          await OnlineSessionService.createSession(_classroomRemoteId!);
      if (!mounted) return;
      if (session != null) {
        setState(() {
          _onlineSessionId        = session['id']?.toString();
          _onlineSessionData      = session;
          _onlineParticipantCount = 0;
        });
        _startParticipantPolling();
      }
    }

    if (!mounted) return;

    final success = _onlineSessionId != null;
    setState(() {
      _hybridStarting = false;
      _hybridMode     = success;
    });

    if (success) {
      // 3. Bridge: forward LAN student connections to the online channel
      OnlineSessionService.startLanBridge(_onlineSessionId!);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Hybrid session active — LAN + Online students can join.'),
          backgroundColor: Colors.teal,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Online session failed. Running LAN-only mode.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  /// Tears down both LAN and Online sessions in one action.
  Future<void> _stopHybridMode() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop Hybrid Session'),
        content: const Text(
            'This will disconnect all LAN and online students.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Stop bridge first
    try {
      OnlineSessionService.stopLanBridge();
    } catch (_) {}

    // End online session (best effort)
    if (_onlineSessionId != null) {
      try {
        await OnlineSessionService.broadcastEvent(
            _onlineSessionId!, 'PRESENTATION_ENDED', {});
      } catch (_) {}
      try {
        await OnlineSessionService.endSession(_onlineSessionId!);
      } catch (_) {}
      _onlineParticipantPollTimer?.cancel();
    }

    // Stop LAN
    try {
      LanServerIsolateManager.instance.stopServer();
    } catch (_) {}
    try {
      LanScannerService.stopBeacon();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _hybridMode             = false;
        _onlineSessionId        = null;
        _onlineSessionData      = null;
        _onlineParticipantCount = 0;
      });
    }
  }

  // ---------------------------------------------------------------------------

  IconData _iconForMime(String m) {
    if (m == 'application/pdf') return Icons.picture_as_pdf;
    if (m.startsWith('image/')) return Icons.image;
    if (m.contains('word')) return Icons.description;
    return Icons.insert_drive_file;
  }

  Color _colorForMime(String m) {
    if (m == 'application/pdf') return Colors.red;
    if (m.startsWith('image/')) return Colors.teal;
    if (m.contains('word')) return Colors.blue;
    return Colors.grey;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isOnlineOnly ? 'Online Session' : 'Live Session Control'),
        backgroundColor: widget.isOnlineOnly
            ? Colors.blue.shade700
            : (_hybridMode
                ? Colors.teal.shade700
                : (_isRoomActive ? Colors.green.shade700 : const Color(0xFF1E3A8A))),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- ONLINE SESSION PANEL (top, online-only mode) ---
              if (widget.isOnlineOnly) ...[
                _buildOnlineSessionPanel(),
                const SizedBox(height: 16),
              ],

              // --- SERVER STATUS CARD (LAN mode only) ---
              if (!widget.isOnlineOnly) ...[
                Card(
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: _isRoomActive ? Colors.green : Colors.grey.shade300, width: 2),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        Icon(
                          _isRoomActive ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                          size: 64,
                          color: _isRoomActive ? Colors.green : Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isRoomActive ? 'Edge-LAN Broadcast Active' : 'Network Offline',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: _isRoomActive ? Colors.green.shade700 : Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _serverAddress,
                                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (_isRoomActive)
                              Tooltip(
                                message: 'How to connect',
                                child: GestureDetector(
                                  onTap: () => showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      title: Row(
                                        children: const [
                                          Icon(Icons.cast_connected, color: Color(0xFF1E3A8A)),
                                          SizedBox(width: 8),
                                          Text('How to Connect'),
                                        ],
                                      ),
                                      content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: const [
                                          _HintStep(
                                            number: '1',
                                            icon: Icons.wifi,
                                            text: 'Connect the TV or device to the same Wi-Fi network as this device, or connect to this device\'s hotspot.',
                                          ),
                                          SizedBox(height: 12),
                                          _HintStep(
                                            number: '2',
                                            icon: Icons.open_in_browser,
                                            text: 'Open a web browser (e.g. Chrome, Edge, or the built-in TV browser).',
                                          ),
                                          SizedBox(height: 12),
                                          _HintStep(
                                            number: '3',
                                            icon: Icons.link,
                                            text: 'Type the IP address shown on this card into the browser address bar and press Enter.',
                                          ),
                                        ],
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text('Got it'),
                                        ),
                                      ],
                                    ),
                                  ),
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E3A8A),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Center(
                                      child: Text('!',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),



                // --- STUDENT CONNECTION METRICS ---
                Row(
                  children: [
                    Expanded(
                      child: _buildMetricCard(
                        'Connected Devices',
                        '$_connectedStudentsCount',
                        Icons.devices,
                        _isRoomActive ? Colors.blue : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildMetricCard(
                        'Packet Loss',
                        _isRoomActive ? '0.0%' : '--',
                        Icons.speed,
                        _isRoomActive ? Colors.orange : Colors.grey,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // --- ALWAYS-ON CLASSROOM RECORD SHORTCUTS ---
              // Visible regardless of server state so records are never locked
              // behind needing to start the network first.
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Classroom Records',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey,
                        letterSpacing: 0.5)),
              ),
              Row(
                children: [
                  Expanded(
                    child: _buildRecordShortcut(
                      icon: Icons.assignment_turned_in,
                      label: 'Attendance',
                      color: Colors.orange,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AttendanceLogView(
                            classroomId: widget.classroomId,
                            classroomName: widget.classroomName,
                            classroomSchedule: widget.classroomSchedule,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildRecordShortcut(
                      icon: Icons.menu_book,
                      label: 'Materials',
                      color: Colors.purple,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MaterialsLibraryView(
                            classroomId: widget.classroomId,
                            classroomName: widget.classroomName,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildRecordShortcut(
                      icon: Icons.quiz_outlined,
                      label: 'Quiz Records',
                      color: Colors.teal,
                      onTap: () => _openQuizRecords(),
                    ),
                  ),
                ],
              ),

              const Spacer(),

              // --- ONLINE SESSION PANEL (bottom, LAN mode only) ---
              // Removed from LAN view — Start Online is only in the Online Cloud Server route.

              // --- MAIN CONTROL BUTTONS ---

              // Present & Quiz — show whenever LAN or an online session is active
              if (_isRoomActive || _onlineSessionId != null) ...[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.co_present, size: 28),
                  label: const Text('Open Presentation Canvas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  onPressed: _showMaterialPickerSheet,
                ),
                const SizedBox(height: 12),
                // Active quiz banner
                if (_activeQuizId != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.quiz, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_activeQuizTitle ?? 'Active Quiz',
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text('$_quizSubmissions submission${_quizSubmissions == 1 ? '' : 's'}',
                                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            ],
                          ),
                        ),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.green,
                              side: const BorderSide(color: Colors.green)),
                          onPressed: _stopQuiz,
                          child: const Text('End Quiz'),
                        ),
                      ],
                    ),
                  )
                else
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E3A8A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.quiz, size: 24),
                    label: const Text('Launch Quiz', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    onPressed: _showQuizPickerSheet,
                  ),
                const SizedBox(height: 16),
              ],

              // Toggle Server button — LAN mode only (Hybrid removed)
              if (!widget.isOnlineOnly) ...[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _hybridMode || _isRoomActive
                            ? Colors.red.shade600
                            : const Color(0xFF1E3A8A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: Icon(
                      _hybridMode || _isRoomActive
                          ? Icons.stop_circle
                          : Icons.bolt,
                      size: 28),
                  label: Text(
                    _hybridMode
                        ? 'Stop Hybrid Session'
                        : (_isRoomActive
                            ? 'Terminate Local Network'
                            : 'Initialize Local Network'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  onPressed: _hybridMode ? _stopHybridMode : _toggleRoomState,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOnlineSessionPanel() {
    if (_classroomRemoteId == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, size: 18, color: Colors.grey),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Publish this classroom online to enable Online Sessions.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }

    final isActive = _onlineSessionId != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _hybridMode
            ? Colors.teal.shade50
            : (isActive ? Colors.blue.shade50 : Colors.grey.shade50),
        border: Border.all(
            color: _hybridMode
                ? Colors.teal.shade300
                : (isActive ? Colors.blue.shade300 : Colors.grey.shade300)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            _hybridMode
                ? Icons.device_hub
                : (isActive ? Icons.cloud_done : Icons.cloud_outlined),
            size: 18,
            color: _hybridMode
                ? Colors.teal
                : (isActive ? Colors.blue : Colors.grey),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _hybridMode
                      ? 'Hybrid Session Active'
                      : (isActive ? 'Online Session Active' : 'Online Session'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _hybridMode
                        ? Colors.teal.shade800
                        : (isActive
                            ? Colors.blue.shade800
                            : Colors.grey.shade700),
                  ),
                ),
                Text(
                  _hybridMode
                      ? '$_connectedStudentsCount LAN  •  $_onlineParticipantCount online'
                      : (isActive
                          ? '$_onlineParticipantCount student(s) online'
                          : 'Students can join from anywhere'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          if (_onlineSessionStarting || _hybridStarting)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (_hybridMode)
            // Hybrid mode: no video button, stop is handled elsewhere
            const SizedBox.shrink()
          else if (isActive)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: _endOnlineSession,
              child: const Text('End', style: TextStyle(fontSize: 13)),
            )
          else
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E3A8A),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                textStyle: const TextStyle(fontSize: 12),
              ),
              onPressed: _startOnlineSession,
              child: const Text('Start Online'),
            ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }


  Widget _buildRecordShortcut({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade200),
          borderRadius: BorderRadius.circular(12),
          color: color.withValues(alpha: 0.06),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Shows a picker so the teacher can choose which closed/active quiz to review.
  Future<void> _openQuizRecords() async {
    final quizzes =
        await AsuraRepository.getRoomQuizzesForClassroom(widget.classroomId);
    if (!mounted) return;

    if (quizzes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No quizzes for this classroom yet.'),
          action: SnackBarAction(
            label: 'Manage Quizzes',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RoomQuizListView(
                  classroomId: widget.classroomId,
                  classroomName: widget.classroomName,
                ),
              ),
            ),
          ),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Quiz Records',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: quizzes.length,
                  itemBuilder: (_, i) {
                    final q = quizzes[i];
                    final status = q['status'] as String? ?? 'draft';
                    Color statusColor = status == 'active'
                        ? Colors.green
                        : status == 'closed'
                            ? Colors.grey
                            : Colors.blue;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            statusColor.withValues(alpha: 0.15),
                        child: Icon(Icons.quiz,
                            color: statusColor, size: 20),
                      ),
                      title: Text(q['title'] as String,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)),
                      subtitle: Text(status.toUpperCase(),
                          style: TextStyle(
                              fontSize: 11, color: statusColor)),
                      trailing:
                          const Icon(Icons.chevron_right, color: Colors.grey),
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => QuizResultsView(
                              quizId: q['id'] as String,
                              quizTitle: q['title'] as String,
                            ),
                          ),
                        );
                      },
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
}

/// A numbered step row used inside the "How to Connect" hint dialog.
class _HintStep extends StatelessWidget {
  final String number;
  final IconData icon;
  final String text;

  const _HintStep({
    required this.number,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
            color: Color(0xFF1E3A8A),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(number,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(width: 10),
        Icon(icon, size: 18, color: const Color(0xFF1E3A8A)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: const TextStyle(fontSize: 13, height: 1.4)),
        ),
      ],
    );
  }
}
