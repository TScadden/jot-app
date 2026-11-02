import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/heart_data.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

import 'test_helpers.dart';

/// Perf package (Nov 2, 2026) — instant paint for biometric screens.
///
/// Pins:
/// - Sleep paints hero + Recent Nights from the local history store
///   BEFORE the Health Connect connection verdict even lands, and a
///   full open then costs exactly ONE range read and ZERO per-day
///   sleep-minutes reads.
/// - HeartDataCache freshness: a successful load stamps its date
///   fresh for the 5-minute window; a FAILED load never stamps.
/// - The Heart screen performs NO Health Connect read when its
///   painted cache entry is fresh, and exactly one when it is stale.
/// - Home's vitals load writes its HR series through to the Heart
///   cache (clean reads only), so Home → Heart shares one read.
/// - Chart downsampling bounds the point count, preserves the exact
///   peak sample, and only ever emits real samples.

String _key(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class _MemStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void _bindMem(HeartDataCache cache, _MemStore mem) {
  cache.debugSetStore(read: mem.read, write: mem.write, delete: mem.delete);
}

// ── Sleep fakes ─────────────────────────────────────────────────────

class _PaintHc extends HealthConnectService {
  final Completer<bool> connectedGate = Completer<bool>();
  int minutesCalls = 0;
  int rangeCalls = 0;

  @override
  Future<bool> isConnected() => connectedGate.future;

  @override
  Future<int?> readSleepMinutes(String dateStr) async {
    minutesCalls++;
    return null;
  }

  @override
  Future<SleepStages?> readSleepStages(String dateStr) async => null;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    rangeCalls++;
    return const [];
  }
}

TabsBackend _backend() {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient(
        (_) async => http.Response(jsonEncode({'profile': {}}), 200)),
    sessionStore: store,
  );
}

// ── Heart fakes ─────────────────────────────────────────────────────

class _CountingHeartHc extends HealthConnectService {
  int readCount = 0;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<bool> hasPersistedConnection() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    readCount++;
    return const [];
  }
}

int _todayMs(int hour) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour).millisecondsSinceEpoch;
}

void main() {
  group('HeartDataCache freshness (perf package)', () {
    setUp(() {
      HeartDataCache.instance.debugReset();
      _bindMem(HeartDataCache.instance, _MemStore());
    });

    test('a successful load is fresh inside the window, stale after', () {
      final cache = HeartDataCache.instance;
      final t0 = DateTime(2026, 11, 2, 9);
      cache.apply(
        '2026-11-02',
        [HrSample(timeMs: t0.millisecondsSinceEpoch, bpm: 72)],
        now: t0,
      );
      expect(cache.isFresh('2026-11-02', now: t0), isTrue);
      expect(
          cache.isFresh('2026-11-02',
              now: t0.add(const Duration(minutes: 4))),
          isTrue);
      expect(
          cache.isFresh('2026-11-02',
              now: t0.add(const Duration(minutes: 6))),
          isFalse);
      expect(cache.isFresh('2026-11-03', now: t0), isFalse,
          reason: 'a date never loaded is never fresh');
    });

    test('a FAILED load never stamps freshness', () {
      final cache = HeartDataCache.instance;
      final t0 = DateTime(2026, 11, 2, 9);
      cache.apply('2026-11-02', const [], succeeded: false, now: t0);
      expect(cache.isFresh('2026-11-02', now: t0), isFalse);
      expect(cache.hasDate('2026-11-02'), isFalse);
    });

    test('zero samples are never cached as fresh data', () {
      final cache = HeartDataCache.instance;
      final t0 = DateTime(2026, 11, 2, 9);
      final data = cache.apply(
        '2026-11-02',
        [HrSample(timeMs: t0.millisecondsSinceEpoch, bpm: 0)],
        now: t0,
      );
      expect(data.samples, isEmpty,
          reason: 'a 0 bpm sample is a failed read, never stored');
    });
  });

  group('downsampleHrForChart (perf package)', () {
    test('short series pass through (valid-filtered only)', () {
      final base = DateTime(2026, 11, 2, 8).millisecondsSinceEpoch;
      final samples = [
        HrSample(timeMs: base, bpm: 0), // failed read — dropped
        HrSample(timeMs: base + 60000, bpm: 70),
        HrSample(timeMs: base + 120000, bpm: 80),
      ];
      final out = downsampleHrForChart(samples, 512);
      expect(out.map((s) => s.bpm), [70, 80]);
    });

    test('long series: bounded, peak exact, only real samples', () {
      final base = DateTime(2026, 11, 2).millisecondsSinceEpoch;
      // One sample per minute for a full day; a single peak of 187
      // at minute 631 and a single trough of 41 at minute 200.
      final samples = [
        for (var i = 0; i < 1440; i++)
          HrSample(
            timeMs: base + i * 60000,
            bpm: i == 631 ? 187 : (i == 200 ? 41 : 60 + (i % 40)),
          ),
      ];
      final out = downsampleHrForChart(samples, 512);
      expect(out.length, lessThanOrEqualTo(512));
      expect(out.length, greaterThan(100),
          reason: 'downsampled, not decimated to a stub');
      final peak = out.reduce((a, b) => a.bpm >= b.bpm ? a : b);
      expect(peak.bpm, 187);
      expect(peak.timeMs, base + 631 * 60000,
          reason: 'the peak marker keeps the peak sample\'s own time');
      expect(out.map((s) => s.bpm), contains(41),
          reason: 'bucket minima survive too');
      final realTimes = samples.map((s) => s.timeMs).toSet();
      expect(out.every((s) => realTimes.contains(s.timeMs)), isTrue,
          reason: 'every chart point is a real sample — none invented');
      for (var i = 1; i < out.length; i++) {
        expect(out[i].timeMs, greaterThanOrEqualTo(out[i - 1].timeMs),
            reason: 'time order preserved');
      }
    });
  });

  group('Heart screen freshness skip (perf package)', () {
    setUp(() {
      HeartDataCache.instance.debugReset();
      _bindMem(HeartDataCache.instance, _MemStore());
    });

    testWidgets('fresh cache paints with ZERO Health Connect reads',
        (tester) async {
      final cache = HeartDataCache.instance;
      cache.apply(
        _key(DateTime.now()),
        [
          HrSample(timeMs: _todayMs(8), bpm: 70),
          HrSample(timeMs: _todayMs(9), bpm: 80),
          HrSample(timeMs: _todayMs(10), bpm: 90),
        ],
        now: DateTime.now(),
      );
      final hc = _CountingHeartHc();
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(healthConnectService: hc, cache: cache),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('Peak 90 bpm'), findsOneWidget,
          reason: 'the cached series is what painted');
      expect(find.text('Updating sync data...'), findsNothing);
      expect(hc.readCount, 0,
          reason: 'a fresh cached date must not re-read Health Connect');
    });

    testWidgets('stale cache still revalidates with one read',
        (tester) async {
      final cache = HeartDataCache.instance;
      cache.apply(
        _key(DateTime.now()),
        [HrSample(timeMs: _todayMs(8), bpm: 70)],
        now: DateTime.now().subtract(const Duration(minutes: 10)),
      );
      final hc = _CountingHeartHc();
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(healthConnectService: hc, cache: cache),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(hc.readCount, 1,
          reason: 'outside the fresh window the load runs as before');
    });
  });

  group('HealthRepository HR write-through (perf package)', () {
    setUp(() {
      HeartDataCache.instance.debugReset();
      _bindMem(HeartDataCache.instance, _MemStore());
    });

    HealthRepository repoWith(HealthConnectService hc) => HealthRepository(
          hc: hc,
          backend: TabsBackend(
            client: MockClient((_) async =>
                http.Response(jsonEncode({'entries': []}), 200)),
            sessionStore: FakeSessionStore()..token = 'tok',
          ),
        );

    test('a clean vitals read lands in the Heart cache, fresh', () async {
      final hc = _RepoHc(samples: [
        HrSample(timeMs: _todayMs(10), bpm: 70),
        HrSample(timeMs: _todayMs(12), bpm: 80),
      ]);
      final vitals = await repoWith(hc).loadTodayVitals(connected: true);
      expect(vitals.heartRate, 75);
      final today = _key(DateTime.now());
      expect(HeartDataCache.instance.isFresh(today), isTrue);
      expect(HeartDataCache.instance.snapshot(today)?.samples, hasLength(2));
    });

    test('a FAILED vitals read writes nothing through', () async {
      final hc = _RepoHc(samples: const [], fail: true);
      final vitals = await repoWith(hc).loadTodayVitals(connected: true);
      expect(vitals.heartRate, isNull);
      final today = _key(DateTime.now());
      expect(HeartDataCache.instance.hasDate(today), isFalse);
      expect(HeartDataCache.instance.isFresh(today), isFalse);
    });

    test('a PARTIAL vitals read writes nothing through', () async {
      // A partial read returns real samples with some chunks
      // missing and records ONLY lastPartialErrorCode (F2) — the
      // write-through gate must still refuse it, or the Heart
      // screen would paint the incomplete series as fresh and
      // complete inside the freshness window.
      final hc = _RepoHc(
        samples: [
          HrSample(timeMs: _todayMs(10), bpm: 70),
          HrSample(timeMs: _todayMs(12), bpm: 80),
        ],
        partial: true,
      );
      final vitals = await repoWith(hc).loadTodayVitals(connected: true);
      expect(vitals.heartRate, 75,
          reason: 'partial data still serves the Home vitals strip');
      final today = _key(DateTime.now());
      expect(HeartDataCache.instance.hasDate(today), isFalse,
          reason: 'a partial series must never enter the Heart cache');
      expect(HeartDataCache.instance.isFresh(today), isFalse,
          reason: 'a partial read must never stamp freshness');
    });
  });

  group('Sleep instant paint (perf package)', () {
    testWidgets(
        'store data paints before the HC verdict lands; one open = '
        'one range read, zero per-day reads', (tester) async {
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final mem = _MemStore();
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(read: mem.read, write: mem.write, delete: mem.delete);
      store.debugReset();
      final now = DateTime.now();
      await store.mergeRefresh([
        for (var i = 9; i >= 0; i--)
          DailyBiometrics(
            date: _key(now.subtract(Duration(days: i))),
            sleepMinutes: i == 0 ? 450 : 480,
          ),
      ]);

      final hc = _PaintHc();
      await tester.pumpWidget(MaterialApp(
        home: SleepScreen(
          backend: _backend(),
          healthConnect: hc,
          historyQueries: HealthHistoryQueries(hc: hc, store: store),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The connection verdict has NOT landed yet (gate pending) —
      // the store's real last data is already on screen.
      expect(find.text('Time Asleep Today'), findsOneWidget);
      expect(find.text('7h30m'), findsWidgets,
          reason: 'today\'s stored 450 minutes paint instantly');
      expect(find.text('Recent Nights'), findsOneWidget);

      hc.connectedGate.complete(true);
      await tester.pumpAndSettle();

      expect(hc.rangeCalls, 1,
          reason: 'the whole fresh load is one range read');
      expect(hc.minutesCalls, 0,
          reason: 'no per-day readSleepMinutes calls in one open');
      expect(find.text('7h30m'), findsWidgets,
          reason: 'the fresh load swaps in the same real data');
    });

    testWidgets('empty store: no invented paint, per-day fallback runs',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final mem = _MemStore();
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(read: mem.read, write: mem.write, delete: mem.delete);
      store.debugReset();

      final hc = _FallbackHc();
      await tester.pumpWidget(MaterialApp(
        home: SleepScreen(
          backend: _backend(),
          healthConnect: hc,
          historyQueries: HealthHistoryQueries(hc: hc, store: store),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('7h30m'), findsWidgets,
          reason: 'per-day data still loads exactly as before');
      expect(hc.minutesCalls, greaterThan(0),
          reason: 'a range read that yields nothing falls back');
    });
  });
}

/// Repository fake: serves fixed samples, fails the read the way
/// the real service does (empty result + recorded error code), or
/// returns a PARTIAL read the way the real service does (real
/// samples + only the partial code recorded, per F2).
class _RepoHc extends HealthConnectService {
  _RepoHc({required this.samples, this.fail = false, this.partial = false});

  final List<HrSample> samples;
  final bool fail;
  final bool partial;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    if (fail) {
      lastReadErrorCode = 'READ_FAILED';
      return const [];
    }
    if (partial) {
      lastPartialErrorCode = 'HR_SAMPLES_PARTIAL';
    }
    return samples;
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => null;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => null;
}

/// Sleep fake with NO range read (the bridge returns nothing and
/// records no error) but real per-day minutes — the fallback path.
class _FallbackHc extends HealthConnectService {
  int minutesCalls = 0;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<int?> readSleepMinutes(String dateStr) async {
    minutesCalls++;
    return 450;
  }

  @override
  Future<SleepStages?> readSleepStages(String dateStr) async => null;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    // A clean, genuinely-empty range read: the union succeeds with
    // no rows, so _loadWindowFromUnion must fall back per-day.
    return const [];
  }
}
