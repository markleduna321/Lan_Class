// lib/features/online/participant_tile_widget.dart
//
// Simple participant name/avatar tile.
// The WebRTC video rendering (RTCVideoRenderer) has been removed as part of
// the Jitsi SDK migration — Jitsi handles all video UI natively.

import 'package:flutter/material.dart';

class ParticipantTile extends StatelessWidget {
  final String participantId;
  final String participantName;
  final bool isCameraOff;
  final bool isMuted;
  final bool isSelf;
  final VoidCallback? onMutePressed;

  const ParticipantTile({
    super.key,
    required this.participantId,
    required this.participantName,
    this.isCameraOff = false,
    this.isMuted = false,
    this.isSelf = false,
    this.onMutePressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: const Color(0xFF1E3A8A),
                  child: Text(
                    participantName.isNotEmpty
                        ? participantName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  participantName,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (isSelf)
            const Positioned(
              top: 4, left: 4,
              child: Chip(
                label: Text('You',
                    style: TextStyle(fontSize: 9, color: Colors.white)),
                backgroundColor: Colors.black45,
                padding: EdgeInsets.zero,
                labelPadding: EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
          if (isMuted)
            const Positioned(
              bottom: 4, left: 4,
              child: Icon(Icons.mic_off,
                  color: Colors.red, size: 14),
            ),
          if (onMutePressed != null)
            Positioned(
              top: 4, right: 4,
              child: GestureDetector(
                onTap: onMutePressed,
                child: Icon(
                  isMuted ? Icons.mic_off : Icons.mic,
                  color: isMuted ? Colors.red : Colors.white70,
                  size: 16,
                ),
              ),
            ),
        ],
      ),
    );
  }
}