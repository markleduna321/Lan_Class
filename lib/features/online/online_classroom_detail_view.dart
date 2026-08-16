// lib/features/online/online_classroom_detail_view.dart
//
// Phase 3 — Online Classroom Detail + Materials Viewer
// Shows classroom info, materials list, and active-session status.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:http/http.dart' as http;
import '../../services/cloud_api_service.dart';
import 'online_session_lobby_view.dart';
import 'room_join_utils.dart';

class OnlineClassroomDetailView extends StatefulWidget {
  final String remoteId;
  final String name;
  final String schedule;
  final String? teacherName;
  final bool isSaved;
  final VoidCallback onSave;

  const OnlineClassroomDetailView({
    super.key,
    required this.remoteId,
    required this.name,
    required this.schedule,
    required this.isSaved,
    required this.onSave,
    this.teacherName,
  });

  @override
  State<OnlineClassroomDetailView> createState() =>
      _OnlineClassroomDetailViewState();
}

class _OnlineClassroomDetailViewState
    extends State<OnlineClassroomDetailView> {
  bool _materialsLoading = true;
  bool _sessionLoading = true;
  bool _isSaved = false;
  List<Map<String, dynamic>> _materials = [];
  Map<String, dynamic>? _activeSession;
  String? _materialsError;

  // Tracks which material IDs are being downloaded
  final Set<String> _downloadingIds = {};

  @override
  void initState() {
    super.initState();
    _isSaved = widget.isSaved;
    _loadMaterials();
    _checkActiveSession();
  }

  Future<void> _loadMaterials() async {
    setState(() {
      _materialsLoading = true;
      _materialsError = null;
    });

    final response =
        await CloudApiService.get('/api/classrooms/${widget.remoteId}/materials');
    if (!mounted) return;

    if (response == null) {
      setState(() {
        _materialsError = 'Could not load materials. Check your connection.';
        _materialsLoading = false;
      });
      return;
    }

    if (response.statusCode == 200) {
      try {
        final decoded = jsonDecode(response.body);
        final List<dynamic> raw =
            decoded is List ? decoded : (decoded['data'] as List? ?? []);
        setState(() {
          _materials = raw.cast<Map<String, dynamic>>();
          _materialsLoading = false;
        });
      } catch (_) {
        setState(() {
          _materialsError = 'Unexpected response format.';
          _materialsLoading = false;
        });
      }
    } else {
      setState(() {
        _materialsError = 'Error ${response.statusCode}';
        _materialsLoading = false;
      });
    }
  }

  Future<void> _checkActiveSession() async {
    setState(() => _sessionLoading = true);

    final response = await CloudApiService.get(
        '/api/classrooms/${widget.remoteId}/active-session');
    if (!mounted) return;

    setState(() {
      _sessionLoading = false;
      if (response != null && response.statusCode == 200) {
        try {
          final decoded =
              jsonDecode(response.body) as Map<String, dynamic>;
          // Server may wrap in {"session": {...}} or return flat object
          _activeSession =
              (decoded['session'] as Map<String, dynamic>?) ?? decoded;
        } catch (_) {
          _activeSession = null;
        }
      } else {
        _activeSession = null;
      }
    });
  }

  Future<void> _openMaterial(Map<String, dynamic> material) async {
    final url      = (material['url'] as String?) ?? '';
    final mime     = (material['mime_type'] as String?) ?? '';
    final name     = (material['original_name'] as String?) ?? 'file';
    final remoteId = material['id']?.toString() ?? '';

    if (url.isEmpty) {
      _showError('Material URL is not available.');
      return;
    }

    // PDFs → open in-app with Syncfusion network viewer (no download needed)
    if (mime == 'application/pdf') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _NetworkPdfView(title: name, url: url),
        ),
      );
      return;
    }

    // Images → open in-app image viewer
    if (mime.startsWith('image/')) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _NetworkImageView(title: name, url: url),
        ),
      );
      return;
    }

    // Other types (e.g. DOCX) → download to cache then open with system app
    setState(() => _downloadingIds.add(remoteId));
    await _downloadAndOpen(url, name, remoteId);
    if (mounted) setState(() => _downloadingIds.remove(remoteId));
  }

  Future<void> _downloadAndOpen(
      String url, String filename, String remoteId) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final dest = File('${cacheDir.path}/online_materials/$remoteId/$filename');
      await dest.parent.create(recursive: true);

      if (!await dest.exists()) {
        final base  = await CloudApiService.getBaseUrl();
        final token = await const FlutterSecureStorage()
            .read(key: CloudApiService.kToken);

        final response = await http.get(
          Uri.parse(url.startsWith('http') ? url : '$base$url'),
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ).timeout(const Duration(minutes: 5));

        if (response.statusCode != 200) {
          _showError('Download failed (${response.statusCode}).');
          return;
        }
        await dest.writeAsBytes(response.bodyBytes);
      }

      await OpenFilex.open(dest.path);
    } catch (e) {
      _showError('Could not open file: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _saveClassroom() {
    widget.onSave();
    setState(() => _isSaved = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Classroom saved to My Classrooms.'),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.name,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            if (widget.schedule.isNotEmpty)
              Text(widget.schedule,
                  style:
                      const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        actions: [
          _sessionLoading
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))),
                )
              : Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _activeSession != null
                      ? Chip(
                          label: const Text('Live',
                              style: TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold)),
                          backgroundColor: Colors.green.shade400,
                          side: BorderSide.none,
                          padding: EdgeInsets.zero,
                          labelPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                        )
                      : Chip(
                          label: const Text('Offline',
                              style: TextStyle(fontSize: 11)),
                          backgroundColor: Colors.white24,
                          side: BorderSide.none,
                          padding: EdgeInsets.zero,
                          labelPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                        ),
                ),
        ],
      ),
      body: Column(
        children: [
          // --- INFO CARD ---
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF1E3A8A).withValues(alpha: 0.05),
            child: Row(
              children: [
                const Icon(Icons.cloud_outlined,
                    color: Color(0xFF1E3A8A), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.teacherName != null
                        ? 'Instructor: ${widget.teacherName}'
                        : 'Online Classroom',
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ),
                if (_activeSession != null)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final navigator = Navigator.of(context);

                      // Register student as participant + get fresh session data
                      final joinResp = await CloudApiService.post(
                          '/api/classrooms/${widget.remoteId}/join', {});

                      Map<String, dynamic>? session;
                      if (joinResp != null && joinResp.statusCode == 200) {
                        session = parseJoinedSessionPayload(joinResp.body);
                      }
                      // Fallback to locally-cached active-session data
                      session ??= _activeSession;

                      if (session == null) {
                        if (mounted) {
                          messenger.showSnackBar(const SnackBar(
                              content: Text('Could not join session. Try again.')));
                        }
                        return;
                      }

                      final sessionId = session['id']?.toString() ?? '';

                      if (sessionId.isEmpty) {
                        if (mounted) {
                          messenger.showSnackBar(const SnackBar(
                              content: Text('Session info unavailable.')));
                        }
                        return;
                      }
                      if (!mounted) return;
                      navigator.push(
                        MaterialPageRoute(
                          builder: (_) => OnlineSessionLobbyView(
                            classroomRemoteId: widget.remoteId,
                            classroomName: widget.name,
                            sessionId: sessionId,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.login, size: 16),
                    label: const Text('Join Live'),
                  )
                else
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1E3A8A),
                      side: const BorderSide(color: Color(0xFF1E3A8A)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => OnlineSessionLobbyView(
                          classroomRemoteId: widget.remoteId,
                          classroomName: widget.name,
                          // no sessionId — browse-only mode
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.folder_open_outlined, size: 16),
                    label: const Text('Browse'),
                  ),
              ],
            ),
          ),

          // --- MATERIALS SECTION HEADER ---
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                const Text('Materials',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                const Spacer(),
                if (!_isSaved)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E3A8A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    onPressed: _saveClassroom,
                    icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                    label: const Text('Save Room'),
                  )
                else
                  Row(
                    children: [
                      Icon(Icons.bookmark_added,
                          size: 16, color: Colors.green.shade600),
                      const SizedBox(width: 4),
                      Text('Saved',
                          style: TextStyle(
                              fontSize: 12, color: Colors.green.shade700)),
                    ],
                  ),
              ],
            ),
          ),

          // --- MATERIALS LIST ---
          Expanded(child: _buildMaterialsList()),
        ],
      ),
    );
  }

  Widget _buildMaterialsList() {
    if (_materialsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_materialsError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade300, size: 48),
              const SizedBox(height: 12),
              Text(_materialsError!,
                  style: const TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _loadMaterials, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_materials.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('No materials uploaded yet.',
                style: TextStyle(color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: _materials.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final m        = _materials[index];
        final mime     = (m['mime_type'] as String?) ?? '';
        final name     = (m['original_name'] as String?) ?? 'Unnamed';
        final size     = (m['size_bytes'] as int?) ?? 0;
        final remoteId = m['id']?.toString() ?? '';
        final isLoading = _downloadingIds.contains(remoteId);

        return Card(
          elevation: 1,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _colorForMime(mime).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(_iconForMime(mime),
                  color: _colorForMime(mime), size: 22),
            ),
            title: Text(name,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            subtitle: Text(_formatSize(size),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            trailing: isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.open_in_new,
                    size: 20, color: Colors.grey),
            onTap: isLoading ? null : () => _openMaterial(m),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------

  IconData _iconForMime(String mime) {
    if (mime == 'application/pdf') return Icons.picture_as_pdf;
    if (mime.startsWith('image/')) return Icons.image;
    if (mime.contains('word')) return Icons.description;
    return Icons.insert_drive_file;
  }

  Color _colorForMime(String mime) {
    if (mime == 'application/pdf') return Colors.red;
    if (mime.startsWith('image/')) return Colors.teal;
    if (mime.contains('word')) return Colors.blue;
    return Colors.grey;
  }

  String _formatSize(int bytes) {
    if (bytes == 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// ---------------------------------------------------------------------------
// Network PDF Viewer
// ---------------------------------------------------------------------------

class _NetworkPdfView extends StatelessWidget {
  final String title;
  final String url;

  const _NetworkPdfView({required this.title, required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title,
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      body: SfPdfViewer.network(url),
    );
  }
}

// ---------------------------------------------------------------------------
// Network Image Viewer
// ---------------------------------------------------------------------------

class _NetworkImageView extends StatelessWidget {
  final String title;
  final String url;

  const _NetworkImageView({required this.title, required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title,
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) {
              if (progress == null) return child;
              return const Center(child: CircularProgressIndicator());
            },
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image, size: 64, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }
}
