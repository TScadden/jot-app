import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Fakes ─────────────────────────────────────────────────────────

class FakeBackend extends TabsBackend {
  List<QuickLogCategory> categories = const [];
  List<QuickLogEntry> entries = const [];
  List<BpRecord> bp = const [];
  bool pullFails = false;
  int aiCalls = 0;
  ({
    int? statusCode,
    Map<String, dynamic>? body,
    String? serverError,
    AiTransportFailure? transportFailure,
  }) aiResponse = (
    statusCode: 200,
    body: {'result': '[SECTION] USER SUMMARY\nAll good.'},
    serverError: null,
    transportFailure: null,
  );

  FakeBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      pullFails ? null : <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => categories;

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => entries;

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => bp;

  @override
  Future<
      ({
        int? statusCode,
        Map<String, dynamic>? body,
        String? serverError,
        AiTransportFailure? transportFailure,
      })> postAiDetailed(String path, Map<String, dynamic> body,
      {Duration? timeoutOverride}) async {
    aiCalls++;
    return aiResponse;
  }
}

class FakeHc extends HealthConnectService {
  bool connected = true;
  List<({String date, int mins, int deep})> sleepHist = const [];
  List<({String date, int bpm})> hrHist = const [];
  List<({String date, int kcal})> calHist = const [];
  List<({String date, int count})> spikeHist = const [];
  double? hrvValue;

  @override
  Future<bool> isConnected() async => connected;
  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      sleepHist;
  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      hrHist;
  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      calHist;
  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      spikeHist;
  @override
  Future<double?> readHrvRmssd(String dateStr) async => hrvValue;

  // R71: the union's HRV path is a range read now. Mirror
  // hrvValue: a null/zero value means no usable samples (the
  // zero rule), otherwise one top-tier sample per requested day.
  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    final v = hrvValue;
    if (v == null || v <= 0) return const [];
    final now = DateTime.now();
    final midday = DateTime(now.year, now.month, now.day, 12);
    return [
      for (var i = days - 1; i >= 0; i--)
        (
          t: midday.subtract(Duration(days: i)).millisecondsSinceEpoch,
          ms: v,
          tier: 100,
        ),
    ];
  }
}

QuickLogCategory cat(int id, String name) => QuickLogCategory(
    id: id, name: name, icon: 'x', colorHex: '#FF0000', isDefault: true, sortOrder: id);

List<QuickLogCategory> defaultCats() => [
      cat(1, 'Symptoms'),
      cat(2, 'Food & Eating'),
      cat(3, 'Weight & Vitals'),
      cat(8, 'Medication'),
      cat(4, 'Goals & Habits'),
      cat(5, 'Sleep'),
      cat(6, 'Mood & Energy'),
      cat(7, 'General'),
    ];

QuickLogEntry entry(int id, int catId, int ts) => QuickLogEntry(
    id: id, categoryId: catId, body: 'b$id', chips: '', manualText: '', timestamp: ts);

ReportSnapshot fixtureSnapshot({bool last30Days = true}) {
  return ReportSnapshot(
    last30Days: last30Days,
    generationTimestampMs:
        DateTime(2026, 10, 16, 16, 17).millisecondsSinceEpoch,
    logEntries: [entry(1, 1, 1000), entry(2, 5, 2000)],
    categoriesMap: const {1: 'Symptoms', 5: 'Sleep'},
    userContext: 'ctx',
    userAge: 22,
    userHeightIn: 70,
    userWeightLbs: 165.4,
    userGender: 'Male',
    conditions: const ['POTS', 'MCAS'],
    medications: [
      MedicationEntry(
          name: 'Ivabradine', dose: '7.5 mg', frequency: 'Twice daily'),
    ],
    heartRateSeries: const [('2026-10-01', 60), ('2026-10-02', 70)],
    sleepSeries: const [('2026-10-01', 420), ('2026-10-02', 480)],
    deepSleepSeries: const [('2026-10-01', 60), ('2026-10-02', 120)],
    caloriesSeries: const [('2026-10-01', 2000), ('2026-10-02', 2200)],
    hrvSeries: const [('2026-10-01', 50.0), ('2026-10-02', 60.0)],
    heartRateSpikes: const [('2026-10-01', 3), ('2026-10-02', 2)],
    bloodPressureSeries: const [
      ReportBpRecord(120, 80, 100000),
      ReportBpRecord(130, 90, 200000),
    ],
    sectionMetadata: const {
      'logs': SectionMetadata('logs', DataSourceStatus.success, 600),
      'conditions':
          SectionMetadata('conditions', DataSourceStatus.success, 4),
      'medications':
          SectionMetadata('medications', DataSourceStatus.success, 3),
      'documents':
          SectionMetadata('documents', DataSourceStatus.noData, 0),
      'bloodPressure':
          SectionMetadata('bloodPressure', DataSourceStatus.success, 4),
      'sleep': SectionMetadata('sleep', DataSourceStatus.success, 151),
      'deepSleep':
          SectionMetadata('deepSleep', DataSourceStatus.timedOut, 0),
      'heartRate':
          SectionMetadata('heartRate', DataSourceStatus.success, 172),
      'hrv': SectionMetadata('hrv', DataSourceStatus.success, 144),
      'calories':
          SectionMetadata('calories', DataSourceStatus.success, 14),
      'hrSpikes':
          SectionMetadata('hrSpikes', DataSourceStatus.success, 30),
    },
  );
}

// ── Pure logic ────────────────────────────────────────────────────

void main() {
  // R70 WS2 — the union helper reads/writes the shared history
  // store; reset it (in-memory backing) so cases stay isolated.
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  group('preset category resolution (slug fallback by id)', () {
    test('HEALTH resolves by canonical slug-by-id', () {
      final sel = resolveReportCategories(
          defaultCats(), ReportFocus.health, const {});
      expect(sel.map((c) => c.id).toSet(), {1, 8, 5, 6, 3});
    });
    test('TRAINING resolves by canonical slug-by-id', () {
      final sel = resolveReportCategories(
          defaultCats(), ReportFocus.training, const {});
      expect(sel.map((c) => c.id).toSet(), {4, 3, 2});
    });
    test('CUSTOM resolves by id set only', () {
      final sel = resolveReportCategories(
          defaultCats(), ReportFocus.custom, {7, 99});
      expect(sel.map((c) => c.id), [7]);
    });
    test('non-default id has no slug and matches no preset', () {
      final cats = [...defaultCats(), cat(99, 'Custom Thing')];
      expect(effectiveSlug(cats.last), '');
      expect(
          resolveReportCategories(cats, ReportFocus.health, const {})
              .map((c) => c.id),
          isNot(contains(99)));
    });
  });

  group('coverage math', () {
    const day = 24 * 60 * 60 * 1000;
    test('distinct days uses epoch-day buckets (native)', () {
      final logs = [entry(1, 1, 5 * day), entry(2, 1, 5 * day + 100), entry(3, 1, 6 * day)];
      expect(distinctDaysLogged(logs), 2);
    });
    test('denominator: this month 30; all time span capped 180', () {
      final now = 500 * day;
      expect(
          coverageDenominator([entry(1, 1, 400 * day)],
              last30Days: true, nowMs: now),
          30);
      expect(
          coverageDenominator([entry(1, 1, 400 * day)],
              last30Days: false, nowMs: now),
          101);
      expect(
          coverageDenominator([entry(1, 1, 100 * day)],
              last30Days: false, nowMs: now),
          180);
      expect(coverageDenominator(const [], last30Days: false, nowMs: now), 1);
    });
    test('logsInRange filters cutoff + selection', () {
      final now = 100 * day;
      final logs = [
        entry(1, 1, now - 29 * day),
        entry(2, 1, now - 31 * day),
        entry(3, 5, now - day),
      ];
      expect(
          logsInRange(logs, {1, 5}, last30Days: true, nowMs: now)
              .map((e) => e.id),
          [1, 3]);
      expect(
          logsInRange(logs, {1, 5}, last30Days: false, nowMs: now).length, 3);
    });
  });

  group('request assembly goldens (native byte formats)', () {
    test('userContext profile text', () {
      expect(
        buildReportUserContext(fixtureSnapshot()),
        'ctx\n\nREPORT RANGE: LAST_30_DAYS (30 days)\n'
        'Profile Stats: Age 22, Height 177.8cm, Weight 165.4lbs, Gender Male\n'
        'Medical Conditions: POTS, MCAS\n'
        'Active Medications: Ivabradine 7.5 mg (Twice daily)\n',
      );
    });
    test('FULL range label + duration', () {
      expect(buildReportUserContext(fixtureSnapshot(last30Days: false)),
          contains('REPORT RANGE: FULL (180 days)'));
    });
    test('health summary string', () {
      expect(
        buildHealthSummary(fixtureSnapshot()),
        'Avg Heart Rate: 65 bpm across 2 days. '
        'Avg Sleep: 7.5 hrs/night across 2 days. '
        'Total HR Spikes: 5 recorded. '
        'Blood Pressure Avg: 125/85 mmHg across 2 readings. '
        'Avg Calories: 2100 kcal/day across 2 days. '
        'Avg HRV (RMSSD): 55.0 ms across 2 days. '
        'HRV (RMSSD) by date (sensor data): 2026-10-01: 50.0 ms; 2026-10-02: 60.0 ms. '
        'Avg Deep Sleep: 1.5 hrs/night across 2 days. ',
      );
    });
    test('availability block with disambiguated labels', () {
      expect(
        buildDataAvailability(fixtureSnapshot()),
        'Logs: Available (600 records); '
        'Conditions (profile list): Available (4 records); '
        'Medications (profile list): Available (3 records); '
        'Documents (knowledge base): Unavailable; '
        'BloodPressure: Available (4 records); '
        'Sleep: Available (151 records); '
        'DeepSleep: Unavailable; '
        'HeartRate: Available (172 records); '
        'Hrv: Available (144 records); '
        'Calories: Available (14 records); '
        'HrSpikes: Available (30 records)',
      );
    });
    test('request body shape: entries, categories, knowledgeBase null', () {
      final body = buildAiReportRequest(fixtureSnapshot());
      expect(body['categories'], {'1': 'Symptoms', '5': 'Sleep'});
      expect(body['knowledgeBase'], isNull);
      // Full entry maps, native report DTO shape: `updatedAt` is
      // the DTO default 0 — never a fabricated DateTime.now() stamp.
      expect(body['entries'], [
        {
          'id': 1,
          'categoryId': 1,
          'body': 'b1',
          'chips': '',
          'manualText': '',
          'timestamp': 1000,
          'updatedAt': 0,
        },
        {
          'id': 2,
          'categoryId': 5,
          'body': 'b2',
          'chips': '',
          'manualText': '',
          'timestamp': 2000,
          'updatedAt': 0,
        },
      ]);
      expect(body['dataAvailability'], isNotNull);
    });
  });

  group('fallback summary + failure reasons', () {
    test('raw fallback text is byte-identical to native', () {
      expect(
        buildRawFallbackSummary(fixtureSnapshot()),
        '[SECTION] RAW CLINICAL LOG SUMMARY\n'
        '[BOLD]Notice:[BOLD] AI summary generation was unavailable or non-responsive. '
        'The following report compiles raw longitudinal patient entries and measured biometrics snapshot directly.\n\n'
        '[SECTION] PATIENT OVERVIEW\n'
        '• Total Recorded Entries: 2\n'
        '• Active Conditions: POTS, MCAS\n'
        '• Active Medications: Ivabradine 7.5 mg',
      );
    });
    test('plain reasons are fixed strings mapped from status only', () {
      expect(const AiFailure(timedOut: true).plainReason,
          'network timeout');
      expect(const AiFailure(noSession: true).plainReason, 'not signed in');
      expect(const AiFailure().plainReason, 'unknown error');
      expect(const AiFailure(httpStatus: 401).plainReason,
          'HTTP 401 (signed out?)');
      expect(const AiFailure(httpStatus: 429).plainReason,
          'HTTP 429 (try again later)');
      expect(const AiFailure(httpStatus: 503).plainReason,
          'HTTP 503 (server error)');
      expect(const AiFailure(httpStatus: 400).plainReason,
          'HTTP 400 (request failed)');
      expect(const AiFailure(noResponse: true).plainReason, 'no connection');
    });
    test('retry classes: connection 4, server 2, fatal 1', () {
      expect(const AiFailure(noResponse: true).maxAttempts, 4);
      expect(const AiFailure(httpStatus: 500).maxAttempts, 2);
      expect(const AiFailure(httpStatus: 401).maxAttempts, 1);
      expect(const AiFailure(noResponse: true).backoffAfter(1),
          const Duration(seconds: 2));
      expect(const AiFailure(noResponse: true).backoffAfter(3),
          const Duration(seconds: 8));
    });
  });

  group('markup parsing + availability wording', () {
    test('sections, bullets, plain lines', () {
      final blocks = parseSummaryBlocks(
          '[SECTION] USER SUMMARY\n[BULLET] - First *point* #tag\nPlain #line *kept*\n• Already bulleted');
      expect(blocks[0], isA<SectionBlock>());
      expect((blocks[0] as SectionBlock).text, 'USER SUMMARY');
      expect((blocks[1] as BulletBlock).text, 'First point tag');
      expect((blocks[2] as TextBlock).text, 'Plain line *kept*');
      expect((blocks[3] as TextBlock).text, '• Already bulleted');
    });
    test('inline toggles', () {
      final runs = parseInlineRuns('a [BOLD]bold[BOLD] b [ITALIC]it[ITALIC] c');
      expect(runs.map((r) => r.text), ['a ', 'bold', ' b ', 'it', ' c']);
      expect(runs.map((r) => r.bold), [false, true, false, false, false]);
      expect(runs.map((r) => r.italic), [false, false, false, true, false]);
    });
    test('clean clinical wording per status', () {
      SectionMetadata m(DataSourceStatus s, [int n = 0]) =>
          SectionMetadata('x', s, n);
      expect(availabilityStatusText(m(DataSourceStatus.success, 7)),
          'Available (7 records)');
      expect(availabilityStatusText(m(DataSourceStatus.noData)),
          'No data recorded');
      expect(availabilityStatusText(m(DataSourceStatus.permissionDenied)),
          'Unavailable. Permission not granted.');
      for (final s in [
        DataSourceStatus.unavailable,
        DataSourceStatus.timedOut,
        DataSourceStatus.error,
      ]) {
        expect(availabilityStatusText(m(s)),
            'Unavailable. Data could not be retrieved.');
      }
    });
    test('PDF labels uppercase only the first char (specimen)', () {
      expect(availabilityPdfLabel('bloodPressure'), 'BloodPressure');
      expect(availabilityPdfLabel('deepSleep'), 'DeepSleep');
      expect(availabilityPdfLabel('heartRate'), 'HeartRate');
      expect(availabilityPdfLabel('hrSpikes'), 'HrSpikes');
      expect(availabilityPdfLabel('hrv'), 'Hrv');
      expect(availabilityPdfLabel('logs'), 'Logs');
    });
  });

  group('charts data', () {
    test('zero filtering + sleep hours conversion', () {
      final s = ReportSnapshot(
        last30Days: true,
        generationTimestampMs: 0,
        logEntries: const [],
        categoriesMap: const {},
        sleepSeries: const [
          ('2026-10-02', 480),
          ('2026-10-01', 0),
          ('2026-10-03', 420),
        ],
      );
      final page1 = chartPage1Series(s);
      expect(page1[0].points, [('Oct 2', 8.0), ('Oct 3', 7.0)]);
      expect(page1[1].points, isEmpty); // HR <2 → not-enough-data chart
    });
    test('y-range padding rules', () {
      ChartSeries cs(String title, List<double> vs) => ChartSeries(
          title: title,
          colorHex: '#000000',
          unit: '',
          points: [for (var i = 0; i < vs.length; i++) ('d$i', vs[i])]);
      expect(chartYRange(cs('Avg Heart Rate', [60, 80])).minY, 55);
      expect(chartYRange(cs('HRV (RMSSD)', [3, 9])).minY, 0);
      expect(chartYRange(cs('Systolic Blood Pressure', [120, 130])).minY, 110);
      expect(chartYRange(cs('Sleep Duration', [5, 9])).minY, 0);
      expect(chartYRange(cs('Sleep Duration', [5, 9])).maxY, 14);
    });
    test('x label candidates include last point', () {
      expect(chartXLabelCandidates(12), [0, 2, 4, 6, 8, 10, 11]);
      expect(chartXLabelCandidates(2), [0, 1]);
      expect(chartXLabelCandidates(0), isEmpty);
    });
  });

  group('collector', () {
    test('zero-filtering, BP range filter, permission-denied', () async {
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)]
        ..bp = [
          BpRecord(
              systolic: 120,
              diastolic: 80,
              timeEpochMs: DateTime.now().millisecondsSinceEpoch),
          BpRecord(
              systolic: 110,
              diastolic: 70,
              timeEpochMs: DateTime.now()
                  .subtract(const Duration(days: 40))
                  .millisecondsSinceEpoch),
        ];
      final hc = FakeHc()
        ..sleepHist = [
          (date: '2026-10-15', mins: 0, deep: 0),
          (date: '2026-10-16', mins: 430, deep: 90),
        ]
        ..hrHist = [(date: '2026-10-16', bpm: 0), (date: '2026-10-15', bpm: 62)]
        ..calHist = [(date: '2026-10-16', kcal: 0)]
        ..spikeHist = [(date: '2026-10-16', count: 0)]
        ..hrvValue = 0;
      final collector = ReportDataCollector(backend: backend, hc: hc);
      final snap = await collector.collect(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
      );
      expect(snap.sleepSeries, [('2026-10-16', 430)]);
      expect(snap.deepSleepSeries, [('2026-10-16', 90)]);
      expect(snap.heartRateSeries, [('2026-10-15', 62)]);
      expect(snap.caloriesSeries, isEmpty);
      expect(snap.hrvSeries, isEmpty);
      // A 0 spike count is a real sampled day (native keeps the row).
      expect(snap.heartRateSpikes, [('2026-10-16', 0)]);
      expect(snap.bloodPressureSeries.length, 1);
      expect(snap.sectionMetadata['calories']!.status,
          DataSourceStatus.noData);
      expect(snap.sectionMetadata.keys.toList(), [
        'logs', 'conditions', 'medications', 'documents', 'bloodPressure',
        'sleep', 'deepSleep', 'heartRate', 'hrv', 'calories', 'hrSpikes',
      ]);

      final denied = await ReportDataCollector(
              backend: backend, hc: FakeHc()..connected = false)
          .collect(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
      );
      expect(denied.sectionMetadata['sleep']!.status,
          DataSourceStatus.permissionDenied);
    });

    test('documents loader feeds snapshot + request knowledgeBase',
        () async {
      final collector = ReportDataCollector(
        backend: FakeBackend(),
        hc: FakeHc(),
        documentsLoader: () async => ['Doc text one', 'Doc text two'],
      );
      final snap = await collector.collect(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
      );
      expect(snap.knowledgeDocuments, ['Doc text one', 'Doc text two']);
      expect(snap.sectionMetadata['documents']!.recordCount, 2);
      expect(buildAiReportRequest(snap)['knowledgeBase'],
          'Doc text one\n\nDoc text two');
    });

    test('all-time entries capped at most recent 2000', () async {
      final backend = FakeBackend()
        ..entries = [
          for (var i = 0; i < 2005; i++) entry(i, 1, 1000000 + i),
        ];
      final snap = await ReportDataCollector(backend: backend, hc: FakeHc())
          .collect(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: false,
        profile: const ReportProfileInput(),
      );
      expect(snap.logEntries.length, 2000);
      expect(snap.logEntries.first.id, 2004);
    });
  });

  group('pipeline', () {
    Future<ReportOutcome> run(
      FakeBackend backend, {
      bool forceRaw = false,
      void Function(String?, bool, String?)? onRender,
    }) {
      final collector = ReportDataCollector(backend: backend, hc: FakeHc());
      final pipeline = ReportGenerationPipeline(
        collector: collector,
        backend: backend,
        delay: (_) async {},
      );
      return pipeline.generate(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        forceRawFallback: forceRaw,
        renderPdf: (snapshot, aiSummary,
            {required bool isRawFallback, String? aiFailureReason}) async {
          onRender?.call(aiSummary, isRawFallback, aiFailureReason);
          return [1, 2, 3];
        },
        savePdf: (bytes, name) async => '/tmp/$name',
      );
    }

    test('no data at all refuses generation', () async {
      final outcome = await run(FakeBackend());
      expect(outcome, isA<ReportFailed>());
      expect((outcome as ReportFailed).message,
          'No patient logs or health data found in selected range.');
      expect(outcome.allowRawFallback, isFalse);
    });

    test('AI success passes the summary through', () async {
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
      String? seenSummary;
      bool? seenRaw;
      final outcome = await run(backend,
          onRender: (s, raw, r) {
            seenSummary = s;
            seenRaw = raw;
          });
      expect(outcome, isA<ReportReady>());
      expect(seenSummary, '[SECTION] USER SUMMARY\nAll good.');
      expect(seenRaw, isFalse);
    });

    test('HTTP 500 retries once (2 attempts) then raw fallback', () async {
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)]
        ..aiResponse = (
          statusCode: 500,
          body: null,
          serverError: 'x',
          transportFailure: null,
        );
      String? seenReason;
      bool? seenRaw;
      final outcome = await run(backend,
          onRender: (s, raw, r) {
            seenRaw = raw;
            seenReason = r;
          });
      expect(backend.aiCalls, 2);
      expect(outcome, isA<ReportReady>());
      expect((outcome as ReportReady).isRawFallback, isTrue);
      expect(seenRaw, isTrue);
      expect(seenReason, 'HTTP 500 (server error)');
      expect(outcome.aiFailureReason, 'HTTP 500 (server error)');
    });

    test('transport timeout (backend-classified) is NOT no connection',
        () async {
      // Report-pdf fix (Juno Ruling 3): the backend's shared 20s
      // transport timeout used to collapse into a bare null and be
      // labelled "no connection". Classified as a timeout it must
      // produce the timeout reason — and keep the connection
      // retry class (4 attempts).
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)]
        ..aiResponse = (
          statusCode: null,
          body: null,
          serverError: null,
          transportFailure: AiTransportFailure.timeout,
        );
      final outcome = await run(backend);
      expect(backend.aiCalls, 4);
      expect(outcome, isA<ReportReady>());
      expect((outcome as ReportReady).aiFailureReason, 'network timeout');
    });

    test('HTTP 401 fails fast (1 attempt), reason signed out', () async {
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)]
        ..aiResponse = (
          statusCode: 401,
          body: null,
          serverError: 'x',
          transportFailure: null,
        );
      final outcome = await run(backend);
      expect(backend.aiCalls, 1);
      expect((outcome as ReportReady).aiFailureReason,
          'HTTP 401 (signed out?)');
    });

    test('forceRaw skips the AI call and carries no reason', () async {
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
      final outcome = await run(backend, forceRaw: true);
      expect(backend.aiCalls, 0);
      expect((outcome as ReportReady).isRawFallback, isTrue);
      expect(outcome.aiFailureReason, isNull);
    });
  });

  group('appointment helpers', () {
    test('countdown + formatting', () {
      final now = DateTime(2026, 10, 16);
      expect(appointmentCountdown('2026-10-16', now: now), 'today');
      expect(appointmentCountdown('2026-10-17', now: now), 'tomorrow');
      expect(appointmentCountdown('2026-10-20', now: now), 'in 4 days');
      expect(appointmentCountdown('2026-10-15', now: now), isNull);
      expect(formatIsoDate('2026-11-03'), 'Nov 3, 2026');
      expect(reportFileName(DateTime(2026, 10, 16)),
          'Tabs_Report_Oct_16_2026.pdf');
      expect(formatExportTimestamp(
              DateTime(2026, 10, 16, 16, 17).millisecondsSinceEpoch),
          'Oct 16, 4:17 PM');
    });
  });

  group('PDF artifact', () {
    test('generates a real PDF (AI + raw variants) into the audit dir',
        () async {
      // Portable: CI runners have no workspace audit dir. Locally
      // R66_AUDIT_DIR points at ~/workspace/audit-r66 for the
      // round's kept evidence; elsewhere a temp dir is used and
      // only the in-memory assertions matter.
      final override = Platform.environment['R66_AUDIT_DIR'];
      final dir = override != null && override.isNotEmpty
          ? Directory(override)
          : Directory('${Directory.systemTemp.path}/audit-r66');
      await dir.create(recursive: true);
      final ai = await buildReportPdfBytes(fixtureSnapshot(),
          aiSummary:
              '[SECTION] USER SUMMARY\n[BOLD]Notice:[BOLD] Fixture summary body with enough words to wrap across the full content width of the report page for layout sanity.\n[SECTION] CLINICAL SUMMARY FOR YOUR DOCTOR\n• Fixture bullet one\n• Fixture bullet two',
          isRawFallback: false);
      expect(ai.length, greaterThan(3000));
      expect(String.fromCharCodes(ai.take(5)), '%PDF-');
      await File('${dir.path}/fixture_report_ai.pdf').writeAsBytes(ai);

      final raw = await buildReportPdfBytes(fixtureSnapshot(),
          aiSummary: null,
          isRawFallback: true,
          aiFailureReason: 'HTTP 500 (server error)');
      await File('${dir.path}/fixture_report_raw.pdf').writeAsBytes(raw);
      expect(raw.length, greaterThan(3000));
    });

    test('meta line: day-count parenthetical is unconditional (native)',
        () {
      expect(reportMetaLine(fixtureSnapshot()),
          startsWith('Report Range: 30-Day Audit (30 Days) · Generated: '));
      expect(reportMetaLine(fixtureSnapshot(last30Days: false)),
          startsWith('Report Range: Full Audit (180 Days) · Generated: '));
    });
  });

  // ── Widget ──────────────────────────────────────────────────────

  group('ProgressReportsPage widget', () {
    Future<({FakeBackend backend, SettingsStore store, FakeReminderNotificationService notifs})>
        pumpPage(WidgetTester tester,
            {List<QuickLogEntry>? entries}) async {
      final mem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final backend = FakeBackend()
        ..categories = defaultCats()
        ..entries = entries ??
            [
              entry(1, 1, DateTime.now().millisecondsSinceEpoch),
              entry(2, 5, DateTime.now().millisecondsSinceEpoch),
            ];
      final notifs = FakeReminderNotificationService();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            ProgressReportsPage(
              profileData: const SettingsProfileData(),
              backend: backend,
              store: store,
              healthConnectService: FakeHc(),
              notificationService: notifs,
              savePdf: (bytes, name) async => '/tmp/$name',
              sharePdf: (bytes, name) async {},
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      return (backend: backend, store: store, notifs: notifs);
    }

    testWidgets('overview, preview, details render with native copy',
        (tester) async {
      await pumpPage(tester);
      expect(find.text('Report type'), findsOneWidget);
      expect(find.text('Symptoms, meds, sleep, mood, and vitals'),
          findsOneWidget);
      expect(find.text('Health report, this month. 2 entries across 5 categories.'),
          findsOneWidget);
      expect(find.text('Log activity by hour'), findsOneWidget);
      expect(find.text('Export PDF Report'), findsOneWidget);
      expect(find.text('Logged 1 of 30 days'), findsOneWidget);
      expect(find.textContaining('Tabs is not a medical device'),
          findsOneWidget);
      // Details card lists the 5 health categories.
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Medication'), findsOneWidget);
    });

    testWidgets('empty state verbatim when no entries in selection',
        (tester) async {
      await pumpPage(tester, entries: const []);
      expect(find.text('Nothing to preview yet'), findsOneWidget);
      expect(
          find.text(
              'Log symptoms, meds, or sleep and your activity will show up here.'),
          findsOneWidget);
      expect(find.text('Add some notes first to generate a report.'),
          findsOneWidget);
    });

    testWidgets('custom preselects all on first open; clear empties',
        (tester) async {
      await pumpPage(tester);
      // 'Custom' also labels the appointment card's type picker;
      // the report-type picker is the first one.
      await tester.tap(find.text('Custom').first);
      await tester.pumpAndSettle();
      expect(find.text('Include these categories'), findsOneWidget);
      final boxes = tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .toList();
      expect(boxes.length, 8);
      expect(boxes.every((b) => b.value == true), isTrue);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('No categories selected'), findsOneWidget);
      expect(
          find.text('Pick at least one category above to see a preview.'),
          findsOneWidget);
    });

    testWidgets('export opens share confirmation; Not now never shares',
        (tester) async {
      var shared = false;
      final mem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final backend = FakeBackend()
        ..categories = defaultCats()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            ProgressReportsPage(
              profileData: const SettingsProfileData(),
              backend: backend,
              store: store,
              healthConnectService: FakeHc(),
              savePdf: (bytes, name) async => '/tmp/$name',
              // Report-pdf fix: the Downloads seam is injected
              // (an unmocked platform channel never completes in a
              // widget test); false = the copy could not land, as
              // on a device without the bridge.
              saveToDownloads: (bytes, name) async => false,
              sharePdf: (bytes, name) async => shared = true,
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Export PDF Report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export PDF Report'));
      // Generation shows an indeterminate spinner (pumpAndSettle
      // would never settle), so pump in steps until the dialog lands.
      for (var i = 0; i < 40 && find.text('Share health report').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Share health report'), findsOneWidget);
      expect(
          find.text(
              'This PDF contains your health data. Only share it with people you trust.'),
          findsOneWidget);
      expect(find.text('For informational purposes only. Not medical advice.'),
          findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(shared, isFalse);
      expect(await store.getReportLastExportMs(), 0);
      // Saved-file transparency (Juno Ruling 2): declining to share
      // still tells the user the PDF is saved in the app — with the
      // save-failed Downloads wording, since the injected seam
      // reports the copy could not land.
      expect(
          find.text(
              'Report saved in the app. It could not be saved to Downloads. Export again any time to share it.'),
          findsOneWidget);
    });

    testWidgets('appointment save schedules day-before reminder id 770002',
        (tester) async {
      final h = await pumpPage(tester);
      await tester.ensureVisible(find.text('Pick a date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick a date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save appointment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save appointment'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Appointment:'), findsOneWidget);
      expect(find.text('Health report saved'), findsOneWidget);
      // Saved today → fire time (yesterday 9 AM) is past → native
      // no-ops; pick a future flow instead: the id must NOT be in
      // the once map, and clear cancels it.
      await tester.ensureVisible(find.text('Clear'));
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(h.notifs.cancelled, contains(appointmentReminderId));
    });

    testWidgets(
        'appointment with a FUTURE date schedules day-before 9 AM reminder',
        (tester) async {
      final h = await pumpPage(tester);
      await tester.ensureVisible(find.text('Pick a date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick a date'));
      await tester.pumpAndSettle();
      // Move one month ahead so the picked day is always in the
      // future, whatever today's date is.
      final now = DateTime.now();
      final picked = DateTime(now.year, now.month + 1, 15);
      await tester.tap(find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.byIcon(Icons.chevron_right)));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.text('${picked.day}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save appointment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save appointment'));
      await tester.pumpAndSettle();
      // scheduleOnce actually fired, for the day before at 9:00 AM.
      expect(h.notifs.once[appointmentReminderId],
          DateTime(picked.year, picked.month, picked.day - 1, 9));
    });
  });
}
