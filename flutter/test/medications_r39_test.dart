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
      final out = archiveMedicationInList(list, 'a', now: at);
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
      final out = archiveMedicationInList(list, 'a', now: at);
      expect(out.single.endDate, 'Oct 13, 2026');
      expect(out.single.isPresent, isFalse);
    });

    test('matches on name when the row has no id', () {
      final list = parseMedicationBlob([
        medRow(id: '', name: 'No Id Med'),
      ]);
      final out =
          archiveMedicationInList(list, 'No Id Med', now: DateTime(2026, 10, 13));
      expect(out.single.isArchived, isTrue);
      expect(out.single.endDate, 'Oct 13, 2026');
    });

    test('unknown id leaves the list unchanged', () {
      final list = parseMedicationBlob([medRow(id: 'a', name: 'Ivabradine')]);
      final out =
          archiveMedicationInList(list, 'nope', now: DateTime(2026, 10, 13));
      expect(out.single.isPresent, isTrue);
      expect(out.single.endDate, 'Present');
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
      final out = unarchiveMedicationInList(list, 'a', now: at);
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

      await tester.tap(find.byKey(const ValueKey('archive_med_iva-1')));
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

  group('Settings User Profile archive', () {
    testWidgets(
        'tap archive → row line becomes Ended with today\'s stamp and the POST body matches',
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

      await tester
          .tap(find.byKey(const ValueKey('archive_medication_m1')));
      await tester.pumpAndSettle();

      final stamp = formatMedArchiveDate(DateTime.now());
      expect(find.text('Started: Sep 2026 • Ended: $stamp'), findsOneWidget);
      expect(find.byKey(const ValueKey('unarchive_medication_m1')),
          findsOneWidget);

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
