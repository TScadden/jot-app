import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_data.dart';
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

/// Fix round (Vera B3) — reminder server whose profile push can
/// be held open on [gate] so a test can attempt a second write
/// while the first push is still in flight.
class _BlockingReminderServer {
  List<Map<String, dynamic>> rows;
  Completer<void>? gate;
  final List<Map<String, dynamic>> pushes = [];

  _BlockingReminderServer(this.rows);

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
          final g = gate;
          if (g != null) await g.future;
          rows = TabsBackend.decodeProfileList(body['reminders']);
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      });
}

/// Fix-round hardening — a habits backend whose SECOND fetch
/// throws, so a test can prove a post-write refetch failure is
/// surfaced instead of silently leaving a stale list.
class _FlakyRefreshBackend extends TabsBackend {
  int fetches = 0;

  _FlakyRefreshBackend()
      : super(
          client: MockClient((_) async => http.Response('{}', 200)),
          sessionStore: FakeSessionStore()..token = 'tok',
        );

  @override
  Future<List<HabitDto>> fetchHabits() async {
    fetches++;
    if (fetches > 1) throw StateError('refetch failed');
    return const [
      HabitDto(id: 'h1', title: 'Drink water', logs: []),
    ];
  }

  @override
  Future<HabitDto?> createHabit(String title) async =>
      HabitDto(id: 'h2', title: title, logs: const []);
}

/// In-memory stand-in for the habits endpoints.
class _HabitServer {
  List<Map<String, dynamic>> habits;
  final List<http.Request> posts = [];
  final List<http.Request> deletes = [];
  final List<http.Request> logs = [];
  bool failLog = false;

  /// Fix round (Vera B3) — when set, a log POST parks on this
  /// completer so a test can attempt a second write mid-flight.
  Completer<void>? logGate;
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
          final g = logGate;
          if (g != null) await g.future;
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

  group('r47 alarm sync slot scheme (fix-round block ids)', () {
    ReminderModel model(Map<String, dynamic> row) =>
        ReminderModel.fromJson(row);

    // Fix-round scheme: pluginId = 100000 + id * 1500 + slot.
    int base(int id) => 100000 + id * 1500;
    List<int> block(int id) => [for (var s = 0; s < 1500; s++) base(id) + s];

    test('FIXED no-days: cancel whole block, then daily at block slot 0',
        () async {
      final fake = FakeReminderNotificationService();
      await syncReminderAlarms(fake, model(_medsRow()));
      expect(fake.cancelled, block(3));
      expect(fake.daily, {base(3): '9:0'});
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
      expect(fake.weekly, {base(3) + 2: '2 7:15', base(3) + 1: '1 10:0'});
    });

    test('INTERVAL: one daily slot per computed time, ordinal slots',
        () async {
      final fake = FakeReminderNotificationService();
      await syncReminderAlarms(fake, model(_waterRow()..['isEnabled'] = true));
      // 8:00 → 21:00 every 2h = 8,10,12,14,16,18,20 → 7 slots.
      expect(fake.daily.keys.toList(),
          [for (var s = 0; s < 7; s++) base(7) + s]);
      expect(fake.daily[base(7)], '8:0');
      expect(fake.daily[base(7) + 6], '20:0');
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
      expect(fake.cancelled, hasLength(1500));
    });

    test('disabled: cancel only. Deleted: cancelReminderAlarms only',
        () async {
      final fake = FakeReminderNotificationService();
      await syncReminderAlarms(fake, model(_waterRow())); // disabled
      expect(fake.daily, isEmpty);
      expect(fake.weekly, isEmpty);
      expect(fake.cancelled, block(7));

      final fake2 = FakeReminderNotificationService();
      await cancelReminderAlarms(fake2, 7);
      expect(fake2.cancelled, block(7));
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
      // Juno F1 gate: rationale dialog first, Allow fires the
      // system request, then the sheet opens.
      await tester.tap(find.text('Allow'));
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
      await tester.tap(find.text('Allow'));
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
      // Delete cancels that reminder's whole fix-round block.
      expect(notifs.cancelled, containsAll([104500, 105999]));
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

  group('r47 fix round B1: plugin id block scheme', () {
    ReminderModel model(Map<String, dynamic> row) =>
        ReminderModel.fromJson(row);
    int base(int id) => 100000 + id * 1500;
    bool isReserved(int id) =>
        id == 1003 || id == 1004 || id == 770001 || (id >= 700000 && id <= 799998);

    test('scheme math: id 1 and max safe id 399 blocks', () {
      expect(reminderSlotId(1, 0), 101500);
      expect(reminderSlotId(1, 1499), 102999);
      expect(reminderSlotId(399, 0), 698500);
      expect(reminderSlotId(399, 1499), 699999);
      expect(isReminderIdSchedulable(1), isTrue);
      expect(isReminderIdSchedulable(399), isTrue);
      expect(isReminderIdSchedulable(400), isFalse);
      expect(isReminderIdSchedulable(0), isFalse);
      expect(isReminderIdSchedulable(770), isFalse);
    });

    test('id 1 custom-days (Tue/Wed) + INTERVAL never touch reserved ids',
        () async {
      final daysRow = _medsRow()
        ..['id'] = 1
        ..['daysOfWeekConfig'] = jsonEncode([
          {'dayOfWeek': 3, 'dayName': 'Tue', 'isEnabled': true, 'hour': 8, 'minute': 30},
          {'dayOfWeek': 4, 'dayName': 'Wed', 'isEnabled': true, 'hour': 9, 'minute': 45},
          {'dayOfWeek': 2, 'dayName': 'Mon', 'isEnabled': false, 'hour': 9, 'minute': 0},
        ]);
      final fake = FakeReminderNotificationService();
      await syncReminderAlarms(fake, model(daysRow));
      // Slots are the Calendar constants inside id 1's block.
      expect(fake.weekly, {101503: '3 8:30', 101504: '4 9:45'});
      expect(fake.cancelled, hasLength(1500));
      for (final id in [...fake.cancelled, ...fake.weekly.keys]) {
        expect(isReserved(id), isFalse, reason: 'id $id is reserved');
        expect(id, inInclusiveRange(101500, 102999));
      }

      final intervalRow = _waterRow()
        ..['id'] = 1
        ..['isEnabled'] = true;
      final fake2 = FakeReminderNotificationService();
      await syncReminderAlarms(fake2, model(intervalRow));
      expect(fake2.daily.keys.toList(),
          [for (var s = 0; s < 7; s++) 101500 + s]);
      for (final id in [...fake2.cancelled, ...fake2.daily.keys]) {
        expect(isReserved(id), isFalse, reason: 'id $id is reserved');
      }
      await cancelReminderAlarms(fake2, 1);
      expect(fake2.daily, isEmpty);
      expect(fake2.cancelled.every((id) => !isReserved(id)), isTrue);
    });

    test('out-of-range ids: nothing scheduled or cancelled, enabled throws',
        () async {
      for (final badId in [0, 400, 770]) {
        final fake = FakeReminderNotificationService();
        final row = _medsRow()..['id'] = badId;
        await expectLater(
          syncReminderAlarms(fake, model(row)),
          throwsA(isA<NotificationServiceException>()),
        );
        expect(fake.daily, isEmpty);
        expect(fake.weekly, isEmpty);
        expect(fake.cancelled, isEmpty);
        await cancelReminderAlarms(fake, badId);
        expect(fake.cancelled, isEmpty);
      }
      // A disabled out-of-range row is cancel-only by definition:
      // silent, and still touches nothing.
      final fake = FakeReminderNotificationService();
      final disabled = _waterRow()..['id'] = 400; // isEnabled false
      await syncReminderAlarms(fake, model(disabled));
      expect(fake.cancelled, isEmpty);
      // Reconcile isolates the bad row and reports failure.
      final ok = await reconcileReminderAlarms(
          fake, [model(_medsRow()), model(_medsRow()..['id'] = 400)]);
      expect(ok, isFalse);
      expect(fake.daily, {base(3): '9:0'});
    });

    testWidgets('reconcile on load leaves Settings notification ids untouched',
        (tester) async {
      final fake = FakeReminderNotificationService();
      // Pre-seed the fake with the Settings schedules (habit 1003,
      // project 1004, check-in 770001, one event counter in the
      // 700000 range) as ReminderSync would have left them.
      fake.daily[1003] = '19:0';
      fake.daily[1004] = '20:0';
      fake.daily[770001] = '4:0';
      fake.once[700123] = DateTime(2027, 1, 1, 9);
      final server = _ReminderServer([_medsRow()..['id'] = 1]);
      await _pump(
          tester,
          RemindersScreen(
            backend: _backendWith(server.client(), token: 'tok'),
            notificationService: fake,
          ));
      await tester.pumpAndSettle();
      expect(fake.daily[1003], '19:0');
      expect(fake.daily[1004], '20:0');
      expect(fake.daily[770001], '4:0');
      expect(fake.once[700123], DateTime(2027, 1, 1, 9));
      expect(fake.cancelled,
          isNot(contains(anyOf(1003, 1004, 770001, 700123))));
      // The id-1 reminder itself was reconciled into its own block.
      expect(fake.daily[101500], '9:0');
    });
  });

  group('r47 fix round B2: INTERVAL slots bounded by the block', () {
    Map<String, dynamic> intervalRow() => {
          'id': 5,
          'title': 'Water break',
          'type': 'INTERVAL',
          'fixedHour': 12,
          'fixedMinute': 0,
          'intervalHours': 0,
          'intervalMinutes': 15,
          'startHour': 8,
          'startMinute': 0,
          'endHour': 21,
          'endMinute': 0,
          'isEnabled': true,
          'daysOfWeekConfig': '',
        };

    test('53-slot interval (15 min across 8:00-21:00) fits the block',
        () async {
      final m = ReminderModel.fromJson(intervalRow());
      expect(intervalSlotMinutes(m), hasLength(53));
      final fake = FakeReminderNotificationService();
      await syncReminderAlarms(fake, m);
      expect(fake.daily, hasLength(53));
      expect(fake.daily.keys.first, 107500);
      expect(fake.daily.keys.last, 107500 + 52);
    });

    test('generation is capped at the 1500-slot block', () {
      final m = ReminderModel.fromJson(intervalRow()
        ..['intervalMinutes'] = 1
        ..['startHour'] = 0
        ..['startMinute'] = 0
        ..['endHour'] = 23
        ..['endMinute'] = 59);
      final times = intervalSlotMinutes(m);
      expect(times, hasLength(1440)); // full day at 1-minute steps
      expect(times.length, lessThanOrEqualTo(1500));
    });

    testWidgets('>48-slot INTERVAL: zero ghost ids after edit-away and delete',
        (tester) async {
      final server = _ReminderServer([intervalRow()]);
      final fake = FakeReminderNotificationService();
      await _pump(
          tester,
          RemindersScreen(
            backend: _backendWith(server.client(), token: 'tok'),
            notificationService: fake,
          ));
      await tester.pumpAndSettle();
      expect(fake.daily, hasLength(53)); // load reconcile scheduled it

      // Edit away: switch the type to FIXED and save.
      await tester.tap(find.text('Water break'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Reminder'), findsOneWidget);
      await tester.tap(find.text('Set Time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // Only the FIXED slot (block slot 0, the row's 12:00) remains.
      expect(fake.daily, {107500: '12:0'});
      expect(fake.weekly, isEmpty);

      // Delete: the whole block is cancelled, nothing survives.
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      expect(server.lastPushedRows, isEmpty);
      expect(fake.daily, isEmpty);
      expect(fake.weekly, isEmpty);
      expect(fake.once, isEmpty);
    });
  });

  group('r47 fix round B4: shared blob id delete reschedules the survivor',
      () {
    testWidgets('two rows share id 3; deleting one reschedules the other',
        (tester) async {
      final first = _medsRow(); // id 3, FIXED 9:00, "Take meds"
      final second = _medsRow()
        ..['title'] = 'Second dose'
        ..['fixedHour'] = 10;
      final server = _ReminderServer([first, second]);
      final fake = FakeReminderNotificationService();
      await _pump(
          tester,
          RemindersScreen(
            backend: _backendWith(server.client(), token: 'tok'),
            notificationService: fake,
          ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();

      expect(server.lastPushedRows, hasLength(1));
      expect(server.lastPushedRows.single['title'], 'Second dose');
      // The delete cancelled the shared block; the post-delete FULL
      // reconcile rescheduled the survivor's 10:00 slot.
      expect(fake.daily, {104500: '10:0'});
    });
  });

  group('r47 fix round B3: writes are serialized', () {
    testWidgets('reminders: a second toggle during a pending push is dropped',
        (tester) async {
      final server = _BlockingReminderServer([_medsRow(), _waterRow()]);
      final gate = Completer<void>();
      server.gate = gate;
      await _pump(
          tester,
          RemindersScreen(
            backend: _backendWith(server.client(), token: 'tok'),
            notificationService: FakeReminderNotificationService(),
          ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      await tester.pump();
      expect(server.pushes, hasLength(1));
      // Every write control is disabled while the push is pending.
      for (final sw in tester.widgetList<Switch>(find.byType(Switch))) {
        expect(sw.onChanged, isNull);
      }
      // Attempted second writes produce NO second push.
      await tester.tap(find.byType(Switch).last);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(server.pushes, hasLength(1));

      gate.complete();
      server.gate = null;
      await tester.pumpAndSettle();
      expect(server.pushes, hasLength(1));
      expect(server.rows[0]['isEnabled'], isFalse);
      expect(server.rows[1], equals(_waterRow()));

      // The serializer released: a fresh toggle pushes again.
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(server.pushes, hasLength(2));
      expect(server.rows[0]['isEnabled'], isTrue);
    });

    testWidgets('habits: a second toggle during a pending log is dropped',
        (tester) async {
      final server = _HabitServer([
        {'id': 'h1', 'title': 'Drink water', 'logs': <String>[]},
        {'id': 'h2', 'title': 'Walk', 'logs': <String>[]},
      ]);
      final gate = Completer<void>();
      server.logGate = gate;
      await _pump(
          tester,
          HabitsScreen(
              backend: _backendWith(server.client(), token: 'tok')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Drink water'));
      await tester.pump();
      await tester.pump();
      expect(server.logs, hasLength(1));
      expect(find.text('1/2 DONE'), findsOneWidget); // optimistic

      await tester.tap(find.text('Walk'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(server.logs, hasLength(1)); // no out-of-order second write
      expect(server.deletes, isEmpty);

      gate.complete();
      server.logGate = null;
      await tester.pumpAndSettle();
      expect(server.logs, hasLength(1));

      // Released: the next toggle goes through.
      await tester.tap(find.text('Walk'));
      await tester.pumpAndSettle();
      expect(server.logs, hasLength(2));
    });
  });

  group('r47 fix round Juno F1: create permission gate order', () {
    Widget screen(_ReminderServer server, FakeReminderNotificationService fake) {
      return RemindersScreen(
        backend: _backendWith(server.client(), token: 'tok'),
        notificationService: fake,
      );
    }

    testWidgets('rationale renders BEFORE any system request; granted opens sheet',
        (tester) async {
      final fake = FakeReminderNotificationService(); // exact = true
      final server = _ReminderServer([_medsRow()]);
      await _pump(tester, screen(server, fake));
      // Ignore any calls the load reconcile made; gate calls are
      // what this test tracks from the FAB tap on.
      fake.calls.clear();

      await tester.tap(find.text('New Reminder'));
      await tester.pumpAndSettle();
      expect(find.text('Enable Notifications'), findsOneWidget);
      expect(
          find.text(
              'Tabs needs notification permission to send your reminders. Tap Allow to continue.'),
          findsOneWidget);
      // Exact check ran; the system request has NOT fired yet.
      expect(fake.calls, ['canScheduleExact']);
      expect(fake.requestCount, 0);
      expect(find.text('Save'), findsNothing); // sheet not open yet

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(fake.calls,
          ['canScheduleExact', 'requestNotificationsPermission']);
      expect(find.text('Save'), findsOneWidget); // sheet opened
    });

    testWidgets('exact-alarm dialog runs FIRST, before the rationale',
        (tester) async {
      final fake = FakeReminderNotificationService()..exact = false;
      final server = _ReminderServer([_medsRow()]);
      await _pump(tester, screen(server, fake));
      fake.calls.clear();

      await tester.tap(find.text('New Reminder'));
      await tester.pumpAndSettle();
      expect(find.text('Exact alarms are off'), findsOneWidget);
      expect(find.text('Enable Notifications'), findsNothing);
      expect(fake.calls, ['canScheduleExact']);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Enable Notifications'), findsOneWidget);
      expect(fake.requestCount, 0);

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('denied at the system dialog: sheet never opens',
        (tester) async {
      final fake = FakeReminderNotificationService()
        ..grantOnRequest = false;
      final server = _ReminderServer([_medsRow()]);
      await _pump(tester, screen(server, fake));

      await tester.tap(find.text('New Reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(fake.requestCount, 1);
      expect(find.text('Save'), findsNothing);
      expect(server.pushes, isEmpty);
      // Existing reminders remain viewable.
      expect(find.text('Take meds'), findsOneWidget);
    });

    testWidgets('Not now at the rationale: no system request, no sheet',
        (tester) async {
      final fake = FakeReminderNotificationService();
      final server = _ReminderServer([_medsRow()]);
      await _pump(tester, screen(server, fake));

      await tester.tap(find.text('New Reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(fake.requestCount, 0);
      expect(find.text('Save'), findsNothing);
      expect(server.pushes, isEmpty);
    });

    testWidgets('edit on card tap does NOT run the gate', (tester) async {
      final fake = FakeReminderNotificationService()
        ..grantOnRequest = false;
      final server = _ReminderServer([_medsRow()]);
      await _pump(tester, screen(server, fake));
      fake.calls.clear();

      await tester.tap(find.text('Take meds'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Reminder'), findsOneWidget);
      expect(fake.calls, isEmpty);
      expect(fake.requestCount, 0);
    });
  });

  group('r47 fix round hardening (optional, Vera notes)', () {
    test('createHabit: a 2xx without a habit object is still success',
        () async {
      final noHabit = _backendWith(
        MockClient((_) async => http.Response('{}', 200)),
        token: 'tok',
      );
      final habit = await noHabit.createHabit('Stretch');
      expect(habit, isNotNull);
      expect(habit!.title, 'Stretch');

      final garbageBody = _backendWith(
        MockClient((_) async => http.Response('ok', 201)),
        token: 'tok',
      );
      expect(await garbageBody.createHabit('Stretch'), isNotNull);
    });

    testWidgets('habits: a post-create refetch failure surfaces an error',
        (tester) async {
      final backend = _FlakyRefreshBackend();
      await _pump(tester, HabitsScreen(backend: backend));
      expect(find.text('Drink water'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Meditate');
      await tester.tap(find.byIcon(Icons.add_circle));
      await tester.pumpAndSettle();

      expect(
          find.text(
              'Saved, but the habit list could not be refreshed. Check your connection and try again.'),
          findsOneWidget);
      // The stale list is still shown — with the error on top of it.
      expect(find.text('Drink water'), findsOneWidget);
    });
  });
}
