// lib/features/online/session_chat_panel.dart
//
// Phase 6 — Session Chat Panel
// Embedded widget shown as an overlay inside OnlineSessionView / OnlineSessionLobbyView.
// Loads message history from GET /api/sessions/{id}/chat.
// Sends messages via POST /api/sessions/{id}/chat + broadcasts CHAT_MESSAGE event.
// Receives new messages from OnlineSessionService.eventStream.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/cloud_api_service.dart';
import '../../services/online_session_service.dart';

// ---------------------------------------------------------------------------
// Chat message model
// ---------------------------------------------------------------------------

class ChatMessage {
  final String senderId;
  final String senderName;
  final bool   isTeacher;
  final String content;
  final DateTime sentAt;

  const ChatMessage({
    required this.senderId,
    required this.senderName,
    required this.isTeacher,
    required this.content,
    required this.sentAt,
  });

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
        senderId:   m['sender_id']   as String? ?? '',
        senderName: m['sender_name'] as String? ?? 'Unknown',
        isTeacher:  (m['is_teacher'] as bool?) ?? false,
        content:    m['content']     as String? ?? '',
        sentAt: DateTime.tryParse(m['sent_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

// ---------------------------------------------------------------------------
// SessionChatPanel
// ---------------------------------------------------------------------------

class SessionChatPanel extends StatefulWidget {
  final String sessionId;
  final String myId;
  final String myName;
  final bool   isTeacher;

  /// Called when the user taps the close (✕) button.
  final VoidCallback onClose;

  const SessionChatPanel({
    super.key,
    required this.sessionId,
    required this.myId,
    required this.myName,
    required this.isTeacher,
    required this.onClose,
  });

  @override
  State<SessionChatPanel> createState() => _SessionChatPanelState();
}

class _SessionChatPanelState extends State<SessionChatPanel> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _loading = true;
  bool _sending  = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();

    // Listen for real-time CHAT_MESSAGE events from Reverb WS
    _sub = OnlineSessionService.instance.eventStream.listen((event) {
      if (event['event'] == 'CHAT_MESSAGE' && mounted) {
        final msg = ChatMessage.fromMap(event);
        // Don't duplicate our own optimistic messages
        if (msg.senderId != widget.myId) {
          setState(() => _messages.add(msg));
          _scrollToBottom();
        }
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  Future<void> _loadHistory() async {
    final response =
        await CloudApiService.get('/api/sessions/${widget.sessionId}/chat');
    if (!mounted) return;
    if (response != null && response.statusCode == 200) {
      try {
        final decoded = jsonDecode(response.body);
        final List<dynamic> raw =
            decoded is List ? decoded : (decoded['data'] as List? ?? []);
        setState(() {
          _messages.addAll(raw.map((m) =>
              ChatMessage.fromMap(m as Map<String, dynamic>)));
          _loading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      } catch (_) {
        setState(() => _loading = false);
      }
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    // Optimistic UI update
    final msg = ChatMessage(
      senderId:   widget.myId,
      senderName: widget.myName,
      isTeacher:  widget.isTeacher,
      content:    text,
      sentAt:     DateTime.now(),
    );
    setState(() {
      _messages.add(msg);
      _sending = true;
    });
    _input.clear();
    _scrollToBottom();

    // Persist via API (which also triggers the Reverb broadcast server-side)
    await CloudApiService.post(
      '/api/sessions/${widget.sessionId}/chat',
      {
        'sender_id':   widget.myId,
        'sender_name': widget.myName,
        'is_teacher':  widget.isTeacher,
        'content':     text,
      },
    );

    if (mounted) setState(() => _sending = false);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Drag handle + title
          _buildHeader(),

          // Messages list
          Expanded(child: _buildMessageList()),

          // Input bar
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E3A8A),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          const Icon(Icons.chat_bubble_outline, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          const Text('Session Chat',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14)),
          const Spacer(),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 10),
            Text('No messages yet. Say hello!',
                style: TextStyle(
                    color: Colors.grey.shade500, fontSize: 13)),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (_, i) => _buildMessageBubble(_messages[i]),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isMine = msg.senderId == widget.myId;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor: msg.isTeacher
                  ? const Color(0xFF1E3A8A)
                  : Colors.grey.shade400,
              child: Text(
                msg.senderName.isNotEmpty
                    ? msg.senderName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 6),
          ],

          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.65,
              ),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isMine
                    ? const Color(0xFF1E3A8A)
                    : msg.isTeacher
                        ? Colors.deepPurple.shade50
                        : Colors.grey.shade100,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(12),
                  topRight: const Radius.circular(12),
                  bottomLeft: Radius.circular(isMine ? 12 : 0),
                  bottomRight: Radius.circular(isMine ? 0 : 12),
                ),
              ),
              child: Column(
                crossAxisAlignment: isMine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (!isMine)
                    Text(
                      msg.isTeacher
                          ? '${msg.senderName} (Teacher)'
                          : msg.senderName,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: msg.isTeacher
                              ? const Color(0xFF1E3A8A)
                              : Colors.grey.shade600),
                    ),
                  Text(
                    msg.content,
                    style: TextStyle(
                        fontSize: 13,
                        color: isMine ? Colors.white : Colors.black87),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatTime(msg.sentAt),
                    style: TextStyle(
                        fontSize: 9,
                        color: isMine
                            ? Colors.white54
                            : Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(color: Colors.grey.shade200)),
          color: Theme.of(context).colorScheme.surface,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Type a message…',
                  hintStyle:
                      TextStyle(fontSize: 13, color: Colors.grey.shade400),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide:
                        BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide:
                        BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            _sending
                ? const SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send_rounded),
                    color: const Color(0xFF1E3A8A),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 36, minHeight: 36),
                  ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h   = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$h:$min';
  }
}
