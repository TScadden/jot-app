import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/features/badges/badge_strings.dart';
import 'package:tabs_lab/src/features/badges/badge_widget.dart';
import 'package:tabs_lab/src/features/badges/badges_screen.dart'
    show badgeIconOf;

/// The badge share card + system share sheet (badge-share package;
/// mirrors streak_share_card.dart EXACTLY in structure — the same
/// service contract, the same offscreen host, the same palette).
///
/// The card is rendered as a PNG (RepaintBoundary → image,
/// 1080×1080): the streak card's navy gradient background and
/// purple glow, Juno's headline "I earned a badge!"
/// (JUNO-COPY.md §1), the badge art at hero size, then the badge
/// name, the rung STANDING ALONE on its own line (§2 — never
/// combined with the name, no dash, no dot), and the achievement
/// line — [BadgeStrings.thresholdLine] for the SHARED rung only,
/// never the next rung and never a measured value (§5 prohibition).
/// The "Tabs" wordmark sits bottom-left exactly as on the streak
/// card. NO emoji.
///
/// The share action hands the PNG file to the ANDROID SYSTEM SHARE
/// SHEET via share_plus — files + fileNameOverrides ONLY: no text,
/// no subject, no in-app destination list, no network call (§3).
class BadgeShareCard extends StatelessWidget {
  final BadgeMetric metric;
  final int rungIndex;

  const BadgeShareCard({
    super.key,
    required this.metric,
    required this.rungIndex,
  });

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
          // Purple glow centered behind the badge art.
          Positioned(
            left: 70,
            top: -18,
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
          // Card copy (Juno §§1–2, in ruled order): headline, badge
          // art, badge name, rung alone, achievement line. Placed
          // with Positioned elements, exactly as the streak card
          // places its copy — no flex to overflow.
          const Positioned(
            top: 84,
            left: 80,
            right: 80,
            child: Text(
              BadgeStrings.shareHeadline,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w800,
                height: 1.2,
                color: Color(0xFFF0EEFF),
              ),
            ),
          ),
          Positioned(
            left: 320,
            top: 232,
            child: BadgeWidget(
              rungIndex: rungIndex,
              icon: badgeIconOf(metric.id),
              size: 440,
            ),
          ),
          Positioned(
            top: 696,
            left: 60,
            right: 60,
            child: Text(
              BadgeStrings.badgeName(metric.id),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 76,
                fontWeight: FontWeight.w800,
                height: 1.15,
                color: Color(0xFFF0EEFF),
              ),
            ),
          ),
          Positioned(
            top: 795,
            left: 60,
            right: 60,
            child: Text(
              badgeRungName(rungIndex),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w800,
                height: 1.2,
                color: BadgeWidget.tierTextColor(rungIndex),
              ),
            ),
          ),
          Positioned(
            top: 884,
            left: 80,
            right: 80,
            child: Text(
              BadgeStrings.thresholdLine(
                metric.id,
                metric.thresholds[rungIndex],
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 52,
                fontWeight: FontWeight.w600,
                height: 1.25,
                color: Color(0xFFC9CEEA),
              ),
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
/// recorder through [BadgeShareService.debugSetShareFn].
typedef BadgeShareFn = Future<void> Function(File file);

class BadgeShareService {
  BadgeShareService._();

  static BadgeShareFn? _shareOverride;
  static Future<Directory> Function()? _dirOverride;

  @visibleForTesting
  static void debugSetShareFn(
    BadgeShareFn? share, {
    Future<Directory> Function()? tempDir,
  }) {
    _shareOverride = share;
    _dirOverride = tempDir;
  }

  static Future<void> _defaultShare(File file) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        fileNameOverrides: [file.path.split(Platform.pathSeparator).last],
      ),
    );
  }

  /// Renders [boundaryKey]'s RepaintBoundary to a 1080×1080 PNG
  /// file in the temp directory. Returns null on any failure (the
  /// caller keeps the screen up — a share failure never dismisses
  /// the host UI).
  static Future<File?> renderCardPng(
    GlobalKey boundaryKey, {
    required BadgeMetric metric,
    required int rungIndex,
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
      '${dir.path}${Platform.pathSeparator}'
      'tabs_badge_share_${metric.id}_$rungIndex.png',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Generates the card PNG from [boundaryKey] and hands EXACTLY
  /// that file to the system share sheet. No text or subject is
  /// passed (Juno §3) and no network call exists on this path.
  static Future<bool> shareFromBoundary(
    GlobalKey boundaryKey, {
    required BadgeMetric metric,
    required int rungIndex,
  }) async {
    final file = await renderCardPng(
      boundaryKey,
      metric: metric,
      rungIndex: rungIndex,
    );
    if (file == null) return false;
    final share = _shareOverride ?? _defaultShare;
    await share(file);
    return true;
  }
}

/// Hosts the offscreen RepaintBoundary the PNG is rendered from.
/// The card renders at its full 1080×1080 logical size inside an
/// OverflowBox so the visible UI is never disturbed by it.
class BadgeShareCardHost extends StatelessWidget {
  final GlobalKey boundaryKey;
  final BadgeMetric metric;
  final int rungIndex;

  const BadgeShareCardHost({
    super.key,
    required this.boundaryKey,
    required this.metric,
    required this.rungIndex,
  });

  @override
  Widget build(BuildContext context) {
    // ClipRect keeps the full-size card from painting over the
    // host screen: only a 1×1 sliver is ever composited, while
    // the RepaintBoundary still renders its own subtree at full
    // size for toImage. ExcludeSemantics keeps the offscreen
    // card's copy out of the host screen's semantics tree — the
    // card is an image-to-be, never a screen a screen reader
    // should announce (its texts would otherwise merge into the
    // host's semantics nodes and pollute their labels).
    return ExcludeSemantics(
      child: ClipRect(
        child: SizedBox(
          width: 1,
          height: 1,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            maxWidth: BadgeShareCard.cardSize,
            minHeight: 0,
            maxHeight: BadgeShareCard.cardSize,
            child: RepaintBoundary(
              key: boundaryKey,
              child: BadgeShareCard(metric: metric, rungIndex: rungIndex),
            ),
          ),
        ),
      ),
    );
  }
}
