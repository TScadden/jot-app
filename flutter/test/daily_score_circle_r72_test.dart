import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';

/// R72 — Home Daily Score header pairing shrink (founder: "make
/// the score icon and whatnot a little bit smaller on the home
/// page"). Mira's measured constants: face 44 → 38dp, face-to-label
/// gap 6 → 5dp, band chip padding h8/v3 → h7/v2; label and chip
/// text stay 10sp. This pins the header face size and the ≥48dp
/// tap target — the detail face (84, R71) and the history-list
/// face (34) are separate sizings and are NOT covered here.
void main() {
  testWidgets('R72: header face is 38dp and tap target stays 48dp',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DailyScoreCircle(score: 72)),
    ));

    // The header face renders at the R72 size.
    expect(tester.getSize(find.byType(DailyScoreFace)),
        const Size(38, 38));

    // The pairing as a whole still offers a ≥48dp tap target in
    // both dimensions (the ConstrainedBox absorbs the shrink).
    final pairing = tester.getSize(find.byType(DailyScoreCircle));
    expect(pairing.height, greaterThanOrEqualTo(48));
    expect(pairing.width, greaterThanOrEqualTo(48));

    // Shrunk, not redesigned: label and band chip still render.
    expect(find.text('72'), findsOneWidget);
    expect(find.text('Daily Score'), findsOneWidget);
    expect(find.text('Good'), findsOneWidget);
  });
}
