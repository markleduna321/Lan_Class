// lib/features/forum/public_profile_view.dart
//
// Read-only public profile of another community member.
// Fetches GET /api/users/{id}/profile and gracefully falls back to the
// name/aura already known from the post when the endpoint is unavailable.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/cloud_api_service.dart';
import '../shared/aura.dart';

class PublicProfileView extends StatefulWidget {
  final String userId;
  final String fallbackName;
  final int fallbackAura;

  const PublicProfileView({
    super.key,
    required this.userId,
    required this.fallbackName,
    this.fallbackAura = 0,
  });

  @override
  State<PublicProfileView> createState() => _PublicProfileViewState();
}

class _PublicProfileViewState extends State<PublicProfileView> {
  bool _loading = true;
  bool _detailsUnavailable = false;
  Map<String, dynamic>? _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await CloudApiService.get('/api/users/${widget.userId}/profile');
    if (!mounted) return;
    if (r != null && r.statusCode == 200) {
      try {
        final decoded = jsonDecode(r.body) as Map<String, dynamic>;
        _profile = (decoded['user'] as Map<String, dynamic>?)
            ?? (decoded['data'] as Map<String, dynamic>?)
            ?? decoded;
      } catch (_) {
        _detailsUnavailable = true;
      }
    } else {
      _detailsUnavailable = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ── Data accessors with fallbacks ─────────────────────────────────────────

  String get _displayName {
    final p = _profile;
    if (p != null) return resolveDisplayName(p, fallback: widget.fallbackName);
    return widget.fallbackName;
  }

  String? get _fullName {
    final p = _profile;
    if (p == null) return null;
    final nick = (p['nickname'] as String?)?.trim();
    final name = (p['name'] as String?)?.trim();
    if (nick != null && nick.isNotEmpty && name != null && name.isNotEmpty) {
      return name; // show full name under the nickname
    }
    return null;
  }

  int get _aura {
    final p = _profile;
    if (p != null) {
      return (p['aura'] as int?) ?? (p['aura_score'] as int?) ?? widget.fallbackAura;
    }
    return widget.fallbackAura;
  }

  String get _role {
    final role = (_profile?['role'] as String?)?.trim();
    if (role == null || role.isEmpty) return 'Member';
    return role[0].toUpperCase() + role.substring(1);
  }

  String get _initials {
    final name = _displayName.trim();
    if (name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  List<String> get _skills {
    final raw = _profile?['skills'];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    if (raw is String && raw.isNotEmpty) {
      try {
        return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      } catch (_) {}
    }
    return [];
  }

  List<Map<String, dynamic>> get _projects {
    final raw = _profile?['projects'];
    if (raw is List) return raw.cast<Map<String, dynamic>>();
    if (raw is String && raw.isNotEmpty) {
      try {
        return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return [];
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tier = auraTierFor(_aura);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hero
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 40,
                            backgroundColor: const Color(0xFF1E3A8A),
                            child: Text(
                              _initials,
                              style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 12),
                          AuraName(
                            name: _displayName,
                            score: _aura,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            maxLines: 1,
                          ),
                          if (_fullName != null)
                            Text(_fullName!,
                                style: TextStyle(
                                    color: Colors.grey.shade500,
                                    fontSize: 12)),
                          const SizedBox(height: 4),
                          Text(_role,
                              style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: tier.color.withValues(alpha: 0.08),
                              border: Border.all(
                                  color: tier.color.withValues(alpha: 0.4)),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AuraFlameBadge(score: _aura, size: 20),
                                const SizedBox(width: 6),
                                Text('$_aura Aura',
                                    style: TextStyle(
                                        color: tier.color,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(width: 6),
                                Text('· ${tier.label}',
                                    style: TextStyle(
                                        color:
                                            tier.color.withValues(alpha: 0.7),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (_detailsUnavailable)
                    _infoBanner(
                        'Full profile details are not available for this user yet.')
                  else ...[
                    // Bio
                    if (((_profile?['bio'] as String?)?.trim().isNotEmpty ??
                        false)) ...[
                      _sectionTitle('About'),
                      _sectionCard(Text(
                        (_profile!['bio'] as String).trim(),
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      )),
                      const SizedBox(height: 16),
                    ],
                    // Skills
                    if (_skills.isNotEmpty) ...[
                      _sectionTitle('Skills'),
                      _sectionCard(Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _skills
                            .map((s) => Chip(
                                  label: Text(s,
                                      style: const TextStyle(fontSize: 12)),
                                  backgroundColor: const Color(0xFF1E3A8A)
                                      .withValues(alpha: 0.08),
                                  side: BorderSide(
                                      color: const Color(0xFF1E3A8A)
                                          .withValues(alpha: 0.2)),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ))
                            .toList(),
                      )),
                      const SizedBox(height: 16),
                    ],
                    // Projects
                    if (_projects.isNotEmpty) ...[
                      _sectionTitle('Projects'),
                      _sectionCard(Column(
                        children: List.generate(_projects.length, (i) {
                          final p = _projects[i];
                          final title = (p['title'] as String?) ?? 'Untitled';
                          final desc = (p['description'] as String?) ?? '';
                          final link = (p['link'] as String?) ?? '';
                          return Padding(
                            padding: EdgeInsets.only(
                                bottom: i == _projects.length - 1 ? 0 : 12),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(10),
                                border:
                                    Border.all(color: Colors.grey.shade200),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    const Icon(Icons.rocket_launch,
                                        size: 16, color: Color(0xFF1E3A8A)),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: Text(title,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 14))),
                                  ]),
                                  if (desc.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(desc,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade700,
                                            height: 1.4)),
                                  ],
                                  if (link.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    GestureDetector(
                                      onTap: () {
                                        Clipboard.setData(
                                            ClipboardData(text: link));
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(const SnackBar(
                                                content:
                                                    Text('Link copied.'),
                                                duration:
                                                    Duration(seconds: 2)));
                                      },
                                      child: Row(children: [
                                        Icon(Icons.link,
                                            size: 13,
                                            color: Colors.blue.shade400),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(link,
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.blue.shade600),
                                              overflow:
                                                  TextOverflow.ellipsis),
                                        ),
                                      ]),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        }),
                      )),
                    ],
                    if (((_profile?['bio'] as String?)?.trim().isEmpty ?? true) &&
                        _skills.isEmpty &&
                        _projects.isEmpty)
                      _infoBanner(
                          'This user has not added a bio, skills, or projects yet.'),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(t,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold)),
      );

  Widget _sectionCard(Widget child) => Card(
        elevation: 1,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );

  Widget _infoBanner(String text) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(children: [
          Icon(Icons.info_outline, size: 18, color: Colors.grey.shade400),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style:
                      TextStyle(fontSize: 13, color: Colors.grey.shade600))),
        ]),
      );
}
