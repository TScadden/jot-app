import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/animations.dart';

/// In-memory SecureStore fake — mirrors the one in health_connect_test.dart
/// (test files can't share it without a shared helper).
class _MemorySecureStore implements SecureStore {
  final Map<String, String> _map = {};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

/// Mirrors [_HomeScreenState._maybeCelebrateStreak]'s storage dance so the
/// once-per-milestone guarantee is tested end to end at the logic level.
Future<int?> _celebrateOnce(_MemorySecureStore store, int? current) async {
  final raw = await store.read(streakMilestoneStorageKey);
  final last = int.tryParse(raw ?? '') ?? 0;
  final milestone = nextMilestoneToCelebrate(
    currentStreak: current,
    lastCelebrated: last,
  );
  if (milestone == null) return null;
  // Persist BEFORE celebrating: a rebuild mid-burst must not re-fire.
  await store.write(streakMilestoneStorageKey, '$milestone');
  return milestone;
}

void main() {
  group('nextMilestoneToCelebrate', () {
    test('fires when crossing 7', () {
      expect(
          nextMilestoneToCelebrate(currentStreak: 7, lastCelebrated: 0), 7);
    });

    test('does not fire below the first milestone', () {
      expect(
          nextMilestoneToCelebrate(currentStreak: 6, lastCelebrated: 0), isNull);
    });

    test('fires at 30 after 7 was celebrated', () {
      expect(
          nextMilestoneToCelebrate(currentStreak: 30, lastCelebrated: 7), 30);
    });

    test('a big jump celebrates the highest crossed milestone only', () {
      expect(
          nextMilestoneToCelebrate(currentStreak: 35, lastCelebrated: 0), 30);
    });

    test('never fires on null or non-positive streaks', () {
      expect(nextMilestoneToCelebrate(currentStreak: null, lastCelebrated: 0),
          isNull);
      expect(
          nextMilestoneToCelebrate(currentStreak: 0, lastCelebrated: 0), isNull);
    });
  });

  group('milestone persistence (once per milestone)', () {
    test('fires exactly once, never re-fires on rebuild', () async {
      final store = _MemorySecureStore();
      expect(await _celebrateOnce(store, 7), 7);
      // Rebuild / reload with the same streak: silent.
      expect(await _celebrateOnce(store, 7), isNull);
      expect(await _celebrateOnce(store, 8), isNull);
    });

    test('never fires when the streak decreases', () async {
      final store = _MemorySecureStore();
      expect(await _celebrateOnce(store, 30), 30);
      expect(await _celebrateOnce(store, 5), isNull);
      // Climbing back to 30 does NOT re-celebrate.
      expect(await _celebrateOnce(store, 30), isNull);
    });

    test('malformed stored value is treated as never celebrated', () async {
      final store = _MemorySecureStore();
      await store.write(streakMilestoneStorageKey, 'garbage');
      expect(await _celebrateOnce(store, 7), 7);
    });
  });

  group('CountUp', () {
    testWidgets('tweens from 0 to the real value', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: 72)),
      ));
      expect(find.text('0'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.text('72'), findsOneWidget);
    });

    testWidgets('renders -- for a null value (never invents)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: null)),
      ));
      await tester.pump();
      expect(find.text('--'), findsOneWidget);
    });

    testWidgets('counts up when the value arrives late', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: null)),
      ));
      await tester.pump();
      expect(find.text('--'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: 480)),
      ));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.text('480'), findsOneWidget);
    });

    testWidgets('jumps instantly under reduced motion', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const CountUp(value: 72),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('72'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });
  });

  group('StaggeredEntrance', () {
    testWidgets('cascades cards in and ends fully visible', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            StaggeredEntrance(index: 0, child: Text('card0')),
            StaggeredEntrance(index: 2, child: Text('card2')),
          ]),
        ),
      ));
      await tester.pump();
      // card2 (160ms delay) is laid out but invisible before its turn.
      expect(find.byType(Opacity), findsOneWidget);
      // Two timed pumps: the first fires card2's delayed start (the
      // single end-frame samples the animation at ~0), the second lets
      // both 450ms entrances run to completion.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(Opacity), findsNothing);
      for (final ft
          in tester.widgetList<FadeTransition>(find.byType(FadeTransition))) {
        expect(ft.opacity.value, 1.0);
      }
    });

    testWidgets('renders instantly under reduced motion', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const Column(children: [
              StaggeredEntrance(index: 3, child: Text('card3')),
            ]),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('card3'), findsOneWidget);
      // No pre-start invisible wrapper around our card (route-level
      // FadeTransitions from MaterialApp don't count).
      expect(
        find.ancestor(
          of: find.text('card3'),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });
  });

  group('ConfettiOverlay', () {
    /// The burst root is the only IgnorePointer with ignoring: true in
    /// the tree (Scaffold internals use ignoring: false).
    Finder burst() => find.byWidgetPredicate(
          (w) => w is IgnorePointer && w.ignoring,
        );

    testWidgets('shows the burst and removes it', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => ConfettiOverlay.show(context),
              child: const Text('celebrate'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('celebrate'));
      await tester.pump();
      expect(burst(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 3000));
      expect(burst(), findsNothing);
    });

    testWidgets('skipped entirely under reduced motion', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => ConfettiOverlay.show(context),
                child: const Text('celebrate'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('celebrate'));
      await tester.pump();
      expect(burst(), findsNothing);
    });
  });

  group('NavDock springy pill', () {
    testWidgets('pill glides to the newly selected tab', (tester) async {
      var tab = DockTab.home;
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: NavDock(
              selected: tab,
              onSelect: (t) => setState(() => tab = t),
            ),
          ),
        ),
      ));
      final pill = find.byKey(const ValueKey('dock_selection_pill'));
      expect(pill, findsOneWidget);
      final leftBefore = tester.getTopLeft(pill).dx;
      await tester.tap(find.byIcon(Icons.favorite));
      await tester.pumpAndSettle();
      final leftAfter = tester.getTopLeft(pill).dx;
      expect(leftAfter, greaterThan(leftBefore));
    });

    testWidgets('pill jumps instantly under reduced motion', (tester) async {
      var tab = DockTab.home;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: NavDock(
                selected: tab,
                onSelect: (t) => setState(() => tab = t),
              ),
            ),
          ),
        ),
      ));
      final pill = find.byKey(const ValueKey('dock_selection_pill'));
      final leftBefore = tester.getTopLeft(pill).dx;
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump();
      final leftAfter = tester.getTopLeft(pill).dx;
      expect(leftAfter, greaterThan(leftBefore));
    });
  });

  group('AnimatedWeatherIcon', () {
    testWidgets('renders every condition kind without crashing',
        (tester) async {
      for (final code in <int?>[0, 2, 3, 61, 71, 95, null]) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: AnimatedWeatherIcon(
              key: const Key('wxicon'),
              weatherCode: code,
              isDay: true,
            ),
          ),
        ));
        // Advance the loop a little; never pumpAndSettle (it repeats).
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.descendant(
            of: find.byKey(const Key('wxicon')),
            matching: find.byType(CustomPaint),
          ),
          findsOneWidget,
        );
      }
      // Night variant.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AnimatedWeatherIcon(
            key: Key('wxicon'),
            weatherCode: 0,
            isDay: false,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.descendant(
          of: find.byKey(const Key('wxicon')),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });
  });

  group('weather condition API (round 14)', () {
    MockClient client(String body, {int status = 200}) {
      return MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
        }
        return http.Response(body, status);
      });
    }

    test('getCurrentWeatherCondition returns temp + code + day flag',
        () async {
      final api = WeatherApiClient(
          client: client(
              '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}'));
      final c = await api.getCurrentWeatherCondition();
      expect(c.temp, 61);
      expect(c.countryCode, 'US');
      expect(c.weatherCode, 2);
      expect(c.isDay, isTrue);
    });

    test('getCurrentWeatherCondition is null-safe on failure', () async {
      final api = WeatherApiClient(client: client('boom', status: 500));
      final c = await api.getCurrentWeatherCondition();
      expect(c.temp, isNull);
      expect(c.weatherCode, isNull);
    });

    test('getConditionAt returns the full record for GPS coords', () async {
      final api = WeatherApiClient(
          client: client(
              '{"current":{"temperature_2m":58.0,"weather_code":61,"is_day":0}}'));
      final c = await api.getConditionAt(
          latitude: 40.3, longitude: -111.7, countryCode: 'US');
      expect(c.temp, 58);
      expect(c.weatherCode, 61);
      expect(c.isDay, isFalse);
    });

    test('getCurrentTempAt still returns just the temp', () async {
      final api = WeatherApiClient(
          client: client(
              '{"current":{"temperature_2m":58.0,"weather_code":61,"is_day":0}}'));
      expect(await api.getCurrentTempAt(latitude: 40.3, longitude: -111.7),
          58);
    });
  });
}
