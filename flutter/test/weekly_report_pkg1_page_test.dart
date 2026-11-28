import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/report_ready_notification.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_report.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Weekly Report Package 1 — the Progress Reports surface:
// entitlement surfaces (free / lapsed / premium), fail-closed
// PRE-GENERATION gating, manual generation into the archive,
// the permission-needed state, and the zero-notification sink
// proof on an away completion.
//
// Fixture week: Mon Nov 9 – Sun Nov 15, 2026; the page clock
// is pinned to Wed Nov 18, 2026, so the most recent closed
// week is Nov 9–15.

final _week = WeeklyWeekWindow(DateTime(2026, 11, 9), DateTime(2026, 11, 15));
final _pageNow = DateTime(2026, 11, 18, 12);

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
    id: id,
    name: name,
    icon: 'x',
    colorHex: '#FF0000',
    isDefault: true,
    sortOrder: int.tryParse(id) ?? 0);

QuickLogEntry _entry(int id, DateTime day) => QuickLogEntry(
      id: id,
      categoryId: '1',
      body: 'entry $id',
      chips: '',
      manualText: '',
      timestamp:
          DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch,
    );

ReportSnapshot _snap({
  Map<String, SectionMetadata> meta = const {},
  bool goodWeek = true,
}) {
  final days = _week.days;
  return ReportSnapshot(
    last30Days: false,
    weekStart: _week.start,
    weekEnd: _week.end,
    generationTimestampMs: _pageNow.millisecondsSinceEpoch,
    logEntries: [for (var i = 0; i < 5; i++) _entry(i + 1, days[i])],
    categoriesMap: const {1: 'Symptoms'},
    dailyScoreSeries:
        goodWeek ? [for (final d in days) (dateStrOf(d), 60)] : const [],
    sleepSeries:
        goodWeek ? [for (final d in days) (dateStrOf(d), 420)] : const [],
    sectionMetadata: meta,
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
      [_cat(1, 'Symptoms')];

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => const [];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];
}

class _FakeHc extends HealthConnectService {
  int settingsOpens = 0;

  @override
  Future<void> openHealthConnectSettings() async {
    settingsOpens++;
  }
}

/// A pipeline that skips collection entirely and ships a canned
/// snapshot through the page's own render/save seams — the page,
/// the service, the evaluator, and the PDF line all run for
/// real; only the (separately tested) collector is stubbed.
class _FakePipeline extends ReportGenerationPipeline {
  _FakePipeline({
    required super.collector,
    required super.backend,
    required this.snapshot,
    this.gate,
  });

  final ReportSnapshot snapshot;
  final Completer<void>? gate;
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
    if (gate != null) await gate!.future;
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

/// A collector that returns a canned snapshot — used with the
/// REAL pipeline to prove a fully blocked/empty weekly week
/// still ships (the pipeline's no-data failure is standard-only).
class _CannedCollector extends ReportDataCollector {
  _CannedCollector({required this.snapshot});

  final ReportSnapshot snapshot;

  @override
  Future<ReportSnapshot> collect({
    required List<QuickLogCategory> selectedCategories,
    required bool last30Days,
    required ReportProfileInput profile,
    void Function(String stage)? onStage,
    bool Function()? isCancelled,
    DateTime? now,
    DateTime? weekStart,
    DateTime? weekEnd,
  }) async =>
      snapshot;
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
  late WeeklySilentNotifier sink;
  late _RecordingNotifier standardNotifier;
  late _Backend backend;
  late _FakeHc hc;

  setUp(() {
    weeklyMem = <String, String>{};
    weeklyStore = WeeklyReportStore.inMemory(weeklyMem);
    sink = WeeklySilentNotifier();
    standardNotifier = _RecordingNotifier();
    backend = _Backend();
    hc = _FakeHc();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required Future<WeeklyEntitlement> Function() entitlement,
    ReportGenerationPipeline? pipeline,
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
          healthConnectService: hc,
          savePdf: (bytes, name) async => '/tmp/$name',
          saveToDownloads: (bytes, name) async => true,
          sharePdf: (bytes, name) async {},
          weeklyEntitlementCheck: entitlement,
          weeklyStore: weeklyStore,
          weeklyNotifier: sink,
          weeklyClock: () => _pageNow,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  _FakePipeline fakePipeline(ReportSnapshot snap, {Completer<void>? gate}) =>
      _FakePipeline(
        collector: ReportDataCollector(
          backend: backend,
          hc: hc,
          insightsLoader: () async => const [],
        ),
        backend: backend,
        snapshot: snap,
        gate: gate,
      );

  /// Package 2 note: at this file's page clock (Wed Nov 18) the
  /// fixture week is the automation's DUE week, so an ungenerated
  /// archive would auto-generate on page open and the manual tap
  /// would no longer be the actor under test. Manual-path tests
  /// seed the week as already generated — automation is then
  /// inert by its own idempotency rule, and the manual run below
  /// (which replaces the seeded entry) is what every assertion
  /// measures.
  Future<void> seedFixtureWeek() => weeklyStore.upsert(WeeklyArchiveRecord(
        weekStartKey: _week.startKey,
        weekEndKey: _week.endKey,
        generatedAtMs: DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
        fileName: 'seed.pdf',
        savedPath: '/tmp/seed.pdf',
        label: WeeklyCompleteness.incomplete,
        blockedSections: const [],
        dailyScoreDays: 3,
        sleepNights: 3,
        loggedDays: 3,
        completeDays: 3,
        avgScoreCompleteDays: null,
      ));

  group('entitlement surfaces', () {
    testWidgets('free user: exactly ONE locked row, nothing else weekly',
        (tester) async {
      await pumpPage(tester, entitlement: () async => WeeklyEntitlement.free);
      expect(find.text('Weekly reports'), findsOneWidget);
      expect(find.text('Weekly report'), findsOneWidget);
      expect(
          find.text(
              'Available with Premium. A weekly summary of your logs and Daily Score.'),
          findsOneWidget);
      expect(find.text('Generate Weekly Report'), findsNothing);
      expect(
          find.text(
              'Weekly reports have stopped. Your existing reports remain available.'),
          findsNothing);
      expect(find.text('No weekly reports yet.'), findsNothing);
    });

    testWidgets(
        'lapsed Premium: the stopped line only, existing reports stay '
        'listed and readable', (tester) async {
      await weeklyStore.upsert(WeeklyArchiveRecord(
        weekStartKey: '2026-11-02',
        weekEndKey: '2026-11-08',
        generatedAtMs: DateTime(2026, 11, 9, 9).millisecondsSinceEpoch,
        fileName: 'report.pdf',
        savedPath: '/tmp/report.pdf',
        label: WeeklyCompleteness.incomplete,
        blockedSections: const [],
        dailyScoreDays: 3,
        sleepNights: 3,
        loggedDays: 3,
        completeDays: 3,
        avgScoreCompleteDays: null,
      ));
      await pumpPage(tester,
          entitlement: () async => WeeklyEntitlement.lapsed);
      expect(
          find.text(
              'Weekly reports have stopped. Your existing reports remain available.'),
          findsOneWidget);
      expect(find.text('Nov 2 – Nov 8, 2026'), findsOneWidget);
      expect(find.text('Incomplete'), findsOneWidget);
      expect(find.text('Generate Weekly Report'), findsNothing);
    });

    testWidgets('premium with no reports yet: generate action + empty state',
        (tester) async {
      await pumpPage(tester,
          entitlement: () async => WeeklyEntitlement.premium);
      expect(find.text('Generate Weekly Report'), findsOneWidget);
      expect(find.text('No weekly reports yet.'), findsOneWidget);
    });

    testWidgets(
        'fail-closed: an entitlement check that throws never reads as '
        'Premium and never generates', (tester) async {
      final pipeline = fakePipeline(_snap());
      await pumpPage(
        tester,
        entitlement: () async => throw StateError('network down'),
        pipeline: pipeline,
      );
      expect(find.text('Generate Weekly Report'), findsNothing);
      expect(find.text('Weekly report'), findsOneWidget,
          reason: 'unknown entitlement falls to the free surface');
      expect(pipeline.generateCalls, 0);
    });

    testWidgets(
        'fail-closed PRE-GENERATION: entitlement lapsing between page '
        'load and the tap stops generation silently — no PDF, no '
        'archive entry, nothing', (tester) async {
      var checks = 0;
      final pipeline = fakePipeline(_snap());
      await pumpPage(
        tester,
        entitlement: () async =>
            ++checks == 1 ? WeeklyEntitlement.premium : WeeklyEntitlement.lapsed,
        pipeline: pipeline,
      );
      expect(find.text('Generate Weekly Report'), findsOneWidget);
      await tester.tap(find.text('Generate Weekly Report'));
      await tester.pumpAndSettle();
      expect(pipeline.generateCalls, 0,
          reason: 'the pre-generation re-check must stop the run');
      expect(await weeklyStore.readAll(), isEmpty);
      expect(sink.calls, 0);
    });
  });

  group('manual generation + archive', () {
    testWidgets(
        'premium generation archives the week labeled Complete and '
        'posts zero notifications', (tester) async {
      await seedFixtureWeek();
      final pipeline = fakePipeline(_snap());
      await pumpPage(tester,
          entitlement: () async => WeeklyEntitlement.premium,
          pipeline: pipeline);
      await tester.tap(find.text('Generate Weekly Report'));
      // The seed already made the store non-empty (see
      // seedFixtureWeek), so wait for the MANUAL run's own
      // outcome: the pipeline ran and the entry relabeled
      // Complete (the seed was Incomplete).
      await _pumpUntil(
          tester,
          () =>
              pipeline.generateCalls > 0 &&
              find.text('Complete').evaluate().isNotEmpty);
      final records = await weeklyStore.readAll();
      expect(records.length, 1);
      expect(records.single.weekStartKey, '2026-11-09');
      expect(records.single.label, WeeklyCompleteness.complete);
      await tester.pumpAndSettle();
      expect(find.text('Nov 9 – Nov 15, 2026'), findsOneWidget);
      expect(find.text('Generated Nov 18, 2026'), findsOneWidget);
      expect(find.text('Complete'), findsOneWidget);
      expect(standardNotifier.shows, 0,
          reason: 'the PR #55 notifier is never used on the weekly path');
    });

    testWidgets(
        'away completion: the weekly service\u2019s only notifier is '
        'the recording sink — attempts are counted, sends are zero',
        (tester) async {
      await seedFixtureWeek();
      final gate = Completer<void>();
      final pipeline = fakePipeline(_snap(), gate: gate);
      await pumpPage(tester,
          entitlement: () async => WeeklyEntitlement.premium,
          pipeline: pipeline);
      await tester.tap(find.text('Generate Weekly Report'));
      await _pumpUntil(tester, () => pipeline.generateCalls > 0);
      // The user leaves mid-generation (Tyson's PR #55 sequence).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      gate.complete();
      await _pumpUntil(tester, () => sink.calls > 0);
      expect(sink.calls, 1,
          reason: 'the completion tried to announce exactly once, '
              'into the sink');
      expect(standardNotifier.shows, 0);
      expect((await weeklyStore.readAll()).length, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pumpUntil(tester,
          () => find.text('Share health report').evaluate().isNotEmpty);
      expect(find.text('Share health report'), findsOneWidget);
    });

    testWidgets(
        'permission-blocked week: Juno §a state verbatim, sections '
        'named, settings action wired, Not now dismisses and the '
        'Blocked entry stays', (tester) async {
      await seedFixtureWeek();
      // A verified-denial snapshot the real collector can
      // actually produce: the denied sections' series are
      // EMPTY (the derivation only derives permissionDenied
      // for a failed, empty read); scores and entries remain.
      final days = _week.days;
      final deniedSnap = ReportSnapshot(
        last30Days: false,
        weekStart: _week.start,
        weekEnd: _week.end,
        generationTimestampMs: _pageNow.millisecondsSinceEpoch,
        logEntries: [for (var i = 0; i < 5; i++) _entry(i + 1, days[i])],
        categoriesMap: const {1: 'Symptoms'},
        dailyScoreSeries: [for (final d in days) (dateStrOf(d), 60)],
        sectionMetadata: const {
          'sleep':
              SectionMetadata('sleep', DataSourceStatus.permissionDenied, 0),
          'deepSleep': SectionMetadata(
              'deepSleep', DataSourceStatus.permissionDenied, 0),
        },
      );
      final pipeline = fakePipeline(deniedSnap);
      await pumpPage(tester,
          entitlement: () async => WeeklyEntitlement.premium,
          pipeline: pipeline);
      await tester.tap(find.text('Generate Weekly Report'));
      await _pumpUntil(tester, () => weeklyMem.isNotEmpty);
      await tester.pumpAndSettle();

      final records = await weeklyStore.readAll();
      expect(records.single.label, WeeklyCompleteness.blocked);
      expect(records.single.blockedSections, ['Sleep', 'DeepSleep']);

      // Dismiss the share confirmation first (its own 'Not now').
      expect(find.text('Share health report'), findsOneWidget);
      await tester.tap(find.text('Not now').first);
      await tester.pumpAndSettle();

      expect(find.text('Permission needed'), findsOneWidget);
      expect(
          find.text(
              "This report isn't complete. Tabs couldn't read the sections below because permission wasn't granted."),
          findsOneWidget);
      expect(find.text('Needs permission:'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('DeepSleep'), findsOneWidget);
      expect(
          find.text(
              'Grant access in Health Connect, then generate the report again.'),
          findsOneWidget);
      expect(find.text('Blocked'), findsOneWidget);

      await tester.tap(find.text('Open Health Connect Settings'));
      await tester.pumpAndSettle();
      expect(hc.settingsOpens, 1,
          reason: 'the same HC settings route the Settings surface uses');

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Permission needed'), findsNothing);
      expect(find.text('Blocked'), findsOneWidget,
          reason: 'dismissal leaves the archive entry, labeled Blocked');
    });

    testWidgets(
        'fully blocked week through the REAL pipeline: an empty '
        'weekly snapshot still ships, archives Blocked, and raises '
        'the permission state (no no-data failure)', (tester) async {
      await seedFixtureWeek();
      final emptyBlocked = ReportSnapshot(
        last30Days: false,
        weekStart: _week.start,
        weekEnd: _week.end,
        generationTimestampMs: _pageNow.millisecondsSinceEpoch,
        logEntries: const [],
        categoriesMap: const {1: 'Symptoms'},
        sectionMetadata: const {
          'sleep':
              SectionMetadata('sleep', DataSourceStatus.permissionDenied, 0),
          'heartRate': SectionMetadata(
              'heartRate', DataSourceStatus.permissionDenied, 0),
        },
      );
      final pipeline = ReportGenerationPipeline(
        collector: _CannedCollector(snapshot: emptyBlocked),
        backend: backend,
      );
      await pumpPage(tester,
          entitlement: () async => WeeklyEntitlement.premium,
          pipeline: pipeline);
      await tester.tap(find.text('Generate Weekly Report'));
      await _pumpUntil(tester, () => weeklyMem.isNotEmpty);
      await tester.pumpAndSettle();
      final records = await weeklyStore.readAll();
      expect(records.length, 1);
      expect(records.single.label, WeeklyCompleteness.blocked);
      expect(records.single.blockedSections, ['Sleep', 'HeartRate']);
      expect(find.text('Permission needed'), findsOneWidget);
    });

    testWidgets(
        'the standard pipeline keeps its no-data failure for '
        'non-weekly ranges (weekly bypass is scoped)', (tester) async {
      final emptyStandard = ReportSnapshot(
        last30Days: true,
        generationTimestampMs: _pageNow.millisecondsSinceEpoch,
        logEntries: const [],
        categoriesMap: const {1: 'Symptoms'},
      );
      final pipeline = ReportGenerationPipeline(
        collector: _CannedCollector(snapshot: emptyStandard),
        backend: backend,
      );
      final outcome = await pipeline.generate(
        selectedCategories: [_cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        forceRawFallback: true,
        renderPdf: (snapshot, aiSummary,
                {required bool isRawFallback, RawReportBanner? rawBanner}) async =>
            const [1, 2, 3],
        savePdf: (bytes, name) async => '/tmp/$name',
      );
      expect(outcome, isA<ReportFailed>());
      expect((outcome as ReportFailed).message,
          'No patient logs or health data found in selected range.');
    });
  });
}
