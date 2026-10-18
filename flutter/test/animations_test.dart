import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/animations.dart';


void main() {

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

  group('CountUpGate (once-per-day)', () {
    Future<String?> memRead(Map<String, String> m, String k) async => m[k];
    Future<void> memWrite(Map<String, String> m, String k, String v) async {
      m[k] = v;
    }

    test('first view of the day animates and persists the date', () async {
      final store = <String, String>{};
      final animate = await CountUpGate.shouldAnimate(
        read: (k) => memRead(store, k),
        write: (k, v) => memWrite(store, k, v),
        now: DateTime(2026, 10, 11, 15, 49),
      );
      expect(animate, isTrue);
      expect(store[CountUpGate.storageKey], '2026-10-11');
    });

    test('second view the same day does not animate (no double-fire)',
        () async {
      final store = <String, String>{};
      Future<bool> check() => CountUpGate.shouldAnimate(
            read: (k) => memRead(store, k),
            write: (k, v) => memWrite(store, k, v),
            now: DateTime(2026, 10, 11, 15, 49),
          );
      expect(await check(), isTrue);
      // A rebuild mid-animation re-checks: the date was already
      // persisted by the first call, so this must not re-fire.
      expect(await check(), isFalse);
      expect(await check(), isFalse);
    });

    test('a new day animates again', () async {
      final store = <String, String>{CountUpGate.storageKey: '2026-10-10'};
      final animate = await CountUpGate.shouldAnimate(
        read: (k) => memRead(store, k),
        write: (k, v) => memWrite(store, k, v),
        now: DateTime(2026, 10, 11, 0, 1),
      );
      expect(animate, isTrue);
      expect(store[CountUpGate.storageKey], '2026-10-11');
    });

    test('uses the device-local calendar date, not UTC', () async {
      final store = <String, String>{};
      // 1:30 AM local on Oct 12 (UTC would still be Oct 11).
      await CountUpGate.shouldAnimate(
        read: (k) => memRead(store, k),
        write: (k, v) => memWrite(store, k, v),
        now: DateTime(2026, 10, 12, 1, 30),
      );
      expect(store[CountUpGate.storageKey], '2026-10-12');
    });

    test('storage failure fails closed: no animation, no crash', () async {
      Future<String?> failRead(String _) async =>
          throw Exception('storage unavailable');
      Future<void> failWrite(String key, String value) async =>
          throw Exception('storage unavailable');
      expect(
        await CountUpGate.shouldAnimate(read: failRead, write: failWrite),
        isFalse,
      );
    });
  });

  group('CountUp once-per-day gating', () {
    testWidgets('animate:false renders the final value instantly',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: 72, animate: false)),
      ));
      await tester.pump();
      expect(find.text('72'), findsOneWidget);
      // No count-up pass through 0 on the way there.
      expect(find.text('0'), findsNothing);
    });

    testWidgets('animate:false shows a late-arriving value instantly',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: null, animate: false)),
      ));
      await tester.pump();
      expect(find.text('--'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: 480, animate: false)),
      ));
      await tester.pump();
      expect(find.text('480'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('animate:true still counts up (default behavior kept)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: 72, animate: true)),
      ));
      expect(find.text('0'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.text('72'), findsOneWidget);
    });

    testWidgets('VitalsStrip passes the gate through to its numbers',
        (tester) async {
      const vitals =
          TodayVitals(heartRate: 72, activeCalories: 480, logCountToday: 3);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: VitalsStrip(vitals: vitals, animateCountUps: false),
        ),
      ));
      await tester.pump();
      expect(find.text('72'), findsOneWidget);
      expect(find.text('480'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });
  });
}
