import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/session_store.dart';

/// Round 13 — authenticated reads against the Tabs backend.
/// Round 18 — extended: full sync-pull cache, profile blobs, friends,
/// AI POST helper.
///
/// Follows the `auth_api.dart` patterns: mockable [http.Client], 20s
/// timeout, HTTPS hard-coded (`https://api.jottracker.com`, no http
/// fallback), generic network errors. The session token lives ONLY in
/// [SessionStore] (secure storage) and the Bearer header — never logged,
/// printed, or included in any error.
///
/// Endpoints (all Bearer):
/// - `GET /api/sync/pull` — the master read: streak
///   (`profile.currentStreak`/`bestStreak`), log-entry timestamps
///   (`entries[].timestamp`, epoch ms), manual BP logs
///   (`profile.manualBloodPressureLogs`, a JSON string), plus profile
///   JSON-string blobs for medications, conditions, reminders,
///   userLists, focusState, and `isUnlimited`.
/// - `GET /api/habits` — habits with `logs` date strings.
/// - `GET /api/friends/list`, `GET /api/friends/notifications` —
///   community.
/// - `POST /api/ai/*` — AI-backed tools (food, tips, coach).
///
/// Any failure — no token, non-200, malformed body, transport error —
/// yields the honest empty outcome: null / empty lists. The UI turns
/// those into "--"/empty states; nothing is invented.
class TabsBackend {
  static const String defaultBaseUrl = 'https://api.jottracker.com';
  static const Duration requestTimeout = Duration(seconds: 20);

  /// Round 18 — in-memory cache for the (large) sync pull so the 16
  /// tools share one fetch per session window instead of each firing
  /// their own. Same stale-while-revalidate spirit as the weather
  /// cache: memory-only, never persisted, never logged.
  static const Duration syncPullTtl = Duration(minutes: 5);
  Map<String, dynamic>? _syncPullCache;
  DateTime? _syncPullAt;

  final http.Client _client;
  final SessionStore _sessionStore;
  final String _baseUrl;

  TabsBackend(
      {http.Client? client, SessionStore? sessionStore, this._baseUrl = defaultBaseUrl})
      : _client = client ?? http.Client(),
        _sessionStore = sessionStore ?? SessionStore();

  /// Exposes the stored token check so callers can gate backend reads.
  Future<String?> readToken() => _sessionStore.readToken();

  /// Round 18 — the full sync-pull body, cached in memory for
  /// [syncPullTtl]. Null on any failure.
  Future<Map<String, dynamic>?> fetchSyncPull() async {
    final cached = _syncPullCache;
    final at = _syncPullAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < syncPullTtl) {
      return cached;
    }
    final body = await _getJson('/api/sync/pull');
    if (body != null) {
      _syncPullCache = body;
      _syncPullAt = DateTime.now();
    }
    return body;
  }

  /// Round 18 — `profile` object from the sync pull. Null on any failure.
  Future<Map<String, dynamic>?> fetchProfile() async {
    final body = await fetchSyncPull();
    final profile = body?['profile'];
    return profile is Map<String, dynamic> ? profile : null;
  }

  /// Round 18 — membership flag from the sync pull (gates Health Coach
  /// and Tips & Tricks, matching native). False when unknown.
  Future<bool> fetchIsUnlimited() async {
    final body = await fetchSyncPull();
    return body?['isUnlimited'] == true;
  }

  /// Round 18 — decode a profile JSON-string blob (medications,
  /// conditions, reminders, userLists, focusState, ...). Tolerates
  /// null/blank/malformed → empty list. Never throws.
  static List<Map<String, dynamic>> decodeProfileList(dynamic raw) {
    List<dynamic>? list;
    if (raw is String) {
      if (raw.trim().isEmpty) return const [];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          list = decoded;
        } else if (decoded is Map<String, dynamic>) {
          return [decoded];
        }
      } catch (_) {
        return const [];
      }
    } else if (raw is List) {
      list = raw;
    }
    if (list == null) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in list) {
      if (item is Map<String, dynamic>) {
        out.add(item);
      } else if (item is String) {
        // Some blobs store plain strings (e.g. condition names).
        out.add({'name': item});
      }
    }
    return out;
  }

  /// Round 18 — friends list from `GET /api/friends/list`.
  Future<List<FriendDto>> fetchFriendsList() async {
    final body = await _getJson('/api/friends/list');
    final friends = body?['friends'];
    if (friends is! List) return const [];
    final out = <FriendDto>[];
    for (final f in friends) {
      if (f is Map<String, dynamic>) {
        try {
          out.add(FriendDto.fromJson(f));
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }

  /// Round 18 — friend notifications from `GET /api/friends/notifications`.
  Future<List<FriendNotificationDto>> fetchFriendNotifications() async {
    final body = await _getJson('/api/friends/notifications');
    final notifications = body?['notifications'];
    if (notifications is! List) return const [];
    final out = <FriendNotificationDto>[];
    for (final n in notifications) {
      if (n is Map<String, dynamic>) {
        try {
          out.add(FriendNotificationDto.fromJson(n));
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }

  /// Round 18 — authenticated POST to an `api/ai/*` endpoint with a JSON
  /// body → decoded JSON object, or null on any failure. Used by the
  /// AI-backed tools (food checker, tips, coach). The token is used
  /// only in the header; never logged.
  Future<Map<String, dynamic>?> postAi(
      String path, Map<String, dynamic> body) async {
    final token = await _sessionStore.readToken();
    if (token == null || token.trim().isEmpty) return null;
    try {
      final response = await _client
          .post(
            Uri.parse('$_baseUrl$path'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
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

/// Round 18 — friend row from `GET /api/friends/list`.
/// Mirrors native `FriendDto`.
class FriendDto {
  final String id;
  final String nickname;
  final String tag;
  final String status;
  final int level;

  const FriendDto({
    required this.id,
    required this.nickname,
    required this.tag,
    required this.status,
    required this.level,
  });

  factory FriendDto.fromJson(Map<String, dynamic> json) {
    final level = json['level'];
    return FriendDto(
      id: '${json['id'] ?? ''}',
      nickname: '${json['nickname'] ?? ''}',
      tag: '${json['tag'] ?? ''}',
      status: '${json['status'] ?? ''}',
      level: level is num ? level.toInt() : 0,
    );
  }
}

/// Round 18 — friend notification from `GET /api/friends/notifications`.
/// Mirrors native `FriendNotificationDto`.
class FriendNotificationDto {
  final int id;
  final String type;
  final String message;
  final bool isRead;
  final String createdAt;
  final String? senderNickname;
  final String? senderTag;

  const FriendNotificationDto({
    required this.id,
    required this.type,
    required this.message,
    required this.isRead,
    required this.createdAt,
    this.senderNickname,
    this.senderTag,
  });

  factory FriendNotificationDto.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    return FriendNotificationDto(
      id: id is num ? id.toInt() : 0,
      type: '${json['type'] ?? ''}',
      message: '${json['message'] ?? ''}',
      isRead: json['isRead'] == true,
      createdAt: '${json['createdAt'] ?? ''}',
      senderNickname: json['senderNickname']?.toString(),
      senderTag: json['senderTag']?.toString(),
    );
  }
}
