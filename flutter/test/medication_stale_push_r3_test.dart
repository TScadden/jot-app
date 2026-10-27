import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'test_helpers.dart';

/// R3 regression — medication stale whole-list push (founder
/// incident, Oct 22–23, 2026): a stale whole-list medication
/// snapshot pushed by an old build overwrote the fresher
/// corrected list on the server, resurrecting escitalopram
/// (ended Oct 16, 2026) as active and dropping desvenlafaxine.
///
/// The production protection lives in the Flutter client, at two
/// layers, and these tests drive BOTH through the REAL
/// [TabsBackend] over a faithful fake HTTP server (the
/// counter_mutation_durability_test.dart harness pattern — the
/// existing medication tests override fetchProfile/postSyncProfile
/// and so never exercise either layer):
///
/// 1. The profile-mutation epoch in [TabsBackend]: a sync pull
///    that STARTED before a successful profile push and LANDS
///    after it is discarded and re-issued, so no caller (and no
///    TTL cache) ever receives the pre-push body. A stale
///    client's whole-list push is built from what its pull
///    delivered — with the epoch guard, that is the FRESHER
///    list, so the push cannot overwrite the correction.
/// 2. Fresh-pull before splice in the medication mutation entry
///    points (Tools Medications tab `_mutateDoc`, Settings
///    `_mutateMedications`): a screen holding a stale load-time
///    snapshot invalidates the cached pull, re-pulls the
///    freshest profile, splices its op into THAT document, and
///    pushes the result — never its stale snapshot wholesale.
///
/// The fake server mirrors the counter durability server's real
/// semantics: POST /api/sync/profile upserts only the fields
/// sent (the server's COALESCE behaviour), and GET
/// /api/sync/pull SNAPSHOTS the server state when the request
/// STARTS and can be held in flight, so a pull that started
/// before a push lands afterwards with the pre-push body — the
/// exact stale-landing hazard.
///
/// Fixture lists: the Oct 23, 2026 corrected state is the
/// FRESHER list (actives exactly BPC-157 0.5, SS-31 0.05,
/// ivabradine 7.5 mg, Desvenlafaxine Succinate ER 50 mg;
/// escitalopram present as ENDED Oct 16, 2026). The STALE list
/// is the pre-correction shape: the same rows minus
/// desvenlafaxine, with escitalopram ACTIVE again.

/// Unique token per test: the backend's shared pull caches and
/// in-flight slot are static and keyed by (baseUrl, token), so
/// tests must not share a token (the counter test's rule).
int _tokenSeq = 0;
FakeSessionStore _session() => FakeSessionStore()
  ..token = 'fake-token-r3-${_tokenSeq++}'
  ..email = 'founder@tabs.app';

Map<String, dynamic> _medRow({
  required String id,
  required String name,
  required String dose,
  String startDate = 'Sep 1, 2026',
  String endDate = 'Present',
  bool isPresent = true,
  String frequency = 'Daily',
  int updatedAt = 1000,
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
      'isDeleted': false,
    };

/// The pre-correction (stale) whole-list snapshot: escitalopram
/// ACTIVE, desvenlafaxine ABSENT.
List<Map<String, dynamic>> _staleRows() => [
      _medRow(
          id: 'bpc',
          name: 'BPC-157',
          dose: '0.5',
          startDate: 'Oct 6, 2026'),
      _medRow(
          id: 'ss31',
          name: 'SS-31',
          dose: '0.05',
          startDate: 'Oct 6, 2026'),
      _medRow(
          id: 'iva',
          name: 'Ivabradine',
          dose: '7.5 mg',
          frequency: 'Twice daily'),
      _medRow(id: 'esc', name: 'Escitalopram', dose: '10mg'),
    ];

/// The Oct 23, 2026 corrected (fresher) list: the four verified
/// actives, plus escitalopram ENDED Oct 16, 2026.
List<Map<String, dynamic>> _fresherRows() => [
      _medRow(
          id: 'bpc',
          name: 'BPC-157',
          dose: '0.5',
          startDate: 'Oct 6, 2026'),
      _medRow(
          id: 'ss31',
          name: 'SS-31',
          dose: '0.05',
          startDate: 'Oct 6, 2026'),
      _medRow(
          id: 'iva',
          name: 'Ivabradine',
          dose: '7.5 mg',
          frequency: 'Twice daily'),
      _medRow(
          id: 'desv',
          name: 'Desvenlafaxine Succinate ER',
          dose: '50 mg',
          startDate: 'Oct 17, 2026',
          updatedAt: 2000),
      _medRow(
        id: 'esc',
        name: 'Escitalopram',
        dose: '10mg',
        endDate: 'Oct 16, 2026',
        isPresent: false,
        updatedAt: 2000,
      ),
    ];

String _encodeRows(List<Map<String, dynamic>> rows) => jsonEncode(rows);

List<Map<String, dynamic>> _decodeRows(String raw) =>
    (jsonDecode(raw) as List).cast<Map<String, dynamic>>();

/// The task's fresher-list assertions, checked against a stored
/// medications blob: the four actives intact with their doses,
/// escitalopram still ended Oct 16, 2026, desvenlafaxine still
/// present.
void _expectFresherListIntact(List<Map<String, dynamic>> rows,
    {required String reason}) {
  final entries = parseMedicationBlob(rows);
  final actives = activeMedicationEntries(entries);
  // The four verified actives are intact. (Containment, not
  // exact-set equality: the widget test's ADD legitimately adds
  // a fifth active on top. Exact equality for the backend test
  // is pinned separately by its stored-string comparison
  // against the fresher blob.)
  expect(
    actives.map((e) => e.name).toSet(),
    containsAll(
        {'BPC-157', 'SS-31', 'Ivabradine', 'Desvenlafaxine Succinate ER'}),
    reason: reason,
  );
  final byName = {for (final e in entries) e.name: e};
  expect(byName['BPC-157']!.dose, '0.5', reason: reason);
  expect(byName['SS-31']!.dose, '0.05', reason: reason);
  expect(byName['Ivabradine']!.dose, '7.5 mg', reason: reason);
  expect(byName['Desvenlafaxine Succinate ER']!.dose, '50 mg',
      reason: reason);
  // Desvenlafaxine still present (not dropped by the stale push).
  expect(byName['Desvenlafaxine Succinate ER']!.isPresent, isTrue,
      reason: reason);
  // Escitalopram still ENDED Oct 16, 2026 (not resurrected).
  final esc = byName['Escitalopram'];
  expect(esc, isNotNull, reason: reason);
  expect(esc!.isPresent, isFalse, reason: reason);
  expect(esc.isArchived, isTrue, reason: reason);
  expect(esc.endDate, 'Oct 16, 2026', reason: reason);
}

class FakeMedicationServer {
  /// Server-side profile `medications` field (raw JSON string,
  /// as stored).
  String medicationsRaw;

  int pullCount = 0;
  int pushCount = 0;
  final List<Map<String, dynamic>> pushes = [];

  /// Holds are a QUEUE (the counter server's pattern): each
  /// armed hold captures the next pull that starts, and
  /// [releaseHeldPull] releases the OLDEST held pull.
  final List<Completer<void>> _heldPulls = [];
  int _holdsArmed = 0;

  FakeMedicationServer({required List<Map<String, dynamic>> rows})
      : medicationsRaw = _encodeRows(rows);

  /// The next GET /api/sync/pull captures its snapshot, then
  /// waits until [releaseHeldPull] before responding.
  void holdNextPull() {
    _holdsArmed++;
  }

  void releaseHeldPull() {
    if (_heldPulls.isNotEmpty) {
      _heldPulls.removeAt(0).complete();
    }
  }

  Map<String, dynamic> _pullBodySnapshot() => {
        'isUnlimited': false,
        'isAdmin': false,
        'nickname': 'Tyson',
        'tag': '1234',
        'profile': {'medications': medicationsRaw},
        'insights': const [],
      };

  List<Map<String, dynamic>> get serverMedRows =>
      _decodeRows(medicationsRaw);

  http.Client client() => MockClient((request) async {
        if (request.url.path == '/api/sync/pull' &&
            request.method == 'GET') {
          pullCount++;
          // Snapshot at request START — a held pull delivers
          // this body even if a push lands while it is in
          // flight.
          final snapshot = _pullBodySnapshot();
          if (_holdsArmed > 0) {
            _holdsArmed--;
            final completer = Completer<void>();
            _heldPulls.add(completer);
            await completer.future;
          }
          return http.Response(jsonEncode(snapshot), 200);
        }
        if (request.url.path == '/api/sync/profile' &&
            request.method == 'POST') {
          pushCount++;
          final fields =
              jsonDecode(request.body) as Map<String, dynamic>;
          pushes.add(fields);
          // Per-field upsert (COALESCE): only sent fields
          // change — a whole-list `medications` push replaces
          // the stored list wholesale, exactly the server
          // behaviour the Oct 22–23 incident ran through.
          if (fields.containsKey('medications')) {
            medicationsRaw = fields['medications'] as String;
          }
          return http.Response('{}', 200);
        }
        return http.Response('not found', 404);
      });

  TabsBackend backend(FakeSessionStore store) =>
      TabsBackend(client: client(), sessionStore: store);
}

void main() {
  group('R3 — stale in-flight pull vs the Oct 23 correction '
      '(backend epoch)', () {
    test(
        'a pull that STARTED on the stale list and LANDS after '
        'the correction push is discarded and re-issued; the '
        'stale client\'s whole-list push built on that pull '
        'pushes the FRESHER list, and the stored list still '
        'equals the fresher list', () async {
      final fresherRaw = _encodeRows(_fresherRows());
      // Seed: the server still holds the PRE-correction list
      // when the stale client starts its pull.
      final server =
          FakeMedicationServer(rows: _staleRows());
      final store = _session();
      final a = server.backend(store);
      final b = server.backend(store);

      // The stale client (B) starts a slow pull; the server
      // snapshots the STALE list (escitalopram active, no
      // desvenlafaxine) and holds the response in flight.
      server.holdNextPull();
      final slowPull = b.fetchSyncPull();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.pullCount, 1);

      // The Oct 23 correction lands while B's pull is in
      // flight: A pushes the verified fresher list through the
      // real profile-push entry point.
      expect(
          await a.postSyncProfile({'medications': fresherRaw}),
          isTrue);
      expect(server.medicationsRaw, fresherRaw);

      // B's pre-correction pull now lands. The epoch guard must
      // discard the stale body and re-issue the GET once: B's
      // caller only ever sees the post-correction body.
      server.releaseHeldPull();
      final body = await slowPull;
      expect(body, isNotNull);
      final deliveredRaw =
          (body!['profile'] as Map)['medications'] as String;
      expect(deliveredRaw, fresherRaw,
          reason: 'the stale pre-correction body must never be '
              'delivered to a caller');
      expect(server.pullCount, 2,
          reason: 'exactly one bounded epoch re-issue');

      // B's TTL cache must not serve the stale body either.
      final again = await b.fetchSyncPull();
      expect((again!['profile'] as Map)['medications'], fresherRaw,
          reason: 'the stale body must never be cached as fresh');

      // The incident step: the stale client now fires its
      // pending WHOLE-LIST snapshot push — POST
      // /api/sync/profile with the full `medications` list it
      // holds, the same entry point the old build used. What
      // it holds is what its pull delivered: the fresher list.
      // The push therefore lands fresher-over-fresher instead
      // of overwriting the correction with the stale snapshot.
      expect(
          await b.postSyncProfile({'medications': deliveredRaw}),
          isTrue);

      // Stored list afterward still equals the fresher list.
      expect(server.medicationsRaw, fresherRaw,
          reason: 'the stale push must not overwrite the '
              'Oct 23 correction');
      _expectFresherListIntact(server.serverMedRows,
          reason: 'stored list after the stale whole-list push');
    });
  });

  group('R3 — stale-loaded Medications screen save '
      '(fresh-pull before splice)', () {
    testWidgets(
        'the screen loads the stale snapshot; the correction '
        'lands server-side; an ADD from the stale screen '
        'splices into the FRESH list — the stored list keeps '
        'the four actives, escitalopram stayed ended, '
        'desvenlafaxine stayed present', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fresherRaw = _encodeRows(_fresherRows());
      final server = FakeMedicationServer(rows: _staleRows());
      final store = _session();
      final a = server.backend(store);
      final b = server.backend(store);

      // The stale client: the Tools Medications screen loads
      // (and renders) the PRE-correction snapshot — 4 active
      // meds including escitalopram, no desvenlafaxine, no
      // archived section.
      await tester.pumpWidget(
          MaterialApp(home: MedicationsScreen(backend: a)));
      await tester.pumpAndSettle();
      expect(find.text('4 Active Medication(s)'), findsOneWidget);
      expect(find.text('Escitalopram'), findsOneWidget);
      expect(find.text('Desvenlafaxine Succinate ER'), findsNothing);
      expect(find.text('Archived Medications (1)'), findsNothing);

      // The Oct 23 correction lands server-side (another
      // client pushes the verified fresher list) while this
      // screen still holds its stale snapshot.
      expect(
          await b.postSyncProfile({'medications': fresherRaw}),
          isTrue);
      expect(server.medicationsRaw, fresherRaw);

      // The user adds a medication from the STALE screen. The
      // save path (`_mutateDoc`) must fresh-pull and splice the
      // add into the fresh document — a whole-list push built
      // on the screen's stale snapshot would resurrect
      // escitalopram and drop desvenlafaxine here.
      await tester.tap(find.byKey(const ValueKey('add_medication')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('med_edit_name')), 'New Med');
      await tester.enterText(
          find.byKey(const ValueKey('med_edit_dose')), '1 tablet');
      // Let the dialog rebuild so Save enables (name + dose
      // present) before tapping it — the r48d2 pattern.
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Medication'));
      await tester.pumpAndSettle();

      // The push that landed was built on the FRESH list.
      final medPushes = server.pushes
          .where((p) => p.containsKey('medications'))
          .toList();
      // Push 1 is the correction itself; push 2 is the screen's
      // save.
      expect(medPushes, hasLength(2));

      final rows = server.serverMedRows;
      // Nothing dropped, nothing duplicated: the 5 fresher rows
      // plus the one addition.
      expect(rows, hasLength(6),
          reason: 'the stale push must not drop fresher rows');
      _expectFresherListIntact(rows,
          reason: 'stored list after the stale screen\'s save');
      final added = rows.singleWhere((r) => r['name'] == 'New Med');
      expect(added['isPresent'], isTrue);
      expect(added['dose'], '1 tablet');

      // And the screen now renders the FRESH state: 5 actives
      // (the four verified + New Med) and escitalopram in the
      // archived section — not resurrected as active.
      expect(find.text('5 Active Medication(s)'), findsOneWidget);
      expect(find.text('Archived Medications (1)'), findsOneWidget);
      expect(find.text('Desvenlafaxine Succinate ER'), findsOneWidget);
    });
  });
}
