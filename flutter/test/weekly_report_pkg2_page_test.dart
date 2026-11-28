import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/report_ready_notification.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_notification.dart';
import 'package:tabs_lab/src/data/weekly_report.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Weekly Report Package 2 — the Progress Reports surface
// wiring for the first-open automation: with the page clock at
// Sunday 21:30 and Premium entitlement, opening the page
// generates the due week WITHOUT a tap, archives it, and posts
// exactly one weekly notification through the injected weekly
// notifier — while the weekly service's silent notifier and
// PR #55's report-ready notifier both stay at zero (the weekly
// send never rides their channels). A free user triggers
// nothing; an already-generated week triggers nothing.
//
// Fixture week: Mon Nov 9 – Sun Nov 15, 2026 (the due week at
// Sunday Nov 15, 2026, 21:30).

final _week = WeeklyWeekWindow(DateTime(2026, 11, 9), DateTime(2026, 11, 15));
final _sundayNight = DateTime(2026, 11, 15, 21, 30);

QuickLogCategory _cat(String id, String name) => QuickLogCategory(
    id: id,
    name: name,
    icon: 'x',
    colorHex: '#FF0000',
    isDefault: true,
    sortOrder: int.tryParse(id) ?? 0);

QuickLogEntry _entry(String id, DateTime day) => QuickLogEntry(
      id: id,
      categoryId: '1',
      body: 'entry $id',
      chips: '',
      manualText: '',
      timestamp:
          DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch,
    );

ReportSnapshot _goodSnap() {
  final days = _week.days;
  return ReportSnapshot(
    last30Days: false,
    weekStart: _week.start,
    weekEnd: _week.end,
    generationTimestampMs: _sundayNight.millisecondsSinceEpoch,
    logEntries: [for (var i = 0; i < 5; i++) _entry('${i + 1}', days[i])],
    categoriesMap: const {'1': 'Symptoms'},
    dailyScoreSeries: [for (final d in days) (dateStrOf(d), 60)],
    sleepSeries: [for (final d in days) (dateStrOf(d), 420)],
  );
}

class _Backend extends TabsBackend {
  _Backend() : super(sessionStore: FakeSessionStore());

  @override
  Future<({bool isUnlimited, bool isAdmin})> fetchMembership() async =>
      (isUnlimited: true, isAdmin: false);

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async =>
      [_cat('1', 'Symptoms')];

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => const [];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];
}

class _FakePipeline extends ReportGenerationPipeline {
  _FakePipeline({
    required super.collector,
    required super.backend,
    required this.snapshot,
  });

  final ReportSnapshot snapshot;
  int generateCalls = 0;

  @override
  Future<ReportOutcome> generate({
    required List<QuickLogCategory> selectedCategories,
    required bool last30Days,
    required ReportProfileInput profile,
    bool forceRawFallback = false,
    RawReportBanner forceRawBanner = RawReportBanner.explicitChoice,
    required ReportRenderPdf renderPdf,
    required Future<String> Function(List<int> bytes, String fileName)
        savePdf,
    Future<bool> Function(List<int> bytes, String fileName)? saveToDownloads,
    void Function(ReportStage stage)? onStage,
    bool Function()? isCancelled,
    DateTime? now,
    String? reportGenerationId,
    bool? checkPickupFirst,
    String? pickupCheckGenerationId,
    DateTime? weekStart,
    DateTime? weekEnd,
  }) async {
    generateCalls++;
    onStage?.call(ReportStage.collecting);
    final bytes = await renderPdf(snapshot, null,
        isRawFallback: true, rawBanner: RawReportBanner.explicitChoice);
    final fileName = reportFileName(
        DateTime.fromMillisecondsSinceEpoch(snapshot.generationTimestampMs));
    final savedPath = await savePdf(bytes, fileName);
    return ReportReady(
      snapshot: snapshot,
      pdfBytes: bytes,
      fileName: fileName,
      savedPath: savedPath,
      isRawFallback: true,
      rawBanner: RawReportBanner.explicitChoice,
    );
  }
}

class _RecordingWeeklyNotifier implements WeeklyNotifier {
  int sends = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> showWeeklyReady() async {
    sends++;
    return true;
  }
}

class _RecordingNotifier implements ReportReadyNotifier {
  int shows = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> showReportReady() async {
    shows++;
    return true;
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 200,
}) async {
  for (var i = 0; i < maxPumps && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  late Map<String, String> weeklyMem;
  late WeeklyReportStore weeklyStore;
  late WeeklySilentNotifier silentSink;
  late _RecordingWeeklyNotifier autoNotifier;
  late _RecordingNotifier standardNotifier;
  late _Backend backend;

  setUp(() {
    weeklyMem = <String, String>{};
    weeklyStore = WeeklyReportStore.inMemory(weeklyMem);
    silentSink = WeeklySilentNotifier();
    autoNotifier = _RecordingWeeklyNotifier();
    standardNotifier = _RecordingNotifier();
    backend = _Backend();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required Future<WeeklyEntitlement> Function() entitlement,
    ReportGenerationPipeline? pipeline,
    DateTime Function()? clock,
  }) async {
    final mem = <String, String>{};
    final store = SettingsStore.withStorage(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProgressReportsPage(
          profileData: const SettingsProfileData(),
          backend: backend,
          store: store,
          pipeline: pipeline,
          clinicianPremiumCheck: () async => true,
          reportReadyNotifier: standardNotifier,
          healthConnectService: HealthConnectService(),
          savePdf: (bytes, name) async => '/tmp/$name',
          saveToDownloads: (bytes, name) async => true,
          sharePdf: (bytes, name) async {},
          weeklyEntitlementCheck: entitlement,
          weeklyStore: weeklyStore,
          weeklyNotifier: silentSink,
          weeklyAutoNotifier: autoNotifier,
          weeklyClock: clock ?? () => _sundayNight,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  _FakePipeline fakePipeline() => _FakePipeline(
        collector: ReportDataCollector(
          backend: backend,
          hc: HealthConnectService(),
          insightsLoader: () async => const [],
        ),
        backend: backend,
        snapshot: _goodSnap(),
      );

  testWidgets(
      'Sunday 21:30 first open: the due week auto-generates with '
      'no tap, archives Complete, and sends exactly one weekly '
      'notification — the silent sink and the report-ready '
      'notifier are never the send path', (tester) async {
    final pipeline = fakePipeline();
    await pumpPage(tester,
        entitlement: () async => WeeklyEntitlement.premium,
        pipeline: pipeline);
    await _pumpUntil(tester, () => autoNotifier.sends > 0);
    await tester.pumpAndSettle();

    expect(pipeline.generateCalls, 1,
        reason: 'exactly one automatic generation, no tap needed');
    final records = await weeklyStore.readAll();
    expect(records.length, 1);
    expect(records.single.weekStartKey, '2026-11-09');
    expect(records.single.label, WeeklyCompleteness.complete);
    expect(autoNotifier.sends, 1);
    expect(standardNotifier.shows, 0,
        reason: 'the weekly send never rides the report-ready path');
    expect(find.text('Nov 9 – Nov 15, 2026'), findsOneWidget);
    expect(find.text('Complete'), findsOneWidget);
  });

  testWidgets('free user at the trigger: nothing generates, '
      'nothing sends, only the locked row shows', (tester) async {
    final pipeline = fakePipeline();
    await pumpPage(tester,
        entitlement: () async => WeeklyEntitlement.free,
        pipeline: pipeline);
    await tester.pumpAndSettle();
    expect(pipeline.generateCalls, 0);
    expect(autoNotifier.sends, 0);
    expect(await weeklyStore.readAll(), isEmpty);
    expect(find.text('Weekly report'), findsOneWidget);
    expect(
        find.text(
            'Available with Premium. A weekly summary of your logs and Daily Score.'),
        findsOneWidget);
  });

  testWidgets('the due week already in the archive: opening the '
      'page generates nothing and sends nothing', (tester) async {
    await weeklyStore.upsert(WeeklyArchiveRecord(
      weekStartKey: _week.startKey,
      weekEndKey: _week.endKey,
      generatedAtMs: _sundayNight.millisecondsSinceEpoch,
      fileName: 'weekly.pdf',
      savedPath: '/tmp/weekly.pdf',
      label: WeeklyCompleteness.complete,
      blockedSections: const [],
      dailyScoreDays: 7,
      sleepNights: 7,
      loggedDays: 5,
      completeDays: 6,
      avgScoreCompleteDays: 60.0,
    ));
    final pipeline = fakePipeline();
    await pumpPage(tester,
        entitlement: () async => WeeklyEntitlement.premium,
        pipeline: pipeline);
    await tester.pumpAndSettle();
    expect(pipeline.generateCalls, 0);
    expect(autoNotifier.sends, 0);
    expect((await weeklyStore.readAll()).length, 1);
  });
}
