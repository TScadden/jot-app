import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Round 42 — History entry editing (port of native
/// `EntryDetailScreen` / `EntryDetailViewModel`):
/// - Text edit → upsert payload carries the SAME id + new body,
///   manualText cleared (native `updateText(edited, "")`).
/// - Category change → payload carries the new categoryId and chips
///   replaced by the native JSON-array shape `["<category name>"]`;
///   the list row updates in place with no reload.
/// - Check-in entries (Mood & Energy + "Daily Ranking") → NO edit UI.
/// - Failed save → old values remain everywhere, error shown.

const _categories = <Map<String, dynamic>>[
  {
    'id': 6,
    'name': 'Mood & Energy',
    'icon': 'circle',
    'colorHex': '#FFD93D',
    'isDefault': true,
    'sortOrder': 5,
  },
  {
    'id': 3,
    'name': 'Symptoms',
    'icon': 'circle',
    'colorHex': '#4ECDC4',
    'isDefault': true,
    'sortOrder': 1,
  },
  {
    'id': 7,
    'name': 'General',
    'icon': 'circle',
    'colorHex': '#CCCCCC',
    'isDefault': true,
    'sortOrder': 0,
  },
];

Map<String, dynamic> _normalEntry() => {
      'id': 42,
      'categoryId': 3,
      'body': 'Brain fog all morning',
      'chips': '["Symptoms"]',
      'manualText': '',
      'timestamp': DateTime(2026, 10, 12, 9, 30).millisecondsSinceEpoch,
    };

Map<String, dynamic> _checkInEntry() => {
      'id': 43,
      'categoryId': 6,
      'body': 'Feeling: 4/5 Today',
      'chips': '["Daily Ranking"]',
      'manualText': '',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

/// Stateful fake server: the sync pull reflects whatever the entries
/// upsert accepted, exactly like the real backend. When [failPosts]
/// is set, POSTs return 500 and server state never changes.
class _FakeServer {
  final List<Map<String, dynamic>> entries;
  bool failPosts = false;
  final List<Map<String, dynamic>> capturedPosts = [];

  _FakeServer(this.entries);

  TabsBackend backend() {
    final store = FakeSessionStore()..token = 'test-token';
    final client = MockClient((request) async {
      if (request.url.path == '/api/sync/pull') {
        return http.Response(
          jsonEncode({
            'entries': entries,
            'categories': _categories,
            'profile': <String, dynamic>{},
            'isUnlimited': true,
            'isAdmin': false,
          }),
          200,
        );
      }
      if (request.url.path == '/api/sync/entries' &&
          request.method == 'POST') {
        if (failPosts) return http.Response('server error', 500);
        final decoded =
            jsonDecode(request.body) as Map<String, dynamic>;
        final rows = (decoded['entries'] as List)
            .cast<Map<String, dynamic>>();
        capturedPosts.addAll(rows);
        for (final row in rows) {
          final i = entries.indexWhere((e) => e['id'] == row['id']);
          if (i >= 0) {
            entries[i] = {...entries[i], ...row};
          } else {
            entries.add(row);
          }
        }
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    });
    return TabsBackend(client: client, sessionStore: store);
  }
}

Future<void> _pumpHistory(
  WidgetTester tester,
  _FakeServer server,
) async {
  await tester.pumpWidget(
    MaterialApp(home: HistoryScreen(backend: server.backend())),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Screen-load perf (Oct 26, 2026): the sync-pull cache is now a
  // STATIC session-keyed map shared by every TabsBackend instance,
  // and every case in this suite reuses the token 'test-token' — so
  // without a reset, one case's cached pull body would be served to
  // the next case's fresh fake server. Reset between cases via the
  // backend's test hook (its documented purpose).
  setUp(() => TabsBackend.debugResetSharedCaches());

  group('pure edit helpers (native EntryDetailViewModel ports)', () {
    const entry = QuickLogEntry(
      id: 42,
      categoryId: 3,
      body: 'Brain fog',
      chips: '["Symptoms"]',
      manualText: 'extra note',
      timestamp: 123456,
    );
    const general = QuickLogCategory(
      id: 7,
      name: 'General',
      icon: 'circle',
      colorHex: '#CCCCCC',
      isDefault: true,
      sortOrder: 0,
    );

    test('combined text joins body + manualText like native', () {
      expect(entryCombinedText(entry), 'Brain fog\n\nextra note');
      expect(entryCombinedText(entry.copyWith(manualText: '')), 'Brain fog');
    });

    test('text edit keeps id/timestamp, clears manualText', () {
      final edited = editedEntryText(entry, 'New text');
      expect(edited.id, 42);
      expect(edited.timestamp, 123456);
      expect(edited.body, 'New text');
      expect(edited.manualText, '');
      expect(edited.categoryId, 3);
      expect(edited.chips, '["Symptoms"]');
      // The upsert payload shape carries that same id.
      final payload = edited.toSyncJson();
      expect(payload['id'], 42);
      expect(payload['body'], 'New text');
      expect(payload['manualText'], '');
    });

    test('category edit replaces chips with JSON array of the name', () {
      final edited = editedEntryCategory(entry, general);
      expect(edited.id, 42);
      expect(edited.categoryId, 7);
      expect(edited.chips, '["General"]');
      expect(edited.body, 'Brain fog');
      expect(edited.manualText, 'extra note');
    });

    test('picker order is sortOrder ASC (native CategoryDao)', () {
      final cats = [
        const QuickLogCategory(
            id: 6, name: 'Mood & Energy', icon: '', colorHex: '',
            isDefault: true, sortOrder: 5),
        const QuickLogCategory(
            id: 3, name: 'Symptoms', icon: '', colorHex: '',
            isDefault: true, sortOrder: 1),
        general,
      ];
      expect(
        sortedCategoriesForPicker(cats).map((c) => c.id),
        [7, 3, 6],
      );
    });

    test('check-in detection: mood category + Daily Ranking chip', () {
      final cats = [general, const QuickLogCategory(
          id: 6, name: 'Mood & Energy', icon: '', colorHex: '',
          isDefault: true, sortOrder: 5)];
      final checkIn = entry.copyWith(
          categoryId: 6, chips: '["Daily Ranking"]');
      expect(isLockedCheckInEntry(checkIn, cats), isTrue);
      // Same chip in another category is NOT a check-in.
      expect(isLockedCheckInEntry(
          entry.copyWith(chips: '["Daily Ranking"]'), cats), isFalse);
      // Mood category without the reserved chip is NOT locked.
      expect(isLockedCheckInEntry(
          entry.copyWith(categoryId: 6, chips: '["Symptoms"]'), cats),
          isFalse);
    });

    test('parseEntryChips never renders raw JSON, tolerates junk', () {
      expect(parseEntryChips('["Daily Ranking","Nausea"]'),
          ['Daily Ranking', 'Nausea']);
      expect(parseEntryChips('not json'), isEmpty);
      expect(parseEntryChips(''), isEmpty);
    });
  });

  group('History entry editing (widget, fake server)', () {
    testWidgets('edit text → same id upsert, list row updates in place',
        (tester) async {
      final server = _FakeServer([_normalEntry()]);
      await _pumpHistory(tester, server);
      expect(find.text('Brain fog all morning'), findsOneWidget);

      await tester.tap(find.text('Brain fog all morning'));
      await tester.pumpAndSettle();
      // Detail shows the category picker + Edit affordance.
      expect(find.text('CHANGE CATEGORY'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Entry Text'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('entry_text_editor')),
          'Edited note text');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Exactly one upsert, carrying the EXISTING id + new body.
      expect(server.capturedPosts, hasLength(1));
      final row = server.capturedPosts.single;
      expect(row['id'], 42);
      expect(row['body'], 'Edited note text');
      expect(row['manualText'], '');
      expect(row['categoryId'], 3);
      expect(row['chips'], '["Symptoms"]');

      // Detail adopted the new text AND the list row behind it
      // already updated in place (old body gone, no reload spinner).
      expect(find.text('Edited note text'), findsWidgets);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Edited note text'), findsOneWidget);
      expect(find.text('Brain fog all morning'), findsNothing);
    });

    testWidgets('change category → payload + chips shape, row updates',
        (tester) async {
      final server = _FakeServer([_normalEntry()]);
      await _pumpHistory(tester, server);

      await tester.tap(find.text('Brain fog all morning'));
      await tester.pumpAndSettle();
      // Picker chips are the uppercase native-style labels.
      await tester.tap(find.text('GENERAL'));
      await tester.pumpAndSettle();

      expect(server.capturedPosts, hasLength(1));
      final row = server.capturedPosts.single;
      expect(row['id'], 42);
      expect(row['categoryId'], 7);
      // Native chips shape: JSON array string with the category name.
      expect(row['chips'], '["General"]');
      expect(row['body'], 'Brain fog all morning');

      // Dialog title follows the new category without any reload, and
      // the list row behind it now carries the General chip as well
      // (filter row + card + dialog title).
      expect(find.text('General'), findsWidgets);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Brain fog all morning'), findsOneWidget);
    });

    testWidgets('check-in entry → no edit UI present', (tester) async {
      final server = _FakeServer([_checkInEntry()]);
      await _pumpHistory(tester, server);
      // The list card shows the locked tag instead of the category.
      expect(find.text('Daily Ranking'), findsOneWidget);

      await tester.tap(find.text('Feeling: 4/5 Today'));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsNothing);
      expect(find.byIcon(Icons.edit), findsNothing);
      expect(find.text('CHANGE CATEGORY'), findsNothing);
      expect(
        find.text(
            'This entry was logged automatically and cannot be edited.'),
        findsOneWidget,
      );
      expect(
        find.text(
            'This tag was added automatically and cannot be changed.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.lock), findsWidgets);
      // No save was (or could be) attempted.
      expect(server.capturedPosts, isEmpty);
    });

    testWidgets('failed save → old values remain, error shown',
        (tester) async {
      final server = _FakeServer([_normalEntry()])..failPosts = true;
      await _pumpHistory(tester, server);

      await tester.tap(find.text('Brain fog all morning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('entry_text_editor')), 'Phantom edit');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Honest error, editor stays open, nothing adopted.
      expect(find.text("Couldn't save that edit — try again."),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // Detail still shows the OLD body — no phantom edit.
      expect(find.text('Brain fog all morning'), findsWidgets);
      expect(find.text('Phantom edit'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Brain fog all morning'), findsOneWidget);
      expect(find.text('Phantom edit'), findsNothing);
    });

    testWidgets('failed category change → old category kept, error shown',
        (tester) async {
      final server = _FakeServer([_normalEntry()])..failPosts = true;
      await _pumpHistory(tester, server);

      await tester.tap(find.text('Brain fog all morning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GENERAL'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't save that change — try again."),
          findsOneWidget);
      // Title still names the OLD category; server state unchanged.
      expect(find.text('Symptoms'), findsWidgets);
      expect(server.entries.single['categoryId'], 3);
    });
  });
}
