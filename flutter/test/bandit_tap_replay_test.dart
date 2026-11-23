import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/home/bandit_reading_slot.dart';

/// Regression tests for the founder report (Nov 23, 2026, 11:51 AM):
/// "Sometimes when I click on Bandit, to do the little animation
/// thing, it doesn't actually do it."
///
/// Root cause (proven against the Flutter 3.47.7 SDK source,
/// painting/image_stream.dart): a one-shot animation's
/// MultiFrameImageStreamCompleter DISPOSES its codec when the last
/// cycle finishes and keeps only the final frame (== the loop base
/// frame). The slot's per-tap ValueKey creates a new Image widget,
/// but Image.asset resolves through PaintingBinding.imageCache by
/// provider key, so the next tap re-attaches a listener to the same
/// dead completer: addListener can only resume playback while the
/// codec is alive, so the new listener is handed the static final
/// frame and nothing ever moves. The swap looks like a tap that
/// does nothing. Cache eviction under memory pressure drops the
/// dead entry and the next tap re-decodes and plays — the
/// founder's "sometimes".
///
/// These tests therefore observe PLAYBACK RESTART — completer
/// identity and real frame progression across a second
/// post-return tap — not just which asset path is in the tree
/// (the pre-existing v9 test asserts the path only, which is why
/// it could not catch this).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bandit tap replay', () {
    tearDown(() => debugBanditSlotMotionOverride = null);

    Image displayedImage(WidgetTester tester) =>
        tester.widget<Image>(find.descendant(
          of: find.byType(BanditReadingSlot),
          matching: find.byType(Image),
        ));

    String assetOf(WidgetTester tester) =>
        (displayedImage(tester).image as AssetImage).assetName;

    /// The completer the displayed image resolves to through the
    /// image cache. Two taps that share a completer share its
    /// playback state — a finished one-shot completer never
    /// replays.
    ImageStreamCompleter completerOf(WidgetTester tester) {
      final stream =
          displayedImage(tester).image.resolve(ImageConfiguration.empty);
      return stream.completer!;
    }

    /// Advances fake time in 100 ms steps, giving the real codec
    /// time to decode between frames.
    Future<void> step(WidgetTester tester, int steps) async {
      for (var i = 0; i < steps; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<Uint8List> posterBytes(WidgetTester tester) async {
      late Uint8List bytes;
      await tester.runAsync(() async {
        final data = await rootBundle.load(BanditReadingSlot.posterAsset);
        final codec =
            await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        final raw =
            await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        bytes = raw!.buffer.asUint8List();
      });
      return bytes;
    }

    /// Pixels differing from the poster by more than premultiply
    /// rounding (>2 per channel — the tolerance the v9 audit
    /// proved for identical frames). A frame mid-animation (gaze
    /// lifted, grin open, the hop's rigid translate) differs by
    /// tens of thousands of pixels; the base/final frame by ~0.
    int diffCount(Uint8List a, Uint8List b) {
      var n = 0;
      for (var i = 0; i < a.length; i += 4) {
        if ((a[i] - b[i]).abs() > 2 ||
            (a[i + 1] - b[i + 1]).abs() > 2 ||
            (a[i + 2] - b[i + 2]).abs() > 2 ||
            (a[i + 3] - b[i + 3]).abs() > 2) {
          n++;
        }
      }
      return n;
    }

    /// Converts emitted frames to RGBA bytes. Must run inside
    /// runAsync: toByteData is real engine async and a bare await
    /// of it in the fake-async test body never completes.
    Future<List<Uint8List>> framesOf(
        WidgetTester tester, List<ImageInfo> infos) async {
      final out = await tester.runAsync(() async {
        final bytes = <Uint8List>[];
        for (final info in infos) {
          final raw = await info.image
              .toByteData(format: ui.ImageByteFormat.rawRgba);
          bytes.add(raw!.buffer.asUint8List());
          info.dispose();
        }
        return bytes;
      });
      return out!;
    }

    /// One full tap cycle: tap, collect the frames the tap
    /// completer emits while fake time runs past the return
    /// timer, end back on the loop. Returns (completer, frames).
    Future<(ImageStreamCompleter, List<Uint8List>)> playOneTap(
        WidgetTester tester, Uint8List poster) async {
      await tester.tap(
          find.byKey(const ValueKey('bandit_reading_tap_target')));
      await tester.pump();
      expect(assetOf(tester), BanditReadingSlot.tapAsset,
          reason: 'the tap must swap the slot to the tap asset');
      final completer = completerOf(tester);
      final infos = <ImageInfo>[];
      final stream =
          displayedImage(tester).image.resolve(ImageConfiguration.empty);
      void listener(ImageInfo info, bool _) => infos.add(info);
      stream.addListener(ImageStreamListener(listener));
      // Step past the return timer (1.25 s fake) AND until the
      // completer has emitted the tap's full 15 stored frames.
      // Fixed step counts flake under load: WebP decode is real
      // async, so emission can lag fake time; the listener stays
      // attached after the return and keeps collecting until the
      // one-shot finishes (or the cap proves it never will).
      var steps = 0;
      while (steps < 40 && infos.length < 15) {
        await step(tester, 1);
        steps++;
      }
      stream.removeListener(ImageStreamListener(listener));
      // If all frames landed before the return timer, ride out
      // the rest of the tap duration.
      var settle = 0;
      while (assetOf(tester) == BanditReadingSlot.tapAsset && settle < 20) {
        await step(tester, 1);
        settle++;
      }
      await tester.pump();
      expect(assetOf(tester), BanditReadingSlot.loopAsset,
          reason: 'after tapDuration the slot must be back on the loop');
      final frames = await framesOf(tester, infos);
      return (completer, frames);
    }

    testWidgets('a second idle tap replays the animation', (tester) async {
      debugBanditSlotMotionOverride = true;
      final poster = await posterBytes(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BanditReadingSlot()),
      ));
      expect(assetOf(tester), BanditReadingSlot.loopAsset);

      // First tap: plays in full (sanity — this worked even before
      // the fix, because didChangeDependencies precaches the tap
      // asset and parks its completer with the codec alive).
      final (completer1, frames1) = await playOneTap(tester, poster);
      expect(frames1.length, greaterThan(3),
          reason: 'first tap must emit a real multi-frame playback');
      expect(frames1.any((f) => diffCount(f, poster) > 1000), isTrue,
          reason: 'first tap must reach frames that visibly differ '
              'from the base frame (gaze/grin/hop)');

      // Second tap, after the slot returned to the loop: must
      // replay from the start, not sit on the finished completer's
      // final frame.
      final (completer2, frames2) = await playOneTap(tester, poster);
      expect(identical(completer2, completer1), isFalse,
          reason: 'the second tap resolved to the SAME image-stream '
              'completer as the first — a finished one-shot completer '
              'has disposed its codec and can never replay; the tap '
              'asset must be evicted and re-decoded per play');
      expect(frames2.length, greaterThan(3),
          reason: 'second tap emitted ${frames2.length} frame(s) — '
              'a dead completer hands a new listener only its final '
              'static frame');
      expect(frames2.any((f) => diffCount(f, poster) > 1000), isTrue,
          reason: 'second tap never left the base frame — the '
              'animation did not play (the founder bug)');

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('every repeated tap across cycles gets a fresh completer',
        (tester) async {
      debugBanditSlotMotionOverride = true;
      final poster = await posterBytes(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BanditReadingSlot()),
      ));
      final seen = <ImageStreamCompleter>{};
      for (var cycle = 1; cycle <= 3; cycle++) {
        final (completer, frames) = await playOneTap(tester, poster);
        expect(seen.contains(completer), isFalse,
            reason: 'tap #$cycle reused a previous completer — '
                'a used one-shot completer cannot replay');
        seen.add(completer);
        expect(frames.any((f) => diffCount(f, poster) > 1000), isTrue,
            reason: 'tap #$cycle never left the base frame');
      }
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('tap still replays after a parent rebuild', (tester) async {
      debugBanditSlotMotionOverride = true;
      final poster = await posterBytes(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BanditReadingSlot()),
      ));
      final (completer1, _) = await playOneTap(tester, poster);

      // Home rebuilds around the slot (new ancestor tree, same
      // slot) — the state and the image cache carry over.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ColoredBox(
            color: Colors.black,
            child: BanditReadingSlot(),
          ),
        ),
      ));
      await step(tester, 2);

      final (completer2, frames2) = await playOneTap(tester, poster);
      expect(identical(completer2, completer1), isFalse,
          reason: 'after a rebuild the tap still hit the finished '
              'completer and could not replay');
      expect(frames2.any((f) => diffCount(f, poster) > 1000), isTrue,
          reason: 'tap after rebuild never left the base frame');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('guard: re-tap during the second playback is ignored',
        (tester) async {
      debugBanditSlotMotionOverride = true;
      final poster = await posterBytes(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BanditReadingSlot()),
      ));
      await playOneTap(tester, poster); // first cycle

      await tester.tap(
          find.byKey(const ValueKey('bandit_reading_tap_target')));
      await tester.pump();
      expect(assetOf(tester), BanditReadingSlot.tapAsset);
      expect(displayedImage(tester).key, const ValueKey('bandit_tap_2'));
      // Mid-playback re-tap: no restart, epoch unchanged.
      await tester.tap(
          find.byKey(const ValueKey('bandit_reading_tap_target')));
      await tester.pump();
      expect(displayedImage(tester).key, const ValueKey('bandit_tap_2'),
          reason: 'taps during playback stay ignored after the fix');
      await step(tester, 16);
      expect(assetOf(tester), BanditReadingSlot.loopAsset);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });
}
