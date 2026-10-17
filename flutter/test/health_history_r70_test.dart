import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/metrics_csv_import.dart';

/// In-memory fake for the store's storage functions.
class _FakeStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Fake Health Connect: returns canned windows, records call args.
class _FakeHc extends HealthConnectService {
  List<({String date, int bpm})> hr = const [];
  List<({String date, int kcal})> cal = const [];
  List<({String date, int mins, int deep})> sleep = const [];
  List<({String date, int count})> spikes = const [];
  double? hrv;
  final List<String> calls = [];
  final List<int> spikeDayArgs = [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async {
    calls.add('hr$days');
    return hr;
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async {
    calls.add('cal$days');
    return cal;
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    calls.add('sleep$days');
    return sleep;
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async {
    calls.add('spikes$days');
    spikeDayArgs.add(days);
    return spikes;
  }

  @override
  Future<double?> readHrvRmssd(String dateStr) async {
    calls.add('hrv');
    return hrv;
  }
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  late _FakeStore fake;
  late HealthHistoryStore store;

  setUp(() {
    fake = _FakeStore();
    store = HealthHistoryStore.instance;
    store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
    store.debugReset();
  });

  tearDown(() => store.debugReset());

  group('merge modes + zero rule', () {
    test('mergeRefresh overwrites non-null only, never erases', () async {
      await store.mergeRefresh(const [
        DailyBiometrics(
            date: '2026-10-01', restingHrBpm: 60, sleepMinutes: 400),
      ]);
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-01', restingHrBpm: 62),
      ]);
      final all = await store.readAll();
      expect(all['2026-10-01']!.restingHrBpm, 62);
      expect(all['2026-10-01']!.sleepMinutes, 400); // not erased
    });

    test('mergeFillGaps never overwrites existing values', () async {
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      final res = await store.mergeFillGaps(const [
        DailyBiometrics(
            date: '2026-10-01', restingHrBpm: 99, sleepMinutes: 400),
      ]);
      final all = await store.readAll();
      expect(all['2026-10-01']!.restingHrBpm, 60); // existing wins
      expect(all['2026-10-01']!.sleepMinutes, 400); // gap filled
      expect(res.cellsFilled, 1);
    });

    test('zero rule: 0/negative never stored, never erase; spike 0 stored',
        () async {
      await store.mergeRefresh(const [
        DailyBiometrics(
            date: '2026-10-01',
            restingHrBpm: 60,
            sleepMinutes: 400,
            caloriesKcal: 2000,
            hrvRmssdMs: 50),
      ]);
      await store.mergeRefresh(const [
        DailyBiometrics(
            date: '2026-10-01',
            restingHrBpm: 0,
            sleepMinutes: -5,
            caloriesKcal: 0,
            hrvRmssdMs: 0,
            spikeCount: 0),
      ]);
      final day = (await store.readAll())['2026-10-01']!;
      expect(day.restingHrBpm, 60);
      expect(day.sleepMinutes, 400);
      expect(day.caloriesKcal, 2000);
      expect(day.hrvRmssdMs, 50);
      expect(day.spikeCount, 0); // real data

      // An all-zero incoming day creates nothing.
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-02', restingHrBpm: 0, sleepMinutes: 0),
      ]);
      expect(await store.dayCount(), 1);
    });

    test('readRange inclusive + coverage', () async {
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
        DailyBiometrics(date: '2026-10-05', restingHrBpm: 61),
        DailyBiometrics(date: '2026-10-10', restingHrBpm: 62),
      ]);
      final range = await store.readRange('2026-10-05', '2026-10-10');
      expect(range.keys.toList(), ['2026-10-05', '2026-10-10']);
      final cov = await store.coverage();
      expect(cov.earliest, '2026-10-01');
      expect(cov.latest, '2026-10-10');
      expect(await store.dayCount(), 3);
    });
  });

  group('account binding', () {
    test('owner mismatch wipes like sibling caches; no account = no drop',
        () async {
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ], );
      store.bindToAccount('Owner@Example.com ');
      expect(store.ownerEmail, 'owner@example.com');
      // No account known → no drop.
      expect(await store.clearIfOwnerMismatch(null), isFalse);
      expect(await store.dayCount(), 1);
      // Matching owner (normalized) → keep.
      expect(await store.clearIfOwnerMismatch('owner@example.com'), isFalse);
      expect(await store.dayCount(), 1);
      // Differing owner → wipe + bind.
      expect(await store.clearIfOwnerMismatch('other@example.com'), isTrue);
      expect(await store.dayCount(), 0);
      expect(store.ownerEmail, 'other@example.com');
    });

    test('warmFromDisk drops a blob owned by another account', () async {
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      store.bindToAccount('a@example.com');
      await store.persist();
      store.debugReset(); // memory only; disk blob survives
      await store.warmFromDisk(currentEmail: 'b@example.com');
      expect(await store.dayCount(), 0);
      expect(fake.values.containsKey(HealthHistoryStore.storageKey), isFalse);
    });

    test('warmFromDisk with no account known loads the blob', () async {
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      store.debugReset();
      await store.warmFromDisk();
      expect(await store.dayCount(), 1);
    });
  });

  group('capture (HealthHistorySync)', () {
    test(
        'Sep30 regression: capture never shrinks the store — 180 seeded days survive a 14-day HC window and the window is refreshed',
        () async {
      // Seed 180 synthetic days.
      final start = DateTime(2026, 4, 20);
      final seed = <DailyBiometrics>[
        for (var i = 0; i < 180; i++)
          DailyBiometrics(
              date: _ds(start.add(Duration(days: i))),
              restingHrBpm: 60,
              sleepMinutes: 400),
      ];
      await store.mergeRefresh(seed);
      expect(await store.dayCount(), 180);

      // Fake HC only sees the last 14 days, with FRESH HR values.
      final hc = _FakeHc();
      final window = seed.sublist(166); // last 14 seeded days
      hc.hr = [for (final d in window) (date: d.date, bpm: 75)];
      hc.cal = const [];
      hc.sleep = const [];
      hc.spikes = const [];
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => DateTime(2026, 10, 17, 12));
      expect(await sync.captureFromHealthConnect(force: true), isTrue);

      // The headline assertions: nothing shrank, window refreshed.
      expect(await store.dayCount(), 180);
      final all = await store.readAll();
      for (final d in window) {
        expect(all[d.date]!.restingHrBpm, 75,
            reason: 'overlapping day ${d.date} must be refreshed');
        expect(all[d.date]!.sleepMinutes, 400,
            reason: 'absent incoming sleep must not erase stored sleep');
      }
      // A day far outside the window is untouched.
      expect(all[seed.first.date]!.restingHrBpm, 60);
    });

    test('throttle: skip within 6h; first run is a 180d spike backfill, routine is 31d',
        () async {
      final hc = _FakeHc();
      hc.hr = const [(date: '2026-10-16', bpm: 63)];
      var now = DateTime(2026, 10, 16, 12);
      final sync =
          HealthHistorySync.withDeps(hc: hc, store: store, now: () => now);

      // First-ever capture on an empty store runs even unforced.
      expect(await sync.captureFromHealthConnect(), isTrue);
      expect(hc.spikeDayArgs, [180]);
      final callsAfterFirst = hc.calls.length;

      // Within 6h: throttled, no further reads.
      now = now.add(const Duration(hours: 2));
      expect(await sync.captureFromHealthConnect(), isFalse);
      expect(hc.calls.length, callsAfterFirst);

      // After 6h: runs again, routine spike window.
      now = now.add(const Duration(hours: 5));
      expect(await sync.captureFromHealthConnect(), isTrue);
      expect(hc.spikeDayArgs, [180, 31]);

      // Forced capture ignores the throttle.
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
    });

    test('capture never throws when reads fail', () async {
      final sync = HealthHistorySync.withDeps(
          hc: _ThrowingHc(), store: store, now: () => DateTime(2026, 10, 16));
      expect(await sync.captureFromHealthConnect(force: true), isFalse);
    });
  });

  group('metrics CSV import', () {
    late String fixture;

    setUpAll(() {
      fixture =
          File('test/fixtures/jot_metrics_180d_recovered.csv').readAsStringSync();
    });

    test('fixture parses: 180 rows, known values, No data handling', () {
      final parsed = parseMetricsCsv(fixture);
      expect(parsed, isA<MetricsCsvParseSuccess>());
      final s = parsed as MetricsCsvParseSuccess;
      expect(s.rowsRead, 180);
      expect(s.rowsSkipped, 0);
      final byDate = {for (final r in s.rows) r.date: r};
      // 2026-10-16: HR 63, sleep 6h 25m = 385, deep No data, spikes 24.
      expect(byDate['2026-10-16']!.restingHrBpm, 63);
      expect(byDate['2026-10-16']!.sleepMinutes, 385);
      expect(byDate['2026-10-16']!.deepSleepMinutes, isNull);
      expect(byDate['2026-10-16']!.spikeCount, 24);
      // 2026-10-15: sleep 7h 24m = 444, deep 1h 26m = 86, spikes 48.
      expect(byDate['2026-10-15']!.sleepMinutes, 444);
      expect(byDate['2026-10-15']!.deepSleepMinutes, 86);
      expect(byDate['2026-10-15']!.spikeCount, 48);
      // 2026-10-12: sleep/deep No data, spikes 21.
      expect(byDate['2026-10-12']!.sleepMinutes, isNull);
      expect(byDate['2026-10-12']!.spikeCount, 21);
      // 2026-04-20 (oldest): HR only.
      expect(byDate['2026-04-20']!.restingHrBpm, 61);
      expect(byDate['2026-04-20']!.spikeCount, isNull);
    });

    test('fixture imports 180 days into an empty store', () async {
      final outcome = await importMetricsCsv(csvText: fixture, store: store);
      expect(outcome, isA<MetricsImportOk>());
      final report = (outcome as MetricsImportOk).report;
      expect(report.rowsRead, 180);
      expect(report.daysAdded, 180);
      expect(report.rowsSkipped, 0);
      expect(await store.dayCount(), 180);
      final cov = await store.coverage();
      expect(cov.earliest, '2026-04-20');
      expect(cov.latest, '2026-10-16');
    });

    test('import does not overwrite fresher stored values (fill-gaps only)',
        () async {
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-15', restingHrBpm: 99),
      ]);
      final outcome = await importMetricsCsv(csvText: fixture, store: store);
      expect(outcome, isA<MetricsImportOk>());
      final day = (await store.readAll())['2026-10-15']!;
      expect(day.restingHrBpm, 99); // fresher stored value wins
      expect(day.sleepMinutes, 444); // gap filled from the CSV
      expect(day.deepSleepMinutes, 86);
      expect(day.spikeCount, 48);
    });

    test('wrong header is rejected with a clear message', () {
      final parsed = parseMetricsCsv('Date,HR,Sleep\n2026-10-01,60,7h 0m\n');
      expect(parsed, isA<MetricsCsvParseFailure>());
      expect((parsed as MetricsCsvParseFailure).message,
          metricsCsvMsgWrongHeader);
    });

    test('malformed rows are skipped and counted, never fatal', () {
      const csv = 'Date,Average HR (BPM),Sleep Duration,Deep Sleep,Spikes (count)\n'
          '2026-10-01,60,7h 0m,1h 0m,5\n'
          'not-a-date,60,7h 0m,1h 0m,5\n'
          '2026-10-02,60,banana,1h 0m,5\n'
          '2026-10-03,61,7h6m,45m,3\n';
      final parsed = parseMetricsCsv(csv);
      expect(parsed, isA<MetricsCsvParseSuccess>());
      final s = parsed as MetricsCsvParseSuccess;
      expect(s.rowsRead, 4);
      expect(s.rowsSkipped, 2);
      expect(s.rows.length, 2);
      // Compact 7h6m and bare 45m forms are accepted.
      final oct3 = s.rows.firstWhere((r) => r.date == '2026-10-03');
      expect(oct3.sleepMinutes, 426);
      expect(oct3.deepSleepMinutes, 45);
    });

    test('a CSV 0 cell is a failed read: fills nothing', () async {
      const csv = 'Date,Average HR (BPM),Sleep Duration,Deep Sleep,Spikes (count)\n'
          '2026-10-01,0,0h 0m,No data,0\n';
      final outcome = await importMetricsCsv(csvText: csv, store: store);
      expect(outcome, isA<MetricsImportOk>());
      final day = (await store.readAll())['2026-10-01'];
      // Spike 0 is real and stored; HR/sleep zeros are absent.
      expect(day, isNotNull);
      expect(day!.restingHrBpm, isNull);
      expect(day.sleepMinutes, isNull);
      expect(day.spikeCount, 0);
    });
  });
}

class _ThrowingHc extends HealthConnectService {
  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) =>
      throw StateError('boom');
}
