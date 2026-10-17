import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

import 'test_helpers.dart';

/// Round 19c — instant-render tests:
/// - QuickLogCache validity rules (today's count date-scoped;
///   categories/recents/membership persist).
/// - Quick Log first frame: shell + skeletons on a cold cache, cached
///   values (incl. the gate state) on a warm cache — never a spinner.
/// - History initial open: skeleton, never a spinner.
/// - NavDock pill lands on the SELECTED slot for every tab (the
///   founder-reported bug parked it on Tools for tabs past index 1).

class _FakeStore {
  final Map<String, String> values = {};

  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

const _cat = QuickLogCategory(
  id: 3,
  name: 'Symptoms',
  icon: 'circle',
  colorHex: '#4ECDC4',
  isDefault: true,
  sortOrder: 0,
);

const _recent = QuickLogEntry(
  id: 9,
  categoryId: 3,
  body: 'Brain fog',
  chips: '',
  manualText: '',
  timestamp: 123,
);

/// Backend whose sync pull never lands: the widget under test stays
/// in its first-frame state (seed or skeleton) for the whole test.
TabsBackend _stalledBackend() {
  final store = FakeSessionStore()..token = 'test-token';
  final client = MockClient((_) => Completer<http.Response>().future);
  return TabsBackend(client: client, sessionStore: store);
}

/// Vera BLOCKING 2 helper: every read fails fast (500), while a POST
/// to `/api/ai/suggestions` would succeed — and is counted. If any
/// stale-gate path fires the POST, the count proves it.
TabsBackend _failingBackend({required void Function() onSuggestionsPost}) {
  final store = FakeSessionStore()..token = 'test-token';
  final client = MockClient((request) async {
    if (request.url.path == '/api/ai/suggestions') {
      onSuggestionsPost();
      return http.Response('{"result":["Brain Fog"]}', 200);
    }
    return http.Response('server error', 500);
  });
  return TabsBackend(client: client, sessionStore: store);
}

/// Vera BLOCKING 2 positive control: the sync pull succeeds with a
/// real unlimited membership + one category; suggestions POSTs are
/// counted and return one chip.
TabsBackend _succeedingBackend({required void Function() onSuggestionsPost}) {
  final store = FakeSessionStore()..token = 'test-token';
  final client = MockClient((request) async {
    if (request.url.path == '/api/ai/suggestions') {
      onSuggestionsPost();
      return http.Response('{"result":["Brain Fog"]}', 200);
    }
    if (request.url.path == '/api/sync/pull') {
      return http.Response(
        jsonEncode({
          'entries': <dynamic>[],
          'categories': [_cat.toSyncJson()],
          'profile': <String, dynamic>{},
          'isUnlimited': true,
          'isAdmin': false,
        }),
        200,
      );
    }
    return http.Response('not found', 404);
  });
  return TabsBackend(client: client, sessionStore: store);
}

void main() {
  late _FakeStore store;

  setUp(() {
    store = _FakeStore();
    QuickLogCache.instance.debugReset();
    QuickLogCache.instance.debugSetStore(
      read: store.read,
      write: store.write,
      delete: store.delete,
    );
  });

  tearDown(() => QuickLogCache.instance.debugReset());

  group('QuickLogCache', () {
    test('applyLoad → snapshot carries every section', () {
      final changed = QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 4,
        isUnlimited: false,
        isAdmin: false,
        now: DateTime(2026, 10, 12, 9),
      );
      expect(changed, isTrue);
      final snap = QuickLogCache.instance.snapshot;
      expect(snap.categories.single.name, 'Symptoms');
      expect(snap.recentSuggestions.single.body, 'Brain fog');
      expect(snap.membershipKnown, isTrue);
      expect(snap.isUnlimited, isFalse);
      // (The count's date-scoping is asserted in the round-trip test
      // below, where warmFromDisk takes an explicit clock.)
    });

    test('identical re-apply reports no change (no flash rebuild)',
        () {
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 4,
        isUnlimited: true,
        isAdmin: false,
      );
      final changed = QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 4,
        isUnlimited: true,
        isAdmin: false,
      );
      expect(changed, isFalse);
    });

    test('persist → warm round-trips; stale-day count is dropped',
        () async {
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 7,
        isUnlimited: true,
        isAdmin: false,
        now: DateTime(2026, 10, 11, 22),
      );
      await QuickLogCache.instance.persist();
      expect(store.values[QuickLogCache.storageKey], isNotNull);
      // Sanity: the blob is valid JSON with the documented keys.
      final blob = jsonDecode(store.values[QuickLogCache.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['countDate'], '2026-10-11');

      QuickLogCache.instance.debugReset();
      await QuickLogCache.instance
          .warmFromDisk(now: DateTime(2026, 10, 12, 8));
      final snap = QuickLogCache.instance.snapshot;
      // Categories / recents / membership persist across days…
      expect(snap.categoriesLoaded, isTrue);
      expect(snap.recentsLoaded, isTrue);
      expect(snap.membershipKnown, isTrue);
      expect(snap.isUnlimited, isTrue);
      // …but yesterday's count must not seed a new day.
      expect(snap.todayCountLoaded, isFalse);
    });
  });

  group('QuickLogScreen first frame (round 19c)', () {
    testWidgets('cold cache: shell + skeletons, no spinner',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(backend: _stalledBackend()),
      ));
      await tester.pump();
      // Static shell is up immediately.
      expect(find.text('Quick Log'), findsOneWidget);
      expect(find.text('Categories'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      // Skeletons stand in for the loading sections…
      expect(find.byType(SkeletonBox), findsWidgets);
      // …and there is no blocking spinner anywhere on open.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Flush the stalled backend's 20s HTTP-timeout timer so the
      // test tears down clean (pre-existing teardown failure).
      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
    });

    testWidgets('warm cache: cached values + gate render instantly',
        (tester) async {
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 2,
        isUnlimited: false,
        isAdmin: false,
      );
      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(backend: _stalledBackend()),
      ));
      await tester.pump();
      expect(find.text('Symptoms'), findsWidgets);
      expect(find.text('Brain fog'), findsWidgets);
      // The CACHED gate state renders — honest Standard Access for a
      // non-member, from the first frame.
      expect(find.text('Standard Access'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Flush the stalled backend's 20s HTTP-timeout timer (above).
      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
    });
  });

  group('HistoryScreen initial load (round 19c)', () {
    testWidgets('skeleton, not a spinner', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: _stalledBackend()),
      ));
      await tester.pump();
      expect(find.text('History'), findsOneWidget);
      expect(find.byType(SkeletonBox), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Flush the stalled backend's 20s HTTP-timeout timer (above).
      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
    });
  });

  group('Account binding (round 19c fix, Vera BLOCKING 1)', () {
    test('persist stamps ownerEmail; warm as the SAME account keeps data',
        () async {
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 2,
        isUnlimited: false,
        isAdmin: false,
        ownerEmail: 'a@example.com',
      );
      await QuickLogCache.instance.persist();
      final blob = jsonDecode(store.values[QuickLogCache.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['ownerEmail'], 'a@example.com');

      QuickLogCache.instance.debugReset();
      await QuickLogCache.instance
          .warmFromDisk(currentEmail: 'a@example.com');
      final snap = QuickLogCache.instance.snapshot;
      expect(snap.categoriesLoaded, isTrue);
      expect(snap.categories.single.name, 'Symptoms');
      expect(snap.ownerEmail, 'a@example.com');
    });

    test('warm as a DIFFERENT account drops the blob (memory + disk)',
        () async {
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 2,
        isUnlimited: true,
        isAdmin: false,
        ownerEmail: 'a@example.com',
      );
      await QuickLogCache.instance.persist();
      QuickLogCache.instance.debugReset();

      await QuickLogCache.instance
          .warmFromDisk(currentEmail: 'b@example.com');
      final snap = QuickLogCache.instance.snapshot;
      expect(snap.categoriesLoaded, isFalse);
      expect(snap.recentsLoaded, isFalse);
      expect(snap.membershipKnown, isFalse);
      expect(snap.todayCountLoaded, isFalse);
      // The other account's blob is gone from disk, and the cache is
      // now bound to the new account.
      expect(store.values.containsKey(QuickLogCache.storageKey), isFalse);
      expect(QuickLogCache.instance.ownerEmail, 'b@example.com');
    });

    test('legacy blob with no owner is dropped once an account is known',
        () async {
      // Pre-binding blobs carry no ownerEmail: untrusted by default.
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 2,
        isUnlimited: false,
        isAdmin: false,
      );
      await QuickLogCache.instance.persist();
      QuickLogCache.instance.debugReset();
      await QuickLogCache.instance
          .warmFromDisk(currentEmail: 'b@example.com');
      expect(QuickLogCache.instance.snapshot.categoriesLoaded, isFalse);
    });

    test('clearIfOwnerMismatch: same account keeps, different drops + binds',
        () async {
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 2,
        isUnlimited: false,
        isAdmin: false,
        ownerEmail: 'a@example.com',
      );
      expect(
          await QuickLogCache.instance
              .clearIfOwnerMismatch('a@example.com'),
          isFalse);
      expect(QuickLogCache.instance.snapshot.categoriesLoaded, isTrue);

      expect(
          await QuickLogCache.instance
              .clearIfOwnerMismatch('b@example.com'),
          isTrue);
      final snap = QuickLogCache.instance.snapshot;
      expect(snap.categoriesLoaded, isFalse);
      expect(snap.recentsLoaded, isFalse);
      expect(snap.membershipKnown, isFalse);
      // Bound to B now: B's next load stamps B as the blob owner.
      expect(QuickLogCache.instance.ownerEmail, 'b@example.com');
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 1,
        isUnlimited: false,
        isAdmin: false,
      );
      await QuickLogCache.instance.persist();
      final blob = jsonDecode(store.values[QuickLogCache.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['ownerEmail'], 'b@example.com');
    });

    test('HomeDataCache parity: warm + login-hook mismatch both drop',
        () async {
      final homeStore = _FakeStore();
      HomeDataCache.instance.debugSetStore(
        read: homeStore.read,
        write: homeStore.write,
        delete: homeStore.delete,
      );
      HomeDataCache.instance.debugReset();
      addTearDown(() => HomeDataCache.instance.debugReset());

      HomeDataCache.instance.applyVitals(
        const TodayVitals(heartRate: 72, logCountToday: 3),
        ownerEmail: 'a@example.com',
      );
      HomeDataCache.instance.applyStreak(12, 30);
      await HomeDataCache.instance.persist();
      final blob = jsonDecode(homeStore.values[HomeDataCache.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['ownerEmail'], 'a@example.com');

      // Warm-time enforcement as account B.
      HomeDataCache.instance.debugReset();
      await HomeDataCache.instance
          .warmFromDisk(currentEmail: 'b@example.com');
      expect(HomeDataCache.instance.snapshot.vitalsLoaded, isFalse);
      expect(HomeDataCache.instance.snapshot.streakLoaded, isFalse);
      expect(
          homeStore.values.containsKey(HomeDataCache.storageKey), isFalse);

      // Login-hook enforcement as account B over an in-memory A seed.
      HomeDataCache.instance.applyVitals(
        const TodayVitals(heartRate: 72),
        ownerEmail: 'a@example.com',
      );
      expect(
          await HomeDataCache.instance
              .clearIfOwnerMismatch('b@example.com'),
          isTrue);
      expect(HomeDataCache.instance.snapshot.vitalsLoaded, isFalse);
      expect(HomeDataCache.instance.ownerEmail, 'b@example.com');
    });

    testWidgets(
        'warm cache as A → login as B → first frame shows skeletons, '
        'never A\'s rows', (tester) async {
      // Warm cache as account A (exactly what a cold start as A left
      // behind: A's categories, A's recent row, A's Standard gate).
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 2,
        isUnlimited: false,
        isAdmin: false,
        ownerEmail: 'a@example.com',
      );
      // Login as account B — the exact calls the login-success hook
      // in main.dart makes before the shell mounts.
      await QuickLogCache.instance.clearIfOwnerMismatch('b@example.com');
      await HomeDataCache.instance.clearIfOwnerMismatch('b@example.com');

      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(backend: _stalledBackend()),
      ));
      await tester.pump();
      // NONE of A's data may appear — not the category, not the
      // recent row, not A's cached gate state.
      expect(find.text('Symptoms'), findsNothing);
      expect(find.text('Brain fog'), findsNothing);
      expect(find.text('Standard Access'), findsNothing);
      // The first frame is the shell + skeletons, no spinner.
      expect(find.text('Quick Log'), findsOneWidget);
      expect(find.byType(SkeletonBox), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Flush the stalled backend's 20s HTTP-timeout timer (above).
      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
    });
  });

  group('AI gate freshness (round 19c fix, Vera BLOCKING 2)', () {
    testWidgets(
        'warm cache isUnlimited=true + failing backend → no suggestions '
        'POST can fire before the first fresh refresh completes',
        (tester) async {
      var posts = 0;
      // Visual seed: cached unlimited membership (stale gate).
      QuickLogCache.instance.applyLoad(
        categories: const [_cat],
        recentSuggestions: const [_recent],
        todayCount: 1,
        isUnlimited: true,
        isAdmin: false,
      );
      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(
          backend: _failingBackend(onSuggestionsPost: () => posts++),
        ),
      ));
      // Let the background refresh run — it FAILS (500s), so no
      // successful membership fetch ever completes this session.
      await tester.pump();
      await tester.pump();

      // The cached tray still RENDERS (the point of 19c): the Load
      // Suggestions action is on screen…
      expect(find.text('Load Suggestions'), findsOneWidget);
      // …but disabled while the gate is stale.
      final button = tester.widget<TextButton>(find.ancestor(
        of: find.text('Load Suggestions'),
        matching: find.byType(TextButton),
      ));
      expect(button.onPressed, isNull);

      // Try every pre-refresh action anyway: tap Load, tap the
      // category (auto-fetch path), wait out the tap's fetch delay.
      await tester.tap(find.text('Load Suggestions'),
          warnIfMissed: false);
      await tester.tap(find.text('Symptoms').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(posts, 0,
          reason: 'no POST /api/ai/suggestions may fire on a stale '
              'cached gate');
    });

    testWidgets(
        'positive control: after a fresh successful membership fetch, '
        'Load Suggestions DOES post', (tester) async {
      var posts = 0;
      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(
          backend: _succeedingBackend(onSuggestionsPost: () => posts++),
        ),
      ));
      // Fresh refresh lands: real unlimited membership, gate opens.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('Load Suggestions'), findsOneWidget);
      final button = tester.widget<TextButton>(find.ancestor(
        of: find.text('Load Suggestions'),
        matching: find.byType(TextButton),
      ));
      expect(button.onPressed, isNotNull);

      await tester.tap(find.text('Load Suggestions'));
      await tester.pump();
      await tester.pump();
      expect(posts, 1);
      expect(find.text('Brain Fog'), findsWidgets);
    });
  });

  group('NavDock pill audit (round 19c)', () {
    // For every tab, the pill's center must sit on that tab's own
    // icon center. Before the fix, slots 2–4 clamped to slot 1
    // (Tools) because the controller was bounded 0–1.
    for (final (tab, icon) in <(DockTab, IconData)>[
      (DockTab.home, Icons.home),
      (DockTab.tools, Icons.assignment),
      (DockTab.quickLog, Icons.edit),
      (DockTab.heart, Icons.favorite),
      (DockTab.settings, Icons.settings),
    ]) {
      testWidgets('pill centers on $tab', (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: NavDock(selected: tab, onSelect: (_) {}),
            ),
          ),
        ));
        await tester.pump();
        final pill = find.byKey(const ValueKey('dock_selection_pill'));
        final pillCenter = tester.getCenter(pill).dx;
        final iconCenter = tester
            .getCenter(find.descendant(
              of: find.byType(NavDock),
              matching: find.byIcon(icon),
            ))
            .dx;
        expect((pillCenter - iconCenter).abs(), lessThan(1.0),
            reason: 'pill must center on the $tab slot, not Tools');
      });
    }

    testWidgets('quick-log ring shows only when Quick Log is selected',
        (tester) async {
      Widget dock(DockTab tab) => MaterialApp(
            home: Scaffold(body: NavDock(selected: tab, onSelect: (_) {})),
          );
      await tester.pumpWidget(dock(DockTab.home));
      await tester.pump();
      var ring = tester.widget<Container>(
          find.byKey(const ValueKey('dock_quicklog_ring')));
      expect((ring.decoration! as BoxDecoration).border!.top.color,
          Colors.transparent);
      await tester.pumpWidget(dock(DockTab.quickLog));
      await tester.pump();
      ring = tester.widget<Container>(
          find.byKey(const ValueKey('dock_quicklog_ring')));
      expect((ring.decoration! as BoxDecoration).border!.top.color,
          isNot(Colors.transparent));
    });
  });
}
