import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';

import 'test_helpers.dart';

/// Plan-tap instant-response suite (founder report, Nov 2, 2026):
/// tapping ✓ Take / ⊘ Skip on a Today's Plan medication row gave
/// NO visual response until the network write + a full plan reload
/// landed (each leg carrying a 20s timeout), and a single global
/// acting-lock silently ate taps on every other row meanwhile.
///
/// The fix (today_summary_card.dart): the slide-away starts the
/// same frame as the tap (optimistic, presentation first), the
/// write + reconciling reload run in the background through a
/// serialized future chain (the loader allocates entry ids as
/// server-max+1, so writes must never overlap), and a failed
/// reminder/habit write (loader returns false) restores the row.
///
/// Fixtures mirror test/today_summary_r35_test.dart: a stateful
/// MockClient fake server whose pull reflects posted entries.

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

/// Stateful fake server with two Daily meds. When [postGate] is
/// set, every POST /api/sync/entries parks on it before the entry
/// is recorded and reflected in later pulls — a stalled network.
class StallServer {
  final List<Map<String, dynamic>> serverEntries = [];
  final List<Map<String, dynamic>> postedEntries = [];
  Completer<void>? postGate;
  int postAttempts = 0;

  http.Client get client => MockClient(_handle);

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
      {
        'id': 'med-uuid-2',
        'name': 'Pyridostigmine',
        'dose': '60 mg',
        'frequency': 'Daily',
        'startDate': '2026-01-01',
        'endDate': 'Present',
        'isPresent': true,
        'isDeleted': false,
        'updatedAt': '1760000000000',
      },
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
    };
  }

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(jsonEncode(_pullBody()), 200);
    }
    if (request.url.path == '/api/habits') {
      return http.Response('{"habits":[]}', 200);
    }
    if (request.url.path == '/api/sync/entries') {
      postAttempts++;
      final gate = postGate;
      if (gate != null) await gate.future;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final e in (body['entries'] as List)) {
        final row = (e as Map).cast<String, dynamic>();
        postedEntries.add(row);
        serverEntries.removeWhere((s) => s['id'] == row['id']);
        serverEntries.add(row);
      }
      return http.Response('{"success":true}', 200);
    }
    return http.Response('{}', 404);
  }
}

/// Lets real-async completions land in the fake-async test zone
/// (same bridge the R35 suite uses).
Future<void> bridgeRealAsync(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
  }
  await tester.pump();
}

Future<void> pumpCard(WidgetTester tester, StallServer server) async {
  final session = FakeSessionStore()
    ..token = 'tok'
    ..email = 'a@x.com';
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TodaySummaryCard(
            backend: TabsBackend(client: server.client, sessionStore: session),
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
}

/// Taps the [tooltip] button in the row whose title is [medName],
/// chosen by vertical proximity so the target is deterministic
/// regardless of plan sort order.
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

/// Opens the stall gate and lets the background write chain drain
/// (write → reconciling reload → next write …) to completion.
Future<void> drainChain(WidgetTester tester, StallServer server) async {
  final gate = server.postGate;
  if (gate != null && !gate.isCompleted) gate.complete();
  await bridgeRealAsync(tester);
  await bridgeRealAsync(tester);
  await tester.pumpAndSettle();
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

  testWidgets(
      'stalled network: Take responds instantly — the slide-away '
      'starts while the entries POST never completes',
      (tester) async {
    final server = StallServer()..postGate = Completer<void>();
    await pumpCard(tester, server);
    expect(find.text('Ivabradine'), findsOneWidget);
    expect(find.text('Pyridostigmine'), findsOneWidget);

    await tapRowButton(tester, 'Ivabradine', 'Take Medication');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The POST is still parked on the gate — nothing has been
    // recorded server-side — yet the row is already exiting.
    expect(server.postGate!.isCompleted, isFalse);
    expect(server.postedEntries, isEmpty);
    expect(find.byKey(const Key('slide-away-slot')), findsOneWidget);
    // The exiting copy of the row is the one inside the slot.
    expect(
      find.descendant(
        of: find.byKey(const Key('slide-away-slot')),
        matching: find.text('Ivabradine'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // Cleanup: open the gate and drain so no request timer is
    // left pending at test end; the parked write then lands
    // exactly once, with the byte-exact body.
    await drainChain(tester, server);
    expect(server.postedEntries, hasLength(1));
    expect(server.postedEntries.single['body'], 'Took Ivabradine 7.5 mg');
  });

  testWidgets(
      'rapid back-to-back Takes on two meds both register '
      'instantly, and the serialized writes land with distinct '
      'entry ids', (tester) async {
    final server = StallServer()..postGate = Completer<void>();
    await pumpCard(tester, server);

    await tapRowButton(tester, 'Ivabradine', 'Take Medication');
    await tester.pump();
    await tapRowButton(tester, 'Pyridostigmine', 'Take Medication');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Both taps registered despite the stalled network: med 1's
    // exit was finalized by med 2's (one slide at a time), med 1
    // is gone, and med 2 is the row inside the slide slot — not
    // an actionable row.
    expect(find.byKey(const Key('slide-away-slot')), findsOneWidget);
    expect(find.text('Ivabradine'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('slide-away-slot')),
        matching: find.text('Pyridostigmine'),
      ),
      findsOneWidget,
    );
    expect(server.postedEntries, isEmpty);

    await drainChain(tester, server);

    // Exactly two entries, in tap order, byte-exact bodies, and
    // DISTINCT ids — proof the background writes ran sequentially
    // (each allocating server-max+1 from a fresh fetch).
    expect(server.postedEntries, hasLength(2));
    expect(server.postedEntries[0]['body'], 'Took Ivabradine 7.5 mg');
    expect(
        server.postedEntries[1]['body'], 'Took Pyridostigmine 60 mg');
    expect(server.postedEntries[0]['id'],
        isNot(server.postedEntries[1]['id']));
    expect(find.text('Ivabradine'), findsNothing);
    expect(find.text('Pyridostigmine'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-row double-tap posts exactly one entry',
      (tester) async {
    final server = StallServer()..postGate = Completer<void>();
    await pumpCard(tester, server);

    await tapRowButton(tester, 'Ivabradine', 'Take Medication');
    // Second tap in immediate succession — no frame in between, so
    // it lands on the not-yet-rebuilt row; the per-item guard must
    // make it a no-op.
    await tapRowButton(tester, 'Ivabradine', 'Take Medication');
    await tester.pump();

    await drainChain(tester, server);
    expect(server.postedEntries, hasLength(1));
    expect(server.postedEntries.single['body'], 'Took Ivabradine 7.5 mg');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Skip posts exactly one entry in the corrected shape, '
      'byte-identical to base behavior', (tester) async {
    final server = StallServer()..postGate = Completer<void>();
    await pumpCard(tester, server);

    await tapRowButton(tester, 'Ivabradine', 'Skip Medication');
    await tester.pump();
    // Skip is optimistic too: the row exits while the POST stalls.
    expect(find.byKey(const Key('slide-away-slot')), findsOneWidget);

    await drainChain(tester, server);
    expect(server.postedEntries, hasLength(1));
    expect(server.postedEntries.single['body'],
        '[Corrected to Skipped] Took Ivabradine 7.5 mg');
    expect(tester.takeException(), isNull);
  });
}
