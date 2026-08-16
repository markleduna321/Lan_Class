// lib/features/classroom/materials_library_view.dart

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../database/asura_repository.dart';
import '../../services/lan_server_isolate.dart';
import '../../services/cloud_sync_service.dart';
import '../presentation/presentation_viewer_view.dart';

class MaterialsLibraryView extends StatefulWidget {
  final String classroomId;
  final String classroomName;

  const MaterialsLibraryView({
    super.key,
    required this.classroomId,
    required this.classroomName,
  });

  @override
  State<MaterialsLibraryView> createState() => _MaterialsLibraryViewState();
}

class _MaterialsLibraryViewState extends State<MaterialsLibraryView> {
  List<Map<String, dynamic>> _materials = [];
  bool _isUploading = false;
  String? _classroomRemoteId;       // Set once classroom is published
  final Set<String> _cloudBusyIds = {}; // Material IDs actively syncing

  @override
  void initState() {
    super.initState();
    _loadMaterials();
  }

  Future<void> _loadMaterials() async {
    final data =
        await AsuraRepository.getMaterialsForClassroom(widget.classroomId);
    final classroom =
        await AsuraRepository.getClassroomById(widget.classroomId);
    if (mounted) {
      setState(() {
        _materials = data;
        _classroomRemoteId = classroom?['remote_id'] as String?;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // UPLOAD
  // ---------------------------------------------------------------------------

  Future<void> _pickAndUploadFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx', 'doc', 'jpg', 'jpeg', 'png'],
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    if (picked.path == null) return;

    setState(() => _isUploading = true);

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final materialsDir =
          Directory('${docsDir.path}/classroom_materials/${widget.classroomId}');
      await materialsDir.create(recursive: true);

      // Give it a UUID-based filename to avoid collisions
      const uuid = Uuid();
      final ext = p.extension(picked.name);
      final storedFilename = '${uuid.v4()}$ext';
      final destPath = '${materialsDir.path}/$storedFilename';

      await File(picked.path!).copy(destPath);

      await AsuraRepository.insertMaterial({
        'id': const Uuid().v4(),
        'classroom_id': widget.classroomId,
        'original_name': picked.name,
        'filename': storedFilename,
        'mime_type': _mimeFromExtension(ext),
        'file_path': destPath,
        'size_bytes': picked.size,
        'created_at': DateTime.now().toIso8601String(),
      });

      await _loadMaterials();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${picked.name} added to materials.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // PRESENT
  // ---------------------------------------------------------------------------

  void _presentMaterial(Map<String, dynamic> material) {
    final isServerRunning = LanServerIsolateManager.instance.isServerRunning;

    if (!isServerRunning) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Server Not Active'),
          content: const Text(
              'Start the local network from the Teacher Dashboard first, then present a material.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final filePath = material['file_path'] as String;
    final filename = material['filename'] as String;
    final mimeType = material['mime_type'] as String;
    final sizeBytes = material['size_bytes'] as int;

    // Tell the isolate to serve this file and broadcast to students
    LanServerIsolateManager.instance.serveFile(
      filePath: filePath,
      filename: filename,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
    );

    // Teacher opens the presentation canvas with the local file
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PresentationViewerView(
          isTeacher: true,
          documentTitle: material['original_name'] as String,
          pdfFilePath: filePath,
          mimeType: mimeType,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // CLOUD SYNC
  // ---------------------------------------------------------------------------

  Future<void> _pushMaterialToCloud(Map<String, dynamic> material) async {
    if (_classroomRemoteId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Publish the classroom first before syncing materials.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final ready = await CloudSyncService.isReady;
    if (!mounted) return;
    if (!ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Link an online account first (Profile → Cloud Account).'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final materialId = material['id'] as String;
    setState(() => _cloudBusyIds.add(materialId));

    final result = await CloudSyncService.syncMaterial(
      classroomRemoteId: _classroomRemoteId!,
      filePath: material['file_path'] as String,
      originalName: material['original_name'] as String,
      mimeType: material['mime_type'] as String,
      materialId: materialId,
    );

    if (!mounted) return;
    setState(() => _cloudBusyIds.remove(materialId));

    if (result != null) {
      await AsuraRepository.updateMaterialRemoteInfo(
        materialId,
        remoteId: result.remoteId,
        remoteUrl: result.remoteUrl,
      );
      await _loadMaterials();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Material synced to cloud.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cloud sync failed. Check your connection and try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _removeMaterialFromCloud(Map<String, dynamic> material) async {
    if (_classroomRemoteId == null) return;
    final materialId       = material['id'] as String;
    final materialRemoteId = material['remote_id'] as String?;
    if (materialRemoteId == null) return;

    setState(() => _cloudBusyIds.add(materialId));

    final ok = await CloudSyncService.removeMaterialFromCloud(
        _classroomRemoteId!, materialRemoteId);

    if (!mounted) return;
    setState(() => _cloudBusyIds.remove(materialId));

    // Clear local remote info regardless (best-effort)
    await AsuraRepository.updateMaterialRemoteInfo(
      materialId,
      remoteId: ok ? null : materialRemoteId,
      remoteUrl: ok ? null : material['remote_url'] as String?,
    );
    await _loadMaterials();
  }

  // ---------------------------------------------------------------------------
  // DELETE
  // ---------------------------------------------------------------------------

  Future<void> _deleteMaterial(Map<String, dynamic> material) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Material'),
        content: Text('Remove "${material['original_name']}" from this classroom?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Remove file from storage
    try {
      final file = File(material['file_path'] as String);
      if (await file.exists()) await file.delete();
    } catch (_) {}

    await AsuraRepository.deleteMaterial(material['id'] as String);
    await _loadMaterials();
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  String _mimeFromExtension(String ext) {
    switch (ext.toLowerCase().replaceFirst('.', '')) {
      case 'pdf':
        return 'application/pdf';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'doc':
        return 'application/msword';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      default:
        return 'application/octet-stream';
    }
  }

  IconData _iconForMime(String mimeType) {
    if (mimeType == 'application/pdf') return Icons.picture_as_pdf;
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.contains('word')) return Icons.description;
    return Icons.insert_drive_file;
  }

  Color _colorForMime(String mimeType) {
    if (mimeType == 'application/pdf') return Colors.red;
    if (mimeType.startsWith('image/')) return Colors.teal;
    if (mimeType.contains('word')) return Colors.blue;
    return Colors.grey;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final serverRunning = LanServerIsolateManager.instance.isServerRunning;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Materials', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(widget.classroomName,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        actions: [
          if (!serverRunning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Chip(
                label: Text('Server Offline', style: TextStyle(fontSize: 11)),
                backgroundColor: Colors.orange,
              ),
            ),
        ],
      ),
      body: _materials.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_open, size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text('No materials yet.',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('Tap + to upload a PDF, image, or DOCX.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: _materials.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final m = _materials[index];
                final mime = m['mime_type'] as String;
                final isPresentable = mime == 'application/pdf' || mime.startsWith('image/');
                final isDocx = mime.contains('word');

                return Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _colorForMime(mime).withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_iconForMime(mime),
                              color: _colorForMime(mime), size: 26),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(m['original_name'] as String,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 14),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Text(
                                    _formatSize(m['size_bytes'] as int),
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.grey),
                                  ),
                                  if ((m['remote_id'] as String?) != null) ...[
                                    const SizedBox(width: 6),
                                    const Icon(Icons.cloud_done,
                                        size: 13, color: Colors.green),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          children: [
                            if (isPresentable)
                              _ActionButton(
                                icon: Icons.cast_connected,
                                label: 'Present',
                                color: serverRunning
                                    ? const Color(0xFF1E3A8A)
                                    : Colors.grey,
                                onTap: serverRunning
                                    ? () => _presentMaterial(m)
                                    : null,
                              ),
                            if (isDocx)
                              _ActionButton(
                                icon: Icons.open_in_new,
                                label: 'Open',
                                color: Colors.blue,
                                onTap: () =>
                                    OpenFilex.open(m['file_path'] as String),
                              ),
                            // Cloud action
                            if (_classroomRemoteId != null)
                              _cloudBusyIds.contains(m['id'])
                                  ? const Padding(
                                      padding: EdgeInsets.all(4),
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 1.5),
                                      ),
                                    )
                                  : (m['remote_id'] as String?) != null
                                      ? _ActionButton(
                                          icon: Icons.cloud_off,
                                          label: 'Remove',
                                          color: Colors.orange,
                                          onTap: () =>
                                              _removeMaterialFromCloud(m),
                                        )
                                      : _ActionButton(
                                          icon: Icons.cloud_upload,
                                          label: 'Push',
                                          color: Colors.blue,
                                          onTap: () =>
                                              _pushMaterialToCloud(m),
                                        ),
                            const SizedBox(height: 4),
                            _ActionButton(
                              icon: Icons.delete_outline,
                              label: 'Delete',
                              color: Colors.red,
                              onTap: () => _deleteMaterial(m),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        icon: _isUploading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
              )
            : const Icon(Icons.upload_file),
        label: Text(_isUploading ? 'Uploading...' : 'Upload Material'),
        onPressed: _isUploading ? null : _pickAndUploadFile,
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: (onTap != null ? color : Colors.grey).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: onTap != null ? color : Colors.grey),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: onTap != null ? color : Colors.grey,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
