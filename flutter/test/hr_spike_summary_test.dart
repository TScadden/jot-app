import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/daily_biometrics_sync.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';

/// MCP spike-data package (Nov 23, 2026) — app half.
///
/// - computeDailyHrSpikeSummary: ONE walk produces the count
///   (the stored count's own segmentation — asserted EQUAL to
///   computeDailyHrSummary's spikeCount on every stream), the
///   events (same segmentation), max + first-attaining time, and
///   the time-weighted minutes over 100/120.
/// - DailyBiometrics: the five new fields round-trip the store,
///   merge under both merge modes, and sanitize under the zero
///   rule (minutes keep 0; max keeps positive-only).
/// - DailyBiometricsSync: the POST payload carries the new
///   fields in the contract shape; the GET merge fills only
///   locally-absent fields; an owner mismatch sends nothing.
/// - Capture wiring: the spike pass computes summaries from the
///   range sample read into the store, alongside the bridge
///   count, in the same capture.

final _day = DateTime(2026, 11, 20, 8, 0); // local 08:00
int _at(int minutes, [int extraMs = 0]) =>
    _day.add(Duration(minutes: minutes, milliseconds: extraMs))
        .millisecondsSinceEpoch;

HrSample _s(int minutes, int bpm, [int extraMs = 0]) =>
    HrSample(timeMs: _at(minutes, extraMs), bpm: bpm);

void main() {
  group('computeDailyHrSpikeSummary — count/events agreement', () {
    test('three separated spikes: count 3, events are the count\'s '
        'own segmentation, and the count equals '
        'computeDailyHrSummary\'s', () {
      final samples = [
        _s(0, 110), _s(1, 118), // event 1: peak 118, last high @1
        _s(20, 105), // event 2 (19 min after event 1's end @6)
        _s(40, 130), _s(42, 125), // event 3: peak 130
        _s(60, 72), // below threshold, no event
      ];
      final summary = computeDailyHrSpikeSummary(samples)!;
      expect(summary.spikeCount, 3);
      expect(summary.spikeCount,
          computeDailyHrSummary('2026-11-20', samples)!.spikeCount);
      // Top-5 list holds all 3, peak-descending.
      expect(summary.spikeEvents.map((e) => e.peakBpm), [130, 118, 105]);
      final first = summary.spikeEvents.firstWhere((e) => e.peakBpm == 118);
      expect(first.startMs, _at(0));
      expect(first.durationMinutes, 1); // last high @1 − start @0 = 1
      final third = summary.spikeEvents.firstWhere((e) => e.peakBpm == 130);
      expect(third.startMs, _at(40));
      expect(third.durationMinutes, 2);
    });

    test('5-minute boundary: a high reading exactly at end+5min '
        'CONTINUES the event; 1ms later STARTS a new one', () {
      // Event end after @0 is @5. @5 is not > end → same event,
      // end moves to @10. @10 is not > end → same event, end @15.
      // @15+1ms > end → new event.
      final samples = [
        _s(0, 110),
        _s(5, 112),
        _s(10, 108),
        _s(15, 130, 1),
      ];
      final summary = computeDailyHrSpikeSummary(samples)!;
      expect(summary.spikeCount, 2);
      expect(summary.spikeCount,
          computeDailyHrSummary('2026-11-20', samples)!.spikeCount);
      final first = summary.spikeEvents.firstWhere((e) => e.peakBpm == 112);
      expect(first.startMs, _at(0));
      expect(first.durationMinutes, 10); // last high @10 − start @0

      final justAfter = [_s(0, 110), _s(5, 112, 1)];
      final s2 = computeDailyHrSpikeSummary(justAfter)!;
      expect(s2.spikeCount, 2);
      expect(s2.spikeCount,
          computeDailyHrSummary('2026-11-20', justAfter)!.spikeCount);
    });

    test('count is NEVER capped: 7 events → spikeCount 7, stored '
        'list is the top 5 by peak', () {
      final samples = <HrSample>[
        for (var i = 0; i < 7; i++) _s(i * 20, 101 + i * 5), // peaks 101..131
      ];
      final summary = computeDailyHrSpikeSummary(samples)!;
      expect(summary.spikeCount, 7);
      expect(summary.spikeEvents.length, 5);
      expect(summary.spikeEvents.map((e) => e.peakBpm),
          [131, 126, 121, 116, 111]);
    });

    test('agreement with computeDailyHrSummary across crafted '
        'streams (incl. unsorted input and below-threshold noise)',
        () {
      final streams = <List<HrSample>>[
        [_s(0, 99), _s(1, 100), _s(2, 99), _s(30, 100)],
        [_s(9, 140), _s(0, 101), _s(3, 102), _s(8, 70), _s(20, 150)],
        [_s(0, 100)],
        [for (var i = 0; i < 60; i++) _s(i, i.isEven ? 115 : 65)],
        [for (var i = 0; i < 60; i++) _s(i, 115)],
      ];
      for (final stream in streams) {
        final summary = computeDailyHrSpikeSummary(stream)!;
        expect(summary.spikeCount,
            computeDailyHrSummary('2026-11-20', stream)!.spikeCount,
            reason: 'stream: $stream');
        // Events listed never exceed the count, and when the
        // count is ≤ 5 the list IS the full segmentation.
        if (summary.spikeCount <= 5) {
          expect(summary.spikeEvents.length, summary.spikeCount);
        }
      }
    });
  });

  group('computeDailyHrSpikeSummary — minutes estimator', () {
    test('1-minute spacing at 110 for 10 minutes → 10 over 100, '
        '0 over 120', () {
      final samples = [
        for (var i = 0; i < 10; i++) _s(i, 110),
        _s(10, 70), // closes the last high sample's 1-minute cover
      ];
      final summary = computeDailyHrSpikeSummary(samples)!;
      expect(summary.minutesOver100, 10);
      expect(summary.minutesOver120, 0);
    });

    test('1-minute spacing at 130 → both thresholds accumulate', () {
      final samples = [
        for (var i = 0; i < 6; i++) _s(i, 130),
        _s(6, 70),
      ];
      final summary = computeDailyHrSpikeSummary(samples)!;
      expect(summary.minutesOver100, 6);
      expect(summary.minutesOver120, 6);
    });

    test('the 5-minute cap: a 30-minute gap contributes 5, not 30',
        () {
      final samples = [_s(0, 110), _s(30, 110), _s(31, 70)];
      final summary = computeDailyHrSpikeSummary(samples)!;
      // @0 covers min(30, 5) = 5; @30 covers 1 (to the @31 sample).
      expect(summary.minutesOver100, 6);
    });

    test('the day\'s last sample covers nothing; exactly-100 is a '
        'spike but adds no over-100 minutes (strictly over)', () {
      final single = computeDailyHrSpikeSummary([_s(0, 150)])!;
      expect(single.minutesOver100, 0);
      expect(single.minutesOver120, 0);
      expect(single.spikeCount, 1);

      final atThreshold = computeDailyHrSpikeSummary(
          [_s(0, 100), _s(1, 100), _s(2, 70)])!;
      expect(atThreshold.spikeCount, 1); // ≥ 100 starts a spike
      expect(atThreshold.minutesOver100, 0); // but not OVER 100
    });
  });

  group('computeDailyHrSpikeSummary — max and null discipline', () {
    test('max is the highest sample; maxAtMs is the FIRST sample '
        'attaining it', () {
      final samples = [_s(0, 120), _s(5, 140), _s(9, 140), _s(12, 130)];
      final summary = computeDailyHrSpikeSummary(samples)!;
      expect(summary.maxBpm, 140);
      expect(summary.maxAtMs, _at(5));
    });

    test('no samples → null; all-zero samples → null; 0-bpm '
        'samples are ignored, never data', () {
      expect(computeDailyHrSpikeSummary(const []), isNull);
      expect(computeDailyHrSpikeSummary([_s(0, 0), _s(1, 0)]), isNull);
      final mixed = computeDailyHrSpikeSummary(
          [_s(0, 0), _s(1, 90), _s(2, 0), _s(3, 95)])!;
      expect(mixed.maxBpm, 95);
      expect(mixed.spikeCount, 0);
      expect(mixed.spikeEvents, isEmpty);
      expect(mixed.minutesOver100, 0);
    });

    test('a sampled day with no spikes: count 0, empty events, '
        'real max and zero minutes', () {
      final summary =
          computeDailyHrSpikeSummary([_s(0, 80), _s(1, 85), _s(2, 82)])!;
      expect(summary.spikeCount, 0);
      expect(summary.spikeEvents, isEmpty);
      expect(summary.maxBpm, 85);
      expect(summary.maxAtMs, _at(1));
      expect(summary.minutesOver100, 0);
      expect(summary.minutesOver120, 0);
    });
  });

  group('DailyBiometrics spike summary fields — store', () {
    DailyBiometrics sampleRow() => DailyBiometrics(
          date: '2026-11-20',
          restingHrBpm: 58,
          spikeCount: 2,
          maxHrBpm: 142,
          maxHrAtMs: _at(40),
          minutesOver100: 17,
          minutesOver120: 4,
          spikeEvents: [
            HrSpikeEvent(
                startMs: _at(40), peakBpm: 142, durationMinutes: 3),
            HrSpikeEvent(
                startMs: _at(0), peakBpm: 118, durationMinutes: 1),
          ],
        );

    test('JSON round-trip preserves all five fields', () {
      final row = sampleRow();
      final back = DailyBiometrics.fromJson(row.toJson());
      expect(back, row);
    });

    test('a pre-package blob (no new keys) parses with nulls', () {
      final back = DailyBiometrics.fromJson(
          {'date': '2026-11-20', 'spikeCount': 2});
      expect(back, isNotNull);
      expect(back!.maxHrBpm, isNull);
      expect(back.maxHrAtMs, isNull);
      expect(back.minutesOver100, isNull);
      expect(back.minutesOver120, isNull);
      expect(back.spikeEvents, isNull);
    });

    test('sanitized: max 0 → null (failed read), minutes 0 kept '
        '(real data), negative minutes dropped', () {
      final dirty = DailyBiometrics(
        date: '2026-11-20',
        maxHrBpm: 0,
        maxHrAtMs: 0,
        minutesOver100: 0,
        minutesOver120: -3,
      ).sanitized();
      expect(dirty.maxHrBpm, isNull);
      expect(dirty.maxHrAtMs, isNull);
      expect(dirty.minutesOver100, 0);
      expect(dirty.minutesOver120, isNull);
    });

    test('malformed event entries drop individually; list caps '
        'at 5', () {
      final back = DailyBiometrics.fromJson({
        'date': '2026-11-20',
        'spikeEvents': [
          {'startMs': _at(0), 'peakBpm': 120, 'durationMinutes': 2},
          {'startMs': 'junk'},
          'not a map',
          for (var i = 0; i < 6; i++)
            {'startMs': _at(i * 10), 'peakBpm': 110, 'durationMinutes': 1},
        ],
      });
      expect(back!.spikeEvents, isNotNull);
      expect(back.spikeEvents!.length, 5);
      expect(back.spikeEvents!.first.peakBpm, 120);
    });

    test('persist + warm round-trip through the store blob', () async {
      final values = <String, String>{};
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => values[k],
        write: (k, v) async => values[k] = v,
        delete: (k) async => values.remove(k),
      );
      await store.mergeRefresh([sampleRow()]);
      final reread = HealthHistoryStore.testInstance();
      reread.debugSetStore(
        read: (k) async => values[k],
        write: (k, v) async => values[k] = v,
        delete: (k) async => values.remove(k),
      );
      final all = await reread.readAll();
      expect(all['2026-11-20'], sampleRow());
    });

    test('mergeRefresh: incoming summary overwrites; a null '
        'incoming summary never erases the stored one', () async {
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => null,
        write: (k, v) async {},
        delete: (k) async {},
      );
      await store.mergeRefresh([sampleRow()]);
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-11-20', restingHrBpm: 59),
      ]);
      var day = (await store.readAll())['2026-11-20']!;
      expect(day.maxHrBpm, 142);
      expect(day.spikeEvents, hasLength(2));
      expect(day.restingHrBpm, 59); // the refresh still landed

      await store.mergeRefresh([
        DailyBiometrics(
          date: '2026-11-20',
          maxHrBpm: 150,
          maxHrAtMs: _at(50),
          minutesOver100: 20,
          minutesOver120: 9,
          spikeEvents: const [],
        ),
      ]);
      day = (await store.readAll())['2026-11-20']!;
      expect(day.maxHrBpm, 150);
      expect(day.minutesOver120, 9);
      expect(day.spikeEvents, isEmpty); // empty list is real data
    });

    test('mergeFillGaps: fills only locally-absent fields', () async {
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => null,
        write: (k, v) async {},
        delete: (k) async {},
      );
      await store.mergeRefresh([
        DailyBiometrics(date: '2026-11-20', maxHrBpm: 130),
      ]);
      await store.mergeFillGaps([sampleRow()]);
      final day = (await store.readAll())['2026-11-20']!;
      expect(day.maxHrBpm, 130); // local wins
      expect(day.minutesOver100, 17); // absent → filled
      expect(day.spikeEvents, hasLength(2));
    });
  });

  group('DailyBiometricsSync', () {
    HealthHistoryStore memStore() {
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => null,
        write: (k, v) async {},
        delete: (k) async {},
      );
      return store;
    }

    test('POST payload carries the spike summary in the contract '
        'shape; GET merge populates a missing day', () async {
      final store = memStore();
      await store.mergeRefresh([
        DailyBiometrics(
          date: '2026-11-20',
          spikeCount: 2,
          maxHrBpm: 142,
          maxHrAtMs: _at(40),
          minutesOver100: 17,
          minutesOver120: 4,
          spikeEvents: [
            HrSpikeEvent(
                startMs: _at(40), peakBpm: 142, durationMinutes: 3),
          ],
        ),
      ]);
      List<DailyBiometrics>? posted;
      final sync = DailyBiometricsSync.withDeps(
        store: store,
        poster: (days) async {
          posted = days;
          return true;
        },
        fetcher: () async => [
          // A server-only day (e.g. synced from another device).
          DailyBiometrics(
            date: '2026-11-19',
            spikeCount: 1,
            maxHrBpm: 121,
            maxHrAtMs: _at(10),
            minutesOver100: 3,
            minutesOver120: 1,
            spikeEvents: [
              HrSpikeEvent(
                  startMs: _at(10), peakBpm: 121, durationMinutes: 2),
            ],
          ),
        ],
        ownerProvider: () async => 'founder@example.com',
      );
      expect(await sync.syncAfterCapture(), isTrue);
      expect(posted, isNotNull);
      final payload = posted!.single.toJson();
      expect(payload['maxHrBpm'], 142);
      expect(payload['maxHrAtMs'], _at(40));
      expect(payload['minutesOver100'], 17);
      expect(payload['minutesOver120'], 4);
      expect(payload['spikeEvents'], [
        {'startMs': _at(40), 'peakBpm': 142, 'durationMinutes': 3},
      ]);
      // The GET merge landed the server-only day in the store.
      final all = await store.readAll();
      expect(all['2026-11-19']!.maxHrBpm, 121);
      expect(all['2026-11-19']!.spikeEvents!.single.peakBpm, 121);
    });

    test('GET merge never overwrites a local value', () async {
      final store = memStore();
      await store.mergeRefresh([
        DailyBiometrics(date: '2026-11-20', maxHrBpm: 142),
      ]);
      final sync = DailyBiometricsSync.withDeps(
        store: store,
        poster: (days) async => true,
        fetcher: () async => [
          DailyBiometrics(
              date: '2026-11-20', maxHrBpm: 99, minutesOver100: 5),
        ],
        ownerProvider: () async => null,
      );
      expect(await sync.syncAfterCapture(), isTrue);
      final day = (await store.readAll())['2026-11-20']!;
      expect(day.maxHrBpm, 142); // local wins
      expect(day.minutesOver100, 5); // absent field filled
    });

    test('owner mismatch: nothing is posted, run reports false',
        () async {
      final store = memStore();
      store.bindToAccount('founder@example.com');
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-11-20', maxHrBpm: 142),
      ]);
      var postCalls = 0;
      final sync = DailyBiometricsSync.withDeps(
        store: store,
        poster: (days) async {
          postCalls++;
          return true;
        },
        fetcher: () async => const [],
        ownerProvider: () async => 'someone-else@example.com',
      );
      expect(await sync.syncAfterCapture(), isFalse);
      expect(postCalls, 0);
    });

    test('a failed POST reports false and merges nothing', () async {
      final store = memStore();
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-11-20', maxHrBpm: 142),
      ]);
      var fetchCalls = 0;
      final sync = DailyBiometricsSync.withDeps(
        store: store,
        poster: (days) async => false,
        fetcher: () async {
          fetchCalls++;
          return const [];
        },
        ownerProvider: () async => null,
      );
      expect(await sync.syncAfterCapture(), isFalse);
      expect(fetchCalls, 0);
    });
  });

  group('capture wiring — spike summary in the history sync pass',
      () {
    test('a capture stores the bridge count AND the Dart-computed '
        'summary for the day', () async {
      final values = <String, String>{};
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => values[k],
        write: (k, v) async => values[k] = v,
        delete: (k) async => values.remove(k),
      );
      final hc = _SummaryHc();
      final sync = HealthHistorySync.withDeps(
        hc: hc,
        store: store,
        now: () => DateTime(2026, 11, 20, 12),
      );
      HealthHistorySync.debugResetFlight();
      addTearDown(HealthHistorySync.debugResetFlight);
      expect(await sync.capture(force: true), isTrue);
      final day = (await store.readAll())['2026-11-20']!;
      expect(day.spikeCount, 1); // the bridge count, unchanged path
      expect(day.maxHrBpm, 118);
      expect(day.maxHrAtMs, _at(1));
      expect(day.minutesOver100, 2);
      expect(day.minutesOver120, 0);
      expect(day.spikeEvents, hasLength(1));
      expect(day.spikeEvents!.single.peakBpm, 118);
      expect(day.spikeEvents!.single.startMs, _at(0));
    });
  });
}

/// Capture fake: one spike day. The bridge count read and the raw
/// sample read describe the same samples (110 @0, 118 @1, then a
/// closing 70 @2 so the second high sample covers a minute).
class _SummaryHc extends HealthConnectService {
  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
          int days) async =>
      const [(date: '2026-11-20', count: 1)];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];

  @override
  Future<HcReadOutcome<List<HrSample>>> readHrSamplesRangeWithOutcome(
      {required int startMs, required int endMs}) async {
    final all = [_s(0, 110), _s(1, 118), _s(2, 70)];
    return HcReadOutcome(
        value:
            all.where((s) => s.timeMs >= startMs && s.timeMs < endMs).toList());
  }
}
