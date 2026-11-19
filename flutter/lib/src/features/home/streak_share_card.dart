import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// The streak share card + system share sheet (streak upgrade
/// deliverable 3; spec addendum — BINDING).
///
/// The card is rendered as a PNG (RepaintBoundary → image,
/// 1080×1080) matching tabs_streak_share_card_v7_20261118.png:
/// dark navy gradient background, the founder-set text
/// "I have a streak of / {N} / days of tracking my health!"
/// ({N} = the SETTLED count at generation time — never a
/// projected, simulated, or pre-settlement count, Juno §10), the
/// number in orange (#FF6A3D family), the Bandit cheer art
/// (assets/images/bandit_cheer_cut_v3.png, copied verbatim — never
/// recut) bleeding off the bottom edge over a purple glow and a
/// ground shadow, and the "Tabs" wordmark bottom-left. NO emoji.
///
/// The share action hands the PNG file to the ANDROID SYSTEM SHARE
/// SHEET via share_plus — no in-app destination list, no direct
/// posting, no network call.
class StreakShareCard extends StatelessWidget {
  final int count;

  const StreakShareCard({super.key, required this.count});

  static const double cardSize = 1080;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: cardSize,
      height: cardSize,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-0.6, -1),
                  end: Alignment(0.6, 1),
                  colors: [
                    Color(0xFF0D1428),
                    Color(0xFF080E1A),
                    Color(0xFF1B1440),
                  ],
                  stops: [0, 0.58, 1],
                ),
              ),
            ),
          ),
          // Purple glow behind Bandit (bottom-right).
          Positioned(
            right: -180,
            bottom: -120,
            width: 940,
            height: 940,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF7C6EFF).withValues(alpha: 0.55),
                    const Color(0xFF7C6EFF).withValues(alpha: 0),
                  ],
                  stops: const [0, 0.68],
                ),
              ),
            ),
          ),
          // Ground shadow under Bandit.
          Positioned(
            right: 32,
            bottom: 4,
            width: 580,
            height: 80,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                gradient: RadialGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.62),
                    Colors.black.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.7],
                ),
              ),
            ),
          ),
          // Bandit cheer art, bleeding off the bottom edge.
          Positioned(
            right: -20,
            bottom: -16,
            height: 724,
            child: Image.asset(
              'assets/images/bandit_cheer_cut_v3.png',
              fit: BoxFit.fitHeight,
            ),
          ),
          // Founder-set text (Juno §10 — confirmed verbatim).
          Positioned(
            left: 88,
            top: 104,
            width: 530,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'I have a streak of',
                  style: TextStyle(
                    fontSize: 58,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: Color(0xFFC9CEEA),
                  ),
                ),
                Text(
                  '$count',
                  key: const Key('shareCardCount'),
                  style: const TextStyle(
                    fontSize: 300,
                    fontWeight: FontWeight.w900,
                    height: 1.02,
                    color: Color(0xFFFF6B4A),
                  ),
                ),
                const Text(
                  'days of tracking my health!',
                  style: TextStyle(
                    fontSize: 58,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: Color(0xFFF0EEFF),
                  ),
                ),
              ],
            ),
          ),
          const Positioned(
            left: 88,
            bottom: 72,
            child: Text(
              'Tabs',
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.w700,
                color: Color(0xFF7C6EFF),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hands one generated PNG file to the system share sheet. The
/// production implementation is share_plus; tests substitute a
/// recorder through [StreakShareService.debugSetShareFn].
typedef StreakShareFn = Future<void> Function(File file);

class StreakShareService {
  StreakShareService._();

  static StreakShareFn? _shareOverride;
  static Future<Directory> Function()? _dirOverride;

  @visibleForTesting
  static void debugSetShareFn(
    StreakShareFn? share, {
    Future<Directory> Function()? tempDir,
  }) {
    _shareOverride = share;
    _dirOverride = tempDir;
  }

  static Future<void> _defaultShare(File file) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], fileNameOverrides: [file.path.split(Platform.pathSeparator).last]),
    );
  }

  /// Renders [boundaryKey]'s RepaintBoundary to a 1080×1080 PNG
  /// file in the temp directory. Returns null on any failure (the
  /// caller keeps the screen up — a share failure never dismisses
  /// a celebration).
  static Future<File?> renderCardPng(
    GlobalKey boundaryKey, {
    required int count,
  }) async {
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return null;
    final bytes = byteData.buffer.asUint8List();
    final dir = _dirOverride != null
        ? await _dirOverride!()
        : await getTemporaryDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}tabs_streak_share_$count.png',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Generates the card PNG from [boundaryKey] and hands EXACTLY
  /// that file to the system share sheet. No network call exists
  /// on this path.
  static Future<bool> shareFromBoundary(
    GlobalKey boundaryKey, {
    required int count,
  }) async {
    final file = await renderCardPng(boundaryKey, count: count);
    if (file == null) return false;
    final share = _shareOverride ?? _defaultShare;
    await share(file);
    return true;
  }
}

/// Hosts the offscreen RepaintBoundary the PNG is rendered from.
/// The card renders at its full 1080×1080 logical size inside an
/// OverflowBox so the visible UI is never disturbed by it.
class StreakShareCardHost extends StatelessWidget {
  final GlobalKey boundaryKey;
  final int count;

  const StreakShareCardHost({
    super.key,
    required this.boundaryKey,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    // ClipRect keeps the full-size card from painting over the
    // host screen: only a 1×1 sliver is ever composited, while
    // the RepaintBoundary still renders its own subtree at full
    // size for toImage.
    return ClipRect(
      child: SizedBox(
        width: 1,
        height: 1,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: StreakShareCard.cardSize,
          minHeight: 0,
          maxHeight: StreakShareCard.cardSize,
          child: RepaintBoundary(
            key: boundaryKey,
            child: StreakShareCard(count: count),
          ),
        ),
      ),
    );
  }
}
