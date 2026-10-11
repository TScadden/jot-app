import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// Fake platform side for the weather-icon location flow.
class FakeLocationService extends LocationService {
  bool serviceEnabled = true;
  LocationPermission permission = LocationPermission.denied;
  LocationPermission permissionAfterRequest =
      LocationPermission.whileInUse;
  Position? position;
  int requestPermissionCalls = 0;
  int getPositionCalls = 0;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requestPermissionCalls++;
    permission = permissionAfterRequest;
    return permission;
  }

  @override
  Future<Position?> getPosition() async {
    getPositionCalls++;
    return position;
  }
}

Position _pos(double lat, double lon) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime(2026, 10, 11),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// Mock HTTP client. IP path returns 61°F; the Open-Meteo GPS path
/// returns 70°F so the two are distinguishable.
MockClient _weatherClient({
  void Function()? onIpInfo,
  void Function(String url)? onMeteo,
}) {
  return MockClient((request) async {
    final host = request.url.host;
    if (host == 'ipinfo.io') {
      onIpInfo?.call();
      return http.Response(
          '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
    }
    if (host == 'api.open-meteo.com') {
      onMeteo?.call(request.url.toString());
      // 61 for the IP path, 70 for the GPS path — distinguishable.
      final isGps =
          request.url.queryParameters['latitude'] == '41.0';
      final temp = isGps ? 70.2 : 61.4;
      return http.Response(
          '{"current":{"temperature_2m":$temp,"weather_code":2,"is_day":1}}',
          200);
    }
    return http.Response('not found', 404);
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required WeatherApiClient weather,
  required FakeLocationService location,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(weatherApi: weather, locationService: location),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _weatherButton() =>
    find.widgetWithIcon(IconButton, Icons.cloud);

void main() {
  group('getCurrentTempAt (GPS path)', () {
    test('uses the GPS coords in the Open-Meteo URL, skips ipinfo',
        () async {
      String? meteoUrl;
      int ipInfoHits = 0;
      final api = WeatherApiClient(
          client: _weatherClient(
              onIpInfo: () => ipInfoHits++, onMeteo: (u) => meteoUrl = u));
      final temp = await api.getCurrentTempAt(
          latitude: 41.0, longitude: -112.0, countryCode: 'US');
      expect(temp, 70);
      expect(ipInfoHits, 0);
      expect(meteoUrl, contains('latitude=41.0'));
      expect(meteoUrl, contains('longitude=-112.0'));
      expect(meteoUrl, contains('temperature_unit=fahrenheit'));
    });

    test('honors non-US country for units', () async {
      String? meteoUrl;
      final api = WeatherApiClient(
          client: _weatherClient(onMeteo: (u) => meteoUrl = u));
      await api.getCurrentTempAt(
          latitude: 51.5, longitude: -0.12, countryCode: 'GB');
      expect(meteoUrl, contains('temperature_unit=celsius'));
    });

    test('meteo failure returns null, never a fake zero', () async {
      final api = WeatherApiClient(
          client: MockClient((_) async => http.Response('err', 500)));
      expect(
          await api.getCurrentTempAt(
              latitude: 41.0, longitude: -112.0),
          isNull);
    });
  });

  group('weather icon tap → location flow', () {
    testWidgets('granted permission upgrades temp to the GPS reading',
        (tester) async {
      String? meteoUrl;
      final weather = WeatherApiClient(
          client: _weatherClient(onMeteo: (u) => meteoUrl = u));
      final location = FakeLocationService()
        ..permissionAfterRequest = LocationPermission.whileInUse
        ..position = _pos(41.0, -112.0);

      await _pumpHome(tester, weather: weather, location: location);
      // Initial IP-based temp.
      expect(find.text('61°'), findsOneWidget);

      await tester.tap(_weatherButton());
      await tester.pumpAndSettle();

      expect(location.requestPermissionCalls, 1);
      expect(location.getPositionCalls, 1);
      expect(meteoUrl, contains('latitude=41.0'));
      expect(meteoUrl, contains('longitude=-112.0'));
      // Header now shows the GPS-based temp.
      expect(find.text('70°'), findsOneWidget);
      expect(find.text('61°'), findsNothing);
    });

    testWidgets('denied permission falls back silently to IP weather',
        (tester) async {
      int ipInfoHits = 0;
      String? meteoUrl;
      final weather = WeatherApiClient(
          client: _weatherClient(
              onIpInfo: () => ipInfoHits++,
              onMeteo: (u) => meteoUrl = u));
      final location = FakeLocationService()
        ..permissionAfterRequest = LocationPermission.denied;

      await _pumpHome(tester, weather: weather, location: location);
      final hitsAfterLoad = ipInfoHits;

      await tester.tap(_weatherButton());
      await tester.pumpAndSettle();

      // Asked once, denied → no position attempt, IP fallback re-ran.
      expect(location.requestPermissionCalls, 1);
      expect(location.getPositionCalls, 0);
      expect(ipInfoHits, greaterThan(hitsAfterLoad));
      // Still showing the IP temp — no error, no fake zero.
      expect(find.text('61°'), findsOneWidget);
      expect(meteoUrl, isNot(contains('latitude=41.0')));
    });

    testWidgets('permanently denied never re-prompts, IP fallback',
        (tester) async {
      final weather =
          WeatherApiClient(client: _weatherClient());
      final location = FakeLocationService()
        ..permission = LocationPermission.deniedForever;

      await _pumpHome(tester, weather: weather, location: location);
      await tester.tap(_weatherButton());
      await tester.pumpAndSettle();

      expect(location.requestPermissionCalls, 0);
      expect(location.getPositionCalls, 0);
      expect(find.text('61°'), findsOneWidget);
    });

    testWidgets('location services off falls back to IP weather',
        (tester) async {
      final weather =
          WeatherApiClient(client: _weatherClient());
      final location = FakeLocationService()..serviceEnabled = false;

      await _pumpHome(tester, weather: weather, location: location);
      await tester.tap(_weatherButton());
      await tester.pumpAndSettle();

      expect(location.requestPermissionCalls, 0);
      expect(location.getPositionCalls, 0);
      expect(find.text('61°'), findsOneWidget);
    });

    testWidgets('position timeout falls back to IP weather',
        (tester) async {
      final weather =
          WeatherApiClient(client: _weatherClient());
      final location = FakeLocationService()
        ..permissionAfterRequest = LocationPermission.whileInUse
        ..position = null; // getPosition returns null (timeout path)

      await _pumpHome(tester, weather: weather, location: location);
      await tester.tap(_weatherButton());
      await tester.pumpAndSettle();

      expect(location.getPositionCalls, 1);
      expect(find.text('61°'), findsOneWidget);
    });
  });
}
