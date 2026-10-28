import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'test_helpers.dart';

/// Phase 1, item 2a — medication change-event CAPTURE (spec
/// §2.6 + §7 capture group).
///
/// Test levels per surface, stated plainly:
/// - Tools: FULL widget drive through the real
///   [MedicationsScreen] over a fake HTTP server (the R3
///   harness shape), plus diff unit tests over the real
///   [MedicationDocument] ops.
/// - Settings: parse+diff composition over the screen's exact
///   raw-row shapes (raw add literal, add-already-archived
///   literal, raw-row delete). The Settings screen's own save
///   path is already driven end-to-end by the R3 suite; its
///   capture hook differs from Tools only in that composition.
/// - Coach: parse+diff composition over the screen's exact
///   append-row shape, parsed with the screen's own
///   [coachRawRowMap] / [decodeCoachProfileBlobRaw] helpers.
///   (The coach approval path sits behind the full chat flow;
///   no existing harness drives it to the medication approval
///   card.)
/// - Backend: the exact contract body via MockClient.

Map<String, dynamic> _medRow({
  required String id,
  required String name,
  String startDate = 'Sep 1, 2026',
  String endDate = 'Present',
  bool isPresent = true,
  String dose = '7.5 mg',
  String frequency = 'Twice daily',
  int updatedAt = 1000,
}) => {
  'id': id,
  'name': name,
  'startDate': startDate,
  'endDate': endDate,
  'isPresent': isPresent,
  'dose': dose,
  'frequency': frequency,
  'updatedAt': updatedAt,
  'isDeleted': false,
};

String Function() _idGen() {
  var n = 0;
  return () => 'evt-${++n}';
}

final _diffNow = DateTime(2026, 10, 28, 12);

List<MedicationChangeEvent> _diff(
  List<MedicationEntry> before,
  List<MedicationEntry> after, {
  String source = 'tools',
}) => diffMedicationLists(
  before: before,
  after: after,
  source: source,
  now: _diffNow,
  idGen: _idGen(),
);

void main() {
  group('MedicationFieldSnapshot.fromEntry', () {
    test('active → Present endDate + isPresent true; archived → '
        'stored stamp; archived with no stamp → empty endDate', () {
      final active = MedicationEntry.fromBlobRow(
        _medRow(id: 'a', name: 'Active'),
      )!;
      final activeSnap = MedicationFieldSnapshot.fromEntry(active);
      expect(activeSnap.endDate, 'Present');
      expect(activeSnap.isPresent, isTrue);
      expect(activeSnap.dose, '7.5 mg');
      expect(activeSnap.frequency, 'Twice daily');
      expect(activeSnap.startDate, 'Sep 1, 2026');

      final archived = MedicationEntry.fromBlobRow(
        _medRow(
          id: 'b',
          name: 'Gone',
          endDate: 'Oct 16, 2026',
          isPresent: false,
        ),
      )!;
      final archivedSnap = MedicationFieldSnapshot.fromEntry(archived);
      expect(archivedSnap.endDate, 'Oct 16, 2026');
      expect(archivedSnap.isPresent, isFalse);

      final noStamp = MedicationEntry.fromBlobRow(
        _medRow(id: 'c', name: 'NoStamp', endDate: '', isPresent: false),
      )!;
      expect(MedicationFieldSnapshot.fromEntry(noStamp).endDate, '');
      expect(MedicationFieldSnapshot.fromEntry(noStamp).isPresent, isFalse);
    });
  });

  group('diff over MedicationDocument ops', () {
    test('add → one start (old null, effectiveDate = startDate)', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final updated = doc.addEntry(
        name: 'New Med',
        dose: '1 tablet',
        frequency: 'Once daily',
        startDate: 'Oct 1, 2026',
        id: 'new-1',
        now: DateTime(2026, 10, 1),
      );
      final events = _diff(doc.entries, updated.entries);
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.id, 'evt-1');
      expect(e.type, 'start');
      expect(e.medId, 'new-1');
      expect(e.medName, 'New Med');
      expect(e.oldSnapshot, isNull);
      expect(e.newSnapshot, isNotNull);
      expect(e.newSnapshot!.dose, '1 tablet');
      expect(e.newSnapshot!.frequency, 'Once daily');
      expect(e.newSnapshot!.startDate, 'Oct 1, 2026');
      expect(e.newSnapshot!.endDate, 'Present');
      expect(e.newSnapshot!.isPresent, isTrue);
      expect(e.effectiveDate, 'Oct 1, 2026');
      expect(e.recordedAt, _diffNow.millisecondsSinceEpoch);
      expect(e.source, 'tools');
    });

    test('archive → one stop (effectiveDate = stamped endDate, '
        'new.isPresent false)', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final updated = doc.archiveEntry(
        doc.entries.single,
        now: DateTime(2026, 10, 20),
      );
      final events = _diff(doc.entries, updated.entries);
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.type, 'stop');
      expect(e.medId, 'iva');
      expect(e.oldSnapshot!.isPresent, isTrue);
      expect(e.oldSnapshot!.endDate, 'Present');
      expect(e.newSnapshot!.isPresent, isFalse);
      expect(e.newSnapshot!.endDate, 'Oct 20, 2026');
      expect(e.effectiveDate, 'Oct 20, 2026');
    });

    test('unarchive after archive → one restore whose old.endDate '
        'preserves the stamped date the op erases', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final archived = doc.archiveEntry(
        doc.entries.single,
        now: DateTime(2026, 10, 20),
      );
      final restored = archived.unarchiveEntry(
        archived.entries.single,
        now: DateTime(2026, 10, 25),
      );
      // The row itself no longer carries the stamp.
      expect(restored.entries.single.endDate, 'Present');
      final events = _diff(archived.entries, restored.entries);
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.type, 'restore');
      expect(e.oldSnapshot!.isPresent, isFalse);
      expect(e.oldSnapshot!.endDate, 'Oct 20, 2026');
      expect(e.newSnapshot!.isPresent, isTrue);
      expect(e.newSnapshot!.endDate, 'Present');
      expect(e.effectiveDate, 'Oct 20, 2026');
    });

    test('edit dose → dose_change with correct old/new dose', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final target = doc.entries.single;
      final updated = doc.editEntry(
        target,
        name: target.name,
        dose: '5 mg',
        frequency: target.rawFrequency,
        startDate: target.startDate,
        endDate: target.endDate,
        now: DateTime(2026, 10, 21),
      );
      final events = _diff(doc.entries, updated.entries);
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.type, 'dose_change');
      expect(e.oldSnapshot!.dose, '7.5 mg');
      expect(e.newSnapshot!.dose, '5 mg');
      expect(e.effectiveDate, isNull);
    });

    test('edit frequency → frequency_change', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final target = doc.entries.single;
      final updated = doc.editEntry(
        target,
        name: target.name,
        dose: target.dose,
        frequency: '3x daily',
        startDate: target.startDate,
        endDate: target.endDate,
        now: DateTime(2026, 10, 21),
      );
      final events = _diff(doc.entries, updated.entries);
      expect(events, hasLength(1));
      expect(events.single.type, 'frequency_change');
      expect(events.single.oldSnapshot!.frequency, 'Twice daily');
      expect(events.single.newSnapshot!.frequency, '3x daily');
      expect(events.single.effectiveDate, isNull);
    });

    test('edit dates → dates_edit (effectiveDate = new startDate)', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final target = doc.entries.single;
      final updated = doc.editEntry(
        target,
        name: target.name,
        dose: target.dose,
        frequency: target.rawFrequency,
        startDate: 'Sep 15, 2026',
        endDate: target.endDate,
        now: DateTime(2026, 10, 21),
      );
      final events = _diff(doc.entries, updated.entries);
      expect(events, hasLength(1));
      expect(events.single.type, 'dates_edit');
      expect(events.single.oldSnapshot!.startDate, 'Sep 1, 2026');
      expect(events.single.newSnapshot!.startDate, 'Sep 15, 2026');
      expect(events.single.effectiveDate, 'Sep 15, 2026');
    });

    test('edit changing dose+frequency together → exactly ONE '
        'event (dose_change wins by precedence)', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final target = doc.entries.single;
      final updated = doc.editEntry(
        target,
        name: target.name,
        dose: '5 mg',
        frequency: '3x daily',
        startDate: target.startDate,
        endDate: target.endDate,
        now: DateTime(2026, 10, 21),
      );
      final events = _diff(doc.entries, updated.entries);
      expect(events, hasLength(1));
      expect(events.single.type, 'dose_change');
    });

    test('delete → one delete with the full pre-removal snapshot '
        'as old and new null; deleting an archived med carries '
        'its endDate as effectiveDate', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
        _medRow(
          id: 'esc',
          name: 'Escitalopram',
          dose: '10mg',
          endDate: 'Oct 16, 2026',
          isPresent: false,
        ),
      ]);
      final afterActiveDelete = doc.deleteEntry(doc.entries.first);
      var events = _diff(doc.entries, afterActiveDelete.entries);
      expect(events, hasLength(1));
      var e = events.single;
      expect(e.type, 'delete');
      expect(e.medId, 'iva');
      expect(e.medName, 'Ivabradine');
      expect(e.newSnapshot, isNull);
      expect(e.oldSnapshot!.dose, '7.5 mg');
      expect(e.oldSnapshot!.frequency, 'Twice daily');
      expect(e.oldSnapshot!.startDate, 'Sep 1, 2026');
      expect(e.oldSnapshot!.endDate, 'Present');
      expect(e.oldSnapshot!.isPresent, isTrue);
      // Still active when deleted → no effective end date.
      expect(e.effectiveDate, isNull);

      final afterArchivedDelete = doc.deleteEntry(doc.entries.last);
      events = _diff(doc.entries, afterArchivedDelete.entries);
      expect(events, hasLength(1));
      e = events.single;
      expect(e.type, 'delete');
      expect(e.medName, 'Escitalopram');
      expect(e.oldSnapshot!.endDate, 'Oct 16, 2026');
      expect(e.effectiveDate, 'Oct 16, 2026');
    });

    test('no-change edit (same values, updatedAt bumps) → zero '
        'events', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final target = doc.entries.single;
      final updated = doc.editEntry(
        target,
        name: target.name,
        dose: target.dose,
        frequency: target.rawFrequency,
        startDate: target.startDate,
        endDate: target.endDate,
        now: DateTime(2027, 1, 1),
      );
      // updatedAt really did bump — it is simply not compared.
      expect(
        updated.entries.single.updatedAt,
        isNot(doc.entries.single.updatedAt),
      );
      expect(_diff(doc.entries, updated.entries), isEmpty);
    });

    test('rename-only edit → zero events', () {
      final doc = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine'),
      ]);
      final target = doc.entries.single;
      final updated = doc.editEntry(
        target,
        name: 'Ivabradine (renamed)',
        dose: target.dose,
        frequency: target.rawFrequency,
        startDate: target.startDate,
        endDate: target.endDate,
        now: DateTime(2026, 10, 21),
      );
      expect(_diff(doc.entries, updated.entries), isEmpty);
    });
  });

  group('diff-against-fresh (spec §7.6, the R3 shape)', () {
    test('another writer changed the dose after render; the '
        'archive splice runs against the FRESH doc and the stop '
        'event\'s old snapshot equals the FRESH row, not the '
        'rendered one', () {
      // Rendered snapshot: dose 5 mg.
      final rendered = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine', dose: '5 mg'),
      ]);
      // Fresh pull: another writer has since set 7.5 mg.
      final fresh = MedicationDocument.fromRawRows([
        _medRow(id: 'iva', name: 'Ivabradine', dose: '7.5 mg'),
      ]);
      final target = fresh.resolveFreshEntry(rendered.entries.single);
      expect(target, isNotNull);
      final updated = fresh.archiveEntry(target!, now: DateTime(2026, 10, 20));
      final events = _diff(fresh.entries, updated.entries);
      expect(events, hasLength(1));
      expect(events.single.type, 'stop');
      expect(
        events.single.oldSnapshot!.dose,
        '7.5 mg',
        reason:
            'old must come from the fresh row, never the '
            'rendered snapshot',
      );
    });
  });

  group('pairing', () {
    test('id-less identical rows pair by name+snapshot, so an '
        'appended duplicate is exactly one start', () {
      final before = parseMedicationBlob([
        _medRow(id: '', name: 'Duplex'),
        _medRow(id: '', name: 'Duplex'),
      ]);
      final after = parseMedicationBlob([
        _medRow(id: '', name: 'Duplex'),
        _medRow(id: '', name: 'Duplex'),
        _medRow(id: '', name: 'Duplex'),
      ]);
      final events = _diff(before, after);
      expect(events, hasLength(1));
      expect(events.single.type, 'start');
      expect(events.single.medId, '');
      expect(events.single.medName, 'Duplex');
    });
  });

  group('Settings raw-row composition (parse+diff)', () {
    List<MedicationEntry> parseRows(List<Map<String, dynamic>> rows) => [
      for (final row in rows)
        if (MedicationEntry.fromBlobRow(row) != null)
          MedicationEntry.fromBlobRow(row)!,
    ];

    test('Settings raw-add literal → start', () {
      final beforeRows = [_medRow(id: 'iva', name: 'Ivabradine')];
      // The exact raw row literal settings_screen.dart's add
      // dialog builds (microseconds id, DTO defaults).
      final now = DateTime(2026, 10, 28, 9);
      final med = <String, dynamic>{
        'id': '${now.microsecondsSinceEpoch}',
        'name': 'New Med',
        'startDate': 'Oct 2026',
        'endDate': 'Present',
        'isPresent': true,
        'dose': 'As prescribed',
        'frequency': 'Daily',
        'updatedAt': now.millisecondsSinceEpoch,
        'isDeleted': false,
      };
      final afterRows = [...beforeRows, med];
      final events = _diff(
        parseRows(beforeRows),
        parseRows(afterRows),
        source: 'settings',
      );
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.type, 'start');
      expect(e.source, 'settings');
      expect(e.medId, '${now.microsecondsSinceEpoch}');
      expect(e.medName, 'New Med');
      expect(e.newSnapshot!.dose, 'As prescribed');
      expect(e.newSnapshot!.frequency, 'Daily');
      expect(e.newSnapshot!.isPresent, isTrue);
      expect(e.effectiveDate, 'Oct 2026');
    });

    test('Settings add-already-archived literal → start with '
        'new.isPresent false and the declared endDate', () {
      final now = DateTime(2026, 10, 28, 9);
      final med = <String, dynamic>{
        'id': '${now.microsecondsSinceEpoch}',
        'name': 'Old Med',
        'startDate': 'Jan 2026',
        'endDate': 'Jul 2026',
        'isPresent': false,
        'dose': 'As prescribed',
        'frequency': 'Daily',
        'updatedAt': now.millisecondsSinceEpoch,
        'isDeleted': false,
      };
      final events = _diff(
        parseRows(const []),
        parseRows([med]),
        source: 'settings',
      );
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.type, 'start');
      expect(e.newSnapshot!.isPresent, isFalse);
      expect(e.newSnapshot!.endDate, 'Jul 2026');
      expect(e.effectiveDate, 'Jan 2026');
    });

    test('Settings raw-row delete → delete', () {
      final beforeRows = [
        _medRow(id: 'iva', name: 'Ivabradine'),
        _medRow(id: 'bpc', name: 'BPC-157', dose: '0.5'),
      ];
      // The screen's raw-row removal shape: every other row
      // pushed verbatim.
      final afterRows = [
        for (var i = 0; i < beforeRows.length; i++)
          if (i != 0) beforeRows[i],
      ];
      final events = _diff(
        parseRows(beforeRows),
        parseRows(afterRows),
        source: 'settings',
      );
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.type, 'delete');
      expect(e.medName, 'Ivabradine');
      expect(e.oldSnapshot!.dose, '7.5 mg');
      expect(e.newSnapshot, isNull);
    });
  });

  group('Coach append composition (parse+diff)', () {
    List<MedicationEntry> parseCoachRows(List<dynamic> rawRows) {
      final out = <MedicationEntry>[];
      for (final row in rawRows) {
        final map = coachRawRowMap(row);
        if (map == null) continue;
        final entry = MedicationEntry.fromBlobRow(map);
        if (entry != null) out.add(entry);
      }
      return out;
    }

    test('coach append row → start', () {
      final beforeRows = decodeCoachProfileBlobRaw(
        jsonEncode([_medRow(id: 'iva', name: 'Ivabradine')]),
      );
      final afterRows = List<dynamic>.of(beforeRows)
        ..add({
          // The exact row shape _approveMedications appends.
          'id': 'coach-uuid-1',
          'name': 'Magnesium',
          'startDate': 'Oct 2026',
          'endDate': 'Present',
          'isPresent': true,
          'dose': '200 mg',
          'frequency': '',
          'updatedAt': 123456,
          'isDeleted': false,
        });
      final events = _diff(
        parseCoachRows(beforeRows),
        parseCoachRows(afterRows),
        source: 'coach',
      );
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.type, 'start');
      expect(e.source, 'coach');
      expect(e.medId, 'coach-uuid-1');
      expect(e.medName, 'Magnesium');
      expect(e.newSnapshot!.dose, '200 mg');
      expect(e.newSnapshot!.frequency, '');
      expect(e.effectiveDate, 'Oct 2026');
    });

    test('coach no-append (re-approval, existing rows win) → '
        'empty diff', () {
      final rows = decodeCoachProfileBlobRaw(
        jsonEncode([_medRow(id: 'iva', name: 'Ivabradine')]),
      );
      final events = _diff(
        parseCoachRows(rows),
        parseCoachRows(List<dynamic>.of(rows)),
        source: 'coach',
      );
      expect(events, isEmpty);
    });
  });

  group('TabsBackend.postMedicationChangeEvents + emit helper', () {
    test('posts the exact contract body to '
        '/api/sync/medication-events', () async {
      http.Request? captured;
      final backend = TabsBackend(
        client: MockClient((request) async {
          captured = request;
          return http.Response('{}', 200);
        }),
        sessionStore: FakeSessionStore()..token = 'tok-backend-1',
      );
      const event = MedicationChangeEvent(
        id: 'evt-uuid-1',
        medId: 'iva',
        medName: 'Ivabradine',
        type: 'dose_change',
        oldSnapshot: MedicationFieldSnapshot(
          dose: '7.5 mg',
          frequency: 'Twice daily',
          startDate: 'Sep 1, 2026',
          endDate: 'Present',
          isPresent: true,
        ),
        newSnapshot: MedicationFieldSnapshot(
          dose: '5 mg',
          frequency: 'Twice daily',
          startDate: 'Sep 1, 2026',
          endDate: 'Present',
          isPresent: true,
        ),
        effectiveDate: null,
        recordedAt: 1790000000000,
        source: 'tools',
      );
      expect(await backend.postMedicationChangeEvents([event]), isTrue);
      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/api/sync/medication-events');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'events'});
      final eventsJson = (body['events'] as List).cast<Map<String, dynamic>>();
      expect(eventsJson, hasLength(1));
      expect(eventsJson.single.keys.toSet(), {
        'id',
        'medId',
        'medName',
        'type',
        'old',
        'new',
        'effectiveDate',
        'recordedAt',
        'source',
      });
      expect(eventsJson.single, {
        'id': 'evt-uuid-1',
        'medId': 'iva',
        'medName': 'Ivabradine',
        'type': 'dose_change',
        'old': {
          'dose': '7.5 mg',
          'frequency': 'Twice daily',
          'startDate': 'Sep 1, 2026',
          'endDate': 'Present',
          'isPresent': true,
        },
        'new': {
          'dose': '5 mg',
          'frequency': 'Twice daily',
          'startDate': 'Sep 1, 2026',
          'endDate': 'Present',
          'isPresent': true,
        },
        'effectiveDate': null,
        'recordedAt': 1790000000000,
        'source': 'tools',
      });
      expect((eventsJson.single['old'] as Map).keys.toSet(), {
        'dose',
        'frequency',
        'startDate',
        'endDate',
        'isPresent',
      });
    });

    test('emit helper: empty list makes no call; a failing post '
        'is swallowed', () async {
      var calls = 0;
      final backend = TabsBackend(
        client: MockClient((request) async {
          calls++;
          return http.Response('nope', 500);
        }),
        sessionStore: FakeSessionStore()..token = 'tok-backend-2',
      );
      await emitMedicationChangeEvents(backend, const []);
      expect(calls, 0);
      const event = MedicationChangeEvent(
        id: 'evt-uuid-2',
        medId: 'iva',
        medName: 'Ivabradine',
        type: 'stop',
        oldSnapshot: null,
        newSnapshot: null,
        effectiveDate: 'Oct 20, 2026',
        recordedAt: 1790000000000,
        source: 'tools',
      );
      // Must complete normally even though the POST fails.
      await emitMedicationChangeEvents(backend, [event]);
      expect(calls, 1);
    });
  });

  group('Tools MedicationsScreen capture (widget, fake server)', () {
    // Unique token per test: the backend's shared pull caches
    // are static and keyed by (baseUrl, token) — the R3 rule.
    var tokenSeq = 0;
    FakeSessionStore session() => FakeSessionStore()
      ..token = 'fake-token-capture-${tokenSeq++}'
      ..email = 'founder@tabs.app';

    testWidgets('(a) successful archive → POST /api/sync/profile BEFORE '
        'POST /api/sync/medication-events, exactly one stop event', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final server = _CaptureServer(
        rows: [_medRow(id: 'iva', name: 'Ivabradine')],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedicationsScreen(backend: server.backend(session())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 Active Medication(s)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('archive_med_at_0')));
      await tester.pumpAndSettle();

      final posts = server.requestLog
          .where((r) => r.startsWith('POST'))
          .toList();
      expect(posts, [
        'POST /api/sync/profile',
        'POST /api/sync/medication-events',
      ]);
      expect(server.eventPayloads, hasLength(1));
      final events = (server.eventPayloads.single['events'] as List)
          .cast<Map<String, dynamic>>();
      expect(events, hasLength(1));
      final e = events.single;
      final stamp = formatMedArchiveDate(DateTime.now());
      expect(e['type'], 'stop');
      expect(e['medId'], 'iva');
      expect(e['medName'], 'Ivabradine');
      expect(e['source'], 'tools');
      expect(e['id'], isA<String>());
      expect((e['id'] as String).isNotEmpty, isTrue);
      expect(e['recordedAt'], isA<int>());
      expect(e['effectiveDate'], stamp);
      expect(e['old'], {
        'dose': '7.5 mg',
        'frequency': 'Twice daily',
        'startDate': 'Sep 1, 2026',
        'endDate': 'Present',
        'isPresent': true,
      });
      expect(e['new'], {
        'dose': '7.5 mg',
        'frequency': 'Twice daily',
        'startDate': 'Sep 1, 2026',
        'endDate': stamp,
        'isPresent': false,
      });
    });

    testWidgets('(b) profile POST returns 500 → NO medication-events '
        'request at all', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final server = _CaptureServer(
        rows: [_medRow(id: 'iva', name: 'Ivabradine')],
        profileStatus: 500,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedicationsScreen(backend: server.backend(session())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('archive_med_at_0')));
      await tester.pumpAndSettle();

      expect(server.requestLog, contains('POST /api/sync/profile'));
      expect(
        server.requestLog,
        isNot(contains('POST /api/sync/medication-events')),
      );
      expect(server.eventPayloads, isEmpty);
    });

    testWidgets('(c) a no-op save (edit dialog saved with unchanged '
        'values) pushes the profile but emits nothing', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final server = _CaptureServer(
        rows: [_medRow(id: 'iva', name: 'Ivabradine')],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedicationsScreen(backend: server.backend(session())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('edit_med_at_0')));
      await tester.pumpAndSettle();
      expect(find.text('Edit Medication'), findsOneWidget);
      await tester.tap(find.text('Save Medication'));
      await tester.pumpAndSettle();

      // The save DID push the profile (the op is not identical
      // to the fresh doc) — but the diff was empty, so no
      // events request was made.
      expect(server.requestLog, contains('POST /api/sync/profile'));
      expect(
        server.requestLog,
        isNot(contains('POST /api/sync/medication-events')),
      );
      expect(server.eventPayloads, isEmpty);
    });
  });
}

/// Fake HTTP server for the widget tests (the R3 harness
/// shape): GET pull serves the stored blob, POST profile
/// upserts the `medications` field (or fails with
/// [profileStatus]), POST medication-events records its body.
class _CaptureServer {
  String medicationsRaw;
  final int profileStatus;
  final List<String> requestLog = [];
  final List<Map<String, dynamic>> eventPayloads = [];

  _CaptureServer({
    required List<Map<String, dynamic>> rows,
    this.profileStatus = 200,
  }) : medicationsRaw = jsonEncode(rows);

  http.Client client() => MockClient((request) async {
    requestLog.add('${request.method} ${request.url.path}');
    if (request.url.path == '/api/sync/pull' && request.method == 'GET') {
      return http.Response(
        jsonEncode({
          'isUnlimited': false,
          'isAdmin': false,
          'profile': {'medications': medicationsRaw},
          'insights': const [],
        }),
        200,
      );
    }
    if (request.url.path == '/api/sync/profile' && request.method == 'POST') {
      if (profileStatus != 200) {
        return http.Response('error', profileStatus);
      }
      final fields = jsonDecode(request.body) as Map<String, dynamic>;
      if (fields.containsKey('medications')) {
        medicationsRaw = fields['medications'] as String;
      }
      return http.Response('{}', 200);
    }
    if (request.url.path == '/api/sync/medication-events' &&
        request.method == 'POST') {
      eventPayloads.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  });

  TabsBackend backend(FakeSessionStore store) =>
      TabsBackend(client: client(), sessionStore: store);
}
