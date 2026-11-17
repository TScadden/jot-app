// Pickup reconciliation (post-VC 100131 fix) — acceptance tests.
//
// The defect (founder incident, Nov 17, 2026): pickup was checked
// ONLY inside the AI leg, so once a leg exhausted and its outcome
// was HELD as a decision (same-session) or restored as one
// (Case 2), no code path ever checked pickup again for that
// identity — a report the server had finished and was holding
// sat uncollected behind a failure surface (server row
// d1d550c6…, ready, never picked up).
//
// The fix under test:
// - ReportGenerationService.reconcileDecisionPickup(): a one-shot
//   pickup-ONLY probe for a held/restored decision, triggered by
//   handleResumed() / registerPagePresenter() / useBackend(),
//   guarded (no run in flight, identity present, tombstone never,
//   once per decision record), delivering Ready through the
//   existing run paths via the pipeline's prefetched-narrative
//   seam (the probe consumes the server's held row, so the
//   narrative is handed to the leg, never re-fetched).
// - Founder shapes must FAIL on unmodified 84bb2a70 (no probe is
//   ever issued there) and PASS here.
//
// All pickups/POSTs are fakes — no production calls, ever.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/report_generation_journal.dart';
import 'package:tabs_lab/src/data/report_generation_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

typedef AiResult = ({
  int? statusCode,
  Map<String, dynamic>? body,
  String? serverError,
  AiTransportFailure? transportFailure,
});

AiResult aiOk([String text = '[SECTION] USER SUMMARY\nAll good.']) => (
      statusCode: 200,
      body: {'result': text},
      serverError: null,
      transportFailure: null,
    );

AiResult aiTransport(AiTransportFailure f) => (
      statusCode: null,
      body: null,
      serverError: null,
      transportFailure: f,
    );

class FakeBackend extends TabsBackend {
  List<QuickLogCategory> categories = const [];
  List<QuickLogEntry> entries = const [];

  FakeBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => categories;

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => entries;

  @override
  Future<List<BpRecord>> fetchManualBpLogs() async => const [];
}

class FakeHc extends HealthConnectService {
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
  Future<double?> readHrvRmssd(String dateStr) async => null;
  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];
}

QuickLogCategory cat(int id, String name) => QuickLogCategory(
    id: id,
    name: name,
    icon: 'x',
    colorHex: '#FF0000',
    isDefault: true,
    sortOrder: id);

QuickLogEntry entry(int id, int catId, int ts) => QuickLogEntry(
    id: id,
    categoryId: catId,
    body: 'b$id',
    chips: '',
    manualText: '',
    timestamp: ts);

FakeBackend backendWithData() => FakeBackend()
  ..categories = [cat(1, 'Symptoms')]
  ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];

const testId = '0123456789abcdef0123456789abcdef';

const testRequest = ReportRequestIdentity(
  kind: 'standard',
  focusKey: 'health',
  last30Days: true,
  categoryIds: [1],
);

/// Flushes the microtask queue so an unawaited trigger
/// (handleResumed / registerPagePresenter / useBackend) and any
/// delivery run it auto-drives can settle.
Future<void> flush() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// One service + one pipeline wired exactly as the page wires
/// them (providers → service, prefetched seam → service), over
/// scripted POST / leg-pickup / probe-pickup fakes.
class Harness {
  Harness(this.mem) {
    backend = backendWithData();
    svc = ReportGenerationService(
      journal: ReportGenerationJournal.inMemory(mem),
      pickupCall: (id) async {
        probeIds.add(id);
        return probeScript(++probeCalls);
      },
    );
    pipeline = ReportGenerationPipeline(
      collector: ReportDataCollector(backend: backend, hc: FakeHc()),
      backend: backend,
      aiCall: (body) async => aiScript(++aiCalls),
      pickupCall: (id) async {
        legPickupIds.add(id);
        return legPickupScript(++legPickupCalls);
      },
      delay: (_) async {},
      pickupPollInterval: const Duration(milliseconds: 1),
      pickupPollCap: const Duration(milliseconds: 500),
      reportGenerationIdProvider: () => svc.currentReportGenerationId,
      checkPickupFirstProvider: () => svc.currentCheckPickupFirst,
      pickupCheckIdProvider: () => svc.currentPickupCheckId,
      generationInvalidatedProvider: () =>
          svc.currentGenerationInvalidated,
      prefetchedNarrativeProvider: svc.takePrefetchedNarrative,
    );
  }

  final Map<String, String> mem;
  late final FakeBackend backend;
  late final ReportGenerationService svc;
  late final ReportGenerationPipeline pipeline;

  int aiCalls = 0;
  int legPickupCalls = 0;
  int probeCalls = 0;
  final List<String> legPickupIds = [];
  final List<String> probeIds = [];
  String? renderedSummary;

  ReportPickupOutcome Function(int call) probeScript =
      (_) => const PickupNotFound();
  ReportPickupOutcome Function(int call) legPickupScript =
      (_) => const PickupUnreachable();
  AiResult Function(int call) aiScript = (_) => aiOk();

  ReportGenerationRun get run =>
      ({required onStage, required isCancelled}) => pipeline.generate(
            selectedCategories: [cat(1, 'Symptoms')],
            last30Days: true,
            profile: const ReportProfileInput(),
            onStage: onStage,
            isCancelled: isCancelled,
            renderPdf: (snapshot, aiSummary,
                {required bool isRawFallback,
                RawReportBanner? rawBanner}) async {
              renderedSummary = aiSummary;
              return [1, 2, 3];
            },
            savePdf: (bytes, name) async => '/tmp/$name',
          );

  Future<void> start() => svc.start(run, request: testRequest);
}

/// Seeds the journal with a Case 2 decision record in the
/// founder's shape: connection-class attempts, a wire identity,
/// finished — the record a relaunch restores as a decision.
Future<void> seedDecisionRecord(
  Map<String, String> mem, {
  bool invalidated = false,
}) async {
  final journal = ReportGenerationJournal.inMemory(mem);
  await journal.write(ReportJournalEntry(
    generationId: '900-1',
    startedAtMs: 100,
    updatedAtMs: 100,
    finishedAtMs: 200,
    request: testRequest,
    outcomeKind: JournalOutcomeKind.decision,
    reportGenerationId: testId,
    generationInvalidated: invalidated,
    failureClassName: AiFailureClass.connection.name,
    attempts: [
      for (var i = 1; i <= 4; i++)
        AiAttemptRecord(
          attempt: i,
          failureClass: AiFailureClass.connection,
          httpStatus: null,
          succeeded: false,
          at: DateTime.fromMillisecondsSinceEpoch(1000 * i),
        ),
    ],
  ));
}

void main() {
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  group('FOUNDER SHAPE — restored decision (Case 2)', () {
    test('server holds READY → restore + backend bind probes '
        'exactly once, the auto-run delivers the held narrative, '
        'ZERO POSTs, ZERO leg pickups (stash consumed)', () async {
      final mem = <String, String>{};
      await seedDecisionRecord(mem);
      final h = Harness(mem);
      await h.svc.restoreSettled;
      expect(h.svc.restoredDecisionEntry, isNotNull,
          reason: 'Case 2 decision restored from the journal');
      h.probeScript = (_) => PickupReady('HELD NARRATIVE',
          completedAt: DateTime.fromMillisecondsSinceEpoch(4242000));

      // The relaunch trigger: the page binds its backend at
      // initState (progress_reports_page.dart useBackend call).
      h.svc.useBackend(h.backend);
      await flush();

      expect(h.probeCalls, 1, reason: 'exactly one probe');
      expect(h.probeIds, [testId]);
      // Ready on a restored decision converts it to the
      // interrupted entry the page's auto-restore starts from.
      expect(h.svc.restoredDecisionEntry, isNull);
      expect(h.svc.interruptedEntry?.reportGenerationId, testId);

      final ok = await h.svc.autoRestoreInterrupted(h.run);
      expect(ok, isTrue);
      expect(h.aiCalls, 0, reason: 'ZERO POST dispatches');
      expect(h.legPickupCalls, 0,
          reason: 'the leg consumed the stash, never re-fetched');
      expect(h.renderedSummary, 'HELD NARRATIVE');
      expect(h.svc.pendingShare, isNotNull);
      expect(h.svc.journalEntry?.outcomeKind, JournalOutcomeKind.ready);
      expect(h.svc.journalEntry?.heldCompletedAtMs, 4242000);
      expect(h.probeCalls, 1, reason: 'still exactly one probe');
    });

    test('Running restore → converted to interrupted; the '
        'auto-run polls the real endpoint to Ready, ZERO POSTs',
        () async {
      final mem = <String, String>{};
      await seedDecisionRecord(mem);
      final h = Harness(mem);
      await h.svc.restoreSettled;
      h.probeScript = (_) => const PickupRunning();
      var polls = 0;
      h.legPickupScript = (_) => ++polls == 1
          ? const PickupRunning()
          : const PickupReady('RUNNING THEN READY');

      await h.svc.reconcileDecisionPickup();
      expect(h.probeCalls, 1);
      expect(h.svc.restoredDecisionEntry, isNull);
      expect(h.svc.interruptedEntry?.reportGenerationId, testId);
      expect(h.svc.isGenerating, isFalse,
          reason: 'the probe itself never starts a run');

      final ok = await h.svc.autoRestoreInterrupted(h.run);
      expect(ok, isTrue);
      expect(polls, 2, reason: 'the run leg polled pickup');
      expect(h.aiCalls, 0);
      expect(h.renderedSummary, 'RUNNING THEN READY');
      expect(h.svc.pendingShare, isNotNull);
    });

    test('Expired restore → expired state journaled, decision '
        'surface cleared, ZERO POSTs, no run started', () async {
      final mem = <String, String>{};
      await seedDecisionRecord(mem);
      final h = Harness(mem);
      await h.svc.restoreSettled;
      h.probeScript = (_) => const PickupExpired();

      await h.svc.reconcileDecisionPickup();
      expect(h.probeCalls, 1);
      expect(h.svc.expiredEntry, isNotNull);
      expect(h.svc.expiredEntry?.outcomeKind,
          JournalOutcomeKind.expired);
      expect(h.svc.journalEntry?.outcomeKind,
          JournalOutcomeKind.expired);
      // The decision's recorded attempts survive on the record.
      expect(h.svc.expiredEntry?.attempts, hasLength(4));
      expect(h.svc.restoredDecisionEntry, isNull);
      expect(h.svc.interruptedEntry, isNull);
      expect(h.svc.pendingShare, isNull);
      expect(h.svc.isGenerating, isFalse);
      expect(h.aiCalls, 0);
    });

    test('registerPagePresenter is a trigger: entering Progress '
        'Reports probes a restored decision exactly once',
        () async {
      final mem = <String, String>{};
      await seedDecisionRecord(mem);
      final h = Harness(mem);
      await h.svc.restoreSettled;
      h.probeScript = (_) => const PickupReady('VIA PAGE ENTRY');

      h.svc.registerPagePresenter(() {});
      await flush();
      expect(h.probeCalls, 1);
      expect(h.svc.interruptedEntry?.reportGenerationId, testId);
      // The stash waits, keyed, for the auto-run's leg.
      expect(h.svc.takePrefetchedNarrative(testId)?.result,
          'VIA PAGE ENTRY');
    });
  });

  group('FOUNDER SHAPE — same-session held decision', () {
    /// Drives the founder's original leg: every POST dies on a
    /// dead transport (connection class), every leg pickup is
    /// unreachable from that same transport; the leg exhausts and
    /// the decision is held. Returns the held wire identity.
    Future<String> holdDecision(Harness h) async {
      h.aiScript =
          (_) => aiTransport(AiTransportFailure.noResponse);
      h.legPickupScript = (_) => const PickupUnreachable();
      await h.start();
      expect(h.svc.pendingFailure, isA<ReportAiDecision>());
      expect(h.aiCalls, 4,
          reason: 'the connection class exhausted its 4 attempts');
      final id = h.svc.journalEntry?.reportGenerationId;
      expect(id, isNotNull);
      return id!;
    }

    test('leg exhausts on dead transport → decision held → server '
        'flips READY → handleResumed auto-delivers the held '
        'narrative; ZERO additional POSTs, ZERO leg pickups',
        () async {
      final h = Harness(<String, String>{});
      final heldId = await holdDecision(h);
      final legPickupsAtDecision = h.legPickupCalls;
      expect(legPickupsAtDecision, greaterThan(0),
          reason: 'the leg DID check pickup before its retries — '
              'from the same dead transport');
      h.probeScript = (_) => PickupReady('HELD NARRATIVE',
          completedAt: DateTime.fromMillisecondsSinceEpoch(4242000));

      h.svc.handleResumed();
      await flush();

      expect(h.probeCalls, 1);
      expect(h.probeIds, [heldId]);
      expect(h.aiCalls, 4, reason: 'ZERO additional POSTs');
      expect(h.legPickupCalls, legPickupsAtDecision,
          reason: 'the resumed leg consumed the stash');
      expect(h.renderedSummary, 'HELD NARRATIVE');
      expect(h.svc.pendingFailure, isNull);
      expect(h.svc.pendingShare, isNotNull);
      expect(h.svc.journalEntry?.outcomeKind, JournalOutcomeKind.ready);
      expect(h.svc.journalEntry?.heldCompletedAtMs, 4242000);

      // Repeats are inert once the decision is delivered.
      h.svc.handleResumed();
      h.svc.registerPagePresenter(() {});
      await flush();
      expect(h.probeCalls, 1);
    });

    test('probe Running → the auto-driven resume leg polls the '
        'real endpoint to Ready; ZERO additional POSTs', () async {
      final h = Harness(<String, String>{});
      await holdDecision(h);
      h.probeScript = (_) => const PickupRunning();
      var polls = 0;
      h.legPickupScript = (_) => ++polls == 1
          ? const PickupRunning()
          : const PickupReady('POLLED READY');

      await h.svc.reconcileDecisionPickup();
      expect(h.probeCalls, 1);
      expect(polls, 2, reason: 'the resumed leg polled pickup');
      expect(h.aiCalls, 4, reason: 'ZERO additional POSTs');
      expect(h.renderedSummary, 'POLLED READY');
      expect(h.svc.pendingShare, isNotNull);
    });
  });

  group('genuine failure regression — probe changes NOTHING', () {
    for (final (name, outcome) in <(String, ReportPickupOutcome)>[
      ('Failed', const PickupFailed(500, error: 'generic')),
      ('NotFound', const PickupNotFound()),
      ('Unreachable', const PickupUnreachable()),
    ]) {
      test('restored decision + probe $name → decision surface '
          'unchanged, no run, no POST, and repeats never re-probe',
          () async {
        final mem = <String, String>{};
        await seedDecisionRecord(mem);
        final h = Harness(mem);
        await h.svc.restoreSettled;
        h.probeScript = (_) => outcome;

        await h.svc.reconcileDecisionPickup();
        expect(h.probeCalls, 1);
        expect(h.svc.restoredDecisionEntry, isNotNull);
        expect(h.svc.interruptedEntry, isNull);
        expect(h.svc.expiredEntry, isNull);
        expect(h.svc.pendingFailure, isNull);
        expect(h.svc.pendingShare, isNull);
        expect(h.svc.isGenerating, isFalse);
        expect(h.aiCalls, 0);

        // The once-per-decision guard: every later trigger is
        // inert for THIS decision record.
        await h.svc.reconcileDecisionPickup();
        h.svc.handleResumed();
        h.svc.registerPagePresenter(() {});
        h.svc.useBackend(h.backend);
        await flush();
        expect(h.probeCalls, 1);
        expect(h.svc.restoredDecisionEntry, isNotNull);
      });
    }

    test('a THROWING probe seam is Unreachable: no change',
        () async {
      final mem = <String, String>{};
      await seedDecisionRecord(mem);
      final h = Harness(mem);
      await h.svc.restoreSettled;
      h.probeScript = (_) => throw StateError('probe transport boom');

      await h.svc.reconcileDecisionPickup();
      expect(h.probeCalls, 1);
      expect(h.svc.restoredDecisionEntry, isNotNull);
      expect(h.svc.expiredEntry, isNull);
      expect(h.svc.interruptedEntry, isNull);
    });

    test('same-session decision + probe Failed → the decision '
        'presents exactly as today (still held, no run, no POST)',
        () async {
      final h = Harness(<String, String>{});
      h.aiScript =
          (_) => aiTransport(AiTransportFailure.noResponse);
      h.legPickupScript = (_) => const PickupUnreachable();
      await h.start();
      expect(h.svc.pendingFailure, isA<ReportAiDecision>());
      h.probeScript = (_) => const PickupFailed(500, error: 'generic');

      h.svc.handleResumed();
      await flush();
      expect(h.probeCalls, 1);
      expect(h.svc.pendingFailure, isA<ReportAiDecision>());
      expect(h.svc.pendingShare, isNull);
      expect(h.svc.isGenerating, isFalse);
      expect(h.aiCalls, 4, reason: 'no run was started');
    });
  });

  group('tombstone', () {
    test('an invalidated decision record → NO pickup ever, from '
        'any trigger', () async {
      final mem = <String, String>{};
      await seedDecisionRecord(mem, invalidated: true);
      final h = Harness(mem);
      await h.svc.restoreSettled;
      expect(h.svc.restoredDecisionEntry, isNotNull);
      h.probeScript = (_) => const PickupReady('SHOULD NOT BE READ');

      await h.svc.reconcileDecisionPickup();
      h.svc.handleResumed();
      h.svc.registerPagePresenter(() {});
      h.svc.useBackend(h.backend);
      await flush();
      expect(h.probeCalls, 0, reason: 'never probe a tombstone');
      expect(h.legPickupCalls, 0);
      expect(h.aiCalls, 0);
      expect(h.svc.restoredDecisionEntry, isNotNull,
          reason: 'the record itself is left untouched');
      expect(h.svc.takePrefetchedNarrative(testId), isNull);
    });
  });

  group('prefetched seam — service stash semantics', () {
    test('the stash is keyed by identity and consume-on-read',
        () async {
      final mem = <String, String>{};
      await seedDecisionRecord(mem);
      final h = Harness(mem);
      await h.svc.restoreSettled;
      h.probeScript = (_) => PickupReady('STASHED',
          completedAt: DateTime.fromMillisecondsSinceEpoch(99));

      await h.svc.reconcileDecisionPickup();
      expect(h.svc.takePrefetchedNarrative('some-other-id'), isNull,
          reason: 'a stash answers only its own identity — and a '
              'miss does not consume it');
      final hit = h.svc.takePrefetchedNarrative(testId);
      expect(hit?.result, 'STASHED');
      expect(hit?.completedAt,
          DateTime.fromMillisecondsSinceEpoch(99));
      expect(h.svc.takePrefetchedNarrative(testId), isNull,
          reason: 'consume-on-read: the second read is empty');
    });

    test('pipeline: a prefetched hit is handled exactly as '
        'PickupReady — no network pickup, no POST, completedAt '
        'carried to the outcome', () async {
      final backend = backendWithData();
      var providerCalls = 0;
      var pickupCalls = 0;
      var aiCalls = 0;
      final pipeline = ReportGenerationPipeline(
        collector: ReportDataCollector(backend: backend, hc: FakeHc()),
        backend: backend,
        aiCall: (body) async {
          aiCalls++;
          return aiOk();
        },
        pickupCall: (id) async {
          pickupCalls++;
          return const PickupNotFound();
        },
        delay: (_) async {},
        prefetchedNarrativeProvider: (id) {
          providerCalls++;
          return id == testId
              ? (
                  result: 'PREFETCHED',
                  completedAt: DateTime.fromMillisecondsSinceEpoch(31337),
                )
              : null;
        },
      );
      String? rendered;
      final outcome = await pipeline.generate(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        reportGenerationId: testId,
        checkPickupFirst: true,
        renderPdf: (snapshot, aiSummary,
            {required bool isRawFallback,
            RawReportBanner? rawBanner}) async {
          rendered = aiSummary;
          return [1, 2, 3];
        },
        savePdf: (bytes, name) async => '/tmp/$name',
      );
      expect(outcome, isA<ReportReady>());
      expect(rendered, 'PREFETCHED');
      expect((outcome as ReportReady).heldCompletedAtMs, 31337);
      expect(providerCalls, 1);
      expect(pickupCalls, 0);
      expect(aiCalls, 0);
    });
  });

  group('page presentation', () {
    testWidgets('a restored decision whose probe answers Expired '
        'presents Juno\'s signed expired state (verbatim) instead '
        'of the Case 2 decision surface', (tester) async {
      final mem = <String, String>{};
      await seedDecisionRecord(mem);
      final storeMem = <String, String>{};
      final h = Harness(mem);
      await h.svc.restoreSettled;
      expect(h.svc.restoredDecisionEntry, isNotNull);
      h.probeScript = (_) => const PickupExpired();
      final store = SettingsStore.withStorage(
        read: (k) async => storeMem[k],
        write: (k, v) async => storeMem[k] = v,
        delete: (k) async => storeMem.remove(k),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProgressReportsPage(
                  profileData: const SettingsProfileData(),
                  backend: h.backend,
                  store: store,
                  healthConnectService: FakeHc(),
                  generationService: h.svc,
                  savePdf: (bytes, name) async => '/tmp/$name',
                  sharePdf: (bytes, name) async {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(h.probeCalls, 1, reason: 'exactly one probe');
      expect(h.aiCalls, 0);
      // Juno R8-1 FINAL copy, verbatim.
      expect(find.text('Your earlier report is no longer saved'),
          findsOneWidget);
      expect(
          find.text(
              'Tabs finished that report and held it for 24 hours. That time has passed and the held copy has been deleted. You can make a new report from your data.'),
          findsOneWidget);
      expect(find.text('Make a new report'), findsOneWidget);
      // The Case 2 decision surface is gone.
      expect(find.text(restoredDecisionBodyCase2), findsNothing);
      expect(find.text(restoredDecisionAction), findsNothing);
    });
  });
}
