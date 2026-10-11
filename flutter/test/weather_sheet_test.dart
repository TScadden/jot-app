import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/weather_sheet.dart';

/// Fake platform side (same shape as weather_location_test.dart's).
class _FakeLocationService extends LocationService {
  LocationPermission permission = LocationPermission.denied;
  LocationPermission permissionAfterRequest =
      LocationPermission.whileInUse;

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    permission = permissionAfterRequest;
    return permission;
  }

  @override
  Future<Position?> getPosition() async => null;
}

const _meteoOk = '{"current":{"temperature_2m":61.4,"weather_code":2,'
    '"is_day":1,"surface_pressure":1012.3,"uv_index":4.2,'
    '"relative_humidity_2m":38,"wind_speed_10m":7.5}}';

MockClient _mockClient({
  String ipInfoBody =
      '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
  int ipInfoStatus = 200,
  String meteoBody = _meteoOk,
  int meteoStatus = 200,
}) {
  return MockClient((request) async {
    if (request.url.host == 'ipinfo.io') {
      return http.Response(ipInfoBody, ipInfoStatus);
    }
    if (request.url.host == 'api.open-meteo.com') {
      return http.Response(meteoBody, meteoStatus);
    }
    return http.Response('not found', 404);
  });
}

Future<void> _openSheet(
  WidgetTester tester,
  WeatherApiClient api,
  _FakeLocationService location,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showWeatherSheet(
              context: context,
              weatherApi: api,
              locationService: location,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
}

void main() {
  testWidgets('shows loading state first', (tester) async {
    final api = WeatherApiClient(client: _mockClient());
    await _openSheet(tester, api, _FakeLocationService());
    expect(find.text('Fetching local weather...'), findsOneWidget);
  });

  testWidgets('loaded sheet shows all five rows with values',
      (tester) async {
    final api = WeatherApiClient(client: _mockClient());
    await _openSheet(tester, api, _FakeLocationService());
    await tester.pumpAndSettle();
    expect(find.text('Orem'), findsOneWidget);
    expect(find.text('Partly Cloudy'), findsOneWidget);
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.text('61°F'), findsOneWidget);
    expect(find.text('Humidity'), findsOneWidget);
    expect(find.text('38%'), findsOneWidget);
    expect(find.text('Wind Velocity'), findsOneWidget);
    expect(find.text('7.5'), findsOneWidget);
    expect(find.text('mph'), findsOneWidget);
    expect(find.text('UV Index'), findsOneWidget);
    expect(find.text('4.2'), findsOneWidget);
    expect(find.text('Barometric Pressure'), findsOneWidget);
    expect(find.text('1012'), findsOneWidget);
    expect(find.text('hPa'), findsOneWidget);
  });

  testWidgets('missing fields render as "--", never zeros', (tester) async {
    final api = WeatherApiClient(
      client: _mockClient(
        meteoBody:
            '{"current":{"temperature_2m":61.4,"weather_code":0,"is_day":1}}',
      ),
    );
    await _openSheet(tester, api, _FakeLocationService());
    await tester.pumpAndSettle();
    // Humidity / wind / UV / pressure all missing → four "--" values.
    expect(find.text('--'), findsNWidgets(4));
    expect(find.text('0%'), findsNothing);
  });

  testWidgets('unavailable state with Try again', (tester) async {
    final api = WeatherApiClient(
      client: _mockClient(meteoStatus: 500),
    );
    await _openSheet(tester, api, _FakeLocationService());
    await tester.pumpAndSettle();
    expect(
        find.text("Couldn't load weather right now"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('rationale card shows when permission not granted',
      (tester) async {
    final api = WeatherApiClient(client: _mockClient());
    await _openSheet(tester, api, _FakeLocationService());
    await tester.pumpAndSettle();
    expect(
        find.text('Use your location for weather?'), findsOneWidget);
    expect(find.text('Share location'), findsOneWidget);
    // "Not now" dismisses it.
    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(
        find.text('Use your location for weather?'), findsNothing);
  });

  testWidgets('rationale hidden when permission already granted',
      (tester) async {
    final api = WeatherApiClient(client: _mockClient());
    final location = _FakeLocationService()
      ..permission = LocationPermission.whileInUse;
    await _openSheet(tester, api, location);
    await tester.pumpAndSettle();
    expect(
        find.text('Use your location for weather?'), findsNothing);
  });

  testWidgets('tapping Temperature row opens the info sheet',
      (tester) async {
    final api = WeatherApiClient(client: _mockClient());
    await _openSheet(tester, api, _FakeLocationService());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Temperature'));
    await tester.pumpAndSettle();
    expect(find.text('Optimal Sleep Range'), findsOneWidget);
    expect(find.text('Why Temperature Matters'), findsOneWidget);
  });

  testWidgets('high UV shows the High risk badge and warning',
      (tester) async {
    final api = WeatherApiClient(
      client: _mockClient(
        meteoBody:
            '{"current":{"temperature_2m":90.0,"weather_code":0,"is_day":1,'
            '"uv_index":8.5}}',
      ),
    );
    await _openSheet(tester, api, _FakeLocationService());
    await tester.pumpAndSettle();
    expect(find.text('High risk'), findsOneWidget);
    expect(find.text('High UV levels detected. Consider sun protection.'),
        findsOneWidget);
  });
}
