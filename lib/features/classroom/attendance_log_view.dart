// lib/features/classroom/attendance_log_view.dart

import 'package:flutter/material.dart';
import '../../database/asura_repository.dart';

class AttendanceLogView extends StatefulWidget {
  final String classroomId;
  final String classroomName;
  /// Raw schedule string from DB, e.g. "Mon/Wed 9:00 AM - 10:30 AM".
  /// Used to filter the Attendance table to only scheduled days.
  final String classroomSchedule;

  const AttendanceLogView({
    super.key,
    required this.classroomId,
    required this.classroomName,
    this.classroomSchedule = '',
  });

  @override
  State<AttendanceLogView> createState() => _AttendanceLogViewState();
}

class _AttendanceLogViewState extends State<AttendanceLogView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Shared raw data
  List<Map<String, dynamic>> _allRecords = [];
  List<Map<String, dynamic>> _studentSummary = [];
  bool _isLoading = true;

  // Attendance table data
  List<String> _tableStudents = [];
  List<String> _tableDates = [];
  Map<String, Set<String>> _tablePresence = {}; // date -> present student names

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final records =
        await AsuraRepository.getAttendanceForClassroom(widget.classroomId);
    final summary =
        await AsuraRepository.getAttendanceSummaryByStudent(widget.classroomId);

    // Build table data
    final studentsSet = <String>{};
    final datesSet = <String>{};
    final presence = <String, Set<String>>{};

    for (final r in records) {
      final name = r['student_name'] as String;
      final date = r['session_date'] as String;
      studentsSet.add(name);
      datesSet.add(date);
      presence.putIfAbsent(date, () => {}).add(name);
    }

    final students = studentsSet.toList()..sort();

    // Only include dates that fall on a scheduled day of the week so that
    // off-schedule sessions don't create ✗ absences for unaware students.
    final scheduledWeekdays = _parseScheduledWeekdays(widget.classroomSchedule);
    final filteredDates = datesSet.where((d) {
      if (scheduledWeekdays.isEmpty) return true;
      try {
        return scheduledWeekdays.contains(DateTime.parse(d).weekday);
      } catch (_) {
        return true;
      }
    }).toList()
      ..sort((a, b) => b.compareTo(a)); // DESC

    if (mounted) {
      setState(() {
        _allRecords = records;
        _studentSummary = summary;
        _tableStudents = students;
        _tableDates = filteredDates;
        _tablePresence = presence;
        _isLoading = false;
      });
    }
  }

  /// Parses "Mon/Wed 9:00 AM - 10:30 AM" → {1, 3} (DateTime.weekday values).
  Set<int> _parseScheduledWeekdays(String schedule) {
    const map = {
      'Mon': 1, 'Tue': 2, 'Wed': 3, 'Thu': 4,
      'Fri': 5, 'Sat': 6, 'Sun': 7,
    };
    if (schedule.isEmpty) return {};
    // Days are everything before the first digit (start of time)
    final daysPart = schedule.split(RegExp(r'\d'))[0].trim();
    return daysPart.split('/').map((s) => map[s.trim()] ?? 0)
        .where((v) => v > 0).toSet();
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  Map<String, List<Map<String, dynamic>>> _groupByDate() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final r in _allRecords) {
      grouped.putIfAbsent(r['session_date'] as String, () => []).add(r);
    }
    return grouped;
  }

  String _formatDate(String isoDate) {
    try {
      final d = DateTime.parse(isoDate);
      const months = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[d.month]} ${d.day}, ${d.year}';
    } catch (_) {
      return isoDate;
    }
  }

  String _formatDateShort(String isoDate) {
    try {
      final d = DateTime.parse(isoDate);
      const months = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[d.month]}\n${d.day}';
    } catch (_) {
      return isoDate;
    }
  }

  String _formatTime(String? isoDatetime) {
    if (isoDatetime == null) return '';
    try {
      final d = DateTime.parse(isoDatetime).toLocal();
      final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
      final m = d.minute.toString().padLeft(2, '0');
      final ampm = d.hour < 12 ? 'AM' : 'PM';
      return '$h:$m $ampm';
    } catch (_) {
      return isoDatetime;
    }
  }

  String _todayIso() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Attendance',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(widget.classroomName,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
            if (widget.classroomSchedule.isNotEmpty)
              Text(
                '${widget.classroomSchedule} • scheduled days only',
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
          ],
        ),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.amber,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(icon: Icon(Icons.calendar_month, size: 16), text: 'Sessions'),
            Tab(icon: Icon(Icons.people, size: 16), text: 'Students'),
            Tab(icon: Icon(Icons.grid_on, size: 16), text: 'Attendance'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadData();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildSessionsTab(),
                _buildStudentsTab(),
                _buildAttendanceTableTab(),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 1 â€” SESSION LOG (grouped by date, shows joined + disconnected)
  // ---------------------------------------------------------------------------

  Widget _buildSessionsTab() {
    final grouped = _groupByDate();
    if (grouped.isEmpty) {
      return _buildEmpty('No sessions yet.',
          'Students will appear here after joining a live session.');
    }

    final dates = grouped.keys.toList(); // DESC order from query
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: dates.length,
        itemBuilder: (context, i) {
          final date = dates[i];
          final entries = grouped[date]!;
          final isToday = date == _todayIso();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Date header
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 6),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: isToday
                            ? const Color(0xFF1E3A8A)
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isToday
                                ? Icons.radio_button_checked
                                : Icons.calendar_today,
                            size: 13,
                            color: isToday ? Colors.white : Colors.grey,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            isToday
                                ? 'Today â€” ${_formatDate(date)}'
                                : _formatDate(date),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isToday
                                  ? Colors.white
                                  : Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                        '${entries.length} student${entries.length != 1 ? 's' : ''}',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              // Student entries for this date
              Card(
                elevation: 1,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    for (int j = 0; j < entries.length; j++) ...[
                      if (j > 0)
                        const Divider(
                            height: 1, indent: 16, endIndent: 16),
                      _buildSessionRow(entries[j]),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSessionRow(Map<String, dynamic> record) {
    final name = record['student_name'] as String;
    final ip = record['student_ip'] as String;
    final joinedAt = _formatTime(record['joined_at'] as String?);
    final disconnectedAt = record['disconnected_at'] as String?;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final isActive = disconnectedAt == null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor:
                const Color(0xFF1E3A8A).withValues(alpha: 0.1),
            child: Text(initial,
                style: const TextStyle(
                    color: Color(0xFF1E3A8A),
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                Text(ip,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Joined / Disconnected timestamps
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildTimeChip(
                  Icons.login, joinedAt, Colors.green),
              const SizedBox(height: 4),
              isActive
                  ? _buildTimeChip(
                      Icons.circle, 'Active', Colors.orange)
                  : _buildTimeChip(Icons.logout,
                      _formatTime(disconnectedAt), Colors.red),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimeChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 2 â€” STUDENTS SUMMARY
  // ---------------------------------------------------------------------------

  Widget _buildStudentsTab() {
    if (_studentSummary.isEmpty) {
      return _buildEmpty('No students yet.',
          'Student summaries appear after the first live session.');
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: _studentSummary.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final s = _studentSummary[i];
          final name = s['student_name'] as String;
          final total = s['total_sessions'] as int;
          final lastSeen = _formatDate(s['last_seen'] as String);
          final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

          return Card(
            elevation: 1,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 6),
              leading: CircleAvatar(
                radius: 22,
                backgroundColor:
                    const Color(0xFF1E3A8A).withValues(alpha: 0.12),
                child: Text(initial,
                    style: const TextStyle(
                        color: Color(0xFF1E3A8A),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
              ),
              title: Text(name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
              subtitle: Text('Last session: $lastSeen',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.grey)),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('$total',
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E3A8A))),
                  Text(
                    total == 1 ? 'session' : 'sessions',
                    style: const TextStyle(
                        fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 3 â€” ATTENDANCE TABLE (present/absent per date)
  // ---------------------------------------------------------------------------

  Widget _buildAttendanceTableTab() {
    if (_tableStudents.isEmpty || _tableDates.isEmpty) {
      return _buildEmpty('No attendance data yet.',
          'The attendance table will populate after students join sessions.');
    }

    const double nameColW = 150;
    const double dateColW = 64;

    // Summary: how many present per date
    final presentCounts = {
      for (final d in _tableDates)
        d: _tableStudents
            .where((s) => _tablePresence[d]?.contains(s) == true)
            .length,
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Legend
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _legendItem(Icons.check_circle, Colors.green, 'Present'),
              _legendItem(Icons.cancel, Colors.red, 'Absent'),
            ],
          ),
          const SizedBox(height: 12),

          // Scrollable table
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                Row(
                  children: [
                    // Student name column header
                    Container(
                      width: nameColW,
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E3A8A),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(10),
                        ),
                      ),
                      child: const Text('Student',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ),
                    // Date columns header
                    for (final date in _tableDates)
                      Container(
                        width: dateColW,
                        padding: const EdgeInsets.symmetric(
                            vertical: 6, horizontal: 4),
                        color: const Color(0xFF1E3A8A),
                        child: Text(
                          _formatDateShort(date),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: date == _todayIso()
                                ? Colors.amber
                                : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    // Totals header
                    Container(
                      width: dateColW,
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 4),
                      decoration: const BoxDecoration(
                        color: Color(0xFF1E3A8A),
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(10),
                        ),
                      ),
                      child: const Text('Total',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.amber,
                              fontWeight: FontWeight.bold,
                              fontSize: 11)),
                    ),
                  ],
                ),

                // Student rows
                ...List.generate(_tableStudents.length, (si) {
                  final student = _tableStudents[si];
                  final totalPresent = _tableDates
                      .where((d) =>
                          _tablePresence[d]?.contains(student) == true)
                      .length;
                  final isEven = si % 2 == 0;
                  return Row(
                    children: [
                      // Name cell
                      Container(
                        width: nameColW,
                        padding: const EdgeInsets.symmetric(
                            vertical: 10, horizontal: 12),
                        color: isEven
                            ? Colors.grey.shade50
                            : Colors.white,
                        child: Text(
                          student,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Date presence cells
                      for (final date in _tableDates)
                        Container(
                          width: dateColW,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          color: isEven
                              ? Colors.grey.shade50
                              : Colors.white,
                          child: Center(
                            child: _tablePresence[date]
                                        ?.contains(student) ==
                                    true
                                ? const Icon(Icons.check_circle,
                                    color: Colors.green, size: 20)
                                : const Icon(Icons.cancel,
                                    color: Colors.red, size: 20),
                          ),
                        ),
                      // Total cell
                      Container(
                        width: dateColW,
                        padding:
                            const EdgeInsets.symmetric(vertical: 10),
                        color: isEven
                            ? Colors.grey.shade50
                            : Colors.white,
                        child: Center(
                          child: Text(
                            '$totalPresent/${_tableDates.length}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: totalPresent == _tableDates.length
                                  ? Colors.green
                                  : totalPresent == 0
                                      ? Colors.red
                                      : Colors.orange,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }),

                // Footer row: present count per date
                Row(
                  children: [
                    Container(
                      width: nameColW,
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(10),
                        ),
                      ),
                      child: const Text('Present',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.black54)),
                    ),
                    for (final date in _tableDates)
                      Container(
                        width: dateColW,
                        padding:
                            const EdgeInsets.symmetric(vertical: 8),
                        color: Colors.grey.shade200,
                        child: Center(
                          child: Text(
                            '${presentCounts[date]}/${_tableStudents.length}',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54),
                          ),
                        ),
                      ),
                    Container(
                      width: dateColW,
                      padding:
                          const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: const BorderRadius.only(
                          bottomRight: Radius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendItem(IconData icon, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label,
            style:
                TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }

  // ---------------------------------------------------------------------------

  Widget _buildEmpty(String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.assignment_turned_in_outlined,
              size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(title,
              style: TextStyle(
                  color: Colors.grey.shade500, fontSize: 16)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.grey.shade400, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
