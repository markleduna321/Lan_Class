// lib/services/online_session_service.dart
//
// Phase 4 — Online Live Session (WebSocket)
// Manages session lifecycle (REST) and Reverb WebSocket connection.

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'cloud_api_service.dart';
import 'lan_server_isolate.dart';
import 'lan_server_messages.dart';

/// Unified stream event map passed to listeners.
/// Always contains an `event` key (String).
typedef SessionEvent = Map<String, dynamic>;

// ---------------------------------------------------------------------------
// OnlineSessionService
// ---------------------------------------------------------------------------

class OnlineSessionService {
  // Singleton — one WS connection at a time
  static final OnlineSessionService instance = OnlineSessionService._();
  OnlineSessionService._();

  WebSocketChannel? _ws;
  StreamController<SessionEvent>? _controller;
  Timer? _reconnectTimer;
  bool _isConnected = false;
  String? _pendingWsUrl;
  String? _pendingChannel;

  bool get isConnected => _isConnected;

  Stream<SessionEvent> get eventStream {
    _controller ??= StreamController<SessionEvent>.broadcast();
    return _controller!.stream;
  }

  // =========================================================================
  // REST — Teacher operations
  // =========================================================================

  /// POST /api/sessions — creates a live session for a published classroom.
  /// Returns `{id, channel, ws_url, ...}` or null on failure.
  static Future<Map<String, dynamic>?> createSession(
      String classroomRemoteId) async {
    final response = await CloudApiService.post('/api/sessions', {
      'classroom_id': classroomRemoteId,
    });
    if (response == null) return null;
    if (response.statusCode == 200 || response.statusCode == 201) {
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// POST /api/sessions/{id}/end — ends the live session.
  static Future<bool> endSession(String sessionId) async {
    final response =
        await CloudApiService.post('/api/sessions/$sessionId/end', {});
    return response != null &&
        (response.statusCode == 200 || response.statusCode == 204);
  }

  /// POST /api/sessions/{id}/broadcast — pushes an event to all online students.
  /// [event] matches LAN events: SLIDE_START, SLIDE_CHANGE, PRESENTATION_ENDED,
  ///         QUIZ_START, QUIZ_ENDED, PARTICIPANT_UPDATE.
  static Future<bool> broadcastEvent(
      String sessionId, String event, Map<String, dynamic> data) async {
    final response = await CloudApiService.post(
      '/api/sessions/$sessionId/broadcast',
      {'event': event, 'data': data},
    );
    final ok = response != null &&
        (response.statusCode == 200 || response.statusCode == 204);
    if (!ok) {
      // ignore: avoid_print
      print('[OnlineSessionService] broadcastEvent "$event" failed'
          ' — status: ${response?.statusCode}'
          ' — body: ${response?.body}');
    }
    return ok;
  }

  /// GET /api/sessions/{id}/participants
  static Future<List<Map<String, dynamic>>> getParticipants(
      String sessionId) async {
    final response =
        await CloudApiService.get('/api/sessions/$sessionId/participants');
    if (response == null || response.statusCode != 200) return [];
    try {
      final decoded = jsonDecode(response.body);
      final List<dynamic> raw =
          decoded is List ? decoded : (decoded['data'] as List? ?? []);
      return raw.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// POST /api/sessions/{id}/join — returns Jitsi room join data.
  /// Response includes: room_name, display_name, jwt, subject, jaas, role, room_url.
  static Future<Map<String, dynamic>?> joinSession(String sessionId) async {
    final response =
        await CloudApiService.post('/api/sessions/$sessionId/join', {});
    if (response == null) return null;
    if (response.statusCode == 200) {
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// GET /api/sessions/{id}
  static Future<Map<String, dynamic>?> getSession(String sessionId) async {
    final response = await CloudApiService.get('/api/sessions/$sessionId');
    if (response == null || response.statusCode != 200) return null;
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // Phase 7 — Raise Hand helpers
  // =========================================================================

  /// Student raises hand: POST /api/sessions/{id}/hand/raise
  static Future<bool> raiseHand(
      String sessionId, String studentId, String studentName) async {
    final response = await CloudApiService.post(
      '/api/sessions/$sessionId/hand/raise',
      {'student_id': studentId, 'student_name': studentName},
    );
    return response != null &&
        (response.statusCode == 200 || response.statusCode == 204);
  }

  /// Student lowers hand: POST /api/sessions/{id}/hand/lower
  static Future<bool> lowerHand(String sessionId, String studentId) async {
    final response = await CloudApiService.post(
      '/api/sessions/$sessionId/hand/lower',
      {'student_id': studentId},
    );
    return response != null &&
        (response.statusCode == 200 || response.statusCode == 204);
  }

  /// Teacher calls on a student: POST /api/sessions/{id}/hand/call
  /// Server broadcasts CALLED_ON to the target student.
  static Future<bool> callOnStudent(
      String sessionId, String studentId) async {
    final response = await CloudApiService.post(
      '/api/sessions/$sessionId/hand/call',
      {'student_id': studentId},
    );
    return response != null &&
        (response.statusCode == 200 || response.statusCode == 204);
  }

  // =========================================================================
  // Phase 8 — LAN ↔ Online Bridge
  // =========================================================================

  /// Subscribe to LAN server events and forward student join/leave as
  /// PARTICIPANT_UPDATE events on the Reverb channel.
  /// Call this after both LAN and online sessions are active.
  static StreamSubscription<LanServerUpdate>? _lanBridgeSub;

  static void startLanBridge(String sessionId) {
    _lanBridgeSub?.cancel();
    _lanBridgeSub =
        LanServerIsolateManager.instance.serverEvents.listen((update) {
      if (update is StudentConnectedUpdate &&
          (update.studentName?.isNotEmpty ?? false)) {
        // Forward LAN attendance as PARTICIPANT_UPDATE so the online teacher
        // session view can show a LAN student count.
        broadcastEvent(sessionId, 'PARTICIPANT_UPDATE', {
          'source':    'lan',
          'name':      update.studentName ?? '',
          'ip':        update.studentIp,
          'connected': !update.isDisconnect,
          'total_lan': update.totalConnectedCount,
        });
      }
    });
  }

  static void stopLanBridge() {
    _lanBridgeSub?.cancel();
    _lanBridgeSub = null;
  }

  // =========================================================================
  // WebSocket — Student connection (Reverb / Pusher protocol)
  // =========================================================================

  /// Opens a WebSocket to [wsUrl] and subscribes to [channelName].
  /// Emits synthetic events on [eventStream]:
  ///   - `{event: 'CONNECTED'}` when subscription succeeds
  ///   - `{event: 'DISCONNECTED'}` on drop
  ///   - All app events forwarded as-is
  Future<void> connectToSession({
    required String wsUrl,
    required String channelName,
    String? authToken, // Sanctum token for private-channel auth
  }) async {
    _pendingWsUrl = wsUrl;
    _pendingChannel = channelName;
    _controller ??= StreamController<SessionEvent>.broadcast();
    await _openWs(wsUrl: wsUrl, channelName: channelName, authToken: authToken);
  }

  Future<void> _openWs({
    required String wsUrl,
    required String channelName,
    String? authToken,
  }) async {
    try {
      final wsUri = Uri.parse(wsUrl);
      _ws = WebSocketChannel.connect(wsUri);
      _ws!.stream.listen(
        (raw) => _handleRaw(raw, channelName),
        onError: (_) => _onDropped(),
        onDone: () => _onDropped(),
        cancelOnError: true,
      );
    } catch (_) {
      _onDropped();
    }
  }

  void _handleRaw(dynamic raw, String channelName) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final event = msg['event'] as String? ?? '';

      if (event == 'pusher:connection_established') {
        // Pusher: subscribe to the channel once connected
        _ws?.sink.add(jsonEncode({
          'event': 'pusher:subscribe',
          'data': {'channel': channelName},
        }));
        return;
      }

      if (event == 'pusher:error') {
        // Connection rejected by Reverb (e.g. wrong app key)
        // ignore: avoid_print
        print('[OnlineSessionService] pusher:error — ${msg['data']}');
        _onDropped();
        return;
      }

      if (event == 'pusher_internal:subscription_succeeded') {
        _isConnected = true;
        _emit({'event': 'CONNECTED', 'channel': channelName});
        return;
      }

      if (event == 'pusher_internal:subscription_error') {
        // Channel subscription failed (private-channel auth or bad channel)
        // ignore: avoid_print
        print('[OnlineSessionService] subscription_error — ${msg['data']}');
        _emit({'event': 'DISCONNECTED'});
        return;
      }

      // Ignore internal Pusher/Laravel Echo management events
      if (event.startsWith('pusher') || event.startsWith('pusher_internal')) {
        return;
      }

      // App event — data may be JSON-encoded string or already a map
      final rawData = msg['data'];
      Map<String, dynamic> payload;
      if (rawData is String) {
        try {
          payload = jsonDecode(rawData) as Map<String, dynamic>;
        } catch (_) {
          payload = {};
        }
      } else if (rawData is Map<String, dynamic>) {
        payload = rawData;
      } else {
        payload = {};
      }

      _emit({'event': event, ...payload});
    } catch (_) {}
  }

  void _onDropped() {
    _isConnected = false;
    _emit({'event': 'DISCONNECTED'});
    // Schedule reconnect
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (_pendingWsUrl != null && _pendingChannel != null) {
        _openWs(wsUrl: _pendingWsUrl!, channelName: _pendingChannel!);
      }
    });
  }

  void _emit(SessionEvent event) {
    if (_controller != null && !_controller!.isClosed) {
      _controller!.add(event);
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _isConnected = false;
    _pendingWsUrl = null;
    _pendingChannel = null;
    try {
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _controller?.add({'event': 'DISCONNECTED'});
  }
}

// ---------------------------------------------------------------------------
// Helper — derives the Reverb WS URL from the stored API base URL.
// Falls back to server-provided ws_url if available.
// ---------------------------------------------------------------------------

class OnlineSessionUrlHelper {
  OnlineSessionUrlHelper._();

  /// Returns the Reverb WebSocket URL derived from the base URL.
  /// e.g. https://api.example.com → wss://api.example.com/app/reverb
  /// Override with [serverProvidedUrl] if the session response includes ws_url.
  static Future<String> getWsUrl({String? serverProvidedUrl}) async {
    // Ignore the legacy-only placeholder the backend now returns for ws_url
    if (serverProvidedUrl != null &&
        serverProvidedUrl.isNotEmpty &&
        serverProvidedUrl != 'legacy-only') {
      return serverProvidedUrl;
    }
    final base = await CloudApiService.getBaseUrl();
    if (base.isEmpty) return '';
    // Convert https:// → wss://, http:// → ws://
    final wsBase =
        base.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
    return '$wsBase/app/reverb';
  }
}
