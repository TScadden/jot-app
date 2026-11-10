import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:video_player/video_player.dart';

/// Home redesign — the Bandit reading slot in the Home body column:
/// centered, ~240dp wide. Plays the approved reading-loop video
/// (muted, looping, no controls, auto-play on build) when motion is
/// allowed; under reduced motion it shows the poster still and never
/// starts playback. The still path reuses [CoachMascotFigure] — the
/// mascot widgets are reused, never forked.
class BanditReadingSlot extends StatefulWidget {
  const BanditReadingSlot({super.key});

  static const String videoAsset = 'assets/videos/bandit_reading_loop_v3.mp4';
  static const String posterAsset = 'assets/images/bandit_reading_poster_v3.png';

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
    return Center(
      key: const ValueKey('bandit_reading_slot'),
      child: SizedBox(
        width: 240,
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
