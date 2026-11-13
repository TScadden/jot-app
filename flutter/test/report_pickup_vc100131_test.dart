// VC 100131 (Round 3) — server-completion pickup, client half.
//
// Covers the Stage 2 build items:
// - wire identity: 128-bit secure mint, journal round-trip,
//   minted once per logical generation, REUSED across
//   resumeAiDecision and the interrupted rerun, NEW on a fresh
//   start; no-identity legacy behaviour when the mint fails
//   (Vera D1 — no weak fallback);
// - buildAiReportRequest carries reportGenerationId; clinician
//   generations carry the identity through the shared journal;
// - backend pickup mapping (HTTP status first, body status
//   second) + invalidate DELETE (fire-and-forget);
// - leg integration: pickup Ready after a connection failure
//   (exactly 1 POST), Running poll → Ready, stored Failed →
//   decision with the stored failure recorded, NotFound → POST,
//   Expired at restore → expired state with ZERO POSTs, cancel
//   tombstone → invalidate fired + a later restore attempts NO
//   pickup, pickup transport failure → POST proceeds;
// - Vera addenda: POST 202 {status:'running'} → pickup poll
//   (never recorded as an attempt failure); 409
//   generation_in_progress → existing AiFailure mapping, no
//   pickup poll; 429 generation_start_limit → rateLimited as
//   always; PickupReady.completedAt → journal heldCompletedAtMs.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

AiResult aiStatus(int code) => (
      statusCode: code,
      body: null,
      serverError: 'x',
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
  final List<String> invalidated = [];
  int pickupCalls = 0;

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

  @override
  Future<void> invalidateReportGeneration(String generationId) async {
    invalidated.add(generationId);
  }
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

/// A scripted pipeline + its call recorders.
class Script {
  int aiCalls = 0;
  int pickupCalls = 0;
  final List<Map<String, dynamic>> aiBodies = [];
  final List<String> pickupIds = [];
  late ReportGenerationPipeline pipeline;
}

Script scripted(
  FakeBackend backend, {
  required AiResult Function(int call) ai,
  ReportPickupOutcome Function(int call)? pickup,
  Duration pickupPollCap = const Duration(milliseconds: 500),
  bool Function()? generationInvalidated,
}) {
  final s = Script();
  s.pipeline = ReportGenerationPipeline(
    collector: ReportDataCollector(backend: backend, hc: FakeHc()),
    backend: backend,
    aiCall: (body) async {
      s.aiBodies.add(body);
      return ai(++s.aiCalls);
    },
    pickupCall: (id) async {
      s.pickupIds.add(id);
      return pickup!(++s.pickupCalls);
    },
    delay: (_) async {},
    pickupPollInterval: const Duration(milliseconds: 1),
    pickupPollCap: pickupPollCap,
    generationInvalidatedProvider: generationInvalidated,
  );
  return s;
}

Future<ReportOutcome> generate(
  ReportGenerationPipeline pipeline, {
  String? reportGenerationId,
  bool? checkPickupFirst,
  String? pickupCheckGenerationId,
  void Function(String? summary)? onRender,
}) {
  return pipeline.generate(
    selectedCategories: [cat(1, 'Symptoms')],
    last30Days: true,
    profile: const ReportProfileInput(),
    reportGenerationId: reportGenerationId,
    checkPickupFirst: checkPickupFirst,
    pickupCheckGenerationId: pickupCheckGenerationId,
    renderPdf: (snapshot, aiSummary,
        {required bool isRawFallback, RawReportBanner? rawBanner}) async {
      onRender?.call(aiSummary);
      return [1, 2, 3];
    },
    savePdf: (bytes, name) async => '/tmp/$name',
  );
}

const testId = '0123456789abcdef0123456789abcdef';

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


  group('identity mint + journal', () {
    test('mint is 128-bit lowercase hex (32 chars)', () {
      for (var i = 0; i < 20; i++) {
        final id = mintReportGenerationId();
        expect(id, isNotNull);
        expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      }
      // Two mints differ (collision is not a thing at 128 bits).
      expect(mintReportGenerationId(), isNot(mintReportGenerationId()));
    });

    test('journal round-trip preserves the Round 3 fields', () {
      final e = ReportJournalEntry(
        generationId: '1000-1',
        startedAtMs: 1000,
        updatedAtMs: 2000,
        finishedAtMs: 3000,
        request: const ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: true,
          categoryIds: [1],
        ),
        outcomeKind: JournalOutcomeKind.expired,
        reportGenerationId: testId,
        generationInvalidated: true,
        heldCompletedAtMs: 2500,
      );
      final back = ReportJournalEntry.fromJsonString(
          ReportGenerationJournal.encode(e));
      expect(back, isNotNull);
      expect(back!.reportGenerationId, testId);
      expect(back.generationInvalidated, isTrue);
      expect(back.heldCompletedAtMs, 2500);
      expect(back.outcomeKind, JournalOutcomeKind.expired);
    });

    test('pre-Round-3 records read tolerantly (no identity, no '
        'tombstone; unknown outcomeKind degrades to running)', () {
      final back = ReportJournalEntry.fromJsonString(jsonEncode({
        'v': 1,
        'generationId': '999-1',
        'startedAtMs': 1,
        'updatedAtMs': 2,
        'request': {
          'kind': 'standard',
          'focusKey': 'health',
          'last30Days': true,
          'categoryIds': <int>[],
          'forceRaw': false,
        },
        'outcomeKind': 'someFutureKind',
      }));
      expect(back, isNotNull);
      expect(back!.reportGenerationId, isNull);
      expect(back.generationInvalidated, isFalse);
      expect(back.heldCompletedAtMs, isNull);
      expect(back.outcomeKind, JournalOutcomeKind.running);
    });
  });

  group('request builder', () {
    ReportSnapshot snap() => ReportSnapshot(
          last30Days: true,
          generationTimestampMs: 1000,
          logEntries: [entry(1, 1, 1000)],
          categoriesMap: const {1: 'Symptoms'},
        );

    test('carries reportGenerationId when present; byte-legacy '
        'shape when absent', () {
      final withId =
          buildAiReportRequest(snap(), reportGenerationId: testId);
      expect(withId['reportGenerationId'], testId);
      final without = buildAiReportRequest(snap());
      expect(without.containsKey('reportGenerationId'), isFalse);
    });
  });

  group('backend pickup mapping + invalidate', () {
    TabsBackend backendWith(MockClient client) {
      final store = FakeSessionStore()..token = 'tok';
      return TabsBackend(client: client, sessionStore: store);
    }

    test('200 → PickupReady with completedAt; path is owner GET',
        () async {
      String? seenPath;
      String? seenMethod;
      final backend = backendWith(MockClient((req) async {
        seenPath = req.url.path;
        seenMethod = req.method;
        return http.Response(
            jsonEncode({
              'result': 'HELD NARRATIVE',
              'completedAt': '2026-11-13T19:00:00.000Z',
            }),
            200);
      }));
      final out = await backend.fetchReportPickup(testId);
      expect(out, isA<PickupReady>());
      final ready = out as PickupReady;
      expect(ready.result, 'HELD NARRATIVE');
      expect(ready.completedAt,
          DateTime.parse('2026-11-13T19:00:00.000Z'));
      expect(seenPath, '/api/ai/report/result/$testId');
      expect(seenMethod, 'GET');
    });

    test('202 → Running with hint; 404 → NotFound; 410 → Expired; '
        'stored failure status → PickupFailed', () async {
      Future<ReportPickupOutcome> one(int status, Object body) =>
          backendWith(MockClient(
                  (req) async => http.Response(jsonEncode(body), status)))
              .fetchReportPickup(testId);
      final running = await one(202, {'status': 'running', 'retryAfterMs': 5000});
      expect(running, isA<PickupRunning>());
      expect((running as PickupRunning).retryAfterMs, 5000);
      expect(await one(404, {'status': 'not_found', 'error': 'x'}),
          isA<PickupNotFound>());
      expect(await one(410, {'status': 'expired'}), isA<PickupExpired>());
      final failed = await one(502, {'error': 'generic'});
      expect(failed, isA<PickupFailed>());
      expect((failed as PickupFailed).httpStatus, 502);
    });

    test('pickup transport failure → PickupUnreachable, never a '
        'throw, never a generation failure', () async {
      final backend = backendWith(MockClient((req) async {
        throw http.ClientException('boom');
      }));
      expect(await backend.fetchReportPickup(testId),
          isA<PickupUnreachable>());
    });

    test('invalidate fires DELETE on the same URL and swallows '
        'transport errors', () async {
      String? seenPath;
      String? seenMethod;
      final backend = backendWith(MockClient((req) async {
        seenPath = req.url.path;
        seenMethod = req.method;
        return http.Response('{}', 200);
      }));
      await backend.invalidateReportGeneration(testId);
      expect(seenPath, '/api/ai/report/result/$testId');
      expect(seenMethod, 'DELETE');
      final throwing = backendWith(MockClient((req) async {
        throw http.ClientException('boom');
      }));
      await throwing.invalidateReportGeneration(testId); // no throw
    });
  });

  group('leg pickup integration', () {
    test('POST connection failure, then pickup Ready → ReportReady '
        'with exactly 1 POST; completedAt journaled on the outcome',
        () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiTransport(AiTransportFailure.noResponse),
        pickup: (n) => PickupReady('PICKED UP NARRATIVE',
            completedAt: DateTime.fromMillisecondsSinceEpoch(4242)),
      );
      String? rendered;
      final outcome = await generate(
        s.pipeline,
        reportGenerationId: testId,
        onRender: (summary) => rendered = summary,
      );
      expect(outcome, isA<ReportReady>());
      expect(s.aiCalls, 1); // exactly one POST was ever dispatched
      expect(s.pickupCalls, 1);
      expect(s.pickupIds, [testId]);
      expect(rendered, 'PICKED UP NARRATIVE');
      final ready = outcome as ReportReady;
      expect(ready.heldCompletedAtMs, 4242);
      expect(s.aiBodies.single['reportGenerationId'], testId);
      // Attempt history: 1 = connection failure, 2 = pickup success.
      expect(ready.aiAttempts, hasLength(2));
      expect(ready.aiAttempts.first.failureClass,
          AiFailureClass.connection);
      expect(ready.aiAttempts.last.succeeded, isTrue);
      expect(ready.aiAttempts.last.attempt, 2);
    });

    test('pickup Running → poll → Ready (restore head check, '
        'ZERO POSTs)', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiOk(),
        pickup: (n) => n < 3
            ? const PickupRunning(retryAfterMs: 5000)
            : const PickupReady('POLLED READY'),
      );
      final outcome = await generate(s.pipeline,
          reportGenerationId: testId, checkPickupFirst: true);
      expect(outcome, isA<ReportReady>());
      expect(s.aiCalls, 0);
      expect(s.pickupCalls, 3);
    });

    test('pickup Failed → recorded through the AiFailure mapping; '
        'the leg ends in a decision whose FIRST recorded outcome '
        'is the stored failure', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiStatus(500),
        pickup: (n) => const PickupFailed(500, error: 'generic'),
      );
      final outcome = await generate(s.pipeline,
          reportGenerationId: testId, checkPickupFirst: true);
      expect(outcome, isA<ReportAiDecision>());
      final d = outcome as ReportAiDecision;
      expect(d.failureClass, AiFailureClass.server);
      expect(d.aiAttempts.first.httpStatus, 500);
      expect(d.aiAttempts.first.failureClass, AiFailureClass.server);
      // Stored failure (attempt 1) + one POST (attempt 2) exhaust
      // the server class's 2 attempts.
      expect(d.aiAttempts, hasLength(2));
      expect(s.aiCalls, 1);
    });

    test('pickup NotFound → POST proceeds normally', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiOk(),
        pickup: (n) => const PickupNotFound(),
      );
      final outcome = await generate(s.pipeline,
          reportGenerationId: testId, checkPickupFirst: true);
      expect(outcome, isA<ReportReady>());
      expect(s.aiCalls, 1);
      expect(s.pickupCalls, 1);
    });

    test('pickup Expired at restore → expired outcome, ZERO POSTs',
        () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiOk(),
        pickup: (n) => const PickupExpired(),
      );
      final outcome = await generate(s.pipeline,
          reportGenerationId: testId, checkPickupFirst: true);
      expect(outcome, isA<ReportGenerationExpired>());
      expect(s.aiCalls, 0);
    });

    test('pickup transport failure (throwing seam) → POST proceeds, '
        'no new failure mode', () async {
      final backend = backendWithData();
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
          throw StateError('pickup transport boom');
        },
        delay: (_) async {},
      );
      final outcome = await generate(pipeline,
          reportGenerationId: testId, checkPickupFirst: true);
      expect(outcome, isA<ReportReady>());
      expect(aiCalls, 1);
      expect(pickupCalls, 1);
    });

    test('pickup still Running at the poll cap → falls through to '
        'a POST dispatch', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiOk(),
        pickup: (n) => const PickupRunning(),
        pickupPollCap: const Duration(milliseconds: 3),
      );
      final outcome = await generate(s.pipeline,
          reportGenerationId: testId, checkPickupFirst: true);
      expect(outcome, isA<ReportReady>());
      expect(s.aiCalls, 1);
      expect(s.pickupCalls, greaterThan(1)); // it really polled
    });

    test('a fresh start NEVER checks pickup', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiOk(),
        pickup: (n) => const PickupReady('SHOULD NOT BE READ'),
      );
      String? rendered;
      final outcome = await generate(s.pipeline,
          reportGenerationId: testId, onRender: (x) => rendered = x);
      expect(outcome, isA<ReportReady>());
      expect(s.pickupCalls, 0);
      expect(rendered, isNot('SHOULD NOT BE READ'));
    });

    test('tombstone guard: NO pickup is attempted for a cancelled '
        'identity at any call site', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiOk(),
        pickup: (n) => const PickupReady('SHOULD NOT BE READ'),
        generationInvalidated: () => true,
      );
      final outcome = await generate(s.pipeline,
          reportGenerationId: testId, checkPickupFirst: true);
      expect(outcome, isA<ReportReady>());
      expect(s.pickupCalls, 0);
      expect(s.aiCalls, 1);
    });
  });

  group('Vera addenda — POST 202 / 409 / 429', () {
    test('POST 202 running → pickup poll → Ready; the 202 is '
        'never recorded as an attempt', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => (
          statusCode: 202,
          body: {'status': 'running', 'retryAfterMs': 5000},
          serverError: null,
          transportFailure: null,
        ),
        pickup: (n) => const PickupReady('WAITER RESULT'),
      );
      final outcome =
          await generate(s.pipeline, reportGenerationId: testId);
      expect(outcome, isA<ReportReady>());
      expect(s.aiCalls, 1);
      final ready = outcome as ReportReady;
      // Only ONE attempt record exists: the pickup success. The
      // 202 recorded nothing — no failure, no attempt burn.
      expect(ready.aiAttempts, hasLength(1));
      expect(ready.aiAttempts.single.succeeded, isTrue);
    });

    test('POST 202 → poll cap → falls back to a fresh POST', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => n == 1
            ? (
                statusCode: 202,
                body: {'status': 'running'},
                serverError: null,
                transportFailure: null,
              )
            : aiOk('SECOND POST RESULT'),
        pickup: (n) => const PickupRunning(),
        pickupPollCap: const Duration(milliseconds: 3),
      );
      String? rendered;
      final outcome = await generate(s.pipeline,
          reportGenerationId: testId, onRender: (x) => rendered = x);
      expect(outcome, isA<ReportReady>());
      expect(s.aiCalls, 2);
      expect(rendered, 'SECOND POST RESULT');
    });

    test('409 generation_in_progress → existing mapping '
        '(fatalRequest, true 409), exactly 1 attempt, NO pickup '
        'poll (this identity has no row)', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiStatus(409),
        pickup: (n) => const PickupReady('SHOULD NOT BE READ'),
      );
      final outcome =
          await generate(s.pipeline, reportGenerationId: testId);
      expect(outcome, isA<ReportFailed>());
      expect(outcome, isNot(isA<ReportAiDecision>()));
      final f = outcome as ReportFailed;
      expect(f.aiAttempts, hasLength(1));
      expect(f.aiAttempts.single.httpStatus, 409);
      expect(f.aiAttempts.single.failureClass,
          AiFailureClass.fatalRequest);
      expect(s.pickupCalls, 0);
    });

    test('429 generation_start_limit → rateLimited exactly as the '
        'existing class treats 429 (2 attempts, decision)', () async {
      final s = scripted(
        backendWithData(),
        ai: (n) => aiStatus(429),
        pickup: (n) => const PickupNotFound(),
      );
      final outcome =
          await generate(s.pipeline, reportGenerationId: testId);
      expect(outcome, isA<ReportAiDecision>());
      final d = outcome as ReportAiDecision;
      expect(d.failureClass, AiFailureClass.rateLimited);
      expect(d.aiAttempts, hasLength(2));
      expect(
          d.aiAttempts.every((a) => a.httpStatus == 429), isTrue);
    });
  });

  group('service — minting rule, resume/restore reuse, expired, '
      'cancel', () {
    ReportGenerationService serviceOver(
      Map<String, String> mem, {
      FakeBackend? backend,
      String? Function()? mint,
    }) {
      final svc = ReportGenerationService(
        journal: ReportGenerationJournal.inMemory(mem),
        reportGenerationIdMint: mint,
      );
      if (backend != null) svc.useBackend(backend);
      return svc;
    }

    Future<void> runFailed(ReportGenerationService svc,
        {String kind = 'standard'}) {
      return svc.start(
        ({required onStage, required isCancelled}) async =>
            const ReportFailed('boom'),
        request: ReportRequestIdentity(
          kind: kind,
          focusKey: 'health',
          last30Days: true,
          categoryIds: const [1],
        ),
      );
    }

    test('fresh starts mint a NEW identity each time; the journal '
        'record carries it', () async {
      final mem = <String, String>{};
      final svc = serviceOver(mem);
      await runFailed(svc);
      final first = svc.journalEntry?.reportGenerationId;
      expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
      await runFailed(svc);
      final second = svc.journalEntry?.reportGenerationId;
      expect(second, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(second, isNot(first));
    });

    test('clinician generations carry the identity through the '
        'same journal (kind clinician)', () async {
      final mem = <String, String>{};
      final svc = serviceOver(mem);
      await runFailed(svc, kind: 'clinician');
      expect(svc.journalEntry?.request.kind, 'clinician');
      expect(svc.journalEntry?.reportGenerationId,
          matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('mint failure → NO identity (legacy behaviour), never a '
        'weak ID (Vera D1)', () async {
      final mem = <String, String>{};
      final svc = serviceOver(mem, mint: () => null);
      await runFailed(svc);
      expect(svc.journalEntry?.reportGenerationId, isNull);
      expect(svc.currentReportGenerationId, isNull);
    });

    test('interrupted auto-rerun REUSES the persisted identity',
        () async {
      final mem = <String, String>{};
      final journal = ReportGenerationJournal.inMemory(mem);
      await journal.write(const ReportJournalEntry(
        generationId: '111-1',
        startedAtMs: 100,
        updatedAtMs: 100,
        request: ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: true,
          categoryIds: [1],
        ),
        stage: 'collecting',
        outcomeKind: JournalOutcomeKind.running,
        reportGenerationId: testId,
      ));
      final svc = ReportGenerationService(journal: journal);
      await svc.restoreSettled;
      expect(svc.interruptedEntry?.reportGenerationId, testId);
      final ok = await svc.autoRestoreInterrupted(
        ({required onStage, required isCancelled}) async =>
            const ReportFailed('boom'),
      );
      expect(ok, isTrue);
      expect(svc.journalEntry?.reportGenerationId, testId);
    });

    test('resumeAiDecision REUSES the identity and the resumed leg '
        'collects the held narrative by pickup (no POST)', () async {
      final backend = backendWithData();
      final svc = serviceOver(<String, String>{});
      // During the ORIGINAL leg the server has nothing held
      // (NotFound — its POSTs all died client-side); only after
      // the decision is held does the detached generation land
      // and the resume's pickup find it Ready.
      var heldServerSide = false;
      final s = scripted(
        backend,
        ai: (n) => aiTransport(AiTransportFailure.noResponse),
        pickup: (n) => heldServerSide
            ? const PickupReady('RESUMED BY PICKUP')
            : const PickupNotFound(),
      );
      // Wire the pipeline's providers to the service exactly as
      // the page does.
      final pipeline = ReportGenerationPipeline(
        collector: ReportDataCollector(backend: backend, hc: FakeHc()),
        backend: backend,
        aiCall: s.pipeline.aiCall,
        pickupCall: s.pipeline.pickupCall,
        delay: (_) async {},
        pickupPollInterval: const Duration(milliseconds: 1),
        pickupPollCap: const Duration(milliseconds: 500),
        reportGenerationIdProvider: () => svc.currentReportGenerationId,
        checkPickupFirstProvider: () => svc.currentCheckPickupFirst,
        pickupCheckIdProvider: () => svc.currentPickupCheckId,
        generationInvalidatedProvider: () =>
            svc.currentGenerationInvalidated,
      );
      await svc.start(
        ({required onStage, required isCancelled}) => pipeline.generate(
          selectedCategories: [cat(1, 'Symptoms')],
          last30Days: true,
          profile: const ReportProfileInput(),
          onStage: onStage,
          isCancelled: isCancelled,
          renderPdf: (snapshot, aiSummary,
                  {required bool isRawFallback,
                  RawReportBanner? rawBanner}) async =>
              [1, 2, 3],
          savePdf: (bytes, name) async => '/tmp/$name',
        ),
        request: const ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: true,
          categoryIds: [1],
        ),
      );
      expect(svc.pendingFailure, isA<ReportAiDecision>());
      final heldId = svc.journalEntry?.reportGenerationId;
      expect(heldId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(s.aiCalls, 4); // the original leg exhausted

      heldServerSide = true;
      await svc.resumeAiDecision(retryAi: true);
      expect(svc.pendingShare, isNotNull);
      expect(svc.journalEntry?.reportGenerationId, heldId);
      // Every pickup in both legs was keyed by the SAME identity.
      expect(s.pickupIds, isNotEmpty);
      expect(s.pickupIds.every((id) => id == heldId), isTrue);
      expect(s.aiCalls, 4); // the resume dispatched ZERO new POSTs
    });

    test('expired outcome → service holds the expired state, '
        'journaled expired, and a relaunch restores it', () async {
      final mem = <String, String>{};
      final svc = serviceOver(mem);
      await svc.start(
        ({required onStage, required isCancelled}) async =>
            const ReportGenerationExpired(),
        request: const ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: true,
          categoryIds: [1],
        ),
      );
      expect(svc.expiredEntry, isNotNull);
      expect(svc.pendingFailure, isNull);
      expect(svc.journalEntry?.outcomeKind, JournalOutcomeKind.expired);

      final svc2 = serviceOver(mem);
      await svc2.restoreSettled;
      expect(svc2.expiredEntry, isNotNull);
      expect(svc2.expiredEntry?.outcomeKind,
          JournalOutcomeKind.expired);
    });

    test('pickup completion records heldCompletedAtMs on the '
        'terminal journal record (recorded, not displayed)',
        () async {
      final mem = <String, String>{};
      final svc = serviceOver(mem);
      await svc.start(
        ({required onStage, required isCancelled}) async => ReportReady(
          snapshot: ReportSnapshot(
            last30Days: true,
            generationTimestampMs: 1000,
            logEntries: [entry(1, 1, 1000)],
            categoriesMap: const {1: 'Symptoms'},
          ),
          pdfBytes: const [1],
          fileName: 'f.pdf',
          savedPath: '/tmp/f.pdf',
          isRawFallback: false,
          heldCompletedAtMs: 777000,
        ),
        request: const ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: true,
          categoryIds: [1],
        ),
      );
      expect(svc.journalEntry?.heldCompletedAtMs, 777000);
    });

    test('cancel → tombstone persisted on the tap + invalidate '
        'fired with the generation identity', () async {
      final mem = <String, String>{};
      final backend = FakeBackend();
      final svc = serviceOver(mem, backend: backend);
      final gate = Completer<ReportOutcome>();
      final started = svc.start(
        ({required onStage, required isCancelled}) => gate.future,
        request: const ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: true,
          categoryIds: [1],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(svc.isGenerating, isTrue);
      final id = svc.journalEntry?.reportGenerationId;
      expect(id, isNotNull);
      svc.requestCancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Tombstone is in the persisted journal blob itself.
      final blob = ReportJournalEntry.fromJsonString(
          mem[ReportGenerationJournal.journalKey]);
      expect(blob?.generationInvalidated, isTrue);
      expect(backend.invalidated, [id]);
      gate.complete(const ReportFailed('Cancelled'));
      await started;
    });

    test('a tombstoned running record never resurrects on restore '
        '(no interrupted surface, no pickup surface)', () async {
      final mem = <String, String>{};
      final journal = ReportGenerationJournal.inMemory(mem);
      await journal.write(const ReportJournalEntry(
        generationId: '222-1',
        startedAtMs: 100,
        updatedAtMs: 100,
        request: ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: true,
          categoryIds: [1],
        ),
        stage: 'buildingSummary',
        outcomeKind: JournalOutcomeKind.running,
        reportGenerationId: testId,
        generationInvalidated: true,
      ));
      final svc = ReportGenerationService(journal: journal);
      await svc.restoreSettled;
      expect(svc.interruptedEntry, isNull);
      expect(svc.expiredEntry, isNull);
      expect(mem.containsKey(ReportGenerationJournal.journalKey),
          isFalse);
    });
  });

  group('page presentation', () {
    testWidgets('an expired journal record presents Juno\'s signed '
        'expired state on the Progress Reports page', (tester) async {
      final mem = <String, String>{};
      final journal = ReportGenerationJournal.inMemory(mem);
      await journal.write(const ReportJournalEntry(
        generationId: '333-1',
        startedAtMs: 100,
        updatedAtMs: 100,
        finishedAtMs: 200,
        request: ReportRequestIdentity(
          kind: 'standard',
          focusKey: 'health',
          last30Days: true,
          categoryIds: [1],
        ),
        outcomeKind: JournalOutcomeKind.expired,
        reportGenerationId: testId,
      ));
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final backend = backendWithData();
      final svc = ReportGenerationService(journal: journal);
      await svc.restoreSettled;
      expect(svc.expiredEntry, isNotNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProgressReportsPage(
                  profileData: const SettingsProfileData(),
                  backend: backend,
                  store: store,
                  healthConnectService: FakeHc(),
                  generationService: svc,
                  savePdf: (bytes, name) async => '/tmp/$name',
                  sharePdf: (bytes, name) async {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Juno R8-1 FINAL copy, verbatim.
      expect(find.text('Your earlier report is no longer saved'),
          findsOneWidget);
      expect(
          find.text(
              'Tabs finished that report and held it for 24 hours. That time has passed and the held copy has been deleted. You can make a new report from your data.'),
          findsOneWidget);
      expect(find.text('Make a new report'), findsOneWidget);
    });
  });
}
