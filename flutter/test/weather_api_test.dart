import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/weather_api.dart';

/// Builds a mock HTTP client serving ipinfo + Open-Meteo canned payloads.
MockClient _mockWeather({
  int ipInfoStatus = 200,
  String ipInfoBody = '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
  int meteoStatus = 200,
  String meteoBody =
      '{"current":{"temperature_2m":61.4,"weather_code":2,"is_day":1}}',
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
  test('returns the current temp as a whole degree', () async {
    final api = WeatherApiClient(client: _mockWeather());
    expect(await api.getCurrentTemp(), 61);
  });

  test('uses celsius for non-US countries', () async {
    String? seenUrl;
    final client = MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"London","loc":"51.5074,-0.1278","country":"GB"}', 200);
      }
      seenUrl = request.url.toString();
      return http.Response(
          '{"current":{"temperature_2m":16.2,"weather_code":0,"is_day":1}}',
          200);
    });
    final api = WeatherApiClient(client: client);
    expect(await api.getCurrentTemp(), 16);
    expect(seenUrl, contains('temperature_unit=celsius'));
    expect(seenUrl, isNot(contains('temperature_unit=fahrenheit')));
  });

  test('US country uses fahrenheit', () async {
    String? seenUrl;
    final client = MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
      }
      seenUrl = request.url.toString();
      return http.Response(
          '{"current":{"temperature_2m":61.4,"weather_code":2,"is_day":1}}',
          200);
    });
    await WeatherApiClient(client: client).getCurrentTemp();
    expect(seenUrl, contains('temperature_unit=fahrenheit'));
  });

  test('ipinfo failure returns null (honest unavailable state)', () async {
    final api = WeatherApiClient(client: _mockWeather(ipInfoStatus: 500));
    expect(await api.getCurrentTemp(), isNull);
  });

  test('open-meteo failure returns null', () async {
    final api = WeatherApiClient(client: _mockWeather(meteoStatus: 500));
    expect(await api.getCurrentTemp(), isNull);
  });

  test('missing temperature field returns null, never zero', () async {
    final api = WeatherApiClient(
      client: _mockWeather(
          meteoBody: '{"current":{"weather_code":2,"is_day":1}}'),
    );
    final temp = await api.getCurrentTemp();
    expect(temp, isNull);
    expect(temp, isNot(0));
  });

  test('malformed payload returns null', () async {
    final api = WeatherApiClient(
      client: _mockWeather(meteoBody: 'not json at all{{{'),
    );
    expect(await api.getCurrentTemp(), isNull);
  });

  test('sends the Tabs user agent', () async {
    String? seenUa;
    final client = MockClient((request) async {
      seenUa ??= request.headers['User-Agent'];
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.4,"weather_code":2,"is_day":1}}',
          200);
    });
    await WeatherApiClient(client: client).getCurrentTemp();
    expect(seenUa, 'Tabs-App/1.0');
  });
}
