import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/tools/body_info_screen.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';
import 'package:tabs_lab/src/features/tools/project_focus_screen.dart';

import 'test_helpers.dart';

/// Round 48 fix round, seat α — Vera F1/F2-med/F3/F7 regression
/// tests for Medications + Project Focus:
///
/// - F1 (Medications): a profile push re-pulls the freshest blob
///   and splices into it — a med added server-side after the
///   screen opened survives an archive push (deep-equal).
/// - F1 (Project Focus): a check-in push is built from the fresh
///   blob — a server-side focus change after load is not
///   reverted, and unknown blob keys survive.
/// - F1 (Project Focus): flow-step and check-in pushes cannot
///   interleave — all pushes serialize through the one push
///   chain (blocking-backend technique from tools_r48d_test).
/// - F2 (med half): a med-take whose entries pull FAILED posts
///   zero entries and shows a visible error, instead of
///   computing max+1 ids / dedupe from a flattened empty list.
/// - F3: a med-take entry satisfies BOTH readers — Today Summary
///   (`buildTodayPlan` → TAKEN) and Body Info
///   (`evaluateBodyImpacts` → a SYSTEMIC dose impact with the
///   frequency-correct active window).

const medCategory = QuickLogCategory(
  id: 8,
  name: 'Medication',
  icon: 'pill',
  colorHex: '#7C6EFF',
  isDefault: true,
  sortOrder: 0,
);

final _now = DateTime(2026, 10, 13, 9, 30);

Map<String, dynamic> medRow({
  required String id,
  required String name,
  String startDate = 'Sep 1, 2026',
  String endDate = 'Present',
  dynamic isPresent = true,
  String dose = '10mg',
  String frequency = 'Daily',
  dynamic updatedAt = 1000,
  dynamic isDeleted = false,
}) =>
    {
      'id': id,
      'name': name,
      'startDate': startDate,
      'endDate': endDate,
      'isPresent': isPresent,
      'dose': dose,
      'frequency': frequency,
      'updatedAt': updatedAt,
      'isDeleted': isDeleted,
    };

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A Medications backend that models the SERVER: profile reads
/// are built from the current server rows, a successful profile
/// post REPLACES the server rows with the pushed blob, and the
/// sync pull can be switched to failing (Vera F2) while profile
/// reads keep working.
class _MedServerBackend extends TabsBackend {
  _MedServerBackend({
    required List<Map<String, dynamic>> rows,
    List<QuickLogEntry>? entries,
  })  : serverRows = rows,
        entries = entries ?? [],
        super(sessionStore: FakeSessionStore()..token = 'tok');

  List<Map<String, dynamic>> serverRows;
  List<QuickLogEntry> entries;
  final List<List<QuickLogEntry>> entryPosts = [];
  final List<Map<String, dynamic>> profilePosts = [];
  bool profilePostResult = true;
  bool syncPullFails = false;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async =>
      {'medications': jsonEncode(serverRows)};

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async {
    if (syncPullFails) return null;
    return {
      'profile': {'medications': jsonEncode(serverRows)},
      'entries': [for (final e in entries) e.toSyncJson()],
      'categories': [medCategory.toSyncJson()],
    };
  }

  @override
  Future<bool> postLogEntries(List<QuickLogEntry> posted) async {
    entryPosts.add(posted);
    entries = [...entries, ...posted];
    return true;
  }

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePosts.add(fields);
    if (profilePostResult && fields.containsKey('medications')) {
      serverRows = (jsonDecode(fields['medications'] as String) as List)
          .cast<Map<String, dynamic>>();
    }
    return profilePostResult;
  }

  @override
  void invalidateSyncPull() {}
}

/// A Project Focus backend that models the SERVER the same way,
/// with a gate that can hold a profile post in flight.
class _FocusServerBackend extends TabsBackend {
  _FocusServerBackend({required this.serverBlob})
      : super(sessionStore: FakeSessionStore()..token = 'tok');

  Map<String, dynamic> serverBlob;

  /// Decoded focus blobs, in the order posts STARTED.
  final List<Map<String, dynamic>> profilePosts = [];
  Completer<void>? postGate;
  bool postResult = true;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async =>
      {'focusState': jsonEncode(serverBlob)};

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    final blob =
        jsonDecode(fields['focusState'] as String) as Map<String, dynamic>;
    profilePosts.add(blob);
    final gate = postGate;
    if (gate != null) await gate.future;
    if (postResult) serverBlob = blob;
    return postResult;
  }

  @override
  void invalidateSyncPull() {}
}

Map<String, dynamic> focusTestJson({
  required String id,
  required String title,
  required DateTime start,
  Map<String, bool> logs = const {},
}) =>
    {
      'id': id,
      'title': title,
      'desc': 'desc for $title',
      'durationDays': 7,
      'startTimestamp': start.millisecondsSinceEpoch,
      'lockDayStr': null,
      'logs': logs,
      'measureMetric': 'sleepMins',
    };

void main() {
  group('r48fix-a medications (Vera F1)', () {
    testWidgets(
        'archive push re-pulls: a med added to the server blob after load survives (deep-equal on the pushed blob)',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final rows = [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
        medRow(id: 'pyr-1', name: 'Pyridostigmine', dose: '60mg'),
      ];
      final backend = _MedServerBackend(rows: rows);
      await tester.pumpWidget(
          MaterialApp(home: MedicationsScreen(backend: backend)));
      await tester.pumpAndSettle();
      expect(find.text('2 Active Medication(s)'), findsOneWidget);

      // A med lands on the server AFTER the screen opened.
      final addedRow =
          medRow(id: 'mid-1', name: 'Midodrine', dose: '5mg', updatedAt: 2222);
      backend.serverRows = [...rows, addedRow];

      await tester.tap(find.byKey(const ValueKey('archive_med_at_0')));
      await tester.pumpAndSettle();

      expect(backend.profilePosts, hasLength(1));
      final pushed =
          (jsonDecode(backend.profilePosts.single['medications'] as String)
                  as List)
              .cast<Map<String, dynamic>>();
      expect(pushed, hasLength(3));
      // The target was archived in the FRESH document…
      final iva = pushed.singleWhere((r) => r['name'] == 'Ivabradine');
      expect(iva['isPresent'], isFalse);
      expect(iva['endDate'], formatMedArchiveDate(DateTime.now()));
      // …the untouched row is deep-equal…
      expect(pushed.singleWhere((r) => r['name'] == 'Pyridostigmine'),
          rows[1]);
      // …and the server-side addition survives byte-for-byte:
      // a push built from the load-time snapshot would have
      // silently deleted it.
      expect(pushed.singleWhere((r) => r['name'] == 'Midodrine'), addedRow);
      // The screen now renders the fresh state (2 active:
      // Pyridostigmine + the newly arrived Midodrine).
      expect(find.text('2 Active Medication(s)'), findsOneWidget);
      expect(find.text('Archived Medications (1)'), findsOneWidget);
    });
  });

  group('r48fix-a project focus (Vera F1)', () {
    Future<_FocusServerBackend> pumpFocus(
        WidgetTester tester, Map<String, dynamic> blob) async {
      final backend = _FocusServerBackend(serverBlob: blob);
      await tester.pumpWidget(
          MaterialApp(home: ProjectFocusScreen(backend: backend)));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets(
        'check-in push is built from the fresh blob: a server-side focus change after load is not reverted',
        (tester) async {
      final start = DateTime.now().subtract(const Duration(days: 2));
      final test1 = focusTestJson(id: 'test_1', title: 'First test', start: start);
      final backend = await pumpFocus(tester, {
        'activeTests': [test1],
        'activeTest': test1,
        'selectedTestId': 'test_1',
        'currentSubView': 'details',
        'ownerKey': 'keep-me',
      });
      expect(find.text('Yes, I did it'), findsOneWidget);

      // Server-side change after load: a second test appears and
      // a new unknown key lands in the blob.
      final test2 =
          focusTestJson(id: 'test_2', title: 'Second test', start: start);
      backend.serverBlob = {
        'activeTests': [test1, test2],
        'activeTest': test1,
        'selectedTestId': 'test_1',
        'currentSubView': 'details',
        'ownerKey': 'keep-me',
        'serverNote': {'origin': 'web'},
      };

      await tester.tap(find.text('Yes, I did it'));
      await tester.pumpAndSettle();

      expect(backend.profilePosts, hasLength(1));
      final pushed = backend.profilePosts.single;
      final tests = (pushed['activeTests'] as List)
          .cast<Map<String, dynamic>>();
      expect(tests, hasLength(2));
      final today = _dateStr(DateTime.now());
      final pushedTest1 =
          tests.singleWhere((t) => t['id'] == 'test_1');
      expect(pushedTest1['logs'], {today: true});
      // The server-added test survives the check-in push, and so
      // do keys this screen does not own.
      final pushedTest2 =
          tests.singleWhere((t) => t['id'] == 'test_2');
      expect(pushedTest2['title'], 'Second test');
      expect(pushedTest2['logs'], <String, dynamic>{});
      expect(pushed['ownerKey'], 'keep-me');
      expect(pushed['serverNote'], {'origin': 'web'});
      expect(find.text('Response logged for today!'), findsOneWidget);
    });

    testWidgets(
        'flow-step push and check-in push cannot interleave (serialization)',
        (tester) async {
      final start = DateTime.now().subtract(const Duration(days: 2));
      final test1 = focusTestJson(id: 'test_1', title: 'First test', start: start);
      final backend = await pumpFocus(tester, {
        'activeTests': [test1],
        'activeTest': test1,
        'selectedTestId': 'test_1',
        'currentSubView': 'details',
      });
      final gate = Completer<void>();
      backend.postGate = gate;

      // Start the check-in push and let it reach the gated post.
      await tester.tap(find.text('Yes, I did it'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(backend.profilePosts, hasLength(1));

      // Trigger a flow-step push (app-bar "Create Project" →
      // _setSubView → _pushFlowStep) while the check-in post is
      // still in flight. It must NOT start a second post.
      await tester.tap(find.text('Create Project'));
      await tester.pump();
      await tester.pump();
      expect(backend.profilePosts, hasLength(1));

      gate.complete();
      backend.postGate = null;
      await tester.pumpAndSettle();

      // After the gate released, the flow-step push ran — second,
      // in order — and, being built from the fresh blob, it did
      // NOT revert the check-in that landed before it.
      expect(backend.profilePosts, hasLength(2));
      final today = _dateStr(DateTime.now());
      final first = backend.profilePosts[0];
      expect(first['currentSubView'], 'details');
      expect(
          ((first['activeTests'] as List).single
              as Map<String, dynamic>)['logs'],
          {today: true});
      final second = backend.profilePosts[1];
      expect(second['currentSubView'], 'input');
      expect(
          ((second['activeTests'] as List).single
              as Map<String, dynamic>)['logs'],
          {today: true});
      expect(find.text('What are you trying to work towards?'),
          findsOneWidget);
    });
  });

  group('r48fix-a med-take pull failure (Vera F2, med half)', () {
    testWidgets(
        'failed entries pull → zero entry posts + visible error',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final backend = _MedServerBackend(rows: [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
      ]);
      await tester.pumpWidget(
          MaterialApp(home: MedicationsScreen(backend: backend)));
      await tester.pumpAndSettle();
      expect(find.text('1 Active Medication(s)'), findsOneWidget);

      // The entries pull now actually fails (the sync pull
      // behind it returns nothing) — indistinguishable from an
      // empty log through the old flattened fetch.
      backend.syncPullFails = true;
      await tester.tap(find.byKey(const ValueKey('took_med_at_0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(
          find.text(
              'Could not log that dose. Check your connection and try again.'),
          findsOneWidget);
      // Nothing was posted — no id-1 entry computed from a
      // phantom empty list, no success copy.
      expect(backend.entryPosts, isEmpty);
      expect(find.text('Logged 1 dose of Ivabradine (7.5mg)'),
          findsNothing);
    });

    test('fetchLogEntryDtosOrNull distinguishes failure from empty',
        () async {
      final backend = _MedServerBackend(rows: const []);
      // A real, successful empty pull is non-null…
      expect(await backend.fetchLogEntryDtosOrNull(), isEmpty);
      expect(await backend.fetchLogEntryDtosOrNull(), isNotNull);
      // …and a failed pull is null.
      backend.syncPullFails = true;
      expect(await backend.fetchLogEntryDtosOrNull(), isNull);
    });
  });

  group('r48fix-a med-take entry satisfies BOTH readers (Vera F3)', () {
    MedicationEntry med({
      required String name,
      required String dose,
      required String frequency,
    }) =>
        MedicationEntry(
          id: 'm-$name',
          name: name,
          dose: dose,
          frequency: frequency,
          startDate: 'Sep 1, 2026',
          endDate: 'Present',
          isPresent: true,
        );

    test('Today reader: buildTodayPlan resolves the take as TAKEN', () {
      final built = buildMedTakeLogEntries(
        meds: [
          med(name: 'Ivabradine', dose: '7.5mg', frequency: 'Twice daily'),
        ],
        existingEntries: const [],
        categories: const [medCategory],
        now: _now,
      )!;
      final e = built.single;
      // The pinned dual-reader shape.
      expect(e.body, 'Took Ivabradine 7.5mg');
      expect(e.chips, '["Medication Tab"]');
      expect(
          e.manualText,
          'Logged from Medications tab. Took Medication: '
          'Ivabradine 7.5mg (1 dose - Twice daily)');

      final plan = buildTodayPlan(
        medications: [
          SummaryMedication.fromBlobRow(
              medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'))!,
        ],
        reminders: const [],
        habits: const [],
        localState: const TodayPlanLocalState(),
        entries: built,
        medicationCategoryId: 8,
        now: _now,
      );
      expect(plan.plannedCount, 1);
      expect(plan.remainingCount, 0);
      expect(plan.items, isEmpty);
    });

    test(
        'Body Info reader: gate passes and the dose impact carries the frequency-correct window',
        () {
      QuickLogEntry takeFor(String frequency) => buildMedTakeLogEntries(
            meds: [
              med(name: 'Ivabradine', dose: '7.5mg', frequency: frequency),
            ],
            existingEntries: const [],
            categories: const [medCategory],
            now: _now,
          )!
              .single;

      void expectWindow(String frequency, int minutes) {
        final entry = takeFor(frequency);
        expect(isMedTabEntry(entry), isTrue,
            reason: 'gate must pass for $frequency');
        final impacts =
            evaluateBodyImpacts([entry], _now.millisecondsSinceEpoch);
        final dose = impacts
            .where((i) => i.regionId == 'SYSTEMIC')
            .toList();
        expect(dose, hasLength(1), reason: 'one dose impact for $frequency');
        expect(dose.single.durationMinutes, minutes,
            reason: 'window for $frequency');
        // The name extraction yields native's "{name} {dose}"
        // (not the whole "Took …" body / manual marker chain).
        expect(dose.single.regionName, 'Systemic (Ivabradine 7.5mg)');
        expect(dose.single.details, contains('Ivabradine (7.5mg active)'));
      }

      expectWindow('Twice daily', 12 * 60);
      expectWindow('Once daily', 24 * 60);
      expectWindow('3x daily', 8 * 60);
      expectWindow('Four times daily', 6 * 60);
    });
  });
}
