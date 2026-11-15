import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/home/bandit_reading_slot.dart';

/// VC 100137 — Bandit audio fix regression pin.
///
/// Founder report: opening Tabs paused his music/video in other
/// apps. Cause: the reading loop's VideoPlayerController was
/// constructed with NO VideoPlayerOptions, so mixWithOthers
/// defaulted to false and the (muted) player still took audio
/// focus. The fix exposes the options as
/// [BanditReadingSlot.videoPlayerOptions] and passes them at the
/// construction site; both halves are pinned here — the value, and
/// (source-level, in the repo's existing style) the construction
/// site's use of it, so removing the option from the construction
/// fails this test even though the field would still exist.
void main() {
  test('videoPlayerOptions mixes with others (no audio focus grab)', () {
    expect(BanditReadingSlot.videoPlayerOptions.mixWithOthers, isTrue);
  });

  test('the construction site passes videoPlayerOptions', () {
    final source = File('lib/src/features/home/bandit_reading_slot.dart')
        .readAsStringSync();
    expect(
      source,
      contains('videoPlayerOptions: BanditReadingSlot.videoPlayerOptions'),
      reason:
          'VideoPlayerController.asset must be constructed with the '
          'mixWithOthers options, or opening Home pauses other apps.',
    );
    expect(source, contains('mixWithOthers: true'));
  });
}
