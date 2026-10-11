import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/weather_api.dart';

const _ipInfoBody =
    '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}';
const _meteoOk = '{"current":{"temperature_2m":61.4,"weather_code":2,'
    '"is_day":1,"surface_pressure":1012.3,"uv_index":4.2,'
    '"relative_humidity_2m":38,"wind_speed_10m":7.5}}';

/// Mock client with per-host call counters and a fail switch.
class _CountingClient {
  int ipInfoCalls = 0;
  int meteoCalls = 0;
  bool failMeteo = false;

  MockClient get client => MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          ipInfoCalls++;
          return http.Response(_ipInfoBody, 200);
        }
        if (request.url.host == 'api.open-meteo.com') {
          meteoCalls++;
          if (failMeteo) return http.Response('boom', 500);
          return http.Response(_meteoOk, 200);
        }
        return http.Response('not found', 404);
      });
}

void main() {
  group('weather cache (round 15)', () {
    test('default cache TTL is 5 minutes (round 15b)', () {
      final api = WeatherApiClient();
      expect(api.cacheTtl, const Duration(minutes: 5));
    });

    test('second detailed call is a cache hit: no new network requests',
        () async {
      final counter = _CountingClient();
      final api = WeatherApiClient(client: counter.client);

      final first = await api.getDetailedWeather();
      expect(first?.temp, 61);
      expect(counter.ipInfoCalls, 1);
      expect(counter.meteoCalls, 1);

      final sw = Stopwatch()..start();
      final second = await api.getDetailedWeather();
      sw.stop();

      expect(second?.temp, 61);
      expect(second?.humidity, 38);
      expect(counter.ipInfoCalls, 1, reason: 'no new IP lookup');
      expect(counter.meteoCalls, 1, reason: 'no new Open-Meteo request');
      expect(sw.elapsedMilliseconds, lessThan(500),
          reason: 'cache hit returns instantly');
    });

    test('TTL expiry triggers a refetch (never serves stale data)',
        () async {
      final counter = _CountingClient();
      final api =
          WeatherApiClient(client: counter.client, cacheTtl: Duration.zero);

      await api.getDetailedWeather();
      await api.getDetailedWeather();

      expect(counter.meteoCalls, 2);
      expect(counter.ipInfoCalls, 2);
    });

    test('concurrent header + sheet callers share one in-flight request',
        () async {
      final counter = _CountingClient();
      final api = WeatherApiClient(client: counter.client);

      final results = await Future.wait<dynamic>([
        api.getDetailedWeather(),
        api.getDetailedWeather(),
        api.getCurrentWeatherCondition(),
      ]);

      expect(counter.ipInfoCalls, 1, reason: 'one shared IP lookup');
      expect(counter.meteoCalls, 1, reason: 'one shared Open-Meteo request');
      for (final r in results) {
        expect(r, isNotNull);
      }
      final condition =
          results[2] as ({int? temp, String countryCode, int? weatherCode, bool isDay});
      expect(condition.temp, 61);
      expect(condition.weatherCode, 2);
    });

    test('GPS header upgrade warms the sheet cache (no duplicate fetch)',
        () async {
      final counter = _CountingClient();
      final api = WeatherApiClient(client: counter.client);

      final condition =
          await api.getConditionAt(latitude: 40.3, longitude: -111.7);
      expect(condition.temp, 61);
      expect(counter.meteoCalls, 1);

      final details = await api.getDetailedWeather(
          manualLat: 40.3, manualLon: -111.7);
      expect(details?.temp, 61);
      expect(counter.meteoCalls, 1,
          reason: 'sheet served from the header-warmed cache');
    });

    test('forceRefresh bypasses the cache', () async {
      final counter = _CountingClient();
      final api = WeatherApiClient(client: counter.client);

      await api.getDetailedWeather();
      expect(counter.meteoCalls, 1);
      await api.getDetailedWeather(forceRefresh: true);
      expect(counter.meteoCalls, 2);
    });

    test('failed refresh keeps serving the cached value', () async {
      final counter = _CountingClient();
      final api = WeatherApiClient(client: counter.client);

      final first = await api.getDetailedWeather();
      expect(first?.temp, 61);

      counter.failMeteo = true;
      final cached = await api.getDetailedWeather();
      expect(cached?.temp, 61, reason: 'stale-on-failure keeps last good data');
      expect(counter.meteoCalls, 1, reason: 'no network attempt on cache hit');
    });

    test('expired cache + failed network -> honest null, never stale',
        () async {
      final counter = _CountingClient();
      final api =
          WeatherApiClient(client: counter.client, cacheTtl: Duration.zero);

      await api.getDetailedWeather();
      counter.failMeteo = true;
      final result = await api.getDetailedWeather(forceRefresh: true);
      expect(result, isNull);
    });

    test('slow network fails fast (tightened timeouts)', () async {
      final hanging = MockClient((request) async {
        await Future.delayed(const Duration(seconds: 30));
        return http.Response('', 200);
      });
      final api = WeatherApiClient(
        client: hanging,
        ipInfoTimeout: const Duration(milliseconds: 150),
        meteoTimeout: const Duration(milliseconds: 150),
      );

      final sw = Stopwatch()..start();
      final result = await api.getDetailedWeather();
      sw.stop();

      expect(result, isNull);
      expect(sw.elapsedMilliseconds, lessThan(5000),
          reason: 'fails fast instead of hanging');
    });

    test('a failed IP lookup does not wedge future lookups', () async {
      var failIp = true;
      var meteoCalls = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          if (failIp) return http.Response('nope', 500);
          return http.Response(_ipInfoBody, 200);
        }
        meteoCalls++;
        return http.Response(_meteoOk, 200);
      });
      final api = WeatherApiClient(client: client);

      expect(await api.getDetailedWeather(), isNull);
      failIp = false;
      final retry = await api.getDetailedWeather();
      expect(retry?.temp, 61, reason: 'lookup recovers after a failure');
      expect(meteoCalls, 1);
    });
  });
}
