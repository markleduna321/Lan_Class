// lib/features/classroom/student_join_view.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../services/lan_scanner_service.dart';
import '../online/online_classroom_browser_view.dart';
import '../online/online_classroom_detail_view.dart';
import 'student_lobby_view.dart';

const _kSavedClassroomsKey = 'saved_classrooms_v2';

class _SavedClassroom {
  final String ip;
  final String classroomId;
  final String roomName;
  final String schedule;
  final String addedAt;
  final String remoteId; // Laravel classroom ID (Phase 3+)

  _SavedClassroom({
    required this.ip,
    this.classroomId = '',
    this.roomName = '',
    this.schedule = '',
    required this.addedAt,
    this.remoteId = '',
  });

  factory _SavedClassroom.fromJson(Map<String, dynamic> json) => _SavedClassroom(
        ip: (json['ip'] as String?) ?? '',
        classroomId: (json['classroomId'] as String?) ?? '',
        roomName: (json['roomName'] as String?) ?? '',
        schedule: (json['schedule'] as String?) ?? '',
        addedAt: json['addedAt'] as String,
        remoteId: (json['remoteId'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'classroomId': classroomId,
        'roomName': roomName,
        'schedule': schedule,
        'addedAt': addedAt,
        'remoteId': remoteId,
      };
}

class StudentJoinView extends StatefulWidget {
  const StudentJoinView({super.key});

  @override
  State<StudentJoinView> createState() => _StudentJoinViewState();
}

class _StudentJoinViewState extends State<StudentJoinView>
    with TickerProviderStateMixin {
  final TextEditingController _ipController = TextEditingController();
  final _storage = const FlutterSecureStorage();

  List<_SavedClassroom> _savedRooms = [];
  bool _isScanning = false;
  bool _showAddForm = false;
  ScannedRoom? _lastScan;

  late AnimationController _radarController;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _radarController =
        AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() {
        // Rebuild when tab index settles (not mid-animation)
        if (!_tabController.indexIsChanging) setState(() {});
      });
    _loadSavedRooms();
  }

  @override
  void dispose() {
    _radarController.dispose();
    _tabController.dispose();
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedRooms() async {
    final raw = await _storage.read(key: _kSavedClassroomsKey);
    if (raw != null && mounted) {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => _SavedClassroom.fromJson(e as Map<String, dynamic>))
            .toList();
        setState(() => _savedRooms = list);
      } catch (_) {}
    }
  }

  Future<void> _persistRooms() async {
    final raw = jsonEncode(_savedRooms.map((r) => r.toJson()).toList());
    await _storage.write(key: _kSavedClassroomsKey, value: raw);
  }

  Future<void> _addRoom(_SavedClassroom newRoom) async {
    final existingIndex = _savedRooms.indexWhere((r) {
      if (newRoom.remoteId.isNotEmpty && r.remoteId == newRoom.remoteId) return true;
      if (newRoom.classroomId.isNotEmpty && r.classroomId == newRoom.classroomId) return true;
      if (newRoom.remoteId.isEmpty && newRoom.classroomId.isEmpty && r.ip == newRoom.ip) return true;
      return false;
    });

    setState(() {
      if (existingIndex != -1) {
        // Merge with existing room to unify Online/LAN states
        final existing = _savedRooms[existingIndex];
        final merged = _SavedClassroom(
          ip: newRoom.ip.isNotEmpty ? newRoom.ip : existing.ip,
          classroomId: newRoom.classroomId.isNotEmpty ? newRoom.classroomId : existing.classroomId,
          remoteId: newRoom.remoteId.isNotEmpty ? newRoom.remoteId : existing.remoteId,
          roomName: newRoom.roomName.isNotEmpty ? newRoom.roomName : existing.roomName,
          schedule: newRoom.schedule.isNotEmpty ? newRoom.schedule : existing.schedule,
          addedAt: existing.addedAt, // Keep original added date
        );
        _savedRooms.removeAt(existingIndex);
        _savedRooms.insert(0, merged);
      } else {
        _savedRooms.insert(0, newRoom);
      }
      _showAddForm = false;
      _ipController.clear();
      _lastScan = null;
    });
    await _persistRooms();
  }

  Future<void> _removeRoom(_SavedClassroom room) async {
    setState(() => _savedRooms.remove(room));
    await _persistRooms();
  }

  void _joinRoom(_SavedClassroom room) {
    // Online-only rooms (no LAN IP) — navigate to detail view (Phase 4 will add live join)
    if (room.ip.isEmpty && room.remoteId.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OnlineClassroomDetailView(
            remoteId: room.remoteId,
            name: room.roomName,
            schedule: room.schedule,
            isSaved: true,
            onSave: () {}, // Already saved
          ),
        ),
      );
      return;
    }
    // LAN room
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StudentLobbyView(
          hostIp: room.ip,
          roomLabel: room.roomName,
          classroomId: room.classroomId,
          classroomRemoteId: room.remoteId,
        ),
      ),
    );
  }

  void _triggerNetworkScan() async {
    setState(() {
      _isScanning = true;
      _lastScan = null; // clear previous result while new scan is in progress
    });
    _radarController.repeat();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Scanning local network for classrooms...')),
    );

    final scanned = await LanScannerService.scanForRoom();

    if (!mounted) return;
    _radarController.stop();
    setState(() {
      _isScanning = false;
      _lastScan = scanned;
    });

    if (scanned != null) {
      _ipController.text = scanned.ip;
      final label = scanned.name.isNotEmpty ? '${scanned.name} (${scanned.ip})' : scanned.ip;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Found: $label'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active classrooms found. Ensure you are on the same Wi-Fi.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _confirmAndAdd() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    final _SavedClassroom room;
    if (_lastScan != null && _lastScan!.ip == ip) {
      // Use the rich data from the UDP scan, including the remoteId if the
      // teacher has already published this classroom online.
      room = _SavedClassroom(
        ip: _lastScan!.ip,
        classroomId: _lastScan!.classroomId,
        roomName: _lastScan!.name,
        schedule: _lastScan!.schedule,
        remoteId: _lastScan!.remoteId,
        addedAt: DateTime.now().toIso8601String(),
      );
    } else {
      // Manual IP entry — no extra metadata
      room = _SavedClassroom(ip: ip, addedAt: DateTime.now().toIso8601String());
    }
    await _addRoom(room);
    _joinRoom(room);
  }

  /// Called when a student taps "Save" on a classroom in the online browser.
  void _onRoomSavedFromBrowser(Map<String, dynamic> classroom) {
    final room = _SavedClassroom(
      ip: '',
      classroomId: '',
      remoteId: classroom['id']?.toString() ?? '',
      roomName: (classroom['name'] as String?) ?? '',
      schedule: (classroom['schedule'] as String?) ?? '',
      addedAt: DateTime.now().toIso8601String(),
    );
    _addRoom(room);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"${room.roomName}" saved to My Classrooms.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Set<String> get _savedRemoteIds =>
      _savedRooms.map((r) => r.remoteId).where((id) => id.isNotEmpty).toSet();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // --- HEADER ---
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Column(
                children: [
                  RotationTransition(
                    turns: _radarController,
                    child: Icon(
                      Icons.radar,
                      size: 64,
                      color: _isScanning ? Colors.green : const Color(0xFF1E3A8A),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'My Classrooms',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Tap Join to enter a room, or add a new one.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),

            // --- TABS ---
            TabBar(
              controller: _tabController,
              labelColor: const Color(0xFF1E3A8A),
              unselectedLabelColor: Colors.grey,
              indicatorColor: const Color(0xFF1E3A8A),
              tabs: const [
                Tab(icon: Icon(Icons.wifi_tethering, size: 18), text: 'LAN Rooms'),
                Tab(icon: Icon(Icons.cloud_outlined, size: 18), text: 'Browse Online'),
              ],
            ),

            const Divider(height: 1),

            // --- TAB CONTENT ---
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // TAB 0 — LAN saved rooms
                  _buildLanTab(),
                  // TAB 1 — Online browser
                  OnlineClassroomBrowserView(
                    onSaveRoom: _onRoomSavedFromBrowser,
                    savedRemoteIds: _savedRemoteIds,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _tabController.index == 0 && !_showAddForm
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFF1E3A8A),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add Classroom'),
              onPressed: () => setState(() => _showAddForm = true),
            )
          : null,
    );
  }

  Widget _buildLanTab() {
    if (_savedRooms.isEmpty && !_showAddForm) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'No saved classrooms yet.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the button below to add one.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        ..._savedRooms.map((room) => _RoomCard(
              room: room,
              onJoin: () => _joinRoom(room),
              onRemove: () => _removeRoom(room),
            )),
        if (_showAddForm)
          _AddRoomForm(
            ipController: _ipController,
            isScanning: _isScanning,
            scannedRoom: _lastScan,
            onScan: _triggerNetworkScan,
            onAdd: _confirmAndAdd,
            onCancel: () => setState(() {
              _showAddForm = false;
              _ipController.clear();
              _lastScan = null;
            }),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _RoomCard extends StatelessWidget {
  final _SavedClassroom room;
  final VoidCallback onJoin;
  final VoidCallback onRemove;

  const _RoomCard({
    required this.room,
    required this.onJoin,
    required this.onRemove,
  });

  String _addedDate() {
    try {
      final dt = DateTime.parse(room.addedAt).toLocal();
      return 'Added ${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasName = room.roomName.isNotEmpty;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E3A8A).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                room.ip.isEmpty ? Icons.cloud_outlined : Icons.wifi_tethering,
                color: const Color(0xFF1E3A8A),
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasName ? room.roomName : room.ip,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  if (hasName)
                    Text(
                      room.ip,
                      style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontFamily: 'monospace'),
                    ),
                  if (room.schedule.isNotEmpty)
                    Row(
                      children: [
                        const Icon(Icons.schedule,
                            size: 11, color: Colors.blueGrey),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            room.schedule,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.blueGrey),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  Text(_addedDate(),
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: 'Remove',
              onPressed: onRemove,
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E3A8A),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onPressed: onJoin,
              child: Text(room.ip.isEmpty ? 'View' : 'Join'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _AddRoomForm extends StatelessWidget {
  final TextEditingController ipController;
  final bool isScanning;
  final ScannedRoom? scannedRoom;
  final VoidCallback onScan;
  final VoidCallback onAdd;
  final VoidCallback onCancel;

  const _AddRoomForm({
    required this.ipController,
    required this.isScanning,
    this.scannedRoom,
    required this.onScan,
    required this.onAdd,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF1E3A8A), width: 1.5),
      ),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Add New Classroom',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(
                  color: isScanning ? Colors.green : const Color(0xFF1E3A8A),
                  width: 2,
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: isScanning ? null : onScan,
              icon: Icon(
                isScanning ? Icons.search : Icons.wifi_find,
                color: isScanning ? Colors.green : const Color(0xFF1E3A8A),
              ),
              label: Text(
                isScanning ? 'Scanning...' : 'Auto-Scan for Classroom',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isScanning ? Colors.green : const Color(0xFF1E3A8A),
                ),
              ),
            ),
            // Scan result preview card
            if (scannedRoom != null) ...[
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.green.shade300),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.check_circle,
                            color: Colors.green.shade700, size: 15),
                        const SizedBox(width: 6),
                        Text('Classroom found',
                            style: TextStyle(
                                color: Colors.green.shade700,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (scannedRoom!.name.isNotEmpty)
                      Text(scannedRoom!.name,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold)),
                    if (scannedRoom!.schedule.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            const Icon(Icons.schedule,
                                size: 12, color: Colors.blueGrey),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(scannedRoom!.schedule,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.blueGrey)),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(scannedRoom!.ip,
                          style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              fontFamily: 'monospace')),
                    ),
                    if (scannedRoom!.classroomId.isNotEmpty)
                      Builder(builder: (_) {
                        final id = scannedRoom!.classroomId;
                        final display = id.length > 10
                            ? "${id.substring(0, 10)}…"
                            : id;
                        return Text("Room ID: $display",
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey));
                      }),
                  ],
                ),
              ),
            ],
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Row(children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('OR', style: TextStyle(color: Colors.grey)),
                ),
                Expanded(child: Divider()),
              ]),
            ),
            TextField(
              controller: ipController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Enter IP Address',
                prefixIcon: const Icon(Icons.cell_wifi),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E3A8A),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: onAdd,
                    child: const Text('Add & Join'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
