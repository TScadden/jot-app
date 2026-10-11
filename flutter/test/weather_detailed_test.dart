import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/weather_api.dart';

/// Round 11 tests:
/// 1. The NYC wrong-city fallback is gone — ipinfo 2xx without a usable
///    `loc` yields null (icon-only header), never another city's temp.
/// 2. `getDetailedWeather` parses the full field set and maps missing
///    fields to null (sheet renders "--").

MockClient _mockDetailed({
  String ipInfoBody =
      '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
  int ipInfoStatus = 200,
  String meteoBody = '{"current":{"temperature_2m":61.4,"weather_code":2,'
      '"is_day":1,"surface_pressure":1012.3,"uv_index":4.2,'
      '"relative_humidity_2m":38,"wind_speed_10m":7.5}}',
  int meteoStatus = 200,
}) {
  return MockClient((request) async {
    final host = request.url.host;
    if (host == 'ipinfo.io') {
      return http.Response(ipInfoBody, ipInfoStatus);
    }
    if (host == 'api.open-meteo.com') {
      return http.Response(meteoBody, meteoStatus);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  group('NYC fallback removal (round 11 fix)', () {
    test('ipinfo 2xx without loc returns null temp, not NYC', () async {
      final api = WeatherApiClient(
        client: _mockDetailed(
          ipInfoBody: '{"city":"Orem","country":"US"}',
        ),
      );
      expect(await api.getCurrentTemp(), isNull);
    });

    test('ipinfo 2xx with unparseable loc returns null temp', () async {
      final api = WeatherApiClient(
        client: _mockDetailed(
          ipInfoBody: '{"city":"Orem","loc":"nowhere","country":"US"}',
        ),
      );
      expect(await api.getCurrentTemp(), isNull);
    });

    test('detailed weather without loc returns null, not NYC', () async {
      final api = WeatherApiClient(
        client: _mockDetailed(
          ipInfoBody: '{"city":"Orem","country":"US"}',
        ),
      );
      expect(await api.getDetailedWeather(), isNull);
    });

    test('valid loc still works (no regression)', () async {
      final api = WeatherApiClient(client: _mockDetailed());
      expect(await api.getCurrentTemp(), 61);
    });
  });

  group('getDetailedWeather', () {
    test('parses the full field set', () async {
      final api = WeatherApiClient(client: _mockDetailed());
      final d = await api.getDetailedWeather();
      expect(d, isNotNull);
      expect(d!.temp, 61);
      expect(d.condition, 'Partly Cloudy');
      expect(d.iconEmoji, '⛅');
      expect(d.locationName, 'Orem');
      expect(d.unit, 'F');
      expect(d.humidity, 38);
      expect(d.windSpeed, 7.5);
      expect(d.uvIndex, 4.2);
      expect(d.pressure, 1012.3);
      expect(d.loaded, isTrue);
    });

    test('missing optional fields map to null (sheet shows "--")',
        () async {
      final api = WeatherApiClient(
        client: _mockDetailed(
          meteoBody:
              '{"current":{"temperature_2m":61.4,"weather_code":0,"is_day":1}}',
        ),
      );
      final d = await api.getDetailedWeather();
      expect(d, isNotNull);
      expect(d!.temp, 61);
      expect(d.humidity, isNull);
      expect(d.windSpeed, isNull);
      expect(d.uvIndex, isNull);
      expect(d.pressure, isNull);
      expect(d.condition, 'Clear Sky');
      expect(d.loaded, isTrue);
    });

    test('missing temp means not loaded', () async {
      final api = WeatherApiClient(
        client: _mockDetailed(
          meteoBody: '{"current":{"weather_code":2,"is_day":1}}',
        ),
      );
      final d = await api.getDetailedWeather();
      expect(d, isNotNull);
      expect(d!.temp, isNull);
      expect(d.loaded, isFalse);
    });

    test('GPS coords skip the IP lookup', () async {
      var ipHit = false;
      String? seenUrl;
      final client = MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          ipHit = true;
          return http.Response('{}', 200);
        }
        seenUrl = request.url.toString();
        return http.Response(
            '{"current":{"temperature_2m":70.0,"weather_code":0,"is_day":1}}',
            200);
      });
      final api = WeatherApiClient(client: client);
      final d = await api.getDetailedWeather(
        manualLat: 40.1,
        manualLon: -111.6,
        manualCity: 'Current Location',
      );
      expect(ipHit, isFalse);
      expect(seenUrl, contains('latitude=40.1'));
      expect(d!.temp, 70);
      expect(d.locationName, 'Current Location');
    });

    test('meteo failure returns null', () async {
      final api = WeatherApiClient(
        client: _mockDetailed(meteoStatus: 500),
      );
      expect(await api.getDetailedWeather(), isNull);
    });

    test('night icon mapping', () async {
      final api = WeatherApiClient(
        client: _mockDetailed(
          meteoBody:
              '{"current":{"temperature_2m":50.0,"weather_code":0,"is_day":0}}',
        ),
      );
      final d = await api.getDetailedWeather();
      expect(d!.iconEmoji, '🌙');
      expect(d.condition, 'Clear Sky');
    });
  });
}
