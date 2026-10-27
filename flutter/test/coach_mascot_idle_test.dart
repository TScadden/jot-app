import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';

/// Idle-cycle coverage for the full-body Bandit figure (and the avatar
/// after the shared _BlinkCycle refactor). Motion is hard-off under
/// FLUTTER_TEST, so these tests opt in through
/// [debugMascotMotionOverride]; reduced motion must still win.

Widget _wrap(Widget child, {required bool disableAnimations}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

String _figureAsset(WidgetTester tester) {
  final image = tester.widget<Image>(find.descendant(
    of: find.byType(CoachMascotFigure),
    matching: find.byType(Image),
  ));
  return (image.image as AssetImage).assetName;
}

String _avatarAsset(WidgetTester tester) {
  final image = tester.widget<Image>(find.descendant(
    of: find.byType(CoachMascotAvatar),
    matching: find.byType(Image),
  ));
  return (image.image as AssetImage).assetName;
}

/// Pumps in 100 ms steps until [probe] returns [want] or the step
/// budget runs out. Returns true when the wanted state was observed.
Future<bool> _pumpUntil(
  WidgetTester tester,
  String Function() probe,
  String want, {
  int maxSteps = 60,
}) async {
  for (var i = 0; i < maxSteps; i++) {
    if (probe() == want) return true;
    await tester.pump(const Duration(milliseconds: 100));
  }
  return probe() == want;
}

void main() {
  setUp(() {
    debugMascotMotionOverride = true;
  });
  tearDown(() {
    debugMascotMotionOverride = null;
  });

  testWidgets('figure blinks on the established cycle when motion is on',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const CoachMascotFigure(height: 96),
      disableAnimations: false,
    ));
    await tester.pump();
    expect(_figureAsset(tester), kCoachFullAsset);

    // Blink starts 4.0–5.0 s in; the blink frame must appear.
    final sawBlink = await _pumpUntil(
        tester, () => _figureAsset(tester), kCoachFullBlinkAsset);
    expect(sawBlink, isTrue,
        reason: 'figure never swapped to the blink frame');

    // Blink lasts ~180 ms; well within 400 ms the open frame is back
    // (the next blink cannot start for another 4 s).
    await tester.pump(const Duration(milliseconds: 400));
    expect(_figureAsset(tester), kCoachFullAsset);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('figure bob/sway move pixels but never the layout box',
      (tester) async {
    const figure = CoachMascotFigure(height: 96);
    await tester.pumpWidget(_wrap(figure, disableAnimations: false));
    await tester.pump();

    final boxSize = tester.getSize(find.byType(CoachMascotFigure));
    final imageFinder = find.descendant(
      of: find.byType(CoachMascotFigure),
      matching: find.byType(Image),
    );
    final topLeftAtRest = tester.getTopLeft(imageFinder);

    await tester.pump(const Duration(seconds: 2));
    final topLeftMidBob = tester.getTopLeft(imageFinder);

    // Bob is mid-cycle (dy between 0 and -2 px) and sway rotates a
    // whisper — the painted figure moved, the layout box did not.
    expect(topLeftMidBob, isNot(equals(topLeftAtRest)));
    expect((topLeftMidBob - topLeftAtRest).distance, lessThan(4.0));
    expect(tester.getSize(find.byType(CoachMascotFigure)), boxSize);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion renders the still even with the override on',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const CoachMascotFigure(height: 96),
      disableAnimations: true,
    ));
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(_figureAsset(tester), kCoachFullAsset);
    }
    // No idle-motion transforms are inserted at all.
    expect(
      find.descendant(
        of: find.byType(CoachMascotFigure),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without the override the FLUTTER_TEST gate keeps the still',
      (tester) async {
    debugMascotMotionOverride = null;
    await tester.pumpWidget(_wrap(
      const CoachMascotFigure(height: 96),
      disableAnimations: false,
    ));
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(_figureAsset(tester), kCoachFullAsset);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('avatar still blinks through the shared cycle',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const CoachMascotAvatar(size: 36),
      disableAnimations: false,
    ));
    await tester.pump();
    expect(_avatarAsset(tester), kCoachAvatarAsset);
    final sawBlink = await _pumpUntil(
        tester, () => _avatarAsset(tester), kCoachAvatarBlinkAsset);
    expect(sawBlink, isTrue,
        reason: 'avatar never swapped to the blink frame');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_avatarAsset(tester), kCoachAvatarAsset);
    await tester.pumpWidget(const SizedBox());
  });
}
