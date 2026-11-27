import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_report.dart';

import 'test_helpers.dart';

// ── Weekly Report Package 1 — the collector's weekly range
// mode and Vera's throwing fixtures at the collection layer.
//
// The weekly mode must collect EXACTLY the fixed Mon–Sun
// calendar range (entries, stored scores, BP, and the HC union
// via loadRange) under the SAME availability derivation as the
// standard ranges — and the permission-needed gate downstream
// depends on the derivation keeping its states distinct:
//   • true denial   → permissionDenied (gate may fire)
//   • false denial  → stale ("shown as granted, but read
//     blocked"; the grant is present, the read failed with a
//     SecurityException — e.g. permission revoked mid-flight)
//   • the two are never collapsed (Juno §d Flag 3, spec P3).
//
// Fixture week: Mon Nov 9 – Sun Nov 15, 2026.

const _sleepPerm = 'android.permission.health.READ_SLEEP';

final _weekStart = DateTime(2026, 11, 9);
final _weekEnd = DateTime(2026, 11, 15);
final _now = DateTime(2026, 11, 18, 12);

QuickLogEntry _entry(int id, DateTime day) => QuickLogEntry(
      id: id,
      categoryId: '1',
      body: 'entry $id',
      chips: '',
      manualText: '',
      timestamp:
          DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch,
    );

class _Backend extends TabsBackend {
  _Backend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => [
        _entry(1, DateTime(2026, 11, 8)), // Sunday BEFORE the week
        _entry(2, DateTime(2026, 11, 9)), // Monday of the week
        _entry(3, DateTime(2026, 11, 15)), // Sunday of the week
        _entry(4, DateTime(2026, 11, 16)), // Monday AFTER the week
      ];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => [
        BpRecord(
            systolic: 150,
            diastolic: 95,
            timeEpochMs: DateTime(2026, 11, 8, 12).millisecondsSinceEpoch),
        BpRecord(
            systolic: 120,
            diastolic: 80,
            timeEpochMs: DateTime(2026, 11, 12, 12).millisecondsSinceEpoch),
      ];
}

QuickLogEntry _entryAt(int id, DateTime at) => QuickLogEntry(
      id: id,
      categoryId: '1',
      body: 'entry $id',
      chips: '',
      manualText: '',
      timestamp: at.millisecondsSinceEpoch,
    );

/// Boundary-instant entries for the fall-back DST week
/// (Mon Oct 26 – Sun Nov 1, 2026, America/Denver).
class _DstBackend extends TabsBackend {
  _DstBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => [
        _entryAt(10, DateTime(2026, 10, 25, 23, 30)), // before — out
        _entryAt(11, DateTime(2026, 10, 26, 0, 30)), // Mon 00:30 — in
        _entryAt(12, DateTime(2026, 11, 1, 23, 30)), // Sun last hr — in
        _entryAt(13, DateTime(2026, 11, 2, 0, 30)), // next Mon — out
      ];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];
}

enum _ReadMode { healthy, failGeneric, failSecurity }

/// Fake HC in the real service's fail-closed shape (mirrors the
/// Report Reliability Phase 1/2 fixture): a failed read returns
/// [] and records its error code/detail on the instance first.
class _FakeHc extends HealthConnectService {
  Set<String> missing = const {};
  _ReadMode sleepMode = _ReadMode.healthy;

  List<({String date, int mins, int deep})> sleepHist = const [
    (date: '2026-11-10', mins: 420, deep: 80),
    (date: '2026-11-12', mins: 450, deep: 90),
    (date: '2026-11-16', mins: 999, deep: 99), // outside the week
  ];

  @override
  Future<Set<String>> getMissingPermissions() async => missing;

  Future<bool> _failSleep() async {
    await Future<void>.delayed(Duration.zero);
    switch (sleepMode) {
      case _ReadMode.healthy:
        return false;
      case _ReadMode.failGeneric:
        lastReadErrorCode = 'SLEEP_HISTORY_READ_FAILED';
        lastReadErrorDetails = 'IOException';
        return true;
      case _ReadMode.failSecurity:
        lastReadErrorCode = 'SLEEP_HISTORY_READ_FAILED';
        lastReadErrorDetails = 'SecurityException';
        return true;
    }
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      await _failSleep() ? const [] : sleepHist;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [(date: '2026-11-11', bpm: 62)];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [(date: '2026-11-11', kcal: 2100)];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [(date: '2026-11-11', count: 2)];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async => [
        (
          t: DateTime(2026, 11, 11, 12).millisecondsSinceEpoch,
          ms: 55.0,
          tier: 100,
        ),
      ];
}

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
    id: id,
    name: name,
    icon: 'x',
    colorHex: '#FF0000',
    isDefault: true,
    sortOrder: id);

void main() {
  late Map<String, String> disk;
  late HealthHistoryStore store;
  late _FakeHc hc;
  late _Backend backend;

  setUp(() {
    disk = <String, String>{};
    store = HealthHistoryStore.testInstance();
    store.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    store.debugReset();
    hc = _FakeHc();
    backend = _Backend();
  });

  Future<ReportSnapshot> collectWeekly() => ReportDataCollector(
        backend: backend,
        hc: hc,
        historyQueries: HealthHistoryQueries(hc: hc, store: store),
        insightsLoader: () async => const [],
        scoreLoader: () async => {
          '2026-11-08': 99, // previous Sunday — outside
          '2026-11-09': 60,
          '2026-11-11': 62,
          '2026-11-15': 64,
          '2026-11-16': 98, // next Monday — outside
        },
      ).collect(
        selectedCategories: [_cat(1, 'Symptoms')],
        last30Days: false,
        profile: const ReportProfileInput(),
        now: _now,
        weekStart: _weekStart,
        weekEnd: _weekEnd,
      );

  group('weekly range mode', () {
    test('collects exactly the Mon–Sun range in every section', () async {
      final snap = await collectWeekly();
      expect(snap.isWeekly, isTrue);
      expect(snap.durationDays, 7);
      expect(snap.rangeTypeName, 'WEEKLY');
      expect(snap.weekStart, _weekStart);
      expect(snap.weekEnd, _weekEnd);

      // Entries: only the week's Monday and Sunday survive.
      expect(snap.logEntries.map((e) => e.id), [2, 3]);

      // Stored scores: exactly the week's days that hold scores.
      expect(snap.dailyScoreSeries, [
        ('2026-11-09', 60),
        ('2026-11-11', 62),
        ('2026-11-15', 64),
      ]);

      // BP: only the in-week reading.
      expect(snap.bloodPressureSeries.length, 1);
      expect(snap.bloodPressureSeries.single.systolic, 120);

      // HC union via loadRange: the Nov 16 row must not leak in.
      expect(snap.sleepSeries, [
        ('2026-11-10', 420),
        ('2026-11-12', 450),
      ]);
      expect(snap.sectionMetadata['sleep']!.status, DataSourceStatus.success);
      expect(snap.sectionMetadata['sleep']!.recordCount, 2);
    });

    test('fall-back DST week: the collector range stops exactly at '
        'true local midnights (Mon Oct 26 – Sun Nov 1, 2026)', () async {
      // Bites only in a DST zone — run under TZ=America/Denver.
      // Pre-fix, the exclusive end was Sunday 00:00 + 24h of
      // absolute time = Sunday 23:00 local on the 25-hour day,
      // dropping Sunday's last hour (Vera MINOR 2).
      final snap = await ReportDataCollector(
        backend: _DstBackend(),
        hc: hc,
        historyQueries: HealthHistoryQueries(hc: hc, store: store),
        insightsLoader: () async => const [],
        scoreLoader: () async => {
          '2026-10-26': 61,
          '2026-11-01': 63,
          '2026-11-02': 99, // next Monday — outside, must not appear
        },
      ).collect(
        selectedCategories: [_cat(1, 'Symptoms')],
        last30Days: false,
        profile: const ReportProfileInput(),
        now: DateTime(2026, 11, 4, 12),
        weekStart: DateTime(2026, 10, 26),
        weekEnd: DateTime(2026, 11, 1),
      );
      expect(snap.logEntries.map((e) => e.id), [11, 12]);
      expect(snap.dailyScoreSeries, [
        ('2026-10-26', 61),
        ('2026-11-01', 63),
      ]);
    });

    test('a standard range is untouched by weekly mode', () async {
      final snap = await ReportDataCollector(
        backend: backend,
        hc: hc,
        historyQueries: HealthHistoryQueries(hc: hc, store: store),
        insightsLoader: () async => const [],
        scoreLoader: () async => {'2026-11-16': 70},
      ).collect(
        selectedCategories: [_cat(1, 'Symptoms')],
        last30Days: false,
        profile: const ReportProfileInput(),
        now: _now,
      );
      expect(snap.isWeekly, isFalse);
      expect(snap.durationDays, 180);
      expect(snap.rangeTypeName, 'FULL');
      expect(snap.logEntries.length, 4,
          reason: 'the All Time range keeps every entry');
    });
  });

  group('throwing fixtures — the permission gate\u2019s inputs', () {
    test('TRUE denial: sleep read fails and the probe\u2019s missing '
        'set names the sleep permission → permissionDenied, and '
        'the evaluator blocks the week naming Sleep', () async {
      hc.sleepMode = _ReadMode.failGeneric;
      hc.missing = {_sleepPerm};
      final snap = await collectWeekly();
      expect(snap.sectionMetadata['sleep']!.status,
          DataSourceStatus.permissionDenied);
      expect(snap.sleepSeries, isEmpty);

      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: WeeklyWeekWindow(_weekStart, _weekEnd),
        generationCompleted: true,
      );
      expect(ev.label, WeeklyCompleteness.blocked);
      expect(ev.blockedSections, contains('Sleep'));
      expect(ev.contradiction, isFalse);
    });

    test('FALSE denial / revoked mid-generation: the read fails '
        'with a SecurityException while the grant is present → '
        'stale, never permissionDenied; the gate stays unfired',
        () async {
      hc.sleepMode = _ReadMode.failSecurity;
      hc.missing = const {}; // grant present at probe time
      final snap = await collectWeekly();
      expect(snap.sectionMetadata['sleep']!.status, DataSourceStatus.stale);

      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: WeeklyWeekWindow(_weekStart, _weekEnd),
        generationCompleted: true,
      );
      expect(ev.blockedSections, isNot(contains('Sleep')));
      expect(ev.label, isNot(WeeklyCompleteness.blocked));
    });

    test('read failure with an UNKNOWN grant (no missing-set '
        'evidence either way) derives error, not a denial', () async {
      hc.sleepMode = _ReadMode.failGeneric;
      hc.missing = const {}; // nothing missing, yet the read failed
      final snap = await collectWeekly();
      expect(snap.sectionMetadata['sleep']!.status,
          isNot(DataSourceStatus.permissionDenied));
    });
  });
}
