import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';

import 'test_helpers.dart';

/// Round 48, Group D — light re-audit of Habits, Reminders,
/// Medications, Trends. This file pins the defects the sweep
/// found and fixed:
///
/// 1. Habits (Vera R47 ledger): `fetchHabits()` returns `[]` on
///    any failure, so the post-write refresh could not tell a
///    failed refresh from an empty list — it blanked the list and
///    the "could not be refreshed" message was unreachable. The
///    nullable `fetchHabitsOrNull()` path fixes it: a failed
///    refresh surfaces the error and PRESERVES the on-screen list.
/// 2. Habits: the card parsed `target_time` but never rendered
///    it; native shows it under the title.
/// 3. Reminders: `isEnabled` parsing used strict bool identity —
///    a string-serialized "false" read as enabled on the reminder
///    row, and a string "true" read as disabled on a day row.
/// 4. Reminders: a title-only edit of an INTERVAL reminder whose
///    stored interval is zero or mixed (1h 30m) silently rewrote
///    the interval to the picker's XOR view; untouched intervals
///    are now preserved verbatim.
/// 5. Medications: archive/edit whole-list pushes were not
///    serialized (the Vera B3 discipline Habits/Reminders got in
///    R47) — two concurrent pushes could land out of order and
///    the older document would undo the newer change.

TabsBackend _backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

// ── Habits server ─────────────────────────────────────────────────

class _HabitServer {
  List<Map<String, dynamic>> habits;
  bool failGets = false;
  int _nextId = 100;

  _HabitServer(this.habits);

  MockClient client() => MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/api/habits') {
          if (failGets) return http.Response('{"error":"x"}', 500);
          return http.Response(jsonEncode({'habits': habits}), 200);
        }
        if (request.method == 'POST' && path == '/api/habits') {
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
        return http.Response('{}', 404);
      });
}

// ── Reminders server ──────────────────────────────────────────────

class _ReminderServer {
  List<Map<String, dynamic>> rows;
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
          rows = TabsBackend.decodeProfileList(body['reminders']);
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      });

  List<Map<String, dynamic>> get lastPushedRows =>
      TabsBackend.decodeProfileList(pushes.last['reminders']);
}

Map<String, dynamic> _intervalRow({
  required int id,
  required String title,
  required int intervalHours,
  required int intervalMinutes,
}) =>
    {
      'id': id,
      'title': title,
      'type': 'INTERVAL',
      'fixedHour': 12,
      'fixedMinute': 0,
      'intervalHours': intervalHours,
      'intervalMinutes': intervalMinutes,
      'startHour': 8,
      'startMinute': 0,
      'endHour': 21,
      'endMinute': 0,
      'isEnabled': true,
      'daysOfWeekConfig': '',
    };

// ── Medications blocking backend ──────────────────────────────────

class _BlockingMedsBackend extends TabsBackend {
  _BlockingMedsBackend({required this.profile})
      : super(sessionStore: FakeSessionStore()..token = 'tok');

  Map<String, dynamic>? profile;
  final List<Map<String, dynamic>> pushes = [];
  Completer<void>? gate;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async => profile;

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    pushes.add(fields);
    final g = gate;
    if (g != null) await g.future;
    return true;
  }
}

Map<String, dynamic> _medRow(String id, String name) => {
      'id': id,
      'name': name,
      'startDate': 'Sep 1, 2026',
      'endDate': 'Present',
      'isPresent': true,
      'dose': '10mg',
      'frequency': 'Daily',
      'updatedAt': 1000,
      'isDeleted': false,
    };

void main() {
  group('r48d habits: fetchHabitsOrNull distinguishes failure', () {
    test('500 → null; fetchHabits still flattens to []', () async {
      final backend = _backendWith(
        MockClient((_) async => http.Response('{"error":"x"}', 500)),
        token: 'tok',
      );
      expect(await backend.fetchHabitsOrNull(), isNull);
      expect(await backend.fetchHabits(), isEmpty);
    });

    test('missing token → null', () async {
      final backend = _backendWith(
        MockClient((_) async =>
            http.Response(jsonEncode({'habits': []}), 200)),
      );
      expect(await backend.fetchHabitsOrNull(), isNull);
    });

    test('malformed body / missing habits key → null', () async {
      final noKey = _backendWith(
        MockClient((_) async => http.Response('{}', 200)),
        token: 'tok',
      );
      expect(await noKey.fetchHabitsOrNull(), isNull);
      final notJson = _backendWith(
        MockClient((_) async => http.Response('ok', 200)),
        token: 'tok',
      );
      expect(await notJson.fetchHabitsOrNull(), isNull);
    });

    test('success → parsed list; empty list is a REAL empty (non-null)',
        () async {
      final backend = _backendWith(
        MockClient((_) async => http.Response(
              jsonEncode({
                'habits': [
                  {'id': 'h1', 'title': 'Drink water', 'logs': <String>[]},
                ],
              }),
              200,
            )),
        token: 'tok',
      );
      final habits = await backend.fetchHabitsOrNull();
      expect(habits, isNotNull);
      expect(habits!.single.title, 'Drink water');

      final empty = _backendWith(
        MockClient((_) async =>
            http.Response(jsonEncode({'habits': []}), 200)),
        token: 'tok',
      );
      expect(await empty.fetchHabitsOrNull(), isNotNull);
      expect(await empty.fetchHabitsOrNull(), isEmpty);
    });
  });

  group('r48d habits UI', () {
    testWidgets(
        'post-create refresh failure: error shown, list PRESERVED (not blanked)',
        (tester) async {
      final server = _HabitServer([
        {'id': 'h1', 'title': 'Drink water', 'logs': <String>[]},
      ]);
      await _pump(
          tester,
          HabitsScreen(
              backend: _backendWith(server.client(), token: 'tok')));
      expect(find.text('Drink water'), findsOneWidget);

      // The create will succeed; every GET after it fails.
      server.failGets = true;
      await tester.enterText(find.byType(TextField), 'Meditate');
      await tester.tap(find.byIcon(Icons.add_circle));
      await tester.pumpAndSettle();

      expect(
          find.text(
              'Saved, but the habit list could not be refreshed. Check your connection and try again.'),
          findsOneWidget);
      // The pre-write list is still on screen — NOT the empty state.
      expect(find.text('Drink water'), findsOneWidget);
      expect(find.text('No habits yet'), findsNothing);
    });

    testWidgets('card renders the target time under the title (native)',
        (tester) async {
      final server = _HabitServer([
        {
          'id': 'h1',
          'title': 'Drink water',
          'target_time': 'Morning',
          'logs': <String>[],
        },
        {'id': 'h2', 'title': 'Walk', 'logs': <String>[]},
      ]);
      await _pump(
          tester,
          HabitsScreen(
              backend: _backendWith(server.client(), token: 'tok')));
      expect(find.text('Morning'), findsOneWidget);
      // Missing target_time falls back to the DTO default.
      expect(find.text('Anytime'), findsOneWidget);
    });
  });

  group('r48d reminders: tolerant isEnabled parsing', () {
    test('reminder row: string/num bools parse, absent defaults enabled',
        () {
      bool enabled(dynamic v) =>
          ReminderModel.fromJson({'title': 'x', 'isEnabled': v}).isEnabled;
      expect(enabled(true), isTrue);
      expect(enabled(false), isFalse);
      expect(enabled('false'), isFalse);
      expect(enabled('False'), isFalse);
      expect(enabled('0'), isFalse);
      expect(enabled(0), isFalse);
      expect(enabled('true'), isTrue);
      expect(enabled(1), isTrue);
      expect(ReminderModel.fromJson({'title': 'x'}).isEnabled, isTrue);
    });

    test('day row: string/num bools parse, absent defaults disabled', () {
      bool enabled(dynamic v) => DayTimeConfig.fromJson(
              {'dayName': 'Mon', 'isEnabled': v}).isEnabled;
      expect(enabled(true), isTrue);
      expect(enabled('true'), isTrue);
      expect(enabled(1), isTrue);
      expect(enabled(false), isFalse);
      expect(enabled('false'), isFalse);
      expect(enabled(0), isFalse);
      expect(DayTimeConfig.fromJson({'dayName': 'Mon'}).isEnabled, isFalse);
    });

    test('summary uses enabled days parsed from string bools', () {
      final r = ReminderModel.fromJson({
        'title': 'Gym',
        'type': 'FIXED',
        'fixedHour': 9,
        'fixedMinute': 0,
        'isEnabled': 'true',
        'daysOfWeekConfig': jsonEncode([
          {'dayName': 'Mon', 'isEnabled': 'true', 'hour': 7, 'minute': 30},
          {'dayName': 'Tue', 'isEnabled': 'false', 'hour': 7, 'minute': 30},
        ]),
      });
      expect(r.isEnabled, isTrue);
      expect(reminderScheduleSummary(r), 'Mon 7:30 AM');
    });
  });

  group('r48d reminders UI: untouched interval is preserved on edit', () {
    Widget screen(_ReminderServer server) => RemindersScreen(
          backend: _backendWith(server.client(), token: 'tok'),
          notificationService: FakeReminderNotificationService(),
        );

    Future<void> editTitleOnly(
        WidgetTester tester, String from, String to) async {
      await tester.tap(find.text(from));
      await tester.pumpAndSettle();
      expect(find.text('Edit Reminder'), findsOneWidget);
      await tester.enterText(find.byType(TextField), to);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('zero interval (0h 0m) survives a title-only edit',
        (tester) async {
      final server = _ReminderServer([
        _intervalRow(
            id: 11, title: 'Zero interval', intervalHours: 0, intervalMinutes: 0),
      ]);
      await _pump(tester, screen(server));
      await editTitleOnly(tester, 'Zero interval', 'Zero renamed');

      final row = server.lastPushedRows.single;
      expect(row['title'], 'Zero renamed');
      expect(row['intervalHours'], 0);
      expect(row['intervalMinutes'], 0);
    });

    testWidgets('mixed interval (1h 30m) survives a title-only edit',
        (tester) async {
      final server = _ReminderServer([
        _intervalRow(
            id: 12, title: 'Mixed interval', intervalHours: 1, intervalMinutes: 30),
      ]);
      await _pump(tester, screen(server));
      await editTitleOnly(tester, 'Mixed interval', 'Mixed renamed');

      final row = server.lastPushedRows.single;
      expect(row['title'], 'Mixed renamed');
      expect(row['intervalHours'], 1);
      expect(row['intervalMinutes'], 30);
    });
  });

  group('r48d medications: writes are serialized', () {
    testWidgets(
        'a second archive during a pending push is dropped; controls disabled',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final backend = _BlockingMedsBackend(profile: {
        'medications': jsonEncode([
          _medRow('a', 'Ivabradine'),
          _medRow('b', 'Pyridostigmine'),
        ]),
      });
      final gate = Completer<void>();
      backend.gate = gate;
      await _pump(tester, MedicationsScreen(backend: backend));
      expect(find.text('2 Active Medication(s)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('archive_med_at_0')));
      await tester.pump();
      await tester.pump();
      expect(backend.pushes, hasLength(1));

      // While the push is pending the other med's archive button
      // is disabled and its card cannot open the edit dialog.
      final archiveB = tester.widget<IconButton>(
          find.byKey(const ValueKey('archive_med_at_1')));
      expect(archiveB.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('archive_med_at_1')));
      await tester.pump();
      await tester.tap(find.text('Pyridostigmine'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Medication'), findsNothing);
      expect(backend.pushes, hasLength(1));

      gate.complete();
      backend.gate = null;
      await tester.pumpAndSettle();
      expect(backend.pushes, hasLength(1));
      expect(find.text('1 Active Medication(s)'), findsOneWidget);

      // The serializer released: archiving the second med pushes.
      await tester.tap(find.byKey(const ValueKey('archive_med_at_1')));
      await tester.pumpAndSettle();
      expect(backend.pushes, hasLength(2));
      expect(find.text('0 Active Medication(s)'), findsOneWidget);
      expect(find.text('Archived Medications (2)'), findsOneWidget);
    });
  });
}
