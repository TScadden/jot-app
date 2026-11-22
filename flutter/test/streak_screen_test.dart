import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';

/// Streak screen (Lab package Nov 4, 2026; release line VC 100115)
/// — the Streak detail screen renders the engine's real state
/// (hero, Streaks rows, Restore status, History with a visibly
/// marked restored day), and the Home streak pills are the tap
/// target that opens it with the settled state.
void main() {
  DateTime at(int y, int m, int d) => DateTime(y, m, d, 12);

  /// A live run: Oct 28 – Nov 4 counted, Nov 2 restored by
  /// November's save, seeded best 12 (range unknown).
  StreakState savedDayState() {
    var s = streakSeed(current: 5, best: 12, now: at(2026, 11, 1));
    // Counted Oct 28 – Nov 1 after seeding; Nov 2 missed, Nov 3
    // open restores it; Nov 4 open continues. Run = 8 days.
    s = streakEvaluate(s, at(2026, 11, 3));
    s = streakEvaluate(s, at(2026, 11, 4));
    return s;
  }

  Future<void> pumpScreen(WidgetTester tester, StreakState s) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: StreakScreen(state: s, now: at(2026, 11, 4))),
    );
    await tester.pump();
  }

  testWidgets('screen renders hero, sections, and the marked restored day',
      (tester) async {
    final s = savedDayState();
    expect(s.restoredDays, contains('2026-11-02'));
    await pumpScreen(tester, s);

    // Header + hero.
    expect(find.text('Streak'), findsOneWidget);
    expect(find.byKey(const Key('streakHeroNumber')), findsOneWidget);
    expect((tester.widget<Text>(find.byKey(const Key('streakHeroNumber')))).data,
        '8');
    expect(find.text('day streak!'), findsOneWidget);
    expect(find.text('Best 12 days'), findsOneWidget);
    // Juno C6: the hero reads as one value. (Asserted now, while
    // the hero is in the ListView's built region — the scroll below
    // disposes it.)
    expect(find.bySemanticsLabel('8 day streak'), findsOneWidget);

    // Streaks rows.
    expect(find.text('Current Streak'), findsOneWidget);
    expect(find.text('8 days'), findsOneWidget);
    expect(find.text('Longest Streak'), findsOneWidget);
    expect(find.text('12 days'), findsOneWidget);

    // Streak Goal (§3a spoiled variant) — scroll it into the lazy
    // ListView's built region first.
    await tester.scrollUntilVisible(
      find.byKey(const Key('streakGoalCopy')),
      120,
    );
    await tester.pump();
    // Streak Goal (§3a spoiled variant): a freeze was used in
    // November, so the goal copy is the spoiled-month form and the
    // §3b progress row is hidden. (Asserted NOW, while the goal
    // card is in the built region — scrolling on disposes it.)
    expect(
      find.text("A freeze was used in November, so there's no extra "
          'freeze to earn this month. Your next chance starts in '
          'December.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('streakGoalProgress')), findsNothing);
    // Streak Freeze (Juno §4a, used variant): November's monthly
    // freeze is used; total available cover is 0 of 2.
    await tester.scrollUntilVisible(
      find.byKey(const Key('streakFreezeStatus')),
      120,
    );
    await tester.pump();
    expect(find.byKey(const Key('streakFreezeStatus')), findsOneWidget);
    expect(
      find.text('Your free monthly freeze for November has been used. '
          'You have 0 of 2 freezes available. A freeze can cover one '
          'missed day automatically when you have one available.'),
      findsOneWidget,
    );

    // History: November, the restored day is marked, legend shown.
    // (The calendar sits below the fold in the lazy ListView —
    // scroll it into the built region first.)
    await tester.scrollUntilVisible(
      find.byKey(const Key('streakRestoredDay-2026-11-02')),
      120,
    );
    await tester.pump();
    expect(find.text('History'), findsOneWidget);
    expect(find.text('November'), findsOneWidget);
    // Juno string 11: the month count is streak days (Nov 1–4).
    expect(find.text('4 streak days'), findsOneWidget);
    expect(
      find.byKey(const Key('streakRestoredDay-2026-11-02')),
      findsOneWidget,
    );
    expect(
      find.text('A day with a snowflake was covered by a freeze.'),
      findsOneWidget,
    );
    // Juno C6: the covered day is identifiable without color.
    expect(
      find.bySemanticsLabel('November 2, covered by a freeze'),
      findsOneWidget,
    );
  });

  testWidgets('freeze status shows the ready grant in a fresh month',
      (tester) async {
    final s = streakSeed(current: 3, best: 3, now: at(2026, 11, 4));
    await pumpScreen(tester, s);
    await tester.scrollUntilVisible(
      find.byKey(const Key('streakFreezeStatus')),
      120,
    );
    await tester.pump();
    expect(
      find.text('Your free monthly freeze is ready for November. '
          'You have 1 of 2 freezes available. A freeze can cover one '
          'missed day automatically when you have one available.'),
      findsOneWidget,
    );
    // No covered day this month → no marked cell, no legend.
    expect(
      find.byKey(const Key('streakRestoredDay-2026-11-02')),
      findsNothing,
    );
    expect(
      find.text('A day with a snowflake was covered by a freeze.'),
      findsNothing,
    );
  });

  testWidgets('longest streak range caption shows when the range is known',
      (tester) async {
    final s = streakSeed(current: 8, best: 8, now: at(2026, 9, 8));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: StreakScreen(state: s, now: at(2026, 9, 8))),
    );
    await tester.pump();
    expect(find.text('Sep 1–8'), findsOneWidget);
    expect(find.text('Best 8 days'), findsOneWidget);
  });

  testWidgets('tapping either Home streak pill fires onStreakTap',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeStreakRow(
            currentStreak: 7,
            animateCountUps: false,
            onStreakTap: () => taps++,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('homeStreakPills')));
    expect(taps, 1);
  });

  testWidgets('the pills push the streak screen end to end',
      (tester) async {
    // Seed the store the way Home's load does.
    final disk = <String, String>{};
    final store = StreakStore.instance;
    store.debugReset();
    store.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async {
        disk[key] = value;
      },
      delete: (key) async {
        disk.remove(key);
      },
    );
    final settled = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 6,
      seedBest: 12,
      seedStateJson: null,
      now: DateTime.now(),
    );
    expect(settled.seeded, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => HomeStreakRow(
              currentStreak: 6,
              animateCountUps: false,
              onStreakTap: () =>
                  StreakScreen.openWith(context, state: settled),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('homeStreakPills')));
    await tester.pumpAndSettle();
    expect(find.byType(StreakScreen), findsOneWidget);
    expect(find.text('Best 12 days'), findsOneWidget);
  });
}
