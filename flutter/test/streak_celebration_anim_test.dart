import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_screen.dart';
import 'package:tabs_lab/src/features/home/streak_flame.dart';
import 'package:tabs_lab/src/features/settings/streak_sim.dart';

/// The rebuilt celebration sequence (Nov 18, 2026): in-place
/// entrance, grey flame + OLD count, ignition with the count
/// rolling UP old → new, week days loading in one by one, buttons
/// LAST, tap-to-skip, and the reduced-motion final state. These
/// tests run the sequence WITHOUT disableAnimations (except the
/// reduced-motion test itself) — the founder's acceptance
/// descriptions are "how it goes up from 20" and "the days load
/// in".
void main() {
  StreakCelebrationData data({
    int count = 21,
    int? previousCount = 20,
    bool milestone = false,
    int restoredIndex = -1,
  }) {
    return StreakCelebrationData(
      count: count,
      previousCount: previousCount,
      isMilestoneDay: milestone,
      week: [
        for (var i = 0; i < 7; i++)
          (
            label: ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'][i],
            counted: i <= 2,
            isToday: i == 2,
            restored: i == restoredIndex,
          ),
      ],
    );
  }

  Future<void> pumpCelebration(
    WidgetTester tester,
    StreakCelebrationData d, {
    bool reducedMotion = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: reducedMotion
            ? (context, child) => MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: child!,
              )
            : null,
        home: StreakCelebrationScreen(data: d, nickname: 'Tyson'),
      ),
    );
    await tester.pump();
  }

  double buttonsOpacity(WidgetTester tester) {
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(const Key('celebrationYay')),
            matching: find.byType(Opacity),
          )
          .first,
    );
    return opacity.opacity;
  }

  double weekDayOpacity(WidgetTester tester, int i) =>
      tester.widget<Opacity>(find.byKey(Key('celebrationWeekDay_$i'))).opacity;

  group('ignition sequence', () {
    testWidgets('start state: grey flame + the OLD count, week and '
        'buttons not yet in', (tester) async {
      await pumpCelebration(tester, data());
      final flame = tester.widget<StreakFlame>(find.byType(StreakFlame));
      expect(flame.lit, isFalse);
      // The OLD count is what reads before ignition.
      expect(
        (tester.widget<Text>(find.byKey(const Key('celebrationOldCount'))))
            .data,
        '20',
      );
      expect(weekDayOpacity(tester, 0), 0.0);
      expect(weekDayOpacity(tester, 6), 0.0);
      expect(buttonsOpacity(tester), 0.0);
    });

    testWidgets('count-up beat: at ignition the count rolls UP '
        'from old to new, then rests as the plain settled count', (
      tester,
    ) async {
      await pumpCelebration(tester, data());
      // Mid-roll (t ≈ 0.41 of 2.2 s): flame lit, both counts in
      // the roll stack.
      await tester.pump(const Duration(milliseconds: 900));
      final flame = tester.widget<StreakFlame>(find.byType(StreakFlame));
      expect(flame.lit, isTrue);
      expect(find.byKey(const Key('celebrationOldCount')), findsOneWidget);
      expect(
        (tester.widget<Text>(find.byKey(const Key('celebrationCount')))).data,
        '21',
      );
      // After the roll window the stack is gone: the plain settled
      // count remains.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('celebrationOldCount')), findsNothing);
      expect(
        (tester.widget<Text>(find.byKey(const Key('celebrationCount')))).data,
        '21',
      );
    });

    testWidgets('week-row stagger: the days load in ONE BY ONE, '
        'left to right', (tester) async {
      await pumpCelebration(tester, data());
      // t ≈ 1500 ms: day 0's window (1276–1452 ms) has completed;
      // day 6's window (1870–2046 ms) has not started.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(weekDayOpacity(tester, 0), 1.0);
      expect(weekDayOpacity(tester, 6), 0.0);
      // By the end of the sequence every day is in.
      await tester.pump(const Duration(milliseconds: 800));
      for (var i = 0; i < 7; i++) {
        expect(weekDayOpacity(tester, i), 1.0, reason: 'day $i');
      }
    });

    testWidgets('buttons last + skip: a tap during the sequence '
        'jumps to the final state, then LET\'S GO! dismisses', (tester) async {
      await pumpCelebration(tester, data());
      await tester.pump(const Duration(milliseconds: 500));
      expect(buttonsOpacity(tester), 0.0);
      // Tap anywhere: skip. The buttons are now fully in and live.
      await tester.tap(find.byType(StreakCelebrationScreen));
      await tester.pump();
      expect(find.byType(StreakCelebrationScreen), findsOneWidget);
      expect(buttonsOpacity(tester), 1.0);
      expect(find.text("LET'S GO!"), findsOneWidget);
      await tester.tap(find.byKey(const Key('celebrationYay')));
      await tester.pumpAndSettle();
      expect(find.byType(StreakCelebrationScreen), findsNothing);
    });

    testWidgets('reduced motion: the final state from the first '
        'frame — settled count, week in, buttons live', (tester) async {
      await pumpCelebration(tester, data(), reducedMotion: true);
      expect(find.byKey(const Key('celebrationOldCount')), findsNothing);
      expect(
        (tester.widget<Text>(find.byKey(const Key('celebrationCount')))).data,
        '21',
      );
      final flame = tester.widget<StreakFlame>(find.byType(StreakFlame));
      expect(flame.lit, isTrue);
      expect(weekDayOpacity(tester, 6), 1.0);
      expect(buttonsOpacity(tester), 1.0);
      await tester.tap(find.byKey(const Key('celebrationYay')));
      await tester.pumpAndSettle();
      expect(find.byType(StreakCelebrationScreen), findsNothing);
    });

    testWidgets('share affordance re-proof with the sequence '
        'running: real path shows the share icon; the SIM shows '
        'neither share affordance', (tester) async {
      await pumpCelebration(tester, data());
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('celebrationShareIcon')), findsOneWidget);
    });
  });

  group('old-count provenance', () {
    test('fromCompletion carries the run ending yesterday as the '
        'roll start', () {
      final state = StreakState(
        seeded: true,
        seededCurrent: 0,
        seededBest: 68,
        countedDays: {'2026-11-15', '2026-11-16', '2026-11-17', '2026-11-18'},
        lastEvaluatedDay: '2026-11-18',
        accrualMonth: '2026-11',
      );
      final d = StreakCelebrationData.fromCompletion(
        result: const StreakCompletionResult(
          newCount: 4,
          bridgedDays: [],
          freezeUsedKinds: {},
          brokeStreak: false,
          earnedLanded: false,
          isMilestone: false,
        ),
        state: state,
        now: DateTime(2026, 11, 18, 12),
      );
      expect(d.count, 4);
      expect(d.oldCount, 3);
    });

    test('the SIM preview data rolls up from the settled count', () {
      final d = StreakSimEntry.buildPreviewData(
        currentCount: 20,
        now: DateTime(2026, 11, 18, 12),
      );
      expect(d.count, 21);
      expect(d.oldCount, 20);
    });

    test('a construction without previousCount defaults to the '
        'one-step roll', () {
      const d = StreakCelebrationData(
        count: 9,
        week: [],
        isMilestoneDay: false,
      );
      expect(d.oldCount, 8);
    });
  });
}
