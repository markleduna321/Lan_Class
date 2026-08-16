// lib/features/forum/forum_create_post_sheet.dart
//
// Bottom sheet for composing a new forum post.
// Supports: Question, Poll, Showcase categories.
// Text + optional code snippet + optional link. No images.

import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/cloud_api_service.dart';
import 'forum_shared.dart';

class ForumCreatePostSheet extends StatefulWidget {
  final String authorName;
  final String authorNickname;
  final String authorId;

  const ForumCreatePostSheet({
    super.key,
    required this.authorName,
    required this.authorNickname,
    required this.authorId,
  });

  @override
  State<ForumCreatePostSheet> createState() => _ForumCreatePostSheetState();
}

class _ForumCreatePostSheetState extends State<ForumCreatePostSheet> {
  final _formKey    = GlobalKey<FormState>();
  final _titleCtrl  = TextEditingController();
  final _bodyCtrl   = TextEditingController();
  final _codeCtrl   = TextEditingController();
  final _linkCtrl   = TextEditingController();

  String _category  = 'question';
  bool _addCode     = false;
  bool _addLink     = false;
  bool _submitting  = false;

  // Poll state
  final List<TextEditingController> _pollOptionCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];

  static const _kCategories = [
    ('question', 'Question', Icons.help_outline,           Color(0xFF2563EB)),
    ('poll',     'Poll',     Icons.poll_outlined,           Color(0xFF16A34A)),
    ('showcase', 'Showcase', Icons.rocket_launch_outlined,  Color(0xFFEA580C)),
  ];

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _codeCtrl.dispose();
    _linkCtrl.dispose();
    for (final c in _pollOptionCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    // Poll-specific validation
    if (_category == 'poll') {
      final filled = _pollOptionCtrls.where((c) => c.text.trim().isNotEmpty).length;
      if (filled < 2) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A poll needs at least 2 options.'),
              backgroundColor: Colors.orange),
        );
        return;
      }
    }

    setState(() => _submitting = true);

    final payload = <String, dynamic>{
      'category':    _category,
      'title':       _titleCtrl.text.trim(),
      'body':        _bodyCtrl.text.trim(),
      'author_name': widget.authorName,
      'author_id':   widget.authorId,
      if (widget.authorNickname.trim().isNotEmpty)
        'author_nickname': widget.authorNickname.trim(),
      if (_addCode && _codeCtrl.text.trim().isNotEmpty)
        'code_snippet': _codeCtrl.text.trim(),
      if (_addLink && _linkCtrl.text.trim().isNotEmpty)
        'link': _linkCtrl.text.trim(),
      if (_category == 'poll')
        'poll_options': _pollOptionCtrls
            .map((c) => c.text.trim())
            .where((t) => t.isNotEmpty)
            .toList(),
    };

    final r = await CloudApiService.post('/api/forum/posts', payload);
    if (!mounted) return;
    setState(() => _submitting = false);

    if (r != null && (r.statusCode == 200 || r.statusCode == 201)) {
      try {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        final post = Map<String, dynamic>.from(
          (data['post'] as Map<String, dynamic>?) ?? data,
        );
        post['author_name'] = (post['author_name'] as String?)?.trim().isNotEmpty == true
            ? post['author_name']
            : widget.authorName;
        if ((post['author_nickname'] as String?)?.trim().isNotEmpty != true &&
            widget.authorNickname.trim().isNotEmpty) {
          post['author_nickname'] = widget.authorNickname.trim();
        }
        Navigator.pop(context, post);
        return;
      } catch (_) {}
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(r == null
            ? 'No connection. Check your internet.'
            : 'Could not publish (${r.statusCode}). Try again.'),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottom),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),

              // Title
              const Text('New Post',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),

              // Category selector
              const Text('Category',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(children: _kCategories.map((c) {
                final (id, label, icon, color) = c;
                final selected = _category == id;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onTap: () => setState(() => _category = id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: selected
                              ? color.withValues(alpha: 0.12)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: selected ? color : Colors.transparent,
                              width: 1.5),
                        ),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(icon, size: 18,
                              color: selected ? color : Colors.grey.shade500),
                          const SizedBox(height: 4),
                          Text(label,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.normal,
                                  color: selected ? color : Colors.grey.shade600)),
                        ]),
                      ),
                    ),
                  ),
                );
              }).toList()),
              const SizedBox(height: 16),

              // Title field
              TextFormField(
                controller: _titleCtrl,
                maxLength: 200,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Title *',
                  hintText: 'A concise, descriptive title',
                  counterText: '',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Title is required' : null,
              ),
              const SizedBox(height: 12),

              // Body field
              TextFormField(
                controller: _bodyCtrl,
                maxLines: 4,
                maxLength: 2000,
                decoration: InputDecoration(
                  labelText: _category == 'poll'
                      ? 'Description (optional)'
                      : 'Body *',
                  hintText: 'Explain your question, idea, or showcase…',
                  counterText: '',
                  alignLabelWithHint: true,
                ),
                validator: (v) {
                  if (_category != 'poll' && (v == null || v.trim().isEmpty)) {
                    return 'Body is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),

              // Poll options (only for Poll category)
              if (_category == 'poll') ...[
                const Text('Poll Options',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ..._pollOptionCtrls.asMap().entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Expanded(
                          child: TextFormField(
                            controller: e.value,
                            decoration: InputDecoration(
                              hintText: 'Option ${e.key + 1}',
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                            ),
                          ),
                        ),
                        if (e.key >= 2)
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline,
                                color: Colors.red),
                            onPressed: () {
                              setState(() {
                                _pollOptionCtrls[e.key].dispose();
                                _pollOptionCtrls.removeAt(e.key);
                              });
                            },
                          ),
                      ]),
                    )),
                if (_pollOptionCtrls.length < 6)
                  TextButton.icon(
                    onPressed: () => setState(
                        () => _pollOptionCtrls.add(TextEditingController())),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add option'),
                  ),
                const SizedBox(height: 4),
              ],

              // Optional extras row
              Row(children: [
                _ToggleChip(
                    label: 'Code snippet',
                    icon: Icons.code,
                    active: _addCode,
                    onTap: () => setState(() => _addCode = !_addCode)),
                const SizedBox(width: 8),
                _ToggleChip(
                    label: 'Link',
                    icon: Icons.link,
                    active: _addLink,
                    onTap: () => setState(() => _addLink = !_addLink)),
              ]),

              // Code snippet field
              if (_addCode) ...[
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: TextField(
                    controller: _codeCtrl,
                    maxLines: 6,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Color(0xFFD4D4D4)),
                    decoration: const InputDecoration(
                      hintText: '// Paste your code here',
                      hintStyle: TextStyle(
                          color: Color(0xFF6A9955),
                          fontFamily: 'monospace',
                          fontSize: 12),
                      border: InputBorder.none,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      fillColor: Colors.transparent,
                    ),
                  ),
                ),
              ],

              // Link field
              if (_addLink) ...[
                const SizedBox(height: 10),
                TextFormField(
                  controller: _linkCtrl,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'URL',
                    hintText: 'https://…',
                    prefixIcon: Icon(Icons.link),
                  ),
                  validator: (v) {
                    if (_addLink && v != null && v.isNotEmpty) {
                      if (!v.startsWith('http://') && !v.startsWith('https://')) {
                        return 'URL must start with http:// or https://';
                      }
                    }
                    return null;
                  },
                ),
              ],

              const SizedBox(height: 20),

              // Submit
              _submitting
                  ? const Center(child: CircularProgressIndicator())
                  : FilledButton(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: forumCategoryColor(_category),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Publish Post',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _ToggleChip(
      {required this.label,
      required this.icon,
      required this.active,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF1E3A8A).withValues(alpha: 0.1)
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active
                  ? const Color(0xFF1E3A8A)
                  : Colors.grey.shade300),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 14,
              color: active
                  ? const Color(0xFF1E3A8A)
                  : Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: active
                      ? const Color(0xFF1E3A8A)
                      : Colors.grey.shade600,
                  fontWeight: active
                      ? FontWeight.w600
                      : FontWeight.normal)),
        ]),
      ),
    );
  }
}
