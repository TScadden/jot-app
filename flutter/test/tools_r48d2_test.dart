import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'test_helpers.dart';

/// Round 48D2 — Medications screen completion: the actions the
/// Group D re-audit found still disabled are wired to native.
///
/// Native trace pinned here:
/// - "Took Med": `MedicationsViewModel.takeSingleMedication` —
///   logs 1 dose; its own entry body ("Took Medication: …") is
///   NOT the shape Today's evidence reader matches, so the
///   Flutter port writes the coherent Today shape
///   (`ScheduledDoseRepository.recordDoseAction`: body
///   "Took {name} {dose}", category Medication/8, chips "[]",
///   manualText "") — see the dose-logging trace in
///   `data/medications.dart`. Dedupe is recordDoseAction's
///   idempotency rule: one standing uncorrected "Took …" entry
///   per med per day; a second tap posts nothing.
/// - "Took All Meds": native HAS it
///   (`takeAllMedications`: 1 dose per active med), enabled
///   only when every active med is dose-valid.
/// - "Add Medication": the R46 dialog in add mode (native title
///   "Add New Medication"); native `addMedication` appends one
///   row with a fresh UUID, `endDate "Present"`, `isPresent`.
/// - Archived delete: native's archived card has a delete icon
///   with NO confirmation; the pushed blob loses exactly that
///   row (native Settings delete drops the row and pushes the
///   full remaining list; the Medications tombstone never
///   reaches the cloud blob).

const medCategory = QuickLogCategory(
  id: 8,
  name: 'Medication',
  icon: 'pill',
  colorHex: '#7C6EFF',
  isDefault: true,
  sortOrder: 0,
);

final _now = DateTime(2026, 10, 13, 9, 30);

MedicationEntry medEntry({
  String id = 'm1',
  required String name,
  String dose = '10mg',
  String frequency = 'Daily',
  String startDate = 'Sep 1, 2026',
}) =>
    MedicationEntry(
      id: id,
      name: name,
      dose: dose,
      frequency: frequency,
      startDate: startDate,
      endDate: 'Present',
      isPresent: true,
    );

QuickLogEntry logEntry({
  int id = 1,
  int categoryId = 8,
  required String body,
  required DateTime at,
}) =>
    QuickLogEntry(
      id: id,
      categoryId: categoryId,
      body: body,
      chips: '[]',
      manualText: '',
      timestamp: at.millisecondsSinceEpoch,
    );

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

/// Recording fake: canned profile, simulated entry store (a
/// successful post makes the entries stand, like the server),
/// captured profile pushes, switchable results, and a gate to
/// hold an entries post in flight.
class MedsBackend extends TabsBackend {
  MedsBackend({
    required this.profile,
    List<QuickLogEntry>? entries,
    List<QuickLogCategory>? categories,
  })  : entries = entries ?? [],
        categories = categories ?? const [medCategory],
        super(sessionStore: FakeSessionStore()..token = 'tok');

  Map<String, dynamic>? profile;
  List<QuickLogEntry> entries;
  List<QuickLogCategory> categories;
  final List<List<QuickLogEntry>> entryPosts = [];
  final List<Map<String, dynamic>> profilePosts = [];
  bool entryPostResult = true;
  bool profilePostResult = true;
  Completer<void>? entryGate;
  int invalidateCount = 0;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async => profile;

  @override
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async => entries;

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => categories;

  @override
  Future<bool> postLogEntries(List<QuickLogEntry> posted) async {
    entryPosts.add(posted);
    final gate = entryGate;
    if (gate != null) await gate.future;
    if (entryPostResult) entries = [...entries, ...posted];
    return entryPostResult;
  }

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePosts.add(fields);
    return profilePostResult;
  }

  @override
  void invalidateSyncPull() {
    invalidateCount++;
  }
}

List<Map<String, dynamic>> pushedMedRows(MedsBackend backend) {
  final posts = backend.profilePosts
      .where((p) => p.containsKey('medications'))
      .toList();
  expect(posts, hasLength(1));
  return (jsonDecode(posts.single['medications'] as String) as List)
      .cast<Map<String, dynamic>>();
}

void main() {
  group('buildMedTakeLogEntries: payload (Today take shape)', () {
    test('body/category/chips/manualText/timestamp + max+1 id', () {
      final existing = [
        logEntry(id: 41, body: 'Felt dizzy', at: _now),
        // The max id is over ALL entries, not just today's.
        logEntry(
            id: 57,
            body: 'Old entry',
            at: _now.subtract(const Duration(days: 3))),
      ];
      final out = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Ivabradine', dose: '7.5mg')],
        existingEntries: existing,
        categories: const [medCategory],
        now: _now,
      )!;
      final e = out.single;
      expect(e.id, 58);
      expect(e.categoryId, 8);
      expect(e.body, 'Took Ivabradine 7.5mg');
      expect(e.chips, '[]');
      expect(e.manualText, '');
      expect(e.timestamp, _now.millisecondsSinceEpoch);
      // The sync payload carries the same fields (updatedAt is
      // stamped by toSyncJson itself).
      final sync = e.toSyncJson();
      expect(sync['id'], 58);
      expect(sync['categoryId'], 8);
      expect(sync['body'], 'Took Ivabradine 7.5mg');
      expect(sync['chips'], '[]');
      expect(sync['manualText'], '');
      expect(sync['timestamp'], _now.millisecondsSinceEpoch);
    });

    test('category resolves by NAME before the seeded-id fallback', () {
      final out = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Ivabradine')],
        existingEntries: const [],
        categories: const [
          QuickLogCategory(
              id: 42,
              name: 'Medication',
              icon: '',
              colorHex: '',
              isDefault: false,
              sortOrder: 0),
        ],
        now: _now,
      )!;
      expect(out.single.categoryId, 42);
    });

    test('category falls back to the seeded Medication id 8', () {
      final out = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Ivabradine')],
        existingEntries: const [],
        categories: const [
          QuickLogCategory(
              id: 8,
              name: 'Meds',
              icon: '',
              colorHex: '',
              isDefault: true,
              sortOrder: 0),
        ],
        now: _now,
      )!;
      expect(out.single.categoryId, 8);
    });

    test('unresolvable category → null (caller posts nothing)', () {
      expect(
        buildMedTakeLogEntries(
          meds: [medEntry(name: 'Ivabradine')],
          existingEntries: const [],
          categories: const [],
          now: _now,
        ),
        isNull,
      );
      expect(
        buildMedTakeLogEntries(
          meds: [medEntry(name: 'Ivabradine')],
          existingEntries: const [],
          categories: const [
            QuickLogCategory(
                id: 3,
                name: 'Symptoms',
                icon: '',
                colorHex: '',
                isDefault: true,
                sortOrder: 0),
          ],
          now: _now,
        ),
        isNull,
      );
    });

    test('blank dose writes "Took {name}" with no trailing space', () {
      expect(medTakeEntryBody(medEntry(name: 'Ivabradine', dose: '')),
          'Took Ivabradine');
      expect(medTakeEntryBody(medEntry(name: 'Ivabradine', dose: ' 5mg ')),
          'Took Ivabradine 5mg');
    });
  });

  group('buildMedTakeLogEntries: per-day dedupe (recordDoseAction rule)',
      () {
    test('a standing "Took …" entry today → nothing to post', () {
      final out = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Ivabradine', dose: '7.5mg')],
        existingEntries: [
          logEntry(id: 9, body: 'Took Ivabradine 7.5mg', at: _now),
        ],
        categories: const [medCategory],
        now: _now,
      )!;
      expect(out, isEmpty);
    });

    test(
        'vice versa: an entry in the Today shape (as Today Summary writes it) dedupes a Medications tap',
        () {
      // Today's take writes exactly this shape; the Medications
      // screen must read it as already-taken, not double-log.
      final out = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Pyridostigmine', dose: '60mg')],
        existingEntries: [
          logEntry(id: 9, body: 'Took Pyridostigmine 60mg', at: _now),
        ],
        categories: const [medCategory],
        now: _now,
      )!;
      expect(out, isEmpty);
    });

    test('yesterday\'s "Took …" entry does NOT dedupe today', () {
      final out = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Ivabradine', dose: '7.5mg')],
        existingEntries: [
          logEntry(
              id: 9,
              body: 'Took Ivabradine 7.5mg',
              at: _now.subtract(const Duration(days: 1))),
        ],
        categories: const [medCategory],
        now: _now,
      )!;
      expect(out.single.body, 'Took Ivabradine 7.5mg');
      expect(out.single.id, 10);
    });

    test('a "Took …" entry in ANOTHER category does NOT dedupe', () {
      final out = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Ivabradine', dose: '7.5mg')],
        existingEntries: [
          logEntry(
              id: 9,
              categoryId: 1,
              body: 'Took Ivabradine 7.5mg',
              at: _now),
        ],
        categories: const [medCategory],
        now: _now,
      )!;
      expect(out, hasLength(1));
    });

    test(
        'a corrected-to-skipped entry does NOT block a take (native Today: skip nulls the log id, a later take posts fresh)',
        () {
      final out = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Ivabradine', dose: '7.5mg')],
        existingEntries: [
          logEntry(
              id: 9,
              body: '[Corrected to Skipped] Took Ivabradine 7.5mg',
              at: _now),
        ],
        categories: const [medCategory],
        now: _now,
      )!;
      expect(out.single.body, 'Took Ivabradine 7.5mg');
    });

    test(
        'Took All coverage: one entry per untaken med, order preserved, ids sequential from max+1',
        () {
      final out = buildMedTakeLogEntries(
        meds: [
          medEntry(id: 'a', name: 'Ivabradine', dose: '7.5mg'),
          medEntry(id: 'b', name: 'Pyridostigmine', dose: '60mg'),
          medEntry(id: 'c', name: 'Midodrine', dose: '5mg'),
        ],
        existingEntries: [
          logEntry(id: 20, body: 'Took Pyridostigmine 60mg', at: _now),
        ],
        categories: const [medCategory],
        now: _now,
      )!;
      expect(out.map((e) => e.body),
          ['Took Ivabradine 7.5mg', 'Took Midodrine 5mg']);
      expect(out.map((e) => e.id), [21, 22]);
    });

    test(
        'batch-internal dedupe: two same-name rows share one evidence entry (the Today reader is name-based)',
        () {
      final out = buildMedTakeLogEntries(
        meds: [
          medEntry(id: 'a', name: 'Ivabradine', dose: '7.5mg'),
          medEntry(id: 'b', name: 'Ivabradine', dose: '10mg'),
        ],
        existingEntries: const [],
        categories: const [medCategory],
        now: _now,
      )!;
      expect(out, hasLength(1));
      expect(out.single.body, 'Took Ivabradine 7.5mg');
    });
  });

  group('coherence: a dose logged here reads TAKEN in Today Summary',
      () {
    test('buildTodayPlan resolves the med from the built entry', () {
      final built = buildMedTakeLogEntries(
        meds: [medEntry(name: 'Ivabradine', dose: '7.5mg')],
        existingEntries: const [],
        categories: const [medCategory],
        now: _now,
      )!;
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
      // Taken items never render in the plan (R41 rule).
      expect(plan.items, isEmpty);
      expect(plan.summaryText, 'Everything planned for today is complete');
      // And the shared reader agrees directly.
      expect(
        medTakenFromEntries(
          medName: 'Ivabradine',
          todayEntries: built,
          medicationCategoryId: 8,
        ),
        isTrue,
      );
    });
  });

  group('MedicationDocument add (native addMedication)', () {
    test('appends exactly one row; every existing row deep-equal', () {
      final rows = [
        medRow(id: 'a', name: 'Ivabradine', dose: '7.5mg'),
        // An unparseable raw row rides along verbatim.
        {'name': '', 'mystery': true},
        medRow(
            id: 'c',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
      ];
      final doc = MedicationDocument.fromRawRows(rows);
      final updated = doc.addEntry(
        name: 'Midodrine',
        dose: '5mg',
        frequency: 'Once daily',
        startDate: 'Oct 1, 2026',
        id: 'new-uuid',
        now: _now,
      );
      final out = updated.encode();
      expect(out, hasLength(4));
      expect(out[0], rows[0]);
      expect(out[1], rows[1]);
      expect(out[2], rows[2]);
      final added = out[3];
      expect(added['id'], 'new-uuid');
      expect(added['name'], 'Midodrine');
      expect(added['dose'], '5mg');
      expect(added['frequency'], 'Once daily');
      expect(added['startDate'], 'Oct 1, 2026');
      expect(added['endDate'], 'Present');
      expect(added['isPresent'], isTrue);
      expect(added['isDeleted'], isFalse);
      expect(added['updatedAt'], _now.millisecondsSinceEpoch);
      // The original document is untouched (pure op).
      expect(doc.encode(), hasLength(3));
      // The new row classifies active everywhere.
      expect(updated.activeIndices, contains(3));
    });

    test('add on an empty document yields the single active row', () {
      final updated = MedicationDocument.empty.addEntry(
        name: 'Midodrine',
        dose: '5mg',
        frequency: 'Once daily',
        startDate: '',
        id: 'u1',
        now: _now,
      );
      expect(updated.encode(), hasLength(1));
      expect(updated.activeIndices, [0]);
      expect(updated.encode().single['startDate'], '');
    });
  });

  group('MedicationDocument delete (archived permanent delete)', () {
    test('removes exactly that row; the rest deep-equal, order kept',
        () {
      final rows = [
        medRow(id: 'a', name: 'Ivabradine'),
        medRow(
            id: 'c',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
        {'name': '', 'mystery': true},
        medRow(
            id: 'd',
            name: 'Old Med',
            isPresent: false,
            endDate: 'Jan 3, 2026'),
      ];
      final doc = MedicationDocument.fromRawRows(rows);
      final updated = doc.deleteEntry(doc.entryAt(1)!);
      final out = updated.encode();
      expect(out, hasLength(3));
      expect(out[0], rows[0]);
      expect(out[1], rows[2]); // unparseable row preserved verbatim
      expect(out[2], rows[3]);
      expect(updated.archivedIndices, [2]);
      expect(updated.activeIndices, [0]);
      expect(doc.encode(), hasLength(4)); // original untouched
    });

    test(
        'identity targeting: deleting the SECOND of two id-less duplicate archived names leaves the first byte-untouched',
        () {
      final rows = [
        medRow(
            id: '',
            name: 'Duplex',
            dose: '10mg',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
        medRow(
            id: '',
            name: 'Duplex',
            dose: '20mg',
            isPresent: false,
            endDate: 'Sep 9, 2026'),
      ];
      final doc = MedicationDocument.fromRawRows(rows);
      final out = doc.deleteEntry(doc.entryAt(1)!).encode();
      expect(out, hasLength(1));
      expect(out.single, rows[0]);
    });

    test('unresolvable target refuses: document unchanged', () {
      final doc = MedicationDocument.fromRawRows([
        medRow(id: 'a', name: 'Ivabradine'),
      ]);
      final out = doc.deleteEntry(MedicationEntry(id: 'nope', name: 'Ghost'));
      expect(identical(out, doc), isTrue);
    });
  });

  group('generateMedicationUuid', () {
    test('RFC 4122 v4 shape', () {
      final re = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      for (var i = 0; i < 20; i++) {
        expect(generateMedicationUuid(), matches(re));
      }
      expect(generateMedicationUuid() == generateMedicationUuid(), isFalse);
    });
  });

  group('MedicationsScreen R48D2 actions', () {
    Future<MedsBackend> pumpScreen(
        WidgetTester tester, List<Map<String, dynamic>> rows,
        {MedsBackend Function(MedsBackend)? configure}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var backend = MedsBackend(profile: {'medications': jsonEncode(rows)});
      if (configure != null) backend = configure(backend);
      await tester.pumpWidget(
          MaterialApp(home: MedicationsScreen(backend: backend)));
      await tester.pumpAndSettle();
      return backend;
    }

    Future<void> expectSnack(WidgetTester tester, String text) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text(text), findsOneWidget);
    }

    testWidgets(
        'Took Med posts the Today-shaped entry and shows native\'s status',
        (tester) async {
      final backend = await pumpScreen(tester, [
        medRow(
            id: 'iva-1',
            name: 'Ivabradine',
            dose: '7.5mg',
            frequency: 'Twice daily'),
      ], configure: (b) {
        b.entries = [
          logEntry(
              id: 41,
              body: 'Unrelated',
              at: DateTime.now().subtract(const Duration(days: 2))),
        ];
        return b;
      });

      await tester.tap(find.byKey(const ValueKey('took_med_at_0')));
      await expectSnack(tester, 'Logged 1 dose of Ivabradine (7.5mg)');

      expect(backend.entryPosts, hasLength(1));
      final e = backend.entryPosts.single.single;
      expect(e.id, 42);
      expect(e.categoryId, 8);
      expect(e.body, 'Took Ivabradine 7.5mg');
      expect(e.chips, '[]');
      expect(e.manualText, '');
      expect(backend.profilePosts, isEmpty); // no med-record write
    });

    testWidgets('second tap the same day does NOT double-post',
        (tester) async {
      final backend = await pumpScreen(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
      ]);
      await tester.tap(find.byKey(const ValueKey('took_med_at_0')));
      await tester.pumpAndSettle();
      expect(backend.entryPosts, hasLength(1));

      // The fake made the posted entry stand (as the server
      // would); the second tap re-reads it and dedupes.
      await tester.tap(find.byKey(const ValueKey('took_med_at_0')));
      await expectSnack(tester, 'Already logged today');
      expect(backend.entryPosts, hasLength(1));
    });

    testWidgets(
        'Took Med failure → visible error, no success claimed',
        (tester) async {
      final backend = await pumpScreen(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
      ], configure: (b) => b..entryPostResult = false);

      await tester.tap(find.byKey(const ValueKey('took_med_at_0')));
      await expectSnack(tester,
          'Could not log that dose. Check your connection and try again.');
      expect(backend.entryPosts, hasLength(1)); // attempted once
      expect(find.text('Logged 1 dose of Ivabradine (7.5mg)'),
          findsNothing);
    });

    testWidgets(
        'unresolvable Medication category → error and NOTHING is posted',
        (tester) async {
      final backend = await pumpScreen(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
      ], configure: (b) => b..categories = const []);

      await tester.tap(find.byKey(const ValueKey('took_med_at_0')));
      await expectSnack(tester,
          'Could not log that dose. Check your connection and try again.');
      expect(backend.entryPosts, isEmpty);
    });

    testWidgets(
        'Took All posts one entry per med in one call, native status copy',
        (tester) async {
      final backend = await pumpScreen(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
        medRow(
            id: 'pyr-1',
            name: 'Pyridostigmine',
            dose: '60mg',
            frequency: '3x daily'),
      ], configure: (b) {
        b.entries = [logEntry(id: 5, body: 'Earlier', at: DateTime.now())];
        return b;
      });

      await tester.tap(find.byKey(const ValueKey('took_all_meds')));
      await expectSnack(
          tester, 'Logged 1 dose for all 2 medication(s)!');

      expect(backend.entryPosts, hasLength(1));
      final posted = backend.entryPosts.single;
      expect(posted.map((e) => e.body),
          ['Took Ivabradine 7.5mg', 'Took Pyridostigmine 60mg']);
      expect(posted.map((e) => e.id), [6, 7]);
    });

    testWidgets(
        'enable rules: an invalid dose disables its Took Med AND Took All (native), with the native warning',
        (tester) async {
      await pumpScreen(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
        medRow(id: 'bad-1', name: 'Mystery', dose: 'As prescribed'),
      ]);
      final tookValid = tester.widget<ElevatedButton>(
          find.byKey(const ValueKey('took_med_at_0')));
      expect(tookValid.onPressed, isNotNull);
      final tookInvalid = tester.widget<ElevatedButton>(
          find.byKey(const ValueKey('took_med_at_1')));
      expect(tookInvalid.onPressed, isNull);
      final tookAll = tester.widget<ElevatedButton>(
          find.byKey(const ValueKey('took_all_meds')));
      expect(tookAll.onPressed, isNull);
      expect(
          find.text(
              "⚠️ Fill out dose and date started below to unlock 'Took Med' logging."),
          findsOneWidget);
    });

    testWidgets(
        'dose logging is serialized under the writing guard: an archive during a pending dose post is dropped',
        (tester) async {
      final backend = await pumpScreen(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
        medRow(id: 'pyr-1', name: 'Pyridostigmine', dose: '60mg'),
      ]);
      final gate = Completer<void>();
      backend.entryGate = gate;

      await tester.tap(find.byKey(const ValueKey('took_med_at_0')));
      await tester.pump();
      await tester.pump();
      expect(backend.entryPosts, hasLength(1));

      final archive = tester.widget<IconButton>(
          find.byKey(const ValueKey('archive_med_at_1')));
      expect(archive.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('archive_med_at_1')));
      await tester.pump();
      expect(backend.profilePosts, isEmpty);

      gate.complete();
      backend.entryGate = null;
      await tester.pumpAndSettle();

      // The guard released: archiving now pushes.
      await tester.tap(find.byKey(const ValueKey('archive_med_at_1')));
      await tester.pumpAndSettle();
      expect(backend.profilePosts, hasLength(1));
    });

    testWidgets(
        'Add Medication: dialog in add mode appends exactly one row, others deep-equal',
        (tester) async {
      final rows = [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
        medRow(
            id: 'car-1',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
      ];
      final backend = await pumpScreen(tester, rows);

      await tester.tap(find.byKey(const ValueKey('add_medication')));
      await tester.pumpAndSettle();
      expect(find.text('Add New Medication'), findsOneWidget);
      expect(find.text('Edit Medication'), findsNothing);
      // Native add seeds: frequency prefilled, no ended-date field.
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('med_edit_frequency')))
              .controller!
              .text,
          'Once daily');
      expect(find.byKey(const ValueKey('med_edit_end')), findsNothing);
      // Save is disabled until name AND dose are present.
      final saveBefore = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Save Medication'));
      expect(saveBefore.onPressed, isNull);

      await tester.enterText(
          find.byKey(const ValueKey('med_edit_name')), 'Midodrine');
      await tester.enterText(
          find.byKey(const ValueKey('med_edit_dose')), '5mg');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Medication'));
      await tester.pumpAndSettle();

      final out = pushedMedRows(backend);
      expect(out, hasLength(3));
      expect(out[0], rows[0]);
      expect(out[1], rows[1]);
      final added = out[2];
      expect(added['name'], 'Midodrine');
      expect(added['dose'], '5mg');
      expect(added['frequency'], 'Once daily');
      expect(added['startDate'], '');
      expect(added['endDate'], 'Present');
      expect(added['isPresent'], isTrue);
      expect(added['isDeleted'], isFalse);
      expect(added['updatedAt'], greaterThan(1000));
      expect(
          '${added['id']}',
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(find.text('Midodrine'), findsOneWidget);
      expect(find.text('2 Active Medication(s)'), findsOneWidget);
    });

    testWidgets(
        'Add failure → SnackBar and the new med does NOT stay on screen (server reload)',
        (tester) async {
      final backend = await pumpScreen(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
      ], configure: (b) => b..profilePostResult = false);

      await tester.tap(find.byKey(const ValueKey('add_medication')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('med_edit_name')), 'Midodrine');
      await tester.enterText(
          find.byKey(const ValueKey('med_edit_dose')), '5mg');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Medication'));
      await expectSnack(tester,
          'Could not save that change. Check your connection and try again.');
      await tester.pumpAndSettle();
      expect(find.text('Midodrine'), findsNothing);
      expect(find.text('1 Active Medication(s)'), findsOneWidget);
      expect(backend.profilePosts, hasLength(1));
    });

    testWidgets(
        'archived delete: NO confirmation, exactly that row removed from the push',
        (tester) async {
      final rows = [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
        medRow(
            id: 'car-1',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
        medRow(
            id: 'old-1',
            name: 'Old Med',
            isPresent: false,
            endDate: 'Jan 3, 2026'),
      ];
      final backend = await pumpScreen(tester, rows);
      expect(find.text('Archived Medications (2)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('delete_med_at_1')));
      await tester.pumpAndSettle();
      // No confirmation dialog was shown at any point.
      expect(find.byType(AlertDialog), findsNothing);

      final out = pushedMedRows(backend);
      expect(out, hasLength(2));
      expect(out[0], rows[0]);
      expect(out[1], rows[2]);
      expect(find.text('Carvedilol'), findsNothing);
      expect(find.text('Archived Medications (1)'), findsOneWidget);
    });

    testWidgets(
        'archived delete failure → SnackBar, reload keeps the med on screen',
        (tester) async {
      final backend = await pumpScreen(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
        medRow(
            id: 'car-1',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
      ], configure: (b) => b..profilePostResult = false);

      await tester.tap(find.byKey(const ValueKey('delete_med_at_1')));
      await expectSnack(tester,
          'Could not save that change. Check your connection and try again.');
      await tester.pumpAndSettle();
      expect(find.text('Carvedilol'), findsOneWidget);
      expect(find.text('Archived Medications (1)'), findsOneWidget);
      expect(backend.profilePosts, hasLength(1));
    });
  });
}
