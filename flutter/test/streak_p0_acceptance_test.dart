import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/summary_completeness.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_screen.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/home/streak_share_card.dart';

/// P0 acceptance (streak celebration/count package, Nov 18, 2026):
/// the stage log's required tests for Defect A (today counted with
/// an incomplete summary — A1 legacy open-day adoption + A2 proxy
/// plan attestation) and Defect B (celebration vs streak-screen
/// count disagreement via equal-stamp adoption regression), plus
/// the share-card count reproduction.
///
/// Written against the base code FIRST (Bram's reproduction): the
/// A1 strip, the A2 absent-field, and the equal-stamp regression
/// tests FAIL on d06593fc and pass with the fix.
void main() {
  const medCat = 8;
  const moodCat = 6;
  const goalsCat = 4;

  // Wed Nov 18, 2026 — the founder's report day.
  final now = DateTime(2026, 11, 18, 19);
  final dayStart = DateTime(2026, 11, 18, 4);
  const today = '2026-11-18';
  const yesterday = '2026-11-17';

  Set<String> runEnding(String endDay, int length) {
    final end = DateTime.parse(endDay);
    return {
      for (var i = 0; i < length; i++)
        streakDayStr(end.subtract(Duration(days: i))),
    };
  }

  QuickLogEntry entry({
    required int id,
    required int cat,
    required String body,
    String chips = '[]',
    required DateTime at,
  }) =>
      QuickLogEntry(
        id: id,
        categoryId: cat,
        body: body,
        chips: chips,
        manualText: '',
        timestamp: at.millisecondsSinceEpoch,
      );

  QuickLogEntry checkIn() => entry(
        id: 100,
        cat: moodCat,
        body: 'Feeling: 1/5 Today',
        chips: jsonEncode(const [feelingCheckInTag]),
        at: DateTime(2026, 11, 18, 9),
      );

  /// A legacy (v1-era) day-level blob: today counted at app open,
  /// NO summary-completion record (the key does not exist yet in
  /// this blob — exactly what a pre-fix record looks like).
  String legacyBlobJson({
    required Set<String> counted,
    required String stamp,
    int seededCurrent = 27,
    int seededBest = 68,
  }) {
    final json = StreakState(
      seeded: true,
      seededCurrent: seededCurrent,
      seededBest: seededBest,
      countedDays: counted,
      lastEvaluatedDay: stamp,
      accrualMonth: '2026-11',
    ).toJson();
    json.remove('summaryCompletedDays');
    return jsonEncode(json);
  }

  late Map<String, String> disk;
  late Map<String, String> markers;
  late StreakStore store;
  late List<StreakCompletionResult> events;
  late SummaryCompletionWatcher watcher;

  Future<bool> push(int c, int b, String j, {int? purchasedFreezes}) async =>
      true;

  SummaryCompletionContext completeCtx(List<QuickLogEntry> entries) =>
      SummaryCompletionContext(
        plan: buildPlanForFeelingDay(
          feelingDayStart: dayStart,
          medications: const [],
          reminders: const [],
          habits: const [],
          localState: const TodayPlanLocalState(),
          entries: entries,
          medicationCategoryId: medCat,
          goalsCategoryId: goalsCat,
        ),
        planResolved: true,
        entries: entries,
        moodCategoryId: moodCat,
      );

  SummaryCompletionContext incompleteCtx() => SummaryCompletionContext(
        plan: buildPlanForFeelingDay(
          feelingDayStart: dayStart,
          medications: const [
            SummaryMedication(key: 'k1', name: 'MedA', dose: '5mg'),
          ],
          reminders: const [],
          habits: const [],
          localState: const TodayPlanLocalState(),
          entries: [checkIn()],
          medicationCategoryId: medCat,
          goalsCategoryId: goalsCat,
        ),
        planResolved: true,
        entries: [checkIn()],
        moodCategoryId: moodCat,
      );

  setUp(() {
    disk = {};
    markers = {};
    events = [];
    store = StreakStore.instance;
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
    watcher = SummaryCompletionWatcher(
      store: store,
      onCompletion: (r, s) => events.add(r),
    );
    watcher.debugSetMarkerStore(
      read: (key) async => markers[key],
      write: (key, value) async {
        markers[key] = value;
      },
    );
  });

  tearDown(() {
    watcher.dispose();
    store.debugReset();
  });

  group('P0 Defect A1 — legacy open-day adoption', () {
    test(
        'a legacy app-open-counted TODAY with an INCOMPLETE summary '
        'does not count after app open, and no celebration fires',
        () async {
      final legacy = legacyBlobJson(
        counted: runEnding(today, 27),
        stamp: today,
      );
      final s = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: legacy,
        now: now,
        push: push,
      );
      // The still-open day was never summary-completed: its legacy
      // counted mark is stripped; closed days are untouched.
      expect(s.countedDays, isNot(contains(today)));
      expect(s.countedDays, contains(yesterday));
      expect(s.countedDays, hasLength(26));
      expect(streakCurrent(s, now), 26);

      // Watcher evaluation with the day's summary INCOMPLETE
      // (check-in done, a med still remaining) fires nothing.
      final fired = await watcher.maybeFireSummaryCompletion(
        context: incompleteCtx(),
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: legacy,
        push: push,
        now: now,
      );
      expect(fired, isFalse);
      expect(events, isEmpty);
      expect(store.state!.countedDays, isNot(contains(today)));
    });

    test(
        'after the strip, completing the summary fires EXACTLY once '
        'and every surface reads the same count', () async {
      final legacy = legacyBlobJson(
        counted: runEnding(today, 27),
        stamp: today,
      );
      await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: legacy,
        now: now,
        push: push,
      );
      final entries = [checkIn()];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: completeCtx(entries),
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: legacy,
        push: push,
        now: now,
      );
      expect(fired, isTrue);
      expect(events, hasLength(1));
      // One-count-source pin: celebration count == store count ==
      // the count the streak screen renders from the same state.
      expect(events.single.newCount, 27);
      expect(streakCurrent(store.state!, now), 27);
      expect(store.state!.countedDays, contains(today));

      final again = await watcher.maybeFireSummaryCompletion(
        context: completeCtx(entries),
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: legacy,
        push: push,
        now: now,
      );
      expect(again, isFalse);
      expect(events, hasLength(1));
    });
  });

  group('P0 Defect B — adoption monotonicity', () {
    test(
        'post-completion regression: recordOpen against the STALE '
        'pre-completion blob (equal stamp) does not lose today',
        () async {
      // Morning: a v2 blob whose run ends yesterday (26), already
      // stamped today by the morning settle.
      final morning = legacyBlobJson(
        counted: runEnding(yesterday, 26),
        stamp: today,
        seededCurrent: 26,
      );
      await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 26,
        seedBest: 68,
        seedStateJson: morning,
        now: DateTime(2026, 11, 18, 9),
        push: push,
      );
      expect(streakCurrent(store.state!, now), 26);

      // Evening: the summary completes (its profile push is
      // fire-and-forget and, in the founder's case, never landed).
      final done = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: 26,
        seedBest: 68,
        seedStateJson: morning,
        now: now,
        summaryDay: dayStart,
        push: push,
      );
      expect(done.completion!.newCount, 27);
      expect(streakCurrent(store.state!, now), 27);

      // Next open: the server still holds the STALE morning blob
      // with an EQUAL stamp. The local completion must survive.
      final s = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 26,
        seedBest: 68,
        seedStateJson: morning,
        now: DateTime(2026, 11, 18, 20),
        push: push,
      );
      expect(s.countedDays, contains(today));
      expect(streakCurrent(s, now), 27);
    });
  });

  group('P0 Defect A2 — plan attestation shapes', () {
    // Mirrors Home's _evaluateSummaryCompletion plan construction
    // on the base code: decode the profile's lists, build the
    // feeling-day plan, attest planResolved as `profile != null`.
    bool homeBaseCompletes(Map<String, dynamic>? profile) {
      final entries = [checkIn()];
      TodayPlanData? plan;
      if (profile != null) {
        final meds = <SummaryMedication>[];
        for (final row
            in TabsBackend.decodeProfileList(profile['medications'])) {
          final med = SummaryMedication.fromBlobRow(row);
          if (med != null) meds.add(med);
        }
        final reminders = <SummaryReminder>[];
        final rows = TabsBackend.decodeProfileList(profile['reminders']);
        for (var i = 0; i < rows.length; i++) {
          final rem =
              SummaryReminder.fromBlobRow(rows[i], fallbackId: -(i + 1));
          if (rem != null) reminders.add(rem);
        }
        plan = buildPlanForFeelingDay(
          feelingDayStart: dayStart,
          medications: meds,
          reminders: reminders,
          habits: const [],
          localState: const TodayPlanLocalState(),
          entries: entries,
          medicationCategoryId: medCat,
          goalsCategoryId: goalsCat,
        );
      }
      return isSummaryComplete(
        feelingDayStart: dayStart,
        plan: plan,
        planResolved: profile != null,
        entries: entries,
        moodCategoryId: moodCat,
      );
    }

    test(
        'profile payload with the medications field ABSENT must not '
        'complete on the check-in alone', () {
      // A partial payload: profile object present, plan fields
      // missing. decodeProfileList(absent) == [] reads as a
      // plan-free day under the proxy attestation.
      expect(homeBaseCompletes(<String, dynamic>{}), isFalse);
    });

    test(
        'the founder\'s plan shape (daily peptide meds, a '
        'blank-frequency med, a PT reminder, check-in done, 4 items '
        'remaining) does NOT complete', () {
      final profile = <String, dynamic>{
        'medications': jsonEncode([
          {
            'id': 'm-bpc',
            'name': 'BPC-157',
            'dose': '0.05',
            'frequency': 'Once daily',
            'startDate': '2026-11-11',
            'endDate': 'Present',
            'isPresent': true,
            'isDeleted': false,
          },
          {
            'id': 'm-ss31',
            'name': 'SS-31',
            'dose': '0.05',
            'frequency': 'Once daily',
            'startDate': '2026-11-11',
            'endDate': 'Present',
            'isPresent': true,
            'isDeleted': false,
          },
          {
            'id': 'm-mots',
            'name': 'MOTS-c',
            'dose': '0.10',
            'frequency': 'Once daily',
            'startDate': '2026-11-11',
            'endDate': 'Present',
            'isPresent': true,
            'isDeleted': false,
          },
          {
            'id': 'm-desv',
            'name': 'Desvenlafaxine Succinate ER',
            'dose': '50 mg',
            'frequency': 'Once daily',
            'startDate': '2026-10-17',
            'endDate': 'Present',
            'isPresent': true,
            'isDeleted': false,
          },
          {
            // The blank-frequency med (Ivabradine): the stored row
            // carries frequency '' exactly as the app writes it.
            'id': 'm-iva',
            'name': 'Ivabradine',
            'dose': '7.5 mg',
            'frequency': '',
            'startDate': '2026-09-18',
            'endDate': 'Present',
            'isPresent': true,
            'isDeleted': false,
          },
        ]),
        'reminders': jsonEncode([
          {
            'id': 41,
            'title': 'PT exercises',
            'fixedHour': 10,
            'fixedMinute': 0,
            'isEnabled': true,
          },
        ]),
      };
      // Plan shape pin: every med (blank-frequency included) and
      // the PT reminder are planned; with Desvenlafaxine +
      // Ivabradine taken and the check-in done, exactly the
      // founder's 4 items remain (BPC-157, SS-31, MOTS-c, PT).
      final meds = <SummaryMedication>[];
      for (final row
          in TabsBackend.decodeProfileList(profile['medications'])) {
        final med = SummaryMedication.fromBlobRow(row);
        if (med != null) meds.add(med);
      }
      expect(
        meds.map((m) => m.name),
        containsAll([
          'BPC-157',
          'SS-31',
          'MOTS-c',
          'Desvenlafaxine Succinate ER',
          'Ivabradine',
        ]),
      );
      final entries = [
        entry(
          id: 1,
          cat: medCat,
          body: 'Took Desvenlafaxine Succinate ER 50 mg',
          at: DateTime(2026, 11, 18, 8),
        ),
        entry(
          id: 2,
          cat: medCat,
          body: 'Took Ivabradine 7.5 mg',
          at: DateTime(2026, 11, 18, 8),
        ),
        checkIn(),
      ];
      final reminders = <SummaryReminder>[];
      final rows = TabsBackend.decodeProfileList(profile['reminders']);
      for (var i = 0; i < rows.length; i++) {
        final rem = SummaryReminder.fromBlobRow(rows[i], fallbackId: -(i + 1));
        if (rem != null) reminders.add(rem);
      }
      final plan = buildPlanForFeelingDay(
        feelingDayStart: dayStart,
        medications: meds,
        reminders: reminders,
        habits: const [],
        localState: const TodayPlanLocalState(),
        entries: entries,
        medicationCategoryId: medCat,
        goalsCategoryId: goalsCat,
      );
      expect(plan.plannedCount, 6);
      expect(plan.remainingCount, 4);
      expect(
        isSummaryComplete(
          feelingDayStart: dayStart,
          plan: plan,
          planResolved: true,
          entries: entries,
          moodCategoryId: moodCat,
        ),
        isFalse,
      );
    });

    test(
        'genuinely empty LOADED inputs (fields present, empty) can '
        'complete on the check-in alone (plan-free user)', () {
      expect(
        homeBaseCompletes(<String, dynamic>{
          'medications': '[]',
          'reminders': '[]',
        }),
        isTrue,
      );
    });
  });

  group('share-card count reproduction', () {
    testWidgets(
        'real store completion 26 -> 27: the celebration share and '
        'the streak-screen share both render 27 (text + PNG name)',
        (tester) async {
      final morning = legacyBlobJson(
        counted: runEnding(yesterday, 26),
        stamp: today,
        seededCurrent: 26,
      );
      final done = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: 26,
        seedBest: 68,
        seedStateJson: morning,
        now: now,
        summaryDay: dayStart,
        push: push,
      );
      expect(done.completion!.newCount, 27);
      expect(streakCurrent(done.state, now), 27);

      File? handedOff;
      StreakShareService.debugSetShareFn(
        (file) async {
          handedOff = file;
        },
        tempDir: () async => Directory.systemTemp,
      );
      addTearDown(() => StreakShareService.debugSetShareFn(null));

      // ── Celebration share ──────────────────────────────────
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final celebData = StreakCelebrationData.fromCompletion(
        result: done.completion!,
        state: done.state,
        now: now,
      );
      expect(celebData.count, 27);
      int? sharedCount;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: child!,
          ),
          home: StreakCelebrationScreen(
            data: celebData,
            nickname: 'Tyson',
            shareFn: (key, count) async {
              sharedCount = count;
              return true;
            },
          ),
        ),
      );
      await tester.pump();
      expect(
        (tester.widget<Text>(find.byKey(const Key('shareCardCount')))).data,
        '27',
      );
      // The share affordance hands the settled count to the share
      // path.
      await tester.tap(find.byKey(const Key('celebrationShareIcon')));
      await tester.pump();
      expect(sharedCount, 27);
      // The PNG itself: rendered from the celebration's own card
      // boundary through the real share service (runAsync, the
      // codebase's capture pattern — toImage cannot complete in
      // the fake-async zone).
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      final celebKey = tester
          .widget<StreakShareCardHost>(find.byType(StreakShareCardHost))
          .boundaryKey;
      await tester.runAsync(() async {
        final ok = await StreakShareService.shareFromBoundary(
          celebKey,
          count: 27,
        );
        expect(ok, isTrue);
      });
      expect(handedOff, isNotNull);
      expect(handedOff!.path, contains('tabs_streak_share_27.png'));

      // ── Streak screen opened post-completion ───────────────
      handedOff = null;
      await tester.pumpWidget(
        MaterialApp(
          // Reduced motion for the capture, same as the celebration
          // half: the lit flame's flicker otherwise keeps the share
          // boundary perpetually dirty and toImage never completes.
          builder: (context, child) => MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: child!,
          ),
          home: StreakScreen(state: store.state!, now: now),
        ),
      );
      await tester.pump();
      expect(
        (tester.widget<Text>(find.byKey(const Key('shareCardCount')))).data,
        '27',
      );
      // The streak screen's share button calls shareFromBoundary
      // with exactly this host's count (streakCurrent of the same
      // store state) — pin the count at the host, then render the
      // PNG from its boundary through the real service.
      final screenHost = tester
          .widget<StreakShareCardHost>(find.byType(StreakShareCardHost));
      expect(screenHost.count, 27);
      expect(find.byKey(const Key('streakShareButton')), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await tester.runAsync(() async {
        final ok = await StreakShareService.shareFromBoundary(
          screenHost.boundaryKey,
          count: screenHost.count,
        );
        expect(ok, isTrue);
      });
      expect(handedOff, isNotNull);
      expect(handedOff!.path, contains('tabs_streak_share_27.png'));
      // Silence the unused-import lint for RenderRepaintBoundary
      // checks done elsewhere; the boundary type is asserted in
      // streak_upgrade_ui_test.
      expect(RenderRepaintBoundary, isNotNull);
    });
  });
}
