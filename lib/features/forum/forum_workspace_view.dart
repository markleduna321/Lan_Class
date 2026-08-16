// lib/features/forum/forum_workspace_view.dart
//
// Community Forum — browse, vote, and create posts.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../database/asura_repository.dart';
import '../../services/cloud_api_service.dart';
import '../auth/role_utils.dart';
import '../shared/aura.dart';
import 'forum_shared.dart';
import 'forum_post_detail_view.dart';
import 'forum_create_post_sheet.dart';
import 'public_profile_view.dart';

const _kBrand = Color(0xFF1E3A8A);

const _kCategories = [
  ('all',      'All',      Icons.list_alt_outlined),
  ('question', 'Question', Icons.help_outline),
  ('poll',     'Poll',     Icons.poll_outlined),
  ('showcase', 'Showcase', Icons.rocket_launch_outlined),
];

// ---------------------------------------------------------------------------
// Main view
// ---------------------------------------------------------------------------

class ForumWorkspaceView extends StatefulWidget {
  const ForumWorkspaceView({super.key});

  @override
  State<ForumWorkspaceView> createState() => _ForumWorkspaceViewState();
}

class _ForumWorkspaceViewState extends State<ForumWorkspaceView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String _selectedCategory = 'all';
  bool _loading = true;
  bool _hasError = false;
  String _errorMsg = '';
  List<Map<String, dynamic>> _posts = [];
  int _auraScore = 0;
  String _myName = '';
  String _myNickname = '';
  String _myId = '';

  @override
  void initState() {
    super.initState();
    _loadUserThenPosts();
  }

  Future<void> _loadUserThenPosts() async {
    const s = FlutterSecureStorage();
    final activeUser = await AsuraRepository.getActiveUser();
    _myName = (activeUser?['name'] as String?)?.trim().isNotEmpty == true
        ? (activeUser!['name'] as String).trim()
        : await s.read(key: 'ACTIVE_USER_NAME') ?? 'User';
    _myNickname = (activeUser?['nickname'] as String?)?.trim() ?? '';
    _myId   = await s.read(key: 'ONLINE_USER_ID')   ?? _myName;

    final profile = await CloudApiService.getCurrentProfile();
    if (profile != null) {
      final profileName = (profile['name'] as String?)?.trim();
      final profileNickname = (profile['nickname'] as String?)?.trim();
      if (profileName != null && profileName.isNotEmpty) {
        _myName = profileName;
      }
      if (profileNickname != null) {
        _myNickname = profileNickname;
      }
    }
    _loadReputation();
    _fetchPosts();
  }

  Future<void> _loadReputation() async {
    int? aura;

    // Source of truth: user profile aura fields.
    final profile = await CloudApiService.getCurrentProfile();
    aura = extractReputationFromApiPayload(profile);

    // Fallback: forum endpoint if profile aura is unavailable.
    if (aura == null) {
      final r = await CloudApiService.get('/api/forum/reputation');
      if (r != null && r.statusCode == 200) {
        try {
          final data = jsonDecode(r.body) as Map<String, dynamic>;
          aura = extractReputationFromApiPayload(data);
        } catch (_) {}
      }
    }

    if (mounted && aura != null) {
      setState(() => _auraScore = aura!);
    }
  }

  Future<void> _fetchPosts({bool silent = false}) async {
    if (!silent && mounted) setState(() { _loading = true; _hasError = false; });
    final q = _selectedCategory == 'all' ? '' : '?category=$_selectedCategory';
    final r = await CloudApiService.get('/api/forum/posts$q');
    if (!mounted) return;
    if (r == null || r.statusCode != 200) {
      setState(() {
        _loading = false;
        if (!silent) {
          _hasError = true;
          _errorMsg = r == null ? 'Could not reach the server.' : 'Server error (${r.statusCode}).';
        }
      });
      return;
    }
    try {
      final decoded = jsonDecode(r.body);
      final raw = decoded is List ? decoded : (decoded['data'] as List? ?? []);
      setState(() { _posts = raw.cast<Map<String, dynamic>>(); _loading = false; });
    } catch (_) {
      setState(() { _loading = false; if (!silent) _hasError = true; _errorMsg = 'Unexpected response.'; });
    }
  }

  Future<void> _vote(String postId, int vote) async {
    final idx = _posts.indexWhere((p) => p['id'].toString() == postId);
    if (idx < 0) return;
    final post = Map<String, dynamic>.from(_posts[idx]);
    final prevVote  = (post['user_vote']  as int?) ?? 0;
    final prevScore = (post['vote_score'] as int?) ?? 0;
    final newVote   = prevVote == vote ? 0 : vote;
    post['user_vote']  = newVote;
    post['vote_score'] = prevScore - prevVote + newVote;
    setState(() => _posts[idx] = post);
    final r = await CloudApiService.post('/api/forum/posts/$postId/vote', {'vote': newVote});
    if (r == null || r.statusCode != 200) {
      post['user_vote']  = prevVote;
      post['vote_score'] = prevScore;
      if (mounted) setState(() => _posts[idx] = post);
      return;
    }

    await _loadReputation();
  }

  Future<void> _pollVote(String postId, String optionId) async {
    final idx = _posts.indexWhere((p) => p['id'].toString() == postId);
    if (idx < 0) return;
    final post = Map<String, dynamic>.from(_posts[idx]);
    final prev = post['user_poll_vote'] as String?;
    if (prev == optionId) return;
    final opts = (post['poll_options'] as List?)?.cast<Map<String, dynamic>>().map((o) {
      final op = Map<String, dynamic>.from(o);
      if (op['id'].toString() == optionId) op['votes'] = (op['votes'] as int? ?? 0) + 1;
      if (prev != null && op['id'].toString() == prev) {
        op['votes'] = ((op['votes'] as int? ?? 1) - 1).clamp(0, 99999);
      }
      return op;
    }).toList();
    post['poll_options']   = opts;
    post['user_poll_vote'] = optionId;
    setState(() => _posts[idx] = post);
    await CloudApiService.post('/api/forum/posts/$postId/poll-vote', {'option_id': optionId});
  }

  void _openDetail(Map<String, dynamic> post) async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => ForumPostDetailView(
        postId: post['id'].toString(),
          initialPost: _applyCurrentNickname(post),
        myName: _myName,
          myNickname: _myNickname,
        myId: _myId,
        onPostUpdated: (updated) {
          final i = _posts.indexWhere((p) => p['id'].toString() == updated['id'].toString());
            if (i >= 0 && mounted) setState(() => _posts[i] = _applyCurrentNickname(updated));
        },
      ),
    ));
  }

  void _createPost() async {
    final created = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ForumCreatePostSheet(
        authorName: _myName,
        authorNickname: _myNickname,
        authorId: _myId,
      ),
    );
    if (created != null && mounted) {
      setState(() => _posts.insert(0, _applyCurrentNickname(created)));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post published!'), backgroundColor: Colors.green),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'forum_fab',
        onPressed: _createPost,
        backgroundColor: _kBrand,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New Post'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildReputationBanner(),
          _buildCategoryBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildReputationBanner() {
    final tier = auraTierFor(_auraScore);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1E3A8A), Color(0xFF2563EB)]),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        AuraFlameBadge(score: _auraScore, size: 28),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tier.label} Tier', style: const TextStyle(color: Colors.white60, fontSize: 11)),
          Text('$_auraScore Aura', style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
        const Spacer(),
        Text(_myNickname.isNotEmpty ? _myNickname : _myName, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]),
    );
  }

  Map<String, dynamic> _applyCurrentNickname(Map<String, dynamic> post) {
    if (_myNickname.trim().isEmpty) return post;
    if (post['author_id']?.toString() != _myId) return post;

    final updated = Map<String, dynamic>.from(post);
    updated['author_nickname'] = _myNickname.trim();

    final responses = updated['responses'];
    if (responses is List) {
      updated['responses'] = responses.map((item) {
        if (item is! Map<String, dynamic>) return item;
        if (item['author_id']?.toString() != _myId) return item;
        final response = Map<String, dynamic>.from(item);
        response['author_nickname'] = _myNickname.trim();
        return response;
      }).toList();
    }

    return updated;
  }

  Widget _buildCategoryBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _kCategories.map((c) {
            final (id, label, icon) = c;
            final sel = _selectedCategory == id;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                avatar: Icon(icon, size: 14, color: sel ? Colors.white : Colors.grey.shade600),
                label: Text(label, style: TextStyle(color: sel ? Colors.white : Colors.black87, fontSize: 13)),
                selected: sel,
                onSelected: (_) { setState(() => _selectedCategory = id); _fetchPosts(); },
                selectedColor: _kBrand,
                showCheckmark: false,
                side: BorderSide(color: sel ? _kBrand : Colors.grey.shade300),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_hasError) {
      return Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.wifi_off, size: 56, color: Colors.grey.shade300),
        const SizedBox(height: 12),
        Text(_errorMsg, style: TextStyle(color: Colors.grey.shade500), textAlign: TextAlign.center),
        const SizedBox(height: 20),
        ElevatedButton.icon(onPressed: _fetchPosts, icon: const Icon(Icons.refresh), label: const Text('Retry')),
      ])));
    }
    if (_posts.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.forum_outlined, size: 72, color: Colors.grey.shade300),
        const SizedBox(height: 14),
        Text('No posts yet.\nTap "New Post" to start the discussion!',
            style: TextStyle(color: Colors.grey.shade500, height: 1.5), textAlign: TextAlign.center),
      ]));
    }
    return RefreshIndicator(
      onRefresh: () => _fetchPosts(silent: false),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
        itemCount: _posts.length,
        itemBuilder: (_, i) => _PostCard(
          post: _applyCurrentNickname(_posts[i]),
          onTap: () => _openDetail(_posts[i]),
          onVote: (v) => _vote(_posts[i]['id'].toString(), v),
          onPollVote: (opt) => _pollVote(_posts[i]['id'].toString(), opt),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Post card
// ---------------------------------------------------------------------------

class _PostCard extends StatelessWidget {
  final Map<String, dynamic> post;
  final VoidCallback onTap;
  final void Function(int) onVote;
  final void Function(String) onPollVote;
  const _PostCard({required this.post, required this.onTap, required this.onVote, required this.onPollVote});

  @override
  Widget build(BuildContext context) {
    final category   = (post['category']    as String?) ?? 'question';
    final title      = (post['title']       as String?) ?? '';
    final body       = (post['body']        as String?) ?? '';
    final authorName = forumAuthorName(post);
    final authorAura = forumAuthorAura(post);
    final authorId   = forumAuthorId(post);
    final score      = (post['vote_score']  as int?)    ?? 0;
    final userVote   = (post['user_vote']   as int?)    ?? 0;
    final resCount   = (post['response_count'] as int?) ?? 0;
    final code       = post['code_snippet'] as String?;
    final link       = post['link']         as String?;
    final pollOpts   = post['poll_options'] as List?;
    final catColor   = forumCategoryColor(category);
    final catLabel   = category[0].toUpperCase() + category.substring(1);

    return Card(
      margin: const EdgeInsets.only(top: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: Colors.grey.shade200)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ForumAuthorLabel(
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
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.3)),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(body, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4)),
            ],
            if (code != null && code.isNotEmpty) ...[
              const SizedBox(height: 8),
              ForumCodeSnippet(code: code),
            ],
            if (link != null && link.isNotEmpty) ...[
              const SizedBox(height: 8),
              ForumLinkTile(url: link),
            ],
            if (pollOpts != null && pollOpts.isNotEmpty) ...[
              const SizedBox(height: 8),
              ForumPollWidget(
                options: pollOpts.cast<Map<String, dynamic>>(),
                userVote: post['user_poll_vote'] as String?,
                onVote: onPollVote,
              ),
            ],
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(children: [
              ForumVoteButtons(score: score, userVote: userVote, onVote: onVote),
              const Spacer(),
              Icon(Icons.comment_outlined, size: 16, color: Colors.grey.shade500),
              const SizedBox(width: 4),
              Text('$resCount', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ]),
          ]),
        ),
      ),
    );
  }
}