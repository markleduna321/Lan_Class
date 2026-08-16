// lib/features/quiz/quiz_template_list_view.dart

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../database/asura_repository.dart';
import 'quiz_template_editor_view.dart';

class QuizTemplateListView extends StatefulWidget {
  const QuizTemplateListView({super.key});

  @override
  State<QuizTemplateListView> createState() => _QuizTemplateListViewState();
}

class _QuizTemplateListViewState extends State<QuizTemplateListView> {
  List<Map<String, dynamic>> _templates = [];
  Map<String, int> _questionCounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final templates = await AsuraRepository.getAllQuizTemplates();
    final counts = <String, int>{};
    for (final t in templates) {
      final qs =
          await AsuraRepository.getTemplateQuestions(t['id'] as String);
      counts[t['id'] as String] = qs.length;
    }
    if (mounted) {
      setState(() {
        _templates = templates;
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
        title: const Text('New Quiz Template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Template Title', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                  labelText: 'Description (optional)',
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
      await AsuraRepository.insertQuizTemplate({
        'id': id,
        'title': title,
        'description': descController.text.trim().isEmpty
            ? null
            : descController.text.trim(),
        'created_at': DateTime.now().toIso8601String(),
      });
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => QuizTemplateEditorView(templateId: id)),
        ).then((_) => _refresh());
      }
    }
  }

  Future<void> _delete(String id, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Template?'),
        content:
            Text('"$title" and all its questions will be permanently deleted.'),
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
      await AsuraRepository.deleteQuizTemplate(id);
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quiz Library'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Template'),
        onPressed: _createNew,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _templates.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.quiz_outlined, size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('No quiz templates yet.',
                          style:
                              TextStyle(color: Colors.grey, fontSize: 16)),
                      SizedBox(height: 4),
                      Text('Create reusable templates for your quizzes.',
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
                    itemCount: _templates.length,
                    itemBuilder: (ctx, i) {
                      final t = _templates[i];
                      final id = t['id'] as String;
                      final count = _questionCounts[id] ?? 0;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Color(0xFF1E3A8A),
                            child: Icon(Icons.quiz, color: Colors.white),
                          ),
                          title: Text(t['title'] as String,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            '${t['description'] ?? 'No description'}  •  $count question${count == 1 ? '' : 's'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) {
                              if (action == 'edit') {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => QuizTemplateEditorView(
                                        templateId: id),
                                  ),
                                ).then((_) => _refresh());
                              } else if (action == 'delete') {
                                _delete(id, t['title'] as String);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'edit',
                                  child: ListTile(
                                      leading: Icon(Icons.edit_outlined),
                                      title: Text('Edit'),
                                      contentPadding: EdgeInsets.zero)),
                              const PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                      leading: Icon(Icons.delete_outline,
                                          color: Colors.red),
                                      title: Text('Delete',
                                          style:
                                              TextStyle(color: Colors.red)),
                                      contentPadding: EdgeInsets.zero)),
                            ],
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  QuizTemplateEditorView(templateId: id),
                            ),
                          ).then((_) => _refresh()),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
