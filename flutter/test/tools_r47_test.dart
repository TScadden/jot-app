import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/reminder_alarm_sync.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';

import 'test_helpers.dart';

TabsBackend _backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

String _todayStr() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

/// In-memory stand-in for the sync-profile server: holds the
/// reminders blob, records every profile push, can be told to fail.
class _ReminderServer {
  List<Map<String, dynamic>> rows;
  bool failPush = false;
  final List<Map<String, dynamic>> pushes = [];

  _ReminderServer(this.rows);

  MockClient client() => MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'profile': {'reminders': jsonEncode(rows)},
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/profile') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          pushes.add(body);
          if (failPush) return http.Response('{"error":"x"}', 500);
          rows = TabsBackend.decodeProfileList(body['reminders']);
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      });

  /// The decoded reminder rows of the most recent push.
  List<Map<String, dynamic>> get lastPushedRows =>
      TabsBackend.decodeProfileList(pushes.last['reminders']);
}

/// In-memory stand-in for the habits endpoints.
class _HabitServer {
  List<Map<String, dynamic>> habits;
  final List<http.Request> posts = [];
  final List<http.Request> deletes = [];
  final List<http.Request> logs = [];
  bool failLog = false;
  int _nextId = 100;

  _HabitServer(this.habits);

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
        if (request.method == 'DELETE' && path.startsWith('/api/habits/')) {
          deletes.add(request);
          final id = path.split('/').last;
          habits = habits.where((h) => '${h['id']}' != id).toList();
          return http.Response('{}', 200);
        }
        if (request.method == 'POST' && path == '/api/habits/log') {
          logs.add(request);
          if (failLog) return http.Response('{"error":"x"}', 500);
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      });
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _medsRow() => {
      'id': 3,
      'title': 'Take meds',
      'type': 'FIXED',
      'fixedHour': 9,
      'fixedMinute': 0,
      'intervalHours': 2,
      'intervalMinutes': 0,
      'startHour': 8,
      'startMinute': 0,
      'endHour': 21,
      'endMinute': 0,
      'isEnabled': true,
      'daysOfWeekConfig': '',
      'unknownFutureKey': {'nested': [1, 2, 3]},
    };

Map<String, dynamic> _waterRow() => {
      'id': 7,
      'title': 'Drink water',
      'type': 'INTERVAL',
      'fixedHour': 12,
      'fixedMinute': 0,
      'intervalHours': 2,
      'intervalMinutes': 0,
      'startHour': 8,
      'startMinute': 0,
      'endHour': 21,
      'endMinute': 0,
      'isEnabled': false,
      'daysOfWeekConfig': '',
    };

void main() {
  group('r47 model: id + dayOfWeek tolerant parsing', () {
    test('id parses from num and string; absent → 0', () {
      expect(ReminderModel.fromJson({'id': 7, 'title': 'x'}).id, 7);
      expect(ReminderModel.fromJson({'id': '9', 'title': 'x'}).id, 9);
      expect(ReminderModel.fromJson({'title': 'x'}).id, 0);
    });

    test('dayOfWeek parses; absent derives from dayName (Calendar)', () {
      final parsed = DayTimeConfig.fromJson(
          {'dayOfWeek': 5, 'dayName': 'Thu', 'isEnabled': true});
      expect(parsed.dayOfWeek, 5);
      expect(
          DayTimeConfig.fromJson({'dayName': 'Sun'}).dayOfWeek, 1);
      expect(
          DayTimeConfig.fromJson({'dayName': 'Mon'}).dayOfWeek, 2);
      expect(
          DayTimeConfig.fromJson({'dayName': 'Sat'}).dayOfWeek, 7);
      expect(DayTimeConfig.fromJson({'dayName': ''}).dayOfWeek, 2);
      // String-encoded numbers are tolerated too.
      expect(
          DayTimeConfig.fromJson({'dayOfWeek': '3', 'dayName': 'Tue'})
              .dayOfWeek,
          3);
    });

    test('nextReminderId is max+1, starting at 1', () {
      expect(nextReminderId([]), 1);
      expect(nextReminderId([_medsRow(), _waterRow()]), 8);
      expect(nextReminderId([{'id': '4'}]), 5);
    });
  });

  group('r47 Day enum mapping (flutter_local_notifications 19.5.0)', () {
    test('plugin Day values are Calendar constants, 1:1', () {
      // Evidence: pubspec.lock pins flutter_local_notifications
      // 19.5.0, whose lib/src/types.dart declares
      // `enum Day { sunday(1), monday(2), tuesday(3), wednesday(4),
      // thursday(5), friday(6), saturday(7) }`.
      expect(Day.sunday.value, 1);
      expect(Day.monday.value, 2);
      expect(Day.saturday.value, 7);
      for (var cal = 1; cal <= 7; cal++) {
        expect(dayForCalendarDayOfWeek(cal).value, cal);
        expect(dayForCalendarDayOfWeek(cal), Day.values[cal - 1]);
      }
    });

    test('calendarDayOfWeek rotates Dart weekday to Calendar', () {
      // 2026-10-11 was a Sunday; 2026-10-12 a Monday; 2026-10-17 Sat.
      expect(calendarDayOfWeek(DateTime(2026, 10, 11)), 1);
      expect(calendarDayOfWeek(DateTime(2026, 10, 12)), 2);
      expect(calendarDayOfWeek(DateTime(2026, 10, 17)), 7);
    });

    test('nextWeeklyInstance lands on the right weekday/time', () {
      final wedMorning = DateTime(2026, 10, 14, 10, 0); // Wednesday
      // Calendar constants: SUNDAY=1, MONDAY=2, …, WEDNESDAY=4.
      expect(calendarDayOfWeek(wedMorning), 4);
      // Same weekday, time still ahead → today.
      expect(nextWeeklyInstance(wedMorning, 4, 11, 30),
          DateTime(2026, 10, 14, 11, 30));
      // Same weekday, time passed → next week.
      expect(nextWeeklyInstance(wedMorning, 4, 9, 0),
          DateTime(2026, 10, 21, 9, 0));
      // Sunday (Calendar 1) → 2026-10-18.
      expect(nextWeeklyInstance(wedMorning, 1, 8, 0),
          DateTime(2026, 10, 18, 8, 0));
    });
  });

  group('r47 whole-list integrity (ReminderDocument)', () {
    test('toggle flips ONLY isEnabled on the targeted raw row', () {
      final doc = ReminderDocument.fromRawRows([_medsRow(), _waterRow()]);
      final out = doc.toggledAt(0, false).encode();
      final expectedFirst = _medsRow()..['isEnabled'] = false;
      expect(out[0], equals(expectedFirst));
      expect(out[1], equals(_waterRow()));
    });

    test('delete removes exactly the targeted row', () {
      final doc = ReminderDocument.fromRawRows([_medsRow(), _waterRow()]);
      expect(doc.removedAt(0).encode(), equals([_waterRow()]));
      expect(doc.removedAt(1).encode(), equals([_medsRow()]));
      // Out of range refuses rather than guess.
      expect(doc.removedAt(5).encode(), hasLength(2));
    });

    test('edit splices edited fields; unknown keys + other rows intact',
        () {
      final doc = ReminderDocument.fromRawRows([_medsRow(), _waterRow()]);
      final edited = buildReminderRow(
        id: 3,
        title: 'Take meds PM',
        type: 'FIXED',
        fixedHour: 20,
        fixedMinute: 30,
        intervalHours: 2,
        intervalMinutes: 0,
        startHour: 8,
        startMinute: 0,
        endHour: 21,
        endMinute: 0,
        isEnabled: true,
        customDays: false,
        dayConfigs: const [],
      );
      final out = doc.replacedAt(0, edited).encode();
      expect(out[0]['title'], 'Take meds PM');
      expect(out[0]['fixedHour'], 20);
      expect(out[0]['id'], 3);
      // The unknown key on the edited row survives the splice.
      expect(out[0]['unknownFutureKey'], equals({'nested': [1, 2, 3]}));
      // The untouched row is deep-equal to what was pulled.
      expect(out[1], equals(_waterRow()));
    });

    test('new row has the full native shape incl. stringified days', () {
      final row = buildReminderRow(
        id: 8,
        title: 'Gym',
        type: 'FIXED',
        fixedHour: 8,
        fixedMinute: 0,
        intervalHours: 2,
        intervalMinutes: 0,
        startHour: 8,
        startMinute: 0,
        endHour: 21,
        endMinute: 0,
        isEnabled: true,
        customDays: true,
        dayConfigs: const [
          DayTimeConfig(
              dayOfWeek: 2, dayName: 'Mon', isEnabled: true, hour: 9, minute: 0),
          DayTimeConfig(
              dayOfWeek: 1, dayName: 'Sun', isEnabled: false, hour: 9, minute: 0),
        ],
      );
      expect(row.keys.toSet(), {
        'id', 'title', 'type', 'fixedHour', 'fixedMinute', 'intervalHours',
        'intervalMinutes', 'startHour', 'startMinute', 'endHour', 'endMinute',
        'isEnabled', 'daysOfWeekConfig',
      });
      final days = jsonDecode(row['daysOfWeekConfig'] as String) as List;
      expect(days, hasLength(2));
      expect(days[0], {
        'dayOfWeek': 2,
        'dayName': 'Mon',
        'isEnabled': true,
        'hour': 9,
        'minute': 0,
      });
      expect(days[1]['dayOfWeek'], 1); // Sunday = Calendar 1
      // Not customizing → empty string, native parity.
      final plain = buildReminderRow(
        id: 1,
        title: 'x',
        type: 'FIXED',
        fixedHour: 8,
        fixedMinute: 0,
        intervalHours: 2,
        intervalMinutes: 0,
        startHour: 8,
        startMinute: 0,
        endHour: 21,
        endMinute: 0,
        isEnabled: true,
        customDays: false,
        dayConfigs: const [],
      );
      expect(plain['daysOfWeekConfig'], '');
    });
  });

  group('r47 alarm sync slot scheme', () {
    ReminderModel model(Map<String, dynamic> row) =>
        ReminderModel.fromJson(row);

    test('FIXED no-days: cancel 0..47 then daily at slot id*1000', () async {
      final fake = FakeReminderNotificationService();
      await syncReminderAlarms(fake, model(_medsRow()));
      expect(fake.cancelled, [for (var s = 0; s <= 47; s++) 3000 + s]);
      expect(fake.daily, {3000: '9:0'});
      expect(fake.weekly, isEmpty);
    });

    test('FIXED days: weekly slots keyed by Calendar dayOfWeek', () async {
      final fake = FakeReminderNotificationService();
      final row = _medsRow()
        ..['daysOfWeekConfig'] = jsonEncode([
          {'dayOfWeek': 2, 'dayName': 'Mon', 'isEnabled': true, 'hour': 7, 'minute': 15},
          {'dayOfWeek': 4, 'dayName': 'Wed', 'isEnabled': false, 'hour': 7, 'minute': 15},
          {'dayOfWeek': 1, 'dayName': 'Sun', 'isEnabled': true, 'hour': 10, 'minute': 0},
        ]);
      await syncReminderAlarms(fake, model(row));
      expect(fake.daily, isEmpty);
      expect(fake.weekly, {3002: '2 7:15', 3001: '1 10:0'});
    });

    test('INTERVAL: one daily slot per computed time, ordinal slots',
        () async {
      final fake = FakeReminderNotificationService();
      await syncReminderAlarms(fake, model(_waterRow()..['isEnabled'] = true));
      // 8:00 → 21:00 every 2h = 8,10,12,14,16,18,20 → 7 slots.
      expect(fake.daily.keys.toList(),
          [7000, 7001, 7002, 7003, 7004, 7005, 7006]);
      expect(fake.daily[7000], '8:0');
      expect(fake.daily[7006], '20:0');
    });

    test('INTERVAL zero interval schedules nothing (cancel only)',
        () async {
      final fake = FakeReminderNotificationService();
      final row = _waterRow()
        ..['isEnabled'] = true
        ..['intervalHours'] = 0
        ..['intervalMinutes'] = 0;
      await syncReminderAlarms(fake, model(row));
      expect(fake.daily, isEmpty);
      expect(fake.cancelled, hasLength(48));
    });

    test('disabled: cancel only. Deleted: cancelReminderAlarms only',
        () async {
      final fake = FakeReminderNotificationService();
      await syncReminderAlarms(fake, model(_waterRow())); // disabled
      expect(fake.daily, isEmpty);
      expect(fake.weekly, isEmpty);
      expect(fake.cancelled, [for (var s = 0; s <= 47; s++) 7000 + s]);

      final fake2 = FakeReminderNotificationService();
      await cancelReminderAlarms(fake2, 7);
      expect(fake2.cancelled, [for (var s = 0; s <= 47; s++) 7000 + s]);
      expect(fake2.daily, isEmpty);
    });
  });

  group('r47 reminders UI writes', () {
    Widget screen(_ReminderServer server, {FakeReminderNotificationService? notifs}) {
      return RemindersScreen(
        backend: _backendWith(server.client(), token: 'tok'),
        notificationService:
            notifs ?? FakeReminderNotificationService(),
      );
    }

    testWidgets('create pushes the FULL list with a native-shaped new row',
        (tester) async {
      final server = _ReminderServer([_medsRow()]);
      await _pump(tester, screen(server));
      expect(find.text('Take meds'), findsOneWidget);

      await tester.tap(find.text('New Reminder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Stretch');
      await tester.pump(); // let the title listener enable Save
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(server.pushes, hasLength(1));
      final rows = server.lastPushedRows;
      expect(rows, hasLength(2));
      expect(rows[0], equals(_medsRow())); // untouched row intact
      final created = rows[1];
      expect(created['id'], 4); // max(3)+1
      expect(created['title'], 'Stretch');
      expect(created['type'], 'FIXED');
      expect(created['fixedHour'], 8); // sheet default 8:00
      expect(created['isEnabled'], isTrue);
      expect(created['daysOfWeekConfig'], '');
      expect(find.text('Stretch'), findsOneWidget);
    });

    testWidgets('create with blank title: Save stays disabled',
        (tester) async {
      final server = _ReminderServer([]);
      await _pump(tester, screen(server));
      await tester.tap(find.text('New Reminder'));
      await tester.pumpAndSettle();
      final save = tester.widget<FilledButton>(find.widgetWithText(
          FilledButton, 'Save'));
      expect(save.onPressed, isNull);
      expect(server.pushes, isEmpty);
    });

    testWidgets('edit via card tap changes only that row, keeps id',
        (tester) async {
      final server = _ReminderServer([_medsRow(), _waterRow()]);
      await _pump(tester, screen(server));
      await tester.tap(find.text('Take meds'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Reminder'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Take meds PM');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final rows = server.lastPushedRows;
      expect(rows, hasLength(2));
      expect(rows[0]['id'], 3);
      expect(rows[0]['title'], 'Take meds PM');
      expect(rows[0]['unknownFutureKey'], equals({'nested': [1, 2, 3]}));
      expect(rows[1], equals(_waterRow()));
    });

    testWidgets('toggle pushes the full list with only isEnabled flipped',
        (tester) async {
      final server = _ReminderServer([_medsRow(), _waterRow()]);
      await _pump(tester, screen(server));
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      final rows = server.lastPushedRows;
      final expectedFirst = _medsRow()..['isEnabled'] = false;
      expect(rows[0], equals(expectedFirst));
      expect(rows[1], equals(_waterRow()));
    });

    testWidgets('delete removes exactly that row, no confirmation',
        (tester) async {
      final server = _ReminderServer([_medsRow(), _waterRow()]);
      final notifs = FakeReminderNotificationService();
      await _pump(tester, screen(server, notifs: notifs));
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();

      expect(server.lastPushedRows, equals([_waterRow()]));
      expect(find.text('Take meds'), findsNothing);
      // Delete cancels that reminder's slots.
      expect(notifs.cancelled, containsAll([3000, 3047]));
    });

    testWidgets('push failure: error shown, list reloads unchanged',
        (tester) async {
      final server = _ReminderServer([_medsRow()])..failPush = true;
      await _pump(tester, screen(server));
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(
          find.text(
              'Could not save that change. Check your connection and try again.'),
          findsOneWidget);
      await tester.pumpAndSettle();
      // Reloaded from the server: still enabled, still present.
      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isTrue);
      expect(find.text('Take meds'), findsOneWidget);
    });
  });

  group('r47 habits backend', () {
    test('createHabit posts the native body and parses the habit',
        () async {
      http.Request? seen;
      final backend = _backendWith(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'habit': {'id': 'h9', 'title': 'Stretch', 'logs': []},
            }),
            200,
          );
        }),
        token: 'tok',
      );
      final habit = await backend.createHabit('Stretch');
      expect(seen!.url.path, '/api/habits');
      expect(jsonDecode(seen!.body),
          {'title': 'Stretch', 'target_time': 'Anytime'});
      expect(habit?.id, 'h9');
      expect(habit?.title, 'Stretch');
    });

    test('createHabit failure → null; deleteHabit hits the right path',
        () async {
      final failing = _backendWith(
        MockClient((_) async => http.Response('{"error":"x"}', 500)),
        token: 'tok',
      );
      expect(await failing.createHabit('x'), isNull);

      http.Request? seen;
      final backend = _backendWith(
        MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
        token: 'tok',
      );
      expect(await backend.deleteHabit('h42'), isTrue);
      expect(seen!.method, 'DELETE');
      expect(seen!.url.path, '/api/habits/h42');
    });
  });

  group('r47 habits UI writes', () {
    Widget screen(_HabitServer server) => HabitsScreen(
        backend: _backendWith(server.client(), token: 'tok'));

    testWidgets('add via the inline field posts and refreshes the list',
        (tester) async {
      final server = _HabitServer([
        {'id': 'h1', 'title': 'Drink water', 'logs': <String>[]},
      ]);
      await _pump(tester, screen(server));
      expect(find.text('Drink water'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  Meditate  ');
      await tester.tap(find.byIcon(Icons.add_circle));
      await tester.pumpAndSettle();

      expect(server.posts, hasLength(1));
      expect(jsonDecode(server.posts.single.body),
          {'title': 'Meditate', 'target_time': 'Anytime'});
      expect(find.text('Meditate'), findsOneWidget);
    });

    testWidgets('blank add is rejected (no POST)', (tester) async {
      final server = _HabitServer([]);
      await _pump(tester, screen(server));
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.byIcon(Icons.add_circle));
      await tester.pumpAndSettle();
      expect(server.posts, isEmpty);
    });

    testWidgets('delete ✕ hits DELETE and the card disappears',
        (tester) async {
      final server = _HabitServer([
        {'id': 'h1', 'title': 'Drink water', 'logs': <String>[]},
        {'id': 'h2', 'title': 'Walk', 'logs': <String>[]},
      ]);
      await _pump(tester, screen(server));
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();

      expect(server.deletes, hasLength(1));
      expect(server.deletes.single.url.path, '/api/habits/h1');
      expect(find.text('Drink water'), findsNothing);
      expect(find.text('Walk'), findsOneWidget);
    });

    testWidgets('card tap logs today via logHabit and flips the card',
        (tester) async {
      final server = _HabitServer([
        {'id': 'h1', 'title': 'Drink water', 'logs': <String>[]},
      ]);
      await _pump(tester, screen(server));
      expect(find.text('0/1 DONE'), findsOneWidget);

      await tester.tap(find.text('Drink water'));
      await tester.pumpAndSettle();

      expect(server.logs, hasLength(1));
      expect(jsonDecode(server.logs.single.body), {
        'habit_id': 'h1',
        'completed_date': _todayStr(),
        'is_completed': true,
      });
      expect(find.text('1/1 DONE'), findsOneWidget);

      // Tap again → un-log.
      await tester.tap(find.text('Drink water'));
      await tester.pumpAndSettle();
      expect(jsonDecode(server.logs.last.body), {
        'habit_id': 'h1',
        'completed_date': _todayStr(),
        'is_completed': false,
      });
      expect(find.text('0/1 DONE'), findsOneWidget);
    });

    testWidgets('log failure reverts the optimistic toggle + error',
        (tester) async {
      final server = _HabitServer([
        {'id': 'h1', 'title': 'Drink water', 'logs': <String>[]},
      ])
        ..failLog = true;
      await _pump(tester, screen(server));
      await tester.tap(find.text('Drink water'));
      await tester.pump();
      expect(
          find.text(
              'Could not update that habit. Check your connection and try again.'),
          findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('0/1 DONE'), findsOneWidget);
    });

    test('streak helpers are untouched by the write flow', () {
      final today = _todayStr();
      expect(
          habitStreak([today]),
          1);
      expect(overallHabitStreak(const []), 0);
    });
  });
}
