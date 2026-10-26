import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';

import 'test_helpers.dart';

/// Screen-load performance (Oct 26, 2026) — pull-count verification
/// for the shared sync-pull cache fix (commit d848a80: the TTL cache
/// moved from per-instance fields to a STATIC session-keyed map).
///
/// BEFORE (measured on the pre-fix tree @365a0ef with the identical
/// fresh-instance probe): Quick Log's refresh cost **5** sequential
/// GET /api/sync/pull and History's load cost **2**, because both
/// screens reach the backend through a per-access getter
/// (`TabsBackend get _backend => widget.backend ?? TabsBackend();`)
/// and the old cache died with each minted instance.
///
/// These tests pin the AFTER behaviour two ways:
/// 1. Backend-sequence tests replay each screen's exact await chain
///    through a FRESH [TabsBackend] per call — the production getter
///    pattern — and count pulls on a counting [MockClient].
/// 2. Widget tests mount the real screens over a counting client and
///    count the pulls one refresh / initial load actually fires.
void main() {
  var tokenSeq = 0;

  /// One counting fake server: counts GET /api/sync/pull and serves
  /// a small but complete pull body (one category, one entry).
  ({TabsBackend Function() fresh, int Function() pulls}) countingServer() {
    var pulls = 0;
    final token = 'perf-token-${tokenSeq++}';
    final client = MockClient((request) async {
      if (request.url.path == '/api/sync/pull' && request.method == 'GET') {
        pulls++;
        return http.Response(
          jsonEncode({
            'entries': [
              {
                'id': 42,
                'categoryId': 3,
                'body': 'Brain fog all morning',
                'chips': '',
                'manualText': '',
                'timestamp':
                    DateTime(2026, 10, 12, 9, 30).millisecondsSinceEpoch,
              },
            ],
            'categories': [
              {
                'id': 3,
                'name': 'Symptoms',
                'icon': 'circle',
                'colorHex': '#4ECDC4',
                'isDefault': true,
                'sortOrder': 1,
              },
            ],
            'profile': <String, dynamic>{},
            'isUnlimited': true,
            'isAdmin': false,
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    TabsBackend fresh() => TabsBackend(
          client: client,
          sessionStore: FakeSessionStore()..token = token,
        );
    return (fresh: fresh, pulls: () => pulls);
  }

  setUp(() {
    TabsBackend.debugResetSharedCaches();
    QuickLogCache.instance.debugReset();
    QuickLogCache.instance.debugSetStore(
      read: (_) async => null,
      write: (_, __) async {},
      delete: (_) async {},
    );
  });

  tearDown(() {
    TabsBackend.debugResetSharedCaches();
    QuickLogCache.instance.debugReset();
  });

  group('backend sequences (fresh instance per call, as in production)',
      () {
    test('Quick Log refresh chain costs exactly 1 HTTP pull', () async {
      final server = countingServer();
      // quick_log_screen.dart `_refresh`, in order, each await via
      // the per-access getter (a fresh instance per line here).
      final pull = await server.fresh().fetchSyncPull();
      expect(pull, isNotNull);
      await server.fresh().fetchLogEntryDtos();
      await server.fresh().fetchLogCategories();
      await server.fresh().fetchMembership();
      await server.fresh().fetchProfile();
      expect(server.pulls(), 1,
          reason: 'the 4 reads after the first must be shared-cache '
              'hits, not network fetches (pre-fix: 5 pulls)');
    });

    test('History load chain costs exactly 1 HTTP pull', () async {
      final server = countingServer();
      // history_screen.dart `_fetchIntoState`, in order.
      final pull = await server.fresh().fetchSyncPull();
      expect(pull, isNotNull);
      await server.fresh().fetchLogCategories();
      expect(server.pulls(), 1,
          reason: 'categories must ride the cached pull (pre-fix: 2)');
    });
  });

  group('widget level', () {
    testWidgets('Quick Log refresh fires at most 1 HTTP pull',
        (tester) async {
      final server = countingServer();
      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(backend: server.fresh()),
      ));
      // Let the background refresh run to completion.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Symptoms'), findsWidgets,
          reason: 'the refresh actually landed (categories rendered)');
      expect(server.pulls(), lessThanOrEqualTo(1),
          reason: 'one Quick Log refresh = at most one network pull');
      expect(server.pulls(), 1,
          reason: 'a cold open still pays exactly one real fetch');
    });

    testWidgets('History initial load fires at most 1 HTTP pull',
        (tester) async {
      final server = countingServer();
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: server.fresh()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Brain fog all morning'), findsWidgets,
          reason: 'the load actually landed (entry rendered)');
      expect(server.pulls(), lessThanOrEqualTo(1),
          reason: 'fetchSyncPull + fetchLogCategories collapse to '
              'one network pull via the shared cache');
      expect(server.pulls(), 1);
    });
  });
}
