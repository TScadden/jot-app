import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/summary_completeness.dart';
import 'package:tabs_lab/src/data/tabs_day.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';

/// Vera C2, watcher layer (Nov 21, 2026 delta): the watcher's
/// graceStillActive liveness probe is consulted at the fire point.
/// A grace evaluation whose window ended while its inputs were
/// resolving must fire NOTHING and write NO fired-day marker —
/// for any end reason — while the same evaluation under a live
/// window fires exactly as before. (The Home-level races are
/// pinned in midnight_grace_test.dart; this file pins the
/// watcher-side guard the review also required, in isolation.)
void main() {
  final closingStart = DateTime(2026, 11, 5);
  final deadline = DateTime(2026, 11, 6, 0, 1, 30);

  setUp(() {
    TabsDayBoundary.instance.debugCutoverAt = DateTime(2026, 11, 1);
  });
  tearDown(() {
    TabsDayBoundary.instance.debugCutoverAt = null;
  });

  group('SummaryCompletionWatcher grace liveness guard (C2)', () {
    const medCat = '8';
    const moodCat = '6';
    const goalsCat = '4';
    const med = SummaryMedication(key: 'k1', name: 'MedA', dose: '5mg');

    late Map<String, String> disk;
    late Map<String, String> markers;
    late StreakStore store;
    late SummaryCompletionWatcher watcher;
    late List<StreakCompletionResult> events;
    late bool windowAlive;

    Future<bool> push(int c, int b, String j,
            {int? purchasedFreezes}) async =>
        true;

    QuickLogEntry entry({
      required String id,
      required String cat,
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

    // The closing day, complete: med taken in-day, check-in
    // logged inside the grace window (00:00:30).
    List<QuickLogEntry> completeEntries() => [
          entry(
          id: '1',
            cat: medCat,
            body: 'Took MedA 5mg',
            at: DateTime(2026, 11, 5, 20),
          ),
          entry(
          id: '100',
            cat: moodCat,
            body: 'Feeling: 4/5 Today',
            chips: jsonEncode(const [feelingCheckInTag]),
            at: DateTime(2026, 11, 6, 0, 0, 30),
          ),
        ];

    SummaryCompletionContext graceContext(List<QuickLogEntry> entries) =>
        SummaryCompletionContext(
          attestedPlan: AttestedPlan(
            plan: buildPlanForFeelingDay(
              feelingDayStart: closingStart,
              medications: const [med],
              reminders: const [],
              habits: const [],
              localState: const TodayPlanLocalState(),
              entries: entries,
              medicationCategoryId: medCat,
              goalsCategoryId: goalsCat,
              evidenceWindowEnd: deadline,
            ),
            attestation: const PlanAttestation(
              medicationsResolved: true,
              remindersResolved: true,
              habitsResolved: true,
            ),
          ),
          entries: entries,
          moodCategoryId: moodCat,
        );

    Future<bool> fireGrace() => watcher.maybeFireSummaryCompletion(
          context: graceContext(completeEntries()),
          pullSucceeded: true,
          seedCurrent: null,
          seedBest: null,
          seedStateJson: null,
          push: push,
          now: DateTime(2026, 11, 6, 0, 1, 28),
          fireableDayStartOverride: closingStart,
          evidenceWindowEnd: deadline,
          graceStillActive: () => windowAlive,
        );

    setUp(() {
      disk = {};
      markers = {};
      events = [];
      windowAlive = true;
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
    tearDown(() => watcher.dispose());

    test('control: window still live at the fire point → the '
        'closing day fires exactly once', () async {
      final fired = await fireGrace();
      expect(fired, isTrue);
      expect(events, hasLength(1));
      expect(store.state!.countedDays, {'2026-11-05'});
      expect(
        markers[SummaryCompletionWatcher.firedDayStorageKey],
        '2026-11-05',
      );
    });

    test('window ended before the fire (expiry during the '
        'caller\'s resolution) → no fire, no marker; the marker '
        'is not burned — a later live evaluation can still fire',
        () async {
      windowAlive = false;
      final fired = await fireGrace();
      expect(fired, isFalse);
      expect(events, isEmpty);
      expect(store.state?.countedDays ?? const <String>{}, isEmpty);
      expect(markers, isEmpty);

      // No marker was written, so nothing about the refusal is
      // sticky: had the window in fact still been live, the same
      // evaluation re-run fires normally.
      windowAlive = true;
      final later = await fireGrace();
      expect(later, isTrue);
      expect(store.state!.countedDays, {'2026-11-05'});
    });

    test('window ends DURING the watcher call itself (the marker '
        'read flips it, as an expiry landing mid-await would) → '
        'no fire, no marker', () async {
      watcher.debugSetMarkerStore(
        read: (key) async {
          // The window ends while the watcher is awaiting its
          // marker read — the last await before the fire point.
          windowAlive = false;
          return markers[key];
        },
        write: (key, value) async {
          markers[key] = value;
        },
      );
      final fired = await fireGrace();
      expect(fired, isFalse);
      expect(events, isEmpty);
      expect(store.state?.countedDays ?? const <String>{}, isEmpty);
      expect(markers, isEmpty);
    });

    test('no probe (null) keeps the shipped behavior: the grace '
        'fire lands as before', () async {
      final fired = await watcher.maybeFireSummaryCompletion(
        context: graceContext(completeEntries()),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(fired, isTrue);
      expect(store.state!.countedDays, {'2026-11-05'});
    });
  });
}
