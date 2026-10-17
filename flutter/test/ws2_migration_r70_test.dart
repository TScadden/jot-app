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
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/features/tools/key_metrics_screen.dart';

import 'test_helpers.dart';

/// R70 WS2 — migration proofs: readers serve the store's depth,
/// availability counts are the union's honest counts, and the
/// Key Metrics CSV export reflects stored depth.

class _Mem {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

HealthHistoryStore _freshStore(_Mem mem) {
  final s = HealthHistoryStore.testInstance();
  s.debugSetStore(read: mem.read, write: mem.write, delete: mem.delete);
  s.debugReset();
  return s;
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _ago(int n) => _ds(DateTime.now().subtract(Duration(days: n)));

class _FakeHc extends HealthConnectService {
  bool connected = true;
  List<({String date, int bpm})> hr = const [];
  List<({String date, int kcal})> cal = const [];
  List<({String date, int mins, int deep})> sleep = const [];
  List<({String date, int count})> spikes = const [];
  String? exportedContent;
  String? exportedFileName;

  @override
  Future<bool> isConnected() async => connected;
  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      hr;
  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      cal;
  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      sleep;
  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      spikes;
  @override
  Future<double?> readHrvRmssd(String dateStr) async => null;
  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async =>
      const [];
  @override
  Future<int?> readRestingHeartRate(String dateStr) async => null;
  @override
  Future<double?> readLatestWeightKg() async => null;
  @override
  Future<double?> readRespiratoryRate(String dateStr) async => null;
  @override
  Future<double?> readOxygenSaturation(String dateStr) async => null;
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

class _FakeBackend extends TabsBackend {
  _FakeBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};
  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => const [];
  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];
}

TabsBackend _backend() {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient((_) async =>
        http.Response(jsonEncode({'profile': {'weightKg': 70}}), 200)),
    sessionStore: store,
  );
}

void main() {
  group('report collector — union depth', () {
    test('store seeded deeper than the HC window: series + '
        'availability counts reflect the deeper union', () async {
      final store = _freshStore(_Mem());
      // 100 stored days of sleep + HR ending yesterday; HC's own
      // window only returns the most recent 5 days (fresher HR).
      await store.mergeRefresh([
        for (var i = 100; i >= 1; i--)
          DailyBiometrics(
              date: _ago(i), restingHrBpm: 60, sleepMinutes: 420),
      ]);
      final hc = _FakeHc()
        ..sleep = [
          for (var i = 5; i >= 1; i--) (date: _ago(i), mins: 430, deep: 60),
        ]
        ..hr = [
          for (var i = 5; i >= 1; i--) (date: _ago(i), bpm: 63),
        ];
      final collector = ReportDataCollector(
        backend: _FakeBackend(),
        hc: hc,
        historyQueries: HealthHistoryQueries(hc: hc, store: store),
      );
      final snap = await collector.collect(
        selectedCategories: const [],
        last30Days: false,
        profile: const ReportProfileInput(),
        now: DateTime.now(),
      );
      // The 180-day union holds all 100 stored days.
      expect(snap.sleepSeries.length, 100);
      expect(snap.heartRateSeries.length, 100);
      expect(snap.sectionMetadata['sleep']!.recordCount, 100);
      expect(snap.sectionMetadata['heartRate']!.recordCount, 100);
      expect(snap.sectionMetadata['sleep']!.status,
          DataSourceStatus.success);
      // Fresh HC wins inside its window.
      expect(snap.sleepSeries.last, (_ago(1), 430));
      expect(snap.heartRateSeries.last, (_ago(1), 63));
      // Older days keep the stored values.
      expect(snap.sleepSeries.first, (_ago(100), 420));
      expect(snap.heartRateSeries.first, (_ago(100), 60));
    });
  });

  group('weekly snapshot — store-only depth', () {
    test('resting HR snapshot is served from the store when HC '
        'returns nothing', () async {
      final store = _freshStore(_Mem());
      await store.mergeRefresh([
        for (var i = 6; i >= 0; i--)
          DailyBiometrics(date: _ago(i), restingHrBpm: 60),
      ]);
      final hc = _FakeHc(); // every HC range read empty
      final repo = HealthRepository(
        hc: hc,
        backend: _backend(),
        historyQueries: HealthHistoryQueries(hc: hc, store: store),
      );
      final data = await repo.loadSnapshot(SnapshotMetric.restingHeartRate);
      expect(data.points, hasLength(7));
      expect(data.points.every((p) => p.value == 60.0), isTrue);
      expect(data.averageOrTotalText, '7-Day Avg: 60 bpm');
    });

    test('snapshot builders unchanged for identical inputs (golden)',
        () {
      final window = sevenDayWindow();
      final dateStrs = [for (final w in window) w.dateStr];
      final labels = [for (final w in window) w.dayLabel];
      final sleep = buildSleepMetric(
          dateStrs, labels, {for (final d in dateStrs) d: 480});
      expect(sleep.averageOrTotalText, '7-Day Avg: 8h0m');
      final spikes =
          buildSpikesMetric(dateStrs, labels, {dateStrs.last: 3});
      expect(spikes.averageOrTotalText, '7-Day Total: 3 spikes');
    });
  });

  group('key metrics export — stored depth in the CSV', () {
    testWidgets('a stored day HC no longer holds exports its real '
        'values instead of No data', (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final store = _freshStore(_Mem());
      // A day 25 days back exists ONLY in the store.
      await store.mergeRefresh([
        DailyBiometrics(
            date: _ago(25), restingHrBpm: 61, sleepMinutes: 432),
      ]);
      final hc = _FakeHc()
        ..hr = [(date: _ago(0), bpm: 58)]
        ..sleep = [(date: _ago(0), mins: 450, deep: 60)];
      await tester.pumpWidget(MaterialApp(
        home: KeyMetricsScreen(
          backend: _backend(),
          healthConnect: hc,
          historyQueries: HealthHistoryQueries(hc: hc, store: store),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.download));
      await tester.pumpAndSettle();
      expect(find.text('Export Biometrics CSV'), findsOneWidget);
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(hc.exportedFileName, 'jot_metrics_30d.csv');
      final csv = hc.exportedContent!;
      // The deep stored row: its date, its HR, its sleep (7h12m).
      final deepRow =
          csv.split('\n').firstWhere((l) => l.contains(_ago(25)));
      expect(deepRow, contains('61'));
      expect(deepRow, contains('7h12m'));
    });
  });
}
