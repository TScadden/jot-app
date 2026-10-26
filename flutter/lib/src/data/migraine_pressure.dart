import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Barometric pressure auto-attach for migraine attack start.
///
/// Port of the Lab `pressure_lookup.dart` (Kotlin
/// `WeatherApi.getPressureOutlook(lat, lon).currentHpa` with
/// `MigraineRepository.fetchPressure()`'s null -> 0.0 mapping): same
/// Open-Meteo host, same query shape, current pressure = the first
/// hourly `surface_pressure` value — but only when the response
/// carries at least 12 hourly values, exactly like Kotlin's
/// `if (pressures.size < 12) return null` rule (FL-005). Fewer than 12
/// means an unreliable outlook, so it is NOT a real reading.
///
/// Returns 0.0 on ANY failure. Per the founder's zero-value rule,
/// 0.0 means "not captured", never a real reading — the UI shows
/// "Started — logging" for it.
///
/// Juno §G(3): callers pass ONLY coordinates already stored on the
/// device from the weather feature. This function never requests a
/// location, never prompts, and the coordinates are used only to
/// build the Open-Meteo request.
///
/// [httpGet] is an injectable seam for tests (returns the raw
/// response body). Production uses the app's `http` package.
Future<double> fetchPressureHpa({
  required double lat,
  required double lon,
  http.Client? client,
  Future<String> Function(String url)? httpGet,
  Duration timeout = const Duration(seconds: 4),
}) async {
  try {
    final url =
        'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon'
        '&hourly=surface_pressure&forecast_days=2&timezone=auto';
    final String body;
    if (httpGet != null) {
      body = await httpGet(url).timeout(timeout);
    } else {
      final c = client ?? http.Client();
      final response = await c
          .get(Uri.parse(url), headers: const {'User-Agent': 'Tabs-App/1.0'})
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode > 299) {
        return 0.0;
      }
      body = response.body;
    }
    final decoded = jsonDecode(body);
    final pressures = (decoded is Map ? decoded['hourly'] : null) as Map?;
    final values = pressures?['surface_pressure'] as List?;
    // Kotlin parity (FL-005): < 12 hourly values -> not captured.
    if (values == null || values.length < 12) return 0.0;
    final first = (values.first as num?)?.toDouble();
    return (first != null && first > 0) ? first : 0.0;
  } catch (_) {
    return 0.0;
  }
}
