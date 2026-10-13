import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/csv_file_picker.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/blood_pressure_tool_screen.dart';
import 'package:tabs_lab/src/features/tools/lists_screen.dart';
import 'package:tabs_lab/src/features/tools/notes_screen.dart';

import 'test_helpers.dart';

/// In-memory fake of the profile sync endpoints: GET /api/sync/pull
/// serves the stored blobs; POST /api/sync/profile records the push
/// and (unless [failPosts]) applies it, like the real server.
class FakeProfileServer {
  String? userLists;
  String? bpLogs;
  bool failPosts = false;
  final List<Map<String, dynamic>> posts = [];

  http.Client get client => MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'profile': {
                if (userLists != null) 'userLists': userLists,
                if (bpLogs != null) 'manualBloodPressureLogs': bpLogs,
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/profile' &&
            request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          posts.add(body);
          if (failPosts) return http.Response('boom', 500);
          if (body['userLists'] is String) {
            userLists = body['userLists'] as String;
          }
          if (body['manualBloodPressureLogs'] is String) {
            bpLogs = body['manualBloodPressureLogs'] as String;
          }
          return http.Response(jsonEncode({'saved': true}), 200);
        }
        return http.Response('not found', 404);
      });

  TabsBackend backend() {
    final store = FakeSessionStore()..token = 'test-token';
    return TabsBackend(client: client, sessionStore: store);
  }

  List<dynamic> userListsRows() =>
      jsonDecode(userLists ?? '[]') as List<dynamic>;
  List<dynamic> bpRows() => jsonDecode(bpLogs ?? '[]') as List<dynamic>;
}

class FakeCsvPicker extends CsvFilePicker {
  final String? text;
  FakeCsvPicker(this.text);
  @override
  Future<String?> pickCsvText() async => text;
}

/// HealthConnectService whose channel answers "not connected".
HealthConnectService disconnectedHc() {
  const channel = MethodChannel(HealthConnectService.channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'isAvailable':
        return false;
      case 'getGrantedPermissions':
        return <String>[];
      case 'readBloodPressure':
        return <Map<String, Object>>[];
    }
    return null;
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  return HealthConnectService(channel: channel);
}

Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  // ── Lists: pure splices ──────────────────────────────────────────
  group('lists: raw decode + splices', () {
    List<dynamic> baseRows() => [
          {
            'name': '__user_notes__',
            'items': ['T_||_b_||_111'],
          },
          {
            'id': 7,
            'name': 'Groceries',
            'items': ['eggs'],
            'extra': 'keepme',
          },
          {
            'name': 'Chores',
            'items': <String>[],
          },
        ];

    test('decodeUserListsRaw tolerates string/double-encoded/list/garbage',
        () {
      final rows = [
        {'name': 'A', 'items': []}
      ];
      expect(decodeUserListsRaw(jsonEncode(rows)), hasLength(1));
      expect(decodeUserListsRaw(jsonEncode(jsonEncode(rows))), hasLength(1));
      expect(decodeUserListsRaw(rows), hasLength(1));
      expect(decodeUserListsRaw('not json'), isEmpty);
      expect(decodeUserListsRaw(null), isEmpty);
    });

    test('visibleListsFromRaw drops only the notes pseudo-list', () {
      final visible = visibleListsFromRaw(baseRows());
      expect(visible.map((l) => l.name), ['Groceries', 'Chores']);
      expect(visible.first.items, ['eggs']);
    });

    test('create appends a list and preserves every other row verbatim',
        () {
      final next = userListsWithNewList(baseRows(), '  Travel  ')!;
      expect(next, hasLength(4));
      expect(next[0], baseRows()[0]); // notes row untouched
      expect(next[3], {
        'name': 'Travel',
        'items': <String>[],
      });
      expect(userListsWithNewList(baseRows(), '   '), isNull);
    });

    test('add item targets the visible list, keeps unknown row keys', () {
      final next =
          userListsWithAddedItem(baseRows(), 0, 'Groceries', 'milk')!;
      final groceries = next[1] as Map;
      expect(groceries['items'], ['eggs', 'milk']);
      expect(groceries['id'], 7);
      expect(groceries['extra'], 'keepme');
      // Notes row and Chores untouched.
      expect((next[0] as Map)['items'], ['T_||_b_||_111']);
      expect((next[2] as Map)['items'], isEmpty);
    });

    test('add item resolves by name when the fresh blob reordered lists',
        () {
      final reordered = [baseRows()[2], baseRows()[0], baseRows()[1]];
      // Rendered index was 0 for Groceries; in fresh rows index 0 is
      // Chores — the name check must redirect to Groceries.
      final next =
          userListsWithAddedItem(reordered, 0, 'Groceries', 'milk')!;
      expect(((next[2] as Map)['items'] as List), ['eggs', 'milk']);
      expect(((next[0] as Map)['items'] as List), isEmpty);
    });

    test('edit item: exact index, unique-match fallback, ambiguity refused',
        () {
      final rows = baseRows();
      (rows[1] as Map)['items'] = ['eggs', 'milk', 'eggs'];
      final edited =
          userListsWithEditedItem(rows, 0, 'Groceries', 1, 'milk', 'oat milk')!;
      expect(((edited[1] as Map)['items'] as List),
          ['eggs', 'oat milk', 'eggs']);
      // Index shifted: item now unique-matches elsewhere.
      final shifted = baseRows();
      (shifted[1] as Map)['items'] = ['bread', 'eggs'];
      final edited2 = userListsWithEditedItem(
          shifted, 0, 'Groceries', 0, 'eggs', 'egg whites')!;
      expect(((edited2[1] as Map)['items'] as List),
          ['bread', 'egg whites']);
      // Duplicate text with a stale index is ambiguous → refuse.
      expect(
          userListsWithEditedItem(rows, 0, 'Groceries', 5, 'eggs', 'x'),
          isNull);
      // Blank replacement refused (native parity).
      expect(
          userListsWithEditedItem(rows, 0, 'Groceries', 0, 'eggs', '  '),
          isNull);
    });

    test('delete item and delete list splices', () {
      final rows = baseRows();
      (rows[1] as Map)['items'] = ['eggs', 'milk'];
      final without =
          userListsWithoutItem(rows, 0, 'Groceries', 0, 'eggs')!;
      expect(((without[1] as Map)['items'] as List), ['milk']);
      final noList = userListsWithoutList(baseRows(), 1, 'Chores')!;
      expect(noList.map((r) => (r as Map)['name']),
          ['__user_notes__', 'Groceries']);
      expect(userListsWithoutList(baseRows(), 9, 'Nope'), isNull);
    });
  });

  // ── Lists: widget flows ──────────────────────────────────────────
  group('lists: widget write flows', () {
    FakeProfileServer serverWithLists() {
      final server = FakeProfileServer();
      server.userLists = jsonEncode([
        {
          'name': '__user_notes__',
          'items': ['Hidden_||_note_||_111'],
        },
        {
          'name': 'Groceries',
          'items': ['eggs'],
        },
      ]);
      return server;
    }

    testWidgets('renders lists, hides notes pseudo-list, adds an item',
        (tester) async {
      final server = serverWithLists();
      await pumpScreen(tester, ListsScreen(backend: server.backend()));
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Hidden'), findsNothing);
      expect(find.text('eggs'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'milk');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('milk'), findsOneWidget);
      final rows = server.userListsRows();
      expect(rows, hasLength(2));
      expect((rows[1] as Map)['items'], ['eggs', 'milk']);
      // The notes pseudo-list rode the push untouched.
      expect((rows[0] as Map)['items'], ['Hidden_||_note_||_111']);
      expect(server.posts.last.keys, ['userLists']);
    });

    testWidgets('create list from the empty state', (tester) async {
      final server = FakeProfileServer()..userLists = '[]';
      await pumpScreen(tester, ListsScreen(backend: server.backend()));
      expect(find.text('No lists yet'), findsOneWidget);
      await tester.tap(find.text('New List'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Travel');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Travel'), findsOneWidget);
      final rows = server.userListsRows();
      expect(rows, hasLength(1));
      expect((rows[0] as Map)['name'], 'Travel');
    });

    testWidgets('edit and delete an item, then delete the list',
        (tester) async {
      final server = serverWithLists();
      await pumpScreen(tester, ListsScreen(backend: server.backend()));

      // Edit: tap the row, change the text, save with the check.
      await tester.tap(find.text('eggs'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'egg whites');
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      var rows = server.userListsRows();
      expect((rows[1] as Map)['items'], ['egg whites']);
      expect(find.text('egg whites'), findsOneWidget);

      // Delete the item via its ✕.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      rows = server.userListsRows();
      expect((rows[1] as Map)['items'], isEmpty);

      // Delete the list via the header trash + confirm.
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      rows = server.userListsRows();
      expect(rows, hasLength(1));
      expect((rows[0] as Map)['name'], '__user_notes__');
      expect(find.text('No lists yet'), findsOneWidget);
    });

    testWidgets('failed save shows an error and keeps server state',
        (tester) async {
      final server = serverWithLists()..failPosts = true;
      await pumpScreen(tester, ListsScreen(backend: server.backend()));
      await tester.enterText(find.byType(TextField), 'milk');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Could not save that change. Check your connection and try again.'),
          findsOneWidget);
      // Server blob unchanged; the phantom item is gone after reload.
      final rows = server.userListsRows();
      expect((rows[1] as Map)['items'], ['eggs']);
      expect(find.text('milk'), findsNothing);
    });
  });

  // ── Notes: pure splices ──────────────────────────────────────────
  group('notes: parse + splices', () {
    test('encodeNoteItem mirrors native (blank title → New Note)', () {
      expect(encodeNoteItem('  ', ' body ', 42), 'New Note_||_body_||_42');
      expect(encodeNoteItem(' T ', 'b', 7), 'T_||_b_||_7');
    });

    test('title-only notes now parse (native can create them)', () {
      final notes = parseUserNotesFromRaw([
        {
          'name': '__user_notes__',
          'items': ['My Title_||__||_1760200000000'],
        },
      ]);
      expect(notes, hasLength(1));
      expect(notes.single.title, 'My Title');
      expect(notes.single.text, '');
    });

    test('parseUserNotesFromRaw keeps raw identity for splices', () {
      final notes = parseUserNotesFromRaw([
        {'name': 'Shopping', 'items': ['not a note']},
        {
          'name': '__user_notes__',
          'items': ['A_||_one_||_100', 'B_||_two_||_200'],
        },
      ]);
      expect(notes, hasLength(2));
      expect(notes.first.title, 'B'); // newest first
      expect(notes.first.listRowIndex, 1);
      expect(notes.first.itemIndex, 1);
      expect(notes.first.rawText, 'B_||_two_||_200');
    });

    test('parseNoteTimestamp tolerates int, numeric string, ISO', () {
      expect(parseNoteTimestamp('1760200000000'), 1760200000000);
      expect(
          parseNoteTimestamp('2026-10-11T00:00:00.000'),
          DateTime(2026, 10, 11).millisecondsSinceEpoch);
      expect(parseNoteTimestamp('junk'), isNull);
    });

    test('add creates the pseudo-list when missing, appends to first otherwise',
        () {
      final created = notesWithAddedNote([
        {'name': 'Shopping', 'items': ['milk']},
      ], 'T', 'body', 500)!;
      expect(created, hasLength(2));
      expect((created[1] as Map)['name'], '__user_notes__');
      expect((created[1] as Map)['items'], ['T_||_body_||_500']);
      expect((created[0] as Map)['items'], ['milk']);

      final appended = notesWithAddedNote([
        {
          'name': '__user_notes__',
          'items': ['A_||_one_||_100'],
        },
        {
          'name': '__user_notes__',
          'items': ['B_||_two_||_200'],
        },
      ], '', 'new body', 600)!;
      expect(((appended[0] as Map)['items'] as List),
          ['A_||_one_||_100', 'New Note_||_new body_||_600']);
      expect(((appended[1] as Map)['items'] as List), ['B_||_two_||_200']);
      expect(notesWithAddedNote(const [], ' ', ' ', 1), isNull);
    });

    test('edit preserves the original timestamp; delete removes exactly one',
        () {
      final rows = <dynamic>[
        {
          'name': '__user_notes__',
          'items': ['A_||_one_||_100', 'B_||_two_||_200'],
        },
      ];
      final noteB = parseUserNotesFromRaw(rows).first;
      final edited =
          notesWithEditedNote(rows, noteB, 'B2', 'two edited', 999)!;
      expect(((edited[0] as Map)['items'] as List),
          ['A_||_one_||_100', 'B2_||_two edited_||_200']);
      final deleted = notesWithoutNote(rows, noteB)!;
      expect(((deleted[0] as Map)['items'] as List), ['A_||_one_||_100']);
    });

    test('splice refuses when the stored note no longer matches', () {
      final rows = <dynamic>[
        {
          'name': '__user_notes__',
          'items': ['A_||_one_||_100'],
        },
      ];
      const stale = NoteEntry(
        title: 'Ghost',
        text: 'gone',
        timestampMs: 1,
        listRowIndex: 0,
        itemIndex: 0,
        rawText: 'Ghost_||_gone_||_1',
      );
      expect(notesWithoutNote(rows, stale), isNull);
      expect(notesWithEditedNote(rows, stale, 'x', 'y', 5), isNull);
    });
  });

  // ── Notes: widget flows ──────────────────────────────────────────
  group('notes: widget write flows', () {
    FakeProfileServer serverWithNotes() {
      final server = FakeProfileServer();
      server.userLists = jsonEncode([
        {
          'name': 'Groceries',
          'items': ['eggs'],
        },
        {
          'name': '__user_notes__',
          'items': ['PT_||_floor routine_||_1720100000000'],
        },
      ]);
      return server;
    }

    testWidgets('add, edit (timestamp preserved), and delete a note',
        (tester) async {
      final server = serverWithNotes();
      await pumpScreen(tester, NotesScreen(backend: server.backend()));
      expect(find.text('PT'), findsOneWidget);
      expect(find.text('floor routine'), findsOneWidget);

      // Add via the compose card.
      await tester.enterText(find.byType(TextField).at(0), 'Call mom');
      await tester.enterText(find.byType(TextField).at(1), 'sunday');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      var rows = server.userListsRows();
      var items = ((rows[1] as Map)['items'] as List).cast<String>();
      expect(items, hasLength(2));
      expect(items.last.startsWith('Call mom_||_sunday_||_'), isTrue);
      // The real list rode along untouched.
      expect((rows[0] as Map)['items'], ['eggs']);
      expect(find.text('Call mom'), findsOneWidget);

      // Edit the original note; its timestamp must survive.
      await tester.tap(find.text('floor routine'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Note'), findsOneWidget);
      await tester.enterText(
          find.byType(TextField).last, 'floor routine + stretches');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      rows = server.userListsRows();
      items = ((rows[1] as Map)['items'] as List).cast<String>();
      expect(items.first, 'PT_||_floor routine + stretches_||_1720100000000');

      // Delete the edited note via its ✕ (it is the second card —
      // the just-added "Call mom" note is newer and renders first).
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      rows = server.userListsRows();
      items = ((rows[1] as Map)['items'] as List).cast<String>();
      expect(items.any((i) => i.contains('floor routine')), isFalse);
    });

    testWidgets('failed note save shows an error, nothing is pushed',
        (tester) async {
      final server = serverWithNotes()..failPosts = true;
      await pumpScreen(tester, NotesScreen(backend: server.backend()));
      await tester.enterText(find.byType(TextField).at(1), 'unsaved');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Could not save that change. Check your connection and try again.'),
          findsOneWidget);
      final rows = server.userListsRows();
      expect(((rows[1] as Map)['items'] as List), hasLength(1));
      // No note card renders the unsaved text (the compose field
      // legitimately keeps the user's draft for a retry).
      expect(find.text('PT'), findsOneWidget);
    });
  });

  // ── Blood Pressure: pure helpers ─────────────────────────────────
  group('bp: blob helpers', () {
    test('decodeBpLogsRaw tolerates string/double-encoded/list/garbage',
        () {
      final rows = [
        {'systolic': 120, 'diastolic': 80, 'timeEpochMs': 5}
      ];
      expect(decodeBpLogsRaw(jsonEncode(rows)), hasLength(1));
      expect(decodeBpLogsRaw(jsonEncode(jsonEncode(rows))), hasLength(1));
      expect(decodeBpLogsRaw(rows), hasLength(1));
      expect(decodeBpLogsRaw('junk'), isEmpty);
      expect(decodeBpLogsRaw(null), isEmpty);
    });

    test('bpRowValues tolerates string numbers and ISO timestamps', () {
      final v = bpRowValues({
        'systolic': '121',
        'diastolic': '79',
        'timeEpochMs': '2026-10-11T08:30:00.000',
      })!;
      expect(v.systolic, 121);
      expect(v.timeEpochMs,
          DateTime(2026, 10, 11, 8, 30).millisecondsSinceEpoch);
      expect(bpRowValues({'systolic': 120}), isNull);
    });

    test('add prepends with the native id/source; duplicates refused', () {
      final rows = decodeBpLogsRaw(jsonEncode([
        {'systolic': 118, 'diastolic': 76, 'timeEpochMs': 1000},
      ]));
      final next = bpLogsWithAdded(rows, 122, 80, 2000)!;
      expect(next, hasLength(2));
      final added = next[0] as Map;
      expect(added['id'], 'manual_2000_122_80');
      expect(added['source'], 'MANUAL');
      expect(added['systolic'], 122);
      expect(bpLogsWithAdded(rows, 118, 76, 1000), isNull); // duplicate
      expect(bpLogsWithAdded(rows, 0, 80, 3000), isNull); // invalid
    });

    test('delete removes by computed id; absent id refused', () {
      final rows = decodeBpLogsRaw(jsonEncode([
        {'systolic': 118, 'diastolic': 76, 'timeEpochMs': 1000},
        {'systolic': 122, 'diastolic': 80, 'timeEpochMs': 2000},
      ]));
      final next = bpLogsWithoutId(rows, 'manual_1000_118_76')!;
      expect(next, hasLength(1));
      expect(bpLogsWithoutId(rows, 'manual_9_9_9'), isNull);
    });

    test('import dedupes against existing ids and sorts newest first',
        () {
      final rows = decodeBpLogsRaw(jsonEncode([
        {'systolic': 118, 'diastolic': 76, 'timeEpochMs': 1000},
      ]));
      final result = bpLogsWithImported(rows, const [
        BpCsvReading(systolic: 118, diastolic: 76, timeEpochMs: 1000),
        BpCsvReading(systolic: 130, diastolic: 85, timeEpochMs: 3000),
        BpCsvReading(systolic: 125, diastolic: 82, timeEpochMs: 2000),
      ]);
      expect(result.added, 2);
      final times = result.rows
          .map((r) => bpRowValues(r)!.timeEpochMs)
          .toList();
      expect(times, [3000, 2000, 1000]);
    });
  });

  // ── Blood Pressure: CSV parser port ──────────────────────────────
  group('bp: CSV parser (native port)', () {
    test('US headers + M/d/yyyy dates', () {
      final result = parseBpCsv(
          'Systolic,Diastolic,Date\n120,80,9/20/2026\n118,76,9/21/2026\n');
      final success = result as BpCsvParseSuccess;
      expect(success.readings, hasLength(2));
      expect(success.readings[0].timeEpochMs,
          DateTime(2026, 9, 20).millisecondsSinceEpoch);
      expect(success.invalidRowCount, 0);
    });

    test('semicolon delimiter + EU d.M.yyyy dates', () {
      final result =
          parseBpCsv('SYS;DIA;Date\n130;85;20.9.2026\n');
      final success = result as BpCsvParseSuccess;
      expect(success.readings.single.systolic, 130);
      expect(success.readings.single.timeEpochMs,
          DateTime(2026, 9, 20).millisecondsSinceEpoch);
    });

    test('separate date + time columns combine', () {
      final result = parseBpCsv(
          'Systolic,Diastolic,Date,Time\n120,80,2026-09-20,08:15\n');
      final success = result as BpCsvParseSuccess;
      expect(success.readings.single.timeEpochMs,
          DateTime(2026, 9, 20, 8, 15).millisecondsSinceEpoch);
    });

    test('ISO datetime column with offset', () {
      final result = parseBpCsv(
          'Systolic,Diastolic,Timestamp\n120,80,2026-09-20T08:15:00+02:00\n');
      final success = result as BpCsvParseSuccess;
      expect(success.readings.single.timeEpochMs,
          DateTime.parse('2026-09-20T08:15:00+02:00')
              .millisecondsSinceEpoch);
    });

    test('US datetime with AM/PM', () {
      final result = parseBpCsv(
          'Systolic,Diastolic,Date\n120,80,9/20/2026 8:15 AM\n');
      final success = result as BpCsvParseSuccess;
      expect(success.readings.single.timeEpochMs,
          DateTime(2026, 9, 20, 8, 15).millisecondsSinceEpoch);
    });

    test('quoted fields and parenthesized headers normalize', () {
      final result = parseBpCsv(
          'Systolic (mmHg),Diastolic (mmHg),Date\n"120","80",2026-09-20\n');
      final success = result as BpCsvParseSuccess;
      expect(success.readings.single.systolic, 120);
      expect(splitBpCsvLine('a,"b,c",d', ','), ['a', 'b,c', 'd']);
    });

    test('invalid rows counted, in-file duplicates counted', () {
      final result = parseBpCsv('Systolic,Diastolic,Date\n'
          '120,80,2026-09-20\n'
          '120,80,2026-09-20\n'
          '80,120,2026-09-20\n'
          '500,80,2026-09-20\n'
          'abc,80,2026-09-20\n');
      final success = result as BpCsvParseSuccess;
      expect(success.readings, hasLength(1));
      expect(success.duplicateRowCount, 1);
      expect(success.invalidRowCount, 3);
    });

    test('failures carry the native messages', () {
      expect(
          (parseBpCsv('Foo,Bar\n1,2\n') as BpCsvParseFailure).message,
          bpCsvMsgNoHeaders);
      expect((parseBpCsv('') as BpCsvParseFailure).message,
          bpCsvMsgNoValidRows);
      expect(
          (parseBpCsv('Systolic,Diastolic,Date\n120,80,20/13/2026\n')
                  as BpCsvParseFailure)
              .message,
          bpCsvMsgNoDateFormat);
    });

    test('preview splits new vs already-logged; result message pluralizes',
        () {
      final parsed = parseBpCsv(
              'Systolic,Diastolic,Date\n120,80,9/20/2026\n118,76,9/21/2026\n')
          as BpCsvParseSuccess;
      final existing = decodeBpLogsRaw(jsonEncode([
        {
          'systolic': 120,
          'diastolic': 80,
          'timeEpochMs': DateTime(2026, 9, 20).millisecondsSinceEpoch,
        },
      ]));
      final preview = buildBpCsvPreview(parsed, existing);
      expect(preview.newReadings, hasLength(1));
      expect(preview.duplicateCount, 1);
      // Native plural() appends "s" for every count != 1, so a zero
      // invalid count renders "0 invalids" (production matches native).
      expect(bpCsvResultMessage(preview),
          '1 reading imported, 1 row skipped (1 duplicate, 0 invalids)');
    });
  });

  // ── Blood Pressure: widget flows ─────────────────────────────────
  group('bp: widget write flows', () {
    FakeProfileServer serverWithBp() {
      final server = FakeProfileServer();
      server.bpLogs = jsonEncode([
        {'systolic': 118, 'diastolic': 76, 'timeEpochMs': 1700000000000},
        {'systolic': 122, 'diastolic': 80, 'timeEpochMs': 1700100000000},
      ]);
      return server;
    }

    testWidgets('manual add via FAB writes the blob and shows the reading',
        (tester) async {
      final server = serverWithBp();
      await pumpScreen(
        tester,
        BloodPressureToolScreen(
            backend: server.backend(), healthConnect: disconnectedHc()),
      );
      expect(find.text('122 / 80'), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('Log Blood Pressure'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), '131');
      await tester.enterText(find.byType(TextField).at(1), '84');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final rows = server.bpRows();
      expect(rows, hasLength(3));
      final added = rows.first as Map;
      expect(added['systolic'], 131);
      expect(added['diastolic'], 84);
      expect(added['source'], 'MANUAL');
      expect('${added['id']}'.startsWith('manual_'), isTrue);
      // New reading (timestamp = now) is the spotlighted latest.
      expect(find.text('131 / 84'), findsOneWidget);
    });

    testWidgets('invalid values are rejected inside the dialog',
        (tester) async {
      final server = serverWithBp();
      await pumpScreen(
        tester,
        BloodPressureToolScreen(
            backend: server.backend(), healthConnect: disconnectedHc()),
      );
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '0');
      await tester.enterText(find.byType(TextField).at(1), '80');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Please enter valid systolic and diastolic values'),
          findsOneWidget);
      expect(server.posts, isEmpty);
    });

    testWidgets('failed add keeps the dialog open with an error',
        (tester) async {
      final server = serverWithBp()..failPosts = true;
      await pumpScreen(
        tester,
        BloodPressureToolScreen(
            backend: server.backend(), healthConnect: disconnectedHc()),
      );
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '131');
      await tester.enterText(find.byType(TextField).at(1), '84');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save this reading'),
          findsOneWidget);
      expect(server.bpRows(), hasLength(2)); // nothing landed
    });

    testWidgets('delete a manual reading via confirm dialog',
        (tester) async {
      final server = serverWithBp();
      await pumpScreen(
        tester,
        BloodPressureToolScreen(
            backend: server.backend(), healthConnect: disconnectedHc()),
      );
      // Delete icon on the newest (manual) row.
      await tester.tap(find.byIcon(Icons.delete).first);
      await tester.pumpAndSettle();
      expect(find.text('Delete Manual Reading?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      final rows = server.bpRows();
      expect(rows, hasLength(1));
      expect((rows.single as Map)['systolic'], 118);
      expect(find.text('122 / 80 mmHg'), findsNothing);
    });

    testWidgets('CSV import: preview, confirm, result, blob updated',
        (tester) async {
      final server = FakeProfileServer();
      final existingMs = DateTime(2026, 9, 20).millisecondsSinceEpoch;
      server.bpLogs = jsonEncode([
        {'systolic': 120, 'diastolic': 80, 'timeEpochMs': existingMs},
      ]);
      final csv = 'Systolic,Diastolic,Date\n'
          '120,80,9/20/2026\n'
          '118,76,9/21/2026\n';
      await pumpScreen(
        tester,
        BloodPressureToolScreen(
          backend: server.backend(),
          healthConnect: disconnectedHc(),
          csvFilePicker: FakeCsvPicker(csv),
        ),
      );
      await tester.tap(find.text('Import CSV'));
      await tester.pumpAndSettle();
      expect(find.text('Import Blood Pressure CSV'), findsOneWidget);
      expect(find.text('1 reading ready to import'), findsOneWidget);
      expect(find.text('1 duplicate skipped (already in your log)'),
          findsOneWidget);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      expect(find.text('Import Complete'), findsOneWidget);
      expect(
          find.text(
              '1 reading imported, 1 row skipped (1 duplicate, 0 invalids)'),
          findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final rows = server.bpRows();
      expect(rows, hasLength(2));
      expect(find.text('118 / 76'), findsOneWidget);
    });

    testWidgets('CSV parse failure shows the native error dialog',
        (tester) async {
      final server = serverWithBp();
      await pumpScreen(
        tester,
        BloodPressureToolScreen(
          backend: server.backend(),
          healthConnect: disconnectedHc(),
          csvFilePicker: FakeCsvPicker('Foo,Bar\n1,2\n'),
        ),
      );
      await tester.tap(find.text('Import CSV'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't Import CSV"), findsOneWidget);
      expect(find.text(bpCsvMsgNoHeaders), findsOneWidget);
      expect(server.posts, isEmpty);
    });
  });
}
