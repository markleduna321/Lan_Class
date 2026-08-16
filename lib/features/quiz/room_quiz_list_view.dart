// lib/features/quiz/room_quiz_list_view.dart

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../database/asura_repository.dart';
import 'room_quiz_editor_view.dart';

class RoomQuizListView extends StatefulWidget {
  final String classroomId;
  final String classroomName;

  const RoomQuizListView({
    super.key,
    required this.classroomId,
    required this.classroomName,
  });

  @override
  State<RoomQuizListView> createState() => _RoomQuizListViewState();
}

class _RoomQuizListViewState extends State<RoomQuizListView> {
  List<Map<String, dynamic>> _quizzes = [];
  Map<String, int> _questionCounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final quizzes = await AsuraRepository.getRoomQuizzesForClassroom(
        widget.classroomId);
    final counts = <String, int>{};
    for (final q in quizzes) {
      final qs =
          await AsuraRepository.getRoomQuizQuestions(q['id'] as String);
      counts[q['id'] as String] = qs.length;
    }
    if (mounted) {
      setState(() {
        _quizzes = quizzes;
        _questionCounts = counts;
        _loading = false;
      });
    }
  }

  Future<void> _createNew() async {
    final id = const Uuid().v4();
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Quiz'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Quiz Title', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                  labelText: 'Instructions (optional)',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E3A8A),
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final title = nameController.text.trim();
      if (title.isEmpty) return;
      await AsuraRepository.insertRoomQuiz({
        'id': id,
        'classroom_id': widget.classroomId,
        'title': title,
        'description': descController.text.trim().isEmpty
            ? null
            : descController.text.trim(),
        'status': 'draft',
        'source_template_id': null,
        'created_at': DateTime.now().toIso8601String(),
      });
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => RoomQuizEditorView(quizId: id)),
        ).then((_) => _refresh());
      }
    }
  }

  Future<void> _delete(String id, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Quiz?'),
        content: Text('"$title" and all responses will be permanently deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await AsuraRepository.deleteRoomQuiz(id);
      _refresh();
    }
  }

  Color _statusColor(String status) => switch (status) {
        'active' => Colors.green,
        'closed' => Colors.grey,
        _ => Colors.blue,
      };

  IconData _statusIcon(String status) => switch (status) {
        'active' => Icons.play_circle,
        'closed' => Icons.check_circle,
        _ => Icons.pending_outlined,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Quizzes',
                style:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text(widget.classroomName,
                style: const TextStyle(fontSize: 12)),
          ],
        ),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Quiz'),
        onPressed: _createNew,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _quizzes.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.quiz_outlined,
                          size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('No quizzes for this room.',
                          style: TextStyle(color: Colors.grey, fontSize: 16)),
                      SizedBox(height: 4),
                      Text('Create a quiz to launch during a live session.',
                          style:
                              TextStyle(color: Colors.grey, fontSize: 13)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(
                        left: 16, right: 16, top: 16, bottom: 80),
                    itemCount: _quizzes.length,
                    itemBuilder: (ctx, i) {
                      final q = _quizzes[i];
                      final id = q['id'] as String;
                      final status = q['status'] as String? ?? 'draft';
                      final count = _questionCounts[id] ?? 0;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                _statusColor(status).withValues(alpha: 0.15),
                            child: Icon(
                              _statusIcon(status),
                              color: _statusColor(status),
                            ),
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  q['title'] as String,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Chip(
                                label: Text(
                                  status.toUpperCase(),
                                  style: const TextStyle(fontSize: 10),
                                ),
                                backgroundColor:
                                    _statusColor(status).withValues(alpha: 0.15),
                                labelStyle:
                                    TextStyle(color: _statusColor(status)),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                padding: EdgeInsets.zero,
                              ),
                            ],
                          ),
                          subtitle: Text(
                            '$count question${count == 1 ? '' : 's'}${q['description'] != null ? '  •  ${q['description']}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) {
                              if (action == 'edit') {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          RoomQuizEditorView(quizId: id)),
                                ).then((_) => _refresh());
                              } else if (action == 'delete') {
                                _delete(id, q['title'] as String);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'edit',
                                  child: ListTile(
                                      leading: Icon(Icons.edit_outlined),
                                      title: Text('Edit Questions'),
                                      contentPadding: EdgeInsets.zero)),
                              const PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                      leading: Icon(Icons.delete_outline,
                                          color: Colors.red),
                                      title: Text('Delete',
                                          style: TextStyle(
                                              color: Colors.red)),
                                      contentPadding: EdgeInsets.zero)),
                            ],
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    RoomQuizEditorView(quizId: id)),
                          ).then((_) => _refresh()),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
