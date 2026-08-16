// lib/database/asura_repository.dart

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'asura_db.dart';

class AsuraRepository {
  // -----------------------------------------------------------------------
  // PASSWORD HASHING
  // -----------------------------------------------------------------------

  /// SHA-256 hash. Sufficient for local-only storage; replace with bcrypt
  /// when the cloud sync layer is implemented.
  static String hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  // -----------------------------------------------------------------------
  // USER CRUD
  // -----------------------------------------------------------------------

  static Future<void> insertUser(Map<String, dynamic> user) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('users', user);
  }

  /// Inserts or replaces a user row using primary key conflict resolution.
  /// Useful when syncing account records from cloud auth responses.
  static Future<void> upsertUser(Map<String, dynamic> user) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert(
      'users',
      user,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> getUserById(String id) async {
    final db = await AsuraDatabase.instance.database;
    final rows = await db.query('users', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  static Future<Map<String, dynamic>?> getUserByEmail(String email) async {
    final db = await AsuraDatabase.instance.database;
    final rows = await db.query('users', where: 'email = ?', whereArgs: [email.toLowerCase()]);
    return rows.isNotEmpty ? rows.first : null;
  }

  /// Stores the Laravel remote_id returned after a successful online registration/login.
  static Future<void> updateUserRemoteId(String localId, String remoteId) async {
    final db = await AsuraDatabase.instance.database;
    await db.update(
      'users',
      {'remote_id': remoteId},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  /// Returns the user row if credentials are valid, otherwise null.
  static Future<Map<String, dynamic>?> validateLogin(
      String email, String password) async {
    final db = await AsuraDatabase.instance.database;
    final hash = hashPassword(password);
    final rows = await db.query(
      'users',
      where: 'email = ? AND password_hash = ?',
      whereArgs: [email.toLowerCase(), hash],
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  /// Returns the currently active (logged-in) user, resolved from the
  /// stored ACTIVE_USER_UUID in secure storage. Null if not signed in.
  static Future<Map<String, dynamic>?> getActiveUser() async {
    const storage = FlutterSecureStorage();
    final uuid = await storage.read(key: 'ACTIVE_USER_UUID');
    if (uuid == null || uuid.isEmpty) return null;
    return getUserById(uuid);
  }

  /// Updates editable profile fields. Only non-null values are written.
  /// [skills] and [projects] are stored as JSON strings.
  static Future<void> updateUserProfile(
    String id, {
    String? nickname,
    String? bio,
    String? skills,
    String? projects,
  }) async {
    final db = await AsuraDatabase.instance.database;
    final values = <String, dynamic>{
      'nickname': ?nickname,
      'bio': ?bio,
      'skills': ?skills,
      'projects': ?projects,
    };
    if (values.isEmpty) return;
    await db.update('users', values, where: 'id = ?', whereArgs: [id]);
  }

  /// Caches the latest aura score locally (source of truth is the server).
  static Future<void> updateAuraScore(String id, int score) async {
    final db = await AsuraDatabase.instance.database;
    await db.update('users', {'aura_score': score},
        where: 'id = ?', whereArgs: [id]);
  }

  // -----------------------------------------------------------------------
  // MATERIALS (Teacher side)
  // -----------------------------------------------------------------------

  static Future<void> insertMaterial(Map<String, dynamic> material) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('materials', material);
  }

  static Future<List<Map<String, dynamic>>> getMaterialsForClassroom(
      String classroomId) async {
    final db = await AsuraDatabase.instance.database;
    return await db.query('materials',
        where: 'classroom_id = ?',
        whereArgs: [classroomId],
        orderBy: 'created_at DESC');
  }

  static Future<Map<String, dynamic>?> getMaterialByRemoteId(
    String classroomId,
    String remoteId,
  ) async {
    final db = await AsuraDatabase.instance.database;
    final rows = await db.query(
      'materials',
      where: 'classroom_id = ? AND remote_id = ?',
      whereArgs: [classroomId, remoteId],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  static Future<void> updateMaterialSnapshot(
    String id, {
    required String originalName,
    required String filename,
    required String mimeType,
    required String filePath,
    required int sizeBytes,
    required String createdAt,
    required String? remoteId,
    required String? remoteUrl,
  }) async {
    final db = await AsuraDatabase.instance.database;
    await db.update(
      'materials',
      {
        'original_name': originalName,
        'filename': filename,
        'mime_type': mimeType,
        'file_path': filePath,
        'size_bytes': sizeBytes,
        'created_at': createdAt,
        'remote_id': remoteId,
        'remote_url': remoteUrl,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteMaterial(String id) async {
    final db = await AsuraDatabase.instance.database;
    await db.delete('materials', where: 'id = ?', whereArgs: [id]);
  }

  // -----------------------------------------------------------------------
  // STUDENT RECEIVED MATERIALS
  // -----------------------------------------------------------------------

  static Future<void> upsertStudentMaterial(
      Map<String, dynamic> material) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('student_materials', material,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getStudentMaterials(
      String classroomIp) async {
    final db = await AsuraDatabase.instance.database;
    return await db.query('student_materials',
        where: 'classroom_ip = ?',
        whereArgs: [classroomIp],
        orderBy: 'received_at DESC');
  }

  // -----------------------------------------------------------------------
  // CLASSROOM CRUD
  // -----------------------------------------------------------------------

  static Future<void> insertClassroom(Map<String, dynamic> room) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('classrooms', room);
  }

  static Future<List<Map<String, dynamic>>> getAllClassrooms() async {
    final db = await AsuraDatabase.instance.database;
    return await db.query('classrooms');
  }

  /// Removes duplicate local room rows created by earlier sync runs.
  static Future<int> deduplicateClassrooms() async {
    final db = await AsuraDatabase.instance.database;
    return db.transaction<int>((txn) async {
      final rows = await txn.query('classrooms', orderBy: 'rowid ASC');
      final retainedByKey = <String, Map<String, dynamic>>{};
      final duplicateIds = <String>[];

      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final remoteId = row['remote_id']?.toString() ?? '';
        final name = row['name']?.toString().trim().toLowerCase() ?? '';
        final schedule = row['schedule']?.toString().trim().toLowerCase() ?? '';
        final key = name.isNotEmpty || schedule.isNotEmpty
          ? 'identity:$name|$schedule'
          : 'remote:$remoteId';
        final existing = retainedByKey[key];
        if (existing == null) {
          retainedByKey[key] = row;
          continue;
        }

        final existingRemote = existing['remote_id']?.toString() ?? '';
        final currentPublished = row['is_published'] as int? ?? 0;
        final existingPublished = existing['is_published'] as int? ?? 0;
        if (currentPublished > existingPublished ||
            (existingRemote.isEmpty && remoteId.isNotEmpty)) {
          duplicateIds.add(existing['id'].toString());
          retainedByKey[key] = row;
        } else {
          duplicateIds.add(id);
        }
      }

      for (final duplicateId in duplicateIds) {
        final retained = retainedByKey.values.firstWhere(
          (row) => row['id']?.toString() != duplicateId &&
              ((row['name']?.toString().trim().toLowerCase() ?? '') ==
                  (rows.firstWhere((r) => r['id']?.toString() == duplicateId)['name']
                          ?.toString()
                          .trim()
                          .toLowerCase() ?? '')) &&
              ((row['schedule']?.toString().trim().toLowerCase() ?? '') ==
                  (rows.firstWhere((r) => r['id']?.toString() == duplicateId)['schedule']
                          ?.toString()
                          .trim()
                          .toLowerCase() ?? '')),
          orElse: () => <String, dynamic>{},
        );
        if (retained.isNotEmpty) {
          await txn.update(
            'materials',
            {'classroom_id': retained['id']},
            where: 'classroom_id = ?',
            whereArgs: [duplicateId],
          );
        }
        await txn.delete('classrooms', where: 'id = ?', whereArgs: [duplicateId]);
      }

      return duplicateIds.length;
    });
  }

  static Future<Map<String, dynamic>?> getClassroomById(String id) async {
    final db = await AsuraDatabase.instance.database;
    final rows = await db.query('classrooms', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  static Future<Map<String, dynamic>?> findClassroomForSync({
    required String remoteId,
    required String name,
    required String schedule,
  }) async {
    final db = await AsuraDatabase.instance.database;

    final remoteRows = await db.query(
      'classrooms',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
      limit: 1,
    );
    if (remoteRows.isNotEmpty) return remoteRows.first;

    final identityRows = await db.query(
      'classrooms',
      where: 'name = ? AND schedule = ?',
      whereArgs: [name, schedule],
      limit: 1,
    );
    return identityRows.isNotEmpty ? identityRows.first : null;
  }

  static Future<void> updateClassroomSyncState(
    String id, {
    required String name,
    required String schedule,
    required int studentCount,
    required String remoteId,
    required int isPublished,
    required String visibility,
  }) async {
    final db = await AsuraDatabase.instance.database;
    await db.update(
      'classrooms',
      {
        'name': name,
        'schedule': schedule,
        'student_count': studentCount,
        'remote_id': remoteId,
        'is_published': isPublished,
        'visibility': visibility,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Updates `remote_id`, `is_published`, and optionally `visibility` after a successful cloud publish/unpublish.
  static Future<void> updateClassroomPublishStatus(
    String id, {
    required String? remoteId,
    required int isPublished,
    String? visibility,
  }) async {
    final db = await AsuraDatabase.instance.database;
    await db.update(
      'classrooms',
      {
        'remote_id': remoteId,
        'is_published': isPublished,
        'visibility': ?visibility,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Stores the cloud-side ID and download URL for a synced material.
  static Future<void> updateMaterialRemoteInfo(
    String id, {
    required String? remoteId,
    required String? remoteUrl,
  }) async {
    final db = await AsuraDatabase.instance.database;
    await db.update(
      'materials',
      {'remote_id': remoteId, 'remote_url': remoteUrl},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // -----------------------------------------------------------------------
  // ATTENDANCE
  // -----------------------------------------------------------------------

  static Future<void> insertAttendance(Map<String, dynamic> record) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('attendance', record);
  }

  static Future<void> updateAttendanceDisconnect(
      String id, String disconnectedAt) async {
    final db = await AsuraDatabase.instance.database;
    await db.update(
      'attendance',
      {'disconnected_at': disconnectedAt},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// All attendance records for a classroom, newest first.
  static Future<List<Map<String, dynamic>>> getAttendanceForClassroom(
      String classroomId) async {
    final db = await AsuraDatabase.instance.database;
    return await db.query(
      'attendance',
      where: 'classroom_id = ?',
      whereArgs: [classroomId],
      orderBy: 'joined_at DESC',
    );
  }

  /// Distinct session dates (YYYY-MM-DD) for a classroom, newest first.
  static Future<List<String>> getAttendanceSessionDates(
      String classroomId) async {
    final db = await AsuraDatabase.instance.database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT session_date FROM attendance WHERE classroom_id = ? ORDER BY session_date DESC',
      [classroomId],
    );
    return rows.map((r) => r['session_date'] as String).toList();
  }

  // -----------------------------------------------------------------------
  // STUDENT SESSIONS (local log on student device)
  // -----------------------------------------------------------------------

  /// Insert one session record; ignores duplicates (same id = same day).
  static Future<void> insertStudentSession(Map<String, dynamic> session) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('student_sessions', session,
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// All sessions for a given classroom IP, newest first.
  static Future<List<Map<String, dynamic>>> getStudentSessionsByIp(
      String classroomIp) async {
    final db = await AsuraDatabase.instance.database;
    return await db.query(
      'student_sessions',
      where: 'classroom_ip = ?',
      whereArgs: [classroomIp],
      orderBy: 'joined_at DESC',
    );
  }

  /// Per-student summary: name, total sessions attended, last seen date.
  static Future<List<Map<String, dynamic>>> getAttendanceSummaryByStudent(
      String classroomId) async {
    final db = await AsuraDatabase.instance.database;
    return await db.rawQuery('''
      SELECT student_name,
             COUNT(*) AS total_sessions,
             MAX(session_date) AS last_seen
      FROM attendance
      WHERE classroom_id = ?
      GROUP BY student_name
      ORDER BY total_sessions DESC
    ''', [classroomId]);
  }

  // -----------------------------------------------------------------------
  // QUIZ TEMPLATES
  // -----------------------------------------------------------------------

  static Future<void> insertQuizTemplate(Map<String, dynamic> t) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('quiz_templates', t);
  }

  static Future<List<Map<String, dynamic>>> getAllQuizTemplates() async {
    final db = await AsuraDatabase.instance.database;
    return await db.query('quiz_templates', orderBy: 'created_at DESC');
  }

  static Future<void> updateQuizTemplate(String id, Map<String, dynamic> data) async {
    final db = await AsuraDatabase.instance.database;
    await db.update('quiz_templates', data, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteQuizTemplate(String id) async {
    final db = await AsuraDatabase.instance.database;
    await db.delete('quiz_templates', where: 'id = ?', whereArgs: [id]);
    await db.delete('template_questions', where: 'template_id = ?', whereArgs: [id]);
  }

  // -----------------------------------------------------------------------
  // TEMPLATE QUESTIONS
  // -----------------------------------------------------------------------

  static Future<void> insertTemplateQuestion(Map<String, dynamic> q) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('template_questions', q);
  }

  static Future<List<Map<String, dynamic>>> getTemplateQuestions(String templateId) async {
    final db = await AsuraDatabase.instance.database;
    return await db.query('template_questions',
        where: 'template_id = ?',
        whereArgs: [templateId],
        orderBy: 'order_index ASC');
  }

  static Future<void> updateTemplateQuestion(String id, Map<String, dynamic> data) async {
    final db = await AsuraDatabase.instance.database;
    await db.update('template_questions', data, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteTemplateQuestion(String id) async {
    final db = await AsuraDatabase.instance.database;
    await db.delete('template_questions', where: 'id = ?', whereArgs: [id]);
  }

  // -----------------------------------------------------------------------
  // ROOM QUIZZES
  // -----------------------------------------------------------------------

  static Future<void> insertRoomQuiz(Map<String, dynamic> q) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('room_quizzes', q);
  }

  static Future<List<Map<String, dynamic>>> getRoomQuizzesForClassroom(String classroomId) async {
    final db = await AsuraDatabase.instance.database;
    return await db.query('room_quizzes',
        where: 'classroom_id = ?',
        whereArgs: [classroomId],
        orderBy: 'created_at DESC');
  }

  static Future<Map<String, dynamic>?> getRoomQuiz(String id) async {
    final db = await AsuraDatabase.instance.database;
    final rows = await db.query('room_quizzes', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> updateRoomQuizStatus(String id, String status) async {
    final db = await AsuraDatabase.instance.database;
    await db.update('room_quizzes', {'status': status}, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteRoomQuiz(String id) async {
    final db = await AsuraDatabase.instance.database;
    await db.delete('room_quizzes', where: 'id = ?', whereArgs: [id]);
    await db.delete('room_quiz_questions', where: 'quiz_id = ?', whereArgs: [id]);
    await db.delete('quiz_responses', where: 'quiz_id = ?', whereArgs: [id]);
  }

  // -----------------------------------------------------------------------
  // ROOM QUIZ QUESTIONS
  // -----------------------------------------------------------------------

  static Future<void> insertRoomQuizQuestion(Map<String, dynamic> q) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('room_quiz_questions', q);
  }

  static Future<List<Map<String, dynamic>>> getRoomQuizQuestions(String quizId) async {
    final db = await AsuraDatabase.instance.database;
    return await db.query('room_quiz_questions',
        where: 'quiz_id = ?',
        whereArgs: [quizId],
        orderBy: 'order_index ASC');
  }

  static Future<void> updateRoomQuizQuestion(String id, Map<String, dynamic> data) async {
    final db = await AsuraDatabase.instance.database;
    await db.update('room_quiz_questions', data, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteRoomQuizQuestion(String id) async {
    final db = await AsuraDatabase.instance.database;
    await db.delete('room_quiz_questions', where: 'id = ?', whereArgs: [id]);
  }

  /// Copy all questions from a template into a room quiz.
  static Future<void> copyTemplateQuestionsToQuiz(String templateId, String quizId) async {
    final questions = await getTemplateQuestions(templateId);
    for (int i = 0; i < questions.length; i++) {
      final Map<String, dynamic> copy = Map<String, dynamic>.from(questions[i]);
      copy.remove('template_id');
      copy['id'] = '${quizId}_q$i';
      copy['quiz_id'] = quizId;
      await insertRoomQuizQuestion(copy);
    }
  }

  // -----------------------------------------------------------------------
  // QUIZ RESPONSES
  // -----------------------------------------------------------------------

  static Future<void> insertQuizResponse(Map<String, dynamic> r) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('quiz_responses', r, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getResponsesForQuiz(String quizId) async {
    final db = await AsuraDatabase.instance.database;
    return await db.query('quiz_responses',
        where: 'quiz_id = ?',
        whereArgs: [quizId],
        orderBy: 'student_name ASC, submitted_at ASC');
  }

  static Future<List<Map<String, dynamic>>> getQuizScoreSummary(String quizId) async {
    final db = await AsuraDatabase.instance.database;
    return await db.rawQuery('''
      SELECT student_name, student_ip,
             COUNT(*) AS total_answers,
             SUM(CASE WHEN is_correct = 1 THEN 1 ELSE 0 END) AS correct_count,
             MAX(submitted_at) AS submitted_at
      FROM quiz_responses
      WHERE quiz_id = ?
      GROUP BY student_name, student_ip
      ORDER BY correct_count DESC
    ''', [quizId]);
  }

  // -----------------------------------------------------------------------
  // STUDENT QUIZ RESULTS (student-side, stored locally)
  // -----------------------------------------------------------------------

  static Future<void> insertStudentQuizResult(Map<String, dynamic> r) async {
    final db = await AsuraDatabase.instance.database;
    await db.insert('student_quiz_results', r,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getStudentQuizResultsByHost(
      String hostIp, String classroomId) async {
    final db = await AsuraDatabase.instance.database;
    // Filter by both host_ip and classroom_id so two rooms on the same
    // device never show each other's quizzes.
    if (classroomId.isNotEmpty) {
      return await db.query('student_quiz_results',
          where: 'host_ip = ? AND classroom_id = ?',
          whereArgs: [hostIp, classroomId],
          orderBy: 'taken_at DESC');
    }
    // Fallback: no classroomId known — filter by IP only (legacy behaviour)
    return await db.query('student_quiz_results',
        where: 'host_ip = ?',
        whereArgs: [hostIp],
        orderBy: 'taken_at DESC');
  }
}
