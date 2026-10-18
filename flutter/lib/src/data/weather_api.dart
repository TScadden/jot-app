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

  /// Open-Meteo weather code, null when unknown. Stored so cached
  /// entries can drive the header's living icon without refetching.
  final int? weatherCode;

  /// Day/night flag from Open-Meteo, defaults to day.
  final bool isDay;

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
    this.weatherCode,
    this.isDay = true,
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
///   request and is NEVER logged or persisted. Round 15 adds a
///   deliberate, founder-requested exception: an IN-MEMORY cache
///   (process lifetime only, 5-minute TTL) keyed by rounded coordinates,
///   so repeat opens don't re-hit the network. Nothing is written to
///   disk; entries expire and vanish.
/// - Timeouts: 6s for ipinfo, 8s for Open-Meteo (tightened in round 15
///   so a slow network fails fast into the honest unavailable state).
/// - Tests must mock [http.Client]; no real network in tests.
class WeatherApiClient {
  static const String _ipInfoUrl = 'https://ipinfo.io/json';
  static const String _openMeteoBase =
      'https://api.open-meteo.com/v1/forecast';

  final http.Client _client;

  /// How long a cached weather/IP-location entry may be served.
  /// Override in tests to force expiry without waiting.
  final Duration cacheTtl;

  /// HTTP timeouts, tightened in round 15 so a slow network fails fast
  /// into the honest unavailable state instead of hanging the spinner.
  final Duration ipInfoTimeout;
  final Duration meteoTimeout;

  WeatherApiClient({
    http.Client? client,
    this.cacheTtl = const Duration(minutes: 5),
    this.ipInfoTimeout = const Duration(seconds: 6),
    this.meteoTimeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  // ── Round 15: in-memory cache (process lifetime only, never
  // persisted, never logged). Keyed by rounded coordinates so the
  // header and the sheet share one entry per location.

  /// Full weather result per location key, with fetch time.
  final Map<String, _CachedWeather> _weatherCache = {};

  /// In-flight full fetches per location key: concurrent callers
  /// (header + sheet) share one network request.
  final Map<String, Future<WeatherDetails?>> _weatherInflight = {};

  /// Last good IP-geolocation result, with fetch time.
  _IpLocation? _cachedIpLoc;
  DateTime? _ipLocFetchedAt;

  /// In-flight IP lookup: the header and sheet never run it twice.
  Future<_IpLocation?>? _ipLocInflight;

  static String _cacheKey(double lat, double lon) =>
      '${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}';

  WeatherDetails? _freshWeather(String key) {
    final entry = _weatherCache[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.fetchedAt) >= cacheTtl) {
      // Expired: never serve stale data — fall through to a refetch,
      // which lands in the honest loading/unavailable state on failure.
      _weatherCache.remove(key);
      return null;
    }
    return entry.details;
  }

  /// Fire-and-forget cache refresh: warms the entry for the next open.
  /// Never throws (the fetch path returns null on any failure).
  void _refreshInBackground(
    String key, {
    required double lat,
    required double lon,
    required String city,
    required String countryCode,
  }) {
    unawaited(_fetchDetailedShared(
      key,
      lat: lat,
      lon: lon,
      city: city,
      countryCode: countryCode,
    ));
  }

  /// IP geolocation, or null when unusable. Round 11 fix: NO wrong-city
  /// fallback — a missing/unparseable `loc` means "no location".
  /// Round 15: the good result is cached in memory for [cacheTtl] and
  /// concurrent callers share one in-flight lookup.
  Future<_IpLocation?> _locateByIp() async {
    final now = DateTime.now();
    if (_cachedIpLoc != null &&
        _ipLocFetchedAt != null &&
        now.difference(_ipLocFetchedAt!) < cacheTtl) {
      return _cachedIpLoc;
    }
    final inflight = _ipLocInflight;
    if (inflight != null) return inflight;
    final future = _locateByIpNetwork().then((_IpLocation? loc) {
      if (loc != null) {
        _cachedIpLoc = loc;
        _ipLocFetchedAt = DateTime.now();
      }
      return loc;
    });
    // whenComplete (not just then): a failed lookup must clear the
    // in-flight slot too, or one failure would wedge every future
    // lookup on the same errored future.
    _ipLocInflight = future.whenComplete(() => _ipLocInflight = null);
    return _ipLocInflight!;
  }

  Future<_IpLocation?> _locateByIpNetwork() async {
    final locResponse = await _client
        .get(
          Uri.parse(_ipInfoUrl),
          headers: const {'User-Agent': 'Tabs-App/1.0'},
        )
        .timeout(ipInfoTimeout);
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
    return _IpLocation(
      lat: lat,
      lon: lon,
      countryCode: locJson['country'] as String? ?? 'US',
      city: locJson['city'] as String? ?? 'Unknown',
    );
  }

  /// Round 14 — the header weather icon is condition-aware now, so the
  /// IP path returns the full current-conditions record. [getCurrentWeather]
  /// keeps its slim shape for existing callers.
  ///
  /// Round 15 — served from the shared full-detail cache: a fresh entry
  /// returns instantly (real data, minutes old) and warms the cache in
  /// the background; a miss does one full fetch shared with any
  /// concurrent sheet request.
  Future<({int? temp, String countryCode, int? weatherCode, bool isDay})>
      getCurrentWeatherCondition() async {
    try {
      final loc = await _locateByIp();
      if (loc == null) {
        return (
          temp: null,
          countryCode: 'US',
          weatherCode: null,
          isDay: true
        );
      }
      final key = _cacheKey(loc.lat, loc.lon);
      final cached = _freshWeather(key);
      if (cached != null) {
        _refreshInBackground(key,
            lat: loc.lat,
            lon: loc.lon,
            city: loc.city,
            countryCode: loc.countryCode);
        return (
          temp: cached.temp,
          countryCode: loc.countryCode,
          weatherCode: cached.weatherCode,
          isDay: cached.isDay,
        );
      }
      final details = await _fetchDetailedShared(key,
          lat: loc.lat,
          lon: loc.lon,
          city: loc.city,
          countryCode: loc.countryCode);
      if (details == null) {
        return (
          temp: null,
          countryCode: 'US',
          weatherCode: null,
          isDay: true
        );
      }
      return (
        temp: details.temp,
        countryCode: loc.countryCode,
        weatherCode: details.weatherCode,
        isDay: details.isDay,
      );
    } on TimeoutException {
      return (temp: null, countryCode: 'US', weatherCode: null, isDay: true);
    } catch (_) {
      return (temp: null, countryCode: 'US', weatherCode: null, isDay: true);
    }
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
  ///
  /// Round 15 — served from the shared full-detail cache: the GPS
  /// upgrade path and the weather sheet now share ONE Open-Meteo
  /// request per location instead of two.
  Future<({int? temp, int? weatherCode, bool isDay})> getConditionAt({
    required double latitude,
    required double longitude,
    String countryCode = 'US',
  }) async {
    try {
      final key = _cacheKey(latitude, longitude);
      final cached = _freshWeather(key);
      if (cached != null) {
        return (
          temp: cached.temp,
          weatherCode: cached.weatherCode,
          isDay: cached.isDay
        );
      }
      final details = await _fetchDetailedShared(key,
          lat: latitude,
          lon: longitude,
          city: 'Current Location',
          countryCode: countryCode);
      if (details == null) return (temp: null, weatherCode: null, isDay: true);
      return (
        temp: details.temp,
        weatherCode: details.weatherCode,
        isDay: details.isDay
      );
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
  /// Round 15 — cache behavior: a fresh in-memory entry returns
  /// INSTANTLY (real data, minutes old). Pass [forceRefresh] to skip
  /// the cache and hit the network; concurrent callers share one
  /// in-flight request per location.
  ///
  /// Every field is nullable; the sheet renders "--" for missing
  /// values. Coordinates/city are memory-only for the request (plus
  /// the short-lived in-memory cache — never persisted, never logged).
  Future<WeatherDetails?> getDetailedWeather({
    double? manualLat,
    double? manualLon,
    String? manualCity,
    bool forceRefresh = false,
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
        // Shared cached IP lookup — the header already ran this.
        final loc = await _locateByIp();
        // No wrong-city fallback: without usable coords there is no
        // honest reading to show.
        if (loc == null) return null;
        lat = loc.lat;
        lon = loc.lon;
        city = loc.city;
        countryCode = loc.countryCode;
      }

      final key = _cacheKey(lat, lon);
      if (!forceRefresh) {
        final cached = _freshWeather(key);
        if (cached != null) return cached;
      }
      return await _fetchDetailedShared(key,
          lat: lat, lon: lon, city: city, countryCode: countryCode);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Shared full-detail fetch with in-flight dedupe: concurrent
  /// callers for the same location key await ONE network request, and
  /// a good result populates the cache.
  Future<WeatherDetails?> _fetchDetailedShared(
    String key, {
    required double lat,
    required double lon,
    required String city,
    required String countryCode,
  }) {
    final inflight = _weatherInflight[key];
    if (inflight != null) return inflight;
    final future = _fetchDetailedNetwork(
      lat: lat,
      lon: lon,
      city: city,
      countryCode: countryCode,
    ).then((WeatherDetails? details) {
      _weatherInflight.remove(key);
      if (details != null) {
        _weatherCache[key] = _CachedWeather(details, DateTime.now());
      }
      return details;
    });
    _weatherInflight[key] = future;
    return future;
  }

  /// The single Open-Meteo request shape (full field set). Null on ANY
  /// failure — the caller renders the honest unavailable state.
  Future<WeatherDetails?> _fetchDetailedNetwork({
    required double lat,
    required double lon,
    required String city,
    required String countryCode,
  }) async {
    try {
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
          .timeout(meteoTimeout);
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
        weatherCode: weatherCode,
        isDay: isDay,
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

/// Round 15 — IP-geolocation result, cached in memory (never persisted,
/// never logged) for [WeatherApiClient.cacheTtl].
class _IpLocation {
  final double lat;
  final double lon;
  final String countryCode;
  final String city;

  const _IpLocation({
    required this.lat,
    required this.lon,
    required this.countryCode,
    required this.city,
  });
}

/// Round 15 — a cached full weather result with its fetch time.
class _CachedWeather {
  final WeatherDetails details;
  final DateTime fetchedAt;

  const _CachedWeather(this.details, this.fetchedAt);
}
