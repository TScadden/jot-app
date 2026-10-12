import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
