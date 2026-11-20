import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
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
      // Added scope (Nov 19, 2026): the current pill's flame is
      // the streak screen's icon, never the 🔥 emoji text; the
      // best pill keeps its trophy glyph.
      expect(find.text('🔥'), findsNothing);
      expect(find.byIcon(Icons.local_fire_department), findsOneWidget);
      expect(find.text('🏆'), findsOneWidget);
    });

    testWidgets('unwired streaks show "--", never invented numbers',
        (tester) async {
      await _pumpStreakRow(tester);
      // Two streak pills. Round 34: with zero active counters the
      // counter slot renders NOTHING (no placeholder label/count).
      expect(find.text('--'), findsNWidgets(2));
      expect(find.text('Days'), findsNothing);
    });
  });

  group('current-streak pill flame (added scope, Nov 19, 2026)', () {
    // The pill flame in both layouts (HomeStreakStack +
    // HomeStreakRow): no 🔥 text glyph anywhere in the subtree,
    // the streak screen's fire icon present, and its treatment
    // driven by the settled today-complete flag — lit #FF6A3D with
    // no dimming wrappers, grey #8E97B8 desaturated at 45% opacity
    // while today is incomplete (StreakFlame's exact treatment).

    Finder flameIn(Finder host) => find.descendant(
          of: host,
          matching: find.byIcon(Icons.local_fire_department),
        );

    void expectLit(WidgetTester tester, Finder host) {
      final flame = flameIn(host);
      expect(flame, findsOneWidget);
      expect(
        find.descendant(of: host, matching: find.text('🔥')),
        findsNothing,
      );
      final icon = tester.widget<Icon>(flame);
      expect(icon.icon, Icons.local_fire_department);
      expect(icon.color, StreakPillFlame.litColor,
          reason: 'lit flame is StreakFlame orange #FF6A3D');
      expect(icon.size, 15);
      // Lit: no opacity / desaturation wrappers around the icon.
      expect(
        find.ancestor(of: flame, matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(
        find.ancestor(of: flame, matching: find.byType(ColorFiltered)),
        findsNothing,
      );
    }

    void expectUnlit(WidgetTester tester, Finder host) {
      final flame = flameIn(host);
      expect(flame, findsOneWidget);
      expect(
        find.descendant(of: host, matching: find.text('🔥')),
        findsNothing,
      );
      final icon = tester.widget<Icon>(flame);
      expect(icon.color, StreakPillFlame.unlitColor,
          reason: 'unlit flame icon is StreakFlame grey #8E97B8');
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: flame, matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, StreakPillFlame.unlitOpacity,
          reason: 'unlit flame is dimmed to 45% opacity');
      expect(opacity.opacity, 0.45);
      expect(
        find.ancestor(of: flame, matching: find.byType(ColorFiltered)),
        findsOneWidget,
        reason: 'unlit flame is desaturated (StreakFlame grey matrix)',
      );
    }

    Future<void> pumpStack(WidgetTester tester, {required bool lit}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: NotelColors.background,
            body: HomeStreakStack(
              currentStreak: 18,
              bestStreak: 68,
              animateCountUps: false,
              streakTodayComplete: lit,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> pumpRow(WidgetTester tester, {required bool lit}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: NotelColors.background,
            body: HomeStreakRow(
              currentStreak: 18,
              bestStreak: 68,
              animateCountUps: false,
              streakTodayComplete: lit,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('stack: lit flame when today is complete', (tester) async {
      await pumpStack(tester, lit: true);
      expectLit(tester, find.byType(HomeStreakStack));
      // The trophy pill is untouched by the swap.
      expect(find.text('🏆'), findsOneWidget);
    });

    testWidgets('stack: grey flame while today is incomplete',
        (tester) async {
      await pumpStack(tester, lit: false);
      expectUnlit(tester, find.byType(HomeStreakStack));
      expect(find.text('🏆'), findsOneWidget);
    });

    testWidgets('row: lit flame when today is complete', (tester) async {
      await pumpRow(tester, lit: true);
      expectLit(tester, find.byType(HomeStreakRow));
      expect(find.text('🏆'), findsOneWidget);
    });

    testWidgets('row: grey flame while today is incomplete', (tester) async {
      await pumpRow(tester, lit: false);
      expectUnlit(tester, find.byType(HomeStreakRow));
      expect(find.text('🏆'), findsOneWidget);
    });

    testWidgets('default (no settled state passed) renders the grey flame',
        (tester) async {
      await _pumpStreakRow(tester);
      expectUnlit(tester, find.byType(HomeStreakRow));
    });
  });

  group('formatSleepMinutes (round 17b — native TodayScreen.kt format)', () {
    test('522 minutes renders as 8h42m', () {
      expect(formatSleepMinutes(522), '8h42m');
    });

    test('exactly one hour renders as 1h0m', () {
      expect(formatSleepMinutes(60), '1h0m');
    });

    test('under an hour renders as minutes only', () {
      expect(formatSleepMinutes(45), '45m');
      expect(formatSleepMinutes(59), '59m');
    });

    testWidgets('sleep cell shows hours+minutes, not total minutes',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: NotelColors.background,
            body: const VitalsStrip(
              vitals: TodayVitals(sleepMinutes: 522),
              // Instant render — no animation timing involved.
              animateCountUps: false,
            ),
          ),
        ),
      );
      expect(find.text('8h42m'), findsOneWidget);
      expect(find.text('522'), findsNothing);
    });

    testWidgets('missing sleep still shows "--"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: NotelColors.background,
            body: const VitalsStrip(
              vitals: TodayVitals(sleepMinutes: null),
              animateCountUps: false,
            ),
          ),
        ),
      );
      expect(find.text('--'), findsWidgets);
    });
  });
}
