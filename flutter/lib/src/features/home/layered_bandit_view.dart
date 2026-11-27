import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/cosmetics.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';
import 'package:tabs_lab/src/theme/animations.dart';

/// Test seam for the layered view's motion gate (the
/// debugBanditSlotMotionOverride precedent in
/// bandit_reading_slot.dart). Widget tests run under FLUTTER_TEST,
/// where motion is hard-off, so a test may set this to true to
/// step the timeline. Reduced motion still wins, and production
/// code never sets it.
@visibleForTesting
bool? debugLayeredBanditMotionOverride;

/// The reading loop's timeline, baked into Dart.
///
/// Source: the art package's timeline.json (assets_final — the
/// only timing authority for the layered build; verified
/// identical to the table decoded from
/// bandit_reading_loop_v9.webp: 33 stored frames; the encoder
/// merged each blink's two lid-1.0 holds into one 83–84 ms
/// frame, which is why this table has 33 steps, not the 37
/// entries of the un-merged frame list). Eye states: 0 = eyes
/// open (the base layer alone), 1–4 = lid 0.25 / 0.55 / 0.85 /
/// 1.0 (the eye-band patch for that state). Durations sum to
/// 13,999 ms ≈ the loop's 14 s. Pinned by
/// gem_store_test.dart (33 steps, exact sum, state sequence).
abstract final class BanditTimeline {
  static const List<({int durationMs, int eyeState})> steps = [
    (durationMs: 2291, eyeState: 0),
    (durationMs: 42, eyeState: 1),
    (durationMs: 42, eyeState: 2),
    (durationMs: 41, eyeState: 3),
    (durationMs: 84, eyeState: 4),
    (durationMs: 41, eyeState: 3),
    (durationMs: 42, eyeState: 2),
    (durationMs: 42, eyeState: 1),
    (durationMs: 2583, eyeState: 0),
    (durationMs: 42, eyeState: 1),
    (durationMs: 41, eyeState: 2),
    (durationMs: 42, eyeState: 3),
    (durationMs: 83, eyeState: 4),
    (durationMs: 42, eyeState: 3),
    (durationMs: 42, eyeState: 2),
    (durationMs: 41, eyeState: 1),
    (durationMs: 4042, eyeState: 0),
    (durationMs: 42, eyeState: 1),
    (durationMs: 41, eyeState: 2),
    (durationMs: 42, eyeState: 3),
    (durationMs: 83, eyeState: 4),
    (durationMs: 42, eyeState: 3),
    (durationMs: 42, eyeState: 2),
    (durationMs: 41, eyeState: 1),
    (durationMs: 2584, eyeState: 0),
    (durationMs: 41, eyeState: 1),
    (durationMs: 42, eyeState: 2),
    (durationMs: 42, eyeState: 3),
    (durationMs: 83, eyeState: 4),
    (durationMs: 42, eyeState: 3),
    (durationMs: 41, eyeState: 2),
    (durationMs: 42, eyeState: 1),
    (durationMs: 1166, eyeState: 0),
  ];

  static int get totalMs =>
      steps.fold(0, (sum, s) => sum + s.durationMs);
}

/// The eye-band rectangle in the 832×992 frame, from the art
/// package's assets_manifest.json (bandRect x 277, y 271, w 278,
/// h 101) — independently confirmed against the v9 loop itself
/// (the union of every blink frame's diff against the base frame:
/// x 277–554, y 271–371). The eye patches are opaque rectangles
/// at this rect (the band is fully opaque in the source art).
abstract final class BanditBandRect {
  static const double frameWidth = 832;
  static const double frameHeight = 992;
  static const double left = 277;
  static const double top = 271;
  static const double width = 278;
  static const double height = 101;
}

/// Layered Bandit (Gem Store, Nov 27, 2026): ONE widget serving
/// Home and the store for ANY selection mix. The frame stack is
/// chair → Bandit base → eye-band patch for the current blink
/// state → book → shades (when selected), all full-frame
/// 832×992 layers except the eye patches, which are positioned
/// over [BanditBandRect]. A single timeline stepper drives the
/// 33-step blink loop ([BanditTimeline]) so every layer stays in
/// lockstep for every combination — there are no per-combo
/// assets.
///
/// Motion off (reduced motion, widget tests, or [animate] false)
/// renders the state-0 still composite. The head never moves in
/// the reading loop (blink only — the v9 audit), so the shades
/// layer is a static overlay and blinks happen under the lenses.
class LayeredBanditView extends StatefulWidget {
  final BanditSelection selection;

  /// Whether the timeline should run (the caller still loses to
  /// reduced motion / the test environment — see the motion gate
  /// in bandit_reading_slot.dart, whose discipline this mirrors).
  final bool animate;

  /// Semantics label for the composite (Juno §10 #49 on the hero
  /// / Home). Null falls back to the §10 hero label for
  /// [selection]; card previews pass [excludeSemantics] instead
  /// and label the card itself.
  final String? semanticLabel;
  final bool excludeSemantics;

  const LayeredBanditView({
    super.key,
    required this.selection,
    this.animate = true,
    this.semanticLabel,
    this.excludeSemantics = false,
  });

  static const double frameAspect = 832 / 992;

  static String chairAsset(CosmeticItem chair) =>
      'assets/bandit_store/chair_${chair.assetSuffix}.webp';
  static String banditAsset(CosmeticItem bandit) =>
      'assets/bandit_store/bandit_${bandit.assetSuffix}.webp';
  static String eyesAsset(CosmeticItem bandit, int state) =>
      'assets/bandit_store/bandit_eyes_${bandit.assetSuffix}_$state.webp';
  static String bookAsset(CosmeticItem book) =>
      'assets/bandit_store/book_${book.assetSuffix}.webp';
  static String shadesAsset(CosmeticItem shades) =>
      'assets/bandit_store/shades_${shades.assetSuffix}.webp';

  @override
  State<LayeredBanditView> createState() => _LayeredBanditViewState();
}

class _LayeredBanditViewState extends State<LayeredBanditView> {
  int _step = 0;
  Timer? _timer;

  bool get _motionOn {
    if (!widget.animate) return false;
    final override = debugLayeredBanditMotionOverride;
    if (override != null) return override && !animationsDisabled(context);
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    return !animationsDisabled(context);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(LayeredBanditView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A selection change swaps layers in place; the timeline
    // keeps its step so a try-on never restarts the blink loop.
    _syncTimer();
  }

  void _syncTimer() {
    if (_motionOn) {
      _timer ??= Timer(
        Duration(milliseconds: BanditTimeline.steps[_step].durationMs),
        _advance,
      );
    } else {
      _timer?.cancel();
      _timer = null;
      if (_step != 0) setState(() => _step = 0);
    }
  }

  void _advance() {
    _timer = null;
    if (!mounted) return;
    setState(() => _step = (_step + 1) % BanditTimeline.steps.length);
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _layer(String asset, Key key) => Image.asset(
    asset,
    key: key,
    fit: BoxFit.fill,
    semanticLabel: kCoachName,
    errorBuilder: (_, _, _) => const SizedBox.expand(),
  );

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    final eyeState = BanditTimeline.steps[_step].eyeState;
    final stack = AspectRatio(
      aspectRatio: LayeredBanditView.frameAspect,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              _layer(
                LayeredBanditView.chairAsset(selection.chair),
                const ValueKey('layered_chair'),
              ),
              _layer(
                LayeredBanditView.banditAsset(selection.bandit),
                const ValueKey('layered_bandit_base'),
              ),
              if (eyeState > 0)
                Positioned(
                  left: BanditBandRect.left / BanditBandRect.frameWidth * w,
                  top: BanditBandRect.top / BanditBandRect.frameHeight * h,
                  width: BanditBandRect.width / BanditBandRect.frameWidth * w,
                  height:
                      BanditBandRect.height / BanditBandRect.frameHeight * h,
                  child: _layer(
                    LayeredBanditView.eyesAsset(selection.bandit, eyeState),
                    ValueKey('layered_bandit_eyes_$eyeState'),
                  ),
                ),
              _layer(
                LayeredBanditView.bookAsset(selection.book),
                const ValueKey('layered_book'),
              ),
              if (selection.shades != null)
                _layer(
                  LayeredBanditView.shadesAsset(selection.shades!),
                  const ValueKey('layered_shades'),
                ),
            ],
          );
        },
      ),
    );
    if (widget.excludeSemantics) return ExcludeSemantics(child: stack);
    return Semantics(
      label: widget.semanticLabel ?? StoreCopy.heroLabel(selection),
      child: stack,
    );
  }
}
