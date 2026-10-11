import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

Future<void> _pumpStrip(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        backgroundColor: NotelColors.background,
        body: VitalsStrip(),
      ),
    ),
  );
}

Future<void> _pumpStreakRow(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        backgroundColor: NotelColors.background,
        body: HomeStreakRow(),
      ),
    ),
  );
}

void main() {
  group('VitalsStrip', () {
    testWidgets('renders all four cells with icons', (tester) async {
      await _pumpStrip(tester);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.whatshot), findsOneWidget);
      expect(find.byIcon(Icons.edit), findsOneWidget);
      expect(find.byIcon(Icons.nightlight_round), findsOneWidget);
    });

    testWidgets('unwired biometrics show "--", never zeros or fake numbers',
        (tester) async {
      await _pumpStrip(tester);
      // Heart rate, calories, sleep: Health Connect not wired → "--".
      expect(find.text('--'), findsNWidgets(3));
      // No cell may render a bare "0" for a biometric.
      final zeroTexts = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => t.data == '0')
          .toList();
      // Exactly one "0" exists: the real log count (no logs in a fresh app).
      expect(zeroTexts.length, 1);
    });

    testWidgets('log count shows the real 0 (fresh app has no logs)',
        (tester) async {
      await _pumpStrip(tester);
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('has three dividers separating the four cells',
        (tester) async {
      await _pumpStrip(tester);
      final dividers = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) =>
              c.constraints?.maxHeight == 16 &&
              c.constraints?.maxWidth == 1)
          .toList();
      expect(dividers.length, 3);
    });

    testWidgets('icon colors match the native palette', (tester) async {
      await _pumpStrip(tester);
      Icon icon(IconData data) =>
          tester.widget<Icon>(find.byIcon(data));
      expect(icon(Icons.favorite).color, NotelColors.primary);
      expect(icon(Icons.whatshot).color, NotelColors.error);
      expect(icon(Icons.edit).color, NotelColors.success);
      expect(icon(Icons.nightlight_round).color, NotelColors.info);
    });
  });

  group('HomeStreakRow', () {
    testWidgets('renders both streak pills', (tester) async {
      await _pumpStreakRow(tester);
      expect(find.text('🔥'), findsOneWidget);
      expect(find.text('🏆'), findsOneWidget);
    });

    testWidgets('unwired streaks show "--", never invented numbers',
        (tester) async {
      await _pumpStreakRow(tester);
      // Two streak pills + counter label + counter number = 4 placeholders.
      expect(find.text('--'), findsNWidgets(4));
      expect(find.text('Days'), findsOneWidget);
    });
  });
}
