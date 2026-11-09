import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/report_ready_notification.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Report-ready completion notification (founder request,
// Nov 9, 2026) ───────────────────────────────────────────────────
//
// Tyson started a generation, left the app, and was never told
// it finished — the share dialog was waiting when he happened
// back. The page now posts the report-ready notification when a
// generation completes while the user is away (app
// backgrounded), holds the share confirmation, and presents it
// when the user returns. Watched completions show the dialog
// only; cancelled and failed generations notify nothing.
//
// Choreography note: a widget test cannot background the app
// before the tap (the paused scheduler never delivers it), so
// each away test starts the generation in the foreground, holds
// it open on a staged gate, backgrounds the app mid-generation
// — exactly Tyson's sequence — and then releases the gate.

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

/// A collector whose documents stage parks on [gate] until the
/// test releases it — a generation held open mid-flight.
ReportDataCollector _gatedCollector(
  _FakeBackend backend, {
  required Completer<void> gate,
  required void Function() onDocsEntered,
}) =>
    ReportDataCollector(
      backend: backend,
      hc: _FakeHcDisconnected(),
      documentsLoader: () async {
        onDocsEntered();
        await gate.future;
        return const [];
      },
    );

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 100,
}) async {
  for (var i = 0; i < maxPumps && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  Future<({_FakeReportReadyNotifier notifier, _FakeBackend backend})>
      pumpPage(
    WidgetTester tester, {
    ReportGenerationPipeline? pipeline,
    ClinicianReportPipeline? clinicianPipeline,
    _FakeBackend? backend,
  }) async {
    final notifier = _FakeReportReadyNotifier();
    final be = backend ?? _FakeBackend();
    final mem = <String, String>{};
    final store = SettingsStore.withStorage(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    // A tall surface keeps the whole page (including the busy
    // block with the cancel button) onstage: inside a short
    // viewport the busy block renders below the page ListView's
    // cache edge, where default finders cannot evaluate it and
    // ensureVisible has no element to scroll to.
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProgressReportsPage(
          profileData: const SettingsProfileData(),
          backend: be,
          store: store,
          pipeline: pipeline,
          clinicianPipeline: clinicianPipeline,
          clinicianPremiumCheck: () async => true,
          reportReadyNotifier: notifier,
          savePdf: (bytes, name) async => '/tmp/$name',
          saveToDownloads: (bytes, name) async => true,
          sharePdf: (bytes, name) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (notifier: notifier, backend: be);
  }

  testWidgets(
      'away completion: notification posts, dialog is held, '
      'resume presents the share confirmation', (tester) async {
    final backend = _FakeBackend();
    final gate = Completer<void>();
    var docsEntered = false;
    final pipeline = ReportGenerationPipeline(
      collector: _gatedCollector(backend,
          gate: gate, onDocsEntered: () => docsEntered = true),
      backend: backend,
    );
    final h = await pumpPage(tester, pipeline: pipeline);

    await tester.ensureVisible(find.text('Export PDF Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export PDF Report'));
    await _pumpUntil(tester, () => docsEntered);
    expect(docsEntered, isTrue);

    // Tyson's sequence: leave the generation running.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    gate.complete();
    await _pumpUntil(tester, () => h.notifier.shows > 0);
    expect(h.notifier.shows, 1);
    expect(find.text('Share health report'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpUntil(
        tester, () => find.text('Share health report').evaluate().isNotEmpty);
    expect(find.text('Share health report'), findsOneWidget);
    expect(h.notifier.shows, 1,
        reason: 'one completion posts exactly one notification');
  });

  testWidgets('watched completion: dialog only, no notification',
      (tester) async {
    final backend = _FakeBackend();
    final pipeline = ReportGenerationPipeline(
      collector: ReportDataCollector(
        backend: backend,
        hc: _FakeHcDisconnected(),
      ),
      backend: backend,
    );
    final h = await pumpPage(tester, pipeline: pipeline);

    await tester.ensureVisible(find.text('Export PDF Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export PDF Report'));
    await _pumpUntil(
        tester, () => find.text('Share health report').evaluate().isNotEmpty);
    expect(find.text('Share health report'), findsOneWidget);
    expect(h.notifier.shows, 0);
  });

  testWidgets('cancelled generation posts no notification',
      (tester) async {
    final backend = _FakeBackend();
    final gate = Completer<void>();
    var docsEntered = false;
    final pipeline = ReportGenerationPipeline(
      collector: _gatedCollector(backend,
          gate: gate, onDocsEntered: () => docsEntered = true),
      backend: backend,
    );
    final h = await pumpPage(tester, pipeline: pipeline);

    await tester.ensureVisible(find.text('Export PDF Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export PDF Report'));
    await _pumpUntil(tester, () => docsEntered);
    expect(docsEntered, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    await tester.ensureVisible(find.text('Cancel Report Generation'));
    await tester.tap(find.text('Cancel Report Generation'));
    await tester.pump();
    gate.complete();
    // The cancellation completes while the user is away: no
    // notification may post. (Frame production is throttled
    // while paused in the test binding, so the idle-state UI is
    // asserted after returning to the foreground — the outcome
    // was already decided by then.)
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(h.notifier.shows, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpUntil(
        tester, () => find.text('Export PDF Report').evaluate().isNotEmpty);
    expect(find.text('Export PDF Report'), findsOneWidget);
    expect(h.notifier.shows, 0);
    expect(find.text('Share health report'), findsNothing);
  });

  testWidgets('failed generation posts no notification', (tester) async {
    // The pipeline's own backend sees no logs at all, so the
    // collection completes with no data — a ReportFailed outcome.
    // (The page's backend still has entries, so Export is live.)
    final emptyBackend = _FakeBackend()..entries = const [];
    final gate = Completer<void>();
    var docsEntered = false;
    final pipeline = ReportGenerationPipeline(
      collector: _gatedCollector(emptyBackend,
          gate: gate, onDocsEntered: () => docsEntered = true),
      backend: emptyBackend,
    );
    final h = await pumpPage(tester, pipeline: pipeline);

    await tester.ensureVisible(find.text('Export PDF Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export PDF Report'));
    await _pumpUntil(tester, () => docsEntered);
    expect(docsEntered, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    gate.complete();
    // Wait on the failure text itself (a UI-observable condition)
    // rather than a proxy: the completion lands a frame after the
    // pipeline's last microtask.
    await _pumpUntil(
        tester,
        () => find
            .text('No patient logs or health data found in selected range.')
            .evaluate()
            .isNotEmpty,
        maxPumps: 200);
    await tester.ensureVisible(
        find.text('No patient logs or health data found in selected range.'));
    await tester.pumpAndSettle();
    expect(
        find.text('No patient logs or health data found in selected range.'),
        findsOneWidget);
    expect(h.notifier.shows, 0);
    expect(find.text('Share health report'), findsNothing);
  });

  testWidgets('clinician away completion also notifies and holds',
      (tester) async {
    final backend = _FakeBackend();
    final scoreGate = Completer<void>();
    var scoreEntered = false;
    final clinicianPipeline = ClinicianReportPipeline(
      collector: ReportDataCollector(
        backend: backend,
        hc: _FakeHcDisconnected(),
      ),
      clinicianCollector: ClinicianReportCollector(
        scoreLoader: () async {
          scoreEntered = true;
          await scoreGate.future;
          return const {};
        },
        eventsLoader: () async => const [],
        categoriesLoader: () async => _cats(),
      ),
    );
    final h = await pumpPage(tester, clinicianPipeline: clinicianPipeline);

    await tester
        .ensureVisible(find.text('Export Clinician Report (1 page)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export Clinician Report (1 page)'));
    await _pumpUntil(tester, () => scoreEntered);
    expect(scoreEntered, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    scoreGate.complete();
    await _pumpUntil(tester, () => h.notifier.shows > 0);
    expect(h.notifier.shows, 1);
    expect(find.text('Share health report'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpUntil(
        tester, () => find.text('Share health report').evaluate().isNotEmpty);
    expect(find.text('Share health report'), findsOneWidget);
  });

  test('bootstrap routes the report-ready payload to its handler only',
      () {
    NotificationBootstrap.debugReset();
    addTearDown(NotificationBootstrap.debugReset);
    var reportTaps = 0;
    NotificationBootstrap.registerReportReadyTapHandler(() => reportTaps++);
    NotificationBootstrap.dispatchNotificationResponse(
      const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotification,
        payload: LocalReportReadyNotifier.payload,
      ),
    );
    expect(reportTaps, 1);
    // A Daily Score payload (a date) must not reach the report
    // handler, and an empty payload routes nowhere.
    NotificationBootstrap.dispatchNotificationResponse(
      const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotification,
        payload: '2026-11-09',
      ),
    );
    NotificationBootstrap.dispatchNotificationResponse(
      const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotification,
      ),
    );
    expect(reportTaps, 1);
  });

  test('report-ready notifier identity cannot collide with the '
      'score or migraine notifications', () {
    expect(LocalReportReadyNotifier.notificationId, isNot(7301));
    expect(LocalReportReadyNotifier.notificationId, isNot(7302));
    expect(LocalReportReadyNotifier.notificationId, isNot(7303));
    expect(LocalReportReadyNotifier.channelId, 'report_ready');
    expect(LocalReportReadyNotifier.payload, 'report_ready');
    // Juno ruling 2026-11-09, §0 — the verbatim string set. Any
    // change here returns to Juno before it ships.
    expect(LocalReportReadyNotifier.channelName, 'Progress reports');
    expect(LocalReportReadyNotifier.channelDescription,
        'Shows when a report you requested has finished generating.');
    expect(LocalReportReadyNotifier.title, 'Your report is ready');
    expect(LocalReportReadyNotifier.body,
        'Tap to return to the report and share it.');
    expect(LocalReportReadyNotifier.isReportReadyPayload('2026-11-09'),
        isFalse);
    expect(
        LocalReportReadyNotifier.isReportReadyPayload(
            LocalReportReadyNotifier.payload),
        isTrue);
  });
}
