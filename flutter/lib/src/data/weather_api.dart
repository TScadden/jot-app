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
/// Round 10 — GPS upgrade path: [getCurrentTempAt] takes explicit
/// coordinates (from the device GPS after the user taps the weather
/// icon and grants permission) and skips the IP lookup. The country
/// code from the earlier IP fetch is passed through so units stay
/// consistent; it defaults to 'US'.
///
/// The header needs the current temperature AND condition (round 14
/// animates the header icon by weather code); the full field set is only
/// used by the weather sheet.
///
/// Round 11 — detailed weather for the weather bottom sheet.
///
/// Mirrors the native `WeatherApi.getDetailedWeather()`: same Open-Meteo
/// field set (`temperature_2m,weather_code,is_day,surface_pressure,
/// uv_index,relative_humidity_2m,wind_speed_10m`), same unit rules.
///
/// Honesty rule (stricter than native here): every field is nullable.
/// A missing field renders as "--" in the sheet — never a zero, never a
/// wrong-city fallback.
class WeatherDetails {
  /// Whole-degree temp, null when the reading is unavailable.
  final int? temp;

  /// Human condition ("Clear Sky", "Partly Cloudy", ...), null when unknown.
  final String? condition;

  /// Emoji glyph for the condition+daypart, null when unknown.
  final String? iconEmoji;

  /// City / location label, null when unknown.
  final String? locationName;

  /// "F" or "C".
  final String unit;

  /// Relative humidity %, null when unavailable.
  final int? humidity;

  /// Wind speed in the unit-appropriate speed (mph / km/h), null when unavailable.
  final double? windSpeed;

  /// UV index, null when unavailable.
  final double? uvIndex;

  /// Surface pressure in hPa, null when unavailable.
  final double? pressure;

  /// True when we have at least a temperature reading to show.
  bool get loaded => temp != null;

  const WeatherDetails({
    this.temp,
    this.condition,
    this.iconEmoji,
    this.locationName,
    this.unit = 'F',
    this.humidity,
    this.windSpeed,
    this.uvIndex,
    this.pressure,
  });
}
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

  /// Round 14 — the header weather icon is condition-aware now, so the
  /// IP path returns the full current-conditions record. [getCurrentWeather]
  /// keeps its slim shape for existing callers.
  Future<({int? temp, String countryCode, int? weatherCode, bool isDay})>
      getCurrentWeatherCondition() async {
    try {
      final loc = await _locateByIp();
      if (loc == null) return (temp: null, countryCode: 'US', weatherCode: null, isDay: true);
      final current = await _fetchCurrent(
          latitude: loc.lat, longitude: loc.lon, countryCode: loc.countryCode);
      return (
        temp: current.temp,
        countryCode: loc.countryCode,
        weatherCode: current.weatherCode,
        isDay: current.isDay,
      );
    } on TimeoutException {
      return (temp: null, countryCode: 'US', weatherCode: null, isDay: true);
    } catch (_) {
      return (temp: null, countryCode: 'US', weatherCode: null, isDay: true);
    }
  }

  /// IP geolocation, or null when unusable. Round 11 fix: NO wrong-city
  /// fallback — a missing/unparseable `loc` means "no location".
  Future<({double lat, double lon, String countryCode})?> _locateByIp() async {
    final locResponse = await _client
        .get(
          Uri.parse(_ipInfoUrl),
          headers: const {'User-Agent': 'Tabs-App/1.0'},
        )
        .timeout(const Duration(seconds: 10));
    if (locResponse.statusCode < 200 || locResponse.statusCode > 299) {
      return null;
    }
    final locJson = jsonDecode(locResponse.body) as Map<String, dynamic>;
    final locRaw = locJson['loc'] as String?;
    final locParts = locRaw?.split(',');
    final lat = locParts != null && locParts.isNotEmpty
        ? double.tryParse(locParts[0].trim())
        : null;
    final lon = locParts != null && locParts.length > 1
        ? double.tryParse(locParts[1].trim())
        : null;
    if (lat == null || lon == null) return null;
    return (
      lat: lat,
      lon: lon,
      countryCode: locJson['country'] as String? ?? 'US',
    );
  }

  /// Whole-degree temp (null when unavailable) plus the country code
  /// the units were chosen with.
  Future<({int? temp, String countryCode})> getCurrentWeather() async {
    try {
      // 1. IP geolocation.
      final loc = await _locateByIp();
      if (loc == null) {
        // Round 11 fix: NO wrong-city fallback. If the IP lookup has no
        // usable `loc`, we return null (icon-only header) instead of
        // showing another city's temperature as if it were the user's.
        return (temp: null, countryCode: 'US');
      }

      final current = await _fetchCurrent(
          latitude: loc.lat, longitude: loc.lon, countryCode: loc.countryCode);
      return (temp: current.temp, countryCode: loc.countryCode);
    } on TimeoutException {
      return (temp: null, countryCode: 'US');
    } catch (_) {
      // Any failure (network, DNS, bad payload): honest unavailable
      // state — never a fake reading. No details logged (would risk
      // leaking location context).
      return (temp: null, countryCode: 'US');
    }
  }

  /// Returns the current temperature in whole degrees, or null when
  /// unavailable (caller shows icon-only in that case).
  Future<int?> getCurrentTemp() async =>
      (await getCurrentWeather()).temp;

  /// Round 14 — same as [getCurrentTempAt] but with the full
  /// current-conditions record (temp + weather code + day/night) so the
  /// header icon can reflect the actual condition.
  Future<({int? temp, int? weatherCode, bool isDay})> getConditionAt({
    required double latitude,
    required double longitude,
    String countryCode = 'US',
  }) async {
    try {
      return await _fetchCurrent(
          latitude: latitude,
          longitude: longitude,
          countryCode: countryCode);
    } catch (_) {
      return (temp: null, weatherCode: null, isDay: true);
    }
  }

  /// Round 10 — same as [getCurrentTemp] but for explicit GPS
  /// coordinates (user tapped the weather icon and granted location).
  /// Skips the IP lookup. Units follow [countryCode] (the value from
  /// the earlier IP fetch keeps them consistent with the IP path).
  ///
  /// Coordinates are used ONLY to build the Open-Meteo request — never
  /// logged, stored, or sent anywhere else.
  Future<int?> getCurrentTempAt({
    required double latitude,
    required double longitude,
    String countryCode = 'US',
  }) async {
    try {
      return (await _fetchCurrent(
              latitude: latitude,
              longitude: longitude,
              countryCode: countryCode))
          .temp;
    } catch (_) {
      return null;
    }
  }

  /// Shared Open-Meteo fetch. Units: fahrenheit for US, celsius
  /// otherwise (native rule). Returns the whole-degree temp plus the
  /// condition fields the header icon needs.
  Future<({int? temp, int? weatherCode, bool isDay})> _fetchCurrent({
    required double latitude,
    required double longitude,
    required String countryCode,
  }) async {
    final units = countryCode == 'US' ? 'fahrenheit' : 'celsius';
    final windUnit = countryCode == 'US' ? 'mph' : 'kmh';

    final weatherUri = Uri.parse(
      '$_openMeteoBase?latitude=$latitude&longitude=$longitude'
      '&current=temperature_2m,weather_code,is_day'
      '&forecast_days=1&temperature_unit=$units&wind_speed_unit=$windUnit',
    );
    final weatherResponse = await _client
        .get(
          weatherUri,
          headers: const {'User-Agent': 'Tabs-App/1.0'},
        )
        .timeout(const Duration(seconds: 15));
    if (weatherResponse.statusCode < 200 || weatherResponse.statusCode > 299) {
      return (temp: null, weatherCode: null, isDay: true);
    }
    final weatherJson = jsonDecode(weatherResponse.body) as Map<String, dynamic>;
    final current = weatherJson['current'] as Map<String, dynamic>?;
    final temp = (current?['temperature_2m'] as num?)?.toDouble();
    if (temp == null) return (temp: null, weatherCode: null, isDay: true);
    return (
      temp: temp.toInt(),
      weatherCode: (current?['weather_code'] as num?)?.toInt(),
      isDay: (current?['is_day'] as num?)?.toInt() != 0,
    );
  }

  /// Round 11 — detailed weather for the weather bottom sheet.
  ///
  /// Mirrors the native `WeatherApi.getDetailedWeather()` field set:
  /// `temperature_2m,weather_code,is_day,surface_pressure,uv_index,
  /// relative_humidity_2m,wind_speed_10m`. When [manualLat]/[manualLon]
  /// are given (GPS), the IP lookup is skipped and [manualCity] (or
  /// "Current Location") labels the sheet; otherwise IP geolocation
  /// supplies city + coords — with NO wrong-city fallback (missing
  /// `loc` → null, per the round-11 honesty fix).
  ///
  /// Every field is nullable; the sheet renders "--" for missing
  /// values. Coordinates/city are memory-only for the request.
  Future<WeatherDetails?> getDetailedWeather({
    double? manualLat,
    double? manualLon,
    String? manualCity,
  }) async {
    try {
      late final double lat;
      late final double lon;
      late final String city;
      late final String countryCode;

      if (manualLat != null && manualLon != null) {
        lat = manualLat;
        lon = manualLon;
        city = manualCity ?? 'Current Location';
        // Native default when forced: US units.
        countryCode = 'US';
      } else {
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
        final locParts = (locJson['loc'] as String?)?.split(',');
        final parsedLat = locParts != null && locParts.isNotEmpty
            ? double.tryParse(locParts[0].trim())
            : null;
        final parsedLon = locParts != null && locParts.length > 1
            ? double.tryParse(locParts[1].trim())
            : null;
        // No wrong-city fallback: without usable coords there is no
        // honest reading to show.
        if (parsedLat == null || parsedLon == null) return null;
        lat = parsedLat;
        lon = parsedLon;
        city = locJson['city'] as String? ?? 'Unknown';
        countryCode = locJson['country'] as String? ?? 'US';
      }

      final units = countryCode == 'US' ? 'fahrenheit' : 'celsius';
      final unitLabel = units == 'fahrenheit' ? 'F' : 'C';
      final windUnit = units == 'fahrenheit' ? 'mph' : 'kmh';

      final weatherUri = Uri.parse(
        '$_openMeteoBase?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,weather_code,is_day,surface_pressure,'
        'uv_index,relative_humidity_2m,wind_speed_10m'
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
      if (current == null) return null;

      final tempRaw = current['temperature_2m'];
      final temp = tempRaw is num ? tempRaw.toDouble().toInt() : null;
      final weatherCode = (current['weather_code'] as num?)?.toInt();
      final isDay = (current['is_day'] as num?)?.toInt() == 1;

      return WeatherDetails(
        temp: temp,
        condition: weatherCode == null
            ? null
            : _weatherDescription(weatherCode),
        iconEmoji: weatherCode == null
            ? null
            : _weatherIcon(weatherCode, isDay),
        locationName: city,
        unit: unitLabel,
        humidity: (current['relative_humidity_2m'] as num?)?.toInt(),
        windSpeed: (current['wind_speed_10m'] as num?)?.toDouble(),
        uvIndex: (current['uv_index'] as num?)?.toDouble(),
        pressure: (current['surface_pressure'] as num?)?.toDouble(),
      );
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Native `getWeatherDesc` — verbatim mapping.
  String _weatherDescription(int code) {
    if (code == 0) return 'Clear Sky';
    if (code >= 1 && code <= 3) return 'Partly Cloudy';
    if (code == 45 || code == 48) return 'Foggy Conditions';
    if (code >= 51 && code <= 55) return 'Light Drizzle';
    if (code >= 61 && code <= 65) return 'Continuous Rain';
    if (code >= 71 && code <= 75) return 'Snowfall';
    if (code >= 80 && code <= 82) return 'Rain Showers';
    if (code == 95 || code == 96 || code == 99) return 'Thunderstorm';
    return 'Atmospheric Conditions';
  }

  /// Native `getWeatherIcon` — verbatim mapping.
  String _weatherIcon(int code, bool isDay) {
    if (code == 0) return isDay ? '☀️' : '🌙';
    if (code >= 1 && code <= 3) return isDay ? '⛅' : '☁️';
    if (code == 45 || code == 48) return '🌫️';
    if (code >= 51 && code <= 55) return '🌦️';
    if (code >= 61 && code <= 65) return '🌧️';
    if (code >= 71 && code <= 75) return '❄️';
    if (code >= 80 && code <= 82) return '🌧️';
    if (code == 95 || code == 96 || code == 99) return '⛈️';
    return isDay ? '☀️' : '🌙';
  }
}
