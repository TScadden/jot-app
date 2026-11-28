import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/workout_sync_store.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Workout sync — History surface pins (DESIGN §7): the synced
/// card marker + detail provenance banner (Juno-ruled strings),
/// and the §1.4 delete tombstone hook with its failure-restore
/// symmetry, including the local-only cancel path and the R2
/// category-edit behaviour (marker chips stripped by the edit;
/// the LINK is the identity of record and stays intact).

const _categories = <Map<String, dynamic>>[
  {
    'id': 7,
    'name': 'General',
    'icon': 'circle',
    'colorHex': '#CCCCCC',
    'isDefault': true,
    'sortOrder': 0,
  },
  {
    'id': 3,
    'name': 'Symptoms',
    'icon': 'circle',
    'colorHex': '#4ECDC4',
    'isDefault': false,
    'sortOrder': 1,
  },
  {
    'id': 5,
    'name': 'Exercise',
    'icon': 'circle',
    'colorHex': '#7C6EFF',
    'isDefault': false,
    'sortOrder': 2,
  },
];

final _now = DateTime(2026, 11, 26, 12).millisecondsSinceEpoch;

Map<String, dynamic> _syncedEntry() => {
      'id': 581,
      'categoryId': 7,
      'body': 'Walking · 34 min',
      'chips': 'Workout, Health Connect',
      'manualText': 'avg HR 85 · max HR 119',
      'timestamp': _now - 3600000,
    };

Map<String, dynamic> _manualEntry() => {
      'id': 900,
      'categoryId': 7,
      'body': 'Felt tired after lunch',
      'chips': '',
      'manualText': '',
      'timestamp': _now - 7200000,
    };

class _FakeServer {
  final List<Map<String, dynamic>> entries;
  bool failDeletes = false;
  bool failPosts = false;
  final List<int> capturedDeletes = [];
  final List<Map<String, dynamic>> capturedPosts = [];

  _FakeServer(this.entries);

  TabsBackend backend() {
    final store = FakeSessionStore()..token = 'test-token';
    final client = MockClient((request) async {
      if (request.url.path == '/api/sync/pull') {
        return http.Response(
          jsonEncode({
            'entries': entries,
            'categories': _categories,
            'profile': <String, dynamic>{},
            'isUnlimited': true,
            'isAdmin': false,
          }),
          200,
        );
      }
      if (request.url.path == '/api/sync/entries' &&
          request.method == 'POST') {
        if (failPosts) return http.Response('server error', 500);
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        final rows = (decoded['entries'] as List).cast<Map<String, dynamic>>();
        capturedPosts.addAll(rows);
        for (final row in rows) {
          final i = entries.indexWhere((e) => e['id'] == row['id']);
          if (i >= 0) {
            entries[i] = {...entries[i], ...row};
          } else {
            entries.add(row);
          }
        }
        return http.Response('{"ok":true}', 200);
      }
      if (request.url.path.startsWith('/api/sync/entries/') &&
          request.method == 'DELETE') {
        final id = int.parse(request.url.path.split('/').last);
        capturedDeletes.add(id);
        if (failDeletes) return http.Response('server error', 500);
        entries.removeWhere((e) => e['id'] == id);
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    });
    return TabsBackend(client: client, sessionStore: store);
  }
}

LogEntryOutbox _freshOutbox() {
  final disk = <String, String>{};
  final outbox = LogEntryOutbox.instance;
  outbox.debugReset();
  outbox.debugSetStore(
    read: (key) async => disk[key],
    write: (key, value) async => disk[key] = value,
    delete: (key) async => disk.remove(key),
  );
  return outbox;
}

/// The workout store singleton (the delete hook's store) over an
/// in-memory disk, warmed owner-bound and — by default — holding
/// the live link for entry 581.
Future<({WorkoutSyncStore store, Map<String, String> disk})>
    _freshWorkoutStore({bool withLink = true}) async {
  final disk = <String, String>{};
  final store = WorkoutSyncStore.instance;
  store.debugReset();
  store.debugSetStore(
    read: (key) async => disk[key],
    write: (key, value) async => disk[key] = value,
    delete: (key) async => disk.remove(key),
  );
  await store.warmFromDisk(currentEmail: 'a@example.com');
  if (withLink) {
    await store.recordLink(
      key: 'hc:uuid-581',
      entryId: 581,
      state: WorkoutLinkState.linked,
      origin: WorkoutLinkOrigin.synced,
      hcId: 'uuid-581',
    );
  }
  return (store: store, disk: disk);
}

Future<void> _pumpHistory(WidgetTester tester, _FakeServer server) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HistoryScreen(backend: server.backend(), outbox: _freshOutbox()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Juno ruling (PR #190): History single-entry delete has NO
/// confirm dialog — the delete proceeds directly and offers Undo.
/// The old helper tapped the dialog's Delete button; now it just
/// settles the direct delete and pins the dialog's absence.
Future<void> _confirmDelete(WidgetTester tester) async {
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing);
  expect(find.text('This cannot be undone.'), findsNothing);
}

void main() {
  setUp(() => TabsBackend.debugResetSharedCaches());

  group('rendering', () {
    testWidgets('synced card renders the marker; manual card does not',
        (tester) async {
      await _freshWorkoutStore();
      final server = _FakeServer([_syncedEntry(), _manualEntry()]);
      await _pumpHistory(tester, server);

      expect(find.text('Walking · 34 min'), findsOneWidget);
      expect(find.text('Felt tired after lunch'), findsOneWidget);
      expect(find.text('Synced from Health Connect'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('synced_workout_marker')),
        findsOneWidget,
      );
    });

    testWidgets(
        'detail dialog: provenance banner renders, entry stays editable',
        (tester) async {
      await _freshWorkoutStore();
      final server = _FakeServer([_syncedEntry()]);
      await _pumpHistory(tester, server);

      await tester.tap(find.text('Walking · 34 min'));
      await tester.pumpAndSettle();

      // Juno-ruled banner (JUNO-STRINGS §1.2), byte-exact.
      expect(find.text('SYNCED FROM HEALTH CONNECT'), findsOneWidget);
      // Provenance only — NOT the locked treatment: the category
      // picker and Edit affordance render, and the check-in
      // locked note never appears on a synced entry.
      expect(find.text('CHANGE CATEGORY'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(
        find.text(
            'This entry was logged automatically and cannot be edited.'),
        findsNothing,
      );
      // The metrics line shows in the detail body (second
      // paragraph via entryCombinedText).
      expect(find.textContaining('avg HR 85 · max HR 119'), findsWidgets);
    });

    testWidgets('manual entry detail shows no banner', (tester) async {
      await _freshWorkoutStore();
      final server = _FakeServer([_manualEntry()]);
      await _pumpHistory(tester, server);

      await tester.tap(find.text('Felt tired after lunch'));
      await tester.pumpAndSettle();
      expect(find.text('SYNCED FROM HEALTH CONNECT'), findsNothing);
    });
  });

  group('delete tombstone hook (DESIGN §1.4)', () {
    testWidgets('server-known synced delete tombstones (stripped)',
        (tester) async {
      final ws = await _freshWorkoutStore();
      final server = _FakeServer([_syncedEntry()]);
      await _pumpHistory(tester, server);

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await _confirmDelete(tester);

      expect(server.capturedDeletes, [581]);
      expect(find.text('Walking · 34 min'), findsNothing);
      // The link is tombstoned AND stripped: the on-disk record
      // is exactly {state} — only the session key (the map key)
      // and the flag survive (DECISIONS decision 4).
      final link = ws.store.linkForKey('hc:uuid-581');
      expect(link!.state, WorkoutLinkState.tombstoned);
      expect(link.entryId, isNull);
      final blob = jsonDecode(ws.disk[WorkoutSyncStore.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['links'], {
        'hc:uuid-581': {'state': 'tombstoned'},
      });
    });

    testWidgets('DELETE failure restores the row AND the link state',
        (tester) async {
      final ws = await _freshWorkoutStore();
      final server = _FakeServer([_syncedEntry()])..failDeletes = true;
      await _pumpHistory(tester, server);

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await _confirmDelete(tester);

      expect(server.capturedDeletes, [581]);
      // Row restored…
      expect(find.text('Walking · 34 min'), findsOneWidget);
      // …and the link restored with it (not left tombstoned).
      final link = ws.store.linkForKey('hc:uuid-581');
      expect(link!.state, WorkoutLinkState.linked);
      expect(link.entryId, 581);
      expect(ws.store.keyForEntry(581), 'hc:uuid-581');
    });

    testWidgets('local-only synced delete tombstones via the cancel path',
        (tester) async {
      final ws = await _freshWorkoutStore();
      // The entry exists ONLY as a staged local record (never
      // reached the server): the pull is empty, the outbox
      // overlay renders it, and cancelling the record IS the
      // delete — no server DELETE may fire. POSTs fail so the
      // screen's load-time flush cannot promote it to
      // server-known before the delete.
      final server = _FakeServer([])..failPosts = true;
      final outbox = _freshOutbox();
      await outbox.stage(
        QuickLogEntry(
          id: 581,
          categoryId: 7,
          body: 'Walking · 34 min',
          chips: 'Workout, Health Connect',
          manualText: '',
          timestamp: _now - 3600000,
        ),
        serverKnown: false,
        ownerEmail: 'a@example.com',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: HistoryScreen(backend: server.backend(), outbox: outbox),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Walking · 34 min'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await _confirmDelete(tester);

      expect(server.capturedDeletes, isEmpty);
      expect(find.text('Walking · 34 min'), findsNothing);
      expect(ws.store.linkForKey('hc:uuid-581')!.state,
          WorkoutLinkState.tombstoned);
    });

    testWidgets('deleting a MANUAL entry writes no tombstone',
        (tester) async {
      final ws = await _freshWorkoutStore(withLink: false);
      final server = _FakeServer([_manualEntry()]);
      await _pumpHistory(tester, server);

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await _confirmDelete(tester);

      expect(server.capturedDeletes, [900]);
      expect(ws.store.links, isEmpty);
    });
  });

  group('category edit of a synced entry (R2, pinned as known)', () {
    testWidgets('entry survives, link intact', (tester) async {
      final ws = await _freshWorkoutStore();
      final server = _FakeServer([_syncedEntry()]);
      await _pumpHistory(tester, server);

      await tester.tap(find.text('Walking · 34 min'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SYMPTOMS'));
      await tester.pumpAndSettle();

      // The shipped category-edit semantics apply (chips replaced
      // wholesale — the marker is lost from the ENTRY, R2)…
      expect(server.capturedPosts, hasLength(1));
      expect(server.capturedPosts.single['categoryId'], 3);
      expect(server.capturedPosts.single['chips'], '["Symptoms"]');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      // …the entry survives in the list…
      expect(find.text('Walking · 34 min'), findsOneWidget);
      // …and the LINK — the identity of record — is intact, so
      // the next sync can never duplicate the session.
      final link = ws.store.linkForKey('hc:uuid-581');
      expect(link, isNotNull);
      expect(link!.state, WorkoutLinkState.linked);
      expect(link.entryId, 581);
    });
  });
}
