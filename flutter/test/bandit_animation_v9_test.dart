import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/home/bandit_reading_slot.dart';

/// Bandit v9 (Nov 20, 2026) — guards for the remade reading loop
/// and the tap reaction.
///
/// The v8 loop was an H.264 mp4: its background was baked in (no
/// alpha) and its breathing was a pixel warp the founder rejected
/// on sight. The v9 assets are animated WebPs built from discrete
/// drawn frames over the transparent poster. The full frame-diff
/// audit lives with the build package; these tests pin the same
/// invariants in-repo so a future asset swap cannot silently
/// reintroduce a baked background, a warp, or a broken seam:
///
///  * the loop's every frame differs from the poster ONLY inside
///    the eye band (blink only — no breathing, no warp);
///  * blink-bottom frames have fully closed eyes (no white left
///    inside the eye ellipses);
///  * both animations keep transparent corners in every frame;
///  * the tap animation starts and ends on the poster frame
///    exactly, and its length matches the slot's return timer;
///  * VC 100137's audio-focus fix is structural now: the slot has
///    no video player at all, so nothing can take audio focus.
const _eyeBand = (x0: 270, x1: 560, y0: 264, y1: 378);
const _eyes = [
  (cx: 320.20, cy: 320.99, rx: 44.03, ry: 50.85),
  (cx: 510.87, cy: 321.36, rx: 43.50, ry: 49.80),
];

Future<Uint8List> _rgba(ui.Image image) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return bytes!.buffer.asUint8List();
}

/// Decode comparison between two Skia decodes (poster PNG vs
/// animation WebP). The offline audit (libwebp) proves the assets
/// byte-exact; in-engine, toByteData(rawRgba) returns PREMULTIPLIED
/// pixels, and Skia's PNG and WebP paths round the semi-transparent
/// silhouette pixels (6,145 of them) slightly differently. So:
/// fully transparent and fully opaque pixels must match EXACTLY
/// (a warp moves opaque pixels by whole colour values — that is
/// what this guard exists to catch), while pixels that are
/// semi-transparent on either side may differ by at most 2 per
/// channel. Returns (hardViolations, softMaxDiff).
(int, int) _decodeDiffs(Uint8List a, Uint8List b, int w, int h,
    {bool skipEyeBand = false}) {
  var hard = 0;
  var softMax = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (skipEyeBand &&
          x >= _eyeBand.x0 &&
          x < _eyeBand.x1 &&
          y >= _eyeBand.y0 &&
          y < _eyeBand.y1) {
        continue;
      }
      final i = (y * w + x) * 4;
      final aa = a[i + 3];
      final ba = b[i + 3];
      final semi = (aa > 0 && aa < 255) || (ba > 0 && ba < 255);
      var d = (aa - ba).abs();
      for (var c = 0; c < 3; c++) {
        final dc = (a[i + c] - b[i + c]).abs();
        if (dc > d) d = dc;
      }
      if (d == 0) continue;
      if (!semi) {
        hard++;
      } else if (d > softMax) {
        softMax = d;
      }
    }
  }
  return (hard, softMax);
}

/// Asserts two decodes agree under the rule above.
void _expectSameDecode(Uint8List a, Uint8List b, int w, int h,
    {bool skipEyeBand = false, required String reason}) {
  final (hard, softMax) =
      _decodeDiffs(a, b, w, h, skipEyeBand: skipEyeBand);
  expect(hard, 0, reason: reason);
  expect(softMax, lessThanOrEqualTo(2),
      reason: 'semi-transparent silhouette pixels may only differ '
          'by premultiply rounding (<=2): $reason');
}

int _cornerAlphas(Uint8List px, int w, int h) {
  int at(int x, int y) => px[(y * w + x) * 4 + 3];
  return at(0, 0) + at(w - 1, 0) + at(0, h - 1) + at(w - 1, h - 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('VC 100137 is structural: the slot has no video player', () {
    final source = File('lib/src/features/home/bandit_reading_slot.dart')
        .readAsStringSync();
    expect(source, isNot(contains('video_player')),
        reason: 'The reading slot must never construct a video '
            'player — a player can take audio focus (VC 100137) '
            'and an mp4 cannot carry the alpha the v9 remake needs.');
    expect(source, isNot(contains('VideoPlayerController')));
    expect(source, isNot(contains('.mp4')));
  });

  test('loop WebP: blink-only frames, transparent corners, 14 s', () async {
    final posterData = await rootBundle.load(BanditReadingSlot.posterAsset);
    final posterCodec = await ui.instantiateImageCodec(
        posterData.buffer.asUint8List());
    final poster = await _rgba((await posterCodec.getNextFrame()).image);

    final data = await rootBundle.load(BanditReadingSlot.loopAsset);
    final codec =
        await ui.instantiateImageCodec(data.buffer.asUint8List());
    expect(codec.frameCount, 33,
        reason: 'libwebp stores the 37-entry blink timeline as 33 '
            'frames (duplicate frames merged); a different count '
            'means the asset was re-encoded or swapped.');
    var totalMs = 0;
    const blinkBottoms = {4, 12, 20, 28};
    for (var f = 0; f < codec.frameCount; f++) {
      final info = await codec.getNextFrame();
      totalMs += info.duration.inMilliseconds;
      final px = await _rgba(info.image);
      expect(info.image.width, 832);
      expect(info.image.height, 992);
      expect(_cornerAlphas(px, 832, 992), 0,
          reason: 'frame $f has a non-transparent corner — a baked '
              'background is back');
      _expectSameDecode(px, poster, 832, 992,
          skipEyeBand: true,
          reason: 'frame $f changes pixels outside the eye band — '
              'the warp (or any non-blink motion) is back');
      if (blinkBottoms.contains(f)) {
        var white = 0;
        for (final e in _eyes) {
          for (var y = (e.cy - e.ry).floor(); y < e.cy + e.ry; y++) {
            for (var x = (e.cx - e.rx).floor(); x < e.cx + e.rx; x++) {
              final dx = (x - e.cx) / e.rx;
              final dy = (y - e.cy) / e.ry;
              if (dx * dx + dy * dy > 1.0) continue;
              final i = (y * 832 + x) * 4;
              if (px[i] > 200 && px[i + 1] > 200 && px[i + 2] > 200) {
                white++;
              }
            }
          }
        }
        expect(white, 0,
            reason: 'blink-bottom frame $f must have fully closed '
                'eyes (drawn lids cover the whole eye)');
      }
    }
    expect(totalMs, inInclusiveRange(13990, 14010),
        reason: 'the loop is 14 s (encoder rounding may cost 1 ms)');
  });

  test('tap WebP: starts and ends on the poster frame, 1.25 s', () async {
    final posterData = await rootBundle.load(BanditReadingSlot.posterAsset);
    final posterCodec = await ui.instantiateImageCodec(
        posterData.buffer.asUint8List());
    final poster = await _rgba((await posterCodec.getNextFrame()).image);

    final data = await rootBundle.load(BanditReadingSlot.tapAsset);
    final codec =
        await ui.instantiateImageCodec(data.buffer.asUint8List());
    expect(codec.frameCount, 15,
        reason: 'the 30-frame tap timeline stores as 15 frames '
            '(holds merged); a different count means the asset '
            'was re-encoded or swapped.');
    var totalMs = 0;
    Uint8List? first;
    Uint8List? last;
    for (var f = 0; f < codec.frameCount; f++) {
      final info = await codec.getNextFrame();
      totalMs += info.duration.inMilliseconds;
      final px = await _rgba(info.image);
      expect(_cornerAlphas(px, 832, 992), 0,
          reason: 'tap frame $f has a non-transparent corner');
      first ??= px;
      last = px;
    }
    expect(totalMs, inInclusiveRange(1240, 1260));
    expect(totalMs - BanditReadingSlot.tapDuration.inMilliseconds,
        inInclusiveRange(-10, 10),
        reason: 'the slot returns to the loop on a Timer of '
            'tapDuration; the asset must match it');
    _expectSameDecode(first!, poster, 832, 992,
        reason: 'the tap animation must enter seamlessly from the '
            'loop base frame');
    _expectSameDecode(last!, poster, 832, 992,
        reason: 'the tap animation must exit seamlessly back to '
            'the loop base frame');
  });

  group('tap interaction', () {
    tearDown(() => debugBanditSlotMotionOverride = null);

    String assetOf(WidgetTester tester) {
      final image = tester.widget<Image>(find.descendant(
        of: find.byType(BanditReadingSlot),
        matching: find.byType(Image),
      ));
      return (image.image as AssetImage).assetName;
    }

    testWidgets('tap plays the reaction, ignores re-taps, returns',
        (tester) async {
      debugBanditSlotMotionOverride = true;
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BanditReadingSlot()),
      ));
      expect(assetOf(tester), BanditReadingSlot.loopAsset);

      await tester.tap(
          find.byKey(const ValueKey('bandit_reading_tap_target')));
      await tester.pump();
      expect(assetOf(tester), BanditReadingSlot.tapAsset);
      final playing = tester.widget<Image>(find.descendant(
        of: find.byType(BanditReadingSlot),
        matching: find.byType(Image),
      ));
      expect(playing.key, const ValueKey('bandit_tap_1'));

      // A second tap mid-playback is ignored — no restart.
      await tester.tap(
          find.byKey(const ValueKey('bandit_reading_tap_target')));
      await tester.pump();
      final stillPlaying = tester.widget<Image>(find.descendant(
        of: find.byType(BanditReadingSlot),
        matching: find.byType(Image),
      ));
      expect(stillPlaying.key, const ValueKey('bandit_tap_1'));

      // After the full tap duration the slot is back on the loop,
      // restarted from its base frame.
      await tester.pump(BanditReadingSlot.tapDuration);
      await tester.pump();
      expect(assetOf(tester), BanditReadingSlot.loopAsset);
      final looped = tester.widget<Image>(find.descendant(
        of: find.byType(BanditReadingSlot),
        matching: find.byType(Image),
      ));
      expect(looped.key, const ValueKey('bandit_loop_1'));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('reduced motion wins over the test override',
        (tester) async {
      debugBanditSlotMotionOverride = true;
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: BanditReadingSlot()),
        ),
      ));
      expect(assetOf(tester), BanditReadingSlot.posterAsset);
      await tester.tap(
          find.byKey(const ValueKey('bandit_reading_tap_target')));
      await tester.pump();
      expect(assetOf(tester), BanditReadingSlot.posterAsset,
          reason: 'reduced motion: poster only, taps do nothing');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('default test environment shows the poster only',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BanditReadingSlot()),
      ));
      expect(assetOf(tester), BanditReadingSlot.posterAsset);
      // Geometry is measured on the figure's rect (the convention
      // home_redesign_test uses): the slot widget itself spans the
      // column width, the figure inside it is the slot size.
      final figure = tester.getRect(find.descendant(
        of: find.byType(BanditReadingSlot),
        matching: find.byType(Image),
      ));
      expect(figure.width, BanditReadingSlot.slotWidth);
      expect(figure.height, closeTo(BanditReadingSlot.slotHeight, 0.6));
    });
  });
}
