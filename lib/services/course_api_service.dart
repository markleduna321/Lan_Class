// lib/services/course_api_service.dart
//
// Course Academy API client.
// Course routes live under the dedicated Flutter group (/api/mobile/...);
// certificate routes are shared with the web app (/api/...).

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../features/academy/course_models.dart';
import 'cloud_api_service.dart';

typedef CourseActionResult = ({bool ok, String error, bool blocked});
typedef ActivitySubmitResult = ({
  bool ok,
  String error,
  ActivitySubmission? submission,
});

class CourseApiService {
  static const _mobilePrefix = '/api/mobile';
  static const _webPrefix = '/api';

  // -----------------------------------------------------------------------
  // Courses
  // -----------------------------------------------------------------------

  static Future<List<Course>> fetchCourses() async {
    final response = await _getWithFallback('/courses');
    if (response == null || response.statusCode != 200) {
      debugPrint('[Courses] list failed: ${response?.statusCode}');
      return const [];
    }
    try {
      final raw = unwrapList(jsonDecode(response.body), keys: ['courses']);
      debugPrint('[Courses] loaded ${raw.length} course records');
      return raw.map(Course.fromJson).toList();
    } catch (e) {
      debugPrint('[Courses] list parse error: $e');
      return const [];
    }
  }

  static Future<Course?> fetchCourseDetail(String courseId) async {
    final response = await _getWithFallback('/courses/$courseId');
    if (response == null || response.statusCode != 200) {
      debugPrint('[Courses] detail failed: ${response?.statusCode}');
      return null;
    }
    try {
      final map = unwrapObject(jsonDecode(response.body), keys: ['course']);
      return map == null ? null : Course.fromJson(map);
    } catch (e) {
      debugPrint('[Courses] detail parse error: $e');
      return null;
    }
  }

  static Future<CourseActionResult> enroll(String courseId) async {
    final response =
        await _postWithFallback('/courses/$courseId/enroll', const {});
    return _resultFrom(response, fallback: 'Could not enroll. Try again.');
  }

  static Future<CourseActionResult> completeLesson({
    required String courseId,
    required String lessonId,
  }) async {
    final response = await _postWithFallback(
      '/courses/$courseId/lessons/$lessonId/complete',
      {'lesson_id': lessonId, 'course_id': courseId},
    );
    return _resultFrom(response, fallback: 'Could not save your progress.');
  }

  // -----------------------------------------------------------------------
  // Activities
  // -----------------------------------------------------------------------

  /// GET /api/mobile/activities/{id}/submission — restores a prior attempt.
  static Future<ActivitySubmission?> fetchActivitySubmission(
      String activityId) async {
    final response =
        await _getWithFallback('/activities/$activityId/submission');
    if (response == null || response.statusCode != 200) return null;
    return _parseSubmission(response.body);
  }

  /// POST /api/mobile/activities/{id}/submit — body shape depends on the type.
  static Future<ActivitySubmitResult> submitActivity({
    required String activityId,
    required Map<String, dynamic> body,
  }) async {
    final response =
        await _postWithFallback('/activities/$activityId/submit', body);
    final base = _resultFrom(response, fallback: 'Could not submit.');
    if (!base.ok) {
      return (ok: false, error: base.error, submission: null);
    }
    final submission = _parseSubmission(response!.body) ??
        await fetchActivitySubmission(activityId);
    return (
      ok: true,
      error: '',
      submission: submission,
    );
  }

  static ActivitySubmission? _parseSubmission(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['submission'] == null) return null;
      final map = unwrapObject(decoded, keys: ['submission']);
      return map == null ? null : ActivitySubmission.fromJson(map);
    } catch (e) {
      debugPrint('[Activities] parse error: $e');
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Certificates
  // -----------------------------------------------------------------------

  /// GET /api/courses/{id}/certificate — issued cert for a finished course.
  static Future<Certificate?> fetchCourseCertificate(String courseId) async {
    final response =
        await CloudApiService.get('$_webPrefix/courses/$courseId/certificate');
    if (response == null || response.statusCode != 200) {
      debugPrint('[Certificates] course cert failed: ${response?.statusCode}');
      return null;
    }
    return _parseCertificate(response.body);
  }

  /// GET /api/certificates — every certificate owned by the signed-in user.
  static Future<List<Certificate>> fetchMyCertificates() async {
    final response = await CloudApiService.get('$_webPrefix/certificates');
    if (response == null || response.statusCode != 200) {
      debugPrint('[Certificates] list failed: ${response?.statusCode}');
      return const [];
    }
    try {
      final raw =
          unwrapList(jsonDecode(response.body), keys: ['certificates']);
      return raw.map(Certificate.fromJson).toList();
    } catch (e) {
      debugPrint('[Certificates] list parse error: $e');
      return const [];
    }
  }

  /// GET /api/certificates/{uuid} — public verification, no auth required.
  static Future<Certificate?> verifyCertificate(String uuid) async {
    final response =
        await CloudApiService.get('$_webPrefix/certificates/$uuid');
    if (response == null || response.statusCode != 200) return null;
    return _parseCertificate(response.body);
  }

  static String verificationUrl(String uuid) =>
      '${CloudApiService.serverBaseUrl}$_webPrefix/certificates/$uuid';

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  static Certificate? _parseCertificate(String body) {
    try {
      final map = unwrapObject(jsonDecode(body), keys: ['certificate']);
      if (map == null) return null;
      final certificate = Certificate.fromJson(map);
      return certificate.uuid.isEmpty ? null : certificate;
    } catch (e) {
      debugPrint('[Certificates] parse error: $e');
      return null;
    }
  }

  /// 404 on the mobile group means the route was never mirrored there.
  static Future<http.Response?> _getWithFallback(String path) async {
    final mobile = await CloudApiService.get('$_mobilePrefix$path');
    if (mobile != null && mobile.statusCode != 404) return mobile;
    return CloudApiService.get('$_webPrefix$path');
  }

  static Future<http.Response?> _postWithFallback(
      String path, Map<String, dynamic> body) async {
    final mobile = await CloudApiService.post('$_mobilePrefix$path', body);
    if (mobile != null && mobile.statusCode != 404) return mobile;
    return CloudApiService.post('$_webPrefix$path', body);
  }

  static CourseActionResult _resultFrom(
    http.Response? response, {
    required String fallback,
  }) {
    if (response == null) {
      return (
        ok: false,
        error: 'No connection. Check your internet.',
        blocked: false
      );
    }
    final code = response.statusCode;
    if (code == 200 || code == 201 || code == 204) {
      return (ok: true, error: '', blocked: false);
    }
    // 403/422 means the server refused on a rule, not a transport failure.
    final blocked = code == 403 || code == 422;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['message'] is String) {
        return (
          ok: false,
          error: decoded['message'] as String,
          blocked: blocked
        );
      }
    } catch (_) {}
    return (ok: false, error: '$fallback ($code)', blocked: blocked);
  }
}
