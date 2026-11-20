import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/tabs_day.dart';

/// Vera condition 1 regression guard (boundary migration fix
/// round): the workmanager background isolate must load the
/// Tabs-day cutover before the correlation refresh runs there.
///
/// Why this shape: `dailyScoreBackgroundDispatcher` is a
/// top-level `@pragma('vm:entry-point')` tear-off handed to the
/// workmanager plugin — it has no injection seam and cannot be
/// invoked in a unit test without the platform plugin, so a
/// direct behavioral test of the dispatcher is not possible.
/// The guard therefore has two halves:
///
/// 1. A SOURCE-LEVEL ORDERING PIN (the repo's established
///    source-pin pattern, cf. daily_score_refresh_keep_alive_
///    test.dart): the dispatcher body must contain an awaited
///    `TabsDayBoundary.instance.load()` positioned BEFORE the
///    `CorrelationRefresher.production().refreshIfStale()` call.
///    Removing or reordering the load fails this test.
/// 2. A BEHAVIORAL PIN at the closest testable seam: the
///    refresher labels entries through `energyDayLabel`, which
///    reads the singleton. Unloaded (the fresh-isolate state)
///    a post-cutover 00:00–04:00 instant derives LEGACY — the
///    condition-1 bug. After the real `load()` restores the
///    persisted cutover, the same instant derives CALENDAR.
void main() {
  tearDown(() {
    TabsDayBoundary.instance.debugCutoverAt = null;
  });

  group('source pin: dispatcher loads the cutover before the '
      'correlation refresh', () {
    test('dailyScoreBackgroundDispatcher awaits '
        'TabsDayBoundary.instance.load() ahead of refreshIfStale()',
        () {
      final source = File('lib/src/data/daily_score_background.dart')
          .readAsStringSync();
      final start = source.indexOf('void dailyScoreBackgroundDispatcher()');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'the vm:entry-point dispatcher must exist');
      final body = source.substring(start);
      final loadIdx = body.indexOf('await TabsDayBoundary.instance.load()');
      final refreshIdx = body
          .indexOf('CorrelationRefresher.production().refreshIfStale()');
      expect(loadIdx, greaterThanOrEqualTo(0),
          reason: 'the background isolate must load the Tabs-day '
              'cutover — its singleton starts fresh and the '
              'correlation refresh below persists day labels');
      expect(refreshIdx, greaterThanOrEqualTo(0));
      expect(loadIdx, lessThan(refreshIdx),
          reason: 'the load must precede the refresh: the refresh '
              'derives (and persists) day labels through the '
              'boundary, so an unloaded refresh mislabels every '
              'post-cutover 00:00–04:00 entry under the legacy '
              '04:00 rule');
    });
  });

  group('behavioral: the refresh labeling path under a loaded '
      'cutover', () {
    final m = DateTime(2026, 11, 6); // cutover M = (C+1) 00:00
    final smallHours = DateTime(2026, 11, 6, 1, 30); // (C+1) 01:30

    test('unloaded (fresh-isolate state): energyDayLabel derives '
        'legacy — the condition-1 bug state', () {
      TabsDayBoundary.instance.debugCutoverAt = null;
      expect(energyDayLabel(smallHours.millisecondsSinceEpoch),
          '2026-11-05');
    });

    test('after load() restores the persisted cutover, the same '
        'small-hours instant labels under the calendar rule',
        () async {
      final disk = <String, String>{
        TabsDayBoundary.cutoverStorageKey: '${m.millisecondsSinceEpoch}',
      };
      final boundary = TabsDayBoundary(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        clock: () => DateTime(2026, 11, 20, 9),
      );
      await boundary.load();
      expect(boundary.cutoverAt, m,
          reason: 'load() restores the persisted cutover — the '
              'exact step the dispatcher now performs first');
      // The delegates read the singleton; pin it to the value the
      // real load produced (the seam battery's established
      // pattern) and verify the refresher's labeling delegate
      // flips to the calendar rule for the whole small-hours
      // window, while pre-cutover instants keep legacy labels.
      TabsDayBoundary.instance.debugCutoverAt = boundary.cutoverAt;
      expect(energyDayLabel(smallHours.millisecondsSinceEpoch),
          '2026-11-06');
      expect(
          energyDayLabel(
              DateTime(2026, 11, 6, 3, 59).millisecondsSinceEpoch),
          '2026-11-06');
      expect(
          energyDayLabel(
              DateTime(2026, 11, 5, 12).millisecondsSinceEpoch),
          '2026-11-05');
    });
  });
}
