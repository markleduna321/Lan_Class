// lib/features/forum/forum_shared.dart
//
// Shared widgets and helpers used by forum_workspace_view and forum_post_detail_view.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shared/aura.dart';

// ---------------------------------------------------------------------------
// Author helpers — extract display name / aura / id from a post or response map
// ---------------------------------------------------------------------------

/// Display name for a post/response author: nickname → name → 'Unknown'.
String forumAuthorName(Map<String, dynamic> m) {
  final nick = (m['author_nickname'] as String?)?.trim();
  if (nick != null && nick.isNotEmpty) return nick;
  final name = (m['author_name'] as String?)?.trim();
  return (name != null && name.isNotEmpty) ? name : 'Unknown';
}

/// Author aura score (defaults to 0 = Low tier until the backend sends it).
int forumAuthorAura(Map<String, dynamic> m) => (m['author_aura'] as int?) ?? 0;

/// Author id, if present.
String? forumAuthorId(Map<String, dynamic> m) => m['author_id']?.toString();

// ---------------------------------------------------------------------------
// Author label — name (with aura effect) + flame badge, optionally tappable
// ---------------------------------------------------------------------------

class ForumAuthorLabel extends StatelessWidget {
  final String displayName;
  final int aura;
  final VoidCallback? onTap;
  final double fontSize;

  const ForumAuthorLabel({
    super.key,
    required this.displayName,
    required this.aura,
    this.onTap,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AuraFlameBadge(score: aura, size: fontSize + 3),
        const SizedBox(width: 4),
        Flexible(
          child: AuraName(
            name: displayName,
            score: aura,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            baseColor: const Color(0xFF6B7280), // grey-500 for Low tier
            maxLines: 1,
          ),
        ),
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: row,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Category helpers
// ---------------------------------------------------------------------------

Color forumCategoryColor(String cat) => switch (cat) {
      'question'  => const Color(0xFF2563EB),
      'poll'      => const Color(0xFF16A34A),
      'showcase'  => const Color(0xFFEA580C),
      _           => Colors.grey,
    };

IconData forumCategoryIcon(String cat) => switch (cat) {
      'question'  => Icons.help_outline,
      'poll'      => Icons.poll_outlined,
      'showcase'  => Icons.rocket_launch_outlined,
      _           => Icons.article_outlined,
    };

// ---------------------------------------------------------------------------
// Vote buttons
// ---------------------------------------------------------------------------

class ForumVoteButtons extends StatelessWidget {
  final int score;
  final int userVote;
  final void Function(int) onVote;
  const ForumVoteButtons({
    super.key,
    required this.score,
    required this.userVote,
    required this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _VoteBtn(
            icon: Icons.arrow_upward_rounded,
            active: userVote == 1,
            activeColor: Colors.green,
            onTap: () => onVote(1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            '$score',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: userVote == 1
                  ? Colors.green
                  : userVote == -1
                      ? Colors.red
                      : Colors.black87,
            ),
          ),
        ),
        _VoteBtn(
            icon: Icons.arrow_downward_rounded,
            active: userVote == -1,
            activeColor: Colors.red,
            onTap: () => onVote(-1)),
      ],
    );
  }
}

class _VoteBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  const _VoteBtn({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: active
              ? activeColor.withValues(alpha: 0.12)
              : Colors.grey.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            size: 18, color: active ? activeColor : Colors.grey.shade500),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Code snippet
// ---------------------------------------------------------------------------

class ForumCodeSnippet extends StatelessWidget {
  final String code;
  /// When true renders all lines; when false clips to 3 lines.
  final bool full;
  const ForumCodeSnippet({super.key, required this.code, this.full = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: full
          ? () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Code copied to clipboard.'),
                    duration: Duration(seconds: 2)),
              );
            }
          : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              code,
              maxLines: full ? null : 3,
              overflow: full ? null : TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Color(0xFFD4D4D4),
                  height: 1.5),
            ),
            if (full) ...[
              const SizedBox(height: 4),
              Text('long-press to copy',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 10,
                      color: Colors.white.withValues(alpha: 0.3))),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Link tile (tap = copy to clipboard)
// ---------------------------------------------------------------------------

class ForumLinkTile extends StatelessWidget {
  final String url;
  const ForumLinkTile({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: url));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Link copied to clipboard.'),
              duration: Duration(seconds: 2)),
        );
      },
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.link, size: 16, color: Colors.blue.shade700),
            const SizedBox(width: 8),
            Expanded(
                child: Text(url,
                    style: TextStyle(
                        color: Colors.blue.shade700, fontSize: 12),
                    overflow: TextOverflow.ellipsis)),
            Icon(Icons.copy, size: 13, color: Colors.blue.shade400),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Poll widget
// ---------------------------------------------------------------------------

class ForumPollWidget extends StatelessWidget {
  final List<Map<String, dynamic>> options;
  final String? userVote; // option id the current user voted for
  final void Function(String optId) onVote;
  const ForumPollWidget({
    super.key,
    required this.options,
    required this.userVote,
    required this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final totalVotes =
        options.fold<int>(0, (s, o) => s + ((o['votes'] as int?) ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: options.map((o) {
        final id    = o['id'].toString();
        final text  = (o['text'] as String?) ?? '';
        final votes = (o['votes'] as int?) ?? 0;
        final pct   = totalVotes == 0 ? 0.0 : votes / totalVotes;
        final voted = userVote == id;

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: GestureDetector(
            onTap: () => onVote(id),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: voted
                        ? const Color(0xFF1E3A8A)
                        : Colors.grey.shade300),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  FractionallySizedBox(
                    widthFactor: pct,
                    child: Container(
                      height: 36,
                      color: (voted
                              ? const Color(0xFF1E3A8A)
                              : Colors.grey.shade200)
                          .withValues(alpha: 0.2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                            voted
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            size: 16,
                            color: voted
                                ? const Color(0xFF1E3A8A)
                                : Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(text,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: voted
                                        ? FontWeight.w600
                                        : FontWeight.normal))),
                        Text('${(pct * 100).toStringAsFixed(0)}%',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
