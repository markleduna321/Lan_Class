// lib/features/online/online_classroom_browser_view.dart
//
// Phase 3 — Online Classroom Browser (Student)
// Lists all published classrooms from the Laravel backend.

import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/cloud_api_service.dart';
import 'online_classroom_detail_view.dart';

class OnlineClassroomBrowserView extends StatefulWidget {
  /// Called when the student saves a classroom from the browser.
  /// [classroom] contains the raw JSON map from the API.
  final void Function(Map<String, dynamic> classroom) onSaveRoom;

  /// Set of remoteIds already saved by the student (for showing "Saved" badge).
  final Set<String> savedRemoteIds;

  const OnlineClassroomBrowserView({
    super.key,
    required this.onSaveRoom,
    required this.savedRemoteIds,
  });

  @override
  State<OnlineClassroomBrowserView> createState() =>
      _OnlineClassroomBrowserViewState();
}

class _OnlineClassroomBrowserViewState
    extends State<OnlineClassroomBrowserView>
    with AutomaticKeepAliveClientMixin {
  // Keep alive so tab state persists when switching tabs
  @override
  bool get wantKeepAlive => true;

  bool _isLoading = true;
  bool _isLinked = false;
  String? _errorMessage;
  List<Map<String, dynamic>> _classrooms = [];

  @override
  void initState() {
    super.initState();
    _loadClassrooms();
  }

  Future<void> _loadClassrooms() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final linked = await CloudApiService.isLinked;
    if (!mounted) return;

    if (!linked) {
      setState(() {
        _isLinked = false;
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLinked = true);

    final response = await CloudApiService.get('/api/classrooms');
    if (!mounted) return;

    if (response == null) {
      setState(() {
        _errorMessage = 'Could not reach the server. Check your connection.';
        _isLoading = false;
      });
      return;
    }

    if (response.statusCode == 200) {
      try {
        final decoded = jsonDecode(response.body);
        // Handle both array and {data: [...]} paginated responses
        final List<dynamic> raw =
            decoded is List ? decoded : (decoded['data'] as List? ?? []);
        final all = raw.cast<Map<String, dynamic>>();
        // Only show public rooms. Compare case-insensitively in case the
        // server returns 'Private' (capitalised). Rooms with no visibility
        // field default to public (backward-compatible).
        final publicOnly = all
            .where((c) =>
                ((c['visibility'] as String?) ?? 'public').toLowerCase() !=
                'private')
            .toList();
        setState(() {
          _classrooms = publicOnly;
          _isLoading = false;
        });
      } catch (_) {
        setState(() {
          _errorMessage = 'Unexpected response from server.';
          _isLoading = false;
        });
      }
    } else if (response.statusCode == 401) {
      setState(() {
        _errorMessage = 'Session expired. Please re-link your online account.';
        _isLoading = false;
      });
    } else {
      setState(() {
        _errorMessage = 'Server error (${response.statusCode}).';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_isLinked) {
      return _buildNotLinkedState();
    }

    if (_errorMessage != null) {
      return _buildErrorState();
    }

    return RefreshIndicator(
      onRefresh: _loadClassrooms,
      child: Stack(
        children: [
          _classrooms.isEmpty
              ? _buildEmptyState()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: _classrooms.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final cls = _classrooms[index];
                    return _ClassroomCard(
                      classroom: cls,
                      isSaved: widget.savedRemoteIds
                          .contains(cls['id']?.toString() ?? ''),
                      onTap: () => _openDetail(cls),
                      onSave: () => widget.onSaveRoom(cls),
                    );
                  },
                ),
          // Join Private Room FAB
          Positioned(
            bottom: 24,
            right: 16,
            child: FloatingActionButton.extended(
              heroTag: 'join_private_room',
              onPressed: _joinByRoomId,
              backgroundColor: const Color(0xFF1E3A8A),
              icon: const Icon(Icons.lock_open, color: Colors.white),
              label: const Text('Join by Room ID',
                  style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  void _openDetail(Map<String, dynamic> classroom) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnlineClassroomDetailView(
          remoteId: classroom['id'].toString(),
          name: (classroom['name'] as String?) ?? 'Unnamed Classroom',
          schedule: (classroom['schedule'] as String?) ?? '',
          teacherName: classroom['teacher_name'] as String?,
          isSaved: widget.savedRemoteIds
              .contains(classroom['id']?.toString() ?? ''),
          onSave: () => widget.onSaveRoom(classroom),
        ),
      ),
    );
  }

  Future<void> _joinByRoomId() async {
    final controller = TextEditingController();
    final roomId = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join Private Room'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Paste or type the Room ID',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Join')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || roomId == null || roomId.isEmpty) return;

    // Fetch classroom by ID from the server
    final response =
        await CloudApiService.get('/api/classrooms/$roomId');
    if (!mounted) return;

    if (response == null || response.statusCode != 200) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(response?.statusCode == 404
              ? 'Room not found. Check the Room ID and try again.'
              : 'Could not reach the server.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final Map<String, dynamic> classroom;
    try {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      // Server may wrap in {"data": {...}}
      classroom = (decoded['data'] as Map<String, dynamic>?) ?? decoded;
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unexpected server response.')),
      );
      return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnlineClassroomDetailView(
          remoteId: classroom['id']?.toString() ?? roomId,
          name: (classroom['name'] as String?) ?? 'Private Classroom',
          schedule: (classroom['schedule'] as String?) ?? '',
          teacherName: classroom['teacher_name'] as String?,
          isSaved: widget.savedRemoteIds
              .contains(classroom['id']?.toString() ?? ''),
          onSave: () => widget.onSaveRoom(classroom),
        ),
      ),
    );
  }

  Widget _buildNotLinkedState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 72, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            const Text(
              'Not linked to any server',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Link an online account in Profile → Cloud Account to browse classrooms.',
              style: TextStyle(color: Colors.grey.shade600, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, size: 64, color: Colors.red.shade200),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadClassrooms,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.school_outlined, size: 72, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'No published classrooms yet.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              'Pull down to refresh.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ClassroomCard extends StatelessWidget {
  final Map<String, dynamic> classroom;
  final bool isSaved;
  final VoidCallback onTap;
  final VoidCallback onSave;

  const _ClassroomCard({
    required this.classroom,
    required this.isSaved,
    required this.onTap,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final name     = (classroom['name'] as String?) ?? 'Unnamed';
    final schedule = (classroom['schedule'] as String?) ?? '';
    final teacher  = classroom['teacher_name'] as String?;
    final isActive = classroom['is_active'] == true ||
        classroom['is_active'] == 1;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E3A8A).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cloud_outlined,
                    color: Color(0xFF1E3A8A), size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isActive)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.shade100,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.circle,
                                    size: 8, color: Colors.green.shade700),
                                const SizedBox(width: 4),
                                Text('Live',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.green.shade800,
                                        fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                      ],
                    ),
                    if (schedule.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            const Icon(Icons.schedule,
                                size: 11, color: Colors.blueGrey),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(schedule,
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.blueGrey),
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                      ),
                    if (teacher != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('by $teacher',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              isSaved
                  ? Chip(
                      label: const Text('Saved',
                          style: TextStyle(fontSize: 11)),
                      backgroundColor: Colors.green.shade50,
                      side: BorderSide(color: Colors.green.shade300),
                      padding: EdgeInsets.zero,
                      labelPadding:
                          const EdgeInsets.symmetric(horizontal: 8),
                    )
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E3A8A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      onPressed: onSave,
                      child: const Text('Save'),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
