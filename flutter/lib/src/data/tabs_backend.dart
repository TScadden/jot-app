import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/session_store.dart';

/// Round 13 — authenticated reads against the Tabs backend.
///
/// Follows the `auth_api.dart` patterns: mockable [http.Client], 20s
/// timeout, HTTPS hard-coded (`https://api.jottracker.com`, no http
/// fallback), generic network errors. The session token lives ONLY in
/// [SessionStore] (secure storage) and the Bearer header — never logged,
/// printed, or included in any error.
///
/// Endpoints (all `GET`, all Bearer):
/// - `/api/sync/pull` — streak (`profile.currentStreak`/`bestStreak`),
///   log-entry timestamps (`entries[].timestamp`, epoch ms), manual BP
///   logs (`profile.manualBloodPressureLogs`, a JSON string).
/// - `/api/habits` — habits with `logs` date strings.
///
/// Any failure — no token, non-200, malformed body, transport error —
/// yields the honest empty outcome: null streaks / empty lists. The UI
/// turns those into "--"/empty states; nothing is invented.
class TabsBackend {
  static const String defaultBaseUrl = 'https://api.jottracker.com';
  static const Duration requestTimeout = Duration(seconds: 20);

  final http.Client _client;
  final SessionStore _sessionStore;
  final String _baseUrl;

  TabsBackend(
      {http.Client? client, SessionStore? sessionStore, this._baseUrl = defaultBaseUrl})
      : _client = client ?? http.Client(),
        _sessionStore = sessionStore ?? SessionStore();

  /// Exposes the stored token check so callers can gate backend reads.
  Future<String?> readToken() => _sessionStore.readToken();

  /// Current/best streak from `/api/sync/pull`. Nulls on any failure —
  /// the streak row renders "--".
  Future<({int? current, int? best})> fetchStreak() async {
    final body = await _getJson('/api/sync/pull');
    final profile = body?['profile'];
    if (profile is! Map<String, dynamic>) {
      return (current: null, best: null);
    }
    return (
      current: _asInt(profile['currentStreak']),
      best: _asInt(profile['bestStreak']),
    );
  }

  /// Log-entry timestamps (epoch ms) from `/api/sync/pull` `entries`.
  Future<List<int>> fetchLogEntries() async {
    final body = await _getJson('/api/sync/pull');
    final entries = body?['entries'];
    if (entries is! List) return const [];
    final out = <int>[];
    for (final e in entries) {
      if (e is Map<String, dynamic>) {
        final t = _asInt(e['timestamp']);
        if (t != null) out.add(t);
      }
    }
    return out;
  }

  /// Habits from `GET /api/habits` → `{"habits": [...]}`.
  Future<List<HabitDto>> fetchHabits() async {
    final body = await _getJson('/api/habits');
    final habits = body?['habits'];
    if (habits is! List) return const [];
    final out = <HabitDto>[];
    for (final h in habits) {
      if (h is Map<String, dynamic>) {
        try {
          out.add(HabitDto.fromJson(h));
        } catch (_) {
          // Skip malformed habit rows — never fail the whole metric.
        }
      }
    }
    return out;
  }

  /// Manual BP logs from `profile.manualBloodPressureLogs` — a JSON string
  /// of `[{systolic, diastolic, timeEpochMs, ...}]`. Tolerates null, blank,
  /// and malformed content (→ empty); never throws.
  Future<List<BpRecord>> fetchManualBpLogs() async {
    final body = await _getJson('/api/sync/pull');
    final profile = body?['profile'];
    if (profile is! Map<String, dynamic>) return const [];
    final raw = profile['manualBloodPressureLogs'];
    List<dynamic>? list;
    if (raw is String) {
      if (raw.trim().isEmpty) return const [];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) list = decoded;
      } catch (_) {
        return const [];
      }
    } else if (raw is List) {
      list = raw;
    }
    if (list == null) return const [];
    final out = <BpRecord>[];
    for (final item in list) {
      if (item is Map<String, dynamic>) {
        try {
          out.add(BpRecord.fromJson(item));
        } catch (_) {
          // Skip malformed rows — never fail the whole metric.
        }
      }
    }
    return out;
  }

  void close() => _client.close();

  /// Authenticated GET → decoded JSON object, or null on any failure.
  /// The token is used only here, in the header; never logged anywhere.
  Future<Map<String, dynamic>?> _getJson(String path) async {
    final token = await _sessionStore.readToken();
    if (token == null || token.trim().isEmpty) return null;
    try {
      final response = await _client
          .get(
            Uri.parse('$_baseUrl$path'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
