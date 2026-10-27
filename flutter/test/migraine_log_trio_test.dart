import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';

import 'test_helpers.dart';

/// Migraine log trio (founder direction + Juno ruling, Oct 27,
/// 2026 — 2026-10-27-migraine-log-trio-juno.md):
/// - Fix 2: HistoryScreen's initial load invalidates the sync-pull
///   cache BEFORE fetching (the 5-minute TTL cache hid a
///   just-saved migraine entry from the founder).
/// - Fix 3: migraine entries file under "Migraine Symptoms &
///   Triggers" when it exists, else Symptoms, fallback id 1 (§D).
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

  group('fix 3 — migraine category resolution (Juno §D)', () {
    TabsBackend backendForCategories(List<Map<String, dynamic>> cats) {
      final session = FakeSessionStore()..token = 'tok';
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': <dynamic>[],
              'categories': cats,
              'profile': <String, dynamic>{},
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      return TabsBackend(client: client, sessionStore: session);
    }

    Future<int> resolve(List<Map<String, dynamic>> cats) {
      TabsBackend.debugResetSharedCaches();
      return BackendMigraineTrendsGateway(backendForCategories(cats))
          .resolveMigraineCategoryId();
    }

    test('founder category present → its id (founder list shape)',
        () async {
      // The founder's real list: id 1 Symptoms, id 9 the migraine
      // category. The migraine category wins over Symptoms.
      expect(
        await resolve([
          {'id': 1, 'name': 'Symptoms'},
          {'id': 9, 'name': 'Migraine Symptoms & Triggers'},
        ]),
        9,
      );
    });

    test('founder category match is case-insensitive', () async {
      expect(
        await resolve([
          {'id': 9, 'name': 'migraine symptoms & triggers'},
          {'id': 1, 'name': 'Symptoms'},
        ]),
        9,
      );
    });

    test('no founder category → Symptoms id, resolved by name',
        () async {
      // Symptoms carries id 3 here, NOT the fallback 1 — proving
      // the Symptoms step resolves by name, not by the fallback.
      expect(
        await resolve([
          {'id': 3, 'name': 'Symptoms'},
          {'id': 1, 'name': 'Other'},
        ]),
        3,
      );
    });

    test('neither category → fallback id 1', () async {
      expect(
        await resolve([
          {'id': 5, 'name': 'Other'},
        ]),
        1,
      );
    });

    test('posted entry carries the resolved category id', () async {
      final h = Harness();
      h.gateway.categoryId = 9;
      await h.controller.initialize();
      await h.controller.startAttack();
      await h.controller.endWithReliefDialog(reliefRating: 3);
      expect(h.gateway.posted, hasLength(1));
      expect(h.gateway.posted.single.categoryId, 9);
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

class MemoryStore {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

MigraineAttackStore storeWith(MemoryStore s) =>
    MigraineAttackStore.withStorage(
      read: s.read,
      write: s.write,
      delete: s.delete,
    );

class FakeMigraineNotifier implements MigraineNotifier {
  bool enabled;
  bool launch = false;
  final List<int> showCalls = [];
  int cancelCount = 0;
  FakeMigraineNotifier({this.enabled = true});

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> showAttack(int elapsedMin) async {
    if (!enabled) return false;
    showCalls.add(elapsedMin);
    return true;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }

  @override
  Future<bool> areNotificationsEnabled() async => enabled;

  @override
  Future<bool> launchMigrainePayload() async => launch;
}

class FakeTrendsGateway implements MigraineTrendsGateway {
  final List<QuickLogEntry> posted = [];
  bool postResult = true;
  int categoryId = 7;
  int nextId = 100;

  @override
  Future<bool> postEntry(QuickLogEntry entry) async {
    posted.add(entry);
    return postResult;
  }

  @override
  Future<int> resolveMigraineCategoryId() async => categoryId;

  @override
  Future<int> generateEntryId() async => nextId++;
}

class Harness {
  final MemoryStore mem = MemoryStore();
  late final MigraineAttackStore store = storeWith(mem);
  final FakeMigraineNotifier notifier = FakeMigraineNotifier();
  final FakeTrendsGateway gateway = FakeTrendsGateway();
  DateTime now = DateTime(2026, 10, 27, 9, 12);
  late final MigraineController controller = MigraineController(
    store: store,
    notifier: notifier,
    gateway: gateway,
    clock: () => now,
  );
}
