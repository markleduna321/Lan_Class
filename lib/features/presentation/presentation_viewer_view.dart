// lib/features/presentation/presentation_viewer_view.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../services/lan_server_isolate.dart';
import '../../services/lan_scanner_service.dart';
import '../../database/asura_repository.dart';

enum _SourceType { none, asset, file, network }

class PresentationViewerView extends StatefulWidget {
  final bool isTeacher;
  final String documentTitle;
  final String? pdfAssetPath; // legacy/fallback asset
  final String? pdfFilePath;  // local file (teacher presenting a material)
  final String? mimeType;     // explicit mime — needed for images
  final String hostIp;
  /// When true the student viewer pops itself when the WS closes or
  /// PRESENTATION_ENDED arrives — used when launched from StudentLobbyView.
  final bool autoPopOnDisconnect;
  /// Pre-fetched FILE_PRESENTATION_START data from the lobby WS.
  /// When set, the viewer starts rendering immediately without waiting
  /// for the event from the server again.
  final Map<String, dynamic>? initialFileData;

  const PresentationViewerView({
    super.key,
    required this.isTeacher,
    required this.documentTitle,
    this.pdfAssetPath,
    this.pdfFilePath,
    this.mimeType,
    this.hostIp = '192.168.43.1',
    this.autoPopOnDisconnect = false,
    this.initialFileData,
  });

  @override
  State<PresentationViewerView> createState() => _PresentationViewerViewState();
}

class _PresentationViewerViewState extends State<PresentationViewerView> {
  late PdfViewerController _pdfViewerController;
  WebSocketChannel? _studentChannel;

  int _currentPage = 1;
  int _totalPages = 0;
  int? _pendingBroadcastPage;

  // Dynamic source â€” updated by WS event on student side
  _SourceType _sourceType = _SourceType.none;
  String? _activeFilePath;
  String? _activeNetworkUrl;
  String? _activeFilename;
  String? _activeMimeType;
  int _viewerRebuildKey = 0; // force SfPdfViewer recreation on source change

  bool _isSaving = false;
  bool _showSaveBanner = false;
  // Guards against double-pop when PRESENTATION_ENDED event AND onDone both fire
  bool _hasPopped = false;

  // Pre-loaded PDF bytes for local files — avoids SfPdfViewer.file silent
  // failure on Android app-documents paths. Set whenever _activeFilePath changes.
  Future<Uint8List>? _pdfBytesFuture;

  @override
  void initState() {
    super.initState();
    _pdfViewerController = PdfViewerController();

    if (widget.isTeacher) {
      if (widget.pdfFilePath != null) {
        _sourceType = _SourceType.file;
        _activeFilePath = widget.pdfFilePath;
        _activeMimeType = widget.mimeType ?? 'application/pdf';
        _activeFilename = widget.pdfFilePath!.split('/').last;
        _pdfBytesFuture = File(widget.pdfFilePath!).readAsBytes();
      } else if (widget.pdfAssetPath != null) {
        _sourceType = _SourceType.asset;
        _activeMimeType = widget.mimeType ?? 'application/pdf';
      }
    }

    if (!widget.isTeacher) {
      // If lobby already fetched the file event, start rendering immediately.
      if (widget.initialFileData != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (mounted) await _onFilePresentationStart(widget.initialFileData!);
        });
      }
      _listenForTeacherEvents();
    }
  }

  @override
  void dispose() {
    _pdfViewerController.dispose();
    _studentChannel?.sink.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // STUDENT â€“ WebSocket listener
  // ---------------------------------------------------------------------------
  /// Pops the viewer exactly once, regardless of how many events trigger it.
  void _safePop() {
    if (_hasPopped || !mounted) return;
    _hasPopped = true;
    Navigator.of(context).pop();
  }
  void _listenForTeacherEvents() {
    const storage = FlutterSecureStorage();
    storage.read(key: 'ACTIVE_USER_NAME').then((name) {
      try {
        _studentChannel =
            WebSocketChannel.connect(Uri.parse('ws://${widget.hostIp}:8080'));

        // Skip HANDSHAKE when coming from lobby — lobby already announced us.
        // Sending it again would create a duplicate attendance record.
        if (widget.initialFileData == null) {
          _studentChannel!.sink.add(jsonEncode({
            'event': 'HANDSHAKE',
            'from': 'student',
            'name': name ?? 'Student',
          }));
        }

        _studentChannel!.stream.listen(
          (message) async {
            final data = jsonDecode(message) as Map<String, dynamic>;
            switch (data['event'] as String?) {
              case 'PAGE_CHANGE':
                final targetPage = data['page_index'] as int;
                if (mounted && _currentPage != targetPage) {
                  _pdfViewerController.jumpToPage(targetPage);
                }
              case 'FILE_PRESENTATION_START':
                await _onFilePresentationStart(data);
              case 'PRESENTATION_ENDED':
                if (widget.autoPopOnDisconnect) _safePop();
            }
          },
          onError: (_) {
            if (widget.autoPopOnDisconnect) {
              _safePop();
            } else if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Connection to instructor lost.'),
                backgroundColor: Colors.red,
              ));
            }
          },
          onDone: () {
            if (widget.autoPopOnDisconnect) {
              _safePop();
            } else if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Connection to instructor lost.'),
                backgroundColor: Colors.red,
              ));
            }
          },
        );
      } catch (e) {
        debugPrint('WebSocket error: $e');
      }
    });
  }

  Future<void> _onFilePresentationStart(Map<String, dynamic> data) async {
    final filename = data['filename'] as String;
    final mimeType = (data['mime_type'] as String?) ?? 'application/pdf';

    final docsDir = await getApplicationDocumentsDirectory();
    final localPath = '${docsDir.path}/materials/$filename';
    final hasLocal = await File(localPath).exists();

    if (!mounted) return;
    setState(() {
      _activeFilename = filename;
      _activeMimeType = mimeType;
      _viewerRebuildKey++;
      _currentPage = 1;
      _totalPages = 0;

      if (hasLocal) {
        _sourceType = _SourceType.file;
        _activeFilePath = localPath;
        _pdfBytesFuture = File(localPath).readAsBytes();
        _showSaveBanner = false;
      } else {
        _sourceType = _SourceType.network;
        _activeNetworkUrl = 'http://${widget.hostIp}:8080/file';
        _showSaveBanner = true;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // STUDENT â€“ save local copy
  // ---------------------------------------------------------------------------

  Future<void> _saveLocalCopy() async {
    if (_isSaving || _activeNetworkUrl == null || _activeFilename == null) return;
    setState(() => _isSaving = true);

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${docsDir.path}/materials');
      await dir.create(recursive: true);
      final savePath = '${dir.path}/$_activeFilename';

      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(_activeNetworkUrl!));
      final res = await req.close();
      await res.pipe(File(savePath).openWrite());
      client.close();

      // Persist record to DB so the lobby's Materials tab can show the file
      final sizeBytes = await File(savePath).length();
      await AsuraRepository.upsertStudentMaterial({
        'id': '${widget.hostIp}_$_activeFilename',
        'classroom_ip': widget.hostIp,
        'original_name': _activeFilename!,
        'filename': _activeFilename!,
        'mime_type': _activeMimeType ?? 'application/octet-stream',
        'local_path': savePath,
        'size_bytes': sizeBytes,
        'received_at': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _showSaveBanner = false;
        _sourceType = _SourceType.file;
        _activeFilePath = savePath;
        _pdfBytesFuture = File(savePath).readAsBytes();
        _viewerRebuildKey++;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: $_activeFilename'), backgroundColor: Colors.green),
      );
    } catch (_) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Save failed. Check connection.'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // TEACHER â€“ page navigation + broadcast
  // ---------------------------------------------------------------------------

  void _broadcastPageChange(int page) =>
      LanServerIsolateManager.instance.sendSlideChange(page);

  void _goToNextPage() {
    if (_currentPage < _totalPages) {
      _pendingBroadcastPage = _currentPage + 1;
      _pdfViewerController.nextPage();
    }
  }

  void _goToPreviousPage() {
    if (_currentPage > 1) {
      _pendingBroadcastPage = _currentPage - 1;
      _pdfViewerController.previousPage();
    }
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          _activeFilename ?? widget.documentTitle,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (widget.isTeacher) ...[
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined,
                  color: Colors.orangeAccent),
              tooltip: 'Stop Presenting',
              onPressed: _stopPresenting,
            ),
            IconButton(
              icon: const Icon(Icons.power_settings_new,
                  color: Colors.redAccent),
              tooltip: 'Terminate Session',
              onPressed: () => _showEndSessionDialog(context),
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          // 1. CONTENT CANVAS
          if (_sourceType == _SourceType.none)
            _buildWaitingScreen()
          else if (_activeMimeType?.startsWith('image/') == true)
            _buildImageCanvas()
          else
            _buildPdfCanvas(),

          // 2. SAVE COPY BANNER (student, network-streaming mode only)
          if (!widget.isTeacher && _showSaveBanner && _sourceType != _SourceType.none)
            Positioned(
              top: 0, left: 0, right: 0,
              child: Material(
                color: const Color(0xFF1E3A8A).withValues(alpha: 0.92),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.cloud_download_outlined, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Streaming live â€” tap Save to keep a copy offline',
                            style: TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                      _isSaving
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : TextButton(
                              onPressed: _saveLocalCopy,
                              child: const Text('Save',
                                  style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
                            ),
                    ],
                  ),
                ),
              ),
            ),

          // 3. TEACHER PAGE CONTROLS
          if (widget.isTeacher &&
              _sourceType != _SourceType.none &&
              _activeMimeType?.startsWith('image/') != true)
            Positioned(
              bottom: 24, left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E3A8A).withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 10, offset: const Offset(0, 4))
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left, color: Colors.white, size: 32),
                        onPressed: _currentPage > 1 ? _goToPreviousPage : null,
                      ),
                      const SizedBox(width: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(12)),
                        child: Text('$_currentPage / $_totalPages',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, color: Colors.white, size: 32),
                        onPressed: _currentPage < _totalPages ? _goToNextPage : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWaitingScreen() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_top, color: Colors.white38, size: 64),
          SizedBox(height: 16),
          Text('Waiting for the instructor\nto start the presentation...',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildImageCanvas() {
    final Widget img = (_sourceType == _SourceType.file && _activeFilePath != null)
        ? Image.file(File(_activeFilePath!), fit: BoxFit.contain)
        : (_sourceType == _SourceType.network && _activeNetworkUrl != null)
            ? Image.network(_activeNetworkUrl!, fit: BoxFit.contain)
            : const SizedBox.shrink();
    return IgnorePointer(ignoring: !widget.isTeacher, child: img);
  }

  Widget _buildPdfCanvas() {
    void onPageChanged(PdfPageChangedDetails d) {
      final newPage = d.newPageNumber;
      setState(() => _currentPage = newPage);
      if (widget.isTeacher && _pendingBroadcastPage == newPage) {
        _broadcastPageChange(newPage);
        _pendingBroadcastPage = null;
      }
    }

    void onLoaded(PdfDocumentLoadedDetails d) =>
        setState(() => _totalPages = d.document.pages.count);

    void onLoadFailed(PdfDocumentLoadFailedDetails d) {
      debugPrint('PDF load failed: ${d.description}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not open PDF: ${d.description}'),
          backgroundColor: Colors.red,
        ));
      }
    }

    // Local file: read as bytes first — SfPdfViewer.file silently fails on
    // Android app-documents paths in some AGP/Syncfusion combinations.
    if (_sourceType == _SourceType.file && _pdfBytesFuture != null) {
      return FutureBuilder<Uint8List>(
        future: _pdfBytesFuture,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.white70));
          }
          if (snap.hasError || snap.data == null) {
            return Center(
              child: Text('Error reading file:\n${snap.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
            );
          }
          return IgnorePointer(
            ignoring: !widget.isTeacher,
            child: SfPdfViewer.memory(
              snap.data!,
              key: ValueKey('mem$_viewerRebuildKey'),
              controller: _pdfViewerController,
              canShowScrollHead: false,
              pageLayoutMode: PdfPageLayoutMode.single,
              onDocumentLoaded: onLoaded,
              onDocumentLoadFailed: onLoadFailed,
              onPageChanged: onPageChanged,
            ),
          );
        },
      );
    }

    // Network stream (student without local copy)
    if (_sourceType == _SourceType.network && _activeNetworkUrl != null) {
      return IgnorePointer(
        ignoring: !widget.isTeacher,
        child: SfPdfViewer.network(
          _activeNetworkUrl!,
          key: ValueKey('n$_viewerRebuildKey'),
          controller: _pdfViewerController,
          canShowScrollHead: false,
          pageLayoutMode: PdfPageLayoutMode.single,
          onDocumentLoaded: onLoaded,
          onDocumentLoadFailed: onLoadFailed,
          onPageChanged: onPageChanged,
        ),
      );
    }

    // Asset fallback
    return IgnorePointer(
      ignoring: !widget.isTeacher,
      child: SfPdfViewer.asset(
        widget.pdfAssetPath ?? 'assets/sample_lesson.pdf',
        key: ValueKey('a$_viewerRebuildKey'),
        controller: _pdfViewerController,
        canShowScrollHead: false,
        pageLayoutMode: PdfPageLayoutMode.single,
        onDocumentLoaded: onLoaded,
        onDocumentLoadFailed: onLoadFailed,
        onPageChanged: onPageChanged,
      ),
    );
  }

  void _stopPresenting() {
    LanServerIsolateManager.instance.stopPresentation();
    Navigator.of(context).pop();
  }

  void _showEndSessionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End Live Session?'),
        content: const Text(
            'This will shut down the local LAN server and disconnect all active students.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              LanServerIsolateManager.instance.stopServer();
              LanScannerService.stopBeacon();
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('Terminate', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
