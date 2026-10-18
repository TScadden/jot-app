import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'test_helpers.dart';

/// Round 46 — edit dose / start date / end date on the Tools →
/// Medications & Side Effects screen (native `MedicationsScreen`
/// edit dialog + `MedicationsViewModel.updateMedication` are the
/// spec):
/// - Invocation: tap any card (Active AND Archived sections).
/// - Fields: name, dose, frequency, date started, and ended date
///   ONLY for archived meds (an active med's end date is not
///   editable in native and stays the "Present" sentinel).
/// - Dates are written `MMM d, yyyy` — native's format (field
///   examples "Apr 14, 2026" / "Jul 24, 2026"; archive stamp
///   SimpleDateFormat). Native stores free text verbatim, so old
///   rows vary ("October 6,2026", "April 2026") — the picker
///   seeds from them via [parseMedicationDate].
/// - Setting/clearing an archived med's end date never changes
///   its archive state; clearing writes "" and it stays archived.
/// - Save is enabled only with a non-blank name AND dose
///   (native validation); blank frequency saves as "Once daily".

/// Recording fake (the R39 pattern): canned profile, captured
/// `POST /api/sync/profile` payloads, switchable result.
class RecordingEditBackend extends TabsBackend {
  RecordingEditBackend({required this.profile})
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

List<Map<String, dynamic>> pushedRows(RecordingEditBackend backend) {
  final posts =
      backend.profilePosts.where((p) => p.containsKey('medications')).toList();
  expect(posts, hasLength(1));
  return (jsonDecode(posts.single['medications'] as String) as List)
      .cast<Map<String, dynamic>>();
}

void main() {
  group('parseMedicationDate (picker seed for free-text blob dates)', () {
    test('parses the shapes real rows carry', () {
      expect(parseMedicationDate('Oct 13, 2026'), DateTime(2026, 10, 13));
      expect(parseMedicationDate('October 6,2026'), DateTime(2026, 10, 6));
      expect(parseMedicationDate('April 2026'), DateTime(2026, 4, 1));
      expect(parseMedicationDate('Apr 14, 2026'), DateTime(2026, 4, 14));
      expect(parseMedicationDate('Jul 24, 2026'), DateTime(2026, 7, 24));
      expect(parseMedicationDate('Sep 1, 2026'), DateTime(2026, 9, 1));
    });

    test('unparseable strings seed nothing', () {
      expect(parseMedicationDate(''), isNull);
      expect(parseMedicationDate('Present'), isNull);
      expect(parseMedicationDate('sometime last spring'), isNull);
      expect(parseMedicationDate('13 Oct 2026'), isNull);
    });

    test('round-trips the native write format', () {
      for (final s in ['Oct 13, 2026', 'Jan 5, 2026', 'Dec 25, 2026']) {
        expect(formatMedArchiveDate(parseMedicationDate(s)!), s);
      }
    });
  });

  group('edit op (native updateMedication semantics)', () {
    test('edit dose on an active med: only that row changes', () {
      final rows = [
        medRow(id: 'a', name: 'Ivabradine', dose: '7.5mg'),
        medRow(id: 'b', name: 'Pyridostigmine', dose: '60mg'),
        medRow(
            id: 'c',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026',
            updatedAt: 3000),
      ];
      final doc = MedicationDocument.fromRawRows(rows);
      final target = doc.entryAt(0)!;
      final updated = doc.editEntry(
        target,
        name: 'Ivabradine',
        dose: '5mg',
        frequency: target.frequency,
        startDate: target.startDate,
        endDate: target.endDate,
        now: DateTime(2026, 10, 13),
      );
      final out = updated.encode();
      expect(out[0]['dose'], '5mg');
      expect(out[0]['updatedAt'],
          DateTime(2026, 10, 13).millisecondsSinceEpoch);
      expect(out[0]['isPresent'], isTrue);
      expect(out[0]['endDate'], 'Present');
      // Every other row deep-equal to what went in.
      expect(out[1], rows[1]);
      expect(out[2], rows[2]);
    });

    test(
        'identity targeting: editing the SECOND of two id-less duplicate names leaves the first byte-untouched',
        () {
      final rows = [
        medRow(id: '', name: 'Duplex', dose: '10mg', startDate: 'Jan 2026'),
        medRow(id: '', name: 'Duplex', dose: '20mg', startDate: 'Jun 2026'),
      ];
      final doc = MedicationDocument.fromRawRows(rows);
      final out = doc
          .editEntry(
            doc.entryAt(1)!,
            name: 'Duplex',
            dose: '25mg',
            frequency: 'Daily',
            startDate: 'Jun 2026',
            endDate: 'Present',
            now: DateTime(2026, 10, 13),
          )
          .encode();
      expect(out[0], rows[0]);
      expect(out[1]['dose'], '25mg');
      expect(out[1]['startDate'], 'Jun 2026');
    });

    test('edit start date stores the MMM d, yyyy string verbatim', () {
      final doc = MedicationDocument.fromRawRows([
        medRow(id: 'a', name: 'Ivabradine', startDate: 'Sep 2026'),
      ]);
      final out = doc
          .editEntry(
            doc.entryAt(0)!,
            name: 'Ivabradine',
            dose: '10mg',
            frequency: 'Daily',
            startDate: formatMedArchiveDate(DateTime(2026, 9, 15)),
            endDate: 'Present',
            now: DateTime(2026, 10, 13),
          )
          .encode()
          .single;
      expect(out['startDate'], 'Sep 15, 2026');
    });

    test(
        'edit end date on an archived med: payload updated, med stays archived',
        () {
      final doc = MedicationDocument.fromRawRows([
        medRow(
            id: 'c',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
      ]);
      final out = doc
          .editEntry(
            doc.entryAt(0)!,
            name: 'Carvedilol',
            dose: '10mg',
            frequency: 'Daily',
            startDate: 'Sep 1, 2026',
            endDate: 'Jul 24, 2026',
            now: DateTime(2026, 10, 13),
          )
          .encode()
          .single;
      expect(out['endDate'], 'Jul 24, 2026');
      expect(out['isPresent'], isFalse);
      final reparsed = MedicationEntry.fromBlobRow(out)!;
      expect(reparsed.isArchived, isTrue);
      expect(reparsed.endedDate, 'Jul 24, 2026');
    });

    test(
        'clearing an archived med end date writes "" and it stays archived (native)',
        () {
      final doc = MedicationDocument.fromRawRows([
        medRow(
            id: 'c',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
      ]);
      final out = doc
          .editEntry(
            doc.entryAt(0)!,
            name: 'Carvedilol',
            dose: '10mg',
            frequency: 'Daily',
            startDate: 'Sep 1, 2026',
            endDate: '',
            now: DateTime(2026, 10, 13),
          )
          .encode()
          .single;
      expect(out['endDate'], '');
      expect(out['isPresent'], isFalse);
      expect(MedicationEntry.fromBlobRow(out)!.isArchived, isTrue);
    });

    test(
        'archive-stamp coherence: a manual end edit survives until a later archive re-stamps (R39/native rule)',
        () {
      var doc = MedicationDocument.fromRawRows([
        medRow(
            id: 'c',
            name: 'Carvedilol',
            isPresent: false,
            endDate: 'Aug 20, 2026'),
      ]);
      // Manual edit of the archived end date.
      doc = doc.editEntry(
        doc.entryAt(0)!,
        name: 'Carvedilol',
        dose: '10mg',
        frequency: 'Daily',
        startDate: 'Sep 1, 2026',
        endDate: 'Jul 24, 2026',
        now: DateTime(2026, 10, 13),
      );
      expect(doc.encode().single['endDate'], 'Jul 24, 2026');
      // Restore, then archive again: the archive op re-stamps
      // with the archive day, overwriting the manual date.
      doc = doc.unarchiveAt(0, now: DateTime(2026, 10, 14));
      expect(doc.encode().single['endDate'], 'Present');
      doc = doc.archiveAt(0, now: DateTime(2026, 11, 2));
      final row = doc.encode().single;
      expect(row['endDate'], 'Nov 2, 2026');
      expect(row['isPresent'], isFalse);
    });

    test('unresolvable target refuses: document unchanged', () {
      final doc = MedicationDocument.fromRawRows([
        medRow(id: 'a', name: 'Ivabradine'),
      ]);
      final ghost = MedicationEntry(id: 'nope', name: 'Ghost');
      final out = doc.editEntry(
        ghost,
        name: 'Ghost',
        dose: '1mg',
        frequency: 'Daily',
        startDate: '',
        endDate: 'Present',
        now: DateTime(2026, 10, 13),
      );
      expect(identical(out, doc), isTrue);
      expect(out.encode(), doc.encode());
    });

    test('list-level op mirrors the document op', () {
      final list = parseMedicationBlob([
        medRow(id: 'a', name: 'Ivabradine', dose: '7.5mg'),
      ]);
      final out = editMedicationInList(
        list,
        list.single,
        name: 'Ivabradine',
        dose: '5mg',
        frequency: 'Daily',
        startDate: 'Sep 1, 2026',
        endDate: 'Present',
        now: DateTime(2026, 10, 13),
      );
      expect(out.single.dose, '5mg');
      expect(out.single.isArchived, isFalse);
      expect(list.single.dose, '7.5mg'); // pure op
    });
  });

  group('Tools MedicationsScreen edit dialog', () {
    Future<RecordingEditBackend> pumpTools(
        WidgetTester tester, List<Map<String, dynamic>> rows) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final backend = RecordingEditBackend(profile: {
        'medications': jsonEncode(rows),
      });
      await tester.pumpWidget(
          MaterialApp(home: MedicationsScreen(backend: backend)));
      await tester.pumpAndSettle();
      return backend;
    }

    Future<void> openEditor(WidgetTester tester, int rawIndex) async {
      await tester.tap(find.byKey(ValueKey('edit_med_at_$rawIndex')));
      await tester.pumpAndSettle();
      expect(find.text('Edit Medication'), findsOneWidget);
    }

    Future<void> saveDialog(WidgetTester tester) async {
      await tester.tap(find.text('Save Medication'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Medication'), findsNothing);
    }

    testWidgets('tap an active card → edit dose → payload + card updated',
        (tester) async {
      final rows = [
        medRow(
            id: 'iva-1',
            name: 'Ivabradine',
            dose: '7.5mg',
            frequency: 'Twice daily'),
        medRow(
            id: 'pyr-1',
            name: 'Pyridostigmine',
            dose: '60mg',
            frequency: '3x daily'),
      ];
      final backend = await pumpTools(tester, rows);

      await openEditor(tester, 0);
      // The dose field is prefilled with the stored dose.
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('med_edit_dose')))
              .controller!
              .text,
          '7.5mg');
      await tester.enterText(
          find.byKey(const ValueKey('med_edit_dose')), '5mg');
      await tester.pumpAndSettle();
      await saveDialog(tester);

      final out = pushedRows(backend);
      final iva = out.singleWhere((r) => r['name'] == 'Ivabradine');
      expect(iva['dose'], '5mg');
      expect(iva['updatedAt'], greaterThan(1000));
      expect(iva['isPresent'], isTrue);
      expect(iva['endDate'], 'Present');
      // The untouched row is deep-equal to the input row.
      expect(out.singleWhere((r) => r['name'] == 'Pyridostigmine'),
          rows[1]);
      expect(backend.invalidateCount, greaterThanOrEqualTo(1));
      // The card now shows the new dose.
      expect(find.text('5mg  •  Twice daily'), findsOneWidget);
    });

    testWidgets(
        'active med dialog has NO ended-date field (native) and the edit keeps endDate "Present"',
        (tester) async {
      final backend = await pumpTools(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
      ]);
      await openEditor(tester, 0);
      expect(find.byKey(const ValueKey('med_edit_end')), findsNothing);
      expect(find.text('Ended Date (e.g. Jul 24, 2026)'), findsNothing);

      await tester.enterText(
          find.byKey(const ValueKey('med_edit_dose')), '10mg');
      await tester.pumpAndSettle();
      await saveDialog(tester);

      final row = pushedRows(backend).single;
      expect(row['dose'], '10mg');
      expect(row['endDate'], 'Present');
      expect(row['isPresent'], isTrue);
    });

    testWidgets(
        'edit start date via the picker → stored string is MMM d, yyyy exactly',
        (tester) async {
      final backend = await pumpTools(tester, [
        medRow(
            id: 'iva-1',
            name: 'Ivabradine',
            dose: '7.5mg',
            startDate: 'Sep 1, 2026'),
      ]);
      await openEditor(tester, 0);
      // The picker seeds from the stored string (Sep 2026 view).
      await tester.tap(find.byKey(const ValueKey('med_edit_start')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('med_edit_start')))
              .controller!
              .text,
          'Sep 15, 2026');
      await saveDialog(tester);

      final row = pushedRows(backend).single;
      expect(row['startDate'], 'Sep 15, 2026');
      expect(find.text('Started Sep 15, 2026'), findsOneWidget);
    });

    testWidgets(
        'archived card → edit ended date → payload updated and the "Ended …" label reflects it; start date preserved',
        (tester) async {
      final backend = await pumpTools(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
        medRow(
            id: 'car-1',
            name: 'Carvedilol',
            dose: '25mg',
            startDate: 'Jan 5, 2026',
            endDate: 'Aug 20, 2026',
            isPresent: false),
      ]);
      expect(find.text('Ended Aug 20, 2026'), findsOneWidget);

      await openEditor(tester, 1);
      // Archived meds get the ended-date field, prefilled.
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('med_edit_end')))
              .controller!
              .text,
          'Aug 20, 2026');
      await tester.tap(find.byKey(const ValueKey('med_edit_end')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('10'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await saveDialog(tester);

      final out = pushedRows(backend);
      final car = out.singleWhere((r) => r['name'] == 'Carvedilol');
      expect(car['endDate'], 'Aug 10, 2026');
      expect(car['isPresent'], isFalse);
      // Start date rides through the edit untouched.
      expect(car['startDate'], 'Jan 5, 2026');
      expect(find.text('Ended Aug 10, 2026'), findsOneWidget);
    });

    testWidgets(
        'clearing the dose disables Save (native validation: name AND dose required)',
        (tester) async {
      await pumpTools(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: '7.5mg'),
      ]);
      await openEditor(tester, 0);
      await tester.enterText(
          find.byKey(const ValueKey('med_edit_dose')), '');
      await tester.pumpAndSettle();
      final button = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Save Medication'));
      expect(button.onPressed, isNull);
    });

    testWidgets(
        'a stored "As prescribed" dose opens emptied (native) — Save stays disabled until a real dose is typed',
        (tester) async {
      await pumpTools(tester, [
        medRow(id: 'iva-1', name: 'Ivabradine', dose: 'As prescribed'),
      ]);
      await openEditor(tester, 0);
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('med_edit_dose')))
              .controller!
              .text,
          '');
      final button = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Save Medication'));
      expect(button.onPressed, isNull);
    });

    testWidgets(
        'save failure → SnackBar, dialog closed, list reloads from the server unchanged',
        (tester) async {
      final backend = await pumpTools(tester, [
        medRow(
            id: 'iva-1',
            name: 'Ivabradine',
            dose: '7.5mg',
            frequency: 'Twice daily'),
      ]);
      backend.postResult = false;

      await openEditor(tester, 0);
      await tester.enterText(
          find.byKey(const ValueKey('med_edit_dose')), '99mg');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Medication'));
      // Let the save run and the SnackBar enter (before any
      // settle, which would run out its dismissal timer).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(
          find.text(
              'Could not save that change. Check your connection and try again.'),
          findsOneWidget);

      await tester.pumpAndSettle();
      // Reloaded from the server profile: the OLD dose is shown —
      // no local half-state.
      expect(find.text('7.5mg  •  Twice daily'), findsOneWidget);
      expect(find.text('99mg  •  Twice daily'), findsNothing);
      expect(backend.profilePosts, hasLength(1));
    });
  });
}
