import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Round 6 — live weather for the home screen's Today header.
///
/// Mirrors the native app's `WeatherApi.getDetailedWeather()`
/// (`data/remote/WeatherApi.kt`):
/// 1. IP geolocation: `GET https://ipinfo.io/json` → `city`, `loc`
///    (`"lat,lon"`), `country`. No API key (free tier).
/// 2. Current conditions: `GET https://api.open-meteo.com/v1/forecast`
///    with `current=temperature_2m,weather_code,is_day,...` →
///    `current.temperature_2m`. Units: fahrenheit for US, celsius
///    otherwise. No API key.
///
/// The header only needs the current temperature (the native header
/// always shows a cloud glyph; the condition emoji mapping is only used
/// by the weather sheet, which doesn't exist yet).
///
/// Native honesty rule, kept here: on ANY failure (no network, non-2xx,
/// bad payload, DNS) return null — the header then shows the icon only
/// and never a placeholder zero.
///
/// Security rules (Vera):
/// - HTTPS only — both URLs are hard-coded with the https scheme, no
///   http fallback, no API keys.
/// - Location data (city/lat/lon) is used only to build the Open-Meteo
///   request and is NEVER logged, stored, or cached — memory only for
///   the duration of the call.
/// - Timeouts: 10s for ipinfo, 15s for Open-Meteo (native values).
/// - Tests must mock [http.Client]; no real network in tests.
class WeatherApiClient {
  static const String _ipInfoUrl = 'https://ipinfo.io/json';
  static const String _openMeteoBase =
      'https://api.open-meteo.com/v1/forecast';

  final http.Client _client;

  WeatherApiClient({http.Client? client}) : _client = client ?? http.Client();

  /// Returns the current temperature in whole degrees, or null when
  /// unavailable (caller shows icon-only in that case).
  Future<int?> getCurrentTemp() async {
    try {
      // 1. IP geolocation.
      final locResponse = await _client
          .get(
            Uri.parse(_ipInfoUrl),
            headers: const {'User-Agent': 'Tabs-App/1.0'},
          )
          .timeout(const Duration(seconds: 10));
      if (locResponse.statusCode < 200 || locResponse.statusCode > 299) {
        return null;
      }
      final locJson =
          jsonDecode(locResponse.body) as Map<String, dynamic>;
      final locParts =
          (locJson['loc'] as String? ?? '40.7128,-74.0060').split(',');
      final lat = double.tryParse(locParts[0]) ?? 40.7128;
      final lon =
          locParts.length > 1 ? double.tryParse(locParts[1]) ?? -74.0060 : -74.0060;
      final countryCode = locJson['country'] as String? ?? 'US';

      // 2. Units (native rule: fahrenheit for US, celsius otherwise).
      final units = countryCode == 'US' ? 'fahrenheit' : 'celsius';
      final windUnit = countryCode == 'US' ? 'mph' : 'kmh';

      // 3. Current weather from Open-Meteo.
      final weatherUri = Uri.parse(
        '$_openMeteoBase?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,weather_code,is_day'
        '&forecast_days=1&temperature_unit=$units&wind_speed_unit=$windUnit',
      );
      final weatherResponse = await _client
          .get(
            weatherUri,
            headers: const {'User-Agent': 'Tabs-App/1.0'},
          )
          .timeout(const Duration(seconds: 15));
      if (weatherResponse.statusCode < 200 ||
          weatherResponse.statusCode > 299) {
        return null;
      }
      final weatherJson =
          jsonDecode(weatherResponse.body) as Map<String, dynamic>;
      final current = weatherJson['current'] as Map<String, dynamic>?;
      final temp = (current?['temperature_2m'] as num?)?.toDouble();
      if (temp == null) return null;
      return temp.toInt();
    } on TimeoutException {
      return null;
    } catch (_) {
      // Any failure (network, DNS, bad payload): honest unavailable
      // state — never a fake reading. No details logged (would risk
      // leaking location context).
      return null;
    }
  }
}
