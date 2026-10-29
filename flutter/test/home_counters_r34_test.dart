import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/event_counter_rotator.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

/// Round 34 — active event counters on Home.
///
/// Native trace (TodayScreen.kt section 2): the counters live on the
/// RIGHT of the streak row as a rotating pager — "Since/Until {name}"
/// + "{days} Days" + page dots — auto-advancing every 10s when there
/// are several, filtered to `!isArchived` in stored (Settings list)
/// order. The 📅 line at TodayScreen.kt:461 is the zero-counter
/// fallback and its `firstEvent` is a reminder-derived
/// `UpcomingEventItem`, not a counter.
///
/// Unified predicate (Oct 28, 2026): the Flutter filter is
/// `EventCounterItem.isActive` — neither archived NOR
/// delete-stamped — so a stamp-only row never shows on Home.

EventCounterItem _counter({
  String id = 'c1',
  String name = 'Alpha',
  required DateTime target,
  bool isUp = false,
  bool autoUp = false,
  bool isFavorite = false,
  bool isArchived = false,
  int? deletedAt,
}) =>
    EventCounterItem(
      id: id,
      name: name,
      targetDate: target.millisecondsSinceEpoch,
      isUp: isUp,
      autoUp: autoUp,
      isFavorite: isFavorite,
      isArchived: isArchived,
      deletedAt: deletedAt,
    );

/// Local midnight [days] away from [from]'s calendar day.
DateTime _midnightPlus(DateTime from, int days) =>
    DateTime(from.year, from.month, from.day + days);

void main() {
  group('EventCounterItem day-boundary math (local calendar days)', () {
    final now = DateTime(2026, 10, 13, 12, 0); // Tue Oct 13, noon

    test('target today at midnight → 0 days until', () {
      final c = _counter(target: DateTime(2026, 10, 13));
      expect(c.calendarDayDiff(now: now), 0);
      expect(c.daysLabel(now: now), '0 days until');
      expect(c.todayDisplay(now: now), (days: 0, up: false));
    });

    test('target today late evening → still 0 days until', () {
      final c = _counter(target: DateTime(2026, 10, 13, 23, 59));
      expect(c.calendarDayDiff(now: now), 0);
      expect(c.daysLabel(now: now), '0 days until');
    });

    test('target tomorrow at midnight → 1 day until', () {
      final c = _counter(target: DateTime(2026, 10, 14));
      expect(c.calendarDayDiff(now: now), -1);
      expect(c.daysLabel(now: now), '1 day until');
      expect(c.todayDisplay(now: now), (days: 1, up: false));
    });

    test('target yesterday 01:00 → 1 calendar day, not 0', () {
      // The old ms implementation divided (midnight − yesterday
      // 01:00) = 23h by 24h and read 0. Calendar days read 1.
      final c = _counter(target: DateTime(2026, 10, 12, 1, 0));
      expect(c.calendarDayDiff(now: now), 1);
      expect(c.daysLabel(now: now), '1 day until');
      // Native Today clamps a past non-autoUp counter to 0.
      expect(c.todayDisplay(now: now), (days: 0, up: false));
    });

    test('just after midnight: target 23:59 yesterday → 1 day', () {
      final justAfter = DateTime(2026, 10, 13, 0, 1);
      final c = _counter(target: DateTime(2026, 10, 12, 23, 59));
      expect(c.calendarDayDiff(now: justAfter), 1);
    });

    test('just before midnight: target 00:01 tomorrow → 1 day until',
        () {
      final justBefore = DateTime(2026, 10, 12, 23, 59);
      final c = _counter(target: DateTime(2026, 10, 13, 0, 1));
      expect(c.calendarDayDiff(now: justBefore), -1);
      expect(c.daysLabel(now: justBefore), '1 day until');
    });

    test('autoUp flips to since once the target day has passed', () {
      final c = _counter(target: DateTime(2026, 10, 12, 23, 59), autoUp: true);
      expect(c.countsUp(now: now), isTrue);
      expect(c.daysLabel(now: now), '1 day since');
      expect(c.todayDisplay(now: now), (days: 1, up: true));
    });

    test('autoUp does NOT flip on the target day itself', () {
      final c = _counter(target: DateTime(2026, 10, 13, 9, 0), autoUp: true);
      expect(c.countsUp(now: now), isFalse);
      expect(c.todayDisplay(now: now), (days: 0, up: false));
    });

    test('explicit isUp counts since even for a future target; '
        'Today clamps the directed count to 0', () {
      final c = _counter(target: DateTime(2026, 10, 16), isUp: true);
      expect(c.daysLabel(now: now), '3 days since');
      expect(c.todayDisplay(now: now), (days: 0, up: true));
    });

    test('explicit isUp for a past target counts the real days', () {
      final c = _counter(target: DateTime(2026, 10, 10, 15, 30), isUp: true);
      expect(c.daysLabel(now: now), '3 days since');
      expect(c.todayDisplay(now: now), (days: 3, up: true));
    });

    test('month boundary: Sep 30 → Oct 13 is 13 days', () {
      final c = _counter(target: DateTime(2026, 9, 30), isUp: true);
      expect(c.calendarDayDiff(now: now), 13);
    });
  });

  group('activeEventCounters', () {
    test('excludes archived, preserves Settings list order', () {
      final a = _counter(id: 'a', target: DateTime(2026, 11, 1));
      final b = _counter(
          id: 'b', target: DateTime(2026, 10, 20), isArchived: true);
      final c = _counter(id: 'c', target: DateTime(2026, 10, 15));
      final active = activeEventCounters([a, b, c]);
      expect(active.map((x) => x.id).toList(), ['a', 'c']);
    });

    test('all archived → empty (Home renders no slot)', () {
      final b = _counter(target: DateTime(2026, 10, 20), isArchived: true);
      expect(activeEventCounters([b]), isEmpty);
    });

    test('stamp-only (deletedAt set, isArchived false) → excluded '
        '(unified predicate)', () {
      final b = _counter(
          target: DateTime(2026, 10, 20),
          deletedAt: DateTime(2026, 10, 19).millisecondsSinceEpoch);
      expect(b.isArchived, isFalse);
      expect(b.isActive, isFalse);
      expect(activeEventCounters([b]), isEmpty);
    });

    test('both marks → excluded; neither mark → kept', () {
      final both = _counter(
          id: 'both',
          target: DateTime(2026, 10, 20),
          isArchived: true,
          deletedAt: DateTime(2026, 10, 19).millisecondsSinceEpoch);
      final neither =
          _counter(id: 'neither', target: DateTime(2026, 10, 20));
      expect(activeEventCounters([both, neither]).map((c) => c.id),
          ['neither']);
    });

    test('empty → empty', () {
      expect(activeEventCounters(const []), isEmpty);
    });
  });

  group('EventCounterRotator', () {
    final now = DateTime(2026, 10, 13, 12, 0);
    EventCounterItem alpha() =>
        _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7));
    EventCounterItem beta() => _counter(
        id: 'b', name: 'Beta', target: _midnightPlus(now, -3), isUp: true);
    EventCounterItem gamma() =>
        _counter(id: 'g', name: 'Gamma', target: _midnightPlus(now, 1));

    Future<void> pumpRotator(
      WidgetTester tester,
      List<EventCounterItem> counters, {
      VoidCallback? onTap,
      bool reducedMotion = false,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: NotelColors.background,
          body: Center(
            child: SizedBox(
              width: 400,
              child: MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: EventCounterRotator(
                  counters: counters,
                  now: now,
                  onTap: onTap,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('single counter is static: no pager, no dots, no timer',
        (tester) async {
      await pumpRotator(tester, [alpha()]);
      expect(find.text('Until Alpha'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('Days'), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
      // No timer: time passing changes nothing.
      await tester.pump(const Duration(seconds: 35));
      expect(find.text('Until Alpha'), findsOneWidget);
    });

    testWidgets('multiple counters start on the first in list order',
        (tester) async {
      await pumpRotator(tester, [alpha(), beta(), gamma()]);
      expect(find.text('Until Alpha'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('auto-advances every 10s and wraps in order',
        (tester) async {
      await pumpRotator(tester, [alpha(), beta(), gamma()]);
      expect(find.text('Until Alpha'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Since Beta'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Until Gamma'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Until Alpha'), findsOneWidget);
    });

    testWidgets('rotation pauses while the user interacts, then resumes',
        (tester) async {
      await pumpRotator(tester, [alpha(), beta()]);
      final center = tester.getCenter(find.byType(EventCounterRotator));
      final gesture = await tester.startGesture(center);
      // Holding a finger on the slot: two full intervals pass with
      // no advance.
      await tester.pump(const Duration(seconds: 21));
      expect(find.text('Until Alpha'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      // A fresh interval runs after the interaction ends.
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Until Alpha'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Since Beta'), findsOneWidget);
    });

    testWidgets('reduced motion: no auto-advance, manual swipe works',
        (tester) async {
      await pumpRotator(tester, [alpha(), beta()], reducedMotion: true);
      await tester.pump(const Duration(seconds: 35));
      expect(find.text('Until Alpha'), findsOneWidget);
      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Since Beta'), findsOneWidget);
      await tester.pump(const Duration(seconds: 20));
      expect(find.text('Since Beta'), findsOneWidget);
    });

    testWidgets('dots show one per counter under the count',
        (tester) async {
      await pumpRotator(tester, [alpha(), beta(), gamma()]);
      final dots = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).shape == BoxShape.circle)
          .toList();
      expect(dots.length, 3);
    });

    testWidgets('tap fires the callback', (tester) async {
      var taps = 0;
      await pumpRotator(tester, [alpha(), beta()], onTap: () => taps++);
      await tester.tap(find.byType(EventCounterRotator));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('HomeDataCache counters (round 34)', () {
    final store = <String, String>{};

    setUp(() {
      store.clear();
      HomeDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
      HomeDataCache.instance.debugReset();
    });

    tearDown(() => HomeDataCache.instance.debugReset());

    test('applyCounters stores and reports change once', () {
      final a = _counter(id: 'a', target: DateTime(2026, 11, 1));
      expect(HomeDataCache.instance.applyCounters([a]), isTrue);
      expect(HomeDataCache.instance.applyCounters([a]), isFalse);
      final s = HomeDataCache.instance.snapshot;
      expect(s.countersLoaded, isTrue);
      expect(s.counters.single.id, 'a');
    });

    test('persist + warmFromDisk round-trips the counters', () async {
      final a = _counter(id: 'a', target: DateTime(2026, 11, 1));
      final b = _counter(
          id: 'b', target: DateTime(2026, 10, 1), isUp: true);
      HomeDataCache.instance.applyCounters([a, b]);
      await HomeDataCache.instance.persist();
      HomeDataCache.instance.debugReset();
      expect(HomeDataCache.instance.snapshot.countersLoaded, isFalse);
      await HomeDataCache.instance.warmFromDisk();
      final s = HomeDataCache.instance.snapshot;
      expect(s.countersLoaded, isTrue);
      expect(s.counters.map((c) => c.id).toList(), ['a', 'b']);
    });

    test('account mismatch drops the cached counters', () async {
      final a = _counter(id: 'a', target: DateTime(2026, 11, 1));
      HomeDataCache.instance
          .applyCounters([a], ownerEmail: 'first@example.com');
      final dropped = await HomeDataCache.instance
          .clearIfOwnerMismatch('second@example.com');
      expect(dropped, isTrue);
      expect(HomeDataCache.instance.snapshot.countersLoaded, isFalse);
      expect(HomeDataCache.instance.snapshot.counters, isEmpty);
    });

    test('stale counters (older than 7 days) do not seed', () {
      final a = _counter(id: 'a', target: DateTime(2026, 11, 1));
      HomeDataCache.instance.applyCounters([a],
          now: DateTime.now().subtract(const Duration(days: 8)));
      expect(HomeDataCache.instance.snapshot.countersLoaded, isFalse);
    });
  });

  group('HomeScreen counters (round 34)', () {
    tearDown(() => HomeDataCache.instance.debugReset());

    Map<String, dynamic> pullWith(List<Map<String, dynamic>> counters) => {
          'profile': {'eventCounters': jsonEncode(counters)},
        };

    Map<String, dynamic> counterMap({
      required String id,
      required String name,
      required DateTime target,
      bool isUp = false,
      bool autoUp = false,
      bool isArchived = false,
      int? deletedAt,
    }) =>
        {
          'id': id,
          'name': name,
          'targetDate': target.millisecondsSinceEpoch,
          'isUp': isUp,
          'autoUp': autoUp,
          'isFavorite': false,
          'isArchived': isArchived,
          if (deletedAt != null) 'deletedAt': deletedAt,
        };

    WeatherApiClient weather() => WeatherApiClient(
          client: MockClient((request) async {
            if (request.url.host == 'ipinfo.io') {
              return http.Response(
                  '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
                  200);
            }
            if (request.url.host == 'api.open-meteo.com') {
              return http.Response(
                  '{"current":{"temperature_2m":60.0,"weather_code":2,"is_day":1}}',
                  200);
            }
            return http.Response('not found', 404);
          }),
        );

    Future<void> pumpHome(
      WidgetTester tester,
      _FakePullBackend backend,
    ) async {
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: weather(),
          tabsBackend: backend,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    testWidgets('shows active counters from the pull, archived excluded',
        (tester) async {
      final now = DateTime.now();
      final backend = _FakePullBackend(pullWith([
        counterMap(
            id: 'a', name: 'AlphaTrip', target: _midnightPlus(now, 7)),
        counterMap(
            id: 'b',
            name: 'HiddenOld',
            target: _midnightPlus(now, -2),
            isArchived: true),
        counterMap(
            id: 'c',
            name: 'BetaStart',
            target: _midnightPlus(now, -3),
            isUp: true),
      ]));
      await pumpHome(tester, backend);
      expect(find.text('Until AlphaTrip'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('HiddenOld'), findsNothing);
      expect(find.textContaining('HiddenOld'), findsNothing);
      // Rotates to the second active counter in list order.
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Since BetaStart'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('zero active counters → no slot renders at all',
        (tester) async {
      final now = DateTime.now();
      final backend = _FakePullBackend(pullWith([
        counterMap(
            id: 'b',
            name: 'HiddenOld',
            target: _midnightPlus(now, -2),
            isArchived: true),
      ]));
      await pumpHome(tester, backend);
      expect(find.byType(EventCounterRotator), findsNothing);
      expect(find.text('Days'), findsNothing);
    });

    testWidgets('a stamp-only counter (deletedAt set, isArchived '
        'false) does NOT show on Home', (tester) async {
      final now = DateTime.now();
      final backend = _FakePullBackend(pullWith([
        counterMap(
            id: 'a', name: 'AlphaTrip', target: _midnightPlus(now, 7)),
        counterMap(
            id: 's',
            name: 'StampOnly',
            target: _midnightPlus(now, 4),
            deletedAt: _midnightPlus(now, -1).millisecondsSinceEpoch),
      ]));
      await pumpHome(tester, backend);
      expect(find.text('Until AlphaTrip'), findsOneWidget);
      expect(find.textContaining('StampOnly'), findsNothing);
      // It never rotates in either: the only counter in the pager
      // is the active one (single-counter slot, no rotation).
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Until AlphaTrip'), findsOneWidget);
      expect(find.textContaining('StampOnly'), findsNothing);
    });

    testWidgets('empty pull counters → no slot renders', (tester) async {
      final backend = _FakePullBackend(pullWith(const []));
      await pumpHome(tester, backend);
      expect(find.byType(EventCounterRotator), findsNothing);
    });

    testWidgets('cached counters render before the pull resolves',
        (tester) async {
      final now = DateTime.now();
      HomeDataCache.instance.debugSetStore(
        read: (k) async => null,
        write: (k, v) async {},
        delete: (k) async {},
      );
      HomeDataCache.instance.applyCounters([
        _counter(
            id: 'a', name: 'CachedOne', target: _midnightPlus(now, 5)),
      ]);
      // A backend whose pull never completes: only the cache can
      // put a counter on screen.
      final backend = _FakePullBackend(null, hang: true);
      await pumpHome(tester, backend);
      expect(find.text('Until CachedOne'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('tap opens Settings on the Event Counters page; '
        'back returns to Home', (tester) async {
      final now = DateTime.now();
      final backend = _FakePullBackend(pullWith([
        counterMap(
            id: 'a', name: 'AlphaTrip', target: _midnightPlus(now, 7)),
      ]));
      await pumpHome(tester, backend);
      expect(find.text('Until AlphaTrip'), findsOneWidget);
      await tester.tap(find.byType(EventCounterRotator));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Event Counters'), findsOneWidget);
      expect(find.text('Add New Counter'), findsOneWidget);
      // The pushed Settings opened directly on the counters page:
      // its back arrow pops the route (round-34 _back behavior).
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.text('Until AlphaTrip'), findsOneWidget);
      // Returning re-reads the counters from a fresh pull.
      expect(backend.invalidateCount, greaterThan(0));
    });
  });
}

/// TabsBackend whose sync pull is a fixed body (the same shape
/// Settings round 29 consumes). [hang] makes the pull never resolve,
/// proving the Home cache seeds the first frame on its own.
class _FakePullBackend extends TabsBackend {
  final Map<String, dynamic>? body;
  final bool hang;
  int invalidateCount = 0;

  _FakePullBackend(this.body, {this.hang = false})
      : super(sessionStore: FakeSessionStore());

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() {
    if (hang) return Completer<Map<String, dynamic>?>().future;
    return Future.value(body);
  }

  @override
  void invalidateSyncPull() {
    invalidateCount++;
  }
}
