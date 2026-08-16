// lib/features/academy/course_models.dart
//
// Models for the Course Academy. Field names are read defensively because the
// backend wraps payloads inconsistently across endpoints.

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

double _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0;
}

bool _asBool(dynamic v) {
  if (v is bool) return v;
  final s = v?.toString().toLowerCase();
  return s == '1' || s == 'true' || s == 'yes';
}

String _asString(dynamic v) => v?.toString() ?? '';

/// Unwraps nested `{data: ...}` / `{course: ...}` style envelopes.
Map<String, dynamic>? unwrapObject(dynamic decoded, {List<String> keys = const []}) {
  if (decoded is! Map) return null;
  final map = Map<String, dynamic>.from(decoded);
  for (final key in [...keys, 'data']) {
    final inner = map[key];
    if (inner is Map) {
      final nested = unwrapObject(inner, keys: keys);
      return nested ?? Map<String, dynamic>.from(inner);
    }
  }
  return map;
}

/// Unwraps a list that may arrive nested under `data` or a named key.
List<Map<String, dynamic>> unwrapList(dynamic decoded, {List<String> keys = const []}) {
  if (decoded is List) {
    return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }
  if (decoded is Map) {
    for (final key in [...keys, 'data']) {
      final inner = decoded[key];
      if (inner is List) {
        return inner.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
      if (inner is Map) {
        final nested = unwrapList(inner, keys: keys);
        if (nested.isNotEmpty) return nested;
      }
    }
  }
  return const [];
}

/// Lesson/activity ids arrive as ints but are held as strings app-side.
Set<String> _idSet(dynamic raw) {
  if (raw is! List) return const {};
  return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toSet();
}

class Course {
  final String id;
  final String title;
  final String description;
  final String imageUrl;
  final String level;
  final int lessonCount;
  final bool isEnrolled;
  final bool isCompleted;
  final double progress;
  final List<CourseLesson> lessons;
  final String? certificateUuid;

  const Course({
    required this.id,
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.level,
    required this.lessonCount,
    required this.isEnrolled,
    required this.isCompleted,
    required this.progress,
    required this.lessons,
    this.certificateUuid,
  });

  factory Course.fromJson(Map<String, dynamic> json) {
    // `enrollment` is null until the student enrolls; it carries all progress.
    final enrollment = json['enrollment'] is Map
        ? Map<String, dynamic>.from(json['enrollment'] as Map)
        : null;
    final completedIds = _idSet(enrollment?['completed_lesson_ids']);
    final passedActivityIds = _idSet(enrollment?['passed_activity_ids']);

    final lessons = _extractLessons(json, completedIds, passedActivityIds);

    final isEnrolled = enrollment != null ||
        _asBool(json['is_enrolled'] ?? json['enrolled']);

    var progress = _asDouble(enrollment?['progress'] ??
        json['progress'] ??
        json['progress_percent'] ??
        json['completion_percent']);
    if (progress > 1) progress = progress / 100;

    final hasReportedProgress = enrollment?['progress'] != null ||
        json['progress'] != null ||
        json['progress_percent'] != null ||
        json['completion_percent'] != null;
    if (!hasReportedProgress && lessons.isNotEmpty) {
      progress = lessons.where((l) => l.isCompleted).length / lessons.length;
    }

    final completed = json['is_completed'] ?? json['completed'];

    return Course(
      id: _asString(json['id'] ?? json['uuid'] ?? json['slug']),
      title: _asString(json['title'] ?? json['name'] ?? 'Untitled course'),
      description: _asString(json['description'] ?? json['summary']),
      imageUrl: _asString(
          json['image_url'] ?? json['thumbnail'] ?? json['cover_url']),
      level: _asString(json['level'] ?? json['difficulty']),
      lessonCount: json['lesson_count'] != null || json['lessons_count'] != null
          ? _asInt(json['lesson_count'] ?? json['lessons_count'])
          : lessons.length,
      isEnrolled: isEnrolled,
      isCompleted: completed != null ? _asBool(completed) : progress >= 1,
      progress: progress.clamp(0.0, 1.0),
      lessons: lessons,
      certificateUuid: (json['certificate_uuid'] ?? json['certificate']?['uuid'])
          ?.toString(),
    );
  }

  /// Lessons live under `modules[].lessons[]`; older payloads send them flat.
  static List<CourseLesson> _extractLessons(
    Map<String, dynamic> json,
    Set<String> completedIds,
    Set<String> passedActivityIds,
  ) {
    final modules = json['modules'];
    if (modules is List) {
      final result = <CourseLesson>[];
      for (final rawModule in modules.whereType<Map>()) {
        final module = Map<String, dynamic>.from(rawModule);
        final moduleTitle = _asString(module['title'] ?? module['name']);
        final lessons = module['lessons'];
        if (lessons is! List) continue;
        for (final rawLesson in lessons.whereType<Map>()) {
          result.add(CourseLesson.fromJson(
            Map<String, dynamic>.from(rawLesson),
            completedIds: completedIds,
            passedActivityIds: passedActivityIds,
            moduleTitle: moduleTitle,
          ));
        }
      }
      return result;
    }

    final flat = json['lessons'] ?? json['items'];
    if (flat is List) {
      return flat
          .whereType<Map>()
          .map((e) => CourseLesson.fromJson(
                Map<String, dynamic>.from(e),
                completedIds: completedIds,
                passedActivityIds: passedActivityIds,
              ))
          .toList();
    }
    return const [];
  }

  Course copyWith({bool? isEnrolled, List<CourseLesson>? lessons}) {
    final nextLessons = lessons ?? this.lessons;
    final done = nextLessons.where((l) => l.isCompleted).length;
    final nextProgress =
        nextLessons.isEmpty ? progress : done / nextLessons.length;
    return Course(
      id: id,
      title: title,
      description: description,
      imageUrl: imageUrl,
      level: level,
      lessonCount: lessonCount,
      isEnrolled: isEnrolled ?? this.isEnrolled,
      isCompleted: nextProgress >= 1,
      progress: nextProgress,
      lessons: nextLessons,
      certificateUuid: certificateUuid,
    );
  }
}

class CourseLesson {
  final String id;
  final String title;
  final String description;
  final String content;
  final String videoUrl;
  final String moduleTitle;
  final int durationMinutes;
  final bool isCompleted;
  final List<CourseActivity> activities;

  const CourseLesson({
    required this.id,
    required this.title,
    required this.description,
    required this.content,
    required this.videoUrl,
    required this.moduleTitle,
    required this.durationMinutes,
    required this.isCompleted,
    required this.activities,
  });

  factory CourseLesson.fromJson(
    Map<String, dynamic> json, {
    Set<String> completedIds = const {},
    Set<String> passedActivityIds = const {},
    String moduleTitle = '',
  }) {
    final id = _asString(json['id'] ?? json['uuid']);
    final rawActivities = json['activities'];
    final activities = rawActivities is List
        ? (rawActivities
            .whereType<Map>()
            .map((e) => CourseActivity.fromJson(
                  Map<String, dynamic>.from(e),
                  passedActivityIds: passedActivityIds,
                ))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order)))
        : <CourseActivity>[];

    return CourseLesson(
      id: id,
      title: _asString(json['title'] ?? json['name'] ?? 'Lesson'),
      description: _asString(json['description'] ?? json['summary']),
      content: _asString(json['content'] ?? json['body'] ?? json['text']),
      videoUrl: _asString(json['video_url'] ?? json['media_url']),
      moduleTitle: moduleTitle,
      durationMinutes: _asInt(json['duration_minutes'] ?? json['duration']),
      isCompleted: completedIds.contains(id),
      activities: activities,
    );
  }

  bool get allActivitiesPassed => activities.every((a) => a.isPassed);

  CourseLesson markCompleted() => copyWith(isCompleted: true);

  CourseLesson copyWith({
    bool? isCompleted,
    List<CourseActivity>? activities,
  }) =>
      CourseLesson(
        id: id,
        title: title,
        description: description,
        content: content,
        videoUrl: videoUrl,
        moduleTitle: moduleTitle,
        durationMinutes: durationMinutes,
        isCompleted: isCompleted ?? this.isCompleted,
        activities: activities ?? this.activities,
      );
}

class CourseActivity {
  final String id;
  final String type;
  final String title;
  final String instructions;
  final int order;
  final bool isPassed;

  final int blanksCount;
  final List<String?> blanksHints;

  final String language;
  final String starterCode;
  final bool allowReveal;
  final List<ActivityTestCase> testCases;

  final List<ActivityQuestion> questions;

  const CourseActivity({
    required this.id,
    required this.type,
    required this.title,
    required this.instructions,
    required this.order,
    required this.isPassed,
    required this.blanksCount,
    required this.blanksHints,
    required this.language,
    required this.starterCode,
    required this.allowReveal,
    required this.testCases,
    required this.questions,
  });

  factory CourseActivity.fromJson(
    Map<String, dynamic> json, {
    Set<String> passedActivityIds = const {},
  }) {
    final id = _asString(json['id']);
    final hints = json['blanks_hints'];
    final tests = json['test_cases'];
    final questions = json['questions'];

    return CourseActivity(
      id: id,
      type: _asString(json['type']),
      title: _asString(json['title'] ?? 'Activity'),
      instructions: _asString(json['instructions']),
      order: _asInt(json['order']),
      isPassed: passedActivityIds.contains(id),
      blanksCount: _asInt(json['blanks_count']),
      blanksHints: hints is List
          ? hints.map((e) => e?.toString()).toList()
          : const [],
      language: _asString(json['language']),
      starterCode: _asString(json['starter_code']),
      allowReveal: _asBool(json['allow_reveal']),
      testCases: tests is List
          ? tests
              .whereType<Map>()
              .map((e) => ActivityTestCase.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      questions: questions is List
          ? questions
              .whereType<Map>()
              .map((e) => ActivityQuestion.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }

  String get typeLabel => switch (type) {
        'fill_blank' => 'Fill in the blanks',
        'code_write' => 'Write code',
        'quiz' => 'Quiz',
        _ => 'Activity',
      };

  CourseActivity markPassed() => CourseActivity(
        id: id,
        type: type,
        title: title,
        instructions: instructions,
        order: order,
        isPassed: true,
        blanksCount: blanksCount,
        blanksHints: blanksHints,
        language: language,
        starterCode: starterCode,
        allowReveal: allowReveal,
        testCases: testCases,
        questions: questions,
      );
}

class ActivityQuestion {
  final String text;
  final String type;
  final List<String> options;

  const ActivityQuestion({
    required this.text,
    required this.type,
    required this.options,
  });

  factory ActivityQuestion.fromJson(Map<String, dynamic> json) {
    final options = json['options'];
    return ActivityQuestion(
      text: _asString(json['text']),
      type: _asString(json['type']).isEmpty
          ? 'multiple_choice'
          : _asString(json['type']),
      options: options is List
          ? options.map((e) => e.toString()).toList()
          : const [],
    );
  }

  List<String> get choices =>
      type == 'true_false' ? const ['true', 'false'] : options;
}

class ActivityTestCase {
  final String input;
  final String expected;

  const ActivityTestCase({required this.input, required this.expected});

  factory ActivityTestCase.fromJson(Map<String, dynamic> json) =>
      ActivityTestCase(
        input: _asString(json['input']),
        expected: _asString(json['expected']),
      );
}

class ActivitySubmission {
  final String activityId;
  final bool passed;
  final String feedback;

  const ActivitySubmission({
    required this.activityId,
    required this.passed,
    required this.feedback,
  });

  factory ActivitySubmission.fromJson(Map<String, dynamic> json) =>
      ActivitySubmission(
        activityId: _asString(json['activity_id']),
        passed: _asBool(json['passed']),
        feedback: _asString(json['feedback']),
      );
}

class Certificate {
  final String uuid;
  final String courseId;
  final String courseTitle;
  final String recipientName;
  final String issuedAt;
  final String downloadUrl;

  const Certificate({
    required this.uuid,
    required this.courseId,
    required this.courseTitle,
    required this.recipientName,
    required this.issuedAt,
    required this.downloadUrl,
  });

  factory Certificate.fromJson(Map<String, dynamic> json) {
    return Certificate(
      uuid: _asString(json['uuid'] ?? json['id'] ?? json['certificate_uuid']),
      courseId: _asString(json['course_id'] ?? json['course']?['id']),
      courseTitle: _asString(json['course_title'] ??
          json['course']?['title'] ??
          json['title'] ??
          'Course'),
      recipientName: _asString(json['recipient_name'] ??
          json['user_name'] ??
          json['user']?['name']),
      issuedAt: _asString(json['issued_at'] ?? json['created_at']),
      downloadUrl:
          _asString(json['download_url'] ?? json['url'] ?? json['pdf_url']),
    );
  }

  String get issuedDateLabel {
    if (issuedAt.isEmpty) return '';
    try {
      final dt = DateTime.parse(issuedAt).toLocal();
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return issuedAt;
    }
  }
}
