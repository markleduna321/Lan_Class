// lib/services/lan_server_isolate.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'lan_server_messages.dart';

class LanServerIsolateManager {

  static final LanServerIsolateManager instance = LanServerIsolateManager._internal();
  LanServerIsolateManager._internal();
  
  Isolate? _serverIsolate;
  ReceivePort? _uiReceivePort;
  SendPort? _serverSendPort;

  final _eventStreamController = StreamController<LanServerUpdate>.broadcast();
  Stream<LanServerUpdate> get serverEvents => _eventStreamController.stream;

  bool _isServerRunning = false;
  bool get isServerRunning => _isServerRunning;

  /// Spawns the background Dart Isolate and sets up two-way port communications
  Future<void> initializeAndStart({
    required String hostIp,
    int port = 8080,
    String? pdfPath,
    String? webClientHtml,
  }) async {
    if (_isServerRunning) return;

    _uiReceivePort = ReceivePort();

    // Spawn the isolated thread, passing the UI's SendPort to the entrypoint
    _serverIsolate = await Isolate.spawn(
      _isolateEntryPoint,
      _uiReceivePort!.sendPort,
    );

    // Listen for incoming messages from the background thread
    _uiReceivePort!.listen((dynamic message) {
      if (message is SendPort) {
        // Handshake step: Background thread sent its SendPort back to us
        _serverSendPort = message;
        
        // Dispatch command to bind the HTTP/WS server sockets
        _serverSendPort!.send(StartLanServerCommand(
          hostIp: hostIp,
          port: port,
          activePdfPath: pdfPath,
          webClientHtml: webClientHtml,
        ));
      } else if (message is LanServerUpdate) {
        if (message is ServerStateChangedUpdate) {
          _isServerRunning = message.isRunning;
        }
        _eventStreamController.add(message);
      }
    });
  }

  /// Updates the browser web client HTML served at GET / after start.
  void setWebClient(String html) {
    if (_serverSendPort != null) {
      _serverSendPort!.send(SetWebClientCommand(html));
    }
  }

  /// Broadcasts a slide page change event to all connected student WebSockets
  void sendSlideChange(int pageIndex) {
    if (_isServerRunning && _serverSendPort != null) {
      _serverSendPort!.send(BroadcastSlideCommand(pageIndex));
    }
  }

  /// Serves a file via GET /file and broadcasts FILE_PRESENTATION_START to students
  void serveFile({
    required String filePath,
    required String filename,
    required String mimeType,
    required int sizeBytes,
    String? slideDir,
    int slideCount = 0,
  }) {
    if (_isServerRunning && _serverSendPort != null) {
      _serverSendPort!.send(ServeFileCommand(
        filePath: filePath,
        filename: filename,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        slideDir: slideDir,
        slideCount: slideCount,
      ));
    }
  }

  /// Shuts down the background Isolate and frees system socket bounds
  void stopServer() {
    if (_serverSendPort != null) {
      _serverSendPort!.send(StopLanServerCommand());
    }
    _isolateCleanup();
  }

  /// Ends the active presentation and sends students back to lobby
  /// without stopping the server.
  void stopPresentation() {
    if (_isServerRunning && _serverSendPort != null) {
      _serverSendPort!.send(StopPresentationCommand());
    }
  }

  /// Broadcasts a quiz to all connected students.
  void startQuiz({
    required String quizId,
    required String quizTitle,
    required String questionsJson,
  }) {
    if (_isServerRunning && _serverSendPort != null) {
      _serverSendPort!.send(StartQuizCommand(
        quizId: quizId,
        quizTitle: quizTitle,
        questionsJson: questionsJson,
      ));
    }
  }

  /// Ends the active quiz and broadcasts QUIZ_ENDED to students.
  void stopQuiz() {
    if (_isServerRunning && _serverSendPort != null) {
      _serverSendPort!.send(StopQuizCommand());
    }
  }

  void _isolateCleanup() {
    _serverIsolate?.kill(priority: Isolate.immediate);
    _uiReceivePort?.close();
    _serverIsolate = null;
    _uiReceivePort = null;
    _serverSendPort = null;
    _isServerRunning = false;
    _eventStreamController.add(ServerStateChangedUpdate(isRunning: false));
  }
}

// -----------------------------------------------------------------------------
// BACKGROUND ISOLATE ENTRYPOINT (Executes in separate memory heap)
// -----------------------------------------------------------------------------

void _isolateEntryPoint(SendPort uiSendPort) {
  final isolateReceivePort = ReceivePort();

  // Send this thread's SendPort back to the Main UI Isolate
  uiSendPort.send(isolateReceivePort.sendPort);

  HttpServer? localHttpServer;
  final List<WebSocket> activeStudentSockets = [];

  // Active file being served via GET /file
  String? servedFilePath;
  String? servedFilename;
  String? servedMimeType;
  int servedSizeBytes = 0;

  // Browser web client + page-accurate slide sync
  String? webClientHtml;
  String? slideDir;   // directory holding slide_0.png, slide_1.png, …
  int slideCount = 0;

  // Active quiz state
  String? activeQuizId;
  String? activeQuizTitle;
  List<Map<String, dynamic>> activeQuestions = [];

  isolateReceivePort.listen((dynamic message) async {
    if (message is StartLanServerCommand) {
      webClientHtml = message.webClientHtml;
      try {
        // Bind native Dart HTTP server directly to the local hotspot interface
        localHttpServer = await HttpServer.bind(
          message.hostIp,
          message.port,
          shared: true,
        );

        uiSendPort.send(ServerStateChangedUpdate(
          isRunning: true,
          boundAddress: "http://${message.hostIp}:${message.port}",
        ));

        // Start listening to incoming TCP requests
        localHttpServer!.listen((HttpRequest request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            // Upgrade standard HTTP to real-time WebSocket protocol
            final socket = await WebSocketTransformer.upgrade(request);
            activeStudentSockets.add(socket);
            final remoteIp =
                request.connectionInfo?.remoteAddress.address ?? 'Unknown';

            uiSendPort.send(StudentConnectedUpdate(
              studentIp: remoteIp,
              totalConnectedCount: activeStudentSockets.length,
            ));

            socket.listen(
              (payload) {
                // Parse incoming student messages
                try {
                  final data = jsonDecode(payload as String) as Map<String, dynamic>;
                  final event = data['event'] as String?;

                  switch (event) {
                    case 'HANDSHAKE':
                      final studentName =
                          data['name'] as String? ?? 'Student';
                      if (socket.readyState == WebSocket.open) {
                        final ackMap = <String, dynamic>{
                          'event': 'HANDSHAKE_ACK',
                          'status': 'connected',
                        };
                        if (servedFilename != null) {
                          ackMap['current_file'] = {
                            'event': 'FILE_PRESENTATION_START',
                            'filename': servedFilename,
                            'mime_type': servedMimeType ?? 'application/pdf',
                            'size_bytes': servedSizeBytes,
                            'url': '/file',
                            'slide_count': slideCount,
                            'timestamp': DateTime.now().millisecondsSinceEpoch,
                          };
                        }
                        if (activeQuizId != null) {
                          final studentQs = activeQuestions.map((q) => {
                            'id': q['id'],
                            'text': q['question_text'],
                            'type': q['question_type'],
                            'options': q['options'] != null
                                ? jsonDecode(q['options'] as String)
                                : null,
                            'points': q['points'] ?? 1,
                          }).toList();
                          ackMap['current_quiz'] = {
                            'event': 'QUIZ_START',
                            'quiz_id': activeQuizId,
                            'title': activeQuizTitle ?? '',
                            'questions': studentQs,
                          };
                        }
                        socket.add(jsonEncode(ackMap));
                      }
                      // Re-send update with name so the UI can record attendance
                      uiSendPort.send(StudentConnectedUpdate(
                        studentIp: remoteIp,
                        studentName: studentName,
                        totalConnectedCount: activeStudentSockets.length,
                      ));
                    case 'RAISE_HAND':
                      uiSendPort.send(StudentConnectedUpdate(
                        studentIp: remoteIp,
                        totalConnectedCount: activeStudentSockets.length,
                      ));
                    default:
                      break;
                  }
                } catch (_) {
                  // Non-JSON payload — ignore
                }
              },
              onDone: () {
                activeStudentSockets.remove(socket);
                uiSendPort.send(StudentConnectedUpdate(
                  studentIp: remoteIp,
                  isDisconnect: true,
                  totalConnectedCount: activeStudentSockets.length,
                ));
              },
              onError: (_) {
                activeStudentSockets.remove(socket);
              },
            );
          } else {
            // HTTP file serving endpoint
            request.response.headers.add('Access-Control-Allow-Origin', '*');
            if (request.uri.path == '/file' && servedFilePath != null) {
              final file = File(servedFilePath!);
              if (await file.exists()) {
                final parts = (servedMimeType ?? 'application/octet-stream').split('/');
                request.response.headers.contentType =
                    ContentType(parts[0], parts.length > 1 ? parts[1] : 'octet-stream');
                request.response.headers
                    .set('Content-Disposition', 'attachment; filename="$servedFilename"');
                request.response.contentLength = await file.length();
                await request.response.addStream(file.openRead());
              } else {
                request.response.statusCode = HttpStatus.notFound;
                request.response.write('File not found');
              }
              await request.response.close();
            } else if (request.uri.path == '/quiz-submit' && request.method == 'POST') {
              try {
                if (activeQuizId == null) {
                  request.response.statusCode = HttpStatus.conflict;
                  request.response.headers.contentType = ContentType.json;
                  request.response.write(jsonEncode({'error': 'No active quiz'}));
                } else {
                  final bodyBytes = await request.toList();
                  final body = utf8.decode(bodyBytes.expand((b) => b).toList());
                  final data = jsonDecode(body) as Map<String, dynamic>;
                  final studentName = data['student_name'] as String? ?? 'Unknown';
                  final studentIp = request.connectionInfo?.remoteAddress.address ?? 'Unknown';
                  final rawAnswers = (data['answers'] as List?)?.cast<Map<String, dynamic>>() ?? [];

                  int score = 0;
                  int scorableTotal = 0;
                  final results = <Map<String, dynamic>>[];

                  for (final a in rawAnswers) {
                    final qId = a['question_id'] as String? ?? '';
                    final givenAnswer = (a['answer'] as String? ?? '').trim().toLowerCase();
                    Map<String, dynamic> question = {};
                    for (final q in activeQuestions) {
                      if (q['id'] == qId) { question = q; break; }
                    }
                    final qType = question['question_type'] as String? ?? '';
                    final correctAnswer = question['correct_answer'] as String?;
                    final hintsRaw = question['hints'];
                    final hintsDecoded = hintsRaw != null ? jsonDecode(hintsRaw as String) : null;
                    final isScored = qType == 'multiple_choice' || qType == 'true_false';
                    bool? isCorrect;
                    if (isScored && correctAnswer != null) {
                      scorableTotal++;
                      isCorrect = givenAnswer == correctAnswer.trim().toLowerCase();
                      if (isCorrect) score++;
                    }
                    results.add({
                      'question_id': qId,
                      'your_answer': a['answer'],
                      'is_correct': isCorrect,
                      'correct_answer': correctAnswer,
                      'hints': hintsDecoded,
                    });
                  }

                  uiSendPort.send(QuizSubmissionUpdate(
                    studentName: studentName,
                    studentIp: studentIp,
                    quizId: activeQuizId!,
                    score: score,
                    scorableTotal: scorableTotal,
                    results: results,
                  ));

                  request.response.headers.contentType = ContentType.json;
                  request.response.write(jsonEncode({
                    'status': 'ok',
                    'score': score,
                    'scorable_total': scorableTotal,
                    'results': results,
                  }));
                }
              } catch (e) {
                request.response.statusCode = HttpStatus.internalServerError;
                request.response.write(jsonEncode({'error': e.toString()}));
              }
              await request.response.close();
            } else if (request.uri.path == '/' || request.uri.path == '/index.html') {
              // Browser web client (smart TV / laptop viewers)
              request.response.headers.contentType =
                  ContentType('text', 'html', charset: 'utf-8');
              request.response.write(
                  webClientHtml ?? '<h1>AsuraTECH Edge Node Active</h1>');
              await request.response.close();
            } else if (request.uri.path == '/view' && servedFilePath != null) {
              // Serve the current presentation INLINE for in-browser display.
              final file = File(servedFilePath!);
              if (await file.exists()) {
                final parts =
                    (servedMimeType ?? 'application/octet-stream').split('/');
                request.response.headers.contentType = ContentType(
                    parts[0], parts.length > 1 ? parts[1] : 'octet-stream');
                request.response.headers
                    .set('Content-Disposition', 'inline');
                request.response.contentLength = await file.length();
                await request.response.addStream(file.openRead());
              } else {
                request.response.statusCode = HttpStatus.notFound;
                request.response.write('No presentation');
              }
              await request.response.close();
            } else if (request.uri.path.startsWith('/slide/')) {
              // Page-accurate rasterized slide image: /slide/{index}
              final idxStr = request.uri.path.substring('/slide/'.length);
              final idx = int.tryParse(idxStr);
              File? slideFile;
              if (idx != null && slideDir != null) {
                final f = File('$slideDir/slide_$idx.png');
                if (await f.exists()) slideFile = f;
              }
              if (slideFile != null) {
                request.response.headers.contentType = ContentType('image', 'png');
                request.response.headers
                    .set('Cache-Control', 'no-cache');
                request.response.contentLength = await slideFile.length();
                await request.response.addStream(slideFile.openRead());
              } else {
                request.response.statusCode = HttpStatus.notFound;
                request.response.write('Slide not found');
              }
              await request.response.close();
            } else {
              request.response.statusCode = HttpStatus.ok;
              request.response.write('AsuraTECH Edge Node Active');
              await request.response.close();
            }
          }
        });
      } catch (e) {
        uiSendPort.send(ServerStateChangedUpdate(
          isRunning: false,
          errorMessage: e.toString(),
        ));
      }
    }

    if (message is SetWebClientCommand) {
      webClientHtml = message.html;
    }

    if (message is ServeFileCommand) {
      servedFilePath = message.filePath;
      servedFilename = message.filename;
      servedMimeType = message.mimeType;
      servedSizeBytes = message.sizeBytes;
      slideDir = message.slideDir;
      slideCount = message.slideCount;

      // Broadcast FILE_PRESENTATION_START to all connected students
      final payload = jsonEncode({
        'event': 'FILE_PRESENTATION_START',
        'filename': message.filename,
        'mime_type': message.mimeType,
        'size_bytes': message.sizeBytes,
        'url': '/file', // students prepend ws://host:8080 themselves
        'slide_count': message.slideCount,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      for (final clientSocket in activeStudentSockets) {
        if (clientSocket.readyState == WebSocket.open) {
          clientSocket.add(payload);
        }
      }
    }

    if (message is BroadcastSlideCommand) {
      // Stringify payload for low-latency JSON delivery
      final payload = jsonEncode({
        'event': 'PAGE_CHANGE',
        'page_index': message.pageIndex,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      for (final clientSocket in activeStudentSockets) {
        if (clientSocket.readyState == WebSocket.open) {
          clientSocket.add(payload);
        }
      }
    }

    if (message is StopPresentationCommand) {
      // Notify all students and close their connections,
      // but leave the HTTP server running for reconnects.
      const endPayload = '{"event":"PRESENTATION_ENDED"}';
      for (final ws in activeStudentSockets) {
        if (ws.readyState == WebSocket.open) {
          try { ws.add(endPayload); } catch (_) {}
        }
      }
      servedFilePath = null;
      servedFilename = null;
      servedMimeType = null;
      servedSizeBytes = 0;
      slideDir = null;
      slideCount = 0;
      for (final socket in List.from(activeStudentSockets)) {
        await socket.close();
      }
      activeStudentSockets.clear();
    }

    if (message is StartQuizCommand) {
      activeQuizId = message.quizId;
      activeQuizTitle = message.quizTitle;
      activeQuestions = (jsonDecode(message.questionsJson) as List).cast<Map<String, dynamic>>();

      final studentQs = activeQuestions.map((q) => {
        'id': q['id'],
        'text': q['question_text'],
        'type': q['question_type'],
        'options': q['options'] != null ? jsonDecode(q['options'] as String) : null,
        'points': q['points'] ?? 1,
      }).toList();

      final payload = jsonEncode({
        'event': 'QUIZ_START',
        'quiz_id': message.quizId,
        'title': message.quizTitle,
        'questions': studentQs,
      });
      for (final ws in activeStudentSockets) {
        if (ws.readyState == WebSocket.open) {
          try { ws.add(payload); } catch (_) {}
        }
      }
    }

    if (message is StopQuizCommand) {
      activeQuizId = null;
      activeQuizTitle = null;
      activeQuestions = [];
      const payload = '{"event":"QUIZ_ENDED"}';
      for (final ws in activeStudentSockets) {
        if (ws.readyState == WebSocket.open) {
          try { ws.add(payload); } catch (_) {}
        }
      }
    }

    if (message is StopLanServerCommand) {
      // Notify students so lobby can react immediately
      const endPayload = '{"event":"PRESENTATION_ENDED"}';
      for (final ws in activeStudentSockets) {
        if (ws.readyState == WebSocket.open) {
          try { ws.add(endPayload); } catch (_) {}
        }
      }
      servedFilePath = null;
      servedFilename = null;
      servedMimeType = null;
      servedSizeBytes = 0;
      for (final socket in activeStudentSockets) {
        await socket.close();
      }
      activeStudentSockets.clear();
      await localHttpServer?.close(force: true);
      uiSendPort.send(ServerStateChangedUpdate(isRunning: false));
    }
  });
}