import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Migraine log trio (founder direction + Juno ruling, Oct 27,
/// 2026 — 2026-10-27-migraine-log-trio-juno.md):
/// - Fix 2: HistoryScreen's initial load invalidates the sync-pull
///   cache BEFORE fetching (the 5-minute TTL cache hid a
///   just-saved migraine entry from the founder).
/// - Fix 1 support: HistoryScreen's focusEntryId opens that entry
///   once loaded (the completion line's tap target).
void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('fix 2 — History initial load invalidates before fetching', () {
    testWidgets('invalidateSyncPull precedes the first fetchSyncPull',
        (tester) async {
      final backend = _RecordingBackend();
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: backend),
      ));
      await tester.pumpAndSettle();
      expect(backend.calls.length, greaterThanOrEqualTo(2));
      expect(backend.calls.first, 'invalidate',
          reason: 'the initial load invalidates the TTL cache first');
      expect(backend.calls[1], 'fetch',
          reason: 'the first fetch happens only after invalidation');
      // The loaded (empty) state renders — the load itself worked.
      expect(find.text('No entries yet'), findsOneWidget);
    });
  });

  group('fix 1 support — HistoryScreen focusEntryId', () {
    TabsBackend serverBackend() {
      final session = FakeSessionStore()..token = 'tok';
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          // Response.bytes + explicit UTF-8: http.Response(String)
          // encodes latin1 by default and throws on the em dash in
          // the §E entry body.
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'entries': [
                {
                  'id': 42,
                  'categoryId': 9,
                  'body': 'Migraine attack — 45 min. Started '
                      'Oct 27, 9:12 AM.',
                  'chips': '["Migraine attack"]',
                  'manualText': 'Ended Oct 27, 9:57 AM',
                  'timestamp':
                      DateTime(2026, 10, 27, 9, 12).millisecondsSinceEpoch,
                },
                {
                  'id': 7,
                  'categoryId': 1,
                  'body': 'Unrelated older entry',
                  'chips': '[]',
                  'manualText': '',
                  'timestamp':
                      DateTime(2026, 10, 26, 8, 0).millisecondsSinceEpoch,
                },
              ],
              'categories': [
                {
                  'id': 9,
                  'name': 'Migraine Symptoms & Triggers',
                  'icon': 'circle',
                  'colorHex': '#B388FF',
                  'isDefault': false,
                  'sortOrder': 2,
                },
                {
                  'id': 1,
                  'name': 'Symptoms',
                  'icon': 'circle',
                  'colorHex': '#4ECDC4',
                  'isDefault': true,
                  'sortOrder': 1,
                },
              ],
              'profile': <String, dynamic>{},
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('not found', 404);
      });
      return TabsBackend(client: client, sessionStore: session);
    }

    testWidgets('focused entry opens in its detail dialog once loaded',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: serverBackend(), focusEntryId: 42),
      ));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget,
          reason: 'the tap target lands on THAT entry (Juno §A.3)');
      // The dialog is the focused entry's: its body and its real
      // category title, not the other entry's.
      expect(
        find.descendant(
            of: dialog,
            matching: find.textContaining('Migraine attack — 45 min.')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: dialog,
            matching: find.text('Migraine Symptoms & Triggers')),
        findsOneWidget,
      );
    });

    testWidgets('no focus id → no dialog opens', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: serverBackend()),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Unrelated older entry'), findsOneWidget);
    });

    testWidgets('focus id absent from the pull → no dialog, list stands',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: serverBackend(), focusEntryId: 999),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Unrelated older entry'), findsOneWidget);
    });
  });
}

/// Records sync-pull cache/fetch call order, so the fix-2 test can
/// prove the initial load invalidates BEFORE it fetches.
class _RecordingBackend extends TabsBackend {
  final List<String> calls = [];

  _RecordingBackend() : super(sessionStore: FakeSessionStore());

  @override
  void invalidateSyncPull() {
    calls.add('invalidate');
  }

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() {
    calls.add('fetch');
    return Future.value(<String, dynamic>{
      'entries': <dynamic>[],
      'categories': <dynamic>[],
      'profile': <String, dynamic>{},
    });
  }
}
