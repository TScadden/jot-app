import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
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
}
