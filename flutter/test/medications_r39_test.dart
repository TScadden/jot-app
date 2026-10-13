import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Round 39 — one synced medication source of truth + archive
/// stamps the end date.
///
/// Native semantics under test (the shipped behavior the founder
/// brief says to mirror): archiving stamps the end date with
/// TODAY (`MMM d, yyyy`), unconditionally overwriting any
/// existing end date; unarchiving clears the end date back to
/// the `"Present"` sentinel unconditionally. Archived ⟺
/// `isPresent == false`; the blob carries no `isArchived` key.

/// Recording fake for the Tools screen: serves a canned profile,
/// captures every `POST /api/sync/profile` payload, and counts
/// pull-cache invalidations.
class RecordingToolsBackend extends TabsBackend {
  RecordingToolsBackend({required this.profile})
      : super(sessionStore: FakeSessionStore()..token = 'tok');

  Map<String, dynamic>? profile;
  final List<Map<String, dynamic>> profilePosts = [];
  bool postResult = true;
  int invalidateCount = 0;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async => profile;

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePosts.add(fields);
    return postResult;
  }

  @override
  void invalidateSyncPull() {
    invalidateCount++;
  }
}

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

void main() {
  group('formatMedArchiveDate', () {
    test('renders MMM d, yyyy like native SimpleDateFormat', () {
      expect(formatMedArchiveDate(DateTime(2026, 10, 13)), 'Oct 13, 2026');
      expect(formatMedArchiveDate(DateTime(2026, 1, 5)), 'Jan 5, 2026');
      expect(formatMedArchiveDate(DateTime(2026, 12, 25)), 'Dec 25, 2026');
    });
  });

  group('archive op (native semantics)', () {
    test('stamps the end date with the archive date', () {
      final at = DateTime(2026, 10, 13);
      final list = parseMedicationBlob([medRow(id: 'a', name: 'Ivabradine')]);
      final out = archiveMedicationInList(list, list.single, now: at);
      final med = out.single;
      expect(med.isPresent, isFalse);
      expect(med.isArchived, isTrue);
      expect(med.endDate, 'Oct 13, 2026');
      expect(med.updatedAt, at.millisecondsSinceEpoch);
      // The original list is untouched (pure op).
      expect(list.single.isPresent, isTrue);
    });

    test(
        'archive overwrites an existing end date with the stamp (native semantics)',
        () {
      final at = DateTime(2026, 10, 13);
      final list = parseMedicationBlob([
        medRow(id: 'a', name: 'Stale Date Med', endDate: 'Aug 20, 2026'),
      ]);
      final out = archiveMedicationInList(list, list.single, now: at);
      expect(out.single.endDate, 'Oct 13, 2026');
      expect(out.single.isPresent, isFalse);
    });

    test('unresolvable target leaves the list unchanged', () {
      final list = parseMedicationBlob([medRow(id: 'a', name: 'Ivabradine')]);
      final ghost = MedicationEntry(id: 'nope', name: 'Ghost');
      final out =
          archiveMedicationInList(list, ghost, now: DateTime(2026, 10, 13));
      expect(out.single.isPresent, isTrue);
      expect(out.single.endDate, 'Present');
    });
  });

  group('identity targeting (Vera Finding 1)', () {
    test(
        'two id-less rows sharing a name: archiving the SECOND leaves the first byte-untouched',
        () {
      final at = DateTime(2026, 10, 13);
      final rows = [
        medRow(id: '', name: 'Duplex', startDate: 'Jan 2026'),
        medRow(id: '', name: 'Duplex', startDate: 'Jun 2026'),
      ];
      final list = parseMedicationBlob(rows);
      // The production identity path: the exact entry instance.
      final out = archiveMedicationInList(list, list[1], now: at);
      // First row byte-untouched.
      expect(encodeMedicationBlob([out[0]]).single, rows[0]);
      expect(out[0].isPresent, isTrue);
      // Second row stamped.
      expect(out[1].isPresent, isFalse);
      expect(out[1].endDate, 'Oct 13, 2026');
      expect(out[1].startDate, 'Jun 2026');
      expect(out[1].updatedAt, at.millisecondsSinceEpoch);
    });

    test('document archiveEntry targets the exact instance among duplicates',
        () {
      final doc = MedicationDocument.fromRawRows([
        medRow(id: '', name: 'Duplex', startDate: 'Jan 2026'),
        medRow(id: '', name: 'Duplex', startDate: 'Jun 2026'),
      ]);
      final updated = doc.archiveEntry(doc.entryAt(1)!,
          now: DateTime(2026, 10, 13));
      final rows = updated.encode();
      expect(rows[0]['isPresent'], isTrue);
      expect(rows[0]['endDate'], 'Present');
      expect(rows[1]['isPresent'], isFalse);
      expect(rows[1]['endDate'], 'Oct 13, 2026');
    });

    test('ambiguous id fallback refuses rather than guess', () {
      // Target is NOT an instance in the list (a copy) and its id
      // matches two rows — the op must not pick one.
      final list = parseMedicationBlob([
        medRow(id: 'dup', name: 'First'),
        medRow(id: 'dup', name: 'Second'),
      ]);
      final copy = MedicationEntry(id: 'dup', name: 'Copy');
      final out =
          archiveMedicationInList(list, copy, now: DateTime(2026, 10, 13));
      expect(out.every((e) => e.isPresent), isTrue);
    });

    test('unique id fallback resolves an equal-but-not-identical copy', () {
      final list = parseMedicationBlob([
        medRow(id: 'a', name: 'Ivabradine'),
        medRow(id: 'b', name: 'Other'),
      ]);
      final copy = list[0].copyWith();
      expect(identical(copy, list[0]), isFalse);
      final out =
          archiveMedicationInList(list, copy, now: DateTime(2026, 10, 13));
      expect(out[0].isArchived, isTrue);
      expect(out[1].isPresent, isTrue);
    });
  });

  group('raw-row retention (Vera Finding 2)', () {
    test(
        'archive splices back: unparseable row verbatim, extra non-DTO keys intact',
        () {
      final nameless = <String, dynamic>{
        'dose': '5mg',
        'legacyNote': 'no name on this row',
      };
      final withExtra = <String, dynamic>{
        ...medRow(id: 'k', name: 'Keeper'),
        'legacyField': 'keep-me',
        'legacyCount': 7,
      };
      final normal = medRow(id: 't', name: 'Target Med');
      final doc =
          MedicationDocument.fromRawRows([nameless, withExtra, normal]);
      final pushed =
          doc.archiveAt(2, now: DateTime(2026, 10, 13)).encode();
      expect(pushed.length, 3);
      // Unparseable row emitted verbatim.
      expect(pushed[0], nameless);
      // Parseable untouched row: DTO keys from the entry, extra
      // raw keys intact.
      expect(pushed[1]['legacyField'], 'keep-me');
      expect(pushed[1]['legacyCount'], 7);
      expect(pushed[1]['name'], 'Keeper');
      expect(pushed[1]['isPresent'], isTrue);
      // Target row correctly stamped.
      expect(pushed[2]['name'], 'Target Med');
      expect(pushed[2]['isPresent'], isFalse);
      expect(pushed[2]['endDate'], 'Oct 13, 2026');
    });
  });

  group('isArchived splice-back (Vera fix pass 2)', () {
    Map<String, dynamic> stampedRow({
      required String id,
      required String name,
      dynamic isPresent = true,
      String endDate = 'Present',
    }) =>
        {
          ...medRow(
              id: id, name: name, isPresent: isPresent, endDate: endDate),
          'isArchived': true,
        };

    test(
        'unarchive of a stamp-only archived row persists: encoded row re-parses as NOT archived',
        () {
      // The Vera case: archived ONLY via the defensive stamp —
      // isPresent already reads true.
      final doc = MedicationDocument.fromRawRows([
        stampedRow(id: 's', name: 'Stamp Only Med'),
      ]);
      expect(doc.entryAt(0)!.isArchived, isTrue);
      expect(doc.entryAt(0)!.isPresent, isTrue);
      expect(doc.entryAt(0)!.isPlanVisible, isFalse);

      final encoded = doc
          .unarchiveAt(0, now: DateTime(2026, 10, 13))
          .encode()
          .single;
      // Pinned representation: the key the raw row carried stays,
      // overwritten with the cleared stamp state (explicit false).
      expect(encoded['isArchived'], isFalse);
      expect(encoded['isPresent'], isTrue);
      final reparsed = MedicationEntry.fromBlobRow(encoded)!;
      expect(reparsed.isArchived, isFalse);
      expect(reparsed.isPresent, isTrue);
      expect(reparsed.isPlanVisible, isTrue);
    });

    test(
        'archiving a DIFFERENT row preserves the untouched stamped row as archived',
        () {
      final doc = MedicationDocument.fromRawRows([
        stampedRow(id: 's', name: 'Stamp Only Med'),
        medRow(id: 't', name: 'Target Med'),
      ]);
      final encoded =
          doc.archiveAt(1, now: DateTime(2026, 10, 13)).encode();
      // Untouched stamped row: stamp preserved, still archived
      // on re-parse. (Its isPresent is normalized to false by
      // toBlobRow, as for any archived entry — the archived
      // classification is what must survive.)
      expect(encoded[0]['isArchived'], isTrue);
      final untouched = MedicationEntry.fromBlobRow(encoded[0])!;
      expect(untouched.isArchived, isTrue);
      // The archived target re-parses as archived via isPresent.
      final target = MedicationEntry.fromBlobRow(encoded[1])!;
      expect(target.isArchived, isTrue);
      expect(target.isPresent, isFalse);
    });

    test(
        'normal native row (no isArchived key) archived then unarchived gains no isArchived key at any point',
        () {
      final doc = MedicationDocument.fromRawRows([
        medRow(id: 'n', name: 'Normal Med'),
      ]);
      expect(doc.encode().single.containsKey('isArchived'), isFalse);

      final archivedDoc = doc.archiveAt(0, now: DateTime(2026, 10, 13));
      final archivedRow = archivedDoc.encode().single;
      expect(archivedRow.containsKey('isArchived'), isFalse);
      expect(MedicationEntry.fromBlobRow(archivedRow)!.isArchived, isTrue);

      final restoredRow = archivedDoc
          .unarchiveAt(0, now: DateTime(2026, 10, 14))
          .encode()
          .single;
      expect(restoredRow.containsKey('isArchived'), isFalse);
      final reparsed = MedicationEntry.fromBlobRow(restoredRow)!;
      expect(reparsed.isArchived, isFalse);
      expect(reparsed.isPresent, isTrue);
    });

    test(
        'round-trip matrix: stamp x isPresent — a no-op document pass preserves the archived classification',
        () {
      final combos = <(bool, bool)>[
        (true, true),
        (true, false),
        (false, true),
        (false, false),
      ];
      for (final (stamp, present) in combos) {
        final row = <String, dynamic>{
          ...medRow(
            id: 'm',
            name: 'Matrix Med',
            isPresent: present,
            endDate: present ? 'Present' : 'Aug 20, 2026',
          ),
          'isArchived': stamp,
        };
        final doc = MedicationDocument.fromRawRows([row]);
        final before = doc.entryAt(0)!;
        expect(before.hasArchivedStamp, stamp,
            reason: 'stamp=$stamp present=$present');
        final encoded = doc.encode().single;
        // The raw row carried the key, so the encoded value is
        // exactly the entry's stamp state.
        expect(encoded['isArchived'], stamp,
            reason: 'stamp=$stamp present=$present');
        final reparsed = MedicationEntry.fromBlobRow(encoded)!;
        // Only the archived classification is pinned here: a
        // stamp-archived entry (stamp=true, present=true) is
        // normalized by toBlobRow to isPresent=false, exactly
        // like any archived entry.
        expect(reparsed.isArchived, before.isArchived,
            reason: 'stamp=$stamp present=$present');
      }
    });
  });

  group('unarchive op (native semantics)', () {
    test('restores Present, clears the end date, returns to active', () {
      final at = DateTime(2026, 10, 13);
      final list = parseMedicationBlob([
        medRow(
          id: 'a',
          name: 'Carvedilol',
          isPresent: false,
          endDate: 'Aug 20, 2026',
          updatedAt: 5,
        ),
      ]);
      expect(archivedMedicationEntries(list).single.name, 'Carvedilol');
      final out = unarchiveMedicationInList(list, list.single, now: at);
      final med = out.single;
      expect(med.isPresent, isTrue);
      expect(med.isArchived, isFalse);
      expect(med.endDate, 'Present');
      expect(med.updatedAt, at.millisecondsSinceEpoch);
      expect(activeMedicationEntries(out).single.name, 'Carvedilol');
      expect(archivedMedicationEntries(out), isEmpty);
    });
  });

  group('blob payload shape', () {
    test('encoded rows carry exactly the native DTO keys and types', () {
      final entries = parseMedicationBlob([
        medRow(id: 'a', name: 'Ivabradine'),
        medRow(
            id: 'b',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
      ]);
      final rows = encodeMedicationBlob(entries);
      const dtoKeys = {
        'id',
        'name',
        'startDate',
        'endDate',
        'isPresent',
        'dose',
        'frequency',
        'updatedAt',
        'isDeleted',
      };
      for (final row in rows) {
        expect(row.keys.toSet(), dtoKeys);
        expect(row['id'], isA<String>());
        expect(row['name'], isA<String>());
        expect(row['startDate'], isA<String>());
        expect(row['endDate'], isA<String>());
        expect(row['isPresent'], isA<bool>());
        expect(row['dose'], isA<String>());
        expect(row['frequency'], isA<String>());
        expect(row['updatedAt'], isA<int>());
        expect(row['isDeleted'], isA<bool>());
      }
      // Active meds always serialize the Present sentinel.
      expect(rows[0]['endDate'], 'Present');
      expect(rows[0]['isPresent'], isTrue);
      // Archived meds serialize their stamped end date.
      expect(rows[1]['endDate'], 'Aug 20, 2026');
      expect(rows[1]['isPresent'], isFalse);
    });

    test('round-trip preserves raw dose/frequency (no display defaults leak)',
        () {
      final entries = parseMedicationBlob([
        medRow(id: 'x', name: 'Raw Med', dose: '', frequency: '', updatedAt: 42),
      ]);
      final entry = entries.single;
      // Display views apply the pinned defaults…
      expect(entry.dose, '');
      expect(entry.frequency, 'Once daily');
      // …but the encoded row carries the original raw values.
      final row = encodeMedicationBlob(entries).single;
      expect(row['dose'], '');
      expect(row['frequency'], '');
      expect(row['updatedAt'], 42);
    });

    test('isPlanVisible is the Today Summary filter', () {
      final entries = parseMedicationBlob([
        medRow(id: 'a', name: 'Active'),
        medRow(id: 'b', name: 'Ended', isPresent: false, endDate: 'Aug 20, 2026'),
        medRow(id: 'c', name: 'Gone', isDeleted: true),
      ]);
      expect(entries.map((e) => e.isPlanVisible), [true, false, false]);
    });
  });

  group('cross-surface parity', () {
    // One fixture blob: a present med, an ended/archived med, a
    // string-encoded-flags variant, and a deleted tombstone.
    List<Map<String, dynamic>> fixtureRows() => [
          medRow(
            id: 'med-1',
            name: 'Ivabradine',
            dose: '7.5mg',
            frequency: 'Twice daily',
            updatedAt: 1000,
          ),
          medRow(
            id: 'med-2',
            name: 'Carvedilol',
            dose: '25mg',
            startDate: 'Jan 5, 2026',
            endDate: 'Aug 20, 2026',
            isPresent: false,
            updatedAt: 2000,
          ),
          medRow(
            id: 'med-3',
            name: 'String Flag Med',
            startDate: 'Mar 1, 2026',
            endDate: 'Jul 4, 2026',
            isPresent: 'false',
            updatedAt: '3000',
            isDeleted: 'false',
          ),
          medRow(id: 'med-4', name: 'Deleted Med', isDeleted: true),
        ];

    test('Tools path and Settings path classify identically', () {
      final blob = jsonEncode(fixtureRows());

      // Tools path: fetchProfile → decodeProfileList → parse.
      final toolsProfile = <String, dynamic>{'medications': blob};
      final toolsEntries = parseMedicationBlob(
          TabsBackend.decodeProfileList(toolsProfile['medications']));

      // Settings path: SettingsProfileData.fromPull → parse.
      final settingsData = SettingsProfileData.fromPull({
        'profile': {'medications': blob},
      });
      final settingsEntries = parseMedicationBlob(settingsData.medications);

      List<String> names(List<MedicationEntry> es) =>
          es.map((e) => e.name).toList();

      expect(names(activeMedicationEntries(toolsEntries)), ['Ivabradine']);
      expect(names(activeMedicationEntries(settingsEntries)), ['Ivabradine']);
      expect(names(archivedMedicationEntries(toolsEntries)),
          ['Carvedilol', 'String Flag Med']);
      expect(names(archivedMedicationEntries(settingsEntries)),
          ['Carvedilol', 'String Flag Med']);

      // The tombstone is excluded from both displays…
      expect(names(activeMedicationEntries(toolsEntries)),
          isNot(contains('Deleted Med')));
      expect(names(archivedMedicationEntries(settingsEntries)),
          isNot(contains('Deleted Med')));
      // …but preserved in the encoded round-trip.
      final roundTrip = encodeMedicationBlob(toolsEntries);
      expect(roundTrip.length, 4);
      final tombstone =
          roundTrip.singleWhere((r) => r['name'] == 'Deleted Med');
      expect(tombstone['isDeleted'], isTrue);
    });
  });

  group('Tools MedicationsScreen archive', () {
    testWidgets(
        'tap Archive → card moves to Archived and the POST body carries the stamp',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final backend = RecordingToolsBackend(profile: {
        'medications': jsonEncode([
          medRow(
            id: 'iva-1',
            name: 'Ivabradine',
            dose: '7.5mg',
            frequency: 'Twice daily',
          ),
          medRow(
            id: 'pyr-1',
            name: 'Pyridostigmine',
            dose: '60mg',
            frequency: '3x daily',
          ),
        ]),
      });
      await tester.pumpWidget(
          MaterialApp(home: MedicationsScreen(backend: backend)));
      await tester.pumpAndSettle();
      expect(find.text('2 Active Medication(s)'), findsOneWidget);
      expect(find.text('Archived Medications (1)'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('archive_med_at_0')));
      await tester.pumpAndSettle();

      final stamp = formatMedArchiveDate(DateTime.now());
      expect(find.text('1 Active Medication(s)'), findsOneWidget);
      expect(find.text('Archived Medications (1)'), findsOneWidget);
      expect(find.text('Ended $stamp'), findsOneWidget);
      expect(backend.invalidateCount, greaterThanOrEqualTo(1));

      final posts = backend.profilePosts
          .where((p) => p.containsKey('medications'))
          .toList();
      expect(posts, hasLength(1));
      final rows = (jsonDecode(posts.single['medications'] as String)
          as List)
          .cast<Map<String, dynamic>>();
      final iva = rows.singleWhere((r) => r['name'] == 'Ivabradine');
      expect(iva['isPresent'], isFalse);
      expect(iva['endDate'], stamp);
      final pyr = rows.singleWhere((r) => r['name'] == 'Pyridostigmine');
      expect(pyr['isPresent'], isTrue);
      expect(pyr['endDate'], 'Present');
    });
  });

  group('Tools MedicationsScreen duplicates + retention (Vera Findings 1–2)',
      () {
    Future<RecordingToolsBackend> pumpTools(
        WidgetTester tester, List<Map<String, dynamic>> rows) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final backend = RecordingToolsBackend(profile: {
        'medications': jsonEncode(rows),
      });
      await tester.pumpWidget(
          MaterialApp(home: MedicationsScreen(backend: backend)));
      await tester.pumpAndSettle();
      return backend;
    }

    List<Map<String, dynamic>> pushedRows(RecordingToolsBackend backend) {
      final posts = backend.profilePosts
          .where((p) => p.containsKey('medications'))
          .toList();
      expect(posts, hasLength(1));
      return (jsonDecode(posts.single['medications'] as String) as List)
          .cast<Map<String, dynamic>>();
    }

    testWidgets(
        'id-less duplicate names: tapping the SECOND row archives only that row',
        (tester) async {
      final backend = await pumpTools(tester, [
        medRow(id: '', name: 'Duplex', startDate: 'Jan 2026'),
        medRow(id: '', name: 'Duplex', startDate: 'Jun 2026'),
      ]);
      expect(find.text('2 Active Medication(s)'), findsOneWidget);
      // Both rows render the same name; the buttons are told
      // apart only by their raw-index keys.
      expect(find.byKey(const ValueKey('archive_med_at_0')), findsOneWidget);
      expect(find.byKey(const ValueKey('archive_med_at_1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('archive_med_at_1')));
      await tester.pumpAndSettle();

      expect(find.text('1 Active Medication(s)'), findsOneWidget);
      expect(find.text('Archived Medications (1)'), findsOneWidget);
      final rows = pushedRows(backend);
      expect(rows.length, 2);
      // First duplicate byte-untouched…
      expect(rows[0]['startDate'], 'Jan 2026');
      expect(rows[0]['isPresent'], isTrue);
      expect(rows[0]['endDate'], 'Present');
      expect(rows[0]['updatedAt'], 1000);
      // …second duplicate stamped.
      expect(rows[1]['startDate'], 'Jun 2026');
      expect(rows[1]['isPresent'], isFalse);
      expect(rows[1]['endDate'], formatMedArchiveDate(DateTime.now()));
    });

    testWidgets(
        'save retains a nameless row verbatim and extra non-DTO keys',
        (tester) async {
      final nameless = <String, dynamic>{
        'dose': '5mg',
        'legacyNote': 'no name on this row',
      };
      final backend = await pumpTools(tester, [
        nameless,
        {...medRow(id: 'k', name: 'Keeper'), 'legacyField': 'keep-me'},
        medRow(id: 't', name: 'Target Med'),
      ]);
      // Raw indices: 0 nameless (not rendered), 1 Keeper, 2 Target.
      await tester.tap(find.byKey(const ValueKey('archive_med_at_2')));
      await tester.pumpAndSettle();

      final rows = pushedRows(backend);
      expect(rows.length, 3);
      expect(rows[0], nameless);
      expect(rows[1]['legacyField'], 'keep-me');
      expect(rows[1]['name'], 'Keeper');
      expect(rows[1]['isPresent'], isTrue);
      expect(rows[2]['name'], 'Target Med');
      expect(rows[2]['isPresent'], isFalse);
      expect(rows[2]['endDate'], formatMedArchiveDate(DateTime.now()));
    });

    testWidgets(
        'failed save → SnackBar, state reloads from the server, med NOT archived (Vera Finding 4)',
        (tester) async {
      final backend = await pumpTools(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
      ]);
      backend.postResult = false;
      expect(find.text('1 Active Medication(s)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('archive_med_at_0')));
      // Let the tap handler run and the SnackBar enter (before
      // any settle, which would run out its dismissal timer).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(
          find.text(
              'Could not save that change. Check your connection and try again.'),
          findsOneWidget);

      await tester.pumpAndSettle();
      // Reloaded from the server profile: still active, not archived.
      expect(find.text('1 Active Medication(s)'), findsOneWidget);
      expect(find.text('Archived Medications (1)'), findsNothing);
      expect(find.byKey(const ValueKey('archive_med_at_0')), findsOneWidget);
      // The failed attempt did reach the backend exactly once.
      expect(backend.profilePosts, hasLength(1));
    });
  });

  group('Settings User Profile archive', () {
    // Round 44 SUPERSEDES the R39 profile presentation asserted
    // here originally: the User Profile list shows ACTIVE meds
    // only, so archiving the sole med now removes the row from
    // the list (existing empty state shows) instead of flipping
    // it to an "Ended: …" line with a Restore button. The archive
    // OP itself (stamp + POST body + cache invalidation) is
    // unchanged — see profile_active_meds_r44_test.dart for the
    // full R44 suite.
    testWidgets(
        'tap archive → row leaves the profile list and the POST body carries today\'s stamp',
        (tester) async {
      final backend = r29.FakeSettingsBackend()
        ..pullBody = r29.pull(profile: {
          'medications': jsonEncode([
            medRow(
              id: 'm1',
              name: 'Ivabradine',
              startDate: 'Sep 2026',
              dose: 'As prescribed',
              updatedAt: 1,
            ),
          ]),
        });
      await r29.pumpSettings(
        tester,
        r29.host(r29.screen(
            backend: backend, store: r29.fakeStore(<String, String>{}))),
      );
      await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
      await tester.pumpAndSettle();
      expect(find.text('Started: Sep 2026 • Present'), findsOneWidget);
      expect(backend.invalidateCount, 0);

      await tester
          .tap(find.byKey(const ValueKey('archive_medication_at_0')));
      await tester.pumpAndSettle();

      final stamp = formatMedArchiveDate(DateTime.now());
      // R44: the archived row is gone from the profile list —
      // no "Ended: …" line, no Restore button; with no active
      // meds left the existing empty state shows.
      expect(find.text('Started: Sep 2026 • Ended: $stamp'), findsNothing);
      expect(find.text('Ivabradine'), findsNothing);
      expect(find.byKey(const ValueKey('unarchive_medication_at_0')),
          findsNothing);
      expect(
          find.text(
              'No medications added yet. Tap the + button to add one manually.'),
          findsOneWidget);
      // Vera Finding 3: the successful push invalidated the pull
      // cache (the fake records invalidations), so the next pull
      // re-fetches instead of serving pre-push state.
      expect(backend.invalidateCount, greaterThanOrEqualTo(1));

      final push = backend.profilePushes
          .singleWhere((p) => p.containsKey('medications'));
      final rows = (jsonDecode(push['medications'] as String) as List)
          .cast<Map<String, dynamic>>();
      final iva = rows.singleWhere((r) => r['name'] == 'Ivabradine');
      expect(iva['isPresent'], isFalse);
      expect(iva['endDate'], stamp);
    });
  });
}
