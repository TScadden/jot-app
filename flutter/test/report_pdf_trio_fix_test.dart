import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/downloads_saver.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

// ── Fakes (mirrors of the R66 fakes, kept local to this file) ────

class FakeBackend extends TabsBackend {
  List<QuickLogCategory> categories = const [];
  List<QuickLogEntry> entries = const [];

  FakeBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => categories;

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
    })
  >
  postAiDetailed(
    String path,
    Map<String, dynamic> body, {
    Duration? timeoutOverride,
  }) async {
    return (
      statusCode: 200,
      body: {'result': '[SECTION] USER SUMMARY\nAll good.'},
      serverError: null,
      transportFailure: null,
    );
  }
}

class FakeHc extends HealthConnectService {
  bool connected = true;

  @override
  Future<bool> isConnected() async => connected;
  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
    int days,
  ) async => const [];
  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async =>
      const [];
  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async =>
      const [];
  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];
  @override
  Future<double?> readHrvRmssd(String dateStr) async => null;
  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(int days) async {
    return const [];
  }
}

QuickLogCategory cat(int id, String name) => QuickLogCategory(
  id: id,
  name: name,
  icon: 'x',
  colorHex: '#FF0000',
  isDefault: true,
  sortOrder: id,
);

QuickLogEntry entry(int id, int catId, int ts) => QuickLogEntry(
  id: id,
  categoryId: catId,
  body: 'b$id',
  chips: '',
  manualText: '',
  timestamp: ts,
);

Map<String, dynamic> medRow({
  required String name,
  String dose = '',
  String frequency = '',
  bool? isPresent,
  bool? isDeleted,
  bool? isArchived,
  String? endDate,
}) {
  final row = <String, dynamic>{'name': name};
  if (dose.isNotEmpty) row['dose'] = dose;
  if (frequency.isNotEmpty) row['frequency'] = frequency;
  if (isPresent != null) row['isPresent'] = isPresent;
  if (isDeleted != null) row['isDeleted'] = isDeleted;
  if (isArchived != null) row['isArchived'] = isArchived;
  if (endDate != null) row['endDate'] = endDate;
  return row;
}

SettingsProfileData profileWithMeds(List<Map<String, dynamic>> rows) =>
    SettingsProfileData(medicationsRaw: jsonEncode(rows));

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

  // ── ITEM 1 — wrong medications ────────────────────────────────

  group('Item 1: report active-medication filter (Juno Ruling 1)', () {
    List<String> namesOf(List<Map<String, dynamic>> rows) =>
        reportProfileInputFromSettings(profileWithMeds(rows)).activeMedications
            .map((m) => m.name)
            .toList();

    test('present, not deleted, no stamp → included, fields as stored', () {
      final input = reportProfileInputFromSettings(
        profileWithMeds([
          medRow(
            name: 'Ivabradine',
            dose: '7.5mg',
            frequency: 'Twice daily',
            isPresent: true,
            isDeleted: false,
            endDate: 'Present',
          ),
        ]),
      );
      expect(input.activeMedications, hasLength(1));
      final m = input.activeMedications.single;
      expect(m.name, 'Ivabradine');
      expect(m.dose, '7.5mg'); // exactly as stored — no units appended
      expect(m.frequency, 'Twice daily');
    });

    test('isPresent false (standard archive) → excluded', () {
      expect(
        namesOf([
          medRow(
            name: 'Escitalopram',
            dose: '50mg',
            isPresent: false,
            endDate: 'Oct 16, 2026',
          ),
        ]),
        isEmpty,
      );
    });

    test('R35 mixed row: isArchived true + isPresent true → excluded', () {
      expect(
        namesOf([
          medRow(
            name: 'Escitalopram',
            dose: '50mg',
            isPresent: true,
            isArchived: true,
          ),
        ]),
        isEmpty,
      );
    });

    test('isArchived true + isPresent false → excluded', () {
      expect(
        namesOf([medRow(name: 'Old Med', isPresent: false, isArchived: true)]),
        isEmpty,
      );
    });

    test('isDeleted true + isPresent true → excluded', () {
      expect(
        namesOf([
          medRow(name: 'Deleted Med', isPresent: true, isDeleted: true),
        ]),
        isEmpty,
      );
    });

    test('isDeleted true + archived → excluded', () {
      expect(
        namesOf([
          medRow(
            name: 'Deleted Med',
            isPresent: false,
            isDeleted: true,
            isArchived: true,
          ),
        ]),
        isEmpty,
      );
    });

    test('isArchived false stamp + isPresent true → included', () {
      expect(
        namesOf([
          medRow(name: 'Current Med', isPresent: true, isArchived: false),
        ]),
        ['Current Med'],
      );
    });

    test('missing isPresent + endDate "Present" → included', () {
      expect(namesOf([medRow(name: 'Current Med', endDate: 'Present')]), [
        'Current Med',
      ]);
    });

    test('missing isPresent + real end date → excluded', () {
      expect(
        namesOf([medRow(name: 'Ended Med', endDate: 'Oct 16, 2026')]),
        isEmpty,
      );
    });

    test("Juno fixture: snapshot, AI context, fallback, and count "
        'carry exactly the 4 true actives', () async {
      final rows = <Map<String, dynamic>>[
        medRow(
          name: 'Ivabradine',
          dose: '7.5mg',
          frequency: 'Twice daily',
          isPresent: true,
          endDate: 'Present',
        ),
        // Archived escitalopram (standard archive: not present).
        medRow(
          name: 'Escitalopram',
          dose: '50mg',
          frequency: 'Daily',
          isPresent: false,
          endDate: 'Oct 16, 2026',
        ),
        medRow(
          name: 'SS-31 Peptide',
          dose: '0.05',
          frequency: 'Daily',
          isPresent: true,
          endDate: 'Present',
        ),
        // The R35 row: explicit archive stamp over isPresent true.
        medRow(
          name: 'Stamped Archived Med',
          dose: '10mg',
          frequency: 'Daily',
          isPresent: true,
          isArchived: true,
        ),
        medRow(
          name: 'BPC-157 Peptide',
          dose: '0.5',
          frequency: 'Daily',
          isPresent: true,
          endDate: 'Present',
        ),
        medRow(
          name: 'Deleted Med',
          dose: '5mg',
          frequency: 'Daily',
          isPresent: true,
          isDeleted: true,
        ),
        medRow(
          name: 'Desvenlafaxine Succinate ER',
          dose: '50mg',
          frequency: 'Daily',
          isPresent: true,
          endDate: 'Present',
        ),
      ];
      const trueActives = [
        'Ivabradine',
        'SS-31 Peptide',
        'BPC-157 Peptide',
        'Desvenlafaxine Succinate ER',
      ];
      const excluded = ['Escitalopram', 'Stamped Archived Med', 'Deleted Med'];

      final profile = reportProfileInputFromSettings(profileWithMeds(rows));
      expect(profile.activeMedications.map((m) => m.name), trueActives);

      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
      final snap = await ReportDataCollector(backend: backend, hc: FakeHc())
          .collect(
            selectedCategories: [cat(1, 'Symptoms')],
            last30Days: true,
            profile: profile,
          );
      expect(snap.medications.map((m) => m.name), trueActives);
      expect(snap.sectionMetadata['medications']!.recordCount, 4);

      final context = buildReportUserContext(snap);
      expect(
        context,
        contains(
          'Active Medications: Ivabradine 7.5mg (Twice daily), '
          'SS-31 Peptide 0.05 (Daily), BPC-157 Peptide 0.5 (Daily), '
          'Desvenlafaxine Succinate ER 50mg (Daily)',
        ),
      );
      final fallback = buildRawFallbackSummary(snap);
      expect(
        fallback,
        contains(
          'Active Medications: Ivabradine 7.5mg, '
          'SS-31 Peptide 0.05, BPC-157 Peptide 0.5, '
          'Desvenlafaxine Succinate ER 50mg',
        ),
      );
      expect(
        buildDataAvailability(snap),
        contains('Medications (profile list): Available (4 records)'),
      );
      for (final bad in excluded) {
        expect(context, isNot(contains(bad)), reason: 'AI context: $bad');
        expect(fallback, isNot(contains(bad)), reason: 'fallback: $bad');
        expect(snap.medications.map((m) => m.name), isNot(contains(bad)));
      }
    });

    test('collector filters an unfiltered profile input itself', () async {
      final parsed = [
        for (final row in [
          medRow(name: 'Current Med', dose: '1mg', isPresent: true),
          medRow(
            name: 'Stamped Archived Med',
            isPresent: true,
            isArchived: true,
          ),
          medRow(name: 'Deleted Med', isPresent: true, isDeleted: true),
        ])
          MedicationEntry.fromBlobRow(row)!,
      ];
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
      final snap = await ReportDataCollector(backend: backend, hc: FakeHc())
          .collect(
            selectedCategories: [cat(1, 'Symptoms')],
            last30Days: true,
            profile: ReportProfileInput(activeMedications: parsed),
          );
      expect(snap.medications.map((m) => m.name), ['Current Med']);
      expect(snap.sectionMetadata['medications']!.recordCount, 1);
    });

    test(
      'empty active set: fallback "None listed", context line omitted',
      () async {
        final profile = reportProfileInputFromSettings(
          profileWithMeds([
            medRow(name: 'Escitalopram', isPresent: false, isArchived: true),
          ]),
        );
        final backend = FakeBackend()
          ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
        final snap = await ReportDataCollector(backend: backend, hc: FakeHc())
            .collect(
              selectedCategories: [cat(1, 'Symptoms')],
              last30Days: true,
              profile: profile,
            );
        expect(snap.medications, isEmpty);
        expect(
          buildRawFallbackSummary(snap),
          contains('Active Medications: None listed'),
        );
        expect(
          buildReportUserContext(snap),
          isNot(contains('Active Medications:')),
        );
      },
    );
  });

  // ── ITEM 2 — AI failure classification ────────────────────────

  group('Item 2: AiFailure plain reasons (Juno Ruling 3 closed set)', () {
    test('timeout → network timeout (no duration named)', () {
      expect(const AiFailure(timedOut: true).plainReason, 'network timeout');
    });
    test('timeout takes precedence over no-response', () {
      expect(
        const AiFailure(timedOut: true, noResponse: true).plainReason,
        'network timeout',
      );
    });
    test('attempted, no response, no timeout → no connection', () {
      expect(const AiFailure(noResponse: true).plainReason, 'no connection');
    });
    test('no session → not signed in', () {
      expect(const AiFailure(noSession: true).plainReason, 'not signed in');
    });
    test('HTTP statuses, only for a status actually received', () {
      expect(
        const AiFailure(httpStatus: 401).plainReason,
        'HTTP 401 (signed out?)',
      );
      expect(
        const AiFailure(httpStatus: 429).plainReason,
        'HTTP 429 (try again later)',
      );
      expect(
        const AiFailure(httpStatus: 503).plainReason,
        'HTTP 503 (server error)',
      );
      expect(
        const AiFailure(httpStatus: 400).plainReason,
        'HTTP 400 (request failed)',
      );
    });
    test('unclassified → unknown error (last resort)', () {
      expect(const AiFailure().plainReason, 'unknown error');
    });
  });

  group('Item 2: TabsBackend.postAiDetailed transport classification', () {
    TabsBackend backendWith(MockClient client, {String? token}) {
      final store = FakeSessionStore()..token = token;
      return TabsBackend(client: client, sessionStore: store);
    }

    test('transport timeout → AiTransportFailure.timeout, no status', () async {
      final backend = backendWith(
        MockClient((_) async => throw TimeoutException('slow')),
        token: 'tok',
      );
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      expect(res.statusCode, isNull);
      expect(res.transportFailure, AiTransportFailure.timeout);
    });

    test('budgets: shared stays 20s, the AI call gets the native 60s',
        () {
      expect(TabsBackend.requestTimeout, const Duration(seconds: 20));
      expect(TabsBackend.aiRequestTimeout, const Duration(seconds: 60));
    });

    test(
        'a response slower than the budget → timeout classification '
        '(real timer, via the override seam)', () async {
      final backend = backendWith(
        MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response(jsonEncode({'result': 'late'}), 200);
        }),
        token: 'tok',
      );
      final res = await backend.postAiDetailed(
        '/api/ai/report',
        const {},
        timeoutOverride: const Duration(milliseconds: 50),
      );
      expect(res.statusCode, isNull);
      expect(res.transportFailure, AiTransportFailure.timeout);
    });

    test('a response inside the budget succeeds', () async {
      final backend = backendWith(
        MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response(jsonEncode({'result': 'ok'}), 200);
        }),
        token: 'tok',
      );
      final res = await backend.postAiDetailed(
        '/api/ai/report',
        const {},
        timeoutOverride: const Duration(seconds: 2),
      );
      expect(res.statusCode, 200);
      expect(res.transportFailure, isNull);
    });

    test('socket failure → AiTransportFailure.noResponse', () async {
      final backend = backendWith(
        MockClient((_) async => throw const SocketException('no route')),
        token: 'tok',
      );
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      expect(res.statusCode, isNull);
      expect(res.transportFailure, AiTransportFailure.noResponse);
    });

    test('client exception → AiTransportFailure.noResponse', () async {
      final backend = backendWith(
        MockClient((_) async => throw http.ClientException('down')),
        token: 'tok',
      );
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      expect(res.transportFailure, AiTransportFailure.noResponse);
    });

    test('no token → noSession, and no request is attempted', () async {
      var hit = false;
      final backend = backendWith(
        MockClient((_) async {
          hit = true;
          return http.Response('{}', 200);
        }),
      );
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      expect(res.statusCode, isNull);
      expect(res.transportFailure, AiTransportFailure.noSession);
      expect(hit, isFalse);
    });

    test('HTTP 503 → status carried, no transport failure', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{"error":"boom"}', 503)),
        token: 'tok',
      );
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      expect(res.statusCode, 503);
      expect(res.transportFailure, isNull);
    });

    test('HTTP 200 → body carried, no transport failure', () async {
      final backend = backendWith(
        MockClient(
          (_) async => http.Response(jsonEncode({'result': 'ok'}), 200),
        ),
        token: 'tok',
      );
      final res = await backend.postAiDetailed('/api/ai/report', const {});
      expect(res.statusCode, 200);
      expect(res.body?['result'], 'ok');
      expect(res.transportFailure, isNull);
    });
  });

  group('Item 2: pipeline reason per failure kind', () {
    Future<({ReportOutcome outcome, int calls})> runAi(
      Future<
        ({
          int? statusCode,
          Map<String, dynamic>? body,
          String? serverError,
          AiTransportFailure? transportFailure,
        })
      >
      Function(Map<String, dynamic>)
      aiCall,
    ) async {
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
      final pipeline = ReportGenerationPipeline(
        collector: ReportDataCollector(backend: backend, hc: FakeHc()),
        backend: backend,
        aiCall: aiCall,
        delay: (_) async {},
      );
      final outcome = await pipeline.generate(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        renderPdf: (
          snapshot,
          aiSummary, {
          required bool isRawFallback,
          String? aiFailureReason,
        }) async => [1, 2, 3],
        savePdf: (bytes, name) async => '/tmp/$name',
      );
      return (outcome: outcome, calls: -1);
    }

    Future<({String? reason, int calls})> reasonFor(
      Future<
        ({
          int? statusCode,
          Map<String, dynamic>? body,
          String? serverError,
          AiTransportFailure? transportFailure,
        })
      >
      Function(Map<String, dynamic>)
      impl,
    ) async {
      var calls = 0;
      final r = await runAi((body) {
        calls++;
        return impl(body);
      });
      return (reason: (r.outcome as ReportReady).aiFailureReason, calls: calls);
    }

    test(
      'backend transport timeout → network timeout, NOT no connection',
      () async {
        final r = await reasonFor(
          (_) async => (
            statusCode: null,
            body: null,
            serverError: null,
            transportFailure: AiTransportFailure.timeout,
          ),
        );
        expect(r.reason, 'network timeout');
        expect(r.calls, 4); // connection retry class, unchanged
      },
    );

    test('backend no-response → no connection', () async {
      final r = await reasonFor(
        (_) async => (
          statusCode: null,
          body: null,
          serverError: null,
          transportFailure: AiTransportFailure.noResponse,
        ),
      );
      expect(r.reason, 'no connection');
      expect(r.calls, 4);
    });

    test('backend no-session → not signed in', () async {
      final r = await reasonFor(
        (_) async => (
          statusCode: null,
          body: null,
          serverError: null,
          transportFailure: AiTransportFailure.noSession,
        ),
      );
      expect(r.reason, 'not signed in');
    });

    test('HTTP 429 → its verbatim reason, fatal class (1 attempt)', () async {
      final r = await reasonFor(
        (_) async => (
          statusCode: 429,
          body: null,
          serverError: 'slow down',
          transportFailure: null,
        ),
      );
      expect(r.reason, 'HTTP 429 (try again later)');
      expect(r.calls, 1);
    });

    test('outer Dart TimeoutException → network timeout', () async {
      final r = await reasonFor((_) async => throw TimeoutException('x'));
      expect(r.reason, 'network timeout');
    });

    test('unclassified throw → unknown error, never no connection', () async {
      final r = await reasonFor((_) async => throw StateError('weird'));
      expect(r.reason, 'unknown error');
    });

    test('unclassified null result → unknown error', () async {
      final r = await reasonFor(
        (_) async => (
          statusCode: null,
          body: null,
          serverError: null,
          transportFailure: null,
        ),
      );
      expect(r.reason, 'unknown error');
    });
  });

  // ── ITEM 3 — Downloads copy ───────────────────────────────────

  group('Item 3: ReportDownloadsSaver channel wrapper', () {
    const channel = MethodChannel(HealthConnectService.channelName);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('invokes savePdfToDownloads with exact bytes + filename', (
      tester,
    ) async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            seen = call;
            return true;
          });
      const saver = ReportDownloadsSaver();
      final ok = await saver.savePdf(
        bytes: [1, 2, 3, 250],
        fileName: 'Tabs_Report_Oct_22_2026.pdf',
      );
      expect(ok, isTrue);
      expect(seen?.method, 'savePdfToDownloads');
      final args = seen!.arguments as Map;
      expect(args['fileName'], 'Tabs_Report_Oct_22_2026.pdf');
      expect((args['bytes'] as Uint8List).toList(), [1, 2, 3, 250]);
    });

    testWidgets('platform error → false, never throws', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'DOWNLOADS_SAVE_FAILED');
          });
      const saver = ReportDownloadsSaver();
      expect(await saver.savePdf(bytes: [1], fileName: 'x.pdf'), isFalse);
    });

    // Plain test (real async): inside testWidgets' FakeAsync an
    // unmocked channel future never completes — the codebase's
    // known channel-in-widget-test trap.
    test('missing plugin → false, never throws', () async {
      const saver = ReportDownloadsSaver();
      expect(await saver.savePdf(bytes: [1], fileName: 'x.pdf'), isFalse);
    });
  });

  group('Item 3: pipeline Downloads attempt (Juno Ruling 2)', () {
    Future<ReportOutcome> runPipeline({
      Future<bool> Function(List<int> bytes, String fileName)? saveToDownloads,
      void Function(List<int> bytes, String name)? onDownloads,
      void Function(List<int> bytes, String name)? onSave,
    }) {
      final backend = FakeBackend()
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
      final pipeline = ReportGenerationPipeline(
        collector: ReportDataCollector(backend: backend, hc: FakeHc()),
        backend: backend,
        delay: (_) async {},
      );
      return pipeline.generate(
        selectedCategories: [cat(1, 'Symptoms')],
        last30Days: true,
        profile: const ReportProfileInput(),
        renderPdf: (
          snapshot,
          aiSummary, {
          required bool isRawFallback,
          String? aiFailureReason,
        }) async => [9, 8, 7, 6],
        savePdf: (bytes, name) async {
          onSave?.call(bytes, name);
          return '/tmp/$name';
        },
        saveToDownloads: saveToDownloads == null
            ? null
            : (bytes, name) async {
                onDownloads?.call(bytes, name);
                return saveToDownloads(bytes, name);
              },
      );
    }

    test(
      'invoked on success with the exact bytes + filename of the save',
      () async {
        List<int>? dlBytes;
        String? dlName;
        List<int>? savedBytes;
        String? savedName;
        final outcome = await runPipeline(
          saveToDownloads: (bytes, name) async => true,
          onDownloads: (b, n) {
            dlBytes = b;
            dlName = n;
          },
          onSave: (b, n) {
            savedBytes = b;
            savedName = n;
          },
        );
        expect(outcome, isA<ReportReady>());
        final ready = outcome as ReportReady;
        expect(ready.downloadsSaved, isTrue);
        expect(dlBytes, [9, 8, 7, 6]);
        expect(
          identical(dlBytes, savedBytes),
          isTrue,
          reason: 'same byte list — never a regenerated PDF',
        );
        expect(dlName, savedName);
        expect(dlName, ready.fileName);
      },
    );

    test(
      'false return → carried as failed, generation still completes',
      () async {
        final outcome = await runPipeline(
          saveToDownloads: (b, n) async => false,
        );
        expect(outcome, isA<ReportReady>());
        expect((outcome as ReportReady).downloadsSaved, isFalse);
        expect(outcome.pdfBytes, [9, 8, 7, 6]);
      },
    );

    test('throw → carried as failed, generation still completes', () async {
      final outcome = await runPipeline(
        saveToDownloads: (b, n) async => throw StateError('disk gone'),
      );
      expect(outcome, isA<ReportReady>());
      expect((outcome as ReportReady).downloadsSaved, isFalse);
    });

    test('not wired → downloadsSaved is null (no claim made)', () async {
      final outcome = await runPipeline();
      expect(outcome, isA<ReportReady>());
      expect((outcome as ReportReady).downloadsSaved, isNull);
    });
  });

  group('Item 3: page dialog + snackbars (Juno Ruling 2 strings)', () {
    Future<void> pumpAndGenerate(
      WidgetTester tester, {
      required Future<bool> Function(List<int>, String) saveToDownloads,
      Future<void> Function(List<int>, String)? sharePdf,
      List<List<int>>? downloadsCalls,
      List<String>? downloadsNames,
    }) async {
      final mem = <String, String>{};
      final store = SettingsStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final backend = FakeBackend()
        ..categories = [cat(1, 'Symptoms'), cat(5, 'Sleep')]
        ..entries = [entry(1, 1, DateTime.now().millisecondsSinceEpoch)];
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
                  savePdf: (bytes, name) async => '/tmp/$name',
                  saveToDownloads: (bytes, name) async {
                    downloadsCalls?.add(bytes);
                    downloadsNames?.add(name);
                    return saveToDownloads(bytes, name);
                  },
                  sharePdf: sharePdf ?? (bytes, name) async {},
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
      for (
        var i = 0;
        i < 60 && find.text('Share health report').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Share health report'), findsOneWidget);
      expect(
        find.text(
          'This PDF contains your health data. Only share it with people you trust.',
        ),
        findsOneWidget,
      );
    }

    testWidgets(
      'save succeeded: dialog line, decline snackbar names Downloads',
      (tester) async {
        final dlCalls = <List<int>>[];
        await pumpAndGenerate(
          tester,
          saveToDownloads: (b, n) async => true,
          downloadsCalls: dlCalls,
        );
        // The attempt already finished before the dialog opened.
        expect(dlCalls, hasLength(1));
        expect(
          find.text('A copy was also saved to your Downloads folder.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Not now'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Report saved in Downloads and in the app. Export again any time to share it.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('save failed: dialog line in place of the success line, '
        'decline snackbar (regardless of share choice)', (tester) async {
      await pumpAndGenerate(tester, saveToDownloads: (b, n) async => false);
      expect(
        find.text(
          'This report could not be saved to Downloads. It is saved in the app and you can still share it now.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('A copy was also saved to your Downloads folder.'),
        findsNothing,
      );
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Report saved in the app. It could not be saved to Downloads. Export again any time to share it.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Downloads throws: generation completes, dialog shows failed line',
      (tester) async {
        await pumpAndGenerate(
          tester,
          saveToDownloads: (b, n) async => throw StateError('nope'),
        );
        expect(
          find.text(
            'This report could not be saved to Downloads. It is saved in the app and you can still share it now.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('share-sheet failure after Downloads success names Downloads; '
        'shared bytes equal Downloads bytes', (tester) async {
      final dlCalls = <List<int>>[];
      List<int>? sharedBytes;
      await pumpAndGenerate(
        tester,
        saveToDownloads: (b, n) async => true,
        downloadsCalls: dlCalls,
        sharePdf: (bytes, name) async {
          sharedBytes = bytes;
          throw StateError('no share sheet');
        },
      );
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not open the share sheet. The report is saved in Downloads and in the app.',
        ),
        findsOneWidget,
      );
      expect(sharedBytes, isNotNull);
      expect(dlCalls.single, sharedBytes);
    });

    testWidgets(
      'share-sheet failure after Downloads failure keeps existing line',
      (tester) async {
        await pumpAndGenerate(
          tester,
          saveToDownloads: (b, n) async => false,
          sharePdf: (bytes, name) async => throw StateError('no share sheet'),
        );
        await tester.tap(find.text('Share'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Could not open the share sheet. The report is saved in the app.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('successful Share tap shows no extra snackbar', (tester) async {
      var shared = false;
      await pumpAndGenerate(
        tester,
        saveToDownloads: (b, n) async => true,
        sharePdf: (bytes, name) async => shared = true,
      );
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(shared, isTrue);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  // ── ITEM 1 scope extension — the medications WRITE path ──────
  //
  // Server evidence (Oct 22, 2026): the stored blob still carried
  // escitalopram isPresent:true and no desvenlafaxine, with
  // whole-list pushes landing minutes before the report. The
  // Settings screen used to splice archive/add/delete into its
  // LOAD-TIME snapshot and push that stale list wholesale — any
  // server-side change made after the screen loaded was reverted
  // by the next Settings med op. These tests pin the fix: ops
  // re-pull fresh and splice into the fresh list.

  group('Item 1 write path: Settings med ops splice into a FRESH pull',
      () {
    Map<String, dynamic> blobRow(
      String id,
      String name, {
      bool isPresent = true,
      String endDate = 'Present',
      String dose = '10mg',
    }) =>
        {
          'id': id,
          'name': name,
          'startDate': 'Sep 2026',
          'endDate': endDate,
          'isPresent': isPresent,
          'dose': dose,
          'frequency': 'Daily',
          'updatedAt': 1000,
          'isDeleted': false,
        };

    List<Map<String, dynamic>> staleV1() => [
          blobRow('e1', 'Escitalopram', dose: '50mg'),
          blobRow('i1', 'Ivabradine', dose: '7.5mg'),
        ];

    // What another client landed AFTER the Settings screen
    // loaded: escitalopram archived, desvenlafaxine started.
    List<Map<String, dynamic>> freshV2() => [
          blobRow('e1', 'Escitalopram',
              isPresent: false, endDate: 'Oct 16, 2026', dose: '50mg'),
          blobRow('i1', 'Ivabradine', dose: '7.5mg'),
          blobRow('d1', 'Desvenlafaxine Succinate ER', dose: '50mg'),
        ];

    Future<r29.FakeSettingsBackend> pumpStaleProfile(
        WidgetTester tester) async {
      final backend = r29.FakeSettingsBackend()
        ..pullBody = r29.pull(
            profile: {'medications': jsonEncode(staleV1())});
      await r29.pumpSettings(
        tester,
        r29.host(r29.screen(
            backend: backend, store: r29.fakeStore(<String, String>{}))),
      );
      await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
      await tester.pumpAndSettle();
      // The other client's changes land server-side now.
      backend.pullBody =
          r29.pull(profile: {'medications': jsonEncode(freshV2())});
      return backend;
    }

    List<Map<String, dynamic>> lastPushedRows(
        r29.FakeSettingsBackend backend) {
      final pushes = backend.profilePushes
          .where((p) => p.containsKey('medications'))
          .toList();
      expect(pushes, isNotEmpty);
      return (jsonDecode(pushes.last['medications'] as String) as List)
          .cast<Map<String, dynamic>>();
    }

    testWidgets(
        'stale-push cannot resurrect: an ADD built on the stale '
        'snapshot still pushes the fresh archive + the fresh new med',
        (tester) async {
      final backend = await pumpStaleProfile(tester);
      await tester.tap(find.byKey(const ValueKey('add_medication_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('medication_name_field')), 'New Med');
      await tester.enterText(
          find.byKey(const ValueKey('medication_start_field')), 'Oct 2026');
      await tester.tap(find.byKey(const ValueKey('medication_add')));
      await tester.pumpAndSettle();

      final rows = lastPushedRows(backend);
      final byName = {for (final r in rows) '${r['name']}': r};
      // The fresh archive survived: NOT resurrected as active.
      expect(byName['Escitalopram']?['isPresent'], isFalse);
      expect(byName['Escitalopram']?['endDate'], 'Oct 16, 2026');
      // The fresh addition survived: NOT dropped by the stale push.
      expect(byName.keys, contains('Desvenlafaxine Succinate ER'));
      // And the Settings addition itself landed, appended last.
      expect(rows.last['name'], 'New Med');
      expect(rows.last['isPresent'], isTrue);
    });

    testWidgets(
        'stale-push cannot resurrect: an ARCHIVE from the stale '
        'screen archives its target in the fresh list and leaves '
        'the fresh rows untouched', (tester) async {
      final backend = await pumpStaleProfile(tester);
      // Ivabradine renders at raw index 1 in the stale snapshot.
      await tester
          .tap(find.byKey(const ValueKey('archive_medication_at_1')));
      await tester.pumpAndSettle();

      final rows = lastPushedRows(backend);
      final byName = {for (final r in rows) '${r['name']}': r};
      expect(byName['Ivabradine']?['isPresent'], isFalse);
      expect(byName['Escitalopram']?['isPresent'], isFalse);
      expect(byName['Escitalopram']?['endDate'], 'Oct 16, 2026');
      expect(byName.keys, contains('Desvenlafaxine Succinate ER'));
      expect(byName['Desvenlafaxine Succinate ER']?['isPresent'], isTrue);
    });
  });
}
