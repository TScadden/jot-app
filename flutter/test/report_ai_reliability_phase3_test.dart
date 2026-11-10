// Report Generation Reliability Phase 3 — AI-leg reliability
// fixtures (the merge gate).
//
// Every failure class gets a fixture proving ATTEMPT COUNTS and
// outcomes, per the Phase 3 brief:
// (a) 200-no-result retries as the server class;
// (b) 429 retries;
// (c) noSession stops at exactly 1 attempt;
// (d) stale-token 401 → refresh → retry, and post-refresh 401 →
//     session failure, never "no connection";
// (e) client timeout is its own retryable class, attempt recorded;
// (f) exhaustion of a retryable class → the generation HOLDS
//     (no PDF, no notification), decision UI with Juno's exact
//     strings;
// (g) explicit ship-raw choice → raw PDF with the CHOICE banner,
//     the failure banner absent;
// (h) retry-from-hold success → full AI report, attempt history
//     shows the failed attempts plus the successful retry;
// (i) single-flight — a hanging first attempt blocks any second
//     request until it settles.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/report_generation_service.dart';
import 'package:tabs_lab/src/data/report_ready_notification.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'test_helpers.dart';

// ── Fakes (mirrors of the R66 fakes, kept local to this file) ────

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
  int entryFetches = 0;

  FakeBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => categories;

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async {
    entryFetches++;
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
  Future<double?> readHrvRmssd(String dateStr) async => null;
  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];
}

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

QuickLogCategory cat(int id, String name) => QuickLogCategory(
    id: id,
    name: name,
    icon: 'x',
    colorHex: '#FF0000',
    isDefault: true,
    sortOrder: id);

QuickLogEntry entry(int id, int catId, int ts) => QuickLogEntry(
    id: id, categoryId: catId, body: 'b$id', chips: '', manualText: '', timestamp: ts);

/// Extracts the text a generated PDF actually prints: inflate
/// every stream, collect the `(word)` operands of the TJ text
/// operators in order, and join them back into lines of text.
String pdfText(List<int> bytes) {
  final raw = latin1.decode(bytes, allowInvalid: true);
  final inflated = StringBuffer();
  var idx = 0;
  while (true) {
    final s = raw.indexOf('stream', idx);
    if (s < 0) break;
    final e = raw.indexOf('endstream', s);
    if (e < 0) break;
    var start = s + 6;
    if (start < bytes.length && raw[start] == '\r') start++;
    if (start < bytes.length && raw[start] == '\n') start++;
    try {
      inflated.write(
          latin1.decode(ZLibDecoder().convert(bytes.sublist(start, e)),
              allowInvalid: true));
    } catch (_) {
      // Not a compressed stream (fonts/images) — not text.
    }
    idx = e + 9;
  }
  final words = RegExp(r'\((?:[^()\\]|\\.)*\)')
      .allMatches(inflated.toString())
      .map((m) {
    final inner = m.group(0)!;
    return inner.substring(1, inner.length - 1).replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')')
        .replaceAll(r'\\', r'\');
  });
  return words.join(' ');
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

  FakeBackend backendWithData() => FakeBackend()
    ..categories = [cat(1, 'Symptoms')]
    ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];

  /// A pipeline over the fakes with a scripted AI call and render
  /// capture. [script] is consulted per call (1-based).
  ReportGenerationPipeline pipelineFor(
    FakeBackend backend, {
    required AiResult Function(int call) script,
    Duration? attemptTimeout,
  }) {
    var calls = 0;
    return ReportGenerationPipeline(
      collector: ReportDataCollector(backend: backend, hc: FakeHc()),
      backend: backend,
      aiCall: (body) async => script(++calls),
      delay: (_) async {},
      attemptTimeout: attemptTimeout,
    );
  }

  Future<ReportOutcome> generate(
    ReportGenerationPipeline pipeline, {
    void Function(String? summary, bool raw, RawReportBanner? banner)?
        onRender,
    bool realPdf = false,
  }) {
    return pipeline.generate(
      selectedCategories: [cat(1, 'Symptoms')],
      last30Days: true,
      profile: const ReportProfileInput(),
      renderPdf: (snapshot, aiSummary,
          {required bool isRawFallback, RawReportBanner? rawBanner}) async {
        onRender?.call(aiSummary, isRawFallback, rawBanner);
        if (realPdf) {
          return buildReportPdfBytes(snapshot,
              aiSummary: aiSummary,
              isRawFallback: isRawFallback,
              rawBanner: rawBanner ?? RawReportBanner.noChoiceFailure);
        }
        return [1, 2, 3];
      },
      savePdf: (bytes, name) async => '/tmp/$name',
    );
  }

  group('classification table (one object drives retry + reason)', () {
    void check(
      AiFailure f, {
      required AiFailureClass cls,
      required int attempts,
      required String reason,
    }) {
      expect(f.failureClass, cls);
      expect(f.maxAttempts, attempts);
      expect(f.retryable, attempts > 1);
      expect(f.plainReason, reason);
    }

    test('200 without a string result → server, retryable', () {
      check(const AiFailure(httpStatus: 200, missingResult: true),
          cls: AiFailureClass.server,
          attempts: 2,
          reason: 'HTTP 200 (request failed)');
    });
    test('5xx → server, retryable', () {
      check(const AiFailure(httpStatus: 503),
          cls: AiFailureClass.server,
          attempts: 2,
          reason: 'HTTP 503 (server error)');
    });
    test('429 → rateLimited, retryable', () {
      check(const AiFailure(httpStatus: 429),
          cls: AiFailureClass.rateLimited,
          attempts: 2,
          reason: 'HTTP 429 (try again later)');
    });
    test('no response → connection, 4 attempts, only no-connection', () {
      check(const AiFailure(noResponse: true),
          cls: AiFailureClass.connection,
          attempts: 4,
          reason: 'no connection');
    });
    test('timeout → its own class, retryable', () {
      check(const AiFailure(timedOut: true),
          cls: AiFailureClass.timeout,
          attempts: 2,
          reason: 'network timeout');
    });
    test('timeout takes precedence over no-response', () {
      check(const AiFailure(timedOut: true, noResponse: true),
          cls: AiFailureClass.timeout,
          attempts: 2,
          reason: 'network timeout');
    });
    test('no session → session, exactly 1 attempt', () {
      check(const AiFailure(noSession: true),
          cls: AiFailureClass.session,
          attempts: 1,
          reason: 'not signed in');
    });
    test('401 → session, exactly 1 attempt', () {
      check(const AiFailure(httpStatus: 401),
          cls: AiFailureClass.session,
          attempts: 1,
          reason: 'HTTP 401 (signed out?)');
    });
    test('other 4xx → fatalRequest, 1 attempt', () {
      check(const AiFailure(httpStatus: 400),
          cls: AiFailureClass.fatalRequest,
          attempts: 1,
          reason: 'HTTP 400 (request failed)');
    });
    test('unclassified → unknown, 1 attempt, never no connection', () {
      check(const AiFailure(unclassified: true),
          cls: AiFailureClass.unknown,
          attempts: 1,
          reason: 'unknown error');
    });
  });

  group('pipeline fixtures', () {
    test('(a) HTTP 200 whose body lacks a string result retries as '
        'the server class (2 attempts), then holds', () async {
      var calls = 0;
      final outcome = await generate(pipelineFor(
        backendWithData(),
        script: (n) {
          calls = n;
          return (
            statusCode: 200,
            body: {'unexpected': true},
            serverError: null,
            transportFailure: null,
          );
        },
      ));
      expect(calls, 2);
      expect(outcome, isA<ReportAiDecision>());
      final d = outcome as ReportAiDecision;
      expect(d.failureClass, AiFailureClass.server);
      expect(d.aiAttempts, hasLength(2));
      expect(
          d.aiAttempts.every((a) =>
              a.failureClass == AiFailureClass.server &&
              a.httpStatus == 200 &&
              !a.succeeded),
          isTrue);
    });

    test('(a2) HTTP 200 with a non-string result is the same class',
        () async {
      var calls = 0;
      final outcome = await generate(pipelineFor(
        backendWithData(),
        script: (n) {
          calls = n;
          return (
            statusCode: 200,
            body: {'result': 42},
            serverError: null,
            transportFailure: null,
          );
        },
      ));
      expect(calls, 2);
      expect((outcome as ReportAiDecision).failureClass,
          AiFailureClass.server);
    });

    test('(b) HTTP 429 retries (2 attempts), then holds', () async {
      var calls = 0;
      final outcome = await generate(pipelineFor(
        backendWithData(),
        script: (n) {
          calls = n;
          return aiStatus(429);
        },
      ));
      expect(calls, 2);
      final d = outcome as ReportAiDecision;
      expect(d.failureClass, AiFailureClass.rateLimited);
      expect(d.aiFailureReason, 'HTTP 429 (try again later)');
      expect(d.aiAttempts, hasLength(2));
    });

    test('(c) noSession stops at exactly 1 attempt, fatal path',
        () async {
      var calls = 0;
      final outcome = await generate(pipelineFor(
        backendWithData(),
        script: (n) {
          calls = n;
          return aiTransport(AiTransportFailure.noSession);
        },
      ));
      expect(calls, 1);
      expect(outcome, isA<ReportFailed>());
      expect(outcome, isNot(isA<ReportAiDecision>()));
      final f = outcome as ReportFailed;
      expect(f.message, 'not signed in');
      expect(f.aiAttempts, hasLength(1));
      expect(f.aiAttempts.single.failureClass, AiFailureClass.session);
    });

    test('(e) client timeout is its own retryable class and the '
        'attempts are recorded', () async {
      var calls = 0;
      final backend = backendWithData();
      final pipeline = ReportGenerationPipeline(
        collector: ReportDataCollector(backend: backend, hc: FakeHc()),
        backend: backend,
        // A hanging call: only the pipeline's own per-attempt
        // timeout can end it.
        aiCall: (body) {
          calls++;
          return Completer<AiResult>().future;
        },
        delay: (_) async {},
        attemptTimeout: const Duration(milliseconds: 60),
      );
      final outcome = await generate(pipeline);
      expect(calls, 2);
      final d = outcome as ReportAiDecision;
      expect(d.failureClass, AiFailureClass.timeout);
      expect(d.aiFailureReason, 'network timeout');
      expect(d.aiAttempts, hasLength(2));
      expect(
          d.aiAttempts
              .every((a) => a.failureClass == AiFailureClass.timeout),
          isTrue);
    });

    test('(i) single-flight: a hanging first attempt blocks any '
        'second request until it settles', () async {
      final completers = <Completer<AiResult>>[];
      final firedAt = <int>[];
      var settled1 = false;
      Future<AiResult> hanging(int n) {
        firedAt.add(n);
        final c = Completer<AiResult>();
        completers.add(c);
        return c.future;
      }

      final backend = backendWithData();
      ReportGenerationPipeline p(int tag) => ReportGenerationPipeline(
            collector: ReportDataCollector(backend: backend, hc: FakeHc()),
            backend: backend,
            aiCall: (body) => hanging(tag),
            delay: (_) async {},
          );
      Future<ReportOutcome> gen(ReportGenerationPipeline pipe) =>
          pipe.generate(
            selectedCategories: [cat(1, 'Symptoms')],
            last30Days: true,
            profile: const ReportProfileInput(),
            renderPdf: (s, summary,
                    {required bool isRawFallback,
                    RawReportBanner? rawBanner}) async =>
                [1],
            savePdf: (bytes, name) async => '/tmp/$name',
          );

      final g1 = gen(p(1)).then((o) {
        settled1 = true;
        return o;
      });
      // Let generation 1 reach its (hanging) attempt.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(completers, hasLength(1));

      final g2 = gen(p(2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Still exactly ONE request in flight: generation 2's
      // attempt is queued at the gate, unfired.
      expect(completers, hasLength(1));
      expect(settled1, isFalse);

      completers[0].complete(aiOk());
      final o1 = await g1;
      expect(o1, isA<ReportReady>());
      // Only after the first attempt settled did the second fire.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(completers, hasLength(2));
      completers[1].complete(aiOk());
      final o2 = await g2;
      expect(o2, isA<ReportReady>());
      expect(firedAt, [1, 2]);
    });
  });

  group('backend 401 fixtures (d)', () {
    TabsBackend backendWith(MockClient client, FakeSessionStore store) =>
        TabsBackend(client: client, sessionStore: store);

    test('(d) stale-token 401 → refresh once → retry succeeds with '
        'the rotated token', () async {
      final store = FakeSessionStore()
        ..token = 'old-token'
        ..refreshToken = 'rt-0'
        ..email = 'a@b.c';
      final reportAuth = <String?>[];
      var refreshCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path == '/api/auth/refresh-token') {
          refreshCalls++;
          return http.Response(
              jsonEncode({'token': 'new-token', 'refreshToken': 'rt-1'}),
              200);
        }
        if (req.url.path == '/api/ai/report') {
          reportAuth.add(req.headers['Authorization']);
          if (req.headers['Authorization'] == 'Bearer old-token') {
            return http.Response('{"error":"expired"}', 401);
          }
          return http.Response(
              jsonEncode({'result': 'AI TEXT'}), 200);
        }
        return http.Response('{}', 404);
      });
      final backend = backendWith(client, store);
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      expect(res.statusCode, 200);
      expect(res.body?['result'], 'AI TEXT');
      expect(refreshCalls, 1);
      expect(reportAuth, ['Bearer old-token', 'Bearer new-token']);
    });

    test('(d) post-refresh 401 surfaces as a 401 (session), never '
        'a transport/no-connection outcome', () async {
      final store = FakeSessionStore()
        ..token = 'old-token'
        ..refreshToken = 'rt-0'
        ..email = 'a@b.c';
      var reportCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path == '/api/auth/refresh-token') {
          return http.Response(
              jsonEncode({'token': 'new-token', 'refreshToken': 'rt-1'}),
              200);
        }
        reportCalls++;
        return http.Response('{"error":"nope"}', 401);
      });
      final backend = backendWith(client, store);
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      // Initial send + exactly one post-refresh retry, then the
      // 401 is handed up as a STATUS — the pipeline classifies it
      // session/fatal with reason 'HTTP 401 (signed out?)'.
      expect(reportCalls, 2);
      expect(res.statusCode, 401);
      expect(res.transportFailure, isNull);
      final failure = AiFailure(httpStatus: res.statusCode);
      expect(failure.failureClass, AiFailureClass.session);
      expect(failure.plainReason, 'HTTP 401 (signed out?)');
      expect(failure.plainReason, isNot('no connection'));
    });

    test('(d) a call fired while a refresh is in flight waits for '
        'it and fires ONCE with the rotated token (no twin)',
        () async {
      final store = FakeSessionStore()
        ..token = 'old-token'
        ..refreshToken = 'rt-0'
        ..email = 'a@b.c';
      final reportAuth = <String?>[];
      final refreshGate = Completer<void>();
      var refreshStarted = Completer<void>();
      final client = MockClient((req) async {
        if (req.url.path == '/api/auth/refresh-token') {
          if (!refreshStarted.isCompleted) refreshStarted.complete();
          await refreshGate.future;
          return http.Response(
              jsonEncode({'token': 'new-token', 'refreshToken': 'rt-1'}),
              200);
        }
        reportAuth.add(req.headers['Authorization']);
        if (req.headers['Authorization'] == 'Bearer old-token') {
          return http.Response('{"error":"expired"}', 401);
        }
        return http.Response(jsonEncode({'result': 'AI TEXT'}), 200);
      });
      final backend = backendWith(client, store);
      // Call A takes the 401 and starts the (held) refresh.
      final aFuture = backend.postAiDetailed('/api/ai/report', const {});
      await refreshStarted.future;
      // Call B starts while the refresh is still in flight.
      final bFuture = backend.postAiDetailed('/api/ai/report', const {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // B has NOT fired with the stale token — it is waiting out
      // the refresh instead of racing it.
      expect(reportAuth, ['Bearer old-token']);
      refreshGate.complete();
      final a = await aFuture;
      final b = await bFuture;
      expect(a.statusCode, 200);
      expect(b.statusCode, 200);
      // A: stale → 401 → retry on the rotated token. B: exactly
      // one request, on the rotated token. No twin.
      expect(reportAuth,
          ['Bearer old-token', 'Bearer new-token', 'Bearer new-token']);
    });
  });

  group('hold + decision fixtures (f)(g)(h)', () {
    Future<({ReportGenerationService service, FakeNotifier notifier})>
        holdExhausted({
      required AiResult Function(int call) script,
      void Function(String? summary, bool raw, RawReportBanner? banner)?
          onRender,
      bool realPdf = false,
    }) async {
      final backend = backendWithData();
      final notifier = FakeNotifier();
      final service = ReportGenerationService(notifier: notifier);
      final pipeline = pipelineFor(backend, script: script);
      await service.start(
        ({required onStage, required isCancelled}) => pipeline.generate(
          selectedCategories: [cat(1, 'Symptoms')],
          last30Days: true,
          profile: const ReportProfileInput(),
          onStage: onStage,
          isCancelled: isCancelled,
          renderPdf: (snapshot, aiSummary,
              {required bool isRawFallback,
              RawReportBanner? rawBanner}) async {
            onRender?.call(aiSummary, isRawFallback, rawBanner);
            if (realPdf) {
              return buildReportPdfBytes(snapshot,
                  aiSummary: aiSummary,
                  isRawFallback: isRawFallback,
                  rawBanner: rawBanner ?? RawReportBanner.noChoiceFailure);
            }
            return [1, 2, 3];
          },
          savePdf: (bytes, name) async => '/tmp/$name',
        ),
      );
      return (service: service, notifier: notifier);
    }

    test('(f) exhaustion HOLDS: no PDF, no notification, decision '
        'held with the full attempt history', () async {
      var renders = 0;
      final held = await holdExhausted(
        script: (n) => aiTransport(AiTransportFailure.noResponse),
        onRender: (s, raw, b) => renders++,
      );
      expect(renders, 0); // nothing rendered, nothing shipped
      expect(held.service.pendingShare, isNull);
      expect(held.notifier.shown, 0); // failures never notify
      expect(held.service.isGenerating, isFalse);
      final failure = held.service.pendingFailure;
      expect(failure, isA<ReportAiDecision>());
      final d = failure as ReportAiDecision;
      expect(d.failureClass, AiFailureClass.connection);
      expect(d.aiAttempts, hasLength(4));
      expect(d.aiAttempts.map((a) => a.attempt), [1, 2, 3, 4]);
      expect(
          d.aiAttempts
              .every((a) => a.failureClass == AiFailureClass.connection),
          isTrue);
      expect(d.snapshot, isNotNull); // the collected data is held
    });

    test('(g) explicit ship-raw choice → raw PDF with the CHOICE '
        'banner; the failure banner is absent', () async {
      final held = await holdExhausted(
        script: (n) => aiTransport(AiTransportFailure.noResponse),
        realPdf: true,
      );
      await held.service.resumeAiDecision(retryAi: false);
      final ready = held.service.pendingShare;
      expect(ready, isNotNull);
      expect(ready!.isRawFallback, isTrue);
      expect(ready.rawBanner, RawReportBanner.explicitChoice);
      expect(held.service.pendingFailure, isNull);
      final text = pdfText(ready.pdfBytes);
      expect(text, contains('RAW DATA REPORT: DATA ONLY, NO AI ANALYSIS'));
      expect(text,
          contains('You chose to make this report without AI analysis.'));
      expect(text, isNot(contains('AI ANALYSIS UNAVAILABLE')));
      expect(text, isNot(contains('AI unavailable')));
      expect(text, isNot(contains('no connection')));
    });

    test('(g2) the no-choice failure banner pair prints for a raw '
        'ship that was never a decision', () async {
      final snap = ReportSnapshot(
        last30Days: false,
        generationTimestampMs:
            DateTime(2026, 11, 9, 20, 20).millisecondsSinceEpoch,
        logEntries: [entry(1, 1, 1000)],
        categoriesMap: const {1: 'Symptoms'},
        conditions: const ['POTS'],
      );
      final bytes = await buildReportPdfBytes(snap,
          aiSummary: null,
          isRawFallback: true,
          rawBanner: RawReportBanner.noChoiceFailure);
      final text = pdfText(bytes);
      expect(
          text,
          contains(
              'RAW DATA REPORT: AI ANALYSIS UNAVAILABLE AT GENERATION TIME'));
      expect(text, contains('AI analysis could not be completed.'));
      expect(text, isNot(contains('DATA ONLY')));
      expect(text, isNot(contains('You chose')));
      expect(text, isNot(contains('AI unavailable')));
    });

    test('(h) retry-from-hold success → full AI report; history '
        'shows the failed attempts plus the successful retry, and '
        'data is NOT recollected', () async {
      final backend = backendWithData();
      final notifier = FakeNotifier();
      final service = ReportGenerationService(notifier: notifier);
      var aiSucceeds = false;
      var calls = 0;
      final pipeline = ReportGenerationPipeline(
        collector: ReportDataCollector(backend: backend, hc: FakeHc()),
        backend: backend,
        aiCall: (body) async {
          calls++;
          return aiSucceeds
              ? aiOk('[SECTION] USER SUMMARY\nRecovered.')
              : aiTransport(AiTransportFailure.noResponse);
        },
        delay: (_) async {},
      );
      String? renderedSummary;
      await service.start(
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
            return [7, 7, 7];
          },
          savePdf: (bytes, name) async => '/tmp/$name',
        ),
      );
      expect(service.pendingFailure, isA<ReportAiDecision>());
      expect(calls, 4);
      final fetchesAfterHold = backend.entryFetches;

      aiSucceeds = true;
      await service.resumeAiDecision(retryAi: true);
      final ready = service.pendingShare;
      expect(ready, isNotNull);
      expect(ready!.isRawFallback, isFalse);
      expect(renderedSummary, '[SECTION] USER SUMMARY\nRecovered.');
      // The retry ran ONLY the AI leg: no recollection happened.
      expect(backend.entryFetches, fetchesAfterHold);
      expect(calls, 5);
      // History: attempts 1–4 failed (connection), attempt 5 the
      // successful retry — one continuous record.
      expect(ready.aiAttempts, hasLength(5));
      expect(ready.aiAttempts.map((a) => a.attempt), [1, 2, 3, 4, 5]);
      expect(
          ready.aiAttempts
              .take(4)
              .every((a) => a.failureClass == AiFailureClass.connection),
          isTrue);
      expect(ready.aiAttempts.last.succeeded, isTrue);
      expect(ready.aiAttempts.last.failureClass, isNull);
    });

    test('(f2) a retry that exhausts again holds a FRESH decision '
        'with the extended history', () async {
      var renders = 0;
      final held = await holdExhausted(
        script: (n) => aiStatus(500),
        onRender: (s, raw, b) => renders++,
      );
      final first = held.service.pendingFailure as ReportAiDecision;
      expect(first.aiAttempts, hasLength(2));
      await held.service.resumeAiDecision(retryAi: true);
      expect(renders, 0);
      final second = held.service.pendingFailure;
      expect(second, isA<ReportAiDecision>());
      expect(second, isNot(same(first)));
      expect((second as ReportAiDecision).aiAttempts, hasLength(4));
      expect(second.aiAttempts.map((a) => a.attempt), [1, 2, 3, 4]);
    });
  });

  group('Juno decision strings (byte-exact pins)', () {
    test('the ruled strings, pinned literally', () {
      expect(aiDecisionTitle, "AI analysis couldn't be completed");
      expect(
          aiDecisionBody,
          'Your data is safe, and the report data is ready. The AI '
          'analysis could not be completed. You can try the analysis '
          'again, or make the report with the data only and no AI '
          'analysis.');
      expect(aiDecisionRetryLabel, 'Try AI analysis again');
      expect(aiDecisionRawLabel, 'Make report without AI analysis');
    });

    testWidgets('(f) the Progress Reports page presents the '
        'decision UI with Juno\'s exact strings on exhaustion',
        (tester) async {
      final mem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final backend = backendWithData();
      final service = ReportGenerationService(notifier: FakeNotifier());
      final pipeline = pipelineFor(
        backend,
        script: (n) => aiTransport(AiTransportFailure.noResponse),
      );
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
                  pipeline: pipeline,
                  generationService: service,
                  savePdf: (bytes, name) async => '/tmp/$name',
                  sharePdf: (bytes, name) async {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Export PDF Report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export PDF Report'));
      for (var i = 0;
          i < 60 && find.text(aiDecisionTitle).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Juno's surface, byte-exact (the constants are pinned to
      // the ruling literals by the test above; the finders here
      // use the ruling's literal text directly).
      expect(find.text("AI analysis couldn't be completed"),
          findsOneWidget);
      expect(
          find.text(
              'Your data is safe, and the report data is ready. The AI analysis could not be completed. You can try the analysis again, or make the report with the data only and no AI analysis.'),
          findsOneWidget);
      expect(find.text('Try AI analysis again'), findsOneWidget);
      expect(
          find.text('Make report without AI analysis'), findsOneWidget);
      // No share confirmation, no raw ship: the generation held.
      expect(find.text('Share health report'), findsNothing);
      expect(service.pendingFailure, isA<ReportAiDecision>());
      expect(service.pendingShare, isNull);
    });
  });
}
