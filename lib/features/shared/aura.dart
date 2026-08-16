// lib/features/shared/aura.dart
//
// Aura tier system — flame badges and name effects based on a user's aura score.
//
// Tiers:
//   Low       0 – 99     orange flame, plain name
//   Advanced  100 – 999  red flame, red glow on name
//   High      1000+      purple flame, glow + animated fire shimmer on name

import 'package:flutter/material.dart';

enum AuraTier { low, advanced, high }

AuraTier auraTierFor(int score) {
  if (score >= 1000) return AuraTier.high;
  if (score >= 100) return AuraTier.advanced;
  return AuraTier.low;
}

extension AuraTierInfo on AuraTier {
  String get label => switch (this) {
        AuraTier.low => 'Low',
        AuraTier.advanced => 'Advanced',
        AuraTier.high => 'High',
      };

  Color get color => switch (this) {
        AuraTier.low => const Color(0xFFF97316), // orange
        AuraTier.advanced => const Color(0xFFDC2626), // red
        AuraTier.high => const Color(0xFF9333EA), // purple
      };
}

// ---------------------------------------------------------------------------
// Flame badge
// ---------------------------------------------------------------------------

/// A small flame icon coloured by the user's aura tier.
class AuraFlameBadge extends StatelessWidget {
  final int score;
  final double size;
  final bool showScore;

  const AuraFlameBadge({
    super.key,
    required this.score,
    this.size = 16,
    this.showScore = false,
  });

  @override
  Widget build(BuildContext context) {
    final tier = auraTierFor(score);
    final flame = Icon(
      Icons.local_fire_department,
      size: size,
      color: tier.color,
      shadows: tier == AuraTier.high
          ? [Shadow(color: tier.color.withValues(alpha: 0.8), blurRadius: 8)]
          : null,
    );

    if (!showScore) return flame;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        flame,
        const SizedBox(width: 3),
        Text(
          '$score',
          style: TextStyle(
            fontSize: size * 0.8,
            fontWeight: FontWeight.w700,
            color: tier.color,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Aura name — renders a display name with the tier-appropriate effect
// ---------------------------------------------------------------------------

/// Renders [name] with the visual effect for the given aura [score]:
///  - Low:      plain text
///  - Advanced: red glow
///  - High:     glow + animated fire shimmer
class AuraName extends StatefulWidget {
  final String name;
  final int score;
  final double fontSize;
  final FontWeight fontWeight;
  final Color baseColor;
  final int? maxLines;
  final TextOverflow overflow;

  const AuraName({
    super.key,
    required this.name,
    required this.score,
    this.fontSize = 15,
    this.fontWeight = FontWeight.w700,
    this.baseColor = const Color(0xFF1F2937),
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
  });

  @override
  State<AuraName> createState() => _AuraNameState();
}

class _AuraNameState extends State<AuraName>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (auraTierFor(widget.score) == AuraTier.high) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      )..repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant AuraName oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nowHigh = auraTierFor(widget.score) == AuraTier.high;
    if (nowHigh && _controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      )..repeat(reverse: true);
    } else if (!nowHigh && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tier = auraTierFor(widget.score);

    // Low tier — plain text.
    if (tier == AuraTier.low) {
      return Text(
        widget.name,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: widget.fontWeight,
          color: widget.baseColor,
        ),
      );
    }

    // Advanced tier — static red glow.
    if (tier == AuraTier.advanced) {
      return Text(
        widget.name,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: widget.fontWeight,
          color: const Color(0xFFB91C1C),
          shadows: [
            Shadow(
                color: const Color(0xFFDC2626).withValues(alpha: 0.6),
                blurRadius: 8),
          ],
        ),
      );
    }

    // High tier — animated glow + fire shimmer.
    return AnimatedBuilder(
      animation: _controller!,
      builder: (context, _) {
        final t = _controller!.value; // 0 → 1 → 0
        final glow = 6 + 10 * t;
        return ShaderMask(
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: const [
              Color(0xFF9333EA), // purple
              Color(0xFFEC4899), // pink
              Color(0xFFF59E0B), // amber flame tip
            ],
            stops: [0.0, 0.5 + 0.2 * t, 1.0],
          ).createShader(rect),
          child: Text(
            widget.name,
            maxLines: widget.maxLines,
            overflow: widget.overflow,
            style: TextStyle(
              fontSize: widget.fontSize,
              fontWeight: widget.fontWeight,
              color: Colors.white, // masked by shader
              shadows: [
                Shadow(
                    color: const Color(0xFF9333EA).withValues(alpha: 0.7),
                    blurRadius: glow),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Resolves the display name for a user map: nickname → full name → fallback.
String resolveDisplayName(
  Map<String, dynamic> user, {
  String fallback = 'User',
}) {
  final nickname = (user['nickname'] as String?)?.trim();
  if (nickname != null && nickname.isNotEmpty) return nickname;

  final name = (user['name'] as String?)?.trim();
  if (name != null && name.isNotEmpty) return name;

  // Build from parts if present (local user row).
  final first = (user['first_name'] as String?)?.trim() ?? '';
  final last = (user['last_name'] as String?)?.trim() ?? '';
  final full = [first, last].where((p) => p.isNotEmpty).join(' ');
  return full.isNotEmpty ? full : fallback;
}
