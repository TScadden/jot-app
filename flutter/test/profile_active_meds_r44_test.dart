import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/medications.dart';

import 'settings_r29_test.dart' as r29;

/// Round 44 — User Profile medications list shows ACTIVE meds only.
///
/// Founder's rule (supersedes the R39 profile presentation):
/// archived meds must NOT appear in Settings → User Profile at
/// all — no "Ended: …" rows, no Restore buttons there. The filter
/// is DISPLAY-only: the underlying document keeps every row, and
/// any save initiated from the profile screen (add, delete,
/// archive) must still push the FULL list with the hidden
/// archived/deleted rows preserved.
///
/// The Tools → Medications tab (Active/Archived sections +
/// restore) is unchanged and covered by medications_r39_test.dart.

Map<String, dynamic> row({
  required String id,
  required String name,
  String startDate = 'Sep 2026',
  String endDate = 'Present',
  bool isPresent = true,
  String dose = '10mg',
  String frequency = 'Daily',
  int updatedAt = 1000,
  bool isDeleted = false,
  Map<String, dynamic> extra = const {},
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
      ...extra,
    };

/// One active, one archived (with a non-DTO legacy key riding
/// along), one deleted tombstone, and one stamp-only archived
/// row (`isPresent` true but the defensive `isArchived` stamp
/// set — archived per the shared model).
List<Map<String, dynamic>> fixture() => [
      row(
        id: 'a1',
        name: 'Ivabradine',
        startDate: 'Sep 2026',
        dose: '7.5mg',
        frequency: 'Twice daily',
        updatedAt: 111,
      ),
      row(
        id: 'a2',
        name: 'Carvedilol',
        startDate: 'Jan 2026',
        endDate: 'Aug 20, 2026',
        isPresent: false,
        dose: '25mg',
        updatedAt: 222,
        extra: {'legacyNote': 'keep-me'},
      ),
      row(
        id: 'a3',
        name: 'Ghost Med',
        startDate: 'Feb 2026',
        updatedAt: 333,
        isDeleted: true,
      ),
      row(
        id: 'a4',
        name: 'Stamp Med',
        startDate: 'Mar 2026',
        updatedAt: 444,
        extra: {'isArchived': true},
      ),
    ];

Future<r29.FakeSettingsBackend> pumpProfile(
  WidgetTester tester,
  List<Map<String, dynamic>> meds,
) async {
  final backend = r29.FakeSettingsBackend()
    ..pullBody = r29.pull(profile: {'medications': jsonEncode(meds)});
  await r29.pumpSettings(
    tester,
    r29.host(r29.screen(
        backend: backend, store: r29.fakeStore(<String, String>{}))),
  );
  await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
  await tester.pumpAndSettle();
  return backend;
}

List<Map<String, dynamic>> pushedRows(r29.FakeSettingsBackend backend) {
  final pushes =
      backend.profilePushes.where((p) => p.containsKey('medications')).toList();
  expect(pushes, hasLength(1));
  return (jsonDecode(pushes.single['medications'] as String) as List)
      .cast<Map<String, dynamic>>();
}

void main() {
  group('profile display filter (active only)', () {
    testWidgets(
        'active + archived + deleted + stamp-only fixture → only the active row renders',
        (tester) async {
      await pumpProfile(tester, fixture());

      // The active med renders with its Present range line.
      expect(find.text('Ivabradine'), findsOneWidget);
      expect(find.text('Started: Sep 2026 • Present'), findsOneWidget);

      // Archived, deleted, and stamp-only rows render NOTHING:
      // no names, no "Ended: …" line anywhere.
      expect(find.text('Carvedilol'), findsNothing);
      expect(find.text('Ghost Med'), findsNothing);
      expect(find.text('Stamp Med'), findsNothing);
      expect(find.textContaining('Ended:'), findsNothing);

      // No Restore buttons on this screen, for any raw index.
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(ValueKey('unarchive_medication_at_$i')),
            findsNothing);
      }
      expect(find.byTooltip('Restore'), findsNothing);

      // The active row keeps its archive + delete actions, keyed
      // by its index in the FULL list (raw index 0 here).
      expect(find.byKey(const ValueKey('archive_medication_at_0')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('delete_medication_a1')),
          findsOneWidget);
      // Hidden rows expose no actions on this screen.
      expect(find.byKey(const ValueKey('delete_medication_a2')),
          findsNothing);
      expect(find.byKey(const ValueKey('delete_medication_a3')),
          findsNothing);

      // Medications exist, so the empty state does not show.
      expect(
          find.text(
              'No medications added yet. Tap the + button to add one manually.'),
          findsNothing);
    });

    testWidgets(
        'only archived/deleted meds exist → existing empty state, no archived copy',
        (tester) async {
      final meds = fixture().sublist(1); // archived + deleted + stamp-only
      await pumpProfile(tester, meds);

      expect(
          find.text(
              'No medications added yet. Tap the + button to add one manually.'),
          findsOneWidget);
      expect(find.text('Carvedilol'), findsNothing);
      expect(find.text('Ghost Med'), findsNothing);
      expect(find.text('Stamp Med'), findsNothing);
      expect(find.textContaining('Ended:'), findsNothing);
      expect(find.byTooltip('Restore'), findsNothing);
      // The add affordance stays available.
      expect(find.byKey(const ValueKey('add_medication_button')),
          findsOneWidget);
    });
  });

  group('payload preservation (hidden rows survive every save)', () {
    testWidgets(
        'delete an active med → pushed payload still contains the archived and deleted rows, unchanged',
        (tester) async {
      final meds = fixture();
      final backend = await pumpProfile(tester, meds);

      await tester.tap(find.byKey(const ValueKey('delete_medication_a1')));
      await tester.pumpAndSettle();

      expect(find.text('Ivabradine'), findsNothing);
      final rows = pushedRows(backend);
      // Full list minus the deleted active med — hidden rows are
      // present and byte-identical to the fixture (raw-map
      // round-trip, including the non-DTO legacy key and the
      // defensive isArchived stamp).
      expect(rows.length, 3);
      expect(rows[0], meds[1]); // archived Carvedilol, unchanged
      expect(rows[1], meds[2]); // deleted Ghost Med, unchanged
      expect(rows[2], meds[3]); // stamp-only Stamp Med, unchanged
      expect(rows.any((r) => r['name'] == 'Ivabradine'), isFalse);
    });

    testWidgets(
        'add a med → pushed payload keeps every hidden row unchanged and appends the new row',
        (tester) async {
      final meds = fixture();
      final backend = await pumpProfile(tester, meds);

      await tester.tap(find.byKey(const ValueKey('add_medication_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('medication_name_field')), 'New Med');
      await tester.enterText(
          find.byKey(const ValueKey('medication_start_field')), 'Oct 2026');
      await tester.tap(find.byKey(const ValueKey('medication_add')));
      await tester.pumpAndSettle();

      final rows = pushedRows(backend);
      expect(rows.length, 5);
      // Every pre-existing row — active, archived, deleted,
      // stamp-only — is pushed back unchanged, in order.
      for (var i = 0; i < meds.length; i++) {
        expect(rows[i], meds[i], reason: 'row $i must be unchanged');
      }
      expect(rows[4]['name'], 'New Med');
      expect(rows[4]['isPresent'], isTrue);
      expect(rows[4]['endDate'], 'Present');
      // And the new active med renders.
      expect(find.text('New Med'), findsOneWidget);
    });
  });

  group('archive from the profile', () {
    testWidgets(
        'archive an active med → row leaves the list AND the pushed row carries the archive stamp; hidden rows unchanged',
        (tester) async {
      final meds = fixture();
      final backend = await pumpProfile(tester, meds);

      await tester
          .tap(find.byKey(const ValueKey('archive_medication_at_0')));
      await tester.pumpAndSettle();

      // The row leaves the profile list entirely: no name, no
      // "Ended: …" presentation, no Restore button. It was the
      // only active med, so the existing empty state shows.
      expect(find.text('Ivabradine'), findsNothing);
      expect(find.textContaining('Ended:'), findsNothing);
      expect(find.byTooltip('Restore'), findsNothing);
      expect(
          find.text(
              'No medications added yet. Tap the + button to add one manually.'),
          findsOneWidget);

      final rows = pushedRows(backend);
      // Full list pushed — nothing dropped.
      expect(rows.length, 4);
      // The archived row carries the R39/native stamp shape:
      // isPresent=false, endDate = archive day "MMM d, yyyy".
      final stamp = formatMedArchiveDate(DateTime.now());
      final iva = rows.singleWhere((r) => r['name'] == 'Ivabradine');
      expect(iva['isPresent'], isFalse);
      expect(iva['endDate'], stamp);
      expect(iva['id'], 'a1');
      expect(iva['dose'], '7.5mg');
      // Hidden rows survive the splice-back encode unchanged
      // (DTO-shaped values + extra keys intact).
      expect(rows[1], meds[1]); // archived Carvedilol
      expect(rows[2], meds[2]); // deleted Ghost Med
      final stampRow = rows[3];
      expect(stampRow['name'], 'Stamp Med');
      expect(stampRow['isArchived'], isTrue); // stamp preserved
      expect(stampRow['updatedAt'], 444);
    });
  });
}
