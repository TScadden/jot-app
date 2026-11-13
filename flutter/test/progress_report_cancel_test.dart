import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Cancel Report Generation (founder report, Nov 9, 2026) ──────
//
// Tyson's capture: mid-generation on Progress Reports ("Syncing
// health metrics..."), tapping "Cancel Report Generation" had no
// effect. Root cause: the button correctly sets the page's
// _cancelRequested flag, but ReportDataCollector.collect() never
// received the signal — both pipelines read it for the first time
// only AFTER collect() had run every backend pull and the whole
// Health Connect union load to completion. These tests stage a
// generation that parks inside collection, fire the same cancel
// the button fires, then let the in-flight stage finish: a working
// cancel must stop collection at the next stage boundary — the
// Health Connect sync stage is never entered, nothing is saved,
// and (widget test) the page returns to idle.

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
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async =>
      [_entryNow(1, 1)];

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];
}

class _FakeHcConnected extends HealthConnectService {
  @override
  Future<bool> isConnected() async => true;
}

/// Records whether the Health Connect union load — the "Syncing
/// health metrics..." stage — was ever entered.
class _RecordingQueries extends HealthHistoryQueries {
  bool loadEntered = false;

  @override
  Future<HistoryUnion> loadDays(
    int days, {
    DateTime? end,
    Set<HistoryMetric>? metrics,
    bool fetchFromHealthConnect = true,
  }) async {
    loadEntered = true;
    return const HistoryUnion(startDate: '2026-01-01', endDate: '2026-01-31');
  }
}

/// A collector whose documents stage parks on [gate], so a test
/// can fire cancel mid-collection and then let the stage finish.
({ReportDataCollector collector, _RecordingQueries queries})
    _stagedCollector(Completer<void> gate, void Function() onDocsEntered) {
  final queries = _RecordingQueries();
  final collector = ReportDataCollector(
    backend: _FakeBackend(),
    hc: _FakeHcConnected(),
    historyQueries: queries,
    documentsLoader: () async {
      onDocsEntered();
      await gate.future;
      return const [];
    },
    // Phase 4 Pkg4: collect() also reads the correlation insight
    // store through this loader. Left unstaged, the production
    // default reads FlutterSecureStorage, whose platform-channel
    // reply never lands in a fake-async widget test, so collect()
    // would pend forever after the documents gate opens.
    insightsLoader: () async => const [],
  );
  return (collector: collector, queries: queries);
}

void main() {
  testWidgets(
      'cancel during collection aborts before the Health Connect '
      'sync stage and returns the page to idle', (tester) async {
    final gate = Completer<void>();
    var docsEntered = false;
    final staged = _stagedCollector(gate, () => docsEntered = true);
    final backend = _FakeBackend();
    final pipeline = ReportGenerationPipeline(
      collector: staged.collector,
      backend: backend,
    );
    final mem = <String, String>{};
    final store = SettingsStore.withStorage(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    var saves = 0;
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
          backend: backend,
          store: store,
          pipeline: pipeline,
          savePdf: (bytes, name) async {
            saves++;
            return '/tmp/$name';
          },
          saveToDownloads: (bytes, name) async => true,
          sharePdf: (bytes, name) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Export PDF Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export PDF Report'));
    // Advance until collection reaches the gated documents stage.
    for (var i = 0; i < 50 && !docsEntered; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(docsEntered, isTrue);
    // The flag flips in a microtask; the busy frame lands a pump
    // later. Settle before touching the busy block.
    await tester.pump();
    await tester.pump();
    await tester.ensureVisible(find.text('Cancel Report Generation'));
    await tester.pump();
    expect(find.text('Collecting patient data...'), findsOneWidget);
    expect(find.text('Cancel Report Generation'), findsOneWidget);

    // The same action the founder's tap performs.
    await tester.tap(find.text('Cancel Report Generation'));
    await tester.pump();

    // The in-flight documents read finishes; the cancel must now
    // stop the generation at the next stage boundary.
    gate.complete();
    for (var i = 0;
        i < 50 && find.text('Cancel Report Generation').evaluate().isNotEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(staged.queries.loadEntered, isFalse,
        reason: 'a cancelled collection must never enter the Health '
            'Connect sync stage');
    expect(saves, 0, reason: 'a cancelled generation saves no PDF');
    expect(find.text('Cancel Report Generation'), findsNothing);
    expect(find.text('Syncing health metrics...'), findsNothing);
    expect(find.text('Share health report'), findsNothing);
    // Idle again: the export button is back and enabled.
    await tester.ensureVisible(find.text('Export PDF Report'));
    await tester.pumpAndSettle();
    expect(find.text('Export PDF Report'), findsOneWidget);
    final exportButton = tester.widget<ElevatedButton>(find.ancestor(
      of: find.text('Export PDF Report'),
      matching: find.byType(ElevatedButton),
    ));
    expect(exportButton.onPressed, isNotNull);
  });

  test(
      'clinician pipeline: cancel during collection returns '
      'Cancelled, never enters the sync stage, saves nothing',
      () async {
    final gate = Completer<void>();
    var docsEntered = false;
    final staged = _stagedCollector(gate, () => docsEntered = true);
    final pipeline = ClinicianReportPipeline(
      collector: staged.collector,
      clinicianCollector: ClinicianReportCollector(
        scoreLoader: () async => const {},
        eventsLoader: () async => const [],
        categoriesLoader: () async => _cats(),
      ),
    );
    var cancelled = false;
    var saves = 0;
    final outcomeFuture = pipeline.generate(
      selectedCategories: _cats(),
      last30Days: true,
      profile: const ReportProfileInput(),
      isCancelled: () => cancelled,
      renderPdf: (data) async => const [1, 2, 3],
      savePdf: (bytes, name) async {
        saves++;
        return '/tmp/$name';
      },
    );
    for (var i = 0; i < 100 && !docsEntered; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(docsEntered, isTrue);
    cancelled = true;
    gate.complete();
    final outcome = await outcomeFuture;
    expect(outcome, isA<ReportFailed>());
    expect((outcome as ReportFailed).message, 'Cancelled');
    expect(staged.queries.loadEntered, isFalse,
        reason: 'a cancelled collection must never enter the Health '
            'Connect sync stage');
    expect(saves, 0);
  });
}
