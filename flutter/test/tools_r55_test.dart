import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';

import 'test_helpers.dart';

/// Round 55 — Coach perception, memory, and agency tests:
/// - Step 1: context assembler (sections, 0-biometrics omitted,
///   budget truncation, professional updates, counter day-math),
///   bodyLoadHistory from check-in fixtures, gating (isAdmin).
/// - Step 2: memory store (dedupe/cap/account guard/clear/delete),
///   REMEMBER extraction + stripping from display and persistence,
///   approval-event capture.
/// - Step 3: LOG_ENTRY approve (resolve/id/failure), COUNTER
///   approve (Settings row shape), MEDICATION 6-field vs 4-field.

TabsBackend backendWith(MockClient client, {String? token = 'tok'}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

CoachMemoryStore memoryStore(Map<String, String> mem) {
  return CoachMemoryStore.withStorage(
    read: (k) async => mem[k],
    write: (k, v) async => mem[k] = v,
    delete: (k) async => mem.remove(k),
  );
}

MockClient serverClient(
  List<http.BaseRequest> log, {
  Map<String, dynamic> profile = const {},
  List<dynamic> pullEntries = const [],
  List<dynamic> pullCategories = const [],
  bool pullFails = false,
  bool omitEntries = false,
  String coachReply = 'All good.',
}) {
  return MockClient((request) async {
    log.add(request);
    switch (request.url.path) {
      case '/api/sync/pull':
        if (pullFails) return http.Response('boom', 500);
        return http.Response(
            jsonEncode({
              'isUnlimited': true,
              'profile': profile,
              if (!omitEntries) 'entries': pullEntries,
              'categories': pullCategories,
            }),
            200);
      case '/api/sync/profile':
        return http.Response(jsonEncode({'saved': true, 'synced': 1}), 200);
      case '/api/sync/coach_sessions':
      case '/api/sync/coach_messages':
        // Round 57: echo the real batch count, like the restored
        // server handler — a constant 1 hid partial saves.
        final key = request.url.path.endsWith('sessions')
            ? 'sessions'
            : 'messages';
        final batch =
            (jsonDecode(request.body) as Map<String, dynamic>)[key] as List;
        return http.Response(jsonEncode({'synced': batch.length}), 200);
      case '/api/sync/entries':
        return http.Response(jsonEncode({'synced': 1}), 200);
      case '/api/ai/coach':
        return http.Response(jsonEncode({'result': coachReply}), 200);
    }
    return http.Response('{}', 404);
  });
}

List<http.Request> requestsTo(List<http.BaseRequest> log, String path) => [
      for (final r in log)
        if (r.url.path == path && r is http.Request) r,
    ];

dynamic lastProfileField(List<http.BaseRequest> log, String field) {
  final pushes = requestsTo(log, '/api/sync/profile');
  expect(pushes, isNotEmpty, reason: 'expected a profile push');
  final body = jsonDecode(pushes.last.body) as Map<String, dynamic>;
  return jsonDecode(body[field] as String);
}

Future<void> pumpChat(
  WidgetTester tester, {
  required TabsBackend backend,
  required List<CoachChatMessage> messages,
  List<Map<String, dynamic>> pullCategories = const [],
  CoachMemoryStore? memory,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: CoachChatScreen(
        backend: backend,
        notificationService: FakeReminderNotificationService(),
        coachMemoryStore: memory,
        accountEmail: 'user@example.com',
        sessionId: 's1',
        sessionTitle: 'Chat',
        initialMessages: messages,
        pullCategories: pullCategories,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

CoachChatMessage coachMsg(String content, {String id = 'm1'}) =>
    CoachChatMessage(
      id: id,
      sessionId: 's1',
      role: 'coach',
      content: content,
      timestamp: 1,
    );

Future<void> flushSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  final now = DateTime(2026, 10, 13, 12, 0);
  int ms(DateTime d) => d.millisecondsSinceEpoch;

  group('Step 1 — context assembler', () {
    Map<String, dynamic> profileFixture() => {
          'professionalUpdates': 'Clinician note: increase salt intake.',
          'gender': 'Female',
          'age': 22,
          'heightCm': 170.0,
          'weightKg': 70.0,
          'conditions': jsonEncode(['POTS', 'MCAS']),
          'medications': jsonEncode([
            {
              'id': 'a',
              'name': 'Ivabradine',
              'startDate': 'Jan 2026',
              'endDate': 'Present',
              'isPresent': true,
              'dose': '7.5 mg',
              'frequency': 'Twice daily',
              'updatedAt': 1,
              'isDeleted': false,
            },
            {
              'id': 'b',
              'name': 'Old Med',
              'startDate': 'Jan 2025',
              'endDate': 'May 2026',
              'isPresent': false,
              'dose': '5 mg',
              'frequency': 'Daily',
              'updatedAt': 1,
              'isDeleted': false,
            },
          ]),
          'todaySleepMins': 0, // failed read — must be omitted
          'todayAvgHr': 0, // failed read — must be omitted
          'todaySpikes': 2,
          'todaySleepDebt': -180,
          'eventCounters': jsonEncode([
            EventCounterItem(
              id: 'c1',
              name: 'Last faint',
              targetDate: ms(DateTime(2026, 10, 3)),
              isUp: true,
            ).toMap(),
          ]),
          'focusState': jsonEncode({
            'activeTest': {
              'title': 'Morning sunlight',
              'durationDays': 14,
              'startTimestamp': ms(DateTime(2026, 10, 10)),
              'logs': {'2026-10-10': true, '2026-10-11': true},
            },
          }),
        };

    test('sections present from fixtures; 0 biometrics omitted', () {
      final ctx = buildCoachHealthContext(
        profile: profileFixture(),
        entries: [
          {
            'id': 1,
            'categoryId': 2,
            'body': 'Felt dizzy standing',
            'chips': '',
            'manualText': '',
            'timestamp': ms(DateTime(2026, 10, 12, 10)),
          },
        ],
        categories: [
          {'id': 2, 'name': 'Symptoms'},
        ],
        health: const CoachHealthSnapshot(
          sleepNights: [
            (date: '2026-10-11', mins: 390),
            (date: '2026-10-12', mins: 0), // failed read — dropped
            (date: '2026-10-13', mins: 426),
          ],
          sleepDebtMins: 210,
          restingLatestBpm: 62,
          restingLatestDate: '2026-10-13',
          restingAvg7Bpm: 64,
          daytimeHrTodayBpm: 88,
          hrvLatestMs: 41,
          spikesLast7Total: 9,
          spikesToday: 2,
          habits: [(name: 'Salt pills', streak: 4)],
          latestBp: BpRecord(systolic: 118, diastolic: 76, timeEpochMs: 5),
          bpAvg7: (sys: 120, dia: 78),
        ),
        now: now,
      );
      // Professional updates first, labelled as clinician updates.
      expect(ctx, startsWith('CLINICIAN UPDATES (highest priority):'));
      expect(ctx, contains('increase salt intake'));
      // Demographics in the native enriched shape.
      expect(ctx, contains('Profile Info: Gender: Female, Age: 22, '
          'Height: 170 cm, Weight: 154 lbs'));
      expect(ctx, contains('Conditions: POTS, MCAS'));
      // Only the active med, with real dose/frequency.
      expect(ctx, contains('Ivabradine, dose 7.5 mg, Twice daily'));
      expect(ctx, isNot(contains('Old Med')));
      // Zero biometrics never printed.
      expect(ctx, isNot(contains('sleep last night 0')));
      expect(ctx, isNot(contains('daytime heart rate average 0')));
      expect(ctx, contains('2 heart rate spikes today'));
      expect(ctx, contains('sleep debt about 3h'));
      // Health Connect sections.
      expect(ctx, contains('avg 6h48m'));
      expect(ctx, contains('last night 7h6m'));
      expect(ctx, contains('sleep debt about 3h30m'));
      expect(ctx, contains('resting heart rate 62 bpm'));
      expect(ctx, contains('daytime heart rate today (7am to 11pm) '
          'average 88 bpm'));
      expect(ctx, contains('latest HRV 41 ms'));
      expect(ctx, contains('9 heart rate spikes in the last 7 days'));
      expect(ctx, contains('Blood pressure: latest 118/76 mmHg; '
          '7 day average 120/78 mmHg'));
      expect(ctx, contains('Salt pills: current streak 4 days'));
      // Counters use Settings/Home day math; focus test included.
      expect(ctx, contains('Last faint: 10 days since'));
      expect(ctx, contains('Active Project Focus test: Morning '
          'sunlight, day 4 of 14, logged 2 days so far'));
      // Log digest is dated and categorized.
      expect(ctx, contains('2026-10-12 Symptoms: Felt dizzy standing'));
      // No brackets or angle brackets in data sections.
      expect(ctx, isNot(contains('[')));
      expect(ctx, isNot(contains('<')));
    });

    test('log digest ranks symptom before medication before mood',
        () {
      final lines = coachLogDigestLines(
        [
          {
            'categoryId': 3,
            'body': 'mood entry',
            'timestamp': ms(DateTime(2026, 10, 13, 9)),
          },
          {
            'categoryId': 1,
            'body': 'symptom entry',
            'timestamp': ms(DateTime(2026, 10, 11, 9)),
          },
          {
            'categoryId': 2,
            'body': 'med entry',
            'timestamp': ms(DateTime(2026, 10, 12, 9)),
          },
          {
            'categoryId': 1,
            'body': 'ancient symptom',
            'timestamp': ms(DateTime(2026, 9, 1, 9)),
          },
        ],
        [
          {'id': 1, 'name': 'Symptoms'},
          {'id': 2, 'name': 'Medication'},
          {'id': 3, 'name': 'Mood & Energy'},
        ],
        now: now,
      );
      expect(lines, hasLength(3)); // the >14-day entry is excluded
      expect(lines[0], contains('symptom entry'));
      expect(lines[1], contains('med entry'));
      expect(lines[2], contains('mood entry'));
    });

    test('budget: result stays within 9000 chars, digest truncated',
        () {
      final entries = [
        for (var i = 0; i < 20; i++)
          {
            'categoryId': 1,
            'body': 'entry $i ${'x' * 150}',
            'timestamp': ms(DateTime(2026, 10, 12, 10)),
          },
      ];
      final counters = [
        for (var i = 0; i < 120; i++)
          EventCounterItem(
            id: 'c$i',
            name: 'Counter number $i with a long name',
            targetDate: ms(DateTime(2026, 10, 3)),
            isUp: true,
          ).toMap(),
      ];
      final ctx = buildCoachHealthContext(
        profile: {
          'professionalUpdates': 'note ${'y' * 3000}',
          'eventCounters': jsonEncode(counters),
        },
        entries: entries,
        categories: [
          {'id': 1, 'name': 'Symptoms'},
        ],
        health: const CoachHealthSnapshot(sleepNights: [
          (date: '2026-10-10', mins: 400),
          (date: '2026-10-11', mins: 410),
          (date: '2026-10-12', mins: 420),
          (date: '2026-10-13', mins: 430),
        ]),
        now: now,
      );
      expect(ctx.length, lessThanOrEqualTo(coachHealthContextBudget));
    });

    test('enriched context places health before action instructions',
        () {
      final ctx = coachEnrichedUserContext('BASE',
          now: now, healthContext: 'HEALTH BLOCK');
      expect(ctx, startsWith('BASE\n\nHEALTH BLOCK\n\nSYSTEM RULES'));
      // The pre-Round-55 shape is unchanged without the blocks.
      final bare = coachEnrichedUserContext('BASE', now: now);
      expect(bare, startsWith('BASE\n\nSYSTEM RULES'));
    });
  });

  group('Step 1 — bodyLoadHistory from check-ins', () {
    test('energy-day dated lines, latest per day wins', () {
      final body = buildCoachBodyLoadHistory(
        [
          {
            'categoryId': 6,
            'body': 'Feeling: 3/5 Today',
            'chips': '["Daily Ranking"]',
            'timestamp': ms(DateTime(2026, 10, 12, 10)),
          },
          {
            // 2 AM belongs to the Oct 12 energy day (starts 04:00).
            'categoryId': 6,
            'body': 'Feeling: 4/5 Today',
            'chips': '["Daily Ranking"]',
            'timestamp': ms(DateTime(2026, 10, 13, 2)),
          },
          {
            // Same category, no Daily Ranking chip: not a check-in.
            'categoryId': 6,
            'body': 'Feeling: 5/5 Today',
            'chips': '[]',
            'timestamp': ms(DateTime(2026, 10, 13, 9)),
          },
          {
            // Too old.
            'categoryId': 6,
            'body': 'Feeling: 2/5 Today',
            'chips': '["Daily Ranking"]',
            'timestamp': ms(DateTime(2026, 9, 20, 10)),
          },
        ],
        [
          {'id': 6, 'name': 'Mood & Energy'},
        ],
        now: now,
      );
      expect(body, '2026-10-12: 4/5');
    });
  });

  group('Step 1 — gating', () {
    Future<void> pumpHistory(
      WidgetTester tester, {
      required bool isUnlimited,
      required bool isAdmin,
    }) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final mem = <String, String>{};
      final backend = backendWith(MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({
                'isUnlimited': isUnlimited,
                'isAdmin': isAdmin,
                'profile': <String, dynamic>{},
                'coachSessions': [],
                'coachMessages': [],
              }),
              200);
        }
        return http.Response('{}', 404);
      }));
      await tester.pumpWidget(MaterialApp(
        home: HealthCoachScreen(
          backend: backend,
          coachMemoryStore: memoryStore(mem),
          accountEmail: 'user@example.com',
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('isAdmin alone unlocks', (tester) async {
      await pumpHistory(tester, isUnlimited: false, isAdmin: true);
      expect(find.text('Health Coach is locked'), findsNothing);
      expect(find.text('No chats yet.'), findsOneWidget);
      expect(find.text('Coach memory'), findsOneWidget);
    });

    testWidgets('neither flag locks, with the unchanged copy',
        (tester) async {
      await pumpHistory(tester, isUnlimited: false, isAdmin: false);
      expect(find.text('Health Coach is locked'), findsOneWidget);
      expect(
          find.text('Health Coach requires a Tabs membership. '
              'Upgrade in the native app to unlock it.'),
          findsOneWidget);
    });
  });

  group('Step 2 — memory store', () {
    test('dedupe on normalized text, newest wins; cap + truncation',
        () async {
      final mem = <String, String>{};
      final store = memoryStore(mem);
      await store.addFact(
          text: 'Started creatine.', source: 'coach', email: 'a@x.com');
      final after = await store.addFact(
          text: '  started   creatine. ',
          source: 'coach',
          email: 'a@x.com');
      expect(after, hasLength(1));
      expect(after.single.text, 'started creatine.');

      for (var i = 0; i < 45; i++) {
        await store.addFact(
            text: 'fact $i', source: 'coach', email: 'a@x.com');
      }
      final capped = await store.load('a@x.com');
      expect(capped, hasLength(CoachMemoryStore.maxFacts));
      expect(capped.first.text, 'fact 44');

      final long = await store.addFact(
          text: 'z' * 300, source: 'coach', email: 'a@x.com');
      expect(long.first.text.length, CoachMemoryStore.maxFactChars);
    });

    test('account mismatch is ignored and wiped; delete and clear',
        () async {
      final mem = <String, String>{};
      final store = memoryStore(mem);
      await store.addFact(
          text: 'Private fact', source: 'coach', email: 'a@x.com');
      expect(await store.load('b@x.com'), isEmpty);
      // The wipe means even the original owner no longer sees it.
      expect(await store.load('a@x.com'), isEmpty);

      await store.addFact(text: 'one', source: 's', email: 'a@x.com');
      await store.addFact(text: 'two', source: 's', email: 'a@x.com');
      final afterDelete = await store.deleteAt(0, 'a@x.com');
      expect(afterDelete.map((f) => f.text), ['one']);
      await store.clearAll('a@x.com');
      expect(await store.load('a@x.com'), isEmpty);
    });

    String blobFor(String owner, String text) => jsonEncode({
          'ownerEmail': owner,
          'facts': [
            {'text': text, 'createdAt': 1, 'source': 'coach'}
          ],
        });

    test('in-flight load(A) + clear + load(B) yields B-only facts',
        () async {
      final mem = <String, String>{};
      var reads = 0;
      final gate = Completer<String?>();
      final store = CoachMemoryStore.withStorage(
        read: (k) {
          reads++;
          if (reads == 1) return gate.future;
          return Future.value(mem[k]);
        },
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      mem[CoachMemoryStore.storageKey] = blobFor('a@x.com', 'A fact');
      final futureA = store.load('a@x.com'); // gated in-flight read
      await store.clear();
      mem[CoachMemoryStore.storageKey] = blobFor('b@x.com', 'B fact');
      final factsB = await store.load('b@x.com');
      expect(factsB.map((f) => f.text), ['B fact']);
      gate.complete(blobFor('a@x.com', 'A fact'));
      // The stale load's result is discarded, never resurrected.
      expect(await futureA, isEmpty);
      expect(store.cachedFactsFor('b@x.com').map((f) => f.text),
          ['B fact']);
      expect(store.cachedFactsFor('a@x.com'), isEmpty);
    });

    test('recordFact during an account switch persists only the '
        'caller snapshot under the caller owner', () async {
      final mem = <String, String>{};
      var reads = 0;
      final gate = Completer<String?>();
      final store = CoachMemoryStore.withStorage(
        read: (k) {
          reads++;
          if (reads == 1) return gate.future;
          return Future.value(mem[k]);
        },
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      final loading = store.load('a@x.com'); // in-flight
      store.recordFact(
          text: 'A fact', source: 'coach', email: 'a@x.com');
      await store.clear();
      mem[CoachMemoryStore.storageKey] = blobFor('b@x.com', 'B fact');
      final factsB = await store.load('b@x.com');
      expect(factsB.map((f) => f.text), ['B fact']);
      gate.complete(null);
      await loading;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // A's deferred persist never landed: the blob is still B's,
      // owned by B, holding only B's fact.
      final stored =
          jsonDecode(mem[CoachMemoryStore.storageKey]!)
              as Map<String, dynamic>;
      expect(stored['ownerEmail'], 'b@x.com');
      expect(
          (stored['facts'] as List).map((f) => f['text']), ['B fact']);
      expect(store.cachedFactsFor('b@x.com').map((f) => f.text),
          ['B fact']);
    });

    test('clearIfOwnerMismatch wipes a mismatched mirror regardless '
        'of disk state', () async {
      final mem = <String, String>{};
      final store = memoryStore(mem);
      await store.addFact(
          text: 'A fact', source: 's', email: 'a@x.com');
      // Disk now claims B; the mirror still holds A's facts.
      mem[CoachMemoryStore.storageKey] = blobFor('b@x.com', 'B fact');
      expect(await store.clearIfOwnerMismatch('b@x.com'), isTrue);
      expect(store.cachedFacts, isEmpty);
    });

    test('REMEMBER extraction strips trailing, double, bare, and '
        'mid-reply lines', () {
      final (clean, fact) = extractCoachRememberLine(
          'Advice here.\nREMEMBER: User started creatine.');
      expect(clean, 'Advice here.');
      expect(fact, 'User started creatine.');

      // Fix pass: ALL trailing REMEMBER lines are stripped; the
      // last fact-bearing one is captured.
      final (cleanD, factD) = extractCoachRememberLine(
          'Advice.\nREMEMBER: first fact.\nREMEMBER: second fact.');
      expect(cleanD, 'Advice.');
      expect(factD, 'second fact.');

      // A bare trailing REMEMBER: is stripped and captures nothing.
      final (cleanB, factB) =
          extractCoachRememberLine('Advice.\nREMEMBER:');
      expect(cleanB, 'Advice.');
      expect(factB, isNull);

      // Fix pass: a standalone REMEMBER line anywhere is stripped
      // (the pre-fix behavior of leaving mid-reply lines in is
      // reversed by Vera's ruling).
      final (clean2, fact2) =
          extractCoachRememberLine('REMEMBER: not trailing\nMore text');
      expect(fact2, 'not trailing');
      expect(clean2, 'More text');
      expect(clean2, isNot(contains('REMEMBER')));

      final (clean3, fact3) = extractCoachRememberLine('Just advice.');
      expect(fact3, isNull);
      expect(clean3, 'Just advice.');
    });

    test('memory context heading, dates, and Juno follow-through '
        'line', () {
      final ctx = buildCoachMemoryContext([
        CoachMemoryFact(
          text: 'User is trying morning sunlight.',
          createdAt: ms(DateTime(2026, 10, 12)),
          source: 'coach',
        ),
      ]);
      expect(ctx, contains('FROM EARLIER SESSIONS (coach memory, '
          'this device):'));
      expect(ctx, contains('- 2026-10-12: User is trying morning '
          'sunlight.'));
      expect(
          ctx,
          contains('You may reference these facts. When a fact '
              'mentions something the user started, stopped, or is '
              'trying, you may note its date together with the '
              'related values in the fresh health data above, '
              'exactly as recorded. Do not state or imply that it '
              'caused, helped, worsened, or changed any health '
              'value, symptom, or outcome.'));
      expect(buildCoachMemoryContext(const []), isEmpty);
    });

    test('approval events are deterministic', () {
      final parsed = parseCoachMessageContent(
          'Ok [PROPOSE_REMINDER:Take meds|10:00]');
      final event = coachMemoryEventForProposal('reminder',
          approve: true, parsed: parsed, now: now);
      expect(event,
          '2026-10-13: Set a reminder "Take meds" at 10:00 '
          '(approved from Coach).');
      final deny = coachMemoryEventForProposal('reminder',
          approve: false, parsed: parsed, now: now);
      expect(deny, contains('Dismissed a reminder proposal'));
    });
  });

  group('Step 2 — REMEMBER in the send path', () {
    testWidgets(
        'reply REMEMBER line is stripped from display AND the '
        'persisted message, and stored as a fact', (tester) async {
      final log = <http.BaseRequest>[];
      final mem = <String, String>{};
      final store = memoryStore(mem);
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log,
            coachReply:
                'Good plan.\nREMEMBER: User started creatine on Oct 13.')),
        messages: const [],
        memory: store,
      );
      await tester.enterText(find.byType(TextField), 'I started creatine');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(find.text('Good plan.'), findsOneWidget);
      expect(find.textContaining('REMEMBER'), findsNothing);
      // No persisted coach message carries the line.
      for (final r in requestsTo(log, '/api/sync/coach_messages')) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        for (final m in body['messages'] as List) {
          expect('${m['content']}', isNot(contains('REMEMBER')));
        }
      }
      final facts = await store.load('user@example.com');
      expect(facts.map((f) => f.text),
          contains('User started creatine on Oct 13.'));
      // The request itself carried the enriched context + body load.
      final coachReq = requestsTo(log, '/api/ai/coach').single;
      final sent = jsonDecode(coachReq.body) as Map<String, dynamic>;
      expect(sent.containsKey('bodyLoadHistory'), isTrue);
      expect(sent['userContext'], contains('MEMORY:'));
    });

    testWidgets('approving a list captures a memory event',
        (tester) async {
      final log = <http.BaseRequest>[];
      final mem = <String, String>{};
      final store = memoryStore(mem);
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, profile: {
          'userLists': '[]',
        })),
        messages: [coachMsg('List? [PROPOSE_LIST:Groceries|Milk]')],
        memory: store,
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(find.text('✓ List Created'), findsOneWidget);
      final facts = await store.load('user@example.com');
      expect(
          facts.map((f) => f.text),
          contains(contains(
              'Created the list "Groceries" with 1 items '
              '(approved from Coach).')));
    });
  });

  group('Fix pass — stored REMEMBER rendering + file card (N9)', () {
    testWidgets('a stored message with a REMEMBER line renders '
        'clean', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [coachMsg('Stored advice.\nREMEMBER: secret fact')],
      );
      expect(find.text('Stored advice.'), findsOneWidget);
      expect(find.textContaining('REMEMBER'), findsNothing);
      expect(find.textContaining('secret fact'), findsNothing);
    });

    testWidgets('file card without an upload source states the '
        'limitation and disables approve', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [coachMsg('Save it? [PROPOSE_FILE:notes.txt]')],
      );
      expect(find.text(coachFileNotAttachedMessage), findsOneWidget);
      final approve = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Approve'));
      expect(approve.onPressed, isNull);
    });

    testWidgets('file card with an upload source behaves as '
        'before', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [
          const CoachChatMessage(
            id: 'u1',
            sessionId: 's1',
            role: 'user',
            content: '📄 Uploaded file: notes.txt\n\nhello body',
            timestamp: 1,
          ),
          coachMsg('Save it? [PROPOSE_FILE:notes.txt]'),
        ],
      );
      expect(find.text(coachFileNotAttachedMessage), findsNothing);
      final approve = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Approve'));
      expect(approve.onPressed, isNotNull);
    });
  });

  group('Step 3 — LOG_ENTRY', () {
    testWidgets('approve resolves the category, uses max-id + 1',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, pullEntries: [
          {'id': 7, 'body': 'older'},
          {'id': 3, 'body': 'oldest'},
        ], pullCategories: const [
          {'id': 3, 'name': 'Symptoms'},
        ])),
        messages: [
          coachMsg('Log it? [PROPOSE_LOG_ENTRY:Symptoms|Headache today]'),
        ],
        pullCategories: const [
          {'id': 3, 'name': 'Symptoms'},
        ],
      );
      expect(find.text('Proposed Log Entry'), findsOneWidget);
      expect(find.text('Symptoms'), findsOneWidget);
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      final posts = requestsTo(log, '/api/sync/entries');
      expect(posts, hasLength(1));
      final body = jsonDecode(posts.single.body) as Map<String, dynamic>;
      final entry = (body['entries'] as List).single;
      expect(entry['id'], 8);
      expect(entry['categoryId'], 3);
      expect(entry['body'], 'Headache today');
      expect(find.text('✓ Entry Logged'), findsOneWidget);
    });

    testWidgets('unknown category fails honestly and stays pending',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, pullCategories: const [
          {'id': 3, 'name': 'Symptoms'},
        ])),
        messages: [
          coachMsg('Log it? [PROPOSE_LOG_ENTRY:Nope|Headache today]'),
        ],
        pullCategories: const [
          {'id': 3, 'name': 'Symptoms'},
        ],
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(requestsTo(log, '/api/sync/entries'), isEmpty);
      expect(find.text(coachLogEntryUnknownCategoryMessage),
          findsOneWidget);
      expect(find.text('Proposed Log Entry'), findsOneWidget);
      expect(find.text('✓ Entry Logged'), findsNothing);
      await flushSnack(tester);
    });

    testWidgets('contract-violating pull (entries missing) posts '
        'nothing and stays pending', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log,
            omitEntries: true,
            pullCategories: const [
              {'id': 3, 'name': 'Symptoms'},
            ])),
        messages: [
          coachMsg('Log it? [PROPOSE_LOG_ENTRY:Symptoms|Headache]'),
        ],
        pullCategories: const [
          {'id': 3, 'name': 'Symptoms'},
        ],
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(requestsTo(log, '/api/sync/entries'), isEmpty);
      expect(find.text(coachLogEntryPullFailedMessage), findsOneWidget);
      expect(find.text('Proposed Log Entry'), findsOneWidget);
      expect(find.text('✓ Entry Logged'), findsNothing);
      await flushSnack(tester);
    });

    testWidgets('failed re-pull aborts before id math', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, pullFails: true)),
        messages: [
          coachMsg('Log it? [PROPOSE_LOG_ENTRY:Symptoms|Headache]'),
        ],
        pullCategories: const [
          {'id': 3, 'name': 'Symptoms'},
        ],
      );
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(requestsTo(log, '/api/sync/entries'), isEmpty);
      expect(find.text(coachLogEntryPullFailedMessage), findsOneWidget);
      await flushSnack(tester);
    });
  });

  group('Step 3 — COUNTER', () {
    testWidgets('approve appends a Settings-shaped counter row',
        (tester) async {
      final log = <http.BaseRequest>[];
      final existing = EventCounterItem(
        id: 'existing',
        name: 'Existing',
        targetDate: ms(DateTime(2026, 11, 1)),
      ).toMap();
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, profile: {
          'eventCounters': jsonEncode([existing]),
        })),
        messages: [
          coachMsg('Track it? [PROPOSE_COUNTER:Last migraine|2020-01-15]'),
        ],
      );
      expect(find.text('Proposed Event Counter'), findsOneWidget);
      expect(find.text('Last migraine'), findsOneWidget);
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      final rows = lastProfileField(log, 'eventCounters') as List;
      expect(rows, hasLength(2));
      expect(rows[0], existing);
      final added = rows[1] as Map<String, dynamic>;
      // Field-for-field the row EventCounterItem.toMap (Settings
      // create) emits — no more, no fewer.
      expect(added.keys.toSet(), EventCounterItem(
        id: 'x',
        name: 'x',
        targetDate: 0,
      ).toMap().keys.toSet());
      expect(added['name'], 'Last migraine');
      expect(added['targetDate'], ms(DateTime(2020, 1, 15)));
      expect(added['isUp'], isTrue); // a past date counts up (since)
      expect(added['isArchived'], isFalse);
      expect(added['isFavorite'], isFalse); // not the first counter
      expect(find.text('✓ Counter Created'), findsOneWidget);
    });

    testWidgets('counter date 2026-02-31 is rejected: the parsed '
        'date must round-trip', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, profile: {
          'eventCounters': '[]',
        })),
        messages: [
          coachMsg('Track it? [PROPOSE_COUNTER:Last migraine|2026-02-31]'),
        ],
      );
      expect(find.text('Proposed Event Counter'), findsOneWidget);
      await tester.ensureVisible(find.text('Approve'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(find.text(coachCounterInvalidDateMessage), findsOneWidget);
      expect(requestsTo(log, '/api/sync/profile'), isEmpty);
      expect(find.text('✓ Counter Created'), findsNothing);
      await flushSnack(tester);
    });
  });

  group('Step 3 — MEDICATION grammar', () {
    test('6-field and legacy 4-field parses', () {
      final ext = parseCoachMessageContent(
          'Meds [PROPOSE_MEDICATION:Ivabradine|7.5 mg|Twice daily|Jan 2026||true]');
      expect(ext.medications, hasLength(1));
      expect(ext.medications.single.dose, '7.5 mg');
      expect(ext.medications.single.frequency, 'Twice daily');
      expect(ext.medications.single.startDate, 'Jan 2026');
      expect(ext.medications.single.isPresent, isTrue);
      expect(ext.medications.single.endDate, 'Present');

      final legacy = parseCoachMessageContent(
          'Meds [PROPOSE_MEDICATION:Metoprolol|Jan 2025|May 2026|false]');
      expect(legacy.medications.single.dose, isEmpty);
      expect(legacy.medications.single.frequency, isEmpty);
      expect(legacy.medications.single.startDate, 'Jan 2025');
      expect(legacy.medications.single.endDate, 'May 2026');
      expect(legacy.medications.single.isPresent, isFalse);

      // Instructions now teach the extended grammar.
      final ctx = coachEnrichedUserContext(null, now: now);
      expect(ctx,
          contains('Name|Dose|Frequency|StartDate|EndDate|isPresent'));
      expect(ctx, contains('[PROPOSE_LOG_ENTRY:CategoryName|Entry text]'));
      expect(ctx, contains('[PROPOSE_COUNTER:Counter name|yyyy-MM-dd]'));
      // Juno B2: the MEMORY instruction's exact wording.
      expect(ctx, contains('what they decided to start'));
      expect(ctx, contains("starting with 'User reported', and not "
          'as an established result'));
    });

    test('name-with-pipe and non-literal-flag tags fail safe', () {
      // 7 fields (the name itself contains a pipe): no shifted
      // dose/frequency may be read; dates/present come from the
      // final three fields.
      final piped = parseCoachMessageContent(
          'Meds [PROPOSE_MEDICATION:Foo|Bar|7.5 mg|Twice daily|Jan 2026||true]');
      final med = piped.medications.single;
      expect(med.name, 'Foo');
      expect(med.dose, isEmpty);
      expect(med.frequency, isEmpty);
      expect(med.startDate, 'Jan 2026');
      expect(med.isPresent, isTrue);
      expect(med.endDate, 'Present');

      // Exactly 5 fields with a non-literal flag: legacy parse —
      // dose/frequency stay empty, never shifted into.
      final five = parseCoachMessageContent(
          'Meds [PROPOSE_MEDICATION:MedX|Jan 2025|May 2026|yes|trailing]');
      final legacy = five.medications.single;
      expect(legacy.dose, isEmpty);
      expect(legacy.frequency, isEmpty);
      expect(legacy.startDate, 'Jan 2025');
      expect(legacy.endDate, 'May 2026');
      expect(legacy.isPresent, isFalse);

      // A genuine 5-field extended tag (flag in field 5 only)
      // still parses as extended.
      final fiveExt = parseCoachMessageContent(
          'Meds [PROPOSE_MEDICATION:MedY|10 mg|Daily|Jan 2026|true]');
      expect(fiveExt.medications.single.dose, '10 mg');
      expect(fiveExt.medications.single.frequency, 'Daily');
      expect(fiveExt.medications.single.isPresent, isTrue);
    });

    testWidgets('6-field approval writes real dose/frequency',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, profile: {
          'medications': '[]',
        })),
        messages: [
          coachMsg(
              'Add? [PROPOSE_MEDICATION:Ivabradine|7.5 mg|Twice daily|Jan 2026||true]'),
        ],
      );
      await tester.ensureVisible(find.text('Approve & Add'));
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      final rows = lastProfileField(log, 'medications') as List;
      final added = rows.single as Map<String, dynamic>;
      expect(added['dose'], '7.5 mg');
      expect(added['frequency'], 'Twice daily');
    });

    testWidgets('legacy approval keeps the dose placeholder and '
        'an EMPTY frequency (Juno M1)', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log, profile: {
          'medications': '[]',
        })),
        messages: [
          coachMsg('Add? [PROPOSE_MEDICATION:LegacyMed|Jan 2025||true]'),
        ],
      );
      await tester.ensureVisible(find.text('Approve & Add'));
      await tester.tap(find.text('Approve & Add'));
      await tester.pumpAndSettle();
      final rows = lastProfileField(log, 'medications') as List;
      final added = rows.single as Map<String, dynamic>;
      expect(added['dose'], 'As prescribed');
      expect(added['frequency'], '');
    });
  });

  group('Step 2 — memory screen', () {
    testWidgets('shows facts, honest device line, delete and clear',
        (tester) async {
      final mem = <String, String>{};
      final store = memoryStore(mem);
      await store.addFact(
          text: 'Fact one', source: 'coach', email: 'user@example.com');
      await store.addFact(
          text: 'Fact two', source: 'coach', email: 'user@example.com');
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: CoachMemoryScreen(
          store: store,
          accountEmail: 'user@example.com',
          initialFacts: await store.load('user@example.com'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(
          find.text('Coach memory is stored on this device. It is '
              'not synced to your other devices.'),
          findsOneWidget);
      expect(find.text('Fact one'), findsOneWidget);
      expect(find.text('Fact two'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      expect(find.text('Fact two'), findsNothing);
      expect(await store.load('user@example.com'), hasLength(1));

      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear all').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('No coach memory yet.'), findsOneWidget);
      expect(await store.load('user@example.com'), isEmpty);
    });
  });
}
