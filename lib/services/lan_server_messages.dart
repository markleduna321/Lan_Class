// lib/services/lan_server_messages.dart

/// Base class for commands sent FROM the Main UI Isolate TO the Server Isolate
abstract class LanServerCommand {}

class StartLanServerCommand extends LanServerCommand {
  final String hostIp;
  final int port;
  final String? activePdfPath;
  /// Full HTML of the browser web client, served at GET /.
  final String? webClientHtml;

  StartLanServerCommand({
    required this.hostIp,
    this.port = 8080,
    this.activePdfPath,
    this.webClientHtml,
  });
}

/// Updates the HTML served at GET / (in case it is loaded after the server starts).
class SetWebClientCommand extends LanServerCommand {
  final String html;
  SetWebClientCommand(this.html);
}

class BroadcastSlideCommand extends LanServerCommand {
  final int pageIndex;
  BroadcastSlideCommand(this.pageIndex);
}

class StopLanServerCommand extends LanServerCommand {}

/// Ends the active file presentation and notifies students to return to lobby,
/// but keeps the HTTP/WS server running so students can reconnect.
class StopPresentationCommand extends LanServerCommand {}

/// Tells the isolate to start serving a file at GET /file and broadcast
/// FILE_PRESENTATION_START to all connected students.
///
/// For page-accurate browser sync, [slideDir] holds pre-rasterized page PNGs
/// named `slide_0.png`, `slide_1.png`, … and [slideCount] is the page count.
/// Browser clients fetch these via GET /slide/{index}.
class ServeFileCommand extends LanServerCommand {
  final String filePath;
  final String filename;
  final String mimeType;
  final int sizeBytes;
  final String? slideDir;
  final int slideCount;

  ServeFileCommand({
    required this.filePath,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    this.slideDir,
    this.slideCount = 0,
  });
}

/// Base class for updates sent FROM the Server Isolate back TO the Main UI Isolate
abstract class LanServerUpdate {}

class ServerStateChangedUpdate extends LanServerUpdate {
  final bool isRunning;
  final String? boundAddress;
  final String? errorMessage;

  ServerStateChangedUpdate({
    required this.isRunning,
    this.boundAddress,
    this.errorMessage,
  });
}

class StudentConnectedUpdate extends LanServerUpdate {
  final String studentIp;
  final String? studentName; // null for raw-connect updates; set on HANDSHAKE
  final bool isDisconnect;   // true when student leaves
  final int totalConnectedCount;

  StudentConnectedUpdate({
    required this.studentIp,
    this.studentName,
    this.isDisconnect = false,
    required this.totalConnectedCount,
  });
}

// -----------------------------------------------------------------------
// QUIZ COMMANDS
// -----------------------------------------------------------------------

/// Tells the isolate to start a quiz. The isolate broadcasts QUIZ_START to
/// students (stripping correct_answer/hints from the student payload) and
/// stores full question data for scoring via POST /quiz-submit.
class StartQuizCommand extends LanServerCommand {
  final String quizId;
  final String quizTitle;
  /// JSON-encoded List of full question maps (with question_text, question_type,
  /// options, correct_answer, hints, order_index, points).
  final String questionsJson;
  StartQuizCommand({required this.quizId, required this.quizTitle, required this.questionsJson});
}

/// Tells the isolate to end the active quiz and broadcast QUIZ_ENDED to students.
class StopQuizCommand extends LanServerCommand {}

// -----------------------------------------------------------------------
// QUIZ UPDATES (Isolate → UI)
// -----------------------------------------------------------------------

/// Fired when a student submits answers via POST /quiz-submit. The teacher UI
/// receives this to store responses and update the live results view.
class QuizSubmissionUpdate extends LanServerUpdate {
  final String studentName;
  final String studentIp;
  final String quizId;
  final int score;
  final int scorableTotal;
  /// Each entry: {question_id, your_answer, is_correct, correct_answer, hints}
  final List<Map<String, dynamic>> results;

  QuizSubmissionUpdate({
    required this.studentName,
    required this.studentIp,
    required this.quizId,
    required this.score,
    required this.scorableTotal,
    required this.results,
  });
}