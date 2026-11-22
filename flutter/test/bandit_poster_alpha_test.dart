import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/home/bandit_reading_slot.dart';

/// Guard for the founder report of Nov 20, 2026: the Home reading
/// poster shipped as an opaque RGB PNG with the near-black studio
/// background baked in, so any non-default app background (dev-screen
/// background changer) showed Bandit inside a black rectangle. The
/// poster must keep a real alpha channel: fully transparent corners
/// and a substantial transparent share, with the subject itself
/// opaque. If a future asset swap re-bakes a background, this fails.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reading poster has transparent corners and real alpha variance',
      () async {
    final data = await rootBundle.load(BanditReadingSlot.posterAsset);
    final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final image = frame.image;
    expect(image.width, 832);
    expect(image.height, 992);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(bytes, isNotNull);
    final px = bytes!.buffer.asUint8List();

    int alphaAt(int x, int y) => px[(y * image.width + x) * 4 + 3];

    // All four corners fully transparent — no baked box.
    expect(alphaAt(0, 0), 0);
    expect(alphaAt(image.width - 1, 0), 0);
    expect(alphaAt(0, image.height - 1), 0);
    expect(alphaAt(image.width - 1, image.height - 1), 0);

    // Non-trivial alpha variance: a real cutout, not a solid frame.
    var transparent = 0;
    var opaque = 0;
    for (var i = 3; i < px.length; i += 4) {
      if (px[i] == 0) transparent++;
      if (px[i] == 255) opaque++;
    }
    final total = image.width * image.height;
    expect(transparent / total, greaterThan(0.25),
        reason: 'poster background must be transparent, not baked');
    expect(opaque / total, greaterThan(0.4),
        reason: 'the subject itself must stay fully opaque');
    // Subject centre (book/chair area) is opaque art.
    expect(alphaAt(416, 700), 255);
  });
}
