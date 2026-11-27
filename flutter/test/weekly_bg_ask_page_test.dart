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

// ── Weekly Report Background Generation — the Juno
// background-access ask arc (JUNO-RULING 2026-11-24, Flags
// BG-1–BG-5), on the Progress Reports weekly surface.
//
// Fixture week: Mon Nov 9 – Sun Nov 15, 2026; the page clock is
// Sunday Nov 15, 2026, 21:30 (the due week's trigger). The due
// week is seeded into the archive for the ask-only fixtures so
// the automation check is a pure no-op and cannot interfere.

final _week = WeeklyWeekWindow(DateTime(2026, 11, 9), DateTime(2026, 11, 15));
final _sundayNight = DateTime(2026, 11, 15, 21, 30);

const _askTitle = 'Background generation';
const _askBody =
    'With background access in Health Connect, Tabs can generate your weekly report on Sunday night without you opening the app. Without it, your report still generates the first time you open Tabs after Sunday night.';
const _askGuidance =
    'In Health Connect, go to App permissions, then Tabs, then Additional access, and turn on Access data in the background.';

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
  id: id,
  name: name,
  icon: 'x',
  colorHex: '#FF0000',
  isDefault: true,
  sortOrder: id,
);

QuickLogEntry _entry(int id, DateTime day) => QuickLogEntry(
  id: id,
  categoryId: '1',
  body: 'entry $id',
  chips: '',
  manualText: '',
  timestamp: DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch,
);

ReportSnapshot _snap({bool blocked = false}) {
  final days = _week.days;
  return ReportSnapshot(
    last30Days: false,
    weekStart: _week.start,
    weekEnd: _week.end,
    generationTimestampMs: _sundayNight.millisecondsSinceEpoch,
    logEntries: [for (var i = 0; i < 5; i++) _entry(i + 1, days[i])],
    categoriesMap: const {1: 'Symptoms'},
    dailyScoreSeries: [for (final d in days) (dateStrOf(d), 60)],
    sleepSeries: [for (final d in days) (dateStrOf(d), 420)],
    sectionMetadata: blocked
        ? const {
            'heartRate': SectionMetadata(
              'heartRate',
              DataSourceStatus.permissionDenied,
              0,
            ),
          }
        : const {},
  );
}

class _Backend extends TabsBackend {
  _Backend() : super(sessionStore: FakeSessionStore());

  @override
  Future<({bool isUnlimited, bool isAdmin})> fetchMembership() async =>
      (isUnlimited: true, isAdmin: false);

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => [
    _cat(1, 'Symptoms'),
  ];

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
    required Future<String> Function(List<int> bytes, String fileName) savePdf,
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
    final bytes = await renderPdf(
      snapshot,
      null,
      isRawFallback: true,
      rawBanner: RawReportBanner.explicitChoice,
    );
    final fileName = reportFileName(
      DateTime.fromMillisecondsSinceEpoch(snapshot.generationTimestampMs),
    );
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

void main() {
  late Map<String, String> weeklyMem;
  late Map<String, String> settingsMem;
  late WeeklyReportStore weeklyStore;
  late _Backend backend;

  setUp(() {
    weeklyMem = <String, String>{};
    settingsMem = <String, String>{};
    weeklyStore = WeeklyReportStore.inMemory(weeklyMem);
    backend = _Backend();
  });

  SettingsStore settingsStore() => SettingsStore.withStorage(
    read: (k) async => settingsMem[k],
    write: (k, v) async => settingsMem[k] = v,
    delete: (k) async => settingsMem.remove(k),
  );

  Future<void> seedDueWeek() => weeklyStore.upsert(
    WeeklyArchiveRecord(
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
    ),
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    required Future<WeeklyEntitlement> Function() entitlement,
    required Future<bool?> Function() bgCheck,
    ReportGenerationPipeline? pipeline,
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProgressReportsPage(
            profileData: const SettingsProfileData(),
            backend: backend,
            store: settingsStore(),
            pipeline: pipeline,
            clinicianPremiumCheck: () async => true,
            reportReadyNotifier: _RecordingNotifier(),
            healthConnectService: HealthConnectService(),
            savePdf: (bytes, name) async => '/tmp/$name',
            saveToDownloads: (bytes, name) async => true,
            sharePdf: (bytes, name) async {},
            weeklyEntitlementCheck: entitlement,
            weeklyStore: weeklyStore,
            weeklyNotifier: WeeklySilentNotifier(),
            weeklyAutoNotifier: _RecordingWeeklyNotifier(),
            weeklyBackgroundAccessCheck: bgCheck,
            weeklyClock: clock ?? () => _sundayNight,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  _FakePipeline fakePipeline({bool blocked = false}) => _FakePipeline(
    collector: ReportDataCollector(
      backend: backend,
      hc: HealthConnectService(),
      insightsLoader: () async => const [],
    ),
    backend: backend,
    snapshot: _snap(blocked: blocked),
  );

  test('Juno strings are byte-exact (rows 3.1–3.5)', () {
    expect(weeklyBgTitle, _askTitle);
    expect(weeklyBgBody, _askBody);
    expect(weeklyBgGuidance, _askGuidance);
    expect(weeklyBgPrimaryAction, 'Open Health Connect Settings');
    expect(weeklyBgSecondaryAction, 'Not now');
    // Banned inside the ask (Juno §b/§c): no "automatic", no exact
    // time, no deadline construction.
    for (final s in [weeklyBgTitle, weeklyBgBody, weeklyBgGuidance]) {
      expect(s.toLowerCase(), isNot(contains('automatic')));
      expect(s, isNot(contains('9:00')));
      expect(s, isNot(contains('by Sunday night')));
      expect(s, isNot(contains('will be ready')));
    }
  });

  testWidgets('BG-1 (direction 1): Premium + verified-absent grant + '
      'healthy data sections ⇒ the ask shows (byte-exact) and '
      'NO §a permission-needed state shows', (tester) async {
    await seedDueWeek();
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => false,
    );
    expect(find.text(_askTitle), findsOneWidget);
    expect(find.text(_askBody), findsOneWidget);
    expect(find.text(_askGuidance), findsOneWidget);
    expect(find.text('Open Health Connect Settings'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.text('Permission needed'), findsNothing);
  });

  testWidgets('BG-1 (direction 2): a verified data-section denial with '
      'the background grant PRESENT shows the §a state and NO '
      'ask', (tester) async {
    // No seeded week: the Sunday-night automation generates the
    // blocked fixture week, which raises the §a state.
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => true,
      pipeline: fakePipeline(blocked: true),
    );
    expect(find.text('Permission needed'), findsOneWidget);
    expect(find.text(_askTitle), findsNothing);
    expect(find.text(_askBody), findsNothing);
  });

  testWidgets('BG-2: free user never sees the ask (not even '
      'locked/greyed)', (tester) async {
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.free,
      bgCheck: () async => false,
    );
    expect(find.text(_askTitle), findsNothing);
    expect(find.text(_askBody), findsNothing);
  });

  testWidgets('BG-2: lapsed user never sees the ask', (tester) async {
    await seedDueWeek();
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.lapsed,
      bgCheck: () async => false,
    );
    expect(find.text(_askTitle), findsNothing);
  });

  testWidgets('BG-2: entitlement resolver failure renders '
      'nothing (the page resolves fail-closed to free/lapsed, '
      'never Premium)', (tester) async {
    await pumpPage(
      tester,
      entitlement: () async => throw StateError('resolver down'),
      bgCheck: () async => false,
    );
    // The page's resolver contract: a throwing override propagates
    // to _loadWeekly's caller path — the ask must not render on an
    // unverified entitlement in any case.
    expect(find.text(_askTitle), findsNothing);
  });

  testWidgets('BG-3: probe failure / unknown renders nothing', (tester) async {
    await seedDueWeek();
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => null,
    );
    expect(find.text(_askTitle), findsNothing);
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => throw StateError('bridge down'),
    );
    expect(find.text(_askTitle), findsNothing);
  });

  testWidgets('BG-5: granted state is silent — no ask, no '
      'status line, slot not repurposed', (tester) async {
    await seedDueWeek();
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => true,
    );
    expect(find.text(_askTitle), findsNothing);
    expect(find.text(_askBody), findsNothing);
    expect(find.text(_askGuidance), findsNothing);
  });

  testWidgets('BG-4: Not now dismisses for exactly 28 days — same-day '
      'revisit absent, day 29 present, and a grant removes the '
      'ask regardless of the window', (tester) async {
    await seedDueWeek();
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => false,
    );
    expect(find.text(_askTitle), findsOneWidget);

    // Dismiss.
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(
      find.text(_askTitle),
      findsNothing,
      reason: 'dismissed in the same render',
    );

    // Same-day revisit (fresh page over the same persisted
    // stores): still absent.
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => false,
    );
    expect(
      find.text(_askTitle),
      findsNothing,
      reason: 'the dismissal persists across restarts',
    );

    // Day 29 (clock 29 days after the tap; the seeded week is
    // still the archive record — the due-week math at that clock
    // targets a later week, but entitlement + verified absence +
    // expired window are what gate the ask): present again.
    final day29 = _sundayNight.add(const Duration(days: 29));
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => false,
      pipeline: fakePipeline(),
      clock: () => day29,
    );
    expect(
      find.text(_askTitle),
      findsOneWidget,
      reason: 'the 28-day window has expired',
    );

    // Grant removes the ask regardless of window state: dismiss
    // again, then revisit with the grant present inside the new
    // window — still absent (silent granted state).
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => true,
      pipeline: fakePipeline(),
      clock: () => day29,
    );
    expect(find.text(_askTitle), findsNothing);
  });

  testWidgets('BG-4: return-without-granting is NOT a dismissal — the '
      'ask remains after the settings return re-check', (tester) async {
    await seedDueWeek();
    var granted = false;
    await pumpPage(
      tester,
      entitlement: () async => WeeklyEntitlement.premium,
      bgCheck: () async => granted,
    );
    expect(find.text(_askTitle), findsOneWidget);
    // Tap the primary action: the (unmocked) settings intent
    // fails visibly as before, the re-check runs, the grant is
    // still absent, and no dismissal window was started.
    await tester.tap(find.text('Open Health Connect Settings'));
    await tester.pumpAndSettle();
    expect(
      find.text(_askTitle),
      findsOneWidget,
      reason: 'returning without granting starts no window',
    );
    expect(settingsMem[SettingsStore.weeklyBgAskDismissedAtKey], isNull);
    // And when the grant lands, the return re-check (lifecycle
    // resume — the established re-verify-on-return pattern)
    // removes the ask in the same render.
    granted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(_askTitle), findsNothing);
  });
}
