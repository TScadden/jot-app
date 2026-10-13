import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart';
import 'package:tabs_lab/src/features/tools/lists_screen.dart';
import 'package:tabs_lab/src/features/tools/notes_screen.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';

import 'test_helpers.dart';

/// Builds a TabsBackend against a mock HTTP client with an optional token.
TabsBackend _backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

String _dayStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

Future<void> _pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  // ── Habits ───────────────────────────────────────────────────────────

  group('habits: fetchHabits parsing', () {
    test('parses id/title/logs from a realistic payload', () async {
      final backend = _backendWith(
        MockClient((request) async {
          expect(request.url.toString(),
              'https://api.jottracker.com/api/habits');
          return http.Response(
            jsonEncode({
              'habits': [
                {
                  'id': 'h1',
                  'title': 'Drink water',
                  'logs': ['2026-10-10', '2026-10-11'],
                },
                {'id': 'h2', 'title': 'Walk', 'logs': []},
              ],
            }),
            200,
          );
        }),
        token: 'tok',
      );
      final habits = await backend.fetchHabits();
      expect(habits, hasLength(2));
      expect(habits[0].id, 'h1');
      expect(habits[0].title, 'Drink water');
      expect(habits[0].logs, ['2026-10-10', '2026-10-11']);
      expect(habits[1].logs, isEmpty);
    });

    test('401 → empty list (honest empty, never a crash)', () async {
      final backend = _backendWith(
        MockClient(
            (_) async => http.Response('{"error":"bad token"}', 401)),
        token: 'tok',
      );
      expect(await backend.fetchHabits(), isEmpty);
    });

    test('missing token → empty list (never a crash)', () async {
      final backend = _backendWith(
        MockClient((_) async => http.Response('{}', 200)),
      );
      expect(await backend.fetchHabits(), isEmpty);
    });

    test('malformed habit rows are skipped, list survives', () async {
      final backend = _backendWith(
        MockClient((_) async => http.Response(
              jsonEncode({
                'habits': [
                  {'id': 'h1', 'title': 'OK', 'logs': []},
                  'not-a-map',
                ],
              }),
              200,
            )),
        token: 'tok',
      );
      final habits = await backend.fetchHabits();
      expect(habits.map((h) => h.id), ['h1']);
    });
  });

  group('habits: pure streak/date helpers (mirror native)', () {
    test('isHabitCheckedToday honors only today', () {
      final today = _dayStr(_today());
      final yesterday = _dayStr(_today().subtract(const Duration(days: 1)));
      expect(
          isHabitCheckedToday(
              HabitDto(id: 'a', title: 'x', logs: [today])),
          isTrue);
      expect(
          isHabitCheckedToday(
              HabitDto(id: 'a', title: 'x', logs: [yesterday])),
          isFalse);
      expect(
          isHabitCheckedToday(
              const HabitDto(id: 'a', title: 'x', logs: [])),
          isFalse);
    });

    test('habitStreak counts consecutive days ending today', () {
      final t = _today();
      final logs = [0, 1, 2]
          .map((b) => _dayStr(t.subtract(Duration(days: b))))
          .toList();
      expect(habitStreak(logs), 3);
    });

    test('habitStreak stays alive when ending yesterday', () {
      final t = _today();
      final logs = [1, 2].map((b) => _dayStr(t.subtract(Duration(days: b)))).toList();
      expect(habitStreak(logs), 2);
    });

    test('habitStreak breaks on a gap or stale log', () {
      final t = _today();
      expect(
          habitStreak([
            _dayStr(t),
            _dayStr(t.subtract(const Duration(days: 2)))
          ]),
          1);
      expect(habitStreak([_dayStr(t.subtract(const Duration(days: 5)))]), 0);
      expect(habitStreak([]), 0);
      expect(habitStreak(['not-a-date']), 0);
    });

    test('habitDayMarks: 7 marks, last is today, flags match logs', () {
      final t = _today();
      final logs = [_dayStr(t), _dayStr(t.subtract(const Duration(days: 3)))];
      final marks = habitDayMarks(logs);
      expect(marks, hasLength(7));
      expect(marks.last.isToday, isTrue);
      expect(marks.where((m) => m.isToday), hasLength(1));
      expect(marks.last.completed, isTrue);
      expect(marks[3].completed, isTrue);
      expect(marks[0].completed, isFalse);
      expect(marks.every((m) => m.dayLabel.length == 1), isTrue);
    });

    test('overallHabitStreak uses the intersection of log sets', () {
      final t = _today();
      final shared = [0, 1]
          .map((b) => _dayStr(t.subtract(Duration(days: b))))
          .toList();
      final habits = [
        HabitDto(id: 'a', title: 'A', logs: [...shared, _dayStr(t.subtract(const Duration(days: 4)))]),
        HabitDto(id: 'b', title: 'B', logs: shared),
      ];
      expect(overallHabitStreak(habits), 2);
      expect(overallHabitStreak([]), 0);
    });
  });

  group('habits: widget states', () {
    testWidgets('renders habits with DONE pill and week dots', (tester) async {
      final today = _dayStr(_today());
      final backend = _backendWith(
        MockClient((_) async => http.Response(
              jsonEncode({
                'habits': [
                  {'id': 'h1', 'title': 'Drink water', 'logs': [today]},
                  {'id': 'h2', 'title': 'Walk', 'logs': []},
                ],
              }),
              200,
            )),
        token: 'tok',
      );
      await _pumpScreen(tester, HabitsScreen(backend: backend));
      expect(find.text('Daily Habits'), findsOneWidget);
      expect(find.text('Drink water'), findsOneWidget);
      expect(find.text('Walk'), findsOneWidget);
      expect(find.text('1/2 DONE'), findsOneWidget);
    });

    testWidgets('empty payload → honest empty state', (tester) async {
      final backend = _backendWith(
        MockClient((_) async =>
            http.Response(jsonEncode({'habits': []}), 200)),
        token: 'tok',
      );
      await _pumpScreen(tester, HabitsScreen(backend: backend));
      expect(find.text('No habits yet'), findsOneWidget);
      expect(find.text('1/1 DONE'), findsNothing);
    });

    testWidgets('401 → honest empty state, no crash', (tester) async {
      final backend = _backendWith(
        MockClient(
            (_) async => http.Response('{"error":"bad token"}', 401)),
        token: 'tok',
      );
      await _pumpScreen(tester, HabitsScreen(backend: backend));
      expect(find.text('No habits yet'), findsOneWidget);
    });

    testWidgets('missing token → honest empty state, no crash',
        (tester) async {
      final backend = _backendWith(
        MockClient((_) async => http.Response('{}', 200)),
      );
      await _pumpScreen(tester, HabitsScreen(backend: backend));
      expect(find.text('No habits yet'), findsOneWidget);
    });
  });

  // ── Reminders ────────────────────────────────────────────────────────

  group('reminders: model + schedule summary', () {
    test('fromJson applies native defaults', () {
      final r = ReminderModel.fromJson({'title': 'Meds'});
      expect(r.type, 'FIXED');
      expect(r.fixedHour, 12);
      expect(r.fixedMinute, 0);
      expect(r.intervalHours, 2);
      expect(r.isEnabled, isTrue);
      expect(reminderScheduleSummary(r), '12:00 PM');
    });

    test('FIXED summary uses the fixed time', () {
      final r = ReminderModel.fromJson({
        'title': 'Meds',
        'type': 'FIXED',
        'fixedHour': 9,
        'fixedMinute': 5,
      });
      expect(reminderScheduleSummary(r), '9:05 AM');
    });

    test('FIXED summary joins enabled per-day times', () {
      final r = ReminderModel.fromJson({
        'title': 'Gym',
        'type': 'FIXED',
        'daysOfWeekConfig': jsonEncode([
          {'dayName': 'Mon', 'isEnabled': true, 'hour': 9, 'minute': 0},
          {'dayName': 'Tue', 'isEnabled': false, 'hour': 9, 'minute': 0},
          {'dayName': 'Wed', 'isEnabled': true, 'hour': 17, 'minute': 30},
        ]),
      });
      expect(reminderScheduleSummary(r), 'Mon 9:00 AM, Wed 5:30 PM');
    });

    test('INTERVAL summary: hours and minutes variants', () {
      final hours = ReminderModel.fromJson({
        'title': 'Water',
        'type': 'INTERVAL',
        'intervalHours': 2,
        'intervalMinutes': 0,
        'startHour': 8,
        'startMinute': 0,
        'endHour': 21,
        'endMinute': 0,
      });
      expect(reminderScheduleSummary(hours),
          'Every 2h  •  8:00 AM to 9:00 PM');
      final minutes = ReminderModel.fromJson({
        'title': 'Stretch',
        'type': 'INTERVAL',
        'intervalHours': 0,
        'intervalMinutes': 30,
      });
      expect(reminderScheduleSummary(minutes),
          'Every 30m  •  8:00 AM to 9:00 PM');
    });

    test('formatTime12h handles midnight/noon edges', () {
      expect(formatTime12h(0, 0), '12:00 AM');
      expect(formatTime12h(12, 0), '12:00 PM');
      expect(formatTime12h(23, 59), '11:59 PM');
    });

    test('decodeProfileList tolerates blank/malformed blobs', () {
      expect(TabsBackend.decodeProfileList(null), isEmpty);
      expect(TabsBackend.decodeProfileList('  '), isEmpty);
      expect(TabsBackend.decodeProfileList('nope{'), isEmpty);
    });
  });

  group('reminders: widget states', () {
    MockClient remindersClient() => MockClient((_) async => http.Response(
          jsonEncode({
            'profile': {
              'reminders': jsonEncode([
                {
                  'title': 'Take meds',
                  'type': 'FIXED',
                  'fixedHour': 9,
                  'fixedMinute': 0,
                  'isEnabled': true,
                },
                {
                  'title': 'Drink water',
                  'type': 'INTERVAL',
                  'intervalHours': 2,
                  'intervalMinutes': 0,
                  'startHour': 8,
                  'startMinute': 0,
                  'endHour': 21,
                  'endMinute': 0,
                  'isEnabled': false,
                },
              ]),
            },
          }),
          200,
        ));

    testWidgets('renders titles, summaries, and enabled switches',
        (tester) async {
      await _pumpScreen(
          tester,
          RemindersScreen(
              backend: _backendWith(remindersClient(), token: 'tok')));
      expect(find.text('Take meds'), findsOneWidget);
      expect(find.text('9:00 AM'), findsOneWidget);
      expect(find.text('Drink water'), findsOneWidget);
      expect(find.text('Every 2h  •  8:00 AM to 9:00 PM'),
          findsOneWidget);
      // Round 47: the read-only ON/OFF pill became a real Switch.
      final switches =
          tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches, hasLength(2));
      expect(switches[0].value, isTrue);
      expect(switches[1].value, isFalse);
      expect(find.text('New Reminder'), findsOneWidget);
    });

    testWidgets('empty blob → honest empty state', (tester) async {
      final backend = _backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({'profile': {'reminders': '[]'}}), 200)),
        token: 'tok',
      );
      await _pumpScreen(tester, RemindersScreen(backend: backend));
      expect(find.text('No reminders yet'), findsOneWidget);
    });

    testWidgets('401 → failure state, no crash', (tester) async {
      final backend = _backendWith(
        MockClient(
            (_) async => http.Response('{"error":"bad token"}', 401)),
        token: 'tok',
      );
      await _pumpScreen(tester, RemindersScreen(backend: backend));
      expect(find.text('Couldn\'t load reminders'), findsOneWidget);
    });

    testWidgets('missing token → failure state, no crash',
        (tester) async {
      final backend = _backendWith(
        MockClient((_) async => http.Response('{}', 200)),
      );
      await _pumpScreen(tester, RemindersScreen(backend: backend));
      expect(find.text('Couldn\'t load reminders'), findsOneWidget);
    });
  });

  // ── Lists ────────────────────────────────────────────────────────────

  group('lists: model + pseudo-list filter', () {
    test('fromJson keeps name and string items', () {
      final l = UserListModel.fromJson({
        'name': 'MCAS foods',
        'items': ['Chicken', 'Rice', 42, null, '  '],
      });
      expect(l.name, 'MCAS foods');
      // 42 coerces to "42"; nulls and blank strings are dropped.
      expect(l.items, ['Chicken', 'Rice', '42']);
    });

    test('visibleUserLists drops __user_notes__', () {
      final lists = [
        const UserListModel(name: '__user_notes__', items: ['x']),
        const UserListModel(name: 'Groceries', items: []),
      ];
      final visible = visibleUserLists(lists);
      expect(visible.map((l) => l.name), ['Groceries']);
    });
  });

  group('lists: widget states', () {
    MockClient listsClient() => MockClient((_) async => http.Response(
          jsonEncode({
            'profile': {
              'userLists': jsonEncode([
                {
                  'name': 'Groceries',
                  'items': ['Eggs', 'Tortillas'],
                },
                {
                  'name': '__user_notes__',
                  'items': ['should be hidden'],
                },
                {'name': 'Empty list', 'items': []},
              ]),
            },
          }),
          200,
        ));

    testWidgets('renders lists with items; pseudo-list hidden',
        (tester) async {
      await _pumpScreen(tester,
          ListsScreen(backend: _backendWith(listsClient(), token: 'tok')));
      expect(find.text('Groceries'), findsOneWidget);
      // First list auto-expands (native auto-select-first).
      expect(find.text('Eggs'), findsOneWidget);
      expect(find.text('Tortillas'), findsOneWidget);
      expect(find.text('should be hidden'), findsNothing);
      expect(find.text('Empty list'), findsOneWidget);
    });

    testWidgets('expanding a collapsed list shows its rows',
        (tester) async {
      await _pumpScreen(tester,
          ListsScreen(backend: _backendWith(listsClient(), token: 'tok')));
      expect(find.text('Empty list'), findsOneWidget);
      await tester.tap(find.text('Empty list'));
      await tester.pumpAndSettle();
      expect(find.text('This list is empty'), findsOneWidget);
    });

    testWidgets('empty blob → honest empty state', (tester) async {
      final backend = _backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({'profile': {'userLists': '[]'}}), 200)),
        token: 'tok',
      );
      await _pumpScreen(tester, ListsScreen(backend: backend));
      expect(find.text('No lists yet'), findsOneWidget);
    });

    testWidgets('401 → failure state, no crash', (tester) async {
      final backend = _backendWith(
        MockClient(
            (_) async => http.Response('{"error":"bad token"}', 401)),
        token: 'tok',
      );
      await _pumpScreen(tester, ListsScreen(backend: backend));
      expect(find.text('Couldn\'t load lists'), findsOneWidget);
    });
  });

  // ── Notes (round 18b: real source is __user_notes__) ─────────────────────

  group('notes: parsing from __user_notes__', () {
    List<Map<String, dynamic>> notesBlob() =>
        TabsBackend.decodeProfileList(jsonEncode([
          {
            'name': '__user_notes__',
            'items': [
              'Groceries_||_eggs, oats_||_1720000000000',
              'PT_||_floor routine_||_1720100000000',
            ],
          },
          {'name': 'Shopping', 'items': ['not a note']},
        ]));

    test('parses title/body/timestamp, newest first', () {
      final notes = parseUserNotes(notesBlob());
      expect(notes, hasLength(2));
      expect(notes[0].title, 'PT');
      expect(notes[0].text, 'floor routine');
      expect(notes[0].timestampMs, 1720100000000);
      expect(notes[1].title, 'Groceries');
    });

    test('ignores lists that are not __user_notes__', () {
      final notes = parseUserNotes(notesBlob());
      expect(notes.any((n) => n.text == 'not a note'), isFalse);
    });

    test('null/blank/malformed → empty, never throws', () {
      expect(parseUserNotes([]), isEmpty);
      expect(parseUserNotes(TabsBackend.decodeProfileList(null)), isEmpty);
      expect(
          parseUserNotes(TabsBackend.decodeProfileList('garbage')), isEmpty);
    });

    test('formatNoteDate renders native pattern', () {
      final d = DateTime(2026, 10, 11, 14, 5);
      expect(formatNoteDate(d.millisecondsSinceEpoch),
          'Oct 11, 2026 2:05 PM');
      final midnight = DateTime(2026, 1, 2, 0, 30);
      expect(formatNoteDate(midnight.millisecondsSinceEpoch),
          'Jan 2, 2026 12:30 AM');
    });
  });

  group('notes: widget states', () {
    MockClient notesClient() => MockClient((_) async => http.Response(
          jsonEncode({
            'profile': {
              'userLists': jsonEncode([
                {
                  'name': '__user_notes__',
                  'items': [
                    'Evening note_||_Heart rate spike after shower_||_1720000000000',
                  ],
                },
              ]),
            },
          }),
          200,
        ));

    testWidgets('renders note title, text, and date', (tester) async {
      await _pumpScreen(tester,
          NotesScreen(backend: _backendWith(notesClient(), token: 'tok')));
      expect(find.text('Evening note'), findsOneWidget);
      expect(find.text('Heart rate spike after shower'), findsOneWidget);
      expect(
          find.text(formatNoteDate(1720000000000)), findsOneWidget);
    });

    testWidgets('log entries are NOT shown as notes', (tester) async {
      // A profile with entries but no __user_notes__ list → honest empty.
      final backend = _backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({
              'profile': {'userLists': '[]'},
              'entries': [
                {'id': 1, 'body': 'This is a log, not a note'}
              ],
            }),
            200)),
        token: 'tok',
      );
      await _pumpScreen(tester, NotesScreen(backend: backend));
      expect(find.text('This is a log, not a note'), findsNothing);
      expect(find.text('No notes yet'), findsOneWidget);
    });

    testWidgets('empty userLists → honest empty state', (tester) async {
      final backend = _backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({
              'profile': {'userLists': '[]'}
            }),
            200)),
        token: 'tok',
      );
      await _pumpScreen(tester, NotesScreen(backend: backend));
      expect(find.text('No notes yet'), findsOneWidget);
    });

    testWidgets('401 → failure state, no crash', (tester) async {
      final backend = _backendWith(
        MockClient(
            (_) async => http.Response('{"error":"bad token"}', 401)),
        token: 'tok',
      );
      await _pumpScreen(tester, NotesScreen(backend: backend));
      expect(find.text('Couldn\'t load notes'), findsOneWidget);
    });

    testWidgets('missing token → failure state, no crash',
        (tester) async {
      final backend = _backendWith(
        MockClient((_) async => http.Response('{}', 200)),
      );
      await _pumpScreen(tester, NotesScreen(backend: backend));
      expect(find.text('Couldn\'t load notes'), findsOneWidget);
    });
  });
}
