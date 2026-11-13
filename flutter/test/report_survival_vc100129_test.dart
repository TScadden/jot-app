// VC 100129 — report generation survival package tests.
//
// Covers: the generation journal (write/read/supersede/hygiene),
// the 10-cell process-death matrix (alive × 5 states behave as
// before; killed × 5 restore truthfully instead of collapsing
// to idle), orphan adoption (death after PDF save restores the
// ready outcome from the journaled artifact with ZERO
// regeneration), R-1 F2 (pre-dispatch classification), F3
// (correlation printer finite guard), F4 (collection deadline),
// the restored-decision Case 2 surface, and the notification
// tap on a fresh process.
//
// Harness discipline (per the investigation): real service,
// real journal store over an in-memory map (one map = one
// "device"; a second service over the same map is a relaunch),
// real classification loop where a surface is claimed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/report_generation_journal.dart';
import 'package:tabs_lab/src/data/report_generation_service.dart';
import 'package:tabs_lab/src/data/report_ready_notification.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Fakes ────────────────────────────────────────────────────────

class FakeNotifier implements ReportReadyNotifier {
  int shown = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> showReportReady() async {
    shown++;
    return true;
  }
}

class FakeBackend extends TabsBackend {
  List<QuickLogEntry> entries = const [];
  int aiCalls = 0;
  int collects = 0;

  FakeBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};
  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => const [];
  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async {
    collects++;
    return entries;
  }
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
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];
}

class ThrowingTokenStore extends FakeSessionStore {
  @override
  Future<String?> readToken() async =>
      throw StateError('secure storage unavailable');
}

QuickLogCategory cat(int id, String name) => QuickLogCategory(
    id: id, name: name, icon: 'x', colorHex: '#FF0000',
    isDefault: true, sortOrder: id);

QuickLogEntry entry(int id, int catId) => QuickLogEntry(
    id: id,
    categoryId: catId,
    body: 'b$id',
    chips: '',
    manualText: '',
    timestamp: DateTime.now().millisecondsSinceEpoch);

const testRequest = ReportRequestIdentity(
  kind: 'standard',
  focusKey: 'health',
  last30Days: false,
  categoryIds: [1, 5],
);

ReportSnapshot snap() => ReportSnapshot(
      last30Days: false,
      generationTimestampMs: DateTime.now().millisecondsSinceEpoch,
      logEntries: [entry(1, 1)],
      categoriesMap: const {1: 'Symptoms'},
    );

AiAttemptRecord attemptRec(int n, AiFailureClass cls, {int? status}) =>
    AiAttemptRecord(
      attempt: n,
      failureClass: cls,
      httpStatus: status,
      succeeded: false,
      at: DateTime(2026, 11, 13, 1, 37),
    );

/// A service over [mem] (the "device"), with in-memory artifact
/// seams backed by [files].
ReportGenerationService serviceOver(
  Map<String, String> mem, {
  Map<String, List<int>> files = const {},
  FakeNotifier? notifier,
  DateTime Function()? clock,
}) =>
    ReportGenerationService(
      notifier: notifier ?? FakeNotifier(),
      journal: ReportGenerationJournal.inMemory(mem),
      clock: clock,
      artifactExists: (p) async => files.containsKey(p),
      artifactReader: (p) async => files[p]!,
    );

ReportJournalEntry entryFor({
  required JournalOutcomeKind kind,
  String? stage,
  String? savedPath,
  String? fileName,
  List<AiAttemptRecord> attempts = const [],
  String? failureClassName,
}) =>
    ReportJournalEntry(
      generationId: 'g1',
      startedAtMs: DateTime(2026, 11, 13, 1, 30).millisecondsSinceEpoch,
      updatedAtMs: DateTime(2026, 11, 13, 1, 37).millisecondsSinceEpoch,
      finishedAtMs: kind == JournalOutcomeKind.running
          ? null
          : DateTime(2026, 11, 13, 1, 37).millisecondsSinceEpoch,
      request: testRequest,
      stage: stage,
      outcomeKind: kind,
      savedPath: savedPath,
      fileName: fileName,
      message: kind == JournalOutcomeKind.failed ? 'no connection' : null,
      aiFailureReason:
          kind == JournalOutcomeKind.failed ? 'no connection' : null,
      failureClassName: failureClassName,
      attempts: attempts,
    );

Future<void> seedJournal(
    Map<String, String> mem, ReportJournalEntry e) async {
  await ReportGenerationJournal.inMemory(mem).write(e);
  // Journal writes from the service are unawaited; the direct
  // store write above is awaited, so the seed is durable here.
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

  group('journal store', () {
    test('write/read round-trips identity, outcome and attempts',
        () async {
      final mem = <String, String>{};
      final store = ReportGenerationJournal.inMemory(mem);
      await store.write(entryFor(
        kind: JournalOutcomeKind.decision,
        failureClassName: 'connection',
        attempts: [attemptRec(1, AiFailureClass.connection)],
      ));
      final back = await store.read();
      expect(back, isNotNull);
      expect(back!.outcomeKind, JournalOutcomeKind.decision);
      expect(back.request.categoryIds, [1, 5]);
      expect(back.request.kind, 'standard');
      expect(back.attempts.single.failureClass, AiFailureClass.connection);
      expect(back.failureClass, AiFailureClass.connection);
    });

    test('supersede: a second write replaces the record whole',
        () async {
      final mem = <String, String>{};
      final store = ReportGenerationJournal.inMemory(mem);
      await store.write(entryFor(kind: JournalOutcomeKind.failed));
      await store.write(entryFor(
          kind: JournalOutcomeKind.ready,
          savedPath: '/docs/a.pdf',
          fileName: 'a.pdf'));
      final back = await store.read();
      expect(back!.outcomeKind, JournalOutcomeKind.ready);
      expect(back.savedPath, '/docs/a.pdf');
      expect(back.message, isNull);
    });

    test('hygiene: attempts are bounded at the journal cap',
        () async {
      final mem = <String, String>{};
      final store = ReportGenerationJournal.inMemory(mem);
      await store.write(entryFor(
        kind: JournalOutcomeKind.decision,
        attempts: [
          for (var i = 1; i <= 40; i++)
            attemptRec(i, AiFailureClass.connection),
        ],
      ));
      final back = await store.read();
      expect(back!.attempts.length,
          ReportGenerationJournal.maxJournaledAttempts);
      expect(back.attempts.first.attempt, 9); // most recent kept
      expect(back.attempts.last.attempt, 40);
    });

    test('corrupt blob reads as no journal', () async {
      final mem = <String, String>{
        ReportGenerationJournal.journalKey: '{not json',
      };
      expect(await ReportGenerationJournal.inMemory(mem).read(), isNull);
    });
  });

  group('10-cell matrix — process ALIVE (existing behavior)', () {
    test('alive × running: stage is live on the service', () async {
      final s = serviceOver(<String, String>{});
      await s.restoreSettled;
      final gate = Completer<void>();
      unawaited(s.start(
        ({required onStage, required isCancelled}) async {
          onStage(ReportStage.syncing);
          await gate.future;
          return const ReportFailed('Cancelled');
        },
        request: testRequest,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(s.isGenerating, isTrue);
      expect(s.stage, ReportStage.syncing);
      gate.complete();
    });

    test('alive × ready: outcome held as pendingShare', () async {
      final s = serviceOver(<String, String>{});
      await s.restoreSettled;
      await s.start(
        ({required onStage, required isCancelled}) async => ReportReady(
          snapshot: snap(),
          pdfBytes: const [1],
          fileName: 'r.pdf',
          savedPath: '/docs/r.pdf',
          isRawFallback: false,
        ),
        request: testRequest,
      );
      expect(s.pendingShare, isNotNull);
      expect(s.pendingShare!.savedPath, '/docs/r.pdf');
      expect(s.pendingFailure, isNull);
    });

    test('alive × failed: outcome held as pendingFailure', () async {
      final s = serviceOver(<String, String>{});
      await s.restoreSettled;
      await s.start(
        ({required onStage, required isCancelled}) async =>
            const ReportFailed('no connection',
                aiFailureReason: 'no connection'),
        request: testRequest,
      );
      expect(s.pendingFailure, isNotNull);
      expect(s.pendingFailure!.message, 'no connection');
    });

    test('alive × decision: held decision with resume intact',
        () async {
      final s = serviceOver(<String, String>{});
      await s.restoreSettled;
      await s.start(
        ({required onStage, required isCancelled}) async =>
            ReportAiDecision(
          failureReason: 'no connection',
          failureClass: AiFailureClass.connection,
          attempts: [attemptRec(1, AiFailureClass.connection)],
          snapshot: snap(),
          resume: (
                  {required retryAi,
                  required onStage,
                  required isCancelled}) async =>
              const ReportFailed('Cancelled'),
        ),
        request: testRequest,
      );
      expect(s.pendingFailure, isA<ReportAiDecision>());
      // A fresh decision carries NO framing line (R5-8 scope).
      expect(s.heldFramingLine, isNull);
    });

    test('alive × never started: idle, nothing held, no journal '
        'outcome', () async {
      final mem = <String, String>{};
      final s = serviceOver(mem);
      await s.restoreSettled;
      expect(s.isGenerating, isFalse);
      expect(s.pendingShare, isNull);
      expect(s.pendingFailure, isNull);
      expect(s.interruptedEntry, isNull);
      expect(s.restoredDecisionEntry, isNull);
    });
  });

  group('10-cell matrix — process KILLED (restore truthfully)', () {
    test('killed × running: interrupted state, NOT idle', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.running,
              stage: ReportStage.buildingSummary.name));
      final s = serviceOver(mem);
      await s.restoreSettled;
      expect(s.interruptedEntry, isNotNull);
      expect(s.interruptedEntry!.request.categoryIds, [1, 5]);
      expect(s.isGenerating, isFalse);
      expect(s.pendingShare, isNull);
      expect(s.pendingFailure, isNull);
    });

    test('killed × ready: restored from the exact artifact',
        () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.ready,
              savedPath: '/docs/exact.pdf',
              fileName: 'exact.pdf'));
      final s = serviceOver(mem, files: {
        '/docs/exact.pdf': [9, 8, 7],
      });
      await s.restoreSettled;
      expect(s.pendingShare, isNotNull);
      expect(s.pendingShare!.savedPath, '/docs/exact.pdf');
      expect(s.pendingShare!.pdfBytes, [9, 8, 7]);
      expect(s.outcomeRestored, isTrue);
      expect(s.interruptedEntry, isNull);
    });

    test('killed × ready with MISSING artifact: degrades to '
        'interrupted, never a dead ready', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.ready,
              savedPath: '/docs/gone.pdf',
              fileName: 'gone.pdf'));
      final s = serviceOver(mem); // no files: artifact missing
      await s.restoreSettled;
      expect(s.pendingShare, isNull);
      expect(s.interruptedEntry, isNotNull);
    });

    test('killed × failed: recorded failure re-presented WITH '
        'framing and journal attempt lines', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
            kind: JournalOutcomeKind.failed,
            failureClassName: 'connection',
            attempts: [
              attemptRec(1, AiFailureClass.connection),
              attemptRec(2, AiFailureClass.connection),
            ],
          ));
      final s = serviceOver(mem,
          clock: () => DateTime(2026, 11, 13, 9, 0));
      await s.restoreSettled;
      expect(s.pendingFailure, isNotNull);
      expect(s.pendingFailure!.message, 'no connection');
      expect(s.heldFramingLine, 'From your earlier attempt at 1:37 AM.');
      expect(s.displayAttemptLines, [
        'Attempt 1 · 1:37 AM · No connection',
        'Attempt 2 · 1:37 AM · No connection',
      ]);
    });

    test('killed × decision: Case 2 state — journal facts only, '
        'no resumable decision object', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
            kind: JournalOutcomeKind.decision,
            failureClassName: 'timeout',
            attempts: [attemptRec(1, AiFailureClass.timeout)],
          ));
      final s = serviceOver(mem,
          clock: () => DateTime(2026, 11, 14, 9, 0));
      await s.restoreSettled;
      expect(s.restoredDecisionEntry, isNotNull);
      expect(s.pendingFailure, isNull,
          reason: 'a restored decision must not masquerade as a '
              'same-session ReportAiDecision with a resume');
      expect(s.restoredDecisionFraming,
          'From your earlier attempt on Nov 13 at 1:37 AM.');
    });

    test('killed × never started: idle (identical to alive)', () async {
      final s = serviceOver(<String, String>{});
      await s.restoreSettled;
      expect(s.isGenerating, isFalse);
      expect(s.pendingShare, isNull);
      expect(s.pendingFailure, isNull);
      expect(s.interruptedEntry, isNull);
    });

    test('journal superseded on the next start()', () async {
      final mem = <String, String>{};
      await seedJournal(mem, entryFor(kind: JournalOutcomeKind.failed));
      final s = serviceOver(mem);
      await s.restoreSettled;
      expect(s.pendingFailure, isNotNull);
      await s.start(
        ({required onStage, required isCancelled}) async => ReportReady(
          snapshot: snap(),
          pdfBytes: const [1],
          fileName: 'new.pdf',
          savedPath: '/docs/new.pdf',
          isRawFallback: false,
        ),
        request: testRequest,
      );
      final stored = await ReportGenerationJournal.inMemory(mem).read();
      expect(stored!.outcomeKind, JournalOutcomeKind.ready);
      expect(stored.savedPath, '/docs/new.pdf');
    });
  });

  group('orphan adoption (death after PDF save)', () {
    test('ready restored from the journal artifact reference '
        'with zero regeneration after relaunch', () async {
      final mem = <String, String>{};
      final dir =
          Directory.systemTemp.createTempSync('vc100129_orphan');
      addTearDown(() => dir.deleteSync(recursive: true));
      var collects = 0, aiCalls = 0, renders = 0, saves = 0;

      final backend = FakeBackend()..entries = [entry(1, 1)];
      final s1 = serviceOver(mem);
      await s1.restoreSettled;
      final pipeline = ReportGenerationPipeline(
        collector: ReportDataCollector(
          backend: backend,
          hc: FakeHc(),
          documentsLoader: () async => const [],
          insightsLoader: () async => const [],
        ),
        backend: backend,
        aiCall: (body) async {
          aiCalls++;
          return (
            statusCode: 200,
            body: {'result': 'AI TEXT'},
            serverError: null,
            transportFailure: null,
          );
        },
        delay: (_) async {},
        onArtifactSaved: s1.noteArtifactSaved,
      );
      // Simulate death in the orphan window: the run saves the
      // PDF, then the Downloads step hangs forever — _finish
      // never runs, exactly like a kill after savePdf.
      final downloadsGate = Completer<bool>();
      unawaited(s1.start(
        ({required onStage, required isCancelled}) => pipeline.generate(
          selectedCategories: [cat(1, 'Symptoms')],
          last30Days: false,
          profile: const ReportProfileInput(),
          onStage: onStage,
          isCancelled: isCancelled,
          renderPdf: (snapshot, aiSummary,
              {required bool isRawFallback,
              RawReportBanner? rawBanner}) async {
            renders++;
            return [5, 5, 5];
          },
          savePdf: (bytes, name) async {
            saves++;
            final f = File('${dir.path}/$name');
            f.writeAsBytesSync(bytes, flush: true);
            return f.path;
          },
          saveToDownloads: (bytes, name) => downloadsGate.future,
        ),
        request: testRequest,
      ));
      // Wait until the save has landed and been journaled.
      for (var i = 0; i < 200 && saves == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(saves, 1);
      collects = backend.collects;
      final journaled =
          await ReportGenerationJournal.inMemory(mem).read();
      expect(journaled, isNotNull);
      expect(journaled!.outcomeKind, JournalOutcomeKind.running,
          reason: 'death struck before _finish finalized it');
      expect(journaled.savedPath, isNotNull,
          reason: 'the save hook journaled the artifact in-window');
      final savedPath = journaled.savedPath!;
      expect(savedPath, contains('Tabs_Report_'));
      expect(File(savedPath).existsSync(), isTrue);

      // RELAUNCH: a fresh service over the same store. The
      // journal entry is still 'running' but carries the
      // completed save's artifact reference — orphan adoption
      // restores the finished report from it.
      final files = {savedPath: File(savedPath).readAsBytesSync()};
      final s2 = ReportGenerationService(
        notifier: FakeNotifier(),
        journal: ReportGenerationJournal.inMemory(mem),
        artifactExists: (p) async => files.containsKey(p),
        artifactReader: (p) async => files[p]!,
      );
      await s2.restoreSettled;
      // The relaunch performs NO collection, NO AI call, NO
      // render, NO save — every counter stays where death left it.
      expect(backend.collects, collects);
      expect(aiCalls, 1);
      expect(renders, 1);
      expect(saves, 1);
      expect(s2.pendingShare, isNotNull);
      expect(s2.pendingShare!.savedPath, savedPath);
      expect(s2.pendingShare!.pdfBytes, [5, 5, 5]);
      expect(s2.interruptedEntry, isNull);
    });
  });

  group('R-1 F2 — pre-dispatch classification', () {
    test('classification: preDispatch is fatal, 1 attempt, never '
        'no connection', () {
      const f = AiFailure(preDispatch: true);
      expect(f.failureClass, AiFailureClass.preDispatch);
      expect(f.retryable, isFalse);
      expect(f.maxAttempts, 1);
      expect(f.plainReason, isNot('no connection'));
    });

    test('jsonEncode throw in postAiDetailed → preDispatch, '
        'zero requests dispatched', () async {
      var posts = 0;
      final store = FakeSessionStore()..token = 'tok';
      final backend = TabsBackend(
        client: MockClient((req) async {
          posts++;
          return http.Response('{}', 200);
        }),
        sessionStore: store,
      );
      final res = await backend.postAiDetailed('/api/ai/report', {
        'bad': double.nan, // jsonEncode throws on NaN
      });
      expect(posts, 0);
      expect(res.statusCode, isNull);
      expect(res.transportFailure, AiTransportFailure.preDispatch);
    });

    test('token-read throw → preDispatch, not unknown/fatal',
        () async {
      final backend = TabsBackend(
        client: MockClient((req) async => http.Response('{}', 200)),
        sessionStore: ThrowingTokenStore(),
      );
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      expect(res.transportFailure, AiTransportFailure.preDispatch);
    });

    test('pipeline: preDispatch exhausts as a fatal failure in '
        'exactly 1 attempt with its own class', () async {
      final backend = FakeBackend()..entries = [entry(1, 1)];
      var calls = 0;
      final pipeline = ReportGenerationPipeline(
        collector: ReportDataCollector(
          backend: backend,
          hc: FakeHc(),
          documentsLoader: () async => const [],
          insightsLoader: () async => const [],
        ),
        backend: backend,
        aiCall: (body) async {
          calls++;
          return (
            statusCode: null,
            body: null,
            serverError: null,
            transportFailure: AiTransportFailure.preDispatch,
          );
        },
        delay: (_) async {},
      );
      final outcome = await pipeline.generate(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        renderPdf: (s, summary,
                {required bool isRawFallback,
                RawReportBanner? rawBanner}) async =>
            [1],
        savePdf: (bytes, name) async => '/tmp/$name',
      );
      expect(calls, 1);
      expect(outcome, isNot(isA<ReportAiDecision>()));
      final f = outcome as ReportFailed;
      expect(f.aiAttempts.single.failureClass,
          AiFailureClass.preDispatch);
      expect(f.message, isNot('no connection'));
    });
  });

  group('R-1 F3 — correlation printer finite guard', () {
    InsightRecord rec(String family, double a, double b) => InsightRecord(
          familyId: family,
          splitId: family == 'F5' ? 'evt1' : 'split',
          windowKey: 'last90d',
          state: InsightState.numbers,
          groups: [
            InsightGroup(label: 'A days', n: 5, mean: a),
            InsightGroup(label: 'B days', n: 6, mean: b),
          ],
          headerLabel: 'Med X',
          subjectName: 'Med X',
          computedAtMs: 0,
          throughDate: '2026-11-01',
          inputFingerprint: 'x',
        );

    test('NaN and Infinity means are skipped like nulls through '
        'buildAiReportRequest (both printer branches)', () {
      final s = ReportSnapshot(
        last30Days: false,
        generationTimestampMs: 0,
        logEntries: [entry(1, 1)],
        categoriesMap: const {1: 'Symptoms'},
        correlationInsights: [
          rec('F1', double.nan, 70),
          rec('F1', 65, double.infinity),
          rec('F5', double.nan, 70),
          rec('F5', 65, double.negativeInfinity),
        ],
      );
      final body = buildAiReportRequest(s); // must not throw
      expect(body['correlation_insights'], isNull,
          reason: 'every non-finite record is skipped');
    });

    test('a finite record still prints alongside skipped ones',
        () {
      final s = ReportSnapshot(
        last30Days: false,
        generationTimestampMs: 0,
        logEntries: [entry(1, 1)],
        categoriesMap: const {1: 'Symptoms'},
        correlationInsights: [
          rec('F1', double.nan, 70),
          rec('F1', 65, 70),
        ],
      );
      final body = buildAiReportRequest(s);
      expect(body['correlation_insights'], isA<String>());
      expect(body['correlation_insights'] as String, contains('65'));
    });
  });

  group('R-1 F4 — collection deadline', () {
    test('a hung collection surfaces as ReportCollectionTimeout '
        'and the pipeline maps it to a named failure', () async {
      final backend = FakeBackend()..entries = [entry(1, 1)];
      final collector = ReportDataCollector(
        backend: backend,
        hc: FakeHc(),
        documentsLoader: () => Completer<List<String>>().future,
        insightsLoader: () async => const [],
        collectTimeout: const Duration(milliseconds: 60),
      );
      await expectLater(
        collector.collect(
          selectedCategories: [cat(1, 'Symptoms')],
          last30Days: true,
          profile: const ReportProfileInput(),
        ),
        throwsA(isA<ReportCollectionTimeout>()),
      );
      final pipeline = ReportGenerationPipeline(
        collector: collector,
        backend: backend,
        delay: (_) async {},
      );
      final outcome = await pipeline.generate(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        renderPdf: (s, summary,
                {required bool isRawFallback,
                RawReportBanner? rawBanner}) async =>
            [1],
        savePdf: (bytes, name) async => '/tmp/$name',
      );
      expect(outcome, isA<ReportFailed>());
      expect((outcome as ReportFailed).message,
          reportExportFailureMessage);
    });
  });

  group('F5 — held-decision freshness (same session)', () {
    test('a held decision gains the framing line once it is '
        're-encountered on resume', () async {
      final s = serviceOver(<String, String>{},
          clock: () => DateTime(2026, 11, 13, 1, 37));
      await s.restoreSettled;
      await s.start(
        ({required onStage, required isCancelled}) async =>
            ReportAiDecision(
          failureReason: 'no connection',
          failureClass: AiFailureClass.connection,
          attempts: [attemptRec(1, AiFailureClass.connection)],
          snapshot: snap(),
          resume: (
                  {required retryAi,
                  required onStage,
                  required isCancelled}) async =>
              const ReportFailed('Cancelled'),
        ),
        request: testRequest,
      );
      expect(s.heldFramingLine, isNull,
          reason: 'fresh decision from the just-run generation');
      s.handleResumed();
      expect(s.heldFramingLine, 'From your earlier attempt at 1:37 AM.');
    });
  });

  group('notification tap on a fresh process (f)', () {
    test('tap resolves to the restored ready outcome and the '
        'presenter opens the journaled artifact', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.ready,
              savedPath: '/docs/exact.pdf',
              fileName: 'exact.pdf'));
      var presented = 0;
      final s = serviceOver(mem, files: {
        '/docs/exact.pdf': [1, 2, 3],
      });
      s.registerRootPresenter(() => presented++);
      await s.restoreSettled;
      expect(s.pendingShare, isNotNull);
      s.handleNotificationTap();
      // The tap chains off the (already settled) restore future.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(presented, greaterThan(0));
      expect(s.pendingShare!.savedPath, '/docs/exact.pdf');
    });
  });

  group('restored-decision Case 2 surface (e)', () {
    testWidgets('page renders Case 2 body + single action; the '
        'same-session body/buttons are absent', (tester) async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
            kind: JournalOutcomeKind.decision,
            failureClassName: 'connection',
            attempts: [attemptRec(1, AiFailureClass.connection)],
          ));
      final storeMem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => storeMem[k],
        write: (k, v) async => storeMem[k] = v,
        delete: (k) async => storeMem.remove(k),
      );
      final backend = FakeBackend()..entries = [entry(1, 1)];
      final service = serviceOver(mem,
          clock: () => DateTime(2026, 11, 13, 9, 0));
      await service.restoreSettled;
      expect(service.restoredDecisionEntry, isNotNull);
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            ProgressReportsPage(
              profileData: const SettingsProfileData(),
              backend: backend,
              store: store,
              generationService: service,
              clinicianPremiumCheck: () async => false,
              savePdf: (bytes, name) async => '/tmp/$name',
              sharePdf: (bytes, name) async {},
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(aiDecisionTitle), findsOneWidget);
      expect(find.text('From your earlier attempt at 1:37 AM.'),
          findsOneWidget);
      expect(
          find.text(
              'Your data is safe. The AI analysis could not be completed on your earlier attempt. To try again, start a new report.'),
          findsOneWidget);
      expect(find.text('Start a new report'), findsOneWidget);
      // Same-session-only copy must NOT appear for a restore.
      expect(find.text(aiDecisionBody), findsNothing);
      expect(find.text(aiDecisionRetryLabel), findsNothing);
      expect(find.text(aiDecisionRawLabel), findsNothing);
    });
  });

  // Vera §9 Observation 1 (delta follow-on, test-only): her 4
  // probe tests covered three gaps this suite did not exercise
  // directly — autoRestoreInterrupted, the restore/single-flight
  // interaction, and the second-death case. The probes are landed
  // here as permanent shipped tests, split where one probe
  // bundled distinct guards so each guard fails on its own:
  // probe (b) "auto re-run once" → tests 1–3 (fresh run +
  // journaled outcome / second-call refusal / adoption
  // precedence); probe (c) "single-flight" → tests 4–6 (auto
  // refuses while a stage is live / restore landing after a
  // start cannot overwrite it / direct second start is a no-op);
  // probe (d) "second death" → test 7.
  group('auto re-run / single-flight / second death '
      '(Vera §9 probes, permanent)', () {
    test('1. autoRestoreInterrupted: fresh generation from the '
        'persisted identity, fresh outcome journaled', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.running,
              stage: ReportStage.buildingSummary.name));
      final s = serviceOver(mem);
      await s.restoreSettled;
      expect(s.interruptedEntry, isNotNull);
      expect(s.interruptedEntry!.generationId, 'g1');

      var runCalls = 0;
      bool? framingWhileRunning;
      bool? generatingWhileRunning;
      final started = await s.autoRestoreInterrupted(
        ({required onStage, required isCancelled}) async {
          runCalls++;
          // R5-9 state must be observable WHILE the re-run is
          // in flight, not just after it.
          framingWhileRunning = s.autoRunInFlight;
          generatingWhileRunning = s.isGenerating;
          onStage(ReportStage.syncing);
          return ReportReady(
            snapshot: snap(),
            pdfBytes: const [7],
            fileName: 'rerun.pdf',
            savedPath: '/docs/rerun.pdf',
            isRawFallback: false,
          );
        },
      );
      expect(started, isTrue);
      expect(runCalls, 1);
      expect(framingWhileRunning, isTrue);
      expect(generatingWhileRunning, isTrue);
      expect(s.autoRunInFlight, isFalse);
      expect(s.autoRestoreAttempted, isTrue);
      expect(s.interruptedEntry, isNull);
      expect(s.pendingShare, isNotNull);
      expect(s.pendingShare!.savedPath, '/docs/rerun.pdf');
      expect(s.pendingFailure, isNull);
      // The fresh outcome is journaled under the PERSISTED
      // identity (testRequest: standard/health, last30Days
      // false, categories [1, 5]) — a default identity here
      // (last30Days true, no categories) fails this test.
      final stored =
          await ReportGenerationJournal.inMemory(mem).read();
      expect(stored, isNotNull);
      expect(stored!.outcomeKind, JournalOutcomeKind.ready);
      expect(stored.generationId, isNot('g1'));
      expect(stored.savedPath, '/docs/rerun.pdf');
      expect(stored.fileName, 'rerun.pdf');
      expect(stored.finishedAtMs, isNotNull);
      expect(stored.request.kind, 'standard');
      expect(stored.request.focusKey, 'health');
      expect(stored.request.last30Days, isFalse);
      expect(stored.request.categoryIds, [1, 5]);
    });

    test('2. autoRestoreInterrupted: a second call — concurrent '
        'or after completion — runs nothing', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.running,
              stage: ReportStage.buildingSummary.name));
      final s = serviceOver(mem);
      await s.restoreSettled;
      expect(s.interruptedEntry, isNotNull);

      var firstCalls = 0, otherCalls = 0;
      Future<ReportOutcome> otherRun({
        required void Function(ReportStage stage) onStage,
        required bool Function() isCancelled,
      }) async {
        otherCalls++;
        return const ReportFailed('must never run');
      }
      final gate = Completer<void>();
      final first = s.autoRestoreInterrupted(
        ({required onStage, required isCancelled}) async {
          firstCalls++;
          onStage(ReportStage.syncing);
          await gate.future;
          return ReportReady(
            snapshot: snap(),
            pdfBytes: const [3],
            fileName: 'once.pdf',
            savedPath: '/docs/once.pdf',
            isRawFallback: false,
          );
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(firstCalls, 1);
      expect(s.autoRunInFlight, isTrue);
      // Concurrent second call: refused, runs nothing, and does
      // not disturb the in-flight auto re-run's framing state.
      expect(await s.autoRestoreInterrupted(otherRun), isFalse);
      expect(otherCalls, 0);
      expect(s.autoRunInFlight, isTrue);
      expect(s.isGenerating, isTrue);

      gate.complete();
      expect(await first, isTrue);
      expect(firstCalls, 1);
      expect(s.pendingShare!.savedPath, '/docs/once.pdf');
      // Post-completion call: still refused (the one auto
      // attempt for this process is spent and nothing is
      // interrupted), the held outcome is untouched.
      expect(await s.autoRestoreInterrupted(otherRun), isFalse);
      expect(otherCalls, 0);
      expect(s.pendingShare!.savedPath, '/docs/once.pdf');
    });

    test('3. adoption precedence: running + artifact restores '
        'as ready and autoRestoreInterrupted refuses without '
        'burning the attempt', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.running,
              stage: ReportStage.savingFile.name,
              savedPath: '/docs/orphan.pdf',
              fileName: 'orphan.pdf'));
      final s = serviceOver(mem, files: {
        '/docs/orphan.pdf': [4, 4, 4],
      });
      await s.restoreSettled;
      expect(s.pendingShare, isNotNull);
      expect(s.pendingShare!.savedPath, '/docs/orphan.pdf');
      expect(s.interruptedEntry, isNull,
          reason: 'adopted, not interrupted — nothing to re-run');

      var runCalls = 0;
      final started = await s.autoRestoreInterrupted(
        ({required onStage, required isCancelled}) async {
          runCalls++;
          return const ReportFailed('must never run');
        },
      );
      expect(started, isFalse);
      expect(runCalls, 0);
      // A refusal because nothing was interrupted must not
      // consume the process's one auto attempt.
      expect(s.autoRestoreAttempted, isFalse);
      expect(s.pendingShare!.savedPath, '/docs/orphan.pdf');
      expect(s.pendingShare!.pdfBytes, [4, 4, 4]);
      // And it must not supersede the journal record.
      final stored =
          await ReportGenerationJournal.inMemory(mem).read();
      expect(stored!.generationId, 'g1');
      expect(stored.outcomeKind, JournalOutcomeKind.running);
      expect(stored.savedPath, '/docs/orphan.pdf');
    });

    test('4. single-flight: autoRestoreInterrupted refuses '
        'while a generation is already in flight', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.running,
              stage: ReportStage.buildingSummary.name));
      final s = serviceOver(mem);
      await s.restoreSettled;
      expect(s.interruptedEntry, isNotNull);

      // A manual generation starts while the interrupted entry
      // is still on the service (start() itself does not clear
      // it — retryInterrupted does). That makes the auto path's
      // stage guard reachable, and this test pins it.
      final gate = Completer<void>();
      var manualCalls = 0;
      final manual = s.start(
        ({required onStage, required isCancelled}) async {
          manualCalls++;
          onStage(ReportStage.syncing);
          await gate.future;
          return ReportReady(
            snapshot: snap(),
            pdfBytes: const [1],
            fileName: 'manual.pdf',
            savedPath: '/docs/manual.pdf',
            isRawFallback: false,
          );
        },
        request: testRequest,
      );
      await Future<void>.delayed(Duration.zero);
      expect(manualCalls, 1);
      expect(s.isGenerating, isTrue);
      expect(s.interruptedEntry, isNotNull);
      final liveGeneration = s.journalEntry!.generationId;

      var autoCalls = 0;
      final started = await s.autoRestoreInterrupted(
        ({required onStage, required isCancelled}) async {
          autoCalls++;
          return const ReportFailed('must never run');
        },
      );
      expect(started, isFalse);
      expect(autoCalls, 0);
      // The refusal was the stage guard, not the attempt guard:
      // the one auto attempt is not burned by it.
      expect(s.autoRestoreAttempted, isFalse);
      expect(s.isGenerating, isTrue);
      expect(s.journalEntry!.generationId, liveGeneration);

      gate.complete();
      await manual;
      expect(s.pendingShare!.savedPath, '/docs/manual.pdf');
    });

    test('5. single-flight: a restore landing after a start '
        'cannot overwrite the live generation', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.running,
              stage: ReportStage.buildingSummary.name));
      const liveRequest = ReportRequestIdentity(
        kind: 'clinician',
        focusKey: 'clinician',
        last30Days: true,
        categoryIds: [9],
      );
      // No await between construction and start(): the restore
      // is still in flight (its journal read has not landed)
      // when the live generation begins — deterministically,
      // because Dart microtasks cannot interleave synchronous
      // code. The epoch / live-state guard in _restore() must
      // then keep the seeded record off the live generation.
      final s = serviceOver(mem);
      final gate = Completer<void>();
      var liveCalls = 0;
      final live = s.start(
        ({required onStage, required isCancelled}) async {
          liveCalls++;
          onStage(ReportStage.syncing);
          await gate.future;
          return ReportReady(
            snapshot: snap(),
            pdfBytes: const [2],
            fileName: 'live.pdf',
            savedPath: '/docs/live.pdf',
            isRawFallback: false,
          );
        },
        request: liveRequest,
      );
      await s.restoreSettled;
      expect(liveCalls, 1);
      expect(s.isGenerating, isTrue);
      expect(s.stage, ReportStage.syncing);
      expect(s.interruptedEntry, isNull,
          reason: 'the seeded running entry must not surface '
              'as interrupted over a live generation');
      expect(s.pendingShare, isNull);
      expect(s.pendingFailure, isNull);
      expect(s.journalEntry!.request.categoryIds, [9]);
      final stored =
          await ReportGenerationJournal.inMemory(mem).read();
      expect(stored!.outcomeKind, JournalOutcomeKind.running);
      expect(stored.request.kind, 'clinician');
      expect(stored.request.categoryIds, [9]);
      expect(stored.generationId, s.journalEntry!.generationId);

      gate.complete();
      await live;
      expect(s.pendingShare!.savedPath, '/docs/live.pdf');
    });

    test('6. single-flight: a second start() while one is in '
        'flight runs nothing and leaves the journal untouched',
        () async {
      final mem = <String, String>{};
      final s = serviceOver(mem);
      await s.restoreSettled;
      final gate = Completer<void>();
      var firstCalls = 0, secondCalls = 0;
      final first = s.start(
        ({required onStage, required isCancelled}) async {
          firstCalls++;
          onStage(ReportStage.syncing);
          await gate.future;
          return ReportReady(
            snapshot: snap(),
            pdfBytes: const [1],
            fileName: 'first.pdf',
            savedPath: '/docs/first.pdf',
            isRawFallback: false,
          );
        },
        request: testRequest,
      );
      await Future<void>.delayed(Duration.zero);
      expect(firstCalls, 1);
      expect(s.stage, ReportStage.syncing);
      final liveGeneration = s.journalEntry!.generationId;

      // Awaited directly: the second start returns without
      // invoking its run at all.
      await s.start(
        ({required onStage, required isCancelled}) async {
          secondCalls++;
          return const ReportFailed('must never run');
        },
        request: const ReportRequestIdentity(
          kind: 'clinician',
          focusKey: 'clinician',
          last30Days: true,
          categoryIds: [9],
        ),
      );
      expect(secondCalls, 0);
      expect(s.isGenerating, isTrue);
      expect(s.stage, ReportStage.syncing);
      expect(s.journalEntry!.generationId, liveGeneration);
      final stored =
          await ReportGenerationJournal.inMemory(mem).read();
      expect(stored!.generationId, liveGeneration);
      expect(stored.outcomeKind, JournalOutcomeKind.running);
      expect(stored.stage, ReportStage.syncing.name);
      expect(stored.request.categoryIds, [1, 5]);

      gate.complete();
      await first;
      expect(firstCalls, 1);
      expect(s.pendingShare!.savedPath, '/docs/first.pdf');
    });

    test('7. second death: death during the auto re-run leaves '
        'a single truthful running record the next relaunch '
        'restores as interrupted again', () async {
      final mem = <String, String>{};
      await seedJournal(
          mem,
          entryFor(
              kind: JournalOutcomeKind.running,
              stage: ReportStage.buildingSummary.name));
      final s2 = serviceOver(mem);
      await s2.restoreSettled;
      expect(s2.interruptedEntry, isNotNull);

      // The auto re-run starts, then the process "dies"
      // mid-flight: the run's gate never completes while we
      // inspect the journal and relaunch.
      final gate = Completer<void>();
      var rerunCalls = 0;
      final rerun = s2.autoRestoreInterrupted(
        ({required onStage, required isCancelled}) async {
          rerunCalls++;
          onStage(ReportStage.syncing);
          await gate.future;
          return const ReportFailed('Cancelled');
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(rerunCalls, 1);
      expect(s2.autoRunInFlight, isTrue);

      // Exactly one journal record, still valid, truthfully
      // 'running' for the NEW generation under the ORIGINAL
      // request identity — no phantom outcome, no corruption,
      // no artifact claimed.
      expect(mem.keys, [ReportGenerationJournal.journalKey]);
      expect(
          jsonDecode(mem[ReportGenerationJournal.journalKey]!),
          isA<Map<String, dynamic>>());
      final mid =
          await ReportGenerationJournal.inMemory(mem).read();
      expect(mid, isNotNull);
      expect(mid!.outcomeKind, JournalOutcomeKind.running);
      expect(mid.generationId, isNot('g1'));
      expect(mid.stage, ReportStage.syncing.name);
      expect(mid.savedPath, isNull);
      expect(mid.finishedAtMs, isNull);
      expect(mid.request.kind, 'standard');
      expect(mid.request.categoryIds, [1, 5]);
      expect(mid.request.last30Days, isFalse);
      final rerunGeneration = mid.generationId;

      // THIRD process over the same store: the re-run's death
      // restores as interrupted again, carrying the re-run's
      // generation id and the original identity.
      final s3 = serviceOver(mem);
      await s3.restoreSettled;
      expect(s3.interruptedEntry, isNotNull);
      expect(s3.interruptedEntry!.generationId, rerunGeneration);
      expect(s3.interruptedEntry!.request.categoryIds, [1, 5]);
      expect(s3.isGenerating, isFalse);
      expect(s3.pendingShare, isNull);
      expect(s3.pendingFailure, isNull);
      expect(s3.restoredDecisionEntry, isNull);

      // Settle the abandoned re-run so no future dangles: its
      // Cancelled finish clears the (already-asserted) record.
      gate.complete();
      expect(await rerun, isTrue);
    });
  });

  group('Juno string pins (rulings-5 verbatim)', () {
    test('interrupted / auto-run / details strings', () {
      expect(interruptedTitle, "Your report didn't finish");
      expect(
          interruptedBody,
          'Tabs stopped before this report finished. Your logged data is safe, and you can try the report again.');
      expect(interruptedRetryLabel, 'Try again');
      expect(autoRerunFraming, 'Starting your report again');
      expect(attemptDetailsLabel, 'Details');
      expect(
          attemptPlainLabel(AiFailureClass.preDispatch),
          'Could not start the request in the app');
      expect(attemptPlainLabel(AiFailureClass.connection),
          'No connection');
      expect(attemptPlainLabel(AiFailureClass.timeout),
          'Timed out waiting for a response');
      // HTTP status appears ONLY when one was received.
      expect(
          attemptDetailLine(
              attemptRec(3, AiFailureClass.server, status: 500)),
          'Attempt 3 · 1:37 AM · Server error · HTTP 500');
      expect(attemptDetailLine(attemptRec(3, AiFailureClass.server)),
          'Attempt 3 · 1:37 AM · Server error');
    });

    test('filename: unique per generation, prefix kept', () {
      final a = reportFileName(DateTime(2026, 11, 13, 1, 37, 0, 1));
      final b = reportFileName(DateTime(2026, 11, 13, 1, 37, 0, 2));
      expect(a, isNot(b));
      expect(a, startsWith('Tabs_Report_'));
      expect(a, endsWith('.pdf'));
    });

    test('earlier-day framing form', () {
      expect(
        earlierAttemptFraming(DateTime(2026, 11, 12, 23, 5),
            now: DateTime(2026, 11, 13, 9, 0)),
        'From your earlier attempt on Nov 12 at 11:05 PM.',
      );
      // json round-trip of a journal entry keeps the blob valid
      // JSON (no health content fields exist on the model).
      final encoded =
          ReportGenerationJournal.encode(entryFor(
              kind: JournalOutcomeKind.failed));
      expect(jsonDecode(encoded), isA<Map<String, dynamic>>());
    });
  });
}
