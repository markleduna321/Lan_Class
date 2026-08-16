// lib/features/classroom/user_profile_view.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../services/cloud_api_service.dart';
import '../../database/asura_repository.dart';
import '../auth/role_utils.dart';
import '../shared/aura.dart';

class UserProfileView extends StatefulWidget {
  final bool isTeacher;

  const UserProfileView({super.key, required this.isTeacher});

  @override
  State<UserProfileView> createState() => _UserProfileViewState();
}
class _UserProfileViewState extends State<UserProfileView> {
  bool get isTeacher => widget.isTeacher;

  // Local profile state
  Map<String, dynamic>? _user;
  bool _profileLoading = true;
  int _auraScore = 0;
  List<String> _skills = [];
  List<Map<String, dynamic>> _projects = [];
  int _classroomCount = 0;

  // Online account state
  bool _isLinked = false;
  String? _onlineUserId;
  String? _onlineName;
  bool _cloudLoading = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadCloudStatus();
  }

  // ---------------------------------------------------------------------------
  // PROFILE DATA
  // ---------------------------------------------------------------------------

  Future<void> _loadProfile() async {
    final user       = await AsuraRepository.getActiveUser();
    final classrooms = await AsuraRepository.getAllClassrooms();
    var effectiveUser = user == null ? null : Map<String, dynamic>.from(user);

    if (!mounted) return;
    setState(() {
      _user           = effectiveUser;
      _skills         = _parseSkills(effectiveUser?['skills']);
      _projects       = _parseProjects(effectiveUser?['projects']);
      _auraScore      = (effectiveUser?['aura_score'] as int?) ?? 0;
      _classroomCount = classrooms.length;
      _profileLoading = false;
    });

    // Aura: prefer the online reputation score from the updated profile API.
    int aura = (user?['aura_score'] as int?) ?? 0;
    final profile = await CloudApiService.getCurrentProfile();
    if (profile != null) {
      final profileReputation = extractReputationFromApiPayload(profile);
      if (profileReputation != null) {
        aura = profileReputation;
      }

      final profileRole = extractRoleFromApiPayload(profile);
      if (user?['id'] != null) {
        final updatedUser = Map<String, dynamic>.from(user ?? {});
        updatedUser['id'] = user!['id'];
        updatedUser['name'] = (profile['name'] as String?) ?? updatedUser['name'];
        updatedUser['nickname'] = (profile['nickname'] as String?) ?? updatedUser['nickname'];
        updatedUser['bio'] = (profile['bio'] as String?) ?? updatedUser['bio'];
        if (profile['skills'] is List) {
          updatedUser['skills'] = jsonEncode(profile['skills']);
        }
        if (profile['projects'] is List) {
          updatedUser['projects'] = jsonEncode(profile['projects']);
        }
        updatedUser['role'] = profileRole ?? updatedUser['role'] ?? 'audience';
        updatedUser['aura_score'] = aura;
        await AsuraRepository.upsertUser(updatedUser);
        effectiveUser = updatedUser;
      }
    }

    if (profile != null && mounted) {
      setState(() {
        _user = effectiveUser;
        _skills = _parseSkills(effectiveUser?['skills']);
        _projects = _parseProjects(effectiveUser?['projects']);
        _auraScore = aura;
      });
    }
  }

  List<String> _parseSkills(dynamic raw) {
    if (raw is! String || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  List<Map<String, dynamic>> _parseProjects(dynamic raw) {
    if (raw is! String || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  String get _displayName =>
      _user == null ? 'User' : resolveDisplayName(_user!, fallback: 'User');

  String get _fullName {
    final first = (_user?['first_name'] as String?) ?? '';
    final middle = (_user?['middle_name'] as String?) ?? '';
    final last = (_user?['last_name'] as String?) ?? '';
    final full = [first, middle, last].where((s) => s.isNotEmpty).join(' ');
    return full.isNotEmpty ? full : 'User';
  }

  String get _roleLabel {
    final profession = (_user?['profession'] as String?)?.trim();
    if (profession != null && profession.isNotEmpty) return profession;
    return isTeacher ? 'Instructor' : 'Student';
  }

  String get _initials {
    final name = _displayName.trim();
    if (name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }


  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadCloudStatus() async {
    final linked     = await CloudApiService.isLinked;
    final userId     = await CloudApiService.getOnlineUserId();
    final name       = await CloudApiService.getOnlineName();
    if (!mounted) return;
    setState(() {
      _isLinked     = linked;
      _onlineUserId = userId;
      _onlineName   = name;
      _cloudLoading = false;
    });
  }

  Future<void> _unlinkOnline() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink Online Account'),
        content: const Text('This removes the stored token. Your local data is not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unlink', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await CloudApiService.logout();
    if (!mounted) return;
    setState(() {
      _isLinked     = false;
      _onlineUserId = null;
      _onlineName   = null;
    });
  }

  Future<void> _linkOnline() async {
    // Read credentials that were saved at login/signup — no dialog needed.
    const storage = FlutterSecureStorage();
    final email    = await storage.read(key: 'ACTIVE_USER_EMAIL');
    final password = await storage.read(key: 'ACTIVE_USER_PASSWORD');

    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Credentials not found. Please log out and sign in again to enable sync.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _syncing = true);

    final verbose = await CloudApiService.loginWithError(email, password);
    if (!mounted) return;

    if (verbose.result != null) {
      final result = verbose.result!;
      final localUuid = await storage.read(key: 'ACTIVE_USER_UUID');
      if (localUuid != null) {
        await AsuraRepository.updateUserRemoteId(
          localUuid,
          result.user['id'].toString(),
        );
      }
      if (!mounted) return;
      setState(() {
        _isLinked     = true;
        _onlineUserId = result.user['id'].toString();
        _onlineName   = result.user['name'] as String?;
        _syncing      = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Account synced successfully.'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      setState(() => _syncing = false);

      // "credentials do not match" means no online account — offer to register.
      // "already been taken" / "already exists" means account exists but wrong password.
      final errLower = verbose.error.toLowerCase();
      final noAccount = (errLower.contains('credentials') ||
              errLower.contains('match') ||
              errLower.contains('not found') ||
              errLower.contains('invalid')) &&
          !errLower.contains('taken') &&
          !errLower.contains('already');

      if (noAccount && mounted) {
        final wantRegister = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('No Online Account Found'),
            content: Text(
              'The server says: "${verbose.error}"\n\n'
              'You may not have an online account yet. '
              'Register now using your current credentials?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Register'),
              ),
            ],
          ),
        );
        if (wantRegister == true) {
          await _registerOnline(email, password);
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(verbose.error.isNotEmpty
                ? verbose.error
                : 'Sync failed. Check your connection.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _registerOnline(String email, String password) async {
    const storage = FlutterSecureStorage();
    final name = await storage.read(key: 'ACTIVE_USER_NAME') ?? email;
    final role = await storage.read(key: 'ACTIVE_USER_ROLE') ?? 'audience';

    setState(() => _syncing = true);

    // Attempt registration (best-effort — the server may create the account
    // but return a response that can't be parsed cleanly).
    await CloudApiService.register({
      'name': name,
      'email': email,
      'password': password,
      'password_confirmation': password,
      'role': role,
    });

    if (!mounted) return;

    // Whether or not register() succeeded, try to login immediately.
    // If the account was just created the login will confirm it and persist
    // the token. If the account already existed this also succeeds.
    final verbose = await CloudApiService.loginWithError(email, password);
    if (!mounted) return;

    if (verbose.result != null) {
      final result = verbose.result!;
      final localUuid = await storage.read(key: 'ACTIVE_USER_UUID');
      if (localUuid != null) {
        await AsuraRepository.updateUserRemoteId(
          localUuid,
          result.user['id'].toString(),
        );
      }
      if (!mounted) return;
      setState(() {
        _isLinked     = true;
        _onlineUserId = result.user['id'].toString();
        _onlineName   = result.user['name'] as String?;
        _syncing      = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Online account created and synced.'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      setState(() => _syncing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            verbose.error.isNotEmpty
                ? 'Could not sync: ${verbose.error}'
                : 'Registration and login both failed. Try again later.',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // PROFILE EDITORS
  // ---------------------------------------------------------------------------

  Future<void> _saveField({
    String? nickname,
    String? bio,
    String? skills,
    String? projects,
  }) async {
    final id = _user?['id'] as String?;
    if (id == null) return;
    await AsuraRepository.updateUserProfile(
      id,
      nickname: nickname,
      bio: bio,
      skills: skills,
      projects: projects,
    );

    final payload = <String, dynamic>{
      'nickname': ?nickname,
      'bio': ?bio,
      'skills': ?(skills != null ? _decodeJsonArray(skills) : null),
      'projects': ?(projects != null ? _decodeJsonArray(projects) : null),
    };
    if (payload.isEmpty) return;

    final linked = await CloudApiService.isLinked;
    if (!linked) return;

    final response = await CloudApiService.patch('/api/user/profile', payload);
    if (response == null) {
      _showProfileSyncMessage('Profile saved locally. Online sync failed.', isError: true);
      return;
    }

    if (response.statusCode == 200) {
      try {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final updatedUser = Map<String, dynamic>.from(_user ?? const {});
        updatedUser['id'] = id;
        updatedUser['name'] = (decoded['name'] as String?) ?? updatedUser['name'];
        updatedUser['nickname'] = (decoded['nickname'] as String?) ?? updatedUser['nickname'];
        updatedUser['bio'] = (decoded['bio'] as String?) ?? updatedUser['bio'];
        if (decoded['skills'] is List) {
          updatedUser['skills'] = jsonEncode(decoded['skills']);
        }
        if (decoded['projects'] is List) {
          updatedUser['projects'] = jsonEncode(decoded['projects']);
        }
        updatedUser['aura_score'] =
            extractReputationFromApiPayload(decoded) ?? updatedUser['aura_score'];
        updatedUser['role'] = extractRoleFromApiPayload(decoded) ?? updatedUser['role'];
        await AsuraRepository.upsertUser(updatedUser);
        if (mounted) {
          setState(() {
            _user = updatedUser;
            _skills = _parseSkills(updatedUser['skills']);
            _projects = _parseProjects(updatedUser['projects']);
          });
        }
      } catch (_) {
        // Keep local save even if the response body is unexpected.
      }
      return;
    }

    _showProfileSyncMessage(
      'Profile saved locally. Online update failed (${response.statusCode}).',
      isError: true,
    );
  }

  dynamic _decodeJsonArray(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  void _showProfileSyncMessage(String message, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.orange : Colors.green,
      ),
    );
  }

  Future<void> _editNickname() async {
    final controller =
        TextEditingController(text: (_user?['nickname'] as String?) ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Nickname'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: 'Shown in the community',
            counterText: '',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await _saveField(nickname: result);
    if (!mounted) return;
    setState(() => _user?['nickname'] = result);
  }

  Future<void> _editBio() async {
    final controller =
        TextEditingController(text: (_user?['bio'] as String?) ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Bio'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          maxLength: 280,
          decoration: const InputDecoration(
            hintText: 'Tell the community about yourself…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await _saveField(bio: result);
    if (!mounted) return;
    setState(() => _user?['bio'] = result);
  }

  Future<void> _addSkill() async {
    final controller = TextEditingController();
    final skill = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Skill'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: 'e.g. Flutter, Networking, Python',
            counterText: '',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    controller.dispose();
    if (skill == null || skill.isEmpty || _skills.contains(skill)) return;
    setState(() => _skills.add(skill));
    await _saveField(skills: jsonEncode(_skills));
  }

  Future<void> _removeSkill(String skill) async {
    setState(() => _skills.remove(skill));
    await _saveField(skills: jsonEncode(_skills));
  }

  Future<void> _addOrEditProject([int? index]) async {
    final existing = index != null ? _projects[index] : null;
    final titleCtrl =
        TextEditingController(text: (existing?['title'] as String?) ?? '');
    final descCtrl = TextEditingController(
        text: (existing?['description'] as String?) ?? '');
    final linkCtrl =
        TextEditingController(text: (existing?['link'] as String?) ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(index == null ? 'Add Project' : 'Edit Project'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                maxLength: 60,
                decoration: const InputDecoration(
                    labelText: 'Title', counterText: '',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descCtrl,
                maxLines: 3,
                maxLength: 200,
                decoration: const InputDecoration(
                    labelText: 'Description', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: linkCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'Link (optional)',
                    hintText: 'https://…',
                    border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          if (index != null)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx, false);
                setState(() => _projects.removeAt(index));
                await _saveField(projects: jsonEncode(_projects));
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    final title = titleCtrl.text.trim();
    final desc = descCtrl.text.trim();
    final link = linkCtrl.text.trim();
    titleCtrl.dispose();
    descCtrl.dispose();
    linkCtrl.dispose();

    if (saved != true || title.isEmpty) return;
    final project = {
      'title': title,
      'description': desc,
      if (link.isNotEmpty) 'link': link,
    };
    setState(() {
      if (index == null) {
        _projects.add(project);
      } else {
        _projects[index] = project;
      }
    });
    await _saveField(projects: jsonEncode(_projects));
  }

  @override
  Widget build(BuildContext context) {
    if (_profileLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. HERO IDENTITY CARD
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
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
                  // Display name (nickname → full name) with aura effect
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: AuraName(
                          name: _displayName,
                          score: _auraScore,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          maxLines: 1,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.edit_outlined,
                            size: 18, color: Colors.grey.shade500),
                        tooltip: 'Edit nickname',
                        onPressed: _editNickname,
                      ),
                    ],
                  ),
                  // Show full name underneath when a nickname is set
                  if ((_user?['nickname'] as String?)?.trim().isNotEmpty ?? false)
                    Text(
                      _fullName,
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    _roleLabel,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: auraTierFor(_auraScore).color.withValues(alpha: 0.08),
                      border: Border.all(
                          color: auraTierFor(_auraScore).color.withValues(alpha: 0.4)),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AuraFlameBadge(score: _auraScore, size: 20),
                        const SizedBox(width: 6),
                        Text(
                          '$_auraScore Aura',
                          style: TextStyle(
                              color: auraTierFor(_auraScore).color,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '· ${auraTierFor(_auraScore).label}',
                          style: TextStyle(
                              color: auraTierFor(_auraScore).color.withValues(alpha: 0.7),
                              fontSize: 12,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 1b. BIO / ABOUT
          _buildAboutCard(),
          const SizedBox(height: 20),

          // 1c. SKILLS
          _buildSkillsCard(),
          const SizedBox(height: 20),

          // 1d. PROJECTS
          _buildProjectsCard(),
          const SizedBox(height: 20),

          // 2. ACADEMIC METRICS GRID
          const Text('Overview', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.5,
            children: [
              _buildMetricCard(
                isTeacher ? 'Classes Hosted' : 'Classrooms',
                '$_classroomCount',
                Icons.school,
                Colors.blue,
              ),
              _buildMetricCard(
                'Aura Tier',
                auraTierFor(_auraScore).label,
                Icons.local_fire_department,
                auraTierFor(_auraScore).color,
              ),
              _buildMetricCard(
                'Skills',
                '${_skills.length}',
                Icons.workspace_premium,
                Colors.green,
              ),
              _buildMetricCard(
                'Projects',
                '${_projects.length}',
                Icons.rocket_launch,
                Colors.purple,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 3. GAMIFIED ACHIEVEMENT BADGES GALLERY
          const Text('Unlocked Achievements', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 10),
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  _buildBadgeRow(
                    'Local Sync Master',
                    'Successfully hosted/joined your first live Edge-LAN session.',
                    Icons.lan,
                    Colors.green,
                    isUnlocked: true,
                  ),
                  const Divider(height: 24),
                  _buildBadgeRow(
                    'Aura Contributor',
                    'Reach 100+ Aura in the community (Advanced tier).',
                    Icons.workspace_premium,
                    Colors.amber,
                    isUnlocked: _auraScore >= 100,
                  ),
                  const Divider(height: 24),
                  _buildBadgeRow(
                    'Community Legend',
                    'Reach 1000+ Aura in the community (High tier).',
                    Icons.local_fire_department,
                    const Color(0xFF9333EA),
                    isUnlocked: _auraScore >= 1000,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),

          // 4. CLOUD ACCOUNT SECTION
          const Text('Cloud Account', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 10),
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: _cloudLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Status row
                        Row(
                          children: [
                            Icon(
                              _isLinked ? Icons.cloud_done : Icons.cloud_off,
                              color: _isLinked ? Colors.green : Colors.grey,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _isLinked ? 'Linked' : 'Not linked',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: _isLinked ? Colors.green : Colors.grey.shade700,
                                    ),
                                  ),
                                  if (_isLinked && _onlineName != null)
                                    Text(
                                      '$_onlineName  •  ID: $_onlineUserId',
                                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                ],
                              ),
                            ),
                            if (_isLinked)
                              TextButton(
                                onPressed: _unlinkOnline,
                                child: const Text('Unlink', style: TextStyle(color: Colors.red)),
                              )
                            else if (_syncing)
                              const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              ElevatedButton.icon(
                                onPressed: _linkOnline,
                                icon: const Icon(Icons.sync, size: 18),
                                label: const Text('Sync'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1E3A8A),
                                  foregroundColor: Colors.white,
                                ),
                              ),
                          ],
                        ),
                        const Divider(height: 24),
                        // Fixed server info
                        Row(
                          children: [
                            Icon(Icons.dns_outlined,
                                size: 16, color: Colors.grey.shade500),
                            const SizedBox(width: 6),
                            Text(
                              CloudApiService.serverBaseUrl,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(title, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ABOUT / BIO
  // ---------------------------------------------------------------------------

  Widget _buildAboutCard() {
    final bio = (_user?['bio'] as String?)?.trim() ?? '';
    return _sectionCard(
      title: 'About',
      onEdit: _editBio,
      child: bio.isEmpty
          ? Text('Add a short bio to introduce yourself.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13))
          : Text(bio,
              style: const TextStyle(fontSize: 13, height: 1.5)),
    );
  }

  // ---------------------------------------------------------------------------
  // SKILLS
  // ---------------------------------------------------------------------------

  Widget _buildSkillsCard() {
    return _sectionCard(
      title: 'Skills',
      onEdit: _addSkill,
      editIcon: Icons.add,
      child: _skills.isEmpty
          ? Text('Add skills to showcase your expertise.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13))
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _skills.map((s) {
                return Chip(
                  label: Text(s, style: const TextStyle(fontSize: 12)),
                  backgroundColor: const Color(0xFF1E3A8A).withValues(alpha: 0.08),
                  side: BorderSide(
                      color: const Color(0xFF1E3A8A).withValues(alpha: 0.2)),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: () => _removeSkill(s),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }).toList(),
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // PROJECTS
  // ---------------------------------------------------------------------------

  Widget _buildProjectsCard() {
    return _sectionCard(
      title: 'Projects',
      onEdit: () => _addOrEditProject(),
      editIcon: Icons.add,
      child: _projects.isEmpty
          ? Text('Showcase projects you have worked on.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13))
          : Column(
              children: List.generate(_projects.length, (i) {
                final p = _projects[i];
                final title = (p['title'] as String?) ?? 'Untitled';
                final desc = (p['description'] as String?) ?? '';
                final link = (p['link'] as String?) ?? '';
                return Padding(
                  padding: EdgeInsets.only(bottom: i == _projects.length - 1 ? 0 : 12),
                  child: InkWell(
                    onTap: () => _addOrEditProject(i),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.rocket_launch,
                                  size: 16, color: Color(0xFF1E3A8A)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(title,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14)),
                              ),
                              Icon(Icons.edit_outlined,
                                  size: 14, color: Colors.grey.shade400),
                            ],
                          ),
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
                            Row(
                              children: [
                                Icon(Icons.link,
                                    size: 13, color: Colors.blue.shade400),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(link,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.blue.shade600),
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
    );
  }

  /// Shared card wrapper with a title row + edit/add action.
  Widget _sectionCard({
    required String title,
    required Widget child,
    required VoidCallback onEdit,
    IconData editIcon = Icons.edit_outlined,
  }) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(editIcon, size: 18, color: Colors.grey.shade500),
                  onPressed: onEdit,
                ),
              ],
            ),
            const SizedBox(height: 4),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildBadgeRow(String title, String desc, IconData icon, Color color, {required bool isUnlocked}) {
    return Row(
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: isUnlocked ? color.withValues(alpha: 0.1) : Colors.grey.shade100,
          child: Icon(icon, color: isUnlocked ? color : Colors.grey.shade400, size: 28),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: isUnlocked ? Colors.black87 : Colors.grey,
                ),
              ),
              const SizedBox(height: 2),
              Text(desc, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.3)),
            ],
          ),
        ),
      ],
    );
  }
}