import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/migraine_block.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
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
/// - Fix 1: the Today Summary completion line (Juno §A template +
///   §B hint, verbatim) renders ONLY for a confirmed-saved finished
///   attack, and its tap opens that attack's entry in History.
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

  group('fix 1 — completion line text (Juno §A, worked examples)', () {
    MigraineAttack fixture(DateTime start, int durationMin) =>
        MigraineAttack(
          id: start.millisecondsSinceEpoch,
          startTimestamp: start.millisecondsSinceEpoch,
          endTimestamp: start
              .add(Duration(minutes: durationMin))
              .millisecondsSinceEpoch,
          updatedAt: start
              .add(Duration(minutes: durationMin))
              .millisecondsSinceEpoch,
          trendsEntryId: 100,
        );

    test('example 1: under-60 duration, PM start', () {
      final a = fixture(DateTime(2026, 10, 27, 13, 42), 32);
      expect(migraineLoggedLine(a),
          'Migraine attack logged — 32 min. Started Oct 27, 1:42 PM.');
    });

    test('example 2: over-60 duration, AM start', () {
      final a = fixture(DateTime(2026, 10, 27, 9, 12), 135);
      expect(migraineLoggedLine(a),
          'Migraine attack logged — 2h 15m. Started Oct 27, 9:12 AM.');
    });

    test('hint is Juno §B verbatim', () {
      expect(migraineLoggedHint, 'Tap to view in History');
    });
  });

  group('fix 1 — controller truth conditions (Juno §A 1, 2, 5)', () {
    Future<Harness> endedHarness({bool postOk = true}) async {
      final h = Harness();
      h.gateway.postResult = postOk;
      await h.controller.initialize();
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 27, 9, 57);
      await h.controller.endWithReliefDialog(reliefRating: 3);
      return h;
    }

    test('confirmed-saved end → lastLoggedAttack is that attack',
        () async {
      final h = await endedHarness();
      final logged = h.controller.lastLoggedAttack;
      expect(logged, isNotNull);
      expect(logged!.trendsEntryId, 100);
      expect(logged.trendsEntryPending, isFalse);
      expect(logged.isActive, isFalse);
    });

    test('failed end write → NO completion state (no pending variant)',
        () async {
      final h = await endedHarness(postOk: false);
      expect(h.controller.isActive, isFalse,
          reason: 'the end itself still stands (§F degradation)');
      expect(h.controller.lastLoggedAttack, isNull,
          reason: 'an unsaved end must not present as logged (§A.1)');
    });

    test('a later retry confirming the save surfaces the line (§A.2)',
        () async {
      final h = await endedHarness(postOk: false);
      expect(h.controller.lastLoggedAttack, isNull);
      h.gateway.postResult = true;
      await h.controller.onAppResumed();
      expect(h.controller.lastLoggedAttack, isNotNull);
      expect(h.controller.lastLoggedAttack!.trendsEntryId, 100);
    });

    test('§C-form update confirming the entry surfaces the line (§A.1)',
        () async {
      final h = Harness();
      h.gateway.postResult = false;
      await h.controller.initialize();
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 27, 9, 57);
      final ended = await h.controller.endFromNotificationTap();
      h.controller.consumePendingDetails();
      expect(h.controller.lastLoggedAttack, isNull);
      h.gateway.postResult = true;
      final ok = await h.controller
          .saveDetails(attackId: ended!.id, reliefRating: 4);
      expect(ok, isTrue);
      expect(h.controller.lastLoggedAttack, isNotNull);
      expect(h.controller.lastLoggedAttack!.trendsEntryId, 100);
    });

    test('second confirmed attack the same day replaces the line (§A.5)',
        () async {
      final h = await endedHarness();
      expect(h.controller.lastLoggedAttack!.trendsEntryId, 100);
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 27, 10, 30);
      await h.controller.endWithReliefDialog(reliefRating: 2);
      expect(h.controller.lastLoggedAttack!.trendsEntryId, 101);
    });

    test('restored on a later load when the entry still exists',
        () async {
      final h = await endedHarness();
      final g2 = FakeTrendsGateway()..existsResult = true;
      final c2 = MigraineController(
        store: h.store,
        notifier: FakeMigraineNotifier(),
        gateway: g2,
        clock: () => h.now,
      );
      await c2.initialize();
      expect(c2.lastLoggedAttack, isNotNull);
      expect(c2.lastLoggedAttack!.trendsEntryId, 100);
    });

    test('entry deleted → line must not render on a subsequent load (§A.5)',
        () async {
      final h = await endedHarness();
      final g2 = FakeTrendsGateway()..existsResult = false;
      final c2 = MigraineController(
        store: h.store,
        notifier: FakeMigraineNotifier(),
        gateway: g2,
        clock: () => h.now,
      );
      await c2.initialize();
      expect(c2.lastLoggedAttack, isNull);
    });

    test('existence unknown (pull failed) → line kept, not dropped',
        () async {
      final h = await endedHarness();
      final g2 = FakeTrendsGateway()..existsResult = null;
      final c2 = MigraineController(
        store: h.store,
        notifier: FakeMigraineNotifier(),
        gateway: g2,
        clock: () => h.now,
      );
      await c2.initialize();
      expect(c2.lastLoggedAttack, isNotNull);
    });

    test('an attack that ended yesterday is not restored today',
        () async {
      final h = Harness();
      final yStart = DateTime(2026, 10, 26, 22, 0);
      final yEnd = DateTime(2026, 10, 26, 22, 30);
      await h.store.save(MigraineAttack(
        id: yStart.millisecondsSinceEpoch,
        startTimestamp: yStart.millisecondsSinceEpoch,
        endTimestamp: yEnd.millisecondsSinceEpoch,
        updatedAt: yEnd.millisecondsSinceEpoch,
        trendsEntryId: 55,
        trendsEntryPending: false,
      ));
      await h.controller.initialize();
      expect(h.controller.lastLoggedAttack, isNull);
    });
  });

  group('fix 1 — completion line widget (Juno §A + §B)', () {
    Future<Harness> endedHarness({bool postOk = true}) async {
      final h = Harness();
      h.gateway.postResult = postOk;
      await h.controller.initialize();
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 27, 9, 57);
      await h.controller.endWithReliefDialog(reliefRating: 3);
      return h;
    }

    const line = 'Migraine attack logged — 45 min. '
        'Started Oct 27, 9:12 AM.';

    testWidgets('renders line + hint after a saved end; tap fires '
        'with the entry id', (tester) async {
      final h = await endedHarness();
      int? tappedId;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MigraineBlock(
              controller: h.controller,
              onOpenLoggedEntry: (id) => tappedId = id,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(line), findsOneWidget);
      expect(find.text(migraineLoggedHint), findsOneWidget);
      // §B: the screen-reader label is the two ruled strings in
      // order, as one node.
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('$line $migraineLoggedHint'),
          findsOneWidget);
      semantics.dispose();

      await tester.tap(find.text(line));
      await tester.pumpAndSettle();
      expect(tappedId, 100,
          reason: 'the tap targets THAT attack\'s entry (§A.3)');
    });

    testWidgets('no line while the end is unsaved/pending',
        (tester) async {
      final h = await endedHarness(postOk: false);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MigraineBlock(controller: h.controller),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Migraine attack logged'), findsNothing);
      expect(find.text(migraineLoggedHint), findsNothing);
      expect(find.text('Start attack'), findsOneWidget,
          reason: 'idle block otherwise unchanged');
    });

    testWidgets('no line while an attack is running', (tester) async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MigraineBlock(controller: h.controller),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Migraine attack logged'), findsNothing);
      expect(find.text('End attack'), findsOneWidget);
    });
  });

  group('fix 1 — Today Summary tap-through (§A.3, end to end)', () {
    testWidgets('tap opens History focused on the attack\'s entry',
        (tester) async {
      final h = Harness();
      await h.controller.initialize();
      await h.controller.startAttack();
      h.now = DateTime(2026, 10, 27, 9, 57);
      await h.controller.endWithReliefDialog(reliefRating: 3);
      final posted = h.gateway.posted.single;

      final planMem = MemoryStore();
      final cacheMem = MemoryStore();
      final planStore = TodayPlanStore.testInstance();
      planStore.debugSetStore(
          read: planMem.read, write: planMem.write, delete: planMem.delete);
      final cache = TodaySummaryCache.testInstance();
      cache.debugSetStore(
          read: cacheMem.read, write: cacheMem.write, delete: cacheMem.delete);
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'entries': [
                {
                  'id': posted.id,
                  'categoryId': posted.categoryId,
                  'body': posted.body,
                  'chips': posted.chips,
                  'manualText': posted.manualText,
                  'timestamp': posted.timestamp,
                },
              ],
              'categories': [
                {
                  'id': 7,
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
        if (request.url.path == '/api/habits') {
          return http.Response(jsonEncode({'habits': <dynamic>[]}), 200);
        }
        return http.Response('{}', 404);
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TodaySummaryCard(
              backend: TabsBackend(client: client, sessionStore: session),
              healthConnectService: _FakeHc(),
              planStore: planStore,
              summaryCache: cache,
              sessionStore: session,
              migraineController: h.controller,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Expand the card, then tap the completion line.
      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();
      const line = 'Migraine attack logged — 45 min. '
          'Started Oct 27, 9:12 AM.';
      expect(find.text(line), findsOneWidget);
      await tester.tap(find.text(line));
      await tester.pumpAndSettle();

      // History opened on THAT entry: its detail dialog is up with
      // the §E body.
      expect(find.byType(HistoryScreen), findsOneWidget);
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(
            of: dialog, matching: find.textContaining(posted.body)),
        findsOneWidget,
      );
    });
  });
}

class _FakeHc extends HealthConnectService {
  @override
  Future<int?> readSleepMinutes(String dateStr) async => null;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];
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

  bool? existsResult = true;

  @override
  Future<bool?> entryExists(int entryId) async => existsResult;
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
