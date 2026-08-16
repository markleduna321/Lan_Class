// lib/features/academy/course_timeline_view.dart
//
// Course Academy — browse the catalog, track enrolled courses, open certificates.

import 'package:flutter/material.dart';
import '../../services/course_api_service.dart';
import 'certificates_view.dart';
import 'course_detail_view.dart';
import 'course_models.dart';

const _kBrand = Color(0xFF1E3A8A);

class CourseTimelineView extends StatefulWidget {
  const CourseTimelineView({super.key});

  @override
  State<CourseTimelineView> createState() => _CourseTimelineViewState();
}

class _CourseTimelineViewState extends State<CourseTimelineView>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  List<Course> _courses = const [];
  bool _loading = true;
  bool _hasError = false;
  String _errorMessage = 'Could not load courses.';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _hasError = false; });
    final courses = await CourseApiService.fetchCourses();
    if (!mounted) return;
    setState(() {
      _courses = courses;
      _loading = false;
      _hasError = courses.isEmpty;
      _errorMessage = courses.isEmpty
          ? 'No courses were returned by the online academy.'
          : '';
    });
  }

  void _openCourse(Course course) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CourseDetailView(course: course, onChanged: _load),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final enrolled = _courses.where((c) => c.isEnrolled).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'academy_certs',
        backgroundColor: Colors.amber.shade700,
        foregroundColor: Colors.white,
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CertificatesView()),
        ),
        icon: const Icon(Icons.workspace_premium),
        label: const Text('Certificates'),
      ),
      body: Column(
        children: [
          TabBar(
            controller: _tabController,
            labelColor: _kBrand,
            unselectedLabelColor: Colors.grey,
            indicatorColor: _kBrand,
            tabs: [
              Tab(text: 'My Courses (${enrolled.length})'),
              const Tab(text: 'Browse'),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildList(
                        enrolled,
                        emptyIcon: Icons.school_outlined,
                        emptyText:
                            'You have not enrolled in a course yet.\nOpen Browse to find one.',
                      ),
                      _buildList(
                        _courses,
                        emptyIcon: Icons.menu_book_outlined,
                        emptyText: _hasError
                            ? '$_errorMessage\nPull down to retry.'
                            : 'No courses published yet.',
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    List<Course> courses, {
    required IconData emptyIcon,
    required String emptyText,
  }) {
    return RefreshIndicator(
      onRefresh: _load,
      child: courses.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 100),
                Icon(emptyIcon, size: 72, color: Colors.grey.shade300),
                const SizedBox(height: 14),
                Center(
                  child: Text(
                    emptyText,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500, height: 1.5),
                  ),
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: courses.length,
              itemBuilder: (_, i) => _CourseCard(
                course: courses[i],
                onTap: () => _openCourse(courses[i]),
              ),
            ),
    );
  }
}

class _CourseCard extends StatelessWidget {
  final Course course;
  final VoidCallback onTap;

  const _CourseCard({required this.course, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: course.isCompleted
                          ? Colors.green.withValues(alpha: 0.1)
                          : _kBrand.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      course.isCompleted
                          ? Icons.workspace_premium
                          : Icons.menu_book,
                      color: course.isCompleted ? Colors.green : _kBrand,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(course.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(
                          '${course.lessonCount} lesson(s)'
                          '${course.level.isNotEmpty ? ' • ${course.level}' : ''}',
                          style:
                              const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  if (course.isEnrolled && !course.isCompleted)
                    const Icon(Icons.arrow_circle_right, color: _kBrand),
                ],
              ),
              if (course.description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  course.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, height: 1.4, color: Colors.grey.shade700),
                ),
              ],
              if (course.isEnrolled) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: course.progress,
                    minHeight: 6,
                    backgroundColor: Colors.grey.shade200,
                    color: course.isCompleted ? Colors.green : _kBrand,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  course.isCompleted
                      ? 'Completed — certificate available'
                      : '${(course.progress * 100).toStringAsFixed(0)}% complete',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: course.isCompleted
                        ? Colors.green
                        : Colors.grey.shade600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}