import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/habit_time.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart';

import 'test_helpers.dart';

/// VC 100137 — habit scheduled time: backend PATCH, pure helpers,
/// the bounded one-shot notification projection (Nov 11 lesson:
/// fire-time gates become sync-time projections), and the Habits
/// screen add/edit flows. Notification body copy is Juno-ruled
/// verbatim (juno-copy-100137.md item 1).

TabsBackend _backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

class RecordingFake extends FakeReminderNotificationService {
  final Map<int, ({String title, String body, String channelId, bool high})>
  onceDetails = {};

  RecordingFake({super.enabled});

  @override
  Future<void> scheduleOnce({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required DateTime when,
    required bool highImportance,
  }) async {
    onceDetails[id] = (
      title: title,
      body: body,
      channelId: channelId,
      high: highImportance,
    );
    await super.scheduleOnce(
      id: id,
      title: title,
      body: body,
      channelId: channelId,
      channelName: channelName,
      when: when,
      highImportance: highImportance,
    );
  }
}

/// In-memory habits server with the VC 100137 PATCH endpoint.
class _HabitTimeServer {
  List<Map<String, dynamic>> habits;
  final List<http.Request> posts = [];
  final List<http.Request> patches = [];
  final List<http.Request> logs = [];
  int patchStatus = 200;
  int _nextId = 100;

  _HabitTimeServer(this.habits);

  MockClient client() => MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/habits') {
      return http.Response(jsonEncode({'habits': habits}), 200);
    }
    if (request.method == 'POST' && path == '/api/habits') {
      posts.add(request);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final habit = {
        'id': '${_nextId++}',
        'title': body['title'],
        'target_time': body['target_time'],
        'logs': <String>[],
      };
      habits = [...habits, habit];
      return http.Response(jsonEncode({'habit': habit}), 200);
    }
    if (request.method == 'PATCH' && path.startsWith('/api/habits/')) {
      patches.add(request);
      if (patchStatus != 200) {
        return http.Response('{"error":"x"}', patchStatus);
      }
      final id = path.split('/').last;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      Map<String, dynamic>? updated;
      habits = [
        for (final h in habits)
          if ('${h['id']}' == id)
            (updated = {...h, 'target_time': body['target_time']})
          else
            h,
      ];
      if (updated == null) return http.Response('{"error":"x"}', 404);
      return http.Response(jsonEncode({'habit': updated}), 200);
    }
    if (request.method == 'DELETE' && path.startsWith('/api/habits/')) {
      final id = path.split('/').last;
      habits = habits.where((h) => '${h['id']}' != id).toList();
      return http.Response('{}', 200);
    }
    if (request.method == 'POST' && path == '/api/habits/log') {
      logs.add(request);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final today = body['completed_date'] as String;
      habits = [
        for (final h in habits)
          if ('${h['id']}' == '${body['habit_id']}')
            {
              ...h,
              'logs': body['is_completed'] == true
                  ? [...(h['logs'] as List), today]
                  : (h['logs'] as List).where((l) => l != today).toList(),
            }
          else
            h,
      ];
      return http.Response('{}', 200);
    }
    return http.Response('{}', 404);
  });
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('habit_time helpers', () {
    test('parse: stored HH:mm only; Anytime/garbage → null', () {
      expect(parseHabitTargetTime('Anytime'), isNull);
      expect(parseHabitTargetTime(''), isNull);
      expect(parseHabitTargetTime(null), isNull);
      expect(parseHabitTargetTime('garbage'), isNull);
      expect(parseHabitTargetTime('7:30'), isNull); // not zero-padded
      expect(parseHabitTargetTime('24:00'), isNull);
      expect(parseHabitTargetTime('12:60'), isNull);
      expect(parseHabitTargetTime('07:30'), (hour: 7, minute: 30));
      expect(parseHabitTargetTime('00:00'), (hour: 0, minute: 0));
      expect(parseHabitTargetTime('23:59'), (hour: 23, minute: 59));
      expect(hasHabitTargetTime('19:00'), isTrue);
      expect(hasHabitTargetTime('Anytime'), isFalse);
      expect(
        habitTargetTimeOfDay('19:30'),
        const TimeOfDay(hour: 19, minute: 30),
      );
      expect(habitTargetTimeOfDay('Anytime'), isNull);
    });

    test('storage format is zero-padded 24h regardless of locale', () {
      expect(
        formatHabitTargetTimeForStorage(const TimeOfDay(hour: 7, minute: 5)),
        '07:05',
      );
      expect(
        formatHabitTargetTimeForStorage(const TimeOfDay(hour: 19, minute: 30)),
        '19:30',
      );
      expect(
        formatHabitTargetTimeForStorage(const TimeOfDay(hour: 0, minute: 0)),
        '00:00',
      );
    });

    testWidgets('display format goes through TimeOfDay.format (12h locale)', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      // Default test locale is en_US (12h).
      expect(formatHabitTargetTimeForDisplay('19:30', ctx), '7:30 PM');
      expect(formatHabitTargetTimeForDisplay('07:30', ctx), '7:30 AM');
      expect(formatHabitTargetTimeForDisplay('Anytime', ctx), 'Anytime');
      expect(formatHabitTargetTimeForDisplay('garbage', ctx), 'Anytime');
    });
  });

  group('habitTimeFireTimes projection', () {
    // Sunday Nov 15, 2026, 08:00 local.
    final now = DateTime(2026, 11, 15, 8, 0);

    test('Anytime and garbage project nothing', () {
      expect(
        habitTimeFireTimes(
          now: now,
          targetTime: 'Anytime',
          completedDates: const {},
        ),
        isEmpty,
      );
      expect(
        habitTimeFireTimes(
          now: now,
          targetTime: 'nope',
          completedDates: const {},
        ),
        isEmpty,
      );
    });

    test('uncompleted today + time ahead → today armed, 36 fires', () {
      final fires = habitTimeFireTimes(
        now: now,
        targetTime: '09:30',
        completedDates: const {},
      );
      expect(fires.length, 36); // offsets 0..35 inclusive
      expect(fires.first, DateTime(2026, 11, 15, 9, 30));
      expect(fires.last, DateTime(2026, 12, 20, 9, 30));
    });

    test('past time today → first fire is tomorrow', () {
      final fires = habitTimeFireTimes(
        now: now,
        targetTime: '07:00',
        completedDates: const {},
      );
      expect(fires.first, DateTime(2026, 11, 16, 7, 0));
      expect(fires.length, 35);
    });

    test('fire exactly at now is not armed (strictly after)', () {
      final fires = habitTimeFireTimes(
        now: DateTime(2026, 11, 15, 9, 30),
        targetTime: '09:30',
        completedDates: const {},
      );
      expect(fires.first, DateTime(2026, 11, 16, 9, 30));
    });

    test('completed today → today skipped, tomorrow armed', () {
      final fires = habitTimeFireTimes(
        now: now,
        targetTime: '09:30',
        completedDates: const {'2026-11-15'},
      );
      expect(fires.first, DateTime(2026, 11, 16, 9, 30));
      expect(fires.length, 35);
      expect(fires.any((f) => f.day == 15 && f.month == 11), isFalse);
    });

    test('a completed future date is skipped, others stay armed', () {
      final fires = habitTimeFireTimes(
        now: now,
        targetTime: '09:30',
        completedDates: const {'2026-11-16'},
      );
      expect(fires.first, DateTime(2026, 11, 15, 9, 30));
      expect(fires.contains(DateTime(2026, 11, 16, 9, 30)), isFalse);
      expect(fires.length, 35);
    });

    test('horizon bound is respected', () {
      final fires = habitTimeFireTimes(
        now: now,
        targetTime: '09:30',
        completedDates: const {},
        horizonDays: 2,
      );
      expect(fires, [
        DateTime(2026, 11, 15, 9, 30),
        DateTime(2026, 11, 16, 9, 30),
        DateTime(2026, 11, 17, 9, 30),
      ]);
      expect(
        habitTimeFireTimes(
          now: now,
          targetTime: '07:00',
          completedDates: const {},
          horizonDays: 0,
        ),
        isEmpty,
      );
    });
  });

  group('habitTimeNotificationId', () {
    test('stable, in the 900000–1899999 block, disjoint from all owners', () {
      const reserved = {1003, 1004, 770001, 7301, 7303, 7304};
      for (final habitId in ['h1', 'h2', '42', 'a-longer-habit-id']) {
        for (var offset = -40; offset <= 40; offset++) {
          final id = habitTimeNotificationId(
            habitId,
            DateTime(2026, 11, 15 + offset),
          );
          expect(id, inInclusiveRange(900000, 1899999));
          expect(reserved.contains(id), isFalse);
          expect(
            id >= 700000 && id <= 799998,
            isFalse,
            reason: 'event-counter block',
          );
          expect(
            id >= 800000 && id <= 809999,
            isFalse,
            reason: 'project projection block',
          );
          expect(
            id >= 101500 && id <= 699999,
            isFalse,
            reason: 'user-reminder blocks',
          );
        }
      }
    });

    test('same habit+date is stable; distinct dates differ', () {
      final d = DateTime(2026, 11, 15, 9, 30);
      expect(
        habitTimeNotificationId('h1', d),
        habitTimeNotificationId('h1', DateTime(2026, 11, 15)),
      );
      final ids = {
        for (var offset = 0; offset < 14; offset++)
          habitTimeNotificationId('h1', DateTime(2026, 11, 15 + offset)),
      };
      expect(ids.length, 14);
      expect(
        habitTimeNotificationId('h1', d),
        isNot(habitTimeNotificationId('h2', d)),
      );
    });

    test('cancel window sweeps today−36..today+36 (73 ids)', () {
      final now = DateTime(2026, 11, 15, 8, 0);
      final ids = habitTimeCancelIds('h1', now).toList();
      expect(ids.length, 73);
      expect(ids.toSet().length, 73);
      expect(ids, contains(habitTimeNotificationId('h1', now)));
      expect(
        ids,
        contains(habitTimeNotificationId('h1', DateTime(2026, 10, 10))),
      ); // today − 36
      expect(
        ids,
        contains(habitTimeNotificationId('h1', DateTime(2026, 12, 21))),
      ); // today + 36
    });
  });

  group('HabitTimeReminderSync (fake service)', () {
    final now = DateTime(2026, 11, 15, 8, 0);
    HabitDto habit({
      String id = 'h1',
      String title = 'Drink water',
      String targetTime = '09:30',
      List<String> logs = const [],
    }) => HabitDto(id: id, title: title, logs: logs, targetTime: targetTime);

    test(
      'arms the projection with Juno-ruled copy on the habit channel',
      () async {
        final fake = RecordingFake();
        await HabitTimeReminderSync(fake).syncHabits([habit()], now: now);
        expect(fake.once.length, 36);
        final todayFire = DateTime(2026, 11, 15, 9, 30);
        final todayId = habitTimeNotificationId('h1', todayFire);
        expect(fake.once[todayId], todayFire);
        final details = fake.onceDetails[todayId]!;
        expect(details.title, 'Drink water');
        // Juno ruling, verbatim (juno-copy-100137.md item 1).
        expect(details.body, "whenever you're ready. one tap is enough.");
        expect(
          habitTimeReminderBody,
          "whenever you're ready. one tap is enough.",
        );
        expect(details.channelId, 'habit_reminders');
        expect(details.high, isFalse);
        // The whole window was cancelled before arming.
        expect(fake.cancelled, containsAll(habitTimeCancelIds('h1', now)));
      },
    );

    test('completed today: today is not armed, tomorrow is', () async {
      final fake = RecordingFake();
      await HabitTimeReminderSync(fake).syncHabits([
        habit(logs: const ['2026-11-15']),
      ], now: now);
      expect(fake.once.length, 35);
      expect(
        fake.once.containsKey(
          habitTimeNotificationId('h1', DateTime(2026, 11, 15)),
        ),
        isFalse,
      );
      expect(
        fake.once[habitTimeNotificationId('h1', DateTime(2026, 11, 16))],
        DateTime(2026, 11, 16, 9, 30),
      );
    });

    test('Anytime habit: cancel only, nothing armed', () async {
      final fake = RecordingFake();
      await HabitTimeReminderSync(fake)
          .syncHabits([habit(targetTime: 'Anytime')], now: now);
      expect(fake.once, isEmpty);
      expect(fake.cancelled, containsAll(habitTimeCancelIds('h1', now)));
    });

    test(
      'notifications disabled: all windows cancelled, nothing armed',
      () async {
        final fake = RecordingFake(enabled: false);
        await HabitTimeReminderSync(fake).syncHabits([
          habit(),
          habit(id: 'h2', targetTime: 'Anytime'),
        ], now: now);
        expect(fake.once, isEmpty);
        expect(fake.cancelled, containsAll(habitTimeCancelIds('h1', now)));
        expect(fake.cancelled, containsAll(habitTimeCancelIds('h2', now)));
      },
    );

    test('cancelHabit sweeps the habit window only', () async {
      final fake = RecordingFake();
      await HabitTimeReminderSync(fake).cancelHabit('h1', now: now);
      expect(fake.once, isEmpty);
      expect(fake.cancelled, containsAll(habitTimeCancelIds('h1', now)));
      expect(
        fake.cancelled,
        isNot(contains(habitTimeNotificationId('h2', now))),
      );
    });
  });

  group('backend: createHabit target_time + updateHabitTargetTime', () {
    test('createHabit sends the given target_time', () async {
      http.Request? seen;
      final backend = _backendWith(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'habit': {
                'id': 'h9',
                'title': 'Stretch',
                'target_time': '07:30',
                'logs': <String>[],
              },
            }),
            200,
          );
        }),
        token: 'tok',
      );
      final habit = await backend.createHabit('Stretch', targetTime: '07:30');
      expect(jsonDecode(seen!.body), {
        'title': 'Stretch',
        'target_time': '07:30',
      });
      expect(habit?.targetTime, '07:30');
    });

    test(
      'updateHabitTargetTime: PATCH method, path, body; 200 → true',
      () async {
        http.Request? seen;
        final backend = _backendWith(
          MockClient((request) async {
            seen = request;
            return http.Response(
              jsonEncode({
                'habit': {'id': 'h1', 'title': 'x', 'target_time': '07:30'},
              }),
              200,
            );
          }),
          token: 'tok',
        );
        expect(
          await backend.updateHabitTargetTime(
            habitId: 'h1',
            targetTime: '07:30',
          ),
          isTrue,
        );
        expect(seen!.method, 'PATCH');
        expect(seen!.url.path, '/api/habits/h1');
        expect(jsonDecode(seen!.body), {'target_time': '07:30'});
      },
    );

    test('updateHabitTargetTime: id is URL-encoded', () async {
      http.Request? seen;
      final backend = _backendWith(
        MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
        token: 'tok',
      );
      await backend.updateHabitTargetTime(
        habitId: 'h 42',
        targetTime: 'Anytime',
      );
      expect(seen!.url.path, '/api/habits/h%2042');
      expect(jsonDecode(seen!.body), {'target_time': 'Anytime'});
    });

    test('updateHabitTargetTime: 400/404/500/no-session → false', () async {
      for (final status in [400, 404, 500]) {
        final backend = _backendWith(
          MockClient((_) async => http.Response('{"error":"x"}', status)),
          token: 'tok',
        );
        expect(
          await backend.updateHabitTargetTime(
            habitId: 'h1',
            targetTime: '07:30',
          ),
          isFalse,
          reason: 'status $status',
        );
      }
      var called = false;
      final noSession = _backendWith(
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      expect(
        await noSession.updateHabitTargetTime(
          habitId: 'h1',
          targetTime: '07:30',
        ),
        isFalse,
      );
      expect(called, isFalse);
    });

    test('updateHabitTargetTime invalidates the habits cache on success '
        'only', () async {
      var gets = 0;
      var patchStatus = 200;
      final backend = _backendWith(
        MockClient((request) async {
          if (request.method == 'GET') {
            gets++;
            return http.Response(
              jsonEncode({
                'habits': [
                  {'id': 'h1', 'title': 'x', 'logs': <String>[]},
                ],
              }),
              200,
            );
          }
          return http.Response('{}', patchStatus);
        }),
        token: 'tok',
      );
      await backend.fetchHabitsOrNull();
      await backend.fetchHabitsOrNull(); // cache hit
      expect(gets, 1);
      // Failed PATCH: cache survives.
      patchStatus = 400;
      expect(
        await backend.updateHabitTargetTime(habitId: 'h1', targetTime: '07:30'),
        isFalse,
      );
      await backend.fetchHabitsOrNull();
      expect(gets, 1);
      // Successful PATCH: cache dropped, next fetch hits the server.
      patchStatus = 200;
      expect(
        await backend.updateHabitTargetTime(habitId: 'h1', targetTime: '07:30'),
        isTrue,
      );
      await backend.fetchHabitsOrNull();
      expect(gets, 2);
    });
  });

  group('habits screen: time flows (widget)', () {
    Widget screen(_HabitTimeServer server, RecordingFake fake) => HabitsScreen(
      backend: _backendWith(server.client(), token: 'tok'),
      notificationService: fake,
    );

    Future<void> pump(WidgetTester tester, Widget w) async {
      await tester.pumpWidget(MaterialApp(home: w));
      await tester.pumpAndSettle();
    }

    testWidgets('add with a picked time sends it and resets the chip', (
      tester,
    ) async {
      final server = _HabitTimeServer([]);
      final fake = RecordingFake();
      await pump(tester, screen(server, fake));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('habit_add_time_chip')),
          matching: find.text('Anytime'),
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), 'Meditate');
      await tester.tap(find.byKey(const ValueKey('habit_add_time_chip')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK')); // time picker, seeded with now
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add_circle));
      await tester.pumpAndSettle();

      expect(server.posts, hasLength(1));
      final body = jsonDecode(server.posts.single.body) as Map<String, dynamic>;
      expect(body['title'], 'Meditate');
      expect(
        body['target_time'],
        matches(RegExp(r'^([01]\d|2[0-3]):[0-5]\d$')),
      );
      expect(body['target_time'], isNot('Anytime'));
      expect(find.text('Meditate'), findsOneWidget);
      // Picker state reset to Anytime after the successful add.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('habit_add_time_chip')),
          matching: find.text('Anytime'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('edit via Pick a time: PATCH saves, display shows the time, '
        'no log toggle', (tester) async {
      final server = _HabitTimeServer([
        {
          'id': 'h1',
          'title': 'Drink water',
          'target_time': '07:30',
          'logs': <String>[],
        },
      ]);
      final fake = RecordingFake();
      await pump(tester, screen(server, fake));
      expect(find.text('7:30 AM'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('habit_time_h1')));
      await tester.pumpAndSettle();
      expect(find.text('Pick a time'), findsOneWidget);
      expect(find.text('Anytime'), findsWidgets);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Pick a time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK')); // seeded 07:30 → same value
      await tester.pumpAndSettle();

      expect(server.patches, hasLength(1));
      expect(server.patches.single.method, 'PATCH');
      expect(server.patches.single.url.path, '/api/habits/h1');
      expect(jsonDecode(server.patches.single.body), {'target_time': '07:30'});
      expect(server.logs, isEmpty); // the editor never toggles
      expect(find.text('7:30 AM'), findsOneWidget);
      expect(find.text('0/1 DONE'), findsOneWidget);
    });

    testWidgets('edit via Anytime: PATCH clears and display updates', (
      tester,
    ) async {
      final server = _HabitTimeServer([
        {
          'id': 'h1',
          'title': 'Drink water',
          'target_time': '19:30',
          'logs': <String>[],
        },
      ]);
      final fake = RecordingFake();
      await pump(tester, screen(server, fake));
      expect(find.text('7:30 PM'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('habit_time_h1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anytime').last);
      await tester.pumpAndSettle();

      expect(server.patches, hasLength(1));
      expect(jsonDecode(server.patches.single.body), {
        'target_time': 'Anytime',
      });
      expect(find.text('7:30 PM'), findsNothing);
      // Card now shows Anytime (the chip does too, hence widgets).
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('habit_time_h1')),
          matching: find.text('Anytime'),
        ),
        findsOneWidget,
      );
      expect(server.logs, isEmpty);
    });

    testWidgets('edit failure: Juno error shown, old time preserved', (
      tester,
    ) async {
      final server = _HabitTimeServer([
        {
          'id': 'h1',
          'title': 'Drink water',
          'target_time': '19:30',
          'logs': <String>[],
        },
      ])..patchStatus = 500;
      final fake = RecordingFake();
      await pump(tester, screen(server, fake));
      expect(find.text('7:30 PM'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('habit_time_h1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anytime').last);
      await tester.pump();
      expect(
        find.text(
          'Could not save that time. Check your connection and try again.',
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(find.text('7:30 PM'), findsOneWidget);
      expect(server.habits.single['target_time'], '19:30');
    });

    testWidgets('editor Cancel: no PATCH, no toggle', (tester) async {
      final server = _HabitTimeServer([
        {
          'id': 'h1',
          'title': 'Drink water',
          'target_time': '07:30',
          'logs': <String>[],
        },
      ]);
      final fake = RecordingFake();
      await pump(tester, screen(server, fake));

      await tester.tap(find.byKey(const ValueKey('habit_time_h1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(server.patches, isEmpty);
      expect(server.logs, isEmpty);
      expect(find.text('0/1 DONE'), findsOneWidget);
    });

    testWidgets('toggle re-syncs: completing cancels today, un-completing '
        're-arms it when ahead', (tester) async {
      final now = DateTime.now();
      // A time later today (23:59) so the load sync arms today.
      final target = DateTime(now.year, now.month, now.day, 23, 59);
      final rearmExpected = target.isAfter(now);
      final server = _HabitTimeServer([
        {
          'id': 'h1',
          'title': 'Drink water',
          'target_time': '23:59',
          'logs': <String>[],
        },
      ]);
      final fake = RecordingFake();
      await pump(tester, screen(server, fake));
      final todayId = habitTimeNotificationId('h1', now);
      if (rearmExpected) {
        expect(fake.once[todayId], target);
      }

      await tester.tap(find.text('Drink water'));
      await tester.pumpAndSettle();
      expect(find.text('1/1 DONE'), findsOneWidget);
      // Today landed in completedDates → today's one-shot is gone.
      expect(fake.once.containsKey(todayId), isFalse);
      expect(fake.cancelled, contains(todayId));

      await tester.tap(find.text('Drink water'));
      await tester.pumpAndSettle();
      expect(find.text('0/1 DONE'), findsOneWidget);
      if (rearmExpected) {
        expect(fake.once[todayId], target);
      }
    });

    testWidgets('delete cancels the deleted habit window', (tester) async {
      final server = _HabitTimeServer([
        {
          'id': 'h1',
          'title': 'Drink water',
          'target_time': '23:59',
          'logs': <String>[],
        },
      ]);
      final fake = RecordingFake();
      await pump(tester, screen(server, fake));
      final todayId = habitTimeNotificationId('h1', DateTime.now());
      fake.cancelled.clear();

      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();

      expect(find.text('Drink water'), findsNothing);
      expect(fake.once.containsKey(todayId), isFalse);
      expect(
        fake.cancelled,
        containsAll(habitTimeCancelIds('h1', DateTime.now())),
      );
    });
  });
}
