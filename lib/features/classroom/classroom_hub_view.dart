// lib/features/classroom/classroom_hub_view.dart

import 'package:asuratech_lan_classroom/database/asura_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'teacher_dashboard_view.dart';
import 'materials_library_view.dart';
import 'attendance_log_view.dart';
import '../quiz/room_quiz_list_view.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/classroom_sync_events.dart';

class ClassroomHubView extends StatefulWidget {
  const ClassroomHubView({super.key});

  @override
  State<ClassroomHubView> createState() => _ClassroomHubViewState();
}

class _ClassroomHubViewState extends State<ClassroomHubView> {
  final bool _isDeviceOnline = true; 

  List<Map<String, dynamic>> _dbSections = [];
  // Tracks which classroom IDs are actively publishing/unpublishing
  final Set<String> _cloudBusy = {};

  @override
  void initState() {
    super.initState();
    _refreshRooms();
    // Refresh when the background login sync lands rooms on a new device.
    classroomSyncCompleted.addListener(_refreshRooms);
  }

  @override
  void dispose() {
    classroomSyncCompleted.removeListener(_refreshRooms);
    super.dispose();
  }

  Future<void> _refreshRooms() async {
    await AsuraRepository.deduplicateClassrooms();
    final data = await AsuraRepository.getAllClassrooms();
    if (mounted) setState(() => _dbSections = data);
  }
  
  void _showCreateClassModal(BuildContext context) {
    final nameController = TextEditingController();
    
    final List<String> daysOfWeek = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    final Set<String> selectedDays = {};
    TimeOfDay? selectedStartTime;
    TimeOfDay? selectedEndTime; // Added End Time Tracker

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent, 
      builder: (context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setModalState) {
          return SafeArea( // <--- GUARANTEES NO OVERLAP WITH SYSTEM BUTTONS
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                // We only need to account for the keyboard pushing up now
                bottom: MediaQuery.of(context).viewInsets.bottom + 24, 
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Create New Classroom', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('Define the parameters for your new academic section.', style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 24),
                    
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Section Name (e.g., SAD 411)', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 24),

                    const Text('Select Days', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      children: daysOfWeek.map((day) {
                        final isSelected = selectedDays.contains(day);
                        return FilterChip(
                          label: Text(day),
                          selected: isSelected,
                          selectedColor: Colors.blue.shade100,
                          checkmarkColor: const Color(0xFF1E3A8A),
                          onSelected: (bool selected) {
                            setModalState(() {
                              if (selected) {
                                selectedDays.add(day);
                              } else {
                                selectedDays.remove(day);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 24),

                    // SIDE-BY-SIDE START AND END TIME PICKERS
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Start Time', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              _buildTimePickerButton(
                                context: context,
                                selectedTime: selectedStartTime,
                                onTimeSelected: (time) => setModalState(() => selectedStartTime = time),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('End Time', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              _buildTimePickerButton(
                                context: context,
                                selectedTime: selectedEndTime,
                                onTimeSelected: (time) => setModalState(() => selectedEndTime = time),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E3A8A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      // Inside _showCreateClassModal -> ElevatedButton -> onPressed:
                    onPressed: () async {
                      if (nameController.text.isEmpty || selectedDays.isEmpty || selectedStartTime == null || selectedEndTime == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please complete all scheduling fields.')),
                        );
                        return;
                      }

                      final String formattedDays = selectedDays.toList().join('/');
                      final String startStr = selectedStartTime!.format(context);
                      final String endStr = selectedEndTime!.format(context);
                      final String fullSchedule = '$formattedDays $startStr - $endStr';

                      // 1. Package the data matching our actual SQLite schema
                      final newRoom = {
                        'id': DateTime.now().millisecondsSinceEpoch.toString(),
                        'name': nameController.text.trim(),
                        'schedule': fullSchedule,
                        'student_count': 0, // Swapped from 'students' to match our DB schema
                      };

                      // 2. Write it permanently to the local database
                      await AsuraRepository.insertClassroom(newRoom);
                      
                      // 3. Re-fetch the fresh, updated list from the database
                      await _refreshRooms();
                      
                      // 4. Close the sliding modal form safely
                      if (!context.mounted) return;
                      Navigator.pop(context); 
                      
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('New classroom initialized.')),
                      );
                    },
                      child: const Text('Initialize Section', style: TextStyle(fontSize: 16)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // Reusable Time Picker Button Component
  Widget _buildTimePickerButton({required BuildContext context, required TimeOfDay? selectedTime, required Function(TimeOfDay) onTimeSelected}) {
    return InkWell(
      onTap: () async {
        final TimeOfDay? time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.now(),
          builder: (context, child) => Theme(
            data: ThemeData.light().copyWith(colorScheme: const ColorScheme.light(primary: Color(0xFF1E3A8A))),
            child: child!,
          ),
        );
        if (time != null) onTimeSelected(time);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade400), borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              selectedTime == null ? '00:00' : selectedTime.format(context),
              style: TextStyle(fontSize: 14, color: selectedTime == null ? Colors.grey.shade500 : Colors.black87, fontWeight: FontWeight.w600),
            ),
            const Icon(Icons.access_time, color: Colors.grey, size: 18),
          ],
        ),
      ),
    );
  }

  // --- ROOM INTIALIZATION MODAL (Also wrapped in SafeArea) ---

  void _showInitializationMatrix(BuildContext context, String classroomId, String className) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Container(
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Initialize Session: $className', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Select the network topology for this live lecture.', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              _buildRoutingCard(
                title: 'Local Edge-LAN Broadcast',
                subtitle: 'Students connect directly to this device\'s hotspot.',
                icon: Icons.wifi_tethering,
                color: Colors.green,
                isEnabled: true,
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => TeacherDashboardView(
                    classroomId: classroomId,
                    classroomName: className,
                  )));
                },
              ),
              const SizedBox(height: 12),
              _buildRoutingCard(
                title: 'Online Cloud Server',
                subtitle: _isDeviceOnline ? 'Route traffic through AsuraTECH remote servers.' : 'Currently unavailable.',
                icon: Icons.cloud_sync,
                color: Colors.blue,
                isEnabled: _isDeviceOnline,
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => TeacherDashboardView(
                    classroomId: classroomId,
                    classroomName: className,
                    isOnlineOnly: true,
                  )));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoutingCard({required String title, required String subtitle, required IconData icon, required Color color, required bool isEnabled, required VoidCallback onTap}) {
    return Card(
      elevation: isEnabled ? 2 : 0,
      color: isEnabled ? Colors.white : Colors.grey.shade100,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: isEnabled ? color.withValues(alpha: 0.5) : Colors.grey.shade300)),
      child: InkWell(
        onTap: isEnabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: isEnabled ? color.withValues(alpha: 0.1) : Colors.grey.shade200, shape: BoxShape.circle),
                child: Icon(icon, color: isEnabled ? color : Colors.grey, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isEnabled ? Colors.black87 : Colors.grey)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.3)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Room'),
        onPressed: () => _showCreateClassModal(context),
      ),
      body: _dbSections.isEmpty
          ? const Center(child: Text('No classrooms established yet.\nClick "New Room" to begin.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 16)))
          : ListView.builder(
              padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 16.0, bottom: 80.0), // Standard bottom spacing for FAB
              itemCount: _dbSections.length,
              itemBuilder: (context, index) {
                final currentClass = _dbSections[index];
                return Card(
                  elevation: 3,
                  margin: const EdgeInsets.symmetric(vertical: 8.0),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: ExpansionTile(
                    leading: SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      children: [
                        const CircleAvatar(
                          backgroundColor: Color(0xFF1E3A8A),
                          child: Icon(Icons.folder, color: Colors.white),
                        ),
                        if ((currentClass['is_published'] as int? ?? 0) == 1)
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                  color: Colors.white, shape: BoxShape.circle),
                              child: const Icon(Icons.cloud_done,
                                  size: 14, color: Colors.green),
                            ),
                          ),
                      ],
                    ),
                  ),
                    title: Text((currentClass['name'] as String?) ?? 'Classroom', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${(currentClass['schedule'] as String?) ?? ''} • ${currentClass['student_count'] ?? 0} Enrolled', style: const TextStyle(fontSize: 12)),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _buildQuickAction(Icons.analytics, 'Gradebook', Colors.blue, currentClass),
                                _buildQuickAction(Icons.assignment_turned_in, 'Attendance', Colors.orange, currentClass),
                                _buildQuickAction(Icons.menu_book, 'Materials', Colors.purple, currentClass),
                                _buildQuickAction(Icons.quiz, 'Quizzes', Colors.teal, currentClass),
                              ],
                            ),
                            const Divider(height: 24),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A8A), foregroundColor: Colors.white, minimumSize: const Size.fromHeight(44), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                              icon: const Icon(Icons.cast_connected),
                              label: const Text('Start Live Class'),
                              onPressed: () => _showInitializationMatrix(context, currentClass['id']?.toString() ?? '', (currentClass['name'] as String?) ?? 'Classroom'),
                            ),
                            const SizedBox(height: 8),
                            _buildCloudRow(currentClass),
                            const SizedBox(height: 8),
                          ],
                        ),
                      )
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildCloudRow(Map<String, dynamic> classroom) {
    final classroomId  = (classroom['id']?.toString() ?? '');
    if (classroomId.isEmpty) return const SizedBox.shrink();
    final isPublished  = (classroom['is_published'] as int? ?? 0) == 1;
    final isBusy       = _cloudBusy.contains(classroomId);
    final visibility   = (classroom['visibility'] as String?) ?? 'public';
    final remoteId     = (classroom['remote_id']?.toString());
    final isPrivate    = visibility == 'private';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isPublished ? Colors.green.shade50 : Colors.grey.shade50,
        border: Border.all(
            color: isPublished ? Colors.green.shade200 : Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPublished
                    ? (isPrivate ? Icons.lock : Icons.cloud_done)
                    : Icons.cloud_off,
                size: 20,
                color: isPublished
                    ? (isPrivate ? Colors.orange.shade700 : Colors.green)
                    : Colors.grey,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isPublished
                      ? (isPrivate ? 'Published (Private)' : 'Published (Public)')
                      : 'Not published',
                  style: TextStyle(
                    fontSize: 13,
                    color: isPublished
                        ? (isPrivate ? Colors.orange.shade800 : Colors.green.shade700)
                        : Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isBusy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (isPublished)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () => _unpublishClassroom(classroom),
                  child: const Text('Unpublish'),
                )
              else
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  icon: const Icon(Icons.cloud_upload, size: 16),
                  label: const Text('Publish'),
                  onPressed: () => _publishClassroom(classroom),
                ),
            ],
          ),
          // Show room ID for private published classrooms
          if (isPublished && isPrivate && remoteId != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 30),
              child: GestureDetector(
                onTap: () {
                  // Copy to clipboard
                  Clipboard.setData(ClipboardData(text: remoteId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Room ID copied to clipboard.'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Room ID: $remoteId',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade800,
                          fontFamily: 'monospace'),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.copy, size: 12, color: Colors.orange.shade700),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _publishClassroom(Map<String, dynamic> classroom) async {
    final classroomId = (classroom['id']?.toString() ?? '');
    if (classroomId.isEmpty) return;

    final ready = await CloudSyncService.isReady;
    if (!mounted) return;
    if (!ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Link an online account first (Profile → Cloud Account).'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Ask teacher to choose visibility before publishing
    final visibility = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String selected = 'public';
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Set Visibility'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Radio<String>(
                    value: 'public',
                    groupValue: selected,
                    onChanged: (v) => setD(() => selected = v!),
                  ),
                  title: const Text('Public'),
                  subtitle: const Text('Visible to all students in the browser'),
                  trailing: const Icon(Icons.public),
                  onTap: () => setD(() => selected = 'public'),
                ),
                ListTile(
                  leading: Radio<String>(
                    value: 'private',
                    groupValue: selected,
                    onChanged: (v) => setD(() => selected = v!),
                  ),
                  title: const Text('Private'),
                  subtitle: const Text('Hidden — students need the Room ID to join'),
                  trailing: const Icon(Icons.lock_outline),
                  onTap: () => setD(() => selected = 'private'),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, selected),
                  child: const Text('Publish')),
            ],
          ),
        );
      },
    );
    if (!mounted || visibility == null) return;

    // Merge visibility into classroom map for publishClassroom
    final classroomWithVisibility = {...classroom, 'visibility': visibility};

    setState(() => _cloudBusy.add(classroomId));

    final result = await CloudSyncService.publishClassroom(classroomWithVisibility);

    if (!mounted) return;
    setState(() => _cloudBusy.remove(classroomId));

    if (result.remoteId != null) {
      await AsuraRepository.updateClassroomPublishStatus(
        classroomId,
        remoteId: result.remoteId,
        isPublished: 1,
        visibility: visibility,
      );
      await _refreshRooms();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(visibility == 'private'
                ? 'Classroom published (Private). Share the Room ID with your students.'
                : 'Classroom published online.'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.error.isNotEmpty
                ? 'Publish failed: ${result.error}'
                : 'Publish failed. Check your connection.'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  Future<void> _unpublishClassroom(Map<String, dynamic> classroom) async {
    final classroomId = (classroom['id']?.toString() ?? '');
    if (classroomId.isEmpty) return;
    final remoteId    = (classroom['remote_id']?.toString());
    if (remoteId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpublish Classroom'),
        content: const Text(
            'Students will no longer find this classroom online. Local data is not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unpublish'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _cloudBusy.add(classroomId));

    final ok = await CloudSyncService.unpublishClassroom(remoteId);

    if (!mounted) return;
    setState(() => _cloudBusy.remove(classroomId));

    // Always clear local publish status even if server call fails (best-effort)
    await AsuraRepository.updateClassroomPublishStatus(
      classroomId,
      remoteId: ok ? null : remoteId,
      isPublished: ok ? 0 : 1,
    );
    await _refreshRooms();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? 'Classroom unpublished.' : 'Server error — try again.'),
          backgroundColor: ok ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Widget _buildQuickAction(IconData icon, String label, Color color, Map<String, dynamic> classroom) {
    return InkWell(
      onTap: () {
        if (label == 'Materials') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MaterialsLibraryView(
                classroomId: classroom['id']?.toString() ?? '',
                classroomName: (classroom['name'] as String?) ?? 'Classroom',
              ),
            ),
          );
        } else if (label == 'Attendance') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AttendanceLogView(
                classroomId: classroom['id']?.toString() ?? '',
                classroomName: (classroom['name'] as String?) ?? 'Classroom',
                classroomSchedule: (classroom['schedule'] as String?) ?? '',
              ),
            ),
          );
        } else if (label == 'Quizzes') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => RoomQuizListView(
                classroomId: classroom['id']?.toString() ?? '',
                classroomName: (classroom['name'] as String?) ?? 'Classroom',
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$label — coming in a future update.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}