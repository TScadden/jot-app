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
