import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:video_player/video_player.dart';

/// Home redesign — the Bandit reading slot in the Home body column:
/// centered. Plays the approved reading-loop video (muted, looping,
/// no controls, auto-play on build) when motion is allowed; under
/// reduced motion it shows the poster still and never starts
/// playback. The still path reuses [CoachMascotFigure] — the mascot
/// widgets are reused, never forked.
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
/// Home polish round 5 — the loop asset is v5: same deterministic
/// pipeline, same frame/timing/breathing/gaze as v4, except the
/// page-side paw now REACHES to the turning page's corner before
/// the curl starts, follows the leaf through the first ~60% of
/// the flip, then returns home (frames 146–186 of 336). Geometry
/// and slot size are unchanged from round 4.
class BanditReadingSlot extends StatefulWidget {
  const BanditReadingSlot({super.key});

  // Asset swap pattern (PR #82 precedent): code + pubspec move to
  // the new versioned filenames together; the previous version's
  // files are removed in the same change.
  static const String videoAsset = 'assets/videos/bandit_reading_loop_v5.mp4';
  static const String posterAsset =
      'assets/images/bandit_reading_poster_v5.png';

  /// Round 4 slot width: 240 × 1.175 = 282dp. At 360dp wide this
  /// still leaves 39dp of page margin on each side.
  static const double slotWidth = 282;

  /// The reading frame's aspect (width / height): the v3 frame —
  /// poster PNG and loop MP4 alike — is 832×992, and v4/v5 are
  /// built to the same frame.
  static const double frameAspect = 832 / 992;

  /// The slot's exact rendered height at [slotWidth]:
  /// 282 × 992 / 832 ≈ 336.2dp. Home's overlap stack reserves
  /// against this number.
  static const double slotHeight = slotWidth * 992 / 832;

  @override
  State<BanditReadingSlot> createState() => _BanditReadingSlotState();
}

class _BanditReadingSlotState extends State<BanditReadingSlot> {
  VideoPlayerController? _controller;
  bool _videoReady = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Reduced motion: poster still only — playback never starts.
    if (animationsDisabled(context)) return;
    // Widget tests (FLUTTER_TEST) never start playback either: the
    // platform video channel is absent there (the CoachMascotFigure
    // motion gate's precedent).
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final controller =
          VideoPlayerController.asset(BanditReadingSlot.videoAsset);
      _controller = controller;
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
      setState(() => _videoReady = true);
    } catch (_) {
      // Asset or platform unavailable: the poster/still path stands.
      if (mounted) setState(() => _videoReady = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = animationsDisabled(context);
    return Align(
      key: const ValueKey('bandit_reading_slot'),
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: SizedBox(
        width: BanditReadingSlot.slotWidth,
        child: reduced
            ? Image.asset(
                BanditReadingSlot.posterAsset,
                fit: BoxFit.contain,
                semanticLabel: kCoachName,
                errorBuilder: (_, _, _) =>
                    const CoachMascotFigure(height: 210),
              )
            : (_videoReady && _controller != null
                ? AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio == 0
                        ? 1
                        : _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  )
                : Image.asset(
                    BanditReadingSlot.posterAsset,
                    fit: BoxFit.contain,
                    semanticLabel: kCoachName,
                    errorBuilder: (_, _, _) =>
                        const CoachMascotFigure(height: 210),
                  )),
      ),
    );
  }
}
