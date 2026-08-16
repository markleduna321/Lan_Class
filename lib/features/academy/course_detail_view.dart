// lib/features/academy/course_detail_view.dart
//
// Course overview: enroll, work through lessons, then claim the certificate.

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import '../../services/course_api_service.dart';
import 'activity_player_view.dart';
import 'certificate_card.dart';
import 'course_models.dart';

const _kBrand = Color(0xFF1E3A8A);

class CourseDetailView extends StatefulWidget {
  final Course course;
  final VoidCallback? onChanged;

  const CourseDetailView({super.key, required this.course, this.onChanged});

  @override
  State<CourseDetailView> createState() => _CourseDetailViewState();
}

class _CourseDetailViewState extends State<CourseDetailView> {
  late Course _course = widget.course;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    final detail = await CourseApiService.fetchCourseDetail(widget.course.id);
    if (!mounted) return;
    setState(() {
      if (detail != null) _course = detail;
      _loading = false;
    });
  }

  Future<void> _enroll() async {
    setState(() => _busy = true);
    final result = await CourseApiService.enroll(_course.id);
    if (!mounted) return;

    if (!result.ok) {
      setState(() => _busy = false);
      _toast(result.error, isError: true);
      return;
    }

    await _loadDetail();
    if (!mounted) return;
    setState(() {
      _course = _course.copyWith(isEnrolled: true);
      _busy = false;
    });
    widget.onChanged?.call();
    _toast('Enrolled. You can start learning now.');
  }

  Future<void> _openLesson(CourseLesson lesson, bool isUnlocked) async {
    if (!_course.isEnrolled) {
      _toast('Enroll first to start this course.', isError: true);
      return;
    }
    if (!isUnlocked) {
      _toast('Finish the previous lesson first.', isError: true);
      return;
    }

    final completed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _LessonView(courseId: _course.id, lesson: lesson),
      ),
    );

    if (!mounted) return;
    // Refetch so newly passed activities and progress are reflected here.
    await _loadDetail();
    if (completed == true) widget.onChanged?.call();
  }

  Future<void> _claimCertificate() async {
    setState(() => _busy = true);
    final certificate =
        await CourseApiService.fetchCourseCertificate(_course.id);
    if (!mounted) return;
    setState(() => _busy = false);

    if (certificate == null) {
      _toast(
        'Certificate is not ready yet. Finish every lesson, then try again.',
        isError: true,
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: CertificateCard(certificate: certificate),
      ),
    );
  }

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.orange : Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lessons = _course.lessons;
    final done = lessons.where((l) => l.isCompleted).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Course'),
        backgroundColor: _kBrand,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadDetail,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                children: [
                  Text(
                    _course.title,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  if (_course.level.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Chip(
                      label: Text(_course.level,
                          style: const TextStyle(fontSize: 11)),
                      backgroundColor: _kBrand.withValues(alpha: 0.08),
                      side: BorderSide(color: _kBrand.withValues(alpha: 0.2)),
                    ),
                  ],
                  if (_course.description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      _course.description,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Colors.grey.shade700),
                    ),
                  ],
                  const SizedBox(height: 20),
                  _buildProgressCard(done, lessons.length),
                  const SizedBox(height: 20),
                  if (!_course.isEnrolled)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kBrand,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _busy ? null : _enroll,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.school),
                      label: Text(_busy ? 'Enrolling…' : 'Enroll in this course'),
                    )
                  else if (_course.isCompleted)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber.shade700,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _busy ? null : _claimCertificate,
                      icon: const Icon(Icons.workspace_premium),
                      label: const Text('View my certificate'),
                    ),
                  const SizedBox(height: 24),
                  Text('Lessons',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
                  if (lessons.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text('No lessons published yet.',
                          style: TextStyle(color: Colors.grey.shade500)),
                    )
                  else
                    ...lessons.asMap().entries.map((entry) {
                      final index = entry.key;
                      final lesson = entry.value;
                      // A lesson opens once every earlier lesson is done.
                      final unlocked = index == 0 ||
                          lessons.take(index).every((l) => l.isCompleted);
                      return _LessonTile(
                        index: index,
                        lesson: lesson,
                        enrolled: _course.isEnrolled,
                        unlocked: unlocked,
                        onTap: () => _openLesson(lesson, unlocked),
                      );
                    }),
                ],
              ),
            ),
    );
  }

  Widget _buildProgressCard(int done, int total) {
    final pct = total == 0 ? 0.0 : done / total;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kBrand.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBrand.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.timeline, size: 18, color: _kBrand),
              const SizedBox(width: 8),
              Text('$done of $total lessons complete',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
              const Spacer(),
              Text('${(pct * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: _kBrand)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 7,
              backgroundColor: Colors.grey.shade200,
              color: pct >= 1 ? Colors.green : _kBrand,
            ),
          ),
        ],
      ),
    );
  }
}

class _LessonTile extends StatelessWidget {
  final int index;
  final CourseLesson lesson;
  final bool enrolled;
  final bool unlocked;
  final VoidCallback onTap;

  const _LessonTile({
    required this.index,
    required this.lesson,
    required this.enrolled,
    required this.unlocked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final locked = !enrolled || !unlocked;
    final done = lesson.isCompleted;
    final subtitle = _subtitle;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      color: locked ? Colors.grey.shade50 : Colors.white,
      child: ListTile(
        onTap: onTap,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: done
              ? Colors.green
              : (locked ? Colors.grey.shade300 : _kBrand),
          child: Icon(
            done ? Icons.check : (locked ? Icons.lock : Icons.play_arrow),
            color: Colors.white,
            size: 18,
          ),
        ),
        title: Text(
          lesson.title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: locked ? Colors.grey : Colors.black87,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
        trailing: done
            ? const Icon(Icons.verified, color: Colors.green, size: 20)
            : null,
      ),
    );
  }

  String? get _subtitle {
    final parts = [
      if (lesson.moduleTitle.isNotEmpty) lesson.moduleTitle,
      if (lesson.durationMinutes > 0) '${lesson.durationMinutes} min',
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }
}

// ---------------------------------------------------------------------------
// Lesson reader
// ---------------------------------------------------------------------------

class _LessonView extends StatefulWidget {
  final String courseId;
  final CourseLesson lesson;

  const _LessonView({required this.courseId, required this.lesson});

  @override
  State<_LessonView> createState() => _LessonViewState();
}

class _LessonViewState extends State<_LessonView> {
  bool _busy = false;
  late bool _completed = widget.lesson.isCompleted;
  late CourseLesson _lesson = widget.lesson;

  Future<void> _openActivity(CourseActivity activity) async {
    final passed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ActivityPlayerView(activity: activity),
      ),
    );
    if (passed != true || !mounted) return;
    setState(() {
      _lesson = _lesson.copyWith(
        activities: _lesson.activities
            .map((a) => a.id == activity.id ? a.markPassed() : a)
            .toList(),
      );
    });
  }

  Future<void> _markComplete() async {
    setState(() => _busy = true);
    final result = await CourseApiService.completeLesson(
      courseId: widget.courseId,
      lessonId: widget.lesson.id,
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (!result.ok) {
      if (result.blocked) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Not finished yet'),
            content: Text(result.error),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _completed = true);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final lesson = _lesson;
    final body = lesson.content.isNotEmpty ? lesson.content : lesson.description;
    final activitiesPending = !lesson.allActivitiesPassed;

    return Scaffold(
      appBar: AppBar(
        title: Text(lesson.title,
            style: const TextStyle(fontSize: 15),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        backgroundColor: _kBrand,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          Text(lesson.title,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (body.isEmpty)
            Text('This lesson has no written content yet.',
                style: TextStyle(color: Colors.grey.shade500))
          else
            Html(
              data: body,
              style: {
                'body': Style(
                  margin: Margins.zero,
                  fontSize: FontSize(14),
                  lineHeight: const LineHeight(1.6),
                  color: Colors.grey.shade800,
                ),
                'pre': Style(
                  padding: HtmlPaddings.all(12),
                  backgroundColor: Colors.grey.shade100,
                  fontFamily: 'monospace',
                ),
                'code': Style(fontFamily: 'monospace'),
              },
            ),
          if (lesson.videoUrl.isNotEmpty) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link, size: 16, color: _kBrand),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(lesson.videoUrl,
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],
          if (lesson.activities.isNotEmpty) ...[
            const SizedBox(height: 26),
            Row(
              children: [
                Text('Activities',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: Colors.grey.shade600)),
                const SizedBox(width: 8),
                Text(
                  '${lesson.activities.where((a) => a.isPassed).length}'
                  '/${lesson.activities.length} passed',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...lesson.activities.map(
              (activity) => Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: ListTile(
                  onTap: () => _openActivity(activity),
                  leading: CircleAvatar(
                    backgroundColor:
                        activity.isPassed ? Colors.green : Colors.grey.shade300,
                    child: Icon(
                      activity.isPassed ? Icons.check : Icons.edit_note,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  title: Text(activity.title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text(activity.typeLabel,
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_completed && activitiesPending)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Pass every activity to unlock completion.',
                    style: TextStyle(
                        fontSize: 12, color: Colors.orange.shade800),
                  ),
                ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _completed ? Colors.green : _kBrand,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _busy || _completed || activitiesPending
                    ? null
                    : _markComplete,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : Icon(_completed ? Icons.check_circle : Icons.done),
                label: Text(_completed ? 'Completed' : 'Mark as complete'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
