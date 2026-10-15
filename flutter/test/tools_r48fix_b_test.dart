import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/blood_pressure_tool_screen.dart';
import 'package:tabs_lab/src/features/tools/food_screen.dart';
import 'package:tabs_lab/src/features/tools/key_metrics_screen.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

import 'test_helpers.dart';

/// Round 48 fix round (seat γ) — Vera F4 / F5 / F8 + Juno F4.
///
/// - F4 Sleep: a selected date whose 10-night window has no real
///   night at or before it gets a null debt ("Deficit: --"), never a
///   fabricated "-0m", even when recent nights populate history.
/// - F5 Key Metrics: a failed / timed-out history read aborts the
///   CSV export (nothing written or shared, visible error), while a
///   genuinely-empty history still exports "No data"; a per-date
///   result built from a failed read is not cached, so re-selecting
///   the date re-reads it.
/// - Juno F4 Food: level normalization canonicalizes case variants
///   and common synonyms, defaults to "Low" ONLY for missing/empty,
///   and passes an unrecognized non-empty level through (native).
/// - F8 BP: the stored row id rides through BpUiRecord and delete
///   targets it, so a non-deterministic stored id is deletable.

TabsBackend _backend(Map<String, dynamic> pullBody) {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient(
        (_) async => http.Response(jsonEncode(pullBody), 200)),
    sessionStore: store,
  );
}

String _key(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void _bigSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

// ── Sleep fakes ─────────────────────────────────────────────────────

class _SleepFixHc extends HealthConnectService {
  _SleepFixHc(this.minutes);

  final Map<String, int?> minutes;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => minutes[dateStr];

  @override
  Future<SleepStages?> readSleepStages(String dateStr) async => null;
}

// ── Key Metrics fakes ───────────────────────────────────────────────

class _KmFixHc extends HealthConnectService {
  _KmFixHc({this.failExportHistory = false, this.emptyHistory = false});

  /// When true, the 30-day (export-range) history reads fail the way
  /// the real service reports a channel failure: empty result plus a
  /// recorded error code.
  final bool failExportHistory;

  /// When true, every history read cleanly returns nothing (a
  /// genuinely-empty history — no error code recorded).
  final bool emptyHistory;

  String? exportedFileName;
  String? exportedContent;
  final Map<String, int> sampleCalls = {};
  final Set<String> _sampleFailedOnce = {};

  String get _today => _key(DateTime.now());
  String get _yesterday => _key(DateTime.now().subtract(const Duration(days: 1)));

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    sampleCalls[dateStr] = (sampleCalls[dateStr] ?? 0) + 1;
    // Yesterday's FIRST read fails (recorded error code, empty
    // result); the retry succeeds — the F5(b) cache scenario.
    if (dateStr == _yesterday && _sampleFailedOnce.add(dateStr)) {
      lastReadErrorCode = 'READ_FAILED';
      return const [];
    }
    final now = DateTime.now();
    HrSample at(int hour, int bpm) => HrSample(
          timeMs: DateTime(now.year, now.month, now.day, hour)
              .millisecondsSinceEpoch,
          bpm: bpm,
        );
    return [at(8, 70), at(20, 90)]; // daytime average 80
  }

  @override
  Future<int?> readRestingHeartRate(String dateStr) async => 58;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async {
    if (failExportHistory && days == 30) {
      lastReadErrorCode = 'READ_FAILED';
      return const [];
    }
    if (emptyHistory) return const [];
    return [(date: _today, bpm: 58), (date: _yesterday, bpm: 58)];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      emptyHistory
          ? const []
          : [(date: _today, kcal: 500), (date: _yesterday, kcal: 500)];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    if (failExportHistory && days == 30) {
      lastReadErrorCode = 'READ_FAILED';
      return const [];
    }
    if (emptyHistory) return const [];
    return [(date: _today, mins: 450, deep: 120)];
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      emptyHistory ? const [] : [(date: _today, count: 2)];

  @override
  Future<double?> readLatestWeightKg() async => 71.0;

  @override
  Future<double?> readRespiratoryRate(String dateStr) async => 14.5;

  @override
  Future<double?> readOxygenSaturation(String dateStr) async => 98.0;

  @override
  Future<double?> readHrvRmssd(String dateStr) async => 42.4;

  @override
  Future<bool> exportCsvFile({
    required String fileName,
    required String content,
  }) async {
    exportedFileName = fileName;
    exportedContent = content;
    return true;
  }
}

// ── Blood Pressure fakes ────────────────────────────────────────────

class _BpDisconnectedHc extends HealthConnectService {
  @override
  Future<bool> isConnected() async => false;

  @override
  Future<List<BpRecord>> readBloodPressure(int days) async => const [];
}

class _BpServer {
  String? bpLogs;
  final List<Map<String, dynamic>> posts = [];

  TabsBackend backend() {
    final store = FakeSessionStore()..token = 'tok';
    return TabsBackend(
      client: MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'profile': {
                if (bpLogs != null) 'manualBloodPressureLogs': bpLogs,
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/profile' &&
            request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          posts.add(body);
          if (body['manualBloodPressureLogs'] is String) {
            bpLogs = body['manualBloodPressureLogs'] as String;
          }
          return http.Response(jsonEncode({'saved': true}), 200);
        }
        return http.Response('not found', 404);
      }),
      sessionStore: store,
    );
  }

  List<dynamic> bpRows() => jsonDecode(bpLogs ?? '[]') as List<dynamic>;
}

void main() {
  // ── Vera F4: Sleep debt ───────────────────────────────────────────

  group('sleepDebtMinsOrNull (Vera F4)', () {
    test('window with zero real nights at or before the date → null', () {
      final now = DateTime.now();
      final recentOnly = {
        for (var i = 0; i < 3; i++)
          _key(now.subtract(Duration(days: i))): 450,
      };
      final preHistory = _key(now.subtract(const Duration(days: 6)));
      // History is NOT empty (recent nights exist) — the old global
      // guard missed exactly this — but the selected date's window
      // holds no real night, so there is no debt to report.
      expect(sleepDebtMinsOrNull(recentOnly, preHistory), isNull);
      expect(sleepDebtMinsOrNull(const {}, _key(now)), isNull);
      expect(
        sleepDebtMinsOrNull(recentOnly,
            _key(now.subtract(const Duration(days: 30)))),
        isNull,
      );
    });

    test('windows with data keep the existing math, unchanged', () {
      final now = DateTime.now();
      final ten7h = {
        for (var i = 0; i < 10; i++)
          _key(now.subtract(Duration(days: i))): 420,
      };
      expect(sleepDebtMinsOrNull(ten7h, _key(now)), -600);
      final ten8h = {
        for (var i = 0; i < 10; i++)
          _key(now.subtract(Duration(days: i))): 480,
      };
      // A real 0 debt (data present) is 0, not null.
      expect(sleepDebtMinsOrNull(ten8h, _key(now)), 0);
      // Surplus over 8h capped at 1.5h of credit (existing math).
      final d1 = _key(now.subtract(const Duration(days: 1)));
      final d2 = _key(now);
      expect(sleepDebtMinsOrNull({d1: 420, d2: 600}, d2), 0);
      // A single real 7h night on the selected date → 1h of debt.
      expect(sleepDebtMinsOrNull({d2: 420}, d2), -60);
    });

    testWidgets('pre-history night shows Deficit: --, never -0m',
        (tester) async {
      _bigSurface(tester);
      final now = DateTime.now();
      final minutes = <String, int?>{
        _key(now): 450,
        _key(now.subtract(const Duration(days: 1))): 450,
        _key(now.subtract(const Duration(days: 2))): 450,
      };
      await _pump(
        tester,
        SleepScreen(
          backend: _backend({'profile': {}}),
          healthConnect: _SleepFixHc(minutes),
        ),
      );
      expect(find.text('Time Asleep Today'), findsOneWidget);
      // The oldest Recent Night (6 days ago) predates every real
      // night in history — its window is empty.
      await tester.tap(find.byIcon(Icons.bedtime).first);
      await tester.pumpAndSettle();
      expect(find.text('Daily Time Asleep'), findsOneWidget);
      expect(find.text('Deficit: --'), findsOneWidget);
      expect(find.text('Deficit: -0m'), findsNothing);
    });
  });

  // ── Vera F5: Key Metrics failure masking ──────────────────────────

  group('KeyMetrics export (Vera F5a)', () {
    testWidgets('failed history read aborts the export, shares nothing',
        (tester) async {
      _bigSurface(tester);
      final hc = _KmFixHc(failExportHistory: true);
      await _pump(
        tester,
        KeyMetricsScreen(
          backend: _backend({
            'profile': {'todayAvgHr': '78', 'weightKg': '70'},
          }),
          healthConnect: hc,
        ),
      );
      await tester.tap(find.byIcon(Icons.download));
      await tester.pumpAndSettle();
      expect(find.text('Export Biometrics CSV'), findsOneWidget);
      await tester.tap(find.text('Export'));
      // Short pumps only: let the async export run without letting
      // the SnackBar's auto-dismiss timer elapse.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(hc.exportedFileName, isNull);
      expect(hc.exportedContent, isNull);
      expect(
        find.text(
            'Export failed. Your history could not be read, so nothing was exported. Please try again.'),
        findsOneWidget,
      );
    });

    testWidgets('genuinely-empty history still exports No data rows',
        (tester) async {
      _bigSurface(tester);
      final hc = _KmFixHc(emptyHistory: true);
      await _pump(
        tester,
        KeyMetricsScreen(
          backend: _backend({
            'profile': {'todayAvgHr': '78', 'weightKg': '70'},
          }),
          healthConnect: hc,
        ),
      );
      await tester.tap(find.byIcon(Icons.download));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(hc.exportedFileName, 'jot_metrics_30d.csv');
      expect(hc.exportedContent, contains('Date,Average HR (BPM)'));
      expect(hc.exportedContent, contains('No data'));
      expect(
        find.text(
            'Export failed. Your history could not be read, so nothing was exported. Please try again.'),
        findsNothing,
      );
    });
  });

  group('KeyMetrics per-date cache (Vera F5b)', () {
    testWidgets(
        're-selecting a date after a failed read re-reads instead of '
        'serving the cached fake-empty', (tester) async {
      _bigSurface(tester);
      final hc = _KmFixHc();
      await _pump(
        tester,
        KeyMetricsScreen(
          backend: _backend({
            'profile': {'todayAvgHr': '78', 'weightKg': '70'},
          }),
          healthConnect: hc,
        ),
      );
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final yesterdayKey = _key(yesterday);

      // First selection of yesterday: the HR-sample read fails, so
      // the tile has no HR value and the result must not be cached.
      await tester.tap(find.text('${yesterday.day}'));
      await tester.pumpAndSettle();
      expect(hc.sampleCalls[yesterdayKey], 1);
      expect(find.text('80'), findsNothing);

      // Back to today, then yesterday again: a cached fake-empty
      // would leave the call count at 1 and keep the tile empty.
      await tester.tap(find.text('${DateTime.now().day}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('${yesterday.day}'));
      await tester.pumpAndSettle();
      expect(hc.sampleCalls[yesterdayKey], 2);
      expect(find.text('80'), findsOneWidget);
    });
  });

  // ── Juno F4: Food level normalization ─────────────────────────────

  group('normalizeFoodLevel (Juno F4)', () {
    test('canonicalizes case and whitespace variants', () {
      expect(normalizeFoodLevel('high'), 'High');
      expect(normalizeFoodLevel('HIGH'), 'High');
      expect(normalizeFoodLevel('High'), 'High');
      expect(normalizeFoodLevel('medium'), 'Medium');
      expect(normalizeFoodLevel(' Medium '), 'Medium');
      expect(normalizeFoodLevel('MEDIUM'), 'Medium');
      expect(normalizeFoodLevel('low'), 'Low');
      expect(normalizeFoodLevel('LoW'), 'Low');
    });

    test('maps common synonyms', () {
      expect(normalizeFoodLevel('moderate'), 'Medium');
      expect(normalizeFoodLevel('Moderate'), 'Medium');
      expect(normalizeFoodLevel('MODERATE'), 'Medium');
      expect(normalizeFoodLevel('very high'), 'High');
      expect(normalizeFoodLevel('Very High'), 'High');
      expect(normalizeFoodLevel('very-high'), 'High');
      expect(normalizeFoodLevel('mild'), 'Low');
      expect(normalizeFoodLevel('very low'), 'Low');
      expect(normalizeFoodLevel('severe'), 'High');
    });

    test('missing / empty is the ONLY Low fallback', () {
      expect(normalizeFoodLevel(null), 'Low');
      expect(normalizeFoodLevel(''), 'Low');
      expect(normalizeFoodLevel('   '), 'Low');
    });

    test('unrecognized non-empty levels pass through, never Low', () {
      expect(normalizeFoodLevel('Critical'), 'Critical');
      expect(normalizeFoodLevel('Elevated'), 'Elevated');
      expect(normalizeFoodLevel('banana'), 'banana');
      expect(normalizeFoodLevel(' trace '), 'trace');
      expect(normalizeFoodLevel('banana'), isNot('Low'));
    });

    test('parseFoodAiResponse applies the same rules end to end', () {
      final out = parseFoodAiResponse(
          '{"spinach": {'
          '"Histamine": {"level": "moderate", "reasoning": "x"},'
          '"Sugar": {"level": "Critical", "reasoning": "y"}'
          '}}');
      expect(out.single.levels[0].level, 'Medium'); // moderate
      expect(out.single.levels[1].level, 'Critical'); // passthrough
      expect(out.single.levels[2].level, 'Low'); // missing topic
    });
  });

  // ── Vera F8: BP delete identity ───────────────────────────────────

  group('BP stored id (Vera F8)', () {
    test('bpUiRecordsFromRaw carries the stored id into manualId', () {
      final rows = decodeBpLogsRaw(jsonEncode([
        {
          'systolic': 131,
          'diastolic': 84,
          'timeEpochMs': 1700100000000,
          'id': 'legacy-row-42',
          'source': 'MANUAL',
        },
        {'systolic': 118, 'diastolic': 76, 'timeEpochMs': 1000},
      ]));
      final ui = bpUiRecordsFromRaw(rows);
      expect(ui, hasLength(2));
      expect(ui[0].storedId, 'legacy-row-42');
      expect(ui[0].manualId, 'legacy-row-42');
      // No stored id → the deterministic fallback, exactly as before.
      expect(ui[1].storedId, isNull);
      expect(ui[1].manualId, 'manual_1000_118_76');
      // The splice that delete uses removes the stored-id row.
      final next = bpLogsWithoutId(rows, ui[0].manualId);
      expect(next, isNotNull);
      expect(next!, hasLength(1));
      expect(bpRowValues(next.single)!.systolic, 118);
    });

    test('mergeBpUiRecords keeps the stored id; HC still wins dedupe',
        () {
      final manual = bpUiRecordsFromRaw([
        {
          'systolic': 131,
          'diastolic': 84,
          'timeEpochMs': 2000,
          'id': 'legacy-row-42',
        },
        {'systolic': 120, 'diastolic': 80, 'timeEpochMs': 1000, 'id': 'x1'},
      ]);
      final merged = mergeBpUiRecords(
        manual: manual,
        healthConnect: const [
          BpRecord(systolic: 122, diastolic: 82, timeEpochMs: 1000),
        ],
      );
      expect(merged, hasLength(2));
      expect(merged.first.record.timeEpochMs, 2000);
      expect(merged.first.manualId, 'legacy-row-42');
      // The 1000ms collision is the Health Connect copy, as before.
      expect(merged.last.source, BpSource.healthConnect);
      expect(merged.last.record.systolic, 122);
    });

    testWidgets('delete succeeds for a non-deterministic stored id',
        (tester) async {
      _bigSurface(tester);
      final server = _BpServer();
      server.bpLogs = jsonEncode([
        {
          'systolic': 131,
          'diastolic': 84,
          'timeEpochMs': 1700100000000,
          'id': 'legacy-row-42',
          'source': 'MANUAL',
        },
        {'systolic': 118, 'diastolic': 76, 'timeEpochMs': 1700000000000},
      ]);
      await _pump(
        tester,
        BloodPressureToolScreen(
          backend: server.backend(),
          healthConnect: _BpDisconnectedHc(),
        ),
      );
      expect(find.text('131 / 84 mmHg'), findsOneWidget);
      // Newest row (the stored-id one) — its delete icon is first.
      await tester.tap(find.byIcon(Icons.delete).first);
      await tester.pumpAndSettle();
      expect(find.text('Delete Manual Reading?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      final rows = server.bpRows();
      expect(rows, hasLength(1));
      expect((rows.single as Map)['systolic'], 118);
      expect(find.text('131 / 84 mmHg'), findsNothing);
    });
  });
}
