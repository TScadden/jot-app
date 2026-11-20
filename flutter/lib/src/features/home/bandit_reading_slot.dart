import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';
import 'package:tabs_lab/src/theme/animations.dart';

/// Test seam for the slot motion gate (the debugMascotMotionOverride
/// precedent in coach_mascot.dart). Widget tests run under
/// FLUTTER_TEST, where motion is hard-off, so a test may set this to
/// true to exercise the animated path. Reduced motion still wins,
/// and production code never sets it.
@visibleForTesting
bool? debugBanditSlotMotionOverride;

/// Bandit slot motion runs only on a real device with animations
/// allowed: reduced motion and widget tests get the poster still.
bool _slotMotionEnabled(BuildContext context) {
  final override = debugBanditSlotMotionOverride;
  if (override != null) {
    return override && !animationsDisabled(context);
  }
  if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
  return !animationsDisabled(context);
}

/// Home redesign — the Bandit reading slot in the Home body column:
/// centered. Plays the reading animation when motion is allowed;
/// under reduced motion (and in widget tests) it shows the poster
/// still only. The still path reuses [CoachMascotFigure] — the
/// mascot widgets are reused, never forked.
///
/// Home polish round 4 (Part B) — the slot steps up from the
/// redesign's 240dp wide to [slotWidth] 282dp (×1.175, inside the
/// founder's 15–20% bigger band), and Home tucks the slot's bottom
/// edge BEHIND the Today Summary card (see home_screen.dart's
/// overlap stack). The root is an [Align] with heightFactor 1 so
/// the slot's height in that stack is exactly [slotHeight] — a
/// plain [Center] would expand to the stack's full height and
/// push Bandit down.
///
/// Bandit v9 (Nov 20, 2026) — the loop is REMADE as a genuine
/// animation of discrete drawn frames, replacing the v8 video.
/// The founder rejected v8 because its breathing was a chest-only
/// pixel warp (the belly band visibly morphs); v9's frames are the
/// transparent reading poster (PR #123) with drawn eyelid frames
/// composited over the eye band and NOTHING else moving — the
/// frame-diff audit proves zero pixel differences outside the eye
/// band across all 336 timeline frames, transparent corners in
/// every frame, and an exact loop seam. Breathing stays removed
/// (founder decision Nov 12, 2026): blink only.
///
/// The asset is an animated WebP with REAL alpha (the v8 H.264
/// mp4 could not carry transparency, which is why its background
/// was baked in). Encoded lossless with libwebp; the blink-only
/// frames store as small eye-band sub-rectangles, so the 14 s
/// loop is 451,744 bytes — smaller than the 2.06 MB mp4 it
/// replaces. Playback is a plain [Image] — no video player, so
/// the VC 100137 audio-focus concern is gone structurally: there
/// is no player to take focus.
class BanditReadingSlot extends StatefulWidget {
  const BanditReadingSlot({super.key});

  // Asset swap pattern (PR #82 precedent): code + pubspec move to
  // the new versioned filenames together; the previous version's
  // files are removed in the same change.
  static const String loopAsset = 'assets/images/bandit_reading_loop_v9.webp';
  static const String posterAsset =
      'assets/images/bandit_reading_poster_v8.png';

  /// Round 4 slot width: 240 × 1.175 = 282dp. At 360dp wide this
  /// still leaves 39dp of page margin on each side.
  static const double slotWidth = 282;

  /// The reading frame's aspect (width / height): the poster PNG
  /// and the loop WebP are 832×992, the same frame the v3–v8
  /// assets were built to.
  static const double frameAspect = 832 / 992;

  /// The slot's exact rendered height at [slotWidth]:
  /// 282 × 992 / 832 ≈ 336.2dp. Home's overlap stack reserves
  /// against this number.
  static const double slotHeight = slotWidth * 992 / 832;

  @override
  State<BanditReadingSlot> createState() => _BanditReadingSlotState();
}

class _BanditReadingSlotState extends State<BanditReadingSlot> {
  bool _precached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precached) return;
    _precached = true;
    if (!_slotMotionEnabled(context)) return;
    // Decode the animation up front so the first frame paints
    // instantly. The display-time errorBuilder covers a failed
    // asset.
    precacheImage(const AssetImage(BanditReadingSlot.loopAsset), context)
        .catchError((_) {});
  }

  Widget _still() => Image.asset(
        BanditReadingSlot.posterAsset,
        fit: BoxFit.contain,
        semanticLabel: kCoachName,
        errorBuilder: (_, _, _) => const CoachMascotFigure(height: 210),
      );

  @override
  Widget build(BuildContext context) {
    final figure = _slotMotionEnabled(context)
        ? Image.asset(
            BanditReadingSlot.loopAsset,
            fit: BoxFit.contain,
            semanticLabel: kCoachName,
            errorBuilder: (_, _, _) => _still(),
          )
        : _still();
    return Align(
      key: const ValueKey('bandit_reading_slot'),
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: SizedBox(
        width: BanditReadingSlot.slotWidth,
        height: BanditReadingSlot.slotHeight,
        child: figure,
      ),
    );
  }
}
