// lib/features/forum/forum_post_detail_view.dart
//
// Full post view with responses, vote controls, code snippet, link, and poll.

import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/cloud_api_service.dart';
import 'forum_shared.dart';
import 'public_profile_view.dart';

class ForumPostDetailView extends StatefulWidget {
  final String postId;
  final Map<String, dynamic> initialPost;
  final String myName;
  final String myNickname;
  final String myId;
  final void Function(Map<String, dynamic>) onPostUpdated;

  const ForumPostDetailView({
    super.key,
    required this.postId,
    required this.initialPost,
    required this.myName,
    required this.myNickname,
    required this.myId,
    required this.onPostUpdated,
  });

  @override
  State<ForumPostDetailView> createState() => _ForumPostDetailViewState();
}

class _ForumPostDetailViewState extends State<ForumPostDetailView> {
  late Map<String, dynamic> _post;
  List<Map<String, dynamic>> _responses = [];
  bool _loadingResponses = true;
  bool _submitting = false;
  final _replyCtrl    = TextEditingController();
  final _replyCodeCtrl = TextEditingController();
  bool _showCodeField = false;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _post = Map<String, dynamic>.from(widget.initialPost);
    _loadDetail();
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    _replyCodeCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    final r = await CloudApiService.get('/api/forum/posts/${widget.postId}');
    if (!mounted || r == null || r.statusCode != 200) {
      setState(() => _loadingResponses = false);
      return;
    }
    try {
      final data     = jsonDecode(r.body) as Map<String, dynamic>;
      final postData = (data['post'] as Map<String, dynamic>?) ?? data;
      final rawRes   = postData['responses'] as List? ?? data['responses'] as List? ?? [];
      setState(() {
        _post             = postData;
        _responses        = rawRes.cast<Map<String, dynamic>>();
        _loadingResponses = false;
      });
      widget.onPostUpdated(_post);
    } catch (_) {
      setState(() => _loadingResponses = false);
    }
  }

  Future<void> _votePost(int vote) async {
    final prev    = (_post['user_vote']  as int?) ?? 0;
    final prevSc  = (_post['vote_score'] as int?) ?? 0;
    final newVote = prev == vote ? 0 : vote;
    setState(() { _post['user_vote'] = newVote; _post['vote_score'] = prevSc - prev + newVote; });
    widget.onPostUpdated(_post);
    final r = await CloudApiService.post('/api/forum/posts/${widget.postId}/vote', {'vote': newVote});
    if (r == null || r.statusCode != 200) {
      setState(() { _post['user_vote'] = prev; _post['vote_score'] = prevSc; });
      widget.onPostUpdated(_post);
    }
  }

  Future<void> _voteResponse(int idx, int vote) async {
    final res    = Map<String, dynamic>.from(_responses[idx]);
    final prev   = (res['user_vote']  as int?) ?? 0;
    final prevSc = (res['vote_score'] as int?) ?? 0;
    final newVote = prev == vote ? 0 : vote;
    res['user_vote']  = newVote;
    res['vote_score'] = prevSc - prev + newVote;
    setState(() => _responses[idx] = res);
    final rid = res['id'].toString();
    final r = await CloudApiService.post('/api/forum/posts/${widget.postId}/responses/$rid/vote', {'vote': newVote});
    if (r == null || r.statusCode != 200) {
      res['user_vote']  = prev;
      res['vote_score'] = prevSc;
      if (mounted) setState(() => _responses[idx] = res);
    }
  }

  Future<void> _pollVote(String optId) async {
    final prev = _post['user_poll_vote'] as String?;
    if (prev == optId) return;
    final opts = (_post['poll_options'] as List?)?.cast<Map<String, dynamic>>().map((o) {
      final op = Map<String, dynamic>.from(o);
      if (op['id'].toString() == optId) op['votes'] = (op['votes'] as int? ?? 0) + 1;
      if (prev != null && op['id'].toString() == prev) op['votes'] = ((op['votes'] as int? ?? 1) - 1).clamp(0, 99999);
      return op;
    }).toList();
    setState(() { _post['poll_options'] = opts; _post['user_poll_vote'] = optId; });
    widget.onPostUpdated(_post);
    await CloudApiService.post('/api/forum/posts/${widget.postId}/poll-vote', {'option_id': optId});
  }

  Future<void> _submitResponse() async {
    final body = _replyCtrl.text.trim();
    if (body.isEmpty) return;
    final code = _replyCodeCtrl.text.trim();
    setState(() => _submitting = true);
    final payload = <String, dynamic>{
      'body': body, 'author_name': widget.myName, 'author_id': widget.myId,
      if (widget.myNickname.trim().isNotEmpty)
        'author_nickname': widget.myNickname.trim(),
      if (code.isNotEmpty) 'code_snippet': code,
    };
    final r = await CloudApiService.post('/api/forum/posts/${widget.postId}/responses', payload);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (r != null && (r.statusCode == 200 || r.statusCode == 201)) {
      try {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        final res  = Map<String, dynamic>.from(
          (data['response'] as Map<String, dynamic>?) ?? data,
        );
        res['author_name'] = (res['author_name'] as String?)?.trim().isNotEmpty == true
            ? res['author_name']
            : widget.myName;
        if ((res['author_nickname'] as String?)?.trim().isNotEmpty != true &&
            widget.myNickname.trim().isNotEmpty) {
          res['author_nickname'] = widget.myNickname.trim();
        }
        _replyCtrl.clear(); _replyCodeCtrl.clear();
        setState(() {
          _responses.add(res);
          _showCodeField = false;
          _post['response_count'] = (_post['response_count'] as int? ?? 0) + 1;
        });
        widget.onPostUpdated(_post);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
          }
        });
      } catch (_) {}
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not post response. Try again.'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final category   = (_post['category']    as String?) ?? 'question';
    final title      = (_post['title']       as String?) ?? '';
    final body       = (_post['body']        as String?) ?? '';
    final authorName = forumAuthorName(_post);
    final authorAura = forumAuthorAura(_post);
    final authorId   = forumAuthorId(_post);
    final score      = (_post['vote_score']  as int?)    ?? 0;
    final userVote   = (_post['user_vote']   as int?)    ?? 0;
    final code       = _post['code_snippet'] as String?;
    final link       = _post['link']         as String?;
    final pollOpts   = _post['poll_options'] as List?;
    final catColor   = forumCategoryColor(category);
    final catLabel   = category[0].toUpperCase() + category.substring(1);

    return Scaffold(
      appBar: AppBar(
        title: Text(catLabel),
        backgroundColor: catColor,
        foregroundColor: Colors.white,
      ),
      body: Column(children: [
        Expanded(
          child: ListView(
            controller: _scrollCtrl,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            children: [
              // Category + author header
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: catColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(forumCategoryIcon(category), size: 12, color: catColor),
                    const SizedBox(width: 4),
                    Text(catLabel, style: TextStyle(fontSize: 11, color: catColor, fontWeight: FontWeight.w600)),
                  ]),
                ),
                const SizedBox(width: 8),
                ForumAuthorLabel(
                  displayName: authorName,
                  aura: authorAura,
                  onTap: authorId == null
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PublicProfileView(
                                userId: authorId,
                                fallbackName: authorName,
                                fallbackAura: authorAura,
                              ),
                            ),
                          ),
                ),
              ]),
              const SizedBox(height: 10),
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.3)),
              const SizedBox(height: 12),
              if (body.isNotEmpty) Text(body, style: const TextStyle(fontSize: 14, height: 1.6)),
              if (code != null && code.isNotEmpty) ...[
                const SizedBox(height: 12),
                ForumCodeSnippet(code: code, full: true),
              ],
              if (link != null && link.isNotEmpty) ...[
                const SizedBox(height: 10),
                ForumLinkTile(url: link),
              ],
              if (pollOpts != null && pollOpts.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Poll', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 8),
                ForumPollWidget(
                  options: pollOpts.cast<Map<String, dynamic>>(),
                  userVote: _post['user_poll_vote'] as String?,
                  onVote: _pollVote,
                ),
              ],
              const SizedBox(height: 12),
              Row(children: [
                ForumVoteButtons(score: score, userVote: userVote, onVote: _votePost),
                const Spacer(),
                Text('${_responses.length} response${_responses.length == 1 ? "" : "s"}',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
              ]),
              const SizedBox(height: 16),
              const Divider(),
              // Responses
              if (_loadingResponses)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (_responses.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('No responses yet — be the first!',
                      style: TextStyle(color: Colors.grey.shade500))),
                )
              else
                ...List.generate(_responses.length, (i) => _ResponseCard(
                  response: _responses[i],
                  onVote: (v) => _voteResponse(i, v),
                )),
              const SizedBox(height: 8),
            ],
          ),
        ),
        // Reply input
        SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, -2))],
            ),
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_showCodeField) ...[
                  TextField(
                    controller: _replyCodeCtrl,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Paste code snippet…',
                      filled: true,
                      fillColor: const Color(0xFF1E1E1E),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    ),
                    style: const TextStyle(color: Color(0xFFD4D4D4), fontFamily: 'monospace', fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _replyCtrl,
                      maxLines: null,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'Write a response…',
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                        suffixIcon: IconButton(
                          tooltip: 'Add code snippet',
                          icon: Icon(Icons.code, color: _showCodeField ? const Color(0xFF1E3A8A) : Colors.grey),
                          onPressed: () => setState(() => _showCodeField = !_showCodeField),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _submitting
                      ? const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 2))
                      : FilledButton(
                          onPressed: _submitResponse,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1E3A8A),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                          child: const Icon(Icons.send, size: 18),
                        ),
                ]),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ResponseCard extends StatelessWidget {
  final Map<String, dynamic> response;
  final void Function(int) onVote;
  const _ResponseCard({required this.response, required this.onVote});

  @override
  Widget build(BuildContext context) {
    final author   = forumAuthorName(response);
    final aura     = forumAuthorAura(response);
    final authorId = forumAuthorId(response);
    final body     = (response['body']        as String?) ?? '';
    final code     = response['code_snippet'] as String?;
    final score    = (response['vote_score']  as int?)    ?? 0;
    final userVote = (response['user_vote']   as int?)    ?? 0;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: const Color(0xFF1E3A8A).withValues(alpha: 0.1),
            child: Text(author.isNotEmpty ? author[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: ForumAuthorLabel(
              displayName: author,
              aura: aura,
              fontSize: 13,
              onTap: authorId == null
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PublicProfileView(
                            userId: authorId,
                            fallbackName: author,
                            fallbackAura: aura,
                          ),
                        ),
                      ),
            ),
          ),
        ]),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(fontSize: 13, height: 1.5)),
        ],
        if (code != null && code.isNotEmpty) ...[
          const SizedBox(height: 8),
          ForumCodeSnippet(code: code, full: true),
        ],
        const SizedBox(height: 8),
        ForumVoteButtons(score: score, userVote: userVote, onVote: onVote),
      ]),
    );
  }
}