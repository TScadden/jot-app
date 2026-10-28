import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Regression test for the History search clear-button glyph bug:
/// the search TextField was uncontrolled (no TextEditingController),
/// so tapping 'Clear search' reset only the `_searchQuery` filter
/// state and left the typed glyphs visible in the field. The fix
/// gives _HistoryScreenState a controller, wires it into the field,
/// and clears both on tap.

const _categories = <Map<String, dynamic>>[
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

Map<String, dynamic> _fogEntry() => {
      'id': 42,
      'categoryId': 3,
      'body': 'Brain fog all morning',
      'chips': '["Symptoms"]',
      'manualText': '',
      'timestamp': DateTime(2026, 10, 12, 9, 30).millisecondsSinceEpoch,
    };

Map<String, dynamic> _walkEntry() => {
      'id': 44,
      'categoryId': 3,
      'body': 'Took a walk at noon',
      'chips': '["Symptoms"]',
      'manualText': '',
      'timestamp': DateTime(2026, 10, 12, 10, 30).millisecondsSinceEpoch,
    };

class _FakeServer {
  final List<Map<String, dynamic>> entries;

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
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    });
    return TabsBackend(client: client, sessionStore: store);
  }
}

LogEntryOutbox _freshOutbox() {
  final disk = <String, String>{};
  final outbox = LogEntryOutbox.instance;
  outbox.debugReset();
  outbox.debugSetStore(
    read: (key) async => disk[key],
    write: (key, value) async => disk[key] = value,
    delete: (key) async => disk.remove(key),
  );
  return outbox;
}

void main() {
  setUp(() => TabsBackend.debugResetSharedCaches());

  testWidgets(
      'History search clear button empties the field and restores the full list',
      (tester) async {
    final server = _FakeServer([_fogEntry(), _walkEntry()]);
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(backend: server.backend(), outbox: _freshOutbox()),
      ),
    );
    await tester.pumpAndSettle();

    // Full unfiltered list is shown initially.
    expect(find.text('Brain fog all morning'), findsOneWidget);
    expect(find.text('Took a walk at noon'), findsOneWidget);

    // Type a query that filters the list down to one entry.
    await tester.enterText(find.byType(TextField), 'fog');
    await tester.pumpAndSettle();

    expect(find.text('Brain fog all morning'), findsOneWidget);
    expect(find.text('Took a walk at noon'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'fog',
    );

    // Tap Clear.
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();

    // (a) The visible text in the search field is empty.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller, isNotNull);
    expect(field.controller!.text, isEmpty);
    expect(find.byTooltip('Clear search'), findsNothing);

    // (b) The full unfiltered list is back.
    expect(find.text('Brain fog all morning'), findsOneWidget);
    expect(find.text('Took a walk at noon'), findsOneWidget);
  });
}
