import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// Screen-load performance (Oct 26, 2026): the sync-pull TTL cache and
/// the habits fetch must be shared across the many [TabsBackend]
/// instances the app constructs (one per screen, some per property
/// access). Before this package the TTL cache was per-instance, so
/// nearly every navigation paid a full GET /api/sync/pull, Quick Log's
/// refresh paid five, and /api/habits had no cache at all. These tests
/// count HTTP requests — the deterministic proxy for entry latency.
void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  ({TabsBackend Function() make, Map<String, int> counts}) harness(
      String token) {
    final counts = <String, int>{};
    final client = MockClient((request) async {
      final path = request.url.path;
      counts[path] = (counts[path] ?? 0) + 1;
      if (path == '/api/sync/pull') {
        return http.Response(
          jsonEncode({'profile': <String, dynamic>{}, 'entries': []}),
          200,
        );
      }
      if (path == '/api/habits') {
        return http.Response(jsonEncode({'habits': []}), 200);
      }
      return http.Response('{}', 200);
    });
    TabsBackend make() {
      final store = FakeSessionStore()..token = token;
      return TabsBackend(client: client, sessionStore: store);
    }

    return (make: make, counts: counts);
  }

  test('sequential fetchSyncPull on two instances = one HTTP pull',
      () async {
    final h = harness('tok-perf-1');
    await h.make().fetchSyncPull();
    await h.make().fetchSyncPull();
    await h.make().fetchSyncPull();
    expect(h.counts['/api/sync/pull'], 1);
  });

  test('pull-derived getters reuse the shared pull (no extra GETs)',
      () async {
    final h = harness('tok-perf-2');
    await h.make().fetchSyncPull();
    await h.make().fetchStreak();
    await h.make().fetchLogEntries();
    await h.make().fetchManualBpLogs();
    await h.make().fetchProfile();
    await h.make().fetchIsUnlimited();
    expect(h.counts['/api/sync/pull'], 1);
  });

  test('fetchHabitsOrNull across instances = one HTTP fetch', () async {
    final h = harness('tok-perf-3');
    await h.make().fetchHabitsOrNull();
    await h.make().fetchHabitsOrNull();
    expect(h.counts['/api/habits'], 1);
  });

  test('invalidateSyncPull on one instance forces refetch on another',
      () async {
    final h = harness('tok-perf-4');
    final a = h.make();
    await a.fetchSyncPull();
    expect(h.counts['/api/sync/pull'], 1);
    a.invalidateSyncPull();
    await h.make().fetchSyncPull();
    expect(h.counts['/api/sync/pull'], 2);
  });

  test('a different session token never receives the cached pull',
      () async {
    final h1 = harness('tok-perf-5a');
    await h1.make().fetchSyncPull();
    final h2 = harness('tok-perf-5b');
    await h2.make().fetchSyncPull();
    expect(h2.counts['/api/sync/pull'], 1);
  });
}
