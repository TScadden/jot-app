import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';

import 'test_helpers.dart';

/// Daily Summary rapid-completion logging loss (founder report,
/// Nov 20, 2026): "there is a delayed logging issue when I complete
/// things on my daily summary. And if I go too fast it doesn't even
/// mark it done and log it."
///
/// Root cause (diagnosis in ~/workspace/build-daily-summary-race/
/// STAGE-LOG.md): every completion allocates its log entry id as
/// maxId + 1 from a sync-pull snapshot. `invalidateSyncPull()`
/// cleared only the finished-response cache, never the shared
/// in-flight pull, and the pull freshness epoch was bumped only by
/// profile pushes, never by entry posts — so a second completion
/// whose fetch joined (or was served by) a pull that started before
/// the first completion's POST computed the SAME id, and its POST
/// upserted over the first entry's server row, destroying it.
///
/// The fix: (1) an entries-mutation epoch folded into pull
/// freshness, (2) `invalidateSyncPull()` also drops the in-flight
/// slot, (3) the loader serializes the fetch→allocate→post section
/// across all its actions, (4) the card's reconciling reload is
/// coalesced to once per action-chain drain.
///
/// The fake server below mirrors jot-server's POST /api/sync/
/// entries: a batch upsert keyed on (user_id, local_id) that
/// overwrites only when the incoming updatedAt >= the stored one
/// (client `toSyncJson` stamps updatedAt at post time, so the last
/// post to land wins a shared id). Pull bodies are SNAPSHOTTED AT
/// REQUEST TIME and can be held in flight — a slow download of a
/// body the server generated before a concurrent write landed.

class MemoryStore {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

TodayPlanStore planStoreWith(MemoryStore s) {
  final store = TodayPlanStore.testInstance();
  store.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return store;
}

TodaySummaryCache cacheWith(MemoryStore s) {
  final cache = TodaySummaryCache.testInstance();
  cache.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return cache;
}

class FakeSummaryHc extends HealthConnectService {
  @override
  Future<int?> readSleepMinutes(String dateStr) async => null;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];
}

/// Stateful fake server. Pull responses are built from the entry
/// list AT REQUEST TIME; when [pullGate] is armed, delivery of
/// every pull parks on it (the snapshot does not advance while
/// parked — the bytes are already generated, just slow).
class RaceServer {
  final List<Map<String, dynamic>> serverEntries = [];
  int pullRequests = 0;
  Completer<void>? _pullGate;

  http.Client get client => MockClient(_handle);

  void armPullGate() => _pullGate = Completer<void>();

  void releasePullGate() {
    final gate = _pullGate;
    _pullGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void seed(int pastMs) {
    serverEntries.add({
      'id': 900,
      'categoryId': 1,
      'body': 'Migraine',
      'chips': '[]',
      'manualText': '',
      'timestamp': pastMs,
      'updatedAt': pastMs,
    });
  }

  Map<String, dynamic> _pullBody() {
    final meds = jsonEncode([
      {
        'id': 'med-uuid-1',
        'name': 'Ivabradine',
        'dose': '7.5 mg',
        'frequency': 'Daily',
        'startDate': '2026-01-01',
        'endDate': 'Present',
        'isPresent': true,
        'isDeleted': false,
        'updatedAt': '1760000000000',
      },
    ]);
    Map<String, dynamic> reminder(int id, String title) => {
          'id': id,
          'title': title,
          'type': 'FIXED',
          'fixedHour': 23,
          'fixedMinute': 45,
          'intervalHours': 2,
          'intervalMinutes': 0,
          'startHour': 8,
          'startMinute': 0,
          'endHour': 21,
          'endMinute': 0,
          'isEnabled': true,
          'daysOfWeekConfig': '',
        };
    final reminders = jsonEncode([
      reminder(5, 'Salt pills'),
      reminder(6, 'Electrolytes'),
      reminder(7, 'Magnesium'),
    ]);
    return {
      'entries': serverEntries
          .map((e) => {
                'id': '${e['id']}',
                'categoryId': '${e['categoryId']}',
                'body': e['body'],
                'chips': e['chips'],
                'manualText': e['manualText'],
                'timestamp': '${e['timestamp']}',
                'updatedAt': '${e['updatedAt']}',
              })
          .toList(),
      'categories': [
        {
          'id': 1,
          'name': 'Symptoms',
          'icon': 'Favorite',
          'colorHex': '#FF6B6B',
          'isDefault': true,
          'sortOrder': 0,
        },
        {
          'id': 4,
          'name': 'Goals & Habits',
          'icon': 'EmojiEvents',
          'colorHex': '#4D96FF',
          'isDefault': true,
          'sortOrder': 4,
        },
        {
          'id': 8,
          'name': 'Medication',
          'icon': 'Medication',
          'colorHex': '#4ECDC4',
          'isDefault': true,
          'sortOrder': 3,
        },
      ],
      'profile': {'medications': meds, 'reminders': reminders},
      'isUnlimited': true,
      'isAdmin': false,
    };
  }

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/api/sync/pull') {
      pullRequests++;
      final snapshot = jsonEncode(_pullBody());
      final gate = _pullGate;
      if (gate != null) await gate.future;
      return http.Response(snapshot, 200);
    }
    if (request.url.path == '/api/sync/entries') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final e in (body['entries'] as List)) {
        final row = (e as Map).cast<String, dynamic>();
        final existing = serverEntries
            .where((s) => s['id'] == row['id'])
            .toList();
        // Server rule: overwrite only when the incoming updatedAt
        // is at least the stored one.
        if (existing.isEmpty ||
            (row['updatedAt'] as int) >=
                (existing.first['updatedAt'] as int)) {
          serverEntries.removeWhere((s) => s['id'] == row['id']);
          serverEntries.add(row);
        }
      }
      return http.Response('{"success":true}', 200);
    }
    if (request.url.path == '/api/habits') {
      return http.Response(
        jsonEncode({
          'habits': [
            {
              'id': 'h1',
              'title': 'Stretch',
              'target_time': '07:15',
              'created_at': '2026-01-01',
              'logs': <String>[],
            },
          ],
        }),
        200,
      );
    }
    if (request.url.path == '/api/habits/log') {
      return http.Response('{"success":true}', 200);
    }
    return http.Response('{}', 404);
  }

  /// Completion entries = everything except the seeded row.
  List<Map<String, dynamic>> get completions =>
      serverEntries.where((e) => e['id'] != 900).toList();
}

/// Polls [condition] on the real event loop until it holds.
Future<void> until(bool Function() condition, {String? reason}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 5)) {
      fail('timed out waiting for condition ${reason ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  int pastMs() =>
      DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;

  ({TodaySummaryLoader loader, TabsBackend backend, RaceServer server})
      harness() {
    final server = RaceServer()..seed(pastMs());
    final session = FakeSessionStore()
      ..token = 'tok'
      ..email = 'a@x.com';
    final backend = TabsBackend(client: server.client, sessionStore: session);
    final loader = TodaySummaryLoader(
      backend: backend,
      hc: FakeSummaryHc(),
      planStore: planStoreWith(MemoryStore()),
      cache: cacheWith(MemoryStore()),
      sessionStore: session,
    );
    return (loader: loader, backend: backend, server: server);
  }

  Future<Map<String, TodayPlanItem>> planItems(
      TodaySummaryLoader loader, DateTime now) async {
    final data = await loader.loadPlan(now: now);
    return {for (final i in data.plan.items) i.title: i};
  }

  test(
      'REPRO — held in-flight pull + two overlapping completions: '
      'both entries stand with distinct ids', () async {
    final h = harness();
    final now = DateTime.now();
    final items = await planItems(h.loader, now);
    final salt = items['Salt pills']!;
    final electrolytes = items['Electrolytes']!;

    // A pull goes in flight and parks (Home's own load / the
    // previous link's reconciling reload on a slow network). Both
    // completions are then fired without awaiting — the rapid
    // back-to-back tapping the founder described, at the loader
    // level whose write section is the thing being fixed.
    h.server.armPullGate();
    final fA = h.loader.setReminderCompleted(salt, true, now: now);
    final fB =
        h.loader.setReminderCompleted(electrolytes, true, now: now);
    await until(() => h.server.pullRequests >= 1,
        reason: 'first pull in flight');
    h.server.releasePullGate();
    final results = await Future.wait([fA, fB]);
    expect(results, [isTrue, isTrue]);

    final completions = h.server.completions;
    expect(completions, hasLength(2),
        reason: 'both completions must stand in the log; got '
            '${completions.map((e) => '${e['id']}:${e['body']}').toList()}');
    expect(completions.map((e) => e['body']).toSet(), {
      'Completed reminder: Salt pills',
      'Completed reminder: Electrolytes',
    });
    expect(completions.map((e) => e['id']).toSet(), hasLength(2),
        reason: 'each completion must own a distinct entry id');
  });

  test(
      'a pull that started before an entry post is never served '
      'as fresh after it (entries-mutation epoch)', () async {
    final h = harness();
    h.server.armPullGate();
    final pendingPull = h.backend.fetchSyncPull();
    await until(() => h.server.pullRequests >= 1,
        reason: 'pull in flight');
    // Another surface posts an entry while the pull is in flight
    // (outbox flush, quick log, coach — all share postLogEntries).
    final ok = await h.backend.postLogEntries([
      QuickLogEntry(
        id: 901,
        categoryId: 1,
        body: 'Flare',
        chips: '[]',
        manualText: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    expect(ok, isTrue);
    h.server.releasePullGate();
    await pendingPull;
    // The next read must see the posted entry — the stale body
    // the in-flight pull carried must not be cached as fresh.
    final entries = await h.backend.fetchLogEntryDtos();
    expect(entries.map((e) => e.id), contains(901),
        reason: 'the pre-post pull body must never be served '
            'after the post landed');
  });

  test(
      'rapid-fire: five concurrent completions (3 reminders, '
      'habit, med take) all land exactly once with distinct ids',
      () async {
    final h = harness();
    final now = DateTime.now();
    final items = await planItems(h.loader, now);

    final results = await Future.wait<Object?>([
      h.loader.setReminderCompleted(items['Salt pills']!, true, now: now),
      h.loader
          .setReminderCompleted(items['Electrolytes']!, true, now: now),
      h.loader.setReminderCompleted(items['Magnesium']!, true, now: now),
      h.loader.setHabitCompleted(items['Stretch']!, true, now: now),
      h.loader
          .setMedicationAction(items['Ivabradine']!, DoseStatus.taken,
              now: now)
          .then((_) => true),
    ]);
    expect(results.where((r) => r == true), hasLength(5));

    final completions = h.server.completions;
    expect(completions, hasLength(5),
        reason: 'every rapid completion must stand exactly once; '
            'got ${completions.map((e) => '${e['id']}:${e['body']}').toList()}');
    expect(completions.map((e) => e['id']).toSet(), hasLength(5));
    expect(completions.map((e) => e['body']).toSet(), {
      'Completed reminder: Salt pills',
      'Completed reminder: Electrolytes',
      'Completed reminder: Magnesium',
      'Completed habit: Stretch',
      'Took Ivabradine 7.5 mg',
    });

    // And the plan agrees: none of the five items is still open.
    final after = await h.loader.loadPlan(now: now);
    expect(
      after.plan.items.map((i) => i.title).toSet(),
      isNot(anyOf(
        contains('Salt pills'),
        contains('Electrolytes'),
        contains('Magnesium'),
        contains('Stretch'),
        contains('Ivabradine'),
      )),
    );
  });

  test(
      'sequential double-completion of one reminder still yields '
      'exactly one entry (idempotency preserved)', () async {
    final h = harness();
    final now = DateTime.now();
    final items = await planItems(h.loader, now);
    final salt = items['Salt pills']!;

    expect(await h.loader.setReminderCompleted(salt, true, now: now),
        isTrue);
    expect(await h.loader.setReminderCompleted(salt, true, now: now),
        isTrue);
    final matches = h.server.completions
        .where((e) => e['body'] == 'Completed reminder: Salt pills')
        .toList();
    expect(matches, hasLength(1));
  });

  // ── Card level: the reconciling reload is coalesced ──────────
  //
  // Pre-fix, every link of the card's action chain ran its write
  // PLUS a full reconciling reload (a whole sync pull each), so a
  // burst of N taps paid 2N pulls and the last tap's visible state
  // waited on the sum of every cycle — the founder's "delayed
  // logging". Post-fix the writes stay serialized but the reload
  // runs once, when the chain drains: N write fetches + 1 reload.

  group('card reload coalescing', () {
    /// Three Daily meds, instant responses, pull-counting server
    /// (the today_plan_instant_tap_test.dart StallServer shape,
    /// ungated, with a third med so the burst has three links).
    ({
      MockClient client,
      List<Map<String, dynamic>> serverEntries,
      int Function() pulls,
      void Function() resetPulls,
      void Function(Completer<void>?) setPostGate,
    }) cardServer() {
      final serverEntries = <Map<String, dynamic>>[];
      var pulls = 0;
      // When set, every POST /api/sync/entries parks on the gate
      // before recording — a stalled network, so all three taps
      // enqueue while the first write is still in flight (the
      // production condition the coalescing exists for: on an
      // instant network each write would drain before the next
      // tap lands, and there is nothing to coalesce).
      Completer<void>? postGate;
      Map<String, dynamic> med(String id, String name, String dose) =>
          {
            'id': id,
            'name': name,
            'dose': dose,
            'frequency': 'Daily',
            'startDate': '2026-01-01',
            'endDate': 'Present',
            'isPresent': true,
            'isDeleted': false,
            'updatedAt': '1760000000000',
          };
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          pulls++;
          final meds = jsonEncode([
            med('med-uuid-1', 'Ivabradine', '7.5 mg'),
            med('med-uuid-2', 'Pyridostigmine', '60 mg'),
            med('med-uuid-3', 'Midodrine', '10 mg'),
          ]);
          return http.Response(
            jsonEncode({
              'entries': serverEntries
                  .map((e) => {
                        'id': '${e['id']}',
                        'categoryId': '${e['categoryId']}',
                        'body': e['body'],
                        'chips': e['chips'],
                        'manualText': e['manualText'],
                        'timestamp': '${e['timestamp']}',
                        'updatedAt': '${e['timestamp']}',
                      })
                  .toList(),
              'categories': [
                {'id': 1, 'name': 'Symptoms'},
                {'id': 4, 'name': 'Goals & Habits'},
                {'id': 8, 'name': 'Medication'},
              ],
              'profile': {'medications': meds, 'reminders': '[]'},
              'isUnlimited': true,
              'isAdmin': false,
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response('{"habits":[]}', 200);
        }
        if (request.url.path == '/api/sync/entries') {
          final gate = postGate;
          if (gate != null) await gate.future;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          for (final e in (body['entries'] as List)) {
            final row = (e as Map).cast<String, dynamic>();
            serverEntries.removeWhere((s) => s['id'] == row['id']);
            serverEntries.add(row);
          }
          return http.Response('{"success":true}', 200);
        }
        return http.Response('{}', 404);
      });
      return (
        client: client,
        serverEntries: serverEntries,
        pulls: () => pulls,
        resetPulls: () => pulls = 0,
        setPostGate: (g) => postGate = g,
      );
    }

    Future<void> bridgeRealAsync(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)));
      }
      await tester.pump();
    }

    Future<void> tapRowButton(
        WidgetTester tester, String medName, String tooltip) async {
      final nameCenter = tester.getCenter(find.text(medName));
      Finder? best;
      var bestDy = double.infinity;
      for (final element in find.byTooltip(tooltip).evaluate()) {
        final widgetFinder = find.byWidget(element.widget);
        final dy = (tester.getCenter(widgetFinder).dy - nameCenter.dy).abs();
        if (dy < bestDy) {
          bestDy = dy;
          best = widgetFinder;
        }
      }
      expect(best, isNotNull, reason: 'no "$tooltip" button near "$medName"');
      await tester.tap(best!);
    }

    testWidgets(
        'a three-tap burst pays 3 write fetches + ONE drain reload '
        '(4 pulls), not a reload per tap', (tester) async {
      final server = cardServer();
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TodaySummaryCard(
                backend: TabsBackend(
                    client: server.client, sessionStore: session),
                healthConnectService: FakeSummaryHc(),
                planStore: planStoreWith(MemoryStore()),
                summaryCache: cacheWith(MemoryStore()),
                sessionStore: session,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();
      expect(find.text('Ivabradine'), findsOneWidget);
      expect(find.text('Pyridostigmine'), findsOneWidget);
      expect(find.text('Midodrine'), findsOneWidget);

      server.resetPulls();
      // Stall the entries POSTs: all three taps enqueue while the
      // first write is still in flight, exactly the rapid routine
      // the founder described.
      final gate = Completer<void>();
      server.setPostGate(gate);
      await tapRowButton(tester, 'Ivabradine', 'Take Medication');
      await tester.pump();
      await tapRowButton(tester, 'Pyridostigmine', 'Take Medication');
      await tester.pump();
      await tapRowButton(tester, 'Midodrine', 'Take Medication');
      await tester.pump();
      expect(server.serverEntries, isEmpty,
          reason: 'the first POST is still parked on the gate');

      // Release the network and let the background chain drain.
      gate.complete();
      server.setPostGate(null);
      await bridgeRealAsync(tester);
      await bridgeRealAsync(tester);
      await tester.pumpAndSettle();

      // All three writes landed, each with its own entry id.
      expect(server.serverEntries, hasLength(3));
      expect(server.serverEntries.map((e) => e['id']).toSet(),
          hasLength(3));
      expect(server.serverEntries.map((e) => e['body']).toSet(), {
        'Took Ivabradine 7.5 mg',
        'Took Pyridostigmine 60 mg',
        'Took Midodrine 10 mg',
      });
      // The delay fix, counted: one pull per write fetch plus a
      // single reconciling reload at chain drain. (Pre-fix this
      // burst paid 6 — a full reload after every link.)
      expect(server.pulls(), 4,
          reason: 'expected 3 write fetches + 1 coalesced reload');
      expect(tester.takeException(), isNull);
    });
  });
}