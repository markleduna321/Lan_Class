// lib/services/cloud_sync_service.dart
//
// Phase 2 — Publish Classrooms & Sync Materials
// Handles multipart uploads and classroom publish/unpublish operations.
// All methods are static and use CloudApiService for base URL + token.

import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'cloud_api_service.dart';

/// Result returned after a successful material sync.
typedef MaterialSyncResult = ({String remoteId, String remoteUrl});

/// Result returned by publishClassroom.
typedef PublishResult = ({String? remoteId, String error});

class CloudSyncService {
  static const _storage = FlutterSecureStorage();

  // -----------------------------------------------------------------------
  // Classrooms
  // -----------------------------------------------------------------------

  /// POST /api/classrooms
  /// Returns a [PublishResult] — check `remoteId != null` for success.
  static Future<PublishResult> publishClassroom(Map<String, dynamic> classroom) async {
    final response = await CloudApiService.post('/api/classrooms', {
      'id':          classroom['id'],
      'name':        classroom['name'],
      'description': classroom['description'] ?? '',
      'schedule':    classroom['schedule'] ?? '',
      'visibility':  classroom['visibility'] ?? 'public',
    });

    if (response == null) {
      return (remoteId: null, error: 'No response — check your internet connection.');
    }
    if (response.statusCode == 200 || response.statusCode == 201) {
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        // Server may wrap in {"data": {...}} or return flat {"id": ...}
        final inner = data['data'] is Map ? data['data'] as Map<String, dynamic> : data;
        final id = (inner['id'] ?? classroom['id'])?.toString();
        return (remoteId: id, error: '');
      } catch (_) {
        // Parsing failed but HTTP succeeded — use the local UUID
        return (remoteId: classroom['id']?.toString(), error: '');
      }
    }

    String serverMsg = 'Server error (${response.statusCode})';
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      serverMsg = (body['message'] as String?) ?? serverMsg;
    } catch (_) {}
    return (remoteId: null, error: serverMsg);
  }

  /// DELETE /api/classrooms/{remoteId}
  /// Returns true on success.
  static Future<bool> unpublishClassroom(String remoteId) async {
    try {
      final base  = await CloudApiService.getBaseUrl();
      final token = await _storage.read(key: CloudApiService.kToken);
      if (base.isEmpty || token == null) return false;

      final response = await http
          .delete(
            Uri.parse('$base/api/classrooms/$remoteId'),
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 15));

      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  // -----------------------------------------------------------------------
  // Materials
  // -----------------------------------------------------------------------

  /// POST /api/classrooms/{classroomRemoteId}/materials  (multipart)
  /// Returns {remoteId, remoteUrl} on success, or null on failure.
  static Future<MaterialSyncResult?> syncMaterial({
    required String classroomRemoteId,
    required String filePath,
    required String originalName,
    required String mimeType,
    String? materialId,
  }) async {
    try {
      final base  = await CloudApiService.getBaseUrl();
      final token = await _storage.read(key: CloudApiService.kToken);
      if (base.isEmpty || token == null) return null;

      final file  = File(filePath);
      final bytes = await file.readAsBytes();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$base/api/classrooms/$classroomRemoteId/materials'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Accept'] = 'application/json';
      // Backend requires these fields alongside the file.
      request.fields['id']            = materialId ?? '';
      request.fields['original_name'] = originalName;
      request.fields['mime_type']     = mimeType;
      request.fields['size_bytes']    = bytes.length.toString();
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: originalName,
      ));

      final streamed = await request.send().timeout(const Duration(minutes: 3));
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        // Server may wrap in {"data": {...}} or return flat {"id": ...}
        final inner   = data['data'] is Map ? data['data'] as Map<String, dynamic> : data;
        final remoteId  = (inner['id'] ?? data['id'])?.toString() ?? '';
        final remoteUrl = (inner['url'] ?? inner['file_url'] ?? data['url'] ?? '') as String;
        if (remoteId.isEmpty) {
          // ignore: avoid_print
          print('[CloudSyncService] syncMaterial: 200 OK but no id in response: ${response.body}');
          return null;
        }
        return (remoteId: remoteId, remoteUrl: remoteUrl);
      }

      String serverMsg = 'Status ${response.statusCode}';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        serverMsg = (body['message'] as String?) ?? serverMsg;
      } catch (_) {}
      // ignore: avoid_print
      print('[CloudSyncService] syncMaterial failed: $serverMsg — body: ${response.body}');
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[CloudSyncService] syncMaterial exception: $e');
      return null;
    }
  }

  /// DELETE /api/classrooms/{classroomRemoteId}/materials/{materialRemoteId}
  /// Returns true on success.
  static Future<bool> removeMaterialFromCloud(
    String classroomRemoteId,
    String materialRemoteId,
  ) async {
    try {
      final base  = await CloudApiService.getBaseUrl();
      final token = await _storage.read(key: CloudApiService.kToken);
      if (base.isEmpty || token == null) return false;

      final response = await http
          .delete(
            Uri.parse(
                '$base/api/classrooms/$classroomRemoteId/materials/$materialRemoteId'),
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 15));

      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  /// Returns true when both a base URL and an online token are present.
  static Future<bool> get isReady async {
    final base    = await CloudApiService.getBaseUrl();
    final isLinked = await CloudApiService.isLinked;
    return base.isNotEmpty && isLinked;
  }
}
