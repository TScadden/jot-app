import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

/// Counter mutation durability — founder defect, Oct 20, 2026
/// (production VC 10094): tapping Archive or End (delete) on ONE
/// counter made ALL counters disappear ~1s later, and on leaving /
/// re-entering Settings ALL counters were back with the target NOT
/// deleted/archived. Mutations never persisted.
///
/// Otto's live proof cleared the server (pushes persist when they
/// fire with a fresh base); the defect is the client state
/// interplay. These tests drive the REAL [TabsBackend] (per-instance
/// TTL cache, static in-flight dedupe, profile-mutation epoch) over
/// a fake HTTP server with REAL semantics:
/// - the server is a per-field map; POST /api/sync/profile upserts
///   only the fields sent (the server's COALESCE behaviour);
/// - GET /api/sync/pull SNAPSHOTS the server state when the request
///   STARTS and can be held in flight, so a pull that started before
///   a push lands afterwards with the pre-push body — the exact
///   stale-landing hazard;
/// - pulls and pushes can be failed on demand.

const _email = 'founder@tabs.app';

/// Unique token per test: the backend's in-flight pull slot is
/// static and keyed by (baseUrl, token), so tests must not share a
/// token — a pull left in flight by one test would otherwise be
/// joined by the next test's screens.
int _tokenSeq = 0;
FakeSessionStore _session() => FakeSessionStore()
  ..token = 'fake-token-ctr-${_tokenSeq++}'
  ..email = _email;

class FakeCounterServer {
  /// Server-side profile fields (raw JSON strings, as stored).
  String eventCountersRaw;
  String counterHistoryRaw;

  bool failPush = false;
  bool failAllPulls = false;

  /// When set, pulls whose 1-based number is greater than this fail.
  int? failPullsAfterCount;

  int pullCount = 0;
  int pushCount = 0;
  final List<Map<String, dynamic>> pushes = [];

  /// Holds are a QUEUE (correction round, Vera F3 test): each
  /// armed hold captures the next pull that starts, and
  /// [releaseHeldPull] releases the OLDEST held pull — so a test
  /// can hold a pull, arm the NEXT pull's hold too, then release
  /// them one at a time (two pushes landing during one logical
  /// pull, across its epoch re-issue).
  final List<Completer<void>> _heldPulls = [];
  int _holdsArmed = 0;

  FakeCounterServer({
    required List<Map<String, dynamic>> counters,
    List<Map<String, dynamic>> history = const [],
  })  : eventCountersRaw = jsonEncode(counters),
        counterHistoryRaw = jsonEncode(history);

  /// The next GET /api/sync/pull captures its snapshot, then waits
  /// until [releaseHeldPull] before responding.
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
        'profile': {
          'eventCounters': eventCountersRaw,
          'counterHistory': counterHistoryRaw,
        },
        'insights': const [],
      };

  List<Map<String, dynamic>> get serverCounters =>
      (jsonDecode(eventCountersRaw) as List)
          .cast<Map<String, dynamic>>();

  http.Client client() => MockClient((request) async {
        if (request.url.path == '/api/sync/pull' &&
            request.method == 'GET') {
          pullCount++;
          final n = pullCount;
          // Snapshot at request START — a held pull delivers this
          // body even if a push lands while it is in flight.
          final snapshot = _pullBodySnapshot();
          if (_holdsArmed > 0) {
            _holdsArmed--;
            final completer = Completer<void>();
            _heldPulls.add(completer);
            await completer.future;
          }
          if (failAllPulls ||
              (failPullsAfterCount != null && n > failPullsAfterCount!)) {
            return http.Response('pull failed', 500);
          }
          return http.Response(jsonEncode(snapshot), 200);
        }
        if (request.url.path == '/api/sync/profile' &&
            request.method == 'POST') {
          pushCount++;
          final fields =
              jsonDecode(request.body) as Map<String, dynamic>;
          pushes.add(fields);
          if (failPush) return http.Response('push failed', 500);
          // Per-field upsert (COALESCE): only sent fields change.
          if (fields.containsKey('eventCounters')) {
            eventCountersRaw = fields['eventCounters'] as String;
          }
          if (fields.containsKey('counterHistory')) {
            counterHistoryRaw = fields['counterHistory'] as String;
          }
          return http.Response('{}', 200);
        }
        return http.Response('not found', 404);
      });

  TabsBackend backend(FakeSessionStore store) =>
      TabsBackend(client: client(), sessionStore: store);
}

SettingsStore fakeStore(Map<String, String> map) => SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

DateTime _midnightPlus(int days) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + days);
}

/// 12 counters, c1..c12. c7 deliberately has NO `isArchived` key
/// (native-era encoding on the founder's account — 3 such rows):
/// it must pass through every filter untouched.
List<Map<String, dynamic>> _twelveCounters() => [
      for (var i = 1; i <= 12; i++)
        if (i == 7)
          {
            'id': 'c7',
            'name': 'Counter 7',
            'targetDate':
                _midnightPlus(7).millisecondsSinceEpoch,
            'isUp': false,
            'autoUp': false,
            'isFavorite': false,
            // no isArchived key on purpose
          }
        else
          {
            'id': 'c$i',
            'name': 'Counter $i',
            'targetDate':
                _midnightPlus(i).millisecondsSinceEpoch,
            'isUp': false,
            'autoUp': false,
            'isFavorite': false,
            'isArchived': false,
          },
    ];

Future<void> _pumpSettings(
  WidgetTester tester,
  TabsBackend backend,
  Map<String, String> storeMap,
) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // Unmount first: pumping a same-type SettingsScreen over a live
  // one would REUSE its State (no initState, no reload) — the
  // leave-and-return this simulates must be a genuine fresh mount.
  await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  await tester.pump();
  await tester.pumpWidget(MaterialApp(
    home: SettingsScreen(
      email: _email,
      backend: backend,
      settingsStore: fakeStore(storeMap),
      notificationService: FakeReminderNotificationService(),
      openEventCounters: true,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('Defect A — stale in-flight pull vs profile push (backend)',
      () {
    test(
        'a pull that STARTED before a push and LANDS after it is '
        'discarded and re-issued; the caller and the TTL cache only '
        'ever see the post-push body', () async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final a = server.backend(store);
      final b = server.backend(store);

      // B starts a slow pull; the server snapshots 12 active
      // counters and holds the response.
      server.holdNextPull();
      final slowPull = b.fetchSyncPull();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.pullCount, 1);

      // A pushes the archive of c3 (the mutation) while B's pull
      // is still in flight.
      final archived = _twelveCounters()
          .map((c) => c['id'] == 'c3'
              ? {...c, 'isArchived': true}
              : c)
          .toList();
      final ok = await a
          .postSyncProfile({'eventCounters': jsonEncode(archived)});
      expect(ok, isTrue);

      // The pre-push pull now lands.
      server.releaseHeldPull();
      final body = await slowPull;

      // The body B's caller receives must be the POST-push body:
      // the stale landing was discarded and the GET re-issued once.
      final counters = (jsonDecode(
              (body!['profile'] as Map)['eventCounters'] as String)
          as List)
          .cast<Map<String, dynamic>>();
      final c3 = counters.firstWhere((c) => c['id'] == 'c3');
      expect(c3['isArchived'], isTrue,
          reason: 'stale pre-push body must never be delivered');
      expect(server.pullCount, 2,
          reason: 'exactly one bounded re-issue');

      // And B's per-instance TTL cache must not serve the stale
      // body on the next read either.
      final again = await b.fetchSyncPull();
      final againCounters = (jsonDecode(
              (again!['profile'] as Map)['eventCounters'] as String)
          as List)
          .cast<Map<String, dynamic>>();
      expect(
          againCounters.firstWhere((c) => c['id'] == 'c3')['isArchived'],
          isTrue,
          reason: 'stale body must never be cached as fresh');
    });

    test(
        'Vera F3: TWO pushes during one in-flight pull — the second '
        'lands during the epoch re-issue; the delivered body must '
        'reflect BOTH pushes (the re-issue loops while the epoch '
        'moves)', () async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final a = server.backend(store);
      final b = server.backend(store);

      List<Map<String, dynamic>> archivedBody(List<String> ids) =>
          _twelveCounters()
              .map((c) => ids.contains(c['id'])
                  ? {...c, 'isArchived': true}
                  : c)
              .toList();

      // B starts a slow pull (snapshot: nothing archived) and it
      // is held in flight.
      server.holdNextPull();
      final slowPull = b.fetchSyncPull();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.pullCount, 1);

      // Push 1 lands while pull 1 is in flight.
      expect(
          await a.postSyncProfile(
              {'eventCounters': jsonEncode(archivedBody(['c3']))}),
          isTrue);

      // Arm the hold for the re-issue pull BEFORE releasing pull
      // 1, then release: the re-issue starts (snapshotting the
      // post-push-1 state) and is itself held.
      server.holdNextPull();
      server.releaseHeldPull();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.pullCount, 2,
          reason: 'the stale landing was discarded and re-issued');

      // Push 2 lands DURING the re-issue — the window Vera F3
      // names (bulk archive in quick succession).
      expect(
          await a.postSyncProfile(
              {'eventCounters': jsonEncode(archivedBody(['c3', 'c5']))}),
          isTrue);

      // The re-issued pull now lands with a body that predates
      // push 2. The single-re-issue code delivered exactly this
      // body as fresh; the loop must re-issue AGAIN.
      server.releaseHeldPull();
      final body = await slowPull;

      final counters = (jsonDecode(
              (body!['profile'] as Map)['eventCounters'] as String)
          as List)
          .cast<Map<String, dynamic>>();
      expect(counters.firstWhere((c) => c['id'] == 'c3')['isArchived'],
          isTrue);
      expect(counters.firstWhere((c) => c['id'] == 'c5')['isArchived'],
          isTrue,
          reason: 'a body predating the second push must never be '
              'delivered as fresh');
      expect(server.pullCount, 3,
          reason: 'initial pull + two epoch re-issues');
    });
  });

  group('Founder sequence (widget, faithful server)', () {
    testWidgets(
        'delete: slow pre-tap pull lands after the push; leaving '
        'and re-entering keeps the delete; the list never empties',
        (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);
      final b = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      expect(find.text('Counter 3'), findsOneWidget);
      expect(find.text('No counters yet.'), findsNothing);
      // The row with NO isArchived key renders as an active counter.
      expect(find.text('Counter 7'), findsOneWidget);

      // A second instance starts a slow pull BEFORE the tap; the
      // server snapshots the pre-mutation state and holds it.
      server.holdNextPull();
      final slowPull = b.fetchSyncPull();
      await tester.pump();
      await tester.pump();

      // Tap delete on c3. The save re-pulls fresh (joining the
      // held in-flight pull), so nothing changes on screen while
      // the pull is held — and nothing blanks.
      await tester.tap(find.byKey(const ValueKey('counter_delete_c3')));
      await tester.pump();
      expect(find.text('Counter 3'), findsOneWidget);
      expect(find.text('No counters yet.'), findsNothing);

      // The pre-mutation pull lands; the save computes the delete
      // against that (still server-current) list and pushes.
      server.releaseHeldPull();
      await tester.pumpAndSettle();
      await slowPull;

      // Server-side: the push persisted the delete — the archive
      // marker AND a deletedAt stamp.
      final serverC3 =
          server.serverCounters.firstWhere((c) => c['id'] == 'c3');
      expect(serverC3['isArchived'], isTrue);
      expect(serverC3['deletedAt'], isA<int>());
      // The row that had NO isArchived key was treated as active
      // throughout (never deleted by the splice, never dropped).
      final serverC7 =
          server.serverCounters.firstWhere((c) => c['id'] == 'c7');
      expect(serverC7['isArchived'], isNot(isTrue));
      expect(serverC7.containsKey('deletedAt'), isFalse);

      // On this screen c3 is now in the Deleted section.
      expect(find.text('DELETED COUNTERS'), findsOneWidget);
      expect(find.textContaining('Counter 3 (Deleted:'), findsOneWidget);
      expect(find.text('No counters yet.'), findsNothing);

      // Leave and re-enter on the SECOND instance — the one whose
      // pull was in flight across the push. Its TTL cache must not
      // resurrect the pre-delete state.
      await _pumpSettings(tester, b, storeMap);
      expect(find.text('DELETED COUNTERS'), findsOneWidget);
      expect(find.textContaining('Counter 3 (Deleted:'), findsOneWidget);
      // F8 (correction round): the deleted row renders MUTED — its
      // combined label in textSecondary, an active row's name in
      // textPrimary. (Replaces the vacuous isNot(equals(null))
      // color assertion.)
      final label =
          tester.widget<Text>(find.textContaining('Counter 3 (Deleted:'));
      expect(label.style!.color, NotelColors.textSecondary);
      final activeName = tester.widget<Text>(find.text('Counter 1'));
      expect(activeName.style!.color, NotelColors.textPrimary);
      // Juno C1: a successful load confirms the Synced chip.
      expect(find.text('Synced'), findsOneWidget);
      expect(find.text('Not synced'), findsNothing);
      expect(find.text('No counters yet.'), findsNothing);
      // c3's only action in the Deleted section is 'Bring back';
      // the 11 active rows still offer Delete.
      expect(find.byKey(const ValueKey('counter_restore_c3')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('counter_delete_c3')),
          findsNothing);
      expect(find.byTooltip('Delete counter'), findsNWidgets(11));
      // The no-isArchived-key row still renders after re-entry.
      expect(find.text('Counter 7'), findsOneWidget);
    });

    testWidgets(
        'delete of the marker-less row: the stale pull lands '
        'after the push; a SECOND save still carries the marker '
        'and the stamp on the pushed blob', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);
      final b = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      expect(find.text('Counter 7'), findsOneWidget);
      // The fixture premise: c7 has NO isArchived key server-side
      // (the native-era encoding of the founder's 3 stuck rows).
      final fixtureC7 =
          server.serverCounters.firstWhere((c) => c['id'] == 'c7');
      expect(fixtureC7.containsKey('isArchived'), isFalse);

      // A second instance starts a slow pull BEFORE the tap; the
      // server snapshots the pre-mutation state and holds it.
      server.holdNextPull();
      final slowPull = b.fetchSyncPull();
      await tester.pump();
      await tester.pump();

      // Delete c7 — the marker-less row itself. The save re-pulls
      // fresh (joining the held in-flight pull), so nothing
      // changes on screen while the pull is held.
      await tester.tap(find.byKey(const ValueKey('counter_delete_c7')));
      await tester.pump();
      expect(find.text('Counter 7'), findsOneWidget);
      expect(find.text('No counters yet.'), findsNothing);

      // The pre-mutation pull lands; the save computes the delete
      // against that (still server-current) list and pushes.
      server.releaseHeldPull();
      await tester.pumpAndSettle();
      await slowPull;

      // The delete of the marker-less row reached the server and
      // stamped the marker and the deletedAt stamp explicitly.
      expect(server.pushCount, 1);
      final afterFirst =
          server.serverCounters.firstWhere((c) => c['id'] == 'c7');
      expect(afterFirst['isArchived'], isTrue,
          reason: 'deleting the no-key row must stamp isArchived '
              'true on the server');
      expect(afterFirst['deletedAt'], isA<int>(),
          reason: 'deleting the no-key row must stamp deletedAt '
              'on the server');
      final stamp7 = afterFirst['deletedAt'] as int;
      expect(find.text('DELETED COUNTERS'), findsOneWidget);
      expect(find.textContaining('Counter 7 (Deleted:'), findsOneWidget);

      // The step no other counter test performs: SAVE AGAIN after
      // the stale pull has landed. Re-enter on the second instance
      // (the one whose pull crossed the push) and delete c4. The
      // pre-fix client built this second save on its stale
      // snapshot, and the push silently dropped the first
      // delete's marker — the step that made the revert
      // permanent.
      await _pumpSettings(tester, b, storeMap);
      expect(find.text('DELETED COUNTERS'), findsOneWidget);
      expect(find.textContaining('Counter 7 (Deleted:'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('counter_delete_c4')));
      await tester.pumpAndSettle();

      // Exactly one more push fired, and the marker and stamp
      // survived it — both in the pushed blob itself and in the
      // stored server state.
      expect(server.pushCount, 2);
      final pushedBlob = (jsonDecode(
              server.pushes.last['eventCounters'] as String) as List)
          .cast<Map<String, dynamic>>();
      expect(
          pushedBlob.firstWhere((c) => c['id'] == 'c7')['isArchived'],
          isTrue,
          reason: 'the second save must not drop the marker-less '
              "row's deleted marker from the pushed blob");
      expect(
          pushedBlob.firstWhere((c) => c['id'] == 'c7')['deletedAt'],
          stamp7,
          reason: 'the second save must carry the marker-less '
              "row's deletedAt stamp forward, not drop or restamp it");
      expect(
          pushedBlob.firstWhere((c) => c['id'] == 'c4')['isArchived'],
          isTrue);
      expect(
          pushedBlob.firstWhere((c) => c['id'] == 'c4')['deletedAt'],
          isA<int>());
      expect(
          server.serverCounters
              .firstWhere((c) => c['id'] == 'c7')['isArchived'],
          isTrue);
      expect(
          server.serverCounters
              .firstWhere((c) => c['id'] == 'c7')['deletedAt'],
          stamp7);
      expect(
          server.serverCounters
              .firstWhere((c) => c['id'] == 'c4')['isArchived'],
          isTrue);
      // The list never emptied along the way.
      expect(find.text('No counters yet.'), findsNothing);
    });

    testWidgets(
        'Vera F1: double-tap on delete during an in-flight save '
        'deletes exactly once — the buttons disable while the '
        'save runs and the intent is absolute, never a fresh-row '
        'toggle that flips back', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      expect(find.text('Counter 3'), findsOneWidget);

      // Hold the save's fresh re-pull so the save stays in flight
      // across the second tap.
      server.holdNextPull();
      await tester.tap(find.byKey(const ValueKey('counter_delete_c3')));
      await tester.pump();
      await tester.pump();

      // While the save runs, every counter action button is
      // disabled (the save-in-flight guard).
      expect(
          tester
              .widget<IconButton>(
                  find.byKey(const ValueKey('counter_delete_c3')))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<IconButton>(
                  find.byKey(const ValueKey('counter_edit_c3')))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<IconButton>(
                  find.byKey(const ValueKey('counter_end_c3')))
              .onPressed,
          isNull);

      // The double-tap (and a stray End tap) hit disabled buttons:
      // nothing queues behind the running save.
      await tester.tap(find.byKey(const ValueKey('counter_delete_c3')));
      await tester.tap(find.byKey(const ValueKey('counter_end_c4')));
      await tester.pump();

      server.releaseHeldPull();
      await tester.pumpAndSettle();

      // Exactly ONE push fired, and it deleted c3 — with the old
      // fresh-row toggle, the second save restored it again.
      expect(server.pushCount, 1);
      final serverC3 =
          server.serverCounters.firstWhere((c) => c['id'] == 'c3');
      expect(serverC3['isArchived'], isTrue);
      expect(serverC3['deletedAt'], isA<int>());
      expect(server.serverCounters.any((c) => c['id'] == 'c4'), isTrue);
      expect(find.text('DELETED COUNTERS'), findsOneWidget);
      // The guard cleared when the save finished: the row's
      // restore button is live.
      expect(
          tester
              .widget<TextButton>(
                  find.byKey(const ValueKey('counter_restore_c3')))
              .onPressed,
          isNotNull);
    });

    testWidgets(
        'end/delete: slow pre-tap pull lands after the push; leaving '
        'and re-entering keeps the deletion; the list never empties',
        (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);
      final b = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      expect(find.text('Counter 5'), findsOneWidget);

      server.holdNextPull();
      final slowPull = b.fetchSyncPull();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('counter_end_c5')));
      await tester.pump();
      // While the save is in flight the list is untouched, not blank.
      expect(find.text('Counter 5'), findsOneWidget);
      expect(find.text('No counters yet.'), findsNothing);

      server.releaseHeldPull();
      await tester.pumpAndSettle();
      await slowPull;

      // Server-side: c5 is gone and history carries it.
      expect(server.serverCounters.any((c) => c['id'] == 'c5'),
          isFalse);
      expect(server.serverCounters.length, 11);
      final history =
          jsonDecode(server.counterHistoryRaw) as List<dynamic>;
      expect(history.first['name'], 'Counter 5');

      // On screen: gone as a row, present only as a Past Counters
      // line; the other 11 never disappeared.
      expect(find.text('Counter 5'), findsNothing);
      expect(find.textContaining('Counter 5 (Ended:'), findsOneWidget);
      expect(find.text('No counters yet.'), findsNothing);
      for (var i = 1; i <= 12; i++) {
        if (i == 5) continue;
        expect(find.text('Counter $i'), findsOneWidget,
            reason: 'Counter $i must survive the delete of c5');
      }

      // Leave and re-enter on the second instance: still deleted.
      await _pumpSettings(tester, b, storeMap);
      expect(find.text('Counter 5'), findsNothing);
      expect(find.text('No counters yet.'), findsNothing);
      expect(find.byKey(const ValueKey('counter_row_c5')), findsNothing);
      for (var i = 1; i <= 12; i++) {
        if (i == 5) continue;
        expect(find.text('Counter $i'), findsOneWidget,
            reason: 'Counter $i still present after re-entry');
      }
    });

    testWidgets(
        'failed push: honest error, the counter stays, the list '
        'does not blank and does not claim success', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      server.failPush = true;
      // The save's fresh re-pull succeeds, the push fails, and the
      // reload after the failed push ALSO fails: the screen must
      // keep its last-known data, not blank to factory defaults —
      // the founder's ~1s all-counters-gone flicker.
      server.failPullsAfterCount = server.pullCount + 1;

      await tester.tap(find.byKey(const ValueKey('counter_end_c5')));
      await tester.pumpAndSettle();

      expect(
          find.text('Could not save. Check your connection and try again.'),
          findsOneWidget);
      // Server still holds c5 (the push never landed) and the
      // screen honestly shows it again — with the error above,
      // never a silent success and never an empty list.
      expect(server.serverCounters.any((c) => c['id'] == 'c5'), isTrue);
      expect(find.text('Counter 5'), findsOneWidget);
      expect(find.text('No counters yet.'), findsNothing);
      for (var i = 1; i <= 12; i++) {
        expect(find.text('Counter $i'), findsOneWidget,
            reason: 'Counter $i must not blank on a failed save');
      }
      // No tombstone survives a failed delete: a later honest pull
      // (server still carrying c5) must keep showing it.
      final tombstones = await fakeStore(storeMap)
          .getDeletedCounterIds(ownerEmail: _email);
      expect(tombstones, isEmpty);
    });

    testWidgets(
        'failed fresh pull at save time: abort with the save error, '
        'no push is fired, the list is unchanged', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      final pushesBefore = server.pushCount;
      server.failAllPulls = true;

      await tester.tap(find.byKey(const ValueKey('counter_delete_c3')));
      await tester.pumpAndSettle();

      expect(server.pushCount, pushesBefore,
          reason: 'whole-blob rule: no splice onto a stale base');
      expect(
          find.text('Could not save. Check your connection and try again.'),
          findsWidgets);
      // c3 is still active (its button still offers Delete).
      expect(find.byTooltip('Delete counter'), findsNWidgets(12));
      expect(find.text('No counters yet.'), findsNothing);
      // Juno C1: an aborted save drops the Synced chip until the
      // next successful pull/push.
      expect(find.text('Synced'), findsNothing);
      expect(find.text('Not synced'), findsOneWidget);
    });
  });

  group('Delete/Restore round trip (Oct 27, 2026)', () {
    testWidgets(
        'delete stamps the blob and hides the counter from Settings '
        'AND the Home data path; a second save after the stale '
        'landing keeps marker + stamp; restore returns the counter '
        'intact with NO deletedAt key', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);
      final b = server.backend(store);

      // c3's original row, for the restore intactness assertions.
      final originalC3 =
          server.serverCounters.firstWhere((c) => c['id'] == 'c3');

      await _pumpSettings(tester, a, storeMap);

      // Stale pull in flight across the delete push (the founder
      // sequence): it lands after the push and must not resurrect.
      server.holdNextPull();
      final slowPull = b.fetchSyncPull();
      await tester.pump();
      await tester.pump();

      final tapBefore = DateTime.now().millisecondsSinceEpoch;
      await tester.tap(find.byKey(const ValueKey('counter_delete_c3')));
      await tester.pump();
      server.releaseHeldPull();
      await tester.pumpAndSettle();
      await slowPull;
      final tapAfter = DateTime.now().millisecondsSinceEpoch;

      // (a) The pushed blob carries marker + stamp, and c3 is out
      // of BOTH the Settings active list and the Home data path
      // (the activeEventCounters / !isArchived filter).
      var serverC3 =
          server.serverCounters.firstWhere((c) => c['id'] == 'c3');
      expect(serverC3['isArchived'], isTrue);
      expect(serverC3['deletedAt'], isA<int>());
      final stamp = serverC3['deletedAt'] as int;
      expect(stamp, greaterThanOrEqualTo(tapBefore));
      expect(stamp, lessThanOrEqualTo(tapAfter));
      final parsed =
          server.serverCounters.map(EventCounterItem.fromMap).toList();
      expect(activeEventCounters(parsed).any((c) => c.id == 'c3'),
          isFalse);
      expect(activeEventCounters(parsed).length, 11);
      expect(parsed.firstWhere((c) => c.id == 'c3').deletedAt, stamp);
      expect(find.text('DELETED COUNTERS'), findsOneWidget);
      expect(find.byTooltip('Delete counter'), findsNWidgets(11));

      // (c) A SECOND save after the stale landing pushes the whole
      // blob again; c3's marker + stamp must survive it byte-exact.
      await tester.tap(find.byKey(const ValueKey('counter_delete_c4')));
      await tester.pumpAndSettle();
      serverC3 = server.serverCounters.firstWhere((c) => c['id'] == 'c3');
      expect(serverC3['isArchived'], isTrue);
      expect(serverC3['deletedAt'], stamp,
          reason: 'a later whole-blob save must carry the stamp '
              'forward, not drop or restamp it');
      final serverC4 =
          server.serverCounters.firstWhere((c) => c['id'] == 'c4');
      expect(serverC4['isArchived'], isTrue);
      expect(serverC4['deletedAt'], isA<int>());

      // (b) Restore c3: back active with every field intact, and
      // the pushed blob carries NO deletedAt key for it (the key's
      // absence is what clears the stamp server-side).
      await tester.tap(find.byKey(const ValueKey('counter_restore_c3')));
      await tester.pumpAndSettle();
      serverC3 = server.serverCounters.firstWhere((c) => c['id'] == 'c3');
      expect(serverC3['isArchived'], isFalse);
      expect(serverC3.containsKey('deletedAt'), isFalse);
      expect(serverC3['name'], originalC3['name']);
      expect(serverC3['targetDate'], originalC3['targetDate']);
      expect(serverC3['isUp'], originalC3['isUp']);
      expect(serverC3['autoUp'], originalC3['autoUp']);
      expect(serverC3['isFavorite'], originalC3['isFavorite']);
      // The restore is by-id: c4 stays deleted.
      final serverC4After =
          server.serverCounters.firstWhere((c) => c['id'] == 'c4');
      expect(serverC4After['isArchived'], isTrue);
      expect(serverC4After['deletedAt'], serverC4['deletedAt']);
      // On screen: c3 is an active row again; c4 remains deleted.
      expect(find.text('Counter 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('counter_delete_c3')),
          findsOneWidget);
      expect(find.textContaining('Counter 4 (Deleted:'), findsOneWidget);
      expect(find.text('Bring back'), findsOneWidget);
      // And c3 is back on the Home data path, stamp cleared.
      final parsedAfter =
          server.serverCounters.map(EventCounterItem.fromMap).toList();
      expect(activeEventCounters(parsedAfter).any((c) => c.id == 'c3'),
          isTrue);
      expect(parsedAfter.firstWhere((c) => c.id == 'c3').deletedAt,
          isNull);
    });
  });

  group('Defect D — delete tombstones', () {
    testWidgets(
        'a pull body that still carries the deleted id does not '
        'resurrect it; once a body lacks the id the tombstone is '
        'pruned', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      await tester.tap(find.byKey(const ValueKey('counter_end_c5')));
      await tester.pumpAndSettle();
      expect(server.serverCounters.any((c) => c['id'] == 'c5'),
          isFalse);

      // Tombstone recorded at save time, bound to this account.
      var tombstones = await fakeStore(storeMap)
          .getDeletedCounterIds(ownerEmail: _email);
      expect(tombstones, {'c5'});

      // A stale server snapshot still carries c5 (e.g. a lagging
      // read): re-entering must NOT resurrect it, and the
      // tombstone must be kept while the server still carries it.
      server.eventCountersRaw = jsonEncode(_twelveCounters());
      await _pumpSettings(tester, a, storeMap);
      expect(find.text('Counter 5'), findsNothing);
      expect(find.byKey(const ValueKey('counter_row_c5')), findsNothing);
      tombstones = await fakeStore(storeMap)
          .getDeletedCounterIds(ownerEmail: _email);
      expect(tombstones, {'c5'});

      // Once a pulled list no longer contains c5, the tombstone is
      // pruned (self-cleaning, native parity). The re-entry forces
      // a real pull (the same invalidation the app's reload paths
      // run) instead of the backend instance's TTL cache.
      server.eventCountersRaw =
          jsonEncode(_twelveCounters().where((c) => c['id'] != 'c5').toList());
      a.invalidateSyncPull();
      await _pumpSettings(tester, a, storeMap);
      expect(find.text('Counter 5'), findsNothing);
      tombstones = await fakeStore(storeMap)
          .getDeletedCounterIds(ownerEmail: _email);
      expect(tombstones, isEmpty);
    });

    testWidgets(
        'Home counter load shares the tombstone filter: a pulled '
        'list still carrying the deleted id does not show it on '
        'Home either', (tester) async {
      HomeDataCache.instance.debugReset();
      addTearDown(HomeDataCache.instance.debugReset);
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final backend = server.backend(store);
      final storeMap = <String, String>{};
      // c1 was deleted earlier; its tombstone is on device and a
      // stale pull body still carries c1.
      await fakeStore(storeMap)
          .setDeletedCounterIds({'c1'}, ownerEmail: _email);
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          email: _email,
          tabsBackend: backend,
          settingsStore: fakeStore(storeMap),
        ),
      ));
      // Fixed pumps, never pumpAndSettle: the counter rotator's
      // auto-advance timer schedules frames forever (the r34
      // pattern). The pumps below let the pull land, the tombstone
      // post-pass run, and its filtered frame render.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      // The rotator's first counter is c2, not the tombstoned c1.
      expect(find.text('Until Counter 1'), findsNothing);
      expect(find.text('Until Counter 2'), findsOneWidget);
      // Tombstone kept: the server list still carries c1.
      final tombstones = await fakeStore(storeMap)
          .getDeletedCounterIds(ownerEmail: _email);
      expect(tombstones, {'c1'});
    });

    test('tombstones are account-bound: another account never '
        'inherits them, and clear() wipes them', () async {
      final map = <String, String>{};
      final store = fakeStore(map);
      await store.setDeletedCounterIds({'c5'},
          ownerEmail: 'First@Tabs.app');
      expect(
          await store.getDeletedCounterIds(ownerEmail: 'first@tabs.app'),
          {'c5'});
      // A different account reads empty AND the stored set is
      // dropped, so it can never leak into that account's list.
      expect(
          await store.getDeletedCounterIds(ownerEmail: 'other@tabs.app'),
          isEmpty);
      expect(
          await store.getDeletedCounterIds(ownerEmail: 'first@tabs.app'),
          isEmpty);

      await store.setDeletedCounterIds({'c9'}, ownerEmail: _email);
      await store.clear();
      expect(await store.getDeletedCounterIds(ownerEmail: _email),
          isEmpty);
      expect(map.containsKey(SettingsStore.deletedCounterIdsKey),
          isFalse);
    });

    test('an UNOWNED tombstone set is adopted by the first account '
        'that reads it (email-less surfaces write unbound), then '
        'bound against other accounts', () async {
      final map = <String, String>{};
      final store = fakeStore(map);
      // Written by a surface that had no account email.
      await store.setDeletedCounterIds({'c7'});
      expect(await store.getDeletedCounterIds(ownerEmail: _email),
          {'c7'});
      // Adopted: now positively owned, so another account drops it.
      expect(
          await store.getDeletedCounterIds(ownerEmail: 'other@tabs.app'),
          isEmpty);
    });
  });

  group('Correction round — Vera F2 (Sync Now / Recover parity)', () {
    testWidgets(
        'Sync Now runs the tombstone post-pass: a deleted counter '
        'with an active tombstone does NOT reappear after Sync Now '
        'even when the synced body still carries its id',
        (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      // Delete c5 for real: the server drops it, the tombstone is
      // recorded locally.
      await tester.tap(find.byKey(const ValueKey('counter_end_c5')));
      await tester.pumpAndSettle();
      expect(server.serverCounters.any((c) => c['id'] == 'c5'), isFalse);
      expect(
          await fakeStore(storeMap)
              .getDeletedCounterIds(ownerEmail: _email),
          {'c5'});

      // The server body goes stale (a lagging replica still
      // carries c5) — exactly the body a Sync Now would land.
      server.eventCountersRaw = jsonEncode(_twelveCounters());

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sync_now_button')));
      await tester.pumpAndSettle();
      expect(find.text('Sync complete!'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event Counters'));
      await tester.pumpAndSettle();
      // The pre-fix _manualSync set _data straight from the pull:
      // c5 was back. The post-pass must have filtered it.
      expect(find.text('Counter 5'), findsNothing);
      expect(find.byKey(const ValueKey('counter_row_c5')), findsNothing);
      expect(find.text('Counter 4'), findsOneWidget);
      // Tombstone still active: the synced body still carries c5.
      expect(
          await fakeStore(storeMap)
              .getDeletedCounterIds(ownerEmail: _email),
          {'c5'});
      // Juno C1: the successful sync confirms the chip.
      expect(find.text('Synced'), findsOneWidget);
    });

    testWidgets(
        'Defect B side door: load fails at open, Sync Now succeeds, '
        'then a save fails AND its reload pull fails — the screen '
        'keeps the SYNCED data instead of resetting to defaults',
        (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      // First-ever load fails: honest defaults, not-synced chip.
      server.failAllPulls = true;
      await _pumpSettings(tester, a, storeMap);
      expect(find.text('No counters yet.'), findsOneWidget);
      expect(find.text('Not synced'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);

      // Sync Now succeeds and becomes this session's real data.
      server.failAllPulls = false;
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sync_now_button')));
      await tester.pumpAndSettle();
      expect(find.text('Sync complete!'), findsOneWidget);
      // Flush the sync snack so the save-error snack below is the
      // one in the tree when asserted (the messenger QUEUES snacks;
      // a queued one is not yet rendered).
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event Counters'));
      await tester.pumpAndSettle();
      for (var i = 1; i <= 12; i++) {
        expect(find.text('Counter $i'), findsOneWidget);
      }
      expect(find.text('Synced'), findsOneWidget);

      // A save whose push fails and whose reload pull ALSO fails.
      // Pre-fix, _manualSync never set _hasRealData, so the failed
      // reload reset the screen to factory defaults — every
      // counter gone. The save's own fresh pull still succeeds.
      server.failPush = true;
      server.failPullsAfterCount = server.pullCount + 1;
      await tester.tap(find.byKey(const ValueKey('counter_end_c5')));
      await tester.pumpAndSettle();

      expect(
          find.text('Could not save. Check your connection and try again.'),
          findsOneWidget);
      expect(find.text('No counters yet.'), findsNothing);
      for (var i = 1; i <= 12; i++) {
        expect(find.text('Counter $i'), findsOneWidget,
            reason: 'Counter $i must survive on the synced '
                'last-known data');
      }
      // Juno C1: kept-data after a failed load/save is NOT synced.
      expect(find.text('Not synced'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
    });
  });

  group('Correction round — Juno C1 residual (field-partial push)',
      () {
    testWidgets(
        'failed first load, then a successful NON-counter save '
        '(debounced Personal Context push): the counters chip '
        'still shows Not synced — a field-partial push confirms '
        'nothing about eventCounters, which were never pulled',
        (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      // Juno's exact sequence, step 1: the first-ever load fails.
      // The session sits on never-loaded defaults (_hasRealData
      // false, counters empty) and the chip honestly says so.
      server.failAllPulls = true;
      await _pumpSettings(tester, a, storeMap);
      expect(find.text('No counters yet.'), findsOneWidget);
      expect(find.text('Not synced'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
      final pullsAfterFailedLoad = server.pullCount;

      // Step 2: connectivity returns — but NO reload/pull happens.
      // The user instead saves a NON-counter field: the Personal
      // Context text, whose debounced save routes through
      // _pushProfile({'userContext': ...}).
      server.failAllPulls = false;
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      final contextField =
          find.byKey(const ValueKey('personal_context_field'));
      await tester.ensureVisible(contextField);
      await tester.enterText(contextField, 'Recovering well this week.');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      // The push landed, and it was field-partial: userContext
      // only, no eventCounters — and still no pull has ever
      // succeeded (no pull at all since the failed first load).
      expect(server.pushes, hasLength(1));
      expect(server.pushes.single.containsKey('userContext'), isTrue);
      expect(server.pushes.single.containsKey('eventCounters'),
          isFalse);
      expect(server.pullCount, pullsAfterFailedLoad,
          reason: 'the counter list was never pulled in this '
              'session');

      // Step 3: open Event Counters. Pre-fix, _pushProfile set
      // _syncConfirmed = true unconditionally, so the chip showed
      // cloud_done + 'Synced' over the never-pulled default list.
      await tester.tap(find.text('Event Counters'));
      await tester.pumpAndSettle();
      final chip = find.byKey(const ValueKey('counters_sync_chip'));
      expect(chip, findsOneWidget);
      expect(
          find.descendant(of: chip, matching: find.text('Not synced')),
          findsOneWidget);
      expect(
          find.descendant(of: chip, matching: find.text('Synced')),
          findsNothing);
      expect(find.text('No counters yet.'), findsOneWidget);
    });
  });

  group('Correction round — F8 dialog pins', () {
    testWidgets(
        'a failed CREATE counter save keeps the dialog open, fires '
        'no push, and creates nothing', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      await tester.tap(find.byKey(const ValueKey('add_counter')));
      await tester.pumpAndSettle();
      expect(find.text('New Counter'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('counter_name_field')), 'Dentist');

      // The save's fresh pull fails → the save aborts.
      server.failAllPulls = true;
      final pushesBefore = server.pushCount;
      await tester.tap(find.byKey(const ValueKey('counter_save')));
      await tester.pumpAndSettle();

      expect(server.pushCount, pushesBefore);
      // The dialog is STILL open with the typed name intact.
      expect(find.text('New Counter'), findsOneWidget);
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('counter_name_field')))
              .controller!
              .text,
          'Dentist');
      expect(server.serverCounters.length, 12);
    });

    testWidgets(
        'a failed EDIT counter save keeps the dialog open and the '
        'server row unchanged', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);

      await _pumpSettings(tester, a, storeMap);
      await tester.tap(find.byKey(const ValueKey('counter_edit_c3')));
      await tester.pumpAndSettle();
      expect(find.text('Edit Counter'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('counter_name_field')), 'Renamed');

      server.failAllPulls = true;
      final pushesBefore = server.pushCount;
      await tester.tap(find.byKey(const ValueKey('counter_save')));
      await tester.pumpAndSettle();

      expect(server.pushCount, pushesBefore);
      expect(find.text('Edit Counter'), findsOneWidget);
      expect(
          server.serverCounters.firstWhere((c) => c['id'] == 'c3')['name'],
          'Counter 3');
    });
  });

  group('Correction round — Juno C2 (tombstone account separation)',
      () {
    test('a null-owner read of a BOUND set returns empty and does '
        'NOT drop it; a null-owner read of an UNOWNED set returns '
        'it as-is', () async {
      final map = <String, String>{};
      final store = fakeStore(map);
      await store.setDeletedCounterIds({'c5'},
          ownerEmail: 'first@tabs.app');
      // The Research → Settings case: an email-less reader must
      // not see (and so cannot apply) another account's bound set.
      expect(await store.getDeletedCounterIds(), isEmpty);
      // ...and the set survives for its real owner.
      expect(
          await store.getDeletedCounterIds(ownerEmail: 'first@tabs.app'),
          {'c5'});

      final map2 = <String, String>{};
      final store2 = fakeStore(map2);
      await store2.setDeletedCounterIds({'c7'});
      expect(await store2.getDeletedCounterIds(), {'c7'});
    });

    test('clearDeletedCounterIds wipes exactly the two tombstone '
        'keys and leaves the other settings keys', () async {
      final map = <String, String>{};
      final store = fakeStore(map);
      await store.setDeletedCounterIds({'c5'}, ownerEmail: _email);
      await store.setThemeMode('LIGHT');
      await store.clearDeletedCounterIds();
      expect(map.containsKey(SettingsStore.deletedCounterIdsKey),
          isFalse);
      expect(map.containsKey(SettingsStore.deletedCounterOwnerKey),
          isFalse);
      expect(map[SettingsStore.themeModeKey], 'LIGHT');
      expect(await store.getDeletedCounterIds(ownerEmail: _email),
          isEmpty);
    });

    testWidgets(
        'cross-account Research surface: Settings constructed with '
        'NO email does not apply a previous account\'s bound '
        'tombstones — the counter renders', (tester) async {
      final server = FakeCounterServer(counters: _twelveCounters());
      final store = _session();
      final storeMap = <String, String>{};
      final a = server.backend(store);
      // A previous account deleted c5 on this device; its bound
      // tombstone set is on disk. The server (this account) still
      // carries c5 as a live counter.
      await fakeStore(storeMap).setDeletedCounterIds({'c5'},
          ownerEmail: 'previous@tabs.app');

      // The Research → Settings construction: no email threaded.
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          backend: a,
          settingsStore: fakeStore(storeMap),
          notificationService: FakeReminderNotificationService(),
          openEventCounters: true,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Counter 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('counter_row_c5')),
          findsOneWidget);
      // The previous account's set was NOT dropped by the
      // email-less read either — it is intact for its owner.
      expect(
          await fakeStore(storeMap).getDeletedCounterIds(
              ownerEmail: 'previous@tabs.app'),
          {'c5'});
    });

    testWidgets(
        'forced session expiry wipes the tombstone keys (and only '
        'those) from SettingsStore', (tester) async {
      // The AppFlow expiry handler constructs a REAL SettingsStore,
      // so the secure-storage channel is mocked with an in-memory
      // map seeded with the expired account's tombstones.
      final secure = <String, String>{
        SettingsStore.deletedCounterIdsKey: '["c5"]',
        SettingsStore.deletedCounterOwnerKey: _email,
        SettingsStore.themeModeKey: 'LIGHT',
      };
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments is Map
            ? (call.arguments as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure['${args['key']}'] = '${args['value']}';
            return null;
          case 'delete':
            secure.remove(args['key']);
            return null;
          case 'deleteAll':
            secure.clear();
            return null;
          case 'readAll':
            return Map<String, String>.of(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        TabsBackend.onSessionExpired = null;
      });

      final session = FakeSessionStore()
        ..token = 'fake-token-expiry'
        ..refreshToken = 'fake-refresh-expiry'
        ..email = _email;
      await tester.pumpWidget(MaterialApp(
        home: AppFlow(
          authApi: AuthApiClient(
              client: MockClient((_) async => http.Response('{}', 200))),
          sessionStore: session,
          onboardingStore: OnboardingStore.withStorage(
            read: (k) async => null,
            write: (k, v) async {},
            delete: (k) async {},
          ),
          weatherApi: WeatherApiClient(
              client: MockClient((request) async {
            if (request.url.host == 'ipinfo.io') {
              return http.Response(
                  '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
                  200);
            }
            return http.Response(
                '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
                200);
          })),
          notificationService: FakeReminderNotificationService(),
        ),
      ));
      // Past the splash; the legacy session (no onboarding state)
      // restores to Home.
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(secure.containsKey(SettingsStore.deletedCounterIdsKey),
          isTrue);

      // The backend declares the session expired.
      TabsBackend.onSessionExpired?.call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(secure.containsKey(SettingsStore.deletedCounterIdsKey),
          isFalse,
          reason: 'expiry must wipe the tombstone ids key');
      expect(secure.containsKey(SettingsStore.deletedCounterOwnerKey),
          isFalse,
          reason: 'expiry must wipe the tombstone owner key');
      expect(secure[SettingsStore.themeModeKey], 'LIGHT',
          reason: 'the targeted wipe leaves device prefs alone');
      await tester.pump(const Duration(milliseconds: 300));
    });
  });
}
