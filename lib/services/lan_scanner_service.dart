// lib/services/lan_scanner_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Rich scan result returned by [LanScannerService.scanForRoom].
class ScannedRoom {
  final String ip;
  final String classroomId;
  final String name;
  final String schedule;
  /// Laravel remote classroom ID — set when the teacher has published this
  /// room online. Empty string when the room is LAN-only.
  final String remoteId;

  const ScannedRoom({
    required this.ip,
    this.classroomId = '',
    this.name = '',
    this.schedule = '',
    this.remoteId = '',
  });
}

class LanScannerService {
  static RawDatagramSocket? _broadcastSocket;
  static Timer? _beaconTimer;

  // --- TEACHER: SHOUT PRESENCE TO THE NETWORK ---
  static Future<void> startBeacon(
    String serverIp, {
    String classroomId = '',
    String classroomName = '',
    String classroomSchedule = '',
    /// Laravel remote classroom ID — include when the room is published online
    /// so students can link their LAN-saved room to the online session.
    String remoteId = '',
  }) async {
    try {
      // Bind to a random port (0) just for sending — do NOT bind to 8888
      // (the student needs 8888 to be free for listening)
      _broadcastSocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _broadcastSocket!.broadcastEnabled = true;

      // Compute the subnet-directed broadcast address (e.g. 192.168.43.255)
      // This is more reliable on Android than 255.255.255.255 (limited broadcast)
      final parts = serverIp.split('.');
      if (parts.length == 4) parts[3] = '255';
      final broadcastIp = parts.join('.');

      final roomJson = jsonEncode({
        'ip': serverIp,
        'id': classroomId,
        'name': classroomName,
        'schedule': classroomSchedule,
        // Broadcast the online remote_id so students can auto-link
        if (remoteId.isNotEmpty) 'remote_id': remoteId,
      });

      _beaconTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        final payload = utf8.encode('ASURA_ROOM:$roomJson');
        _broadcastSocket?.send(
            payload, InternetAddress(broadcastIp), 8888);
      });
    } catch (e) {
      // Ignore bind errors if port is busy
    }
  }

  static void stopBeacon() {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _broadcastSocket?.close();
    _broadcastSocket = null;
  }

  // --- STUDENT: SCAN THE NETWORK ---
  static Future<ScannedRoom?> scanForRoom(
      {Duration timeout = const Duration(seconds: 4)}) async {
    final completer = Completer<ScannedRoom?>();
    RawDatagramSocket? listenSocket;

    try {
      // Open the radio receiver on port 8888
      listenSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8888,
        reuseAddress: true,
      );

      listenSocket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = listenSocket!.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);
            if (message.startsWith('ASURA_ROOM:')) {
              final body = message.substring('ASURA_ROOM:'.length);
              ScannedRoom room;
              try {
                // New JSON format
                final data = jsonDecode(body) as Map<String, dynamic>;
                room = ScannedRoom(
                  ip: data['ip'] as String,
                  classroomId: (data['id'] as String?) ?? '',
                  name: (data['name'] as String?) ?? '',
                  schedule: (data['schedule'] as String?) ?? '',
                  remoteId: (data['remote_id'] as String?) ?? '',
                );
              } catch (_) {
                // Legacy format: body is just the IP
                room = ScannedRoom(ip: body.trim());
              }
              if (!completer.isCompleted) completer.complete(room);
            }
          }
        }
      });

      // Stop listening if we don't find anything after X seconds
      Future.delayed(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });
    } catch (e) {
      if (!completer.isCompleted) completer.complete(null);
    }

    final result = await completer.future;
    listenSocket?.close();
    return result;
  }
}