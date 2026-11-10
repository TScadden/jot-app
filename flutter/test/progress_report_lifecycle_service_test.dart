import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/report_generation_service.dart';
import 'package:tabs_lab/src/data/report_ready_notification.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/report_generation_presenter.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Report generation lifecycle ownership (founder bug,
// Nov 9, 2026) ───────────────────────────────────────────────────
//
// Tyson tapped Generate on Progress Reports, left to Home inside
// the app, came back, and found nothing generating — the run was
// owned by the page State and died with it. The run now belongs
// to ReportGenerationService; the page is a view of it, and the
// app-root ReportGenerationPresenter presents completions on
// whatever in-app screen is current. This harness reproduces the
// founder's navigation shape: a Home route, a pushed Progress
// Reports route (popping it disposes the page, like the Settings
// body swap / shell tab switch do), and the root presenter above
// the Navigator exactly as main.dart wires it.

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
    id: id,
    name: name,
    icon: 'x',
    colorHex: '#FF0000',
    isDefault: true,
    sortOrder: id);

List<QuickLogCategory> _cats() => [
      _cat(1, 'Symptoms'),
      _cat(2, 'Food & Eating'),
      _cat(3, 'Weight & Vitals'),
      _cat(8, 'Medication'),
      _cat(4, 'Goals & Habits'),
      _cat(5, 'Sleep'),
      _cat(6, 'Mood & Energy'),
      _cat(7, 'General'),
    ];

QuickLogEntry _entryNow(int id, int catId) => QuickLogEntry(
    id: id,
    categoryId: catId,
    body: 'b$id',
    chips: '',
    manualText: '',
    timestamp: DateTime.now().millisecondsSinceEpoch);

class _FakeBackend extends TabsBackend {
  List<QuickLogEntry> entries = [_entryNow(1, 1)];

  _FakeBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<({bool isUnlimited, bool isAdmin})> fetchMembership() async =>
      (isUnlimited: true, isAdmin: false);

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => _cats();

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => entries;

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];

  @override
  Future<
      ({
        int? statusCode,
        Map<String, dynamic>? body,
        String? serverError,
        AiTransportFailure? transportFailure,
      })> postAiDetailed(String path, Map<String, dynamic> body,
      {Duration? timeoutOverride}) async {
    return (
      statusCode: 200,
      body: {'result': '[SECTION] USER SUMMARY\nAll good.'},
      serverError: null,
      transportFailure: null,
    );
  }
}

class _FakeHcDisconnected extends HealthConnectService {
  @override
  Future<bool> isConnected() async => false;

  // Report Reliability Phase 1: the collector no longer consults
  // isConnected() — it always runs the union load. This fake
  // therefore answers the range reads in-memory too (empty, no
  // failure recorded), so generation never touches the platform
  // channel from a widget test's fake-async zone (the deadlock
  // this file's harness already guards against). The lifecycle
  // behavior under test is unchanged: at base the gate produced
  // empty HC sections; now the union produces the same empty
  // sections from clean empty reads.
  @override
  Future<Set<String>> getMissingPermissions() async =>
      HealthConnectService.requiredPermissions;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];
}

class _FakeReportReadyNotifier implements ReportReadyNotifier {
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
  int maxPumps = 100,
}) async {
  for (var i = 0; i < maxPumps && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _Harness {
  final ReportGenerationService service = ReportGenerationService();
  final _FakeReportReadyNotifier notifier = _FakeReportReadyNotifier();
  final _FakeBackend backend = _FakeBackend();
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  // Created synchronously: real async IO inside a testWidgets
  // body deadlocks the fake-async zone.
  final Directory saveDir =
      Directory.systemTemp.createTempSync('report_gen_lifecycle');
  int saves = 0;
  String? lastSavedPath;

  /// A pipeline whose documents stage parks on [gate].
  /// [backendOverride] gives the RUN its own backend (e.g. an
  /// empty one for a failure outcome) while the page keeps its
  /// entries, so Export stays live.
  ReportGenerationPipeline gatedPipeline(Completer<void> gate,
          {required void Function() onDocsEntered,
          _FakeBackend? backendOverride}) =>
      ReportGenerationPipeline(
        collector: ReportDataCollector(
          backend: backendOverride ?? backend,
          hc: _FakeHcDisconnected(),
          documentsLoader: () async {
            onDocsEntered();
            await gate.future;
            return const [];
          },
        ),
        backend: backendOverride ?? backend,
      );

  Future<void> pumpApp(WidgetTester tester,
      {required ReportGenerationPipeline pipeline}) async {
    addTearDown(() {
      if (saveDir.existsSync()) saveDir.deleteSync(recursive: true);
    });
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
      navigatorKey: navKey,
      builder: (context, child) => ReportGenerationPresenter(
        service: service,
        navigatorKey: navKey,
        store: store,
        sharePdf: (bytes, name) async {},
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () =>
                  Navigator.of(ctx).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: ProgressReportsPage(
                    profileData: const SettingsProfileData(),
                    backend: backend,
                    store: store,
                    pipeline: pipeline,
                    generationService: service,
                    reportReadyNotifier: notifier,
                    clinicianPremiumCheck: () async => true,
                    savePdf: (bytes, name) async {
                      saves++;
                      final f = File('${saveDir.path}/$name');
                      // Sync write: this seam runs inside the
                      // pipeline's fake-async test zone.
                      f.writeAsBytesSync(bytes, flush: true);
                      lastSavedPath = f.path;
                      return f.path;
                    },
                    saveToDownloads: (bytes, name) async => true,
                    sharePdf: (bytes, name) async {},
                  ),
                ),
              )),
              child: const Text('Open reports'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openReports(WidgetTester tester) async {
    await tester.tap(find.text('Open reports'));
    // Bounded pumps, never pumpAndSettle: a live generation's
    // spinner animates forever, so settling would hang the test.
    await _pumpUntil(
        tester, () => find.text('Open reports').evaluate().isEmpty);
    await tester.pump();
    await tester.pump();
  }

  Future<void> startGeneration(WidgetTester tester,
      {required bool Function() entered}) async {
    await tester.ensureVisible(find.text('Export PDF Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export PDF Report'));
    await _pumpUntil(tester, entered);
    expect(entered(), isTrue);
  }

  Future<void> leaveReports(WidgetTester tester) async {
    navKey.currentState!.pop();
    await _pumpUntil(
        tester, () => find.text('Open reports').evaluate().isNotEmpty);
    // Let the 300ms route transition finish so the page is
    // actually disposed (production timing: a generation runs
    // for minutes, long after the transition settled).
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Open reports'), findsOneWidget);
  }
}

void main() {
  // Phase 1 harness note (see _FakeHcDisconnected): the union
  // load reads the shared history store, so install the same
  // in-memory singleton backing the other report suites use.
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  testWidgets(
      '(a) generation started, page disposed via in-app navigation, '
      'run completes and the PDF file exists', (tester) async {
    final h = _Harness();
    final gate = Completer<void>();
    var entered = false;
    await h.pumpApp(tester,
        pipeline:
            h.gatedPipeline(gate, onDocsEntered: () => entered = true));
    await h.openReports(tester);
    await h.startGeneration(tester, entered: () => entered);

    // The founder's move: leave to Home inside the app. The page
    // is disposed; the service-owned run must not be.
    await h.leaveReports(tester);
    expect(h.service.isGenerating, isTrue);

    gate.complete();
    await _pumpUntil(tester, () => h.saves > 0);
    expect(h.saves, 1);
    expect(h.lastSavedPath, isNotNull);
    expect(File(h.lastSavedPath!).existsSync(), isTrue,
        reason: 'the completed run saved its PDF');
    expect(h.service.isGenerating, isFalse);
    expect(h.notifier.shows, 0,
        reason: 'in-app completion presents in-app, not by notification');
  });

  testWidgets(
      '(b) completion pop-up presents on a non-Reports screen '
      'exactly once', (tester) async {
    final h = _Harness();
    final gate = Completer<void>();
    var entered = false;
    await h.pumpApp(tester,
        pipeline:
            h.gatedPipeline(gate, onDocsEntered: () => entered = true));
    await h.openReports(tester);
    await h.startGeneration(tester, entered: () => entered);
    await h.leaveReports(tester);

    gate.complete();
    await _pumpUntil(
        tester, () => find.text('Share health report').evaluate().isNotEmpty);
    expect(find.text('Share health report'), findsOneWidget,
        reason: 'the share flow presents on Home, the current screen');

    // Duplicate reveal triggers (resume + notification tap racing
    // the presentation) must not stack a second dialog.
    h.service.handleResumed();
    h.service.handleNotificationTap();
    await tester.pumpAndSettle();
    expect(find.text('Share health report'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Share health report'), findsNothing);
    expect(h.service.pendingShare, isNull,
        reason: 'the held outcome is consumed once seen');
  });

  testWidgets(
      '(c) returning mid-run shows the live stage and Cancel works',
      (tester) async {
    final h = _Harness();
    final gate = Completer<void>();
    var entered = false;
    await h.pumpApp(tester,
        pipeline:
            h.gatedPipeline(gate, onDocsEntered: () => entered = true));
    await h.openReports(tester);
    await h.startGeneration(tester, entered: () => entered);
    await h.leaveReports(tester);

    // Back to Progress Reports while the run is still going: the
    // re-mounted page is a view of the live service state.
    await h.openReports(tester);
    await _pumpUntil(tester,
        () => find.text('Collecting patient data...').evaluate().isNotEmpty);
    expect(find.text('Collecting patient data...'), findsOneWidget);
    await tester.ensureVisible(find.text('Cancel Report Generation'));
    expect(find.text('Cancel Report Generation'), findsOneWidget);

    await tester.tap(find.text('Cancel Report Generation'));
    await tester.pump();
    gate.complete();
    await _pumpUntil(tester, () => !h.service.isGenerating);
    await tester.pumpAndSettle();
    expect(h.service.isGenerating, isFalse);
    expect(h.saves, 0, reason: 'a cancelled run saves nothing new');
    expect(find.text('Share health report'), findsNothing);
    expect(h.notifier.shows, 0);
    await tester.ensureVisible(find.text('Export PDF Report'));
    expect(find.text('Export PDF Report'), findsOneWidget);
  });

  testWidgets(
      '(d) backgrounded completion posts the notification and the '
      'resume reveal is the single held share flow', (tester) async {
    final h = _Harness();
    final gate = Completer<void>();
    var entered = false;
    await h.pumpApp(tester,
        pipeline:
            h.gatedPipeline(gate, onDocsEntered: () => entered = true));
    await h.openReports(tester);
    await h.startGeneration(tester, entered: () => entered);
    await h.leaveReports(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    gate.complete();
    await _pumpUntil(tester, () => h.notifier.shows > 0);
    expect(h.notifier.shows, 1);
    expect(find.text('Share health report'), findsNothing,
        reason: 'no in-app dialog while backgrounded');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpUntil(
        tester, () => find.text('Share health report').evaluate().isNotEmpty);
    expect(find.text('Share health report'), findsOneWidget,
        reason: 'exactly the held share confirmation, no extra dialog');
    expect(h.notifier.shows, 1);
  });

  testWidgets(
      'watched completion with both presenters mounted: the page '
      'presents, exactly once, no notification', (tester) async {
    final h = _Harness();
    final gate = Completer<void>();
    var entered = false;
    await h.pumpApp(tester,
        pipeline:
            h.gatedPipeline(gate, onDocsEntered: () => entered = true));
    await h.openReports(tester);
    await h.startGeneration(tester, entered: () => entered);

    gate.complete();
    await _pumpUntil(
        tester, () => find.text('Share health report').evaluate().isNotEmpty);
    expect(find.text('Share health report'), findsOneWidget);
    expect(h.notifier.shows, 0);
  });

  testWidgets(
      'failure completing on another in-app screen surfaces there '
      'with the existing failure copy and is not dropped',
      (tester) async {
    final h = _Harness();
    final gate = Completer<void>();
    var entered = false;
    // The pipeline's own backend sees no logs: collection
    // completes with no data — a ReportFailed outcome. (The page
    // still lists entries, so Export is live.)
    final emptyBackend = _FakeBackend()..entries = const [];
    await h.pumpApp(
        tester,
        pipeline: h.gatedPipeline(gate,
            onDocsEntered: () => entered = true,
            backendOverride: emptyBackend));
    await h.openReports(tester);
    await h.startGeneration(tester, entered: () => entered);
    await h.leaveReports(tester);

    gate.complete();
    const msg = 'No patient logs or health data found in selected range.';
    await _pumpUntil(tester, () => find.text(msg).evaluate().isNotEmpty,
        maxPumps: 200);
    expect(find.text(msg), findsOneWidget,
        reason: 'the failure surfaces on the current screen');
    expect(h.service.pendingFailure, isNull,
        reason: 'a surfaced failure has been seen, not held forever');
    expect(find.text('Share health report'), findsNothing);
    expect(h.notifier.shows, 0);
  });
}
