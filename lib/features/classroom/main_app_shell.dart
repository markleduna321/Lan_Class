// lib/features/classroom/main_app_shell.dart

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'classroom_hub_view.dart';
import 'student_join_view.dart';
import '../auth/user_model.dart';
import '../forum/forum_workspace_view.dart';
import 'user_profile_view.dart';
import '../academy/course_timeline_view.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../main.dart';
import '../../services/cloud_api_service.dart';
import '../../database/asura_repository.dart';
import '../settings/ai_settings_view.dart';
import '../quiz/quiz_template_list_view.dart';
import '../ai/ai_assistant_view.dart';
import 'package:uuid/uuid.dart';

class MainAppShell extends StatefulWidget {
  final UserRole userRole;

  const MainAppShell({super.key, required this.userRole});

  @override
  State<MainAppShell> createState() => _MainAppShellState();
}

class _MainAppShellState extends State<MainAppShell> {
  int _currentIndex = 0;
  String _userName  = '';

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  Future<void> _loadSession() async {
    const storage = FlutterSecureStorage();
    _userName = (await storage.read(key: 'ACTIVE_USER_NAME')) ?? 'User';
    if (mounted) setState(() {});
    
    // Sync classrooms from server (for new devices after login)
    // For students: syncs enrolled classrooms
    // For teachers: syncs published classrooms they own
    _syncClassroomsFromServer();
  }

  Future<void> _syncClassroomsFromServer() async {
    try {
      // Don't block the UI — run in background
      await Future.delayed(const Duration(milliseconds: 500));
      
      debugPrint('[Classroom Sync] Starting sync for user: $_userName');
      
      // Get current user info to determine role and filter classrooms by owner
      int? currentUserId;
      String? accountRole;
      try {
        final userResponse = await CloudApiService.get('/api/user');
        if (userResponse != null && userResponse.statusCode == 200) {
          final userData = jsonDecode(userResponse.body);
          currentUserId = userData['id'] as int?;
          accountRole = userData['role'] as String?;
          debugPrint('[Classroom Sync] User ID: $currentUserId, account role: $accountRole');
        }
      } catch (e) {
        debugPrint('[Classroom Sync] Failed to get user info: $e');
      }
      
      // Get classrooms from the backend
      final classrooms = await _fetchPublishedClassrooms();
      debugPrint('[Classroom Sync] Fetched ${classrooms.length} total classrooms from server');
      
      if (classrooms.isEmpty) {
        debugPrint('[Classroom Sync] No classrooms found on server');
        return;
      }
      
      // Log all classrooms with owner info for debugging
      for (int i = 0; i < classrooms.length; i++) {
        final classroom = classrooms[i];
        final ownerId = classroom['owner_id'];
        final name = classroom['name'] ?? classroom['title'] ?? 'Unknown';
        debugPrint('[Classroom Sync] Classroom $i: "$name" - owner_id=$ownerId, visibility=${classroom['visibility']}, id=${classroom['id']}');
      }
      
      // Filter classrooms: if user is teacher, only sync their own rooms (owner_id matches)
      List<Map<String, dynamic>> myClassrooms = classrooms;
      if (accountRole == 'teacher' && currentUserId != null) {
        myClassrooms = classrooms
            .where((c) => (c['owner_id'] as int?) == currentUserId)
            .toList();
        debugPrint('[Classroom Sync] Filtered to ${myClassrooms.length} classrooms owned by teacher (user $currentUserId)');
      } else if (accountRole == 'student') {
        debugPrint('[Classroom Sync] User is student - showing available public classrooms');
      }
      
      if (myClassrooms.isEmpty) {
        debugPrint('[Classroom Sync] No classrooms match filter for role=$accountRole');
        return;
      }
      
      // Load existing saved rooms
      const storage = FlutterSecureStorage();
      final rawList = await storage.read(key: 'saved_classrooms_v2');
      final List<Map<String, dynamic>> existingRooms = [];
      if (rawList != null) {
        try {
          final decoded = jsonDecode(rawList) as List<dynamic>;
          existingRooms.addAll(
            decoded.cast<Map<String, dynamic>>()
          );
        } catch (e) {
          debugPrint('[Classroom Sync] Error parsing saved rooms: $e');
        }
      }
      debugPrint('[Classroom Sync] Found ${existingRooms.length} existing saved rooms');
      
      // For each classroom, add it if not already saved
      bool modified = false;
      for (final classroom in myClassrooms) {
        final remoteId = classroom['id']?.toString();
        final roomName = (classroom['name'] as String?) ?? 
                        (classroom['title'] as String?) ?? 
                        'Classroom';
        final schedule = (classroom['schedule'] as String?) ?? '';
        
        if (remoteId?.isNotEmpty == true) {
          final existingIndex = existingRooms.indexWhere((r) {
            if (r['remoteId'] == remoteId) return true;
            final sameName = (r['roomName']?.toString() ?? '') == roomName;
            final sameSchedule = (r['schedule']?.toString() ?? '') == schedule;
            return sameName && sameSchedule;
          });
          if (existingIndex == -1) {
            // Add this classroom to saved rooms
            final newRoom = {
              'ip': '',  // No LAN IP for published classrooms
              'classroomId': '',
              'roomName': roomName,
              'schedule': schedule,
              'addedAt': DateTime.now().toIso8601String(),
              'remoteId': remoteId,
            };
            existingRooms.add(newRoom);
            modified = true;
            debugPrint('[Classroom Sync] ✓ Added: "$roomName" (remoteId: $remoteId)');
          } else {
            final existing = Map<String, dynamic>.from(existingRooms[existingIndex]);
            final mergedRoom = {
              ...existing,
              'roomName': roomName,
              'schedule': schedule,
              'remoteId': remoteId,
            };
            if (jsonEncode(existing) != jsonEncode(mergedRoom)) {
              existingRooms[existingIndex] = mergedRoom;
              modified = true;
              debugPrint('[Classroom Sync] ↻ Updated saved room: "$roomName" (remoteId: $remoteId)');
            } else {
              debugPrint('[Classroom Sync] ⊘ Already exists: "$roomName" (remoteId: $remoteId)');
            }
          }
        }
      }
      
      // Persist if we added new rooms
      if (modified) {
        await storage.write(
          key: 'saved_classrooms_v2',
          value: jsonEncode(existingRooms),
        );
        debugPrint('[Classroom Sync] ✓ Persisted ${existingRooms.length} total rooms to secure storage');
      } else {
        debugPrint('[Classroom Sync] No new rooms to persist');
      }
      
      // Also sync to local classroom database
      await _syncPublishedClassroomsToDb(myClassrooms);
    } catch (e) {
      debugPrint('[Classroom Sync] ERROR: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchPublishedClassrooms() async {
    try {
      // First, get current user info to filter by owner
      debugPrint('[Classroom Fetch] Getting current user info');
      final userResponse = await CloudApiService.get('/api/user');
      
      if (userResponse == null || userResponse.statusCode != 200) {
        debugPrint('[Classroom Fetch] Failed to get user info. Status: ${userResponse?.statusCode}');
      } else {
        final userData = jsonDecode(userResponse.body);
        final userId = userData['id'];
        debugPrint('[Classroom Fetch] Current user ID: $userId, role: ${userData['role']}');
      }
      
      // Try endpoint for user's own classrooms first
      debugPrint('[Classroom Fetch] Attempting /api/me/classrooms');
      var response = await CloudApiService.get('/api/me/classrooms');
      
      if (response == null || response.statusCode != 200) {
        debugPrint('[Classroom Fetch] /api/me/classrooms returned ${response?.statusCode} - falling back');
        
        // Fetch public and private separately and merge — backend filters by visibility by default
        debugPrint('[Classroom Fetch] Fetching /api/classrooms (public + private separately)');
        final publicResponse  = await CloudApiService.get('/api/classrooms?visibility=public');
        final privateResponse = await CloudApiService.get('/api/classrooms?visibility=private');
        
        final List<dynamic> merged = [];
        
        if (publicResponse != null && publicResponse.statusCode == 200) {
          final decoded = jsonDecode(publicResponse.body);
          final raw = decoded is List ? decoded : (decoded['data'] as List? ?? []);
          merged.addAll(raw);
          debugPrint('[Classroom Fetch] Public classrooms: ${raw.length}');
        }
        
        if (privateResponse != null && privateResponse.statusCode == 200) {
          final decoded = jsonDecode(privateResponse.body);
          final raw = decoded is List ? decoded : (decoded['data'] as List? ?? []);
          // Deduplicate by id
          for (final item in raw) {
            final id = item['id']?.toString();
            if (id != null && !merged.any((m) => m['id']?.toString() == id)) {
              merged.add(item);
            }
          }
          debugPrint('[Classroom Fetch] Private classrooms: ${raw.length}');
        }
        
        debugPrint('[Classroom Fetch] Total merged: ${merged.length}');
        return merged.cast<Map<String, dynamic>>();
      }
      
      // /api/me/classrooms succeeded — parse it
      debugPrint('[Classroom Fetch] Response received. Body length: ${response.body.length}');
      final decoded = jsonDecode(response.body);
      final List<dynamic> raw = decoded is List 
          ? decoded 
          : (decoded['data'] as List? ?? []);
      final result = raw.cast<Map<String, dynamic>>();
      debugPrint('[Classroom Fetch] Successfully parsed ${result.length} classrooms');
      return result;
    } catch (e) {
      debugPrint('[Classroom Fetch] Exception: $e');
      return [];
    }
  }

  /// Sync published classrooms to local database for teachers.
  /// This ensures teacher's published rooms appear on new devices.
  Future<void> _syncPublishedClassroomsToDb(
    List<Map<String, dynamic>> classrooms,
  ) async {
    try {
      debugPrint('[DB Sync] Syncing ${classrooms.length} classrooms to local database');
      
      int addedCount = 0;
      int updatedCount = 0;
      
      for (final classroom in classrooms) {
        final remoteId = classroom['id']?.toString();
        if (remoteId?.isNotEmpty != true) continue;
        final roomName = (classroom['name'] as String?) ?? 
                        (classroom['title'] as String?) ?? 
                        'Classroom';
        final schedule = (classroom['schedule'] as String?) ?? '';
        final visibility = (classroom['visibility'] as String?) ?? 'public';
        final studentCount = _asInt(classroom['student_count']);

        final found = await AsuraRepository.findClassroomForSync(
          remoteId: remoteId!,
          name: roomName,
          schedule: schedule,
        );

        String localClassroomId;
        if (found == null || (found['id']?.toString().isEmpty ?? true)) {
          localClassroomId = const Uuid().v4();
          try {
            await AsuraRepository.insertClassroom({
              'id': localClassroomId,
              'name': roomName,
              'schedule': schedule,
              'student_count': studentCount,
              'remote_id': remoteId,
              'is_published': 1,
              'visibility': visibility,
            });
            addedCount++;
            debugPrint('[DB Sync] ✓ Created: $roomName (remoteId: $remoteId)');
          } catch (insertError) {
            debugPrint('[DB Sync] ✗ Failed to insert $roomName: $insertError');
            continue;
          }
        } else {
          localClassroomId = found['id']!.toString();
          await AsuraRepository.updateClassroomSyncState(
            localClassroomId,
            name: roomName,
            schedule: schedule,
            studentCount: studentCount,
            remoteId: remoteId,
            isPublished: 1,
            visibility: visibility,
          );
          updatedCount++;
          debugPrint('[DB Sync] ↻ Updated: $roomName (remoteId: $remoteId)');
        }

        await _syncRemoteMaterialsToDb(
          classroomLocalId: localClassroomId,
          classroomRemoteId: remoteId,
        );
      }
      
      debugPrint('[DB Sync] Complete: $addedCount added, $updatedCount updated');
    } catch (e) {
      debugPrint('[DB Sync] ERROR: $e');
    }
  }

  Future<void> _syncRemoteMaterialsToDb({
    required String classroomLocalId,
    required String classroomRemoteId,
  }) async {
    try {
      final response = await CloudApiService.get(
        '/api/classrooms/$classroomRemoteId/materials',
      );
      if (response == null || response.statusCode != 200) {
        debugPrint('[Material Sync] Skipped for remote classroom $classroomRemoteId: status ${response?.statusCode}');
        return;
      }

      final decoded = jsonDecode(response.body);
      final List<dynamic> raw = decoded is List
          ? decoded
          : (decoded['data'] as List? ?? []);
      if (raw.isEmpty) {
        debugPrint('[Material Sync] No remote materials for classroom $classroomRemoteId');
        return;
      }

      final docsDir = await getApplicationDocumentsDirectory();
      final materialsDir = Directory(
        p.join(docsDir.path, 'classroom_materials', classroomLocalId),
      );
      await materialsDir.create(recursive: true);

      final baseUrl = await CloudApiService.getBaseUrl();
      int syncedCount = 0;

      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;

        final remoteMaterialId = item['id']?.toString();
        final remoteUrl = item['file_url']?.toString() ?? item['url']?.toString() ?? '';
        if (remoteMaterialId == null || remoteMaterialId.isEmpty || remoteUrl.isEmpty) {
          continue;
        }

        final originalName = item['original_name']?.toString() ?? 'Material';
        final mimeType = item['mime_type']?.toString() ?? 'application/octet-stream';
        final sizeBytes = _asInt(item['size_bytes']);
        final createdAt = item['created_at']?.toString() ?? DateTime.now().toIso8601String();
        final existing = await AsuraRepository.getMaterialByRemoteId(
          classroomLocalId,
          remoteMaterialId,
        );

        final extension = p.extension(originalName).isNotEmpty
            ? p.extension(originalName)
            : p.extension(remoteUrl);
        final localFilename = existing?['filename']?.toString().isNotEmpty == true
            ? existing!['filename'].toString()
            : '$remoteMaterialId$extension';
        final localPath = p.join(materialsDir.path, localFilename);

        final downloaded = await _downloadRemoteMaterial(
          remoteUrl: remoteUrl,
          resolvedBaseUrl: baseUrl,
          destinationPath: localPath,
        );
        if (!downloaded) {
          debugPrint('[Material Sync] Failed to download $originalName');
          continue;
        }

        if (existing == null) {
          await AsuraRepository.insertMaterial({
            'id': const Uuid().v4(),
            'classroom_id': classroomLocalId,
            'original_name': originalName,
            'filename': localFilename,
            'mime_type': mimeType,
            'file_path': localPath,
            'size_bytes': sizeBytes,
            'created_at': createdAt,
            'remote_id': remoteMaterialId,
            'remote_url': remoteUrl,
          });
        } else {
          await AsuraRepository.updateMaterialSnapshot(
            existing['id'].toString(),
            originalName: originalName,
            filename: localFilename,
            mimeType: mimeType,
            filePath: localPath,
            sizeBytes: sizeBytes,
            createdAt: createdAt,
            remoteId: remoteMaterialId,
            remoteUrl: remoteUrl,
          );
        }
        syncedCount++;
      }

      debugPrint('[Material Sync] Synced $syncedCount materials for classroom $classroomRemoteId');
    } catch (e) {
      debugPrint('[Material Sync] ERROR for classroom $classroomRemoteId: $e');
    }
  }

  Future<bool> _downloadRemoteMaterial({
    required String remoteUrl,
    required String resolvedBaseUrl,
    required String destinationPath,
  }) async {
    try {
      final uri = Uri.parse(
        remoteUrl.startsWith('http') ? remoteUrl : '$resolvedBaseUrl$remoteUrl',
      );
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        return false;
      }
      await File(destinationPath).writeAsBytes(response.bodyBytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }



  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('You will be returned to the login screen.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await const FlutterSecureStorage().deleteAll();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const SessionInterceptorGate()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTeacher = widget.userRole == UserRole.presenter;

    final List<Widget> views = [
      isTeacher ? const ClassroomHubView() : const StudentJoinView(),
      const CourseTimelineView(),
      const AiAssistantView(),
      const ForumWorkspaceView(),
      UserProfileView(isTeacher: isTeacher),
    ];

    final List<String> titles = [
      isTeacher ? 'Classroom Hub' : 'Join a Room',
      'Course Academy',
      'AI Helper',
      'Community',
      'My Profile',
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor:
            Theme.of(context).navigationBarTheme.backgroundColor ??
                Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(titles[_currentIndex]),
              if (_userName.isNotEmpty && _currentIndex == 0)
                Text(
                  isTeacher ? 'Instructor · $_userName' : 'Student · $_userName',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: Colors.white60,
                  ),
                ),
            ],
          ),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onSelected: (value) async {
                switch (value) {
                  case 'quiz':
                    Navigator.push(context,
                        MaterialPageRoute(
                            builder: (_) => const QuizTemplateListView()));
                  case 'ai':
                    Navigator.push(context,
                        MaterialPageRoute(
                            builder: (_) => AiSettingsView(isTeacher: isTeacher)));
                  case 'signout':
                    await _signOut();
                }
              },
              itemBuilder: (_) => [
                if (isTeacher)
                  const PopupMenuItem(
                    value: 'quiz',
                    child: ListTile(
                      leading: Icon(Icons.quiz_outlined),
                      title: Text('Quiz Library'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                const PopupMenuItem(
                  value: 'ai',
                  child: ListTile(
                    leading: Icon(Icons.auto_awesome_outlined),
                    title: Text('AI Settings'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'signout',
                  child: ListTile(
                    leading: Icon(Icons.logout, color: Colors.red),
                    title: Text('Sign Out',
                        style: TextStyle(color: Colors.red)),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        body: IndexedStack(
          index: _currentIndex,
          children: views,
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          labelBehavior:
              NavigationDestinationLabelBehavior.onlyShowSelected,
          destinations: [
            NavigationDestination(
              icon: Icon(isTeacher
                  ? Icons.school_outlined
                  : Icons.meeting_room_outlined),
              selectedIcon:
                  Icon(isTeacher ? Icons.school : Icons.meeting_room),
              label: isTeacher ? 'Classroom' : 'Join',
            ),
            const NavigationDestination(
              icon: Icon(Icons.collections_bookmark_outlined),
              selectedIcon: Icon(Icons.collections_bookmark),
              label: 'Academy',
            ),
            const NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined),
              selectedIcon: Icon(Icons.auto_awesome),
              label: 'AI Helper',
            ),
            const NavigationDestination(
              icon: Icon(Icons.forum_outlined),
              selectedIcon: Icon(Icons.forum),
              label: 'Community',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}