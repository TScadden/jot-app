import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
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

/// How an authenticated send ended without an HTTP response
/// (report-pdf fix): the classification [TabsBackend.postAiDetailed]
/// plumbs to the report pipeline so its failure reason is truthful
/// (Juno Ruling 3). Server/exception text is never part of it.
enum AiTransportFailure {
  /// The transport's own timeout fired before any response.
  timeout,

  /// A request was attempted, no HTTP response arrived, and the
  /// attempt did not time out (socket/DNS/TLS/client failure).
  noResponse,

  /// No request was attempted: there is no stored session token.
  noSession,
}

class TabsBackend {
  static const String defaultBaseUrl = 'https://api.jottracker.com';
  static const Duration requestTimeout = Duration(seconds: 20);

  /// The AI report call's dedicated transport budget
  /// ([postAiDetailed] only — every other call keeps the shared
  /// [requestTimeout]). Native caps each report attempt at 60s,
  /// and server evidence for the Oct 22, 2026 incident shows a
  /// successful `/api/ai/report` generation taking up to ~31s:
  /// at the shared 20s the transport killed legitimate in-flight
  /// generations and the failure was then mislabelled
  /// "no connection". 60s matches native's per-attempt cap (and
  /// the report pipeline's own 60s outer guard).
  static const Duration aiRequestTimeout = Duration(seconds: 60);

  /// Round 18 — in-memory cache for the (large) sync pull so the 16
  /// tools share one fetch per session window instead of each firing
  /// their own. Same stale-while-revalidate spirit as the weather
  /// cache: memory-only, never persisted, never logged.
  static const Duration syncPullTtl = Duration(minutes: 5);

  /// Screen-load performance (Oct 26, 2026) — the TTL cache is STATIC
  /// and keyed by (baseUrl, token), the same scoping as the Round-60
  /// in-flight slot below. It used to be per-instance, but the app
  /// constructs ~29 [TabsBackend] instances over one session (several
  /// screens mint a new one on every property access), so nearly every
  /// navigation missed the cache and paid a full GET /api/sync/pull.
  /// Each entry records the profile-mutation epoch at which its fetch
  /// STARTED (see [_profileMutationEpoch]): a body whose fetch started
  /// before the latest successful profile push is never served as
  /// fresh, on ANY instance.
  static final Map<
      (String, String?),
      ({
        Map<String, dynamic> body,
        DateTime at,
        int epoch,
      })> _syncPullCacheBySession = {};

  /// Counter-mutation durability (Oct 2026) — app-wide profile
  /// mutation epoch. STATIC for the same reason as the Round 31
  /// refresh slot and the Round 60 in-flight pull slot: the app
  /// constructs ~20 [TabsBackend] instances over ONE stored
  /// session, so a per-instance counter could not see a push made
  /// through another instance.
  ///
  /// Every SUCCESSFUL [postSyncProfile] bumps it. A sync-pull fetch
  /// records the epoch when it STARTS; if the epoch has moved by
  /// the time the body lands, that body predates the push, so it is
  /// discarded and the GET is re-issued exactly once (bounded — no
  /// loop) — see [_getSyncPullEpochChecked]. Before this, a GET
  /// that started before a profile push could land after it and be
  /// stamped fresh for the full 5-minute TTL by [fetchSyncPull];
  /// a surface loading from that instance then rendered pre-push
  /// state (the founder's archive/delete "reverting"), and a later
  /// whole-blob save built on that snapshot overwrote the server
  /// and made the revert permanent.
  static int _profileMutationEpoch = 0;

  /// Round 19 — drops the cached sync pull so the next read hits the
  /// server. Called after local writes (log save/repeat/delete,
  /// category add/delete) so counts and lists refresh honestly.
  /// Oct 26, 2026: clears EVERY session entry — the cache is shared
  /// app-wide now, so one instance's write must invalidate for all.
  void invalidateSyncPull() {
    _syncPullCacheBySession.clear();
  }

  /// The (baseUrl, token) key scoping the shared caches, or null when
  /// the session store is unreadable — callers then skip caching and
  /// take the uncached path, exactly as the epoch-checked shared pull
  /// does when its token read fails.
  Future<(String, String?)?> _sessionKey() async {
    try {
      final token = await _sessionStore.readToken();
      return (_baseUrl, token);
    } catch (_) {
      return null;
    }
  }

  final http.Client _client;
  final SessionStore _sessionStore;
  late final AuthApiClient _authApi;
  final String _baseUrl;

  TabsBackend(
      {http.Client? client,
      SessionStore? sessionStore,
      AuthApiClient? authApi,
      this._baseUrl = defaultBaseUrl})
      : _client = client ?? http.Client(),
        _sessionStore = sessionStore ?? SessionStore() {
    // Round 31 fix pass (Vera NIT 3): the default AuthApiClient
    // shares this backend's client instead of constructing a
    // second http.Client nobody closes separately.
    _authApi = authApi ?? AuthApiClient(client: _client);
  }

  /// Exposes the stored token check so callers can gate backend reads.
  Future<String?> readToken() => _sessionStore.readToken();

  /// Round 55 — the stored account email, for account-bound local
  /// stores (CoachMemoryStore). Routes through this backend's
  /// session store so callers never construct a second one.
  Future<String?> readEmail() => _sessionStore.readEmail();

  // ── Round 31 — 401 → refresh → retry-once (native AuthInterceptor
  // parity) ────────────────────────────────────────────────────────
  //
  // Every authenticated call in this class routes through
  // [_sendAuthed]: attach the stored token; on HTTP 401 run ONE
  // single-flight refresh (concurrent 401s share it); on success
  // retry the original request ONCE with the rotated token.
  //
  // - Temporary refresh failure: the original 401 is handed back to
  //   the caller, which runs its normal honest-failure path. The
  //   stored session is untouched — never log out on a blip.
  // - Definitive refresh failure: THIS wrapper is the single layer
  //   responsible for clearing the session — it awaits
  //   [SessionStore.clear] and then invokes [onSessionExpired] so
  //   the app shell can route back to welcome. Callers of the
  //   callback must NOT clear the store again.
  //
  // Logout is the one exception: native treats
  // `POST /api/auth/logout` as a public auth endpoint, so
  // [logoutAccount] bypasses this path entirely.

  /// Invoked once after a definitive refresh failure has already
  /// cleared the stored session. Static because the shell's screens
  /// each construct their own [TabsBackend]; the app flow (main.dart)
  /// registers its handler here so ANY instance's definitive failure
  /// routes the app back to welcome. Default null (tests, tools).
  static void Function()? onSessionExpired;

  /// The in-flight single-flight refresh, if any. Concurrent 401s
  /// all await this same future, so the refresh endpoint is hit at
  /// most once per expiry wave.
  ///
  /// STATIC (app-wide), not per-instance (Round 31 fix pass, Vera
  /// BLOCKER 2): the app constructs ~20 [TabsBackend] instances
  /// (several per-access getters), all over the SAME stored session.
  /// A per-instance slot let concurrent cold-start 401s on different
  /// instances each POST the old refresh token; refresh tokens
  /// rotate, and the server's reuse detection can read the second
  /// presentation of the rotated-out token as a revocation — its
  /// definitive failure would then clear the fresh pair the first
  /// instance had just saved. One app-wide slot closes that race:
  /// exactly one refresh POST per expiry wave, app-wide.
  static Future<_RefreshOutcome>? _refreshInFlight;

  /// Sends [send] with the stored token. Returns null when there is
  /// no stored token or the transport fails; otherwise the response
  /// (the retried response after a successful refresh, or the
  /// original response — including the original 401 when the refresh
  /// fails temporarily or definitively).
  Future<http.Response?> _sendAuthed(
          Future<http.Response> Function(String token) send) async =>
      (await _sendAuthedDetailed(send)).response;

  /// The detailed form of [_sendAuthed]: identical behaviour, but a
  /// null response carries its classification (report-pdf fix, Juno
  /// Ruling 3). The shared transport timeout's own TimeoutException
  /// is a TIMEOUT — the pre-fix `catch (_)` collapsed it, and every
  /// other transport failure, into an indistinguishable null that
  /// the report pipeline then labelled "no connection". A missing
  /// session is [AiTransportFailure.noSession] (no request was
  /// attempted at all), never a connection failure. Only
  /// [postAiDetailed] consumes the classification; every other
  /// caller keeps the plain null contract via [_sendAuthed].
  Future<({http.Response? response, AiTransportFailure? failure})>
      _sendAuthedDetailed(
    Future<http.Response> Function(String token) send, {
    Duration timeout = requestTimeout,
  }) async {
    final token = await _sessionStore.readToken();
    if (token == null || token.trim().isEmpty) {
      return (response: null, failure: AiTransportFailure.noSession);
    }
    http.Response response;
    try {
      response = await send(token).timeout(timeout);
    } on TimeoutException {
      return (response: null, failure: AiTransportFailure.timeout);
    } catch (_) {
      return (response: null, failure: AiTransportFailure.noResponse);
    }
    if (response.statusCode != 401) return (response: response, failure: null);
    final outcome = await _refreshSingleFlight(failedToken: token);
    if (outcome is _RefreshSucceeded) {
      try {
        return (
          response: await send(outcome.token).timeout(timeout),
          failure: null,
        );
      } on TimeoutException {
        return (response: null, failure: AiTransportFailure.timeout);
      } catch (_) {
        return (response: null, failure: AiTransportFailure.noResponse);
      }
    }
    return (response: response, failure: null);
  }

  /// Single-flight entry point: the first 401 starts the refresh;
  /// every concurrent 401 joins the same future.
  Future<_RefreshOutcome> _refreshSingleFlight({required String failedToken}) {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    late final Future<_RefreshOutcome> future;
    future = _performRefresh(failedToken).whenComplete(() {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    });
    _refreshInFlight = future;
    return future;
  }

  Future<_RefreshOutcome> _performRefresh(String failedToken) async {
    try {
      // A concurrent caller may already have rotated the token
      // while this one waited for the single-flight slot — reuse
      // the stored token instead of refreshing a second time
      // (native AuthInterceptor does the same check under its lock).
      final current = await _sessionStore.readToken();
      if (current != null &&
          current.trim().isNotEmpty &&
          current != failedToken) {
        return _RefreshSucceeded(current);
      }
      final refreshToken = await _sessionStore.readRefreshToken();
      if (refreshToken == null || refreshToken.trim().isEmpty) {
        // Native parity: no refresh token → reconnect required.
        return await _definitiveFailure();
      }
      final result = await _authApi.refreshSession(refreshToken);
      if (result is RefreshSuccess) {
        // Both tokens rotate; the stored email stays unchanged.
        final email = await _sessionStore.readEmail() ?? '';
        await _sessionStore.saveSession(
          token: result.token,
          refreshToken: result.refreshToken,
          email: email,
        );
        return _RefreshSucceeded(result.token);
      }
      if (result is RefreshDefinitiveFailure) {
        return await _definitiveFailure();
      }
      return const _RefreshTemporary();
    } catch (_) {
      // Storage surprise mid-refresh: preserve the session.
      return const _RefreshTemporary();
    }
  }

  /// Definitive failure handling — the ONE place the session is
  /// cleared on refresh rejection. Clears first, then notifies.
  Future<_RefreshOutcome> _definitiveFailure() async {
    try {
      await _sessionStore.clear();
    } catch (_) {
      // SessionStore.clear already isolates per-key failures; this
      // is a last-resort guard so the callback still fires.
    }
    final callback = onSessionExpired;
    if (callback != null) {
      try {
        callback();
      } catch (_) {
        // A shell routing bug must not corrupt the caller's result.
      }
    }
    return const _RefreshDefinitive();
  }

  /// Round 60 — single-flight for the sync-pull NETWORK fetch,
  /// scoped per session (the same pattern as the Round 31 refresh
  /// slot, and for the same reason): the app constructs many
  /// [TabsBackend] instances over ONE stored session, and at cold
  /// start several of them — plus the direct pull readers
  /// ([fetchStreak], [fetchLogEntries], [fetchManualBpLogs], which
  /// deliberately bypass the TTL cache) — used to fire CONCURRENT
  /// IDENTICAL `GET /api/sync/pull` requests (measured at base:
  /// 5 consumers in flight → 5 requests; a cold Home mount → 4).
  /// Now concurrent callers for the SAME session join the first
  /// caller's in-flight request instead of duplicating it.
  ///
  /// The scope key is the (baseUrl, token) pair itself, as a Dart
  /// record: structural equality decides, the hash only buckets.
  /// (Round 60 fix, Juno blocker: the first cut keyed the map by
  /// the `Object.hash(baseUrl, token)` INT alone and never compared
  /// the pair for equality — Dart's hash contract permits unequal
  /// pairs to share a hash code, so two different sessions whose
  /// hashes collided would have shared one in-flight pull, health
  /// data body included. The guarantee now holds by construction,
  /// not probabilistically.) The token string is held in the key
  /// in memory only, for exactly the in-flight lifetime — the
  /// entry is removed on completion — and is never logged or
  /// persisted. Scoping matters: a caller with NO session (or a
  /// different one) must never be handed another session's
  /// in-flight result — an unscoped slot let a tokenless instance's
  /// null result swallow a signed-in instance's pull at Home mount
  /// (caught by the round-21 feeling tests). In production every
  /// instance reads the same stored token, so the dedupe is total
  /// there.
  ///
  /// The slot carries NO result past completion: a caller that
  /// arrives after the fetch lands makes its own request (or hits
  /// its per-instance TTL cache first, in [fetchSyncPull]), so no
  /// stale body can ever be served from here.
  static final Map<
      (String, String?),
      Future<
          ({
            Map<String, dynamic>? body,
            int fetchEpoch,
          })>> _syncPullInFlight = {};

  /// One epoch-checked sync-pull GET: records the profile-mutation
  /// epoch at start; when the body lands after a successful profile
  /// push (epoch moved), the body predates that push — discard it
  /// and re-issue the GET. The re-issue LOOPS while the epoch keeps
  /// moving (bounded at [_maxPullReissues] re-issues): a second
  /// push landing during the first re-issue must not let a body
  /// that predates it be delivered as fresh (Vera F3 — bulk
  /// archive in quick succession hit exactly that window).
  /// [fetchEpoch] is the epoch at which the fetch that produced
  /// [body] STARTED, so callers can refuse to cache a body that
  /// predates the latest push. If the bound is exhausted with the
  /// epoch STILL moving, delivery is refused outright (null body —
  /// the caller's ordinary failed-pull path) rather than handing
  /// out a body known to predate the latest push: a non-null body
  /// from this method always started at the current epoch.
  static const int _maxPullReissues = 3;

  Future<({Map<String, dynamic>? body, int fetchEpoch})>
      _getSyncPullEpochChecked() async {
    var fetchEpoch = _profileMutationEpoch;
    var body = await _getJson('/api/sync/pull');
    var reissues = 0;
    while (body != null &&
        _profileMutationEpoch != fetchEpoch &&
        reissues < _maxPullReissues) {
      reissues++;
      fetchEpoch = _profileMutationEpoch;
      body = await _getJson('/api/sync/pull');
    }
    if (body != null && _profileMutationEpoch != fetchEpoch) {
      return (body: null, fetchEpoch: fetchEpoch);
    }
    return (body: body, fetchEpoch: fetchEpoch);
  }

  Future<({Map<String, dynamic>? body, int fetchEpoch})>
      _fetchSyncPullSharedRecord() async {
    String? token;
    try {
      token = await _sessionStore.readToken();
    } catch (_) {
      // Unreadable store → behave exactly as the pre-Round-60 code
      // (the read inside _sendAuthed surfaces the same outcome),
      // still epoch-checked.
      return _getSyncPullEpochChecked();
    }
    final key = (_baseUrl, token);
    final inFlight = _syncPullInFlight[key];
    if (inFlight != null) return inFlight;
    late final Future<({Map<String, dynamic>? body, int fetchEpoch})>
        future;
    future = _getSyncPullEpochChecked().whenComplete(() {
      if (identical(_syncPullInFlight[key], future)) {
        _syncPullInFlight.remove(key);
      }
    });
    _syncPullInFlight[key] = future;
    return future;
  }

  /// Round 18 — the full sync-pull body, cached in memory for
  /// [syncPullTtl]. Null on any failure.
  ///
  /// Counter-mutation durability (Oct 2026): the cached body is
  /// served only while the epoch recorded when its fetch started
  /// still equals the current profile-mutation epoch — a successful
  /// profile push on ANY instance makes every older cached body
  /// unservable, not just this instance's (the pre-fix per-instance
  /// invalidation in `_pushProfile` could not see other instances).
  Future<Map<String, dynamic>?> fetchSyncPull() async {
    final key = await _sessionKey();
    if (key != null) {
      final entry = _syncPullCacheBySession[key];
      if (entry != null &&
          entry.epoch == _profileMutationEpoch &&
          DateTime.now().difference(entry.at) < syncPullTtl) {
        return entry.body;
      }
    }
    final result = await _fetchSyncPullSharedRecord();
    final body = result.body;
    if (body != null && key != null) {
      _syncPullCacheBySession[key] =
          (body: body, at: DateTime.now(), epoch: result.fetchEpoch);
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
  ///
  /// Round 18b hardening: also accepts an already-decoded [List] or
  /// [Map] (some call sites pass decoded values) and double-encoded
  /// JSON strings (a JSON string containing a JSON string).
  static List<Map<String, dynamic>> decodeProfileList(dynamic raw) {
    List<dynamic>? list;
    if (raw is String) {
      if (raw.trim().isEmpty) return const [];
      try {
        var decoded = jsonDecode(raw);
        // Unwrap double-encoded strings: "\"[...]\", \"{...}\"".
        var guard = 0;
        while (decoded is String &&
            decoded.trim().isNotEmpty &&
            guard < 3) {
          guard++;
          try {
            decoded = jsonDecode(decoded);
          } catch (_) {
            break;
          }
        }
        if (decoded is List) {
          list = decoded;
        } else if (decoded is Map) {
          return [_stringKeyed(decoded)];
        }
      } catch (_) {
        return const [];
      }
    } else if (raw is List) {
      list = raw;
    } else if (raw is Map) {
      // Already-decoded single blob.
      return [_stringKeyed(raw)];
    }
    if (list == null) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in list) {
      if (item is Map) {
        out.add(_stringKeyed(item));
      } else if (item is String) {
        // Some blobs store plain strings (e.g. condition names).
        out.add({'name': item});
      }
    }
    return out;
  }

  /// Coerces a decoded map to `Map<String, dynamic>`; returns `{}` when
  /// the map has no string keys. Never throws.
  static Map<String, dynamic> _stringKeyed(Map<dynamic, dynamic> m) {
    final out = <String, dynamic>{};
    for (final e in m.entries) {
      if (e.key is String) out[e.key as String] = e.value;
    }
    return out;
  }

  /// Round 35 — habit check-off write, mirroring native
  /// `HabitRepository.toggleHabitLog` → `POST /api/habits/log` with
  /// `LogHabitRequest{habit_id, completed_date, is_completed}`
  /// (JotApi.kt:427-431, 715-716). True on HTTP 200. Used by the
  /// Home Today Summary plan rows (native `TodayViewModel.toggleHabit`).
  Future<bool> logHabit({
    required String habitId,
    required String date,
    required bool completed,
  }) async {
    final ok = await _postJson('/api/habits/log', {
      'habit_id': habitId,
      'completed_date': date,
      'is_completed': completed,
    });
    if (ok) invalidateHabits();
    return ok;
  }

  /// Round 47 — create a habit, mirroring native habit creation:
  /// `POST /api/habits` with `{"title": ..., "target_time": "Anytime"}`
  /// → `{"habit": {...}}`. Returns the created habit, or null on any
  /// failure (the caller keeps the honest error path and re-fetches).
  /// Accepts 200 or 201 (resource-created) like the native client's
  /// 2xx handling; every other status is a failure.
  ///
  /// Fix-round hardening: a 2xx response whose body lacks a usable
  /// `habit` object is still a SUCCESS — the POST itself landed, so
  /// reporting failure would invite a retry that creates a
  /// duplicate. A placeholder carrying the requested title is
  /// returned and the caller's re-fetch confirms the real row.
  Future<HabitDto?> createHabit(String title) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/habits'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'title': title, 'target_time': 'Anytime'}),
        ));
    if (response == null ||
        (response.statusCode != 200 && response.statusCode != 201)) {
      return null;
    }
    invalidateHabits();
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final habit = decoded['habit'];
        if (habit is Map<String, dynamic>) return HabitDto.fromJson(habit);
      }
    } catch (_) {
      // A 2xx with an unparseable body still means the POST landed.
    }
    return HabitDto(id: '', title: title, logs: const []);
  }

  /// Round 47 — delete a habit: `DELETE /api/habits/{id}` (native).
  /// True on HTTP 200. There is NO habit update endpoint — a rename
  /// would need delete+recreate, which destroys the habit's
  /// server-side log history, so editing is deliberately not built.
  Future<bool> deleteHabit(String id) async {
    final ok = await _delete('/api/habits/${Uri.encodeComponent(id)}');
    if (ok) invalidateHabits();
    return ok;
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

  /// Round 48 — send a friend request, mirroring native
  /// `CommunityViewModel.sendFriendRequest` → `POST api/friends/request`
  /// with `FriendRequestApiRequest{friendIdString}` (JotApi.kt). The
  /// friendIdString is the friend's 5-digit tag (optionally `#`-prefixed),
  /// exactly as native's Add Friend dialog sends it. Returns the decoded
  /// `GenericResponse` body ({success, message, error}) on HTTP 200 so
  /// the caller can surface the server's own error text; null on any
  /// transport failure.
  Future<Map<String, dynamic>?> sendFriendRequest(
          String friendIdString) =>
      _postJsonMap('/api/friends/request', {'friendIdString': friendIdString});

  /// Round 48 — respond to a friend request, mirroring native
  /// `CommunityViewModel.respondFriendRequest` → `POST api/friends/respond`
  /// with `RespondFriendRequestApiRequest{requestId, action}` where
  /// action is `"accept"` or `"reject"` (JotApi.kt). Returns the decoded
  /// `GenericResponse` body on HTTP 200, null on transport failure.
  Future<Map<String, dynamic>?> respondFriendRequest(
          int requestId, bool accept) =>
      _postJsonMap('/api/friends/respond', {
        'requestId': requestId,
        'action': accept ? 'accept' : 'reject',
      });

  /// Round 48 — mark all friend notifications read, mirroring native
  /// `CommunityViewModel.markNotificationsRead` →
  /// `POST api/friends/notifications/read` (JotApi.kt, no body in
  /// native; an empty JSON object is sent here). True on HTTP 200.
  /// Native ignores failures silently; callers do the same.
  Future<bool> markFriendNotificationsRead() =>
      _postJson('/api/friends/notifications/read', const {});

  /// Round 48 — one friend's shared today stats, mirroring native
  /// `CommunityViewModel.fetchFriendDetail` →
  /// `GET api/friends/data/{friendId}` (JotApi.kt) →
  /// `FriendDetailResponse{success, data, error}`. Returns the decoded
  /// body on HTTP 200, null on any failure.
  Future<Map<String, dynamic>?> fetchFriendDetail(String friendId) =>
      _getJson('/api/friends/data/${Uri.encodeComponent(friendId)}');

  /// Round 48 — push coach sessions, mirroring native
  /// `SyncManager.syncCoachSessions` → `POST api/sync/coach_sessions`
  /// with `SyncCoachSessionsRequest{sessions}` (JotApi.kt). Callers
  /// send ONLY the sessions they created/changed (native syncs its
  /// unsynced rows the same way).
  ///
  /// Round 57 — true only when the server's `{synced: n}` accounts
  /// for EVERY row sent, not merely on HTTP 200. The pre-Round-57
  /// status-only check trusted any 200: the original server handler
  /// silently skipped messages whose session check failed while
  /// still returning 200, so a chat could report "saved" with rows
  /// missing. The restored handler counts rows already stored by an
  /// idempotent retry, so an exact match is the honest success test.
  /// A 200 without a usable `synced` count fails closed.
  Future<bool> syncCoachSessions(
      List<Map<String, dynamic>> sessions) async {
    final res = await _postJsonMap(
        '/api/sync/coach_sessions', {'sessions': sessions});
    return _syncedAll(res, sessions.length);
  }

  /// Round 48 — push coach messages, mirroring native
  /// `SyncManager.syncCoachMessages` → `POST api/sync/coach_messages`
  /// with `SyncCoachMessagesRequest{messages}` (JotApi.kt). True
  /// only on the same Round 57 full-batch verification as
  /// [syncCoachSessions].
  Future<bool> syncCoachMessages(
      List<Map<String, dynamic>> messages) async {
    final res = await _postJsonMap(
        '/api/sync/coach_messages', {'messages': messages});
    return _syncedAll(res, messages.length);
  }

  /// Round 57 — whether a sync response body proves the server holds
  /// all [sent] rows of the batch. Tolerant of a string count (the
  /// server serializes int8 values as JSON strings elsewhere in its
  /// payloads); null/missing/partial counts are failures.
  static bool _syncedAll(Map<String, dynamic>? res, int sent) {
    if (res == null) return false;
    final synced = _asInt(res['synced']);
    return synced != null && synced == sent;
  }

  /// Round 48 — delete a coach session server-side, mirroring native
  /// `CoachHistoryViewModel.deleteSession` / `CoachViewModel.
  /// deleteCurrentSession` → `DELETE api/sync/coach_sessions/{id}`
  /// (JotApi.kt). True on HTTP 200.
  Future<bool> deleteCoachSession(String id) =>
      _delete('/api/sync/coach_sessions/${Uri.encodeComponent(id)}');

  /// Round 48 — AI title for a new coach session, mirroring native
  /// `LogRepository.generateCoachTitle` → `POST api/ai/coach/title`
  /// with `TitleRequest{firstMessage}` → `TitleResponse{title}`
  /// (JotApi.kt). Null on any failure (native falls back to "Chat").
  Future<String?> fetchCoachTitle(String firstMessage) async {
    final res = await postAi('/api/ai/coach/title', {
      'firstMessage': firstMessage,
    });
    final title = res?['title'];
    if (title is String && title.trim().isNotEmpty) return title.trim();
    return null;
  }

  /// Round 48 — classify a coach-proposed note into a log category,
  /// mirroring native `LogRepository.handleCoachNote` →
  /// `GeminiService.classifyCoachNoteCategory` →
  /// `POST api/ai/classify-coach-note` with
  /// `ClassifyAndCleanRequest{noteText, categories}` (JotApi.kt).
  /// Returns the category id, or null on any failure (native falls
  /// back to category 7, "General").
  Future<int?> classifyCoachNote(
      String noteText, Map<String, String> categories) async {
    final res = await postAi('/api/ai/classify-coach-note', {
      'noteText': noteText,
      'categories': categories,
    });
    final result = res?['result'];
    if (result is Map<String, dynamic>) {
      return _asInt(result['categoryId']);
    }
    return null;
  }

  /// Round 48 — push knowledge documents, mirroring native
  /// `SyncManager.syncDocuments` → `POST api/sync/documents` with
  /// `SyncDocumentsRequest{documents}` (JotApi.kt).
  ///
  /// Round 65 — upgraded to the Round 57 verified pattern: true
  /// only when the restored handler's `{synced: n}` accounts for
  /// EVERY row sent. The handler counts rows an idempotent retry
  /// already stored, so an exact match is the honest success test;
  /// a 200 without a usable count (or a partial count) fails
  /// closed — the pre-R65 status-only check could report a save
  /// the server never stored.
  Future<bool> syncDocuments(List<Map<String, dynamic>> documents) async {
    final res =
        await _postJsonMap('/api/sync/documents', {'documents': documents});
    return _syncedAll(res, documents.length);
  }

  /// Round 65 — delete one knowledge document, mirroring native
  /// `LogRepository.deleteDocument` → `DELETE api/sync/documents/{id}`
  /// (JotApi.kt). True on HTTP 200.
  Future<bool> deleteDocument(String id) =>
      _delete('/api/sync/documents/${Uri.encodeComponent(id)}');

  /// Round 65 — fetch one document's base64 file data, mirroring
  /// native's restore read `GET api/sync/documents/{id}` decoded as
  /// `AiResponse<String>` (JotApi.kt). The restored handler carries
  /// the bytes under BOTH `result` (the field native reads) and
  /// `fileData`; either is accepted. Null on any failure.
  Future<String?> fetchDocumentData(String id) async {
    final res =
        await _getJson('/api/sync/documents/${Uri.encodeComponent(id)}');
    if (res == null) return null;
    final result = res['result'];
    if (result is String && result.isNotEmpty) return result;
    final fileData = res['fileData'];
    if (fileData is String && fileData.isNotEmpty) return fileData;
    return null;
  }

  /// Round 65 — extraction, mirroring native
  /// `GeminiService.processDocumentFile` → `POST api/ai/process-document`
  /// with `ProcessDocumentRequest{mimeType, base64Data}` (JotApi.kt)
  /// → `AiResponse<String>.result`: the Gemini transcription of the
  /// document, produced server-side. Returns the text (possibly
  /// empty when nothing readable was found), or null on any failure
  /// (transport, non-200, malformed body) — callers surface the
  /// failure as an honest extraction state, never a fake ready.
  Future<String?> processDocument(String mimeType, String base64Data) async {
    final res = await postAi('/api/ai/process-document', {
      'mimeType': mimeType,
      'base64Data': base64Data,
    });
    final result = res?['result'];
    return result is String ? result : null;
  }

  /// Authenticated POST returning the decoded JSON body on HTTP 200,
  /// null on any failure (transport, non-200, malformed body).
  Future<Map<String, dynamic>?> _postJsonMap(
      String path, Map<String, dynamic> body) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        ));
    if (response == null || response.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Round 18 — authenticated POST to an `api/ai/*` endpoint with a JSON
  /// body → decoded JSON object, or null on any failure. Used by the
  /// AI-backed tools (food checker, tips, coach). The token is used
  /// only in the header; never logged.
  Future<Map<String, dynamic>?> postAi(
      String path, Map<String, dynamic> body) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        ));
    if (response == null || response.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Round 66 — status-carrying variant of [postAi] for the clinical
  /// report call (`POST /api/ai/report`, native
  /// `GeminiService.getMedicalReportSummaryFromSnapshot`): native
  /// captures the HTTP status + the server's `error`/`message` field
  /// so its failure-reason mapping can tell a 401 from a 429 from a
  /// 5xx. Returns `(statusCode: null, ...)` when no HTTP response
  /// arrived, with `transportFailure` classifying why: the shared
  /// transport timeout, a genuine no-response transport failure, or
  /// no stored session (no request attempted). The server error
  /// text is returned for INTERNAL mapping only — callers must map
  /// it to a plain-language reason and never render it (native
  /// `AiFailureReasons` reads only the status).
  Future<
      ({
        int? statusCode,
        Map<String, dynamic>? body,
        String? serverError,
        AiTransportFailure? transportFailure,
      })> postAiDetailed(String path, Map<String, dynamic> body,
          {Duration? timeoutOverride}) async {
    // This call — and only this call — runs on the dedicated
    // [aiRequestTimeout] budget (60s, native's per-attempt cap);
    // the shared 20s [requestTimeout] is unchanged for every
    // other call. Its timeout (and every other no-response
    // outcome) is CLASSIFIED instead of collapsed to a bare null
    // (Juno Ruling 3). [timeoutOverride] is a test seam.
    final sent = await _sendAuthedDetailed(
      (token) => _client.post(
        Uri.parse('$_baseUrl$path'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      ),
      timeout: timeoutOverride ?? aiRequestTimeout,
    );
    final response = sent.response;
    if (response == null) {
      return (
        statusCode: null,
        body: null,
        serverError: null,
        transportFailure: sent.failure,
      );
    }
    Map<String, dynamic>? decoded;
    try {
      final d = jsonDecode(response.body);
      if (d is Map<String, dynamic>) decoded = d;
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode == 200) {
      return (
        statusCode: 200,
        body: decoded,
        serverError: null,
        transportFailure: null,
      );
    }
    // Native error extraction (GeminiService): `error`, else
    // `message`, else the raw body.
    String? serverError;
    if (decoded != null) {
      final e = decoded['error'] ?? decoded['message'];
      if (e != null) serverError = '$e';
    }
    serverError ??= response.body.isEmpty ? null : response.body;
    return (
      statusCode: response.statusCode,
      body: null,
      serverError: serverError,
      transportFailure: null,
    );
  }

  /// Current/best streak from `/api/sync/pull`. Nulls on any failure —
  /// the streak row renders "--".
  Future<({int? current, int? best})> fetchStreak() async {
    // Oct 26, 2026 — reads through the shared TTL pull cache like
    // every other pull view (fetchSyncPull); write paths invalidate
    // or epoch-guard the cache, so the streak cannot go stale past a
    // local write.
    final body = await fetchSyncPull();
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
    // Shared TTL pull cache; see fetchStreak.
    final body = await fetchSyncPull();
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
  /// Empty list on any failure — see [fetchHabitsOrNull] for the
  /// failure-distinguishing variant.
  Future<List<HabitDto>> fetchHabits() async =>
      await fetchHabitsOrNull() ?? const [];

  /// Round 48 (Vera R47 ledger) — nullable variant of [fetchHabits]:
  /// returns null when the fetch itself failed (no token, transport
  /// error, non-200, malformed body, or a body whose `habits` is
  /// not a list), and the parsed list — possibly empty — only when
  /// the server actually answered. Callers that already hold a list
  /// (the Habits screen's post-write refresh) use this to tell
  /// "the server has no habits" apart from "the refresh failed",
  /// so a failed refresh preserves the on-screen list instead of
  /// blanking it to the empty state until the next load.
  /// Oct 26, 2026 — `GET /api/habits` gets the same treatment as the
  /// sync pull: a STATIC session-keyed TTL cache + single-flight. It
  /// previously had neither, so every Habits-screen entry, Today
  /// Summary build, and repository read paid its own round-trip.
  /// Failures (null) are never cached — a failed read must not blank
  /// habits for the TTL window. Every successful habit write
  /// ([logHabit], [createHabit], [deleteHabit]) invalidates.
  static final Map<
      (String, String?),
      ({
        List<HabitDto> habits,
        DateTime at,
      })> _habitsCacheBySession = {};
  static final Map<(String, String?), Future<List<HabitDto>?>>
      _habitsInFlight = {};

  /// Drops the cached habits list for every session. Called after
  /// successful habit writes so post-write re-fetches stay honest.
  void invalidateHabits() {
    _habitsCacheBySession.clear();
  }

  /// Test-only: clears the shared pull/habits caches so suites that
  /// reuse one session token across cases stay isolated (production
  /// has exactly one session; the caches are keyed by it).
  @visibleForTesting
  static void debugResetSharedCaches() {
    _syncPullCacheBySession.clear();
    _habitsCacheBySession.clear();
    _habitsInFlight.clear();
  }

  Future<List<HabitDto>?> fetchHabitsOrNull() async {
    final key = await _sessionKey();
    if (key != null) {
      final entry = _habitsCacheBySession[key];
      if (entry != null &&
          DateTime.now().difference(entry.at) < syncPullTtl) {
        return entry.habits;
      }
      final inFlight = _habitsInFlight[key];
      if (inFlight != null) return inFlight;
    }
    late final Future<List<HabitDto>?> future;
    future = _fetchHabitsUncached().whenComplete(() {
      if (key != null && identical(_habitsInFlight[key], future)) {
        _habitsInFlight.remove(key);
      }
    });
    if (key != null) _habitsInFlight[key] = future;
    final result = await future;
    if (result != null && key != null) {
      _habitsCacheBySession[key] = (habits: result, at: DateTime.now());
    }
    return result;
  }

  Future<List<HabitDto>?> _fetchHabitsUncached() async {
    final body = await _getJson('/api/habits');
    if (body == null) return null;
    final habits = body['habits'];
    if (habits is! List) return null;
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
    // Shared TTL pull cache; see fetchStreak.
    final body = await fetchSyncPull();
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

  // ── Round 19 — Quick Log ─────────────────────────────────────────
  //
  // Native source of truth for every one of these is the sync pull
  // (`GET /api/sync/pull`, native `SyncManager.pullAllData()`):
  // - membership: the pull's `isUnlimited`/`isAdmin` fields (server
  //   `src/routes/sync.js`: isUnlimited = isAdmin || users.is_unlimited;
  //   isAdmin = ADMIN_EMAILS.contains(email) || users.is_admin). Native
  //   writes both into DataStore and gates AI features on isUnlimited.
  // - categories: the pull's `categories[]` — native inserts them into
  //   the local DB on every pull, so the server set is authoritative
  //   (includes the user's customized categories).
  // - entries: the pull's `entries[]` (his ~580), ordered timestamp DESC
  //   by the server.
  //
  // AI suggestions: `POST /api/ai/suggestions`
  // `{category, recentEntries, userContext, knowledgeBase, weatherContext}`
  // → `{result: [...]}` (native `GeminiService.getSuggestions` via
  // Retrofit `JotApi.getSuggestions`).
  //
  // Entry writes: `POST /api/sync/entries` `{entries: [...]}` — server
  // upserts on `(user_id, local_id)`; new rows use max(existing id)+1,
  // mirroring the local autoincrement ids native inserts carry.

  /// Round 19 — admin flag from the sync pull. False when unknown.
  Future<bool> fetchIsAdmin() async {
    final body = await fetchSyncPull();
    return body?['isAdmin'] == true;
  }

  /// Round 19 — the membership gate native uses for AI features.
  /// `fetchIsUnlimited` (round 18) already reads the pull's
  /// `isUnlimited`, which the server computes as
  /// `isAdmin || users.is_unlimited` — so admins are covered.
  Future<({bool isUnlimited, bool isAdmin})> fetchMembership() async {
    final body = await fetchSyncPull();
    if (body == null) return (isUnlimited: false, isAdmin: false);
    final isAdmin = body['isAdmin'] == true;
    final isUnlimited = body['isUnlimited'] == true || isAdmin;
    return (isUnlimited: isUnlimited, isAdmin: isAdmin);
  }

  /// Round 19 — full log-entry rows from the sync pull. Malformed rows
  /// are skipped; never throws.
  Future<List<QuickLogEntry>> fetchLogEntryDtos() async {
    final body = await fetchSyncPull();
    final entries = body?['entries'];
    if (entries is! List) return const [];
    final out = <QuickLogEntry>[];
    for (final e in entries) {
      if (e is Map<String, dynamic>) {
        try {
          out.add(QuickLogEntry.fromJson(e));
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }

  /// Round 19 — the account's real category set from the sync pull.
  /// Empty (never hardcoded) when unreachable — the UI shows an honest
  /// empty/error state instead of a fallback list.
  Future<List<QuickLogCategory>> fetchLogCategories() async {
    final body = await fetchSyncPull();
    final categories = body?['categories'];
    if (categories is! List) return const [];
    final out = <QuickLogCategory>[];
    for (final c in categories) {
      if (c is Map<String, dynamic>) {
        try {
          out.add(QuickLogCategory.fromJson(c));
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }

  /// Round 19 — AI insights from the sync pull (with `entryId`, so the
  /// original entry can be linked — native's history tab shows it).
  Future<List<QuickLogInsight>> fetchLogInsights() async {
    final body = await fetchSyncPull();
    final insights = body?['insights'];
    if (insights is! List) return const [];
    final out = <QuickLogInsight>[];
    for (final i in insights) {
      if (i is Map<String, dynamic>) {
        try {
          out.add(QuickLogInsight.fromJson(i));
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }

  /// Round 19 — `POST /api/sync/entries` `{entries: [...]}`.
  /// Returns true on 200.
  Future<bool> postLogEntries(List<QuickLogEntry> entries) {
    return _postJson(
      '/api/sync/entries',
      {'entries': entries.map((e) => e.toSyncJson()).toList()},
    );
  }

  /// Round 19 — `POST /api/sync/categories` with the FULL category list.
  /// The server deletes any server-side categories missing from the
  /// payload, so callers must always send the complete set (this is how
  /// both add and delete are performed — the server has no single-row
  /// category DELETE route).
  Future<bool> postLogCategories(List<QuickLogCategory> categories) {
    return _postJson(
      '/api/sync/categories',
      {'categories': categories.map((c) => c.toSyncJson()).toList()},
    );
  }

  /// Round 19 — `DELETE /api/sync/entries/{localId}`.
  Future<bool> deleteLogEntry(int id) => _delete('/api/sync/entries/$id');

  /// Round 19 — AI chip suggestions via the real backend endpoint.
  /// `category` and each recent entry are sent as the native DTO shapes;
  /// `knowledgeBase` is always `""` (native omits it from chip
  /// suggestions to stay under the TPM limit). Returns the chip list,
  /// or null on any failure (caller shows the honest error state).
  Future<List<String>?> postSuggestions({
    required QuickLogCategory category,
    required List<QuickLogEntry> recentEntries,
    required String userContext,
    String? weatherContext,
  }) async {
    final res = await postAi('/api/ai/suggestions', {
      'category': category.toSyncJson(),
      'recentEntries': recentEntries.map((e) => e.toSyncJson()).toList(),
      'userContext': userContext,
      'knowledgeBase': '',
      'weatherContext': weatherContext,
    });
    final result = res?['result'];
    if (result is! List) return null;
    return result.map((c) => '$c').toList();
  }

  /// Round 32 — AI category generation for onboarding's setup step,
  /// mirroring native `GeminiService.generateCategories`
  /// (GeminiService.kt:65-95) → `POST /api/ai/generate-categories`
  /// with `{"userContext": ...}` (JotApi.kt:616-617,
  /// `GenerateCategoriesRequest`), returning the `result` name list.
  /// Null on any failure — the caller falls back to native's default
  /// category names, exactly as native does.
  Future<List<String>?> generateCategories(String userContext) async {
    final res = await postAi('/api/ai/generate-categories', {
      'userContext': userContext,
    });
    final result = res?['result'];
    if (result is! List) return null;
    return result.map((c) => '$c').toList();
  }

  // ── Round 29 — Settings ──────────────────────────────────────────
  //
  // Native evidence (data/remote/JotApi.kt):
  // - `POST api/sync/profile` (:665-666) with `SyncProfileRequest`
  //   (:219-261, every field nullable). Native `SyncManager.
  //   pushProfileData` sends the profile fields the Settings setters
  //   mutate (userContext, age/heightCm/weightKg/gender,
  //   autoAiSuggestions, shareDataWithFriends, hrSpikeAlertsEnabled,
  //   spikeThreshold, hrDeltaEnabled, spikeDeltaThreshold,
  //   habitReminderEnabled, projectReminderEnabled,
  //   eventReminderEnabled, eventCounters, counterHistory,
  //   professionalUpdates, knowledgeBase, medications, conditions).
  //   Only the changed keys are sent here; omitted keys stay untouched
  //   server-side (native sync comments rely on the same COALESCE
  //   behaviour for null fields).
  // - `POST api/auth/update-nickname` (:577-578) `{nickname}` →
  //   `{success, nickname, tag, error}` (:478-488).
  // - `POST api/auth/logout` (:586-587) `{refreshToken}` (:178).
  // - `DELETE api/auth/delete-account` (:580-581) → GenericResponse.

  /// Round 29 — partial profile push via `POST /api/sync/profile`.
  ///
  /// Counter-mutation durability (Oct 2026): a successful push bumps
  /// the app-wide profile-mutation epoch (see [_profileMutationEpoch])
  /// — any sync pull that started before this push is discarded on
  /// landing and re-issued once, and every TTL-cached pull body from
  /// before this push becomes unservable on every instance.
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    final ok = await _postJson('/api/sync/profile', fields);
    if (ok) _profileMutationEpoch++;
    return ok;
  }

  /// Phase 1, item 2a — append-only medication change events via
  /// `POST /api/sync/medication-events` with `{"events": [...]}`
  /// (spec §2.6). Insert-only server-side (ON CONFLICT DO
  /// NOTHING on the client-supplied event id — replays are
  /// harmless). True on HTTP 200; callers emit best-effort after
  /// a successful profile push and swallow failures (see
  /// `medication_change_events.dart`).
  Future<bool> postMedicationChangeEvents(
      List<MedicationChangeEvent> events) {
    return _postJson('/api/sync/medication-events', {
      'events': events.map((e) => e.toJson()).toList(),
    });
  }

  /// Phase 1, item 2b — reads the append-only medication change
  /// events via `GET /api/sync/medication-events` →
  /// `{success: true, events: [...]}` OLDEST FIRST, each event in
  /// the client contract shape (see [MedicationChangeEvent]).
  /// Follows the file's list-fetch precedent: an empty list on
  /// ANY failure (transport, non-200, `success != true`, or a
  /// body without a usable `events` list) — indistinguishable
  /// from a genuinely empty history at this layer, and the
  /// timeline screen renders its honest empty changes state from
  /// it (seeded markers and scores still render). Malformed
  /// event rows are skipped; never throws.
  Future<List<MedicationChangeEvent>> fetchMedicationChangeEvents() async {
    final body = await _getJson('/api/sync/medication-events');
    if (body == null || body['success'] != true) return const [];
    final raw = body['events'];
    if (raw is! List) return const [];
    final out = <MedicationChangeEvent>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) {
        try {
          out.add(MedicationChangeEvent.fromJson(e));
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }

  /// Round 29 — nickname update. Returns the decoded body on HTTP 200
  /// (callers check `success`), null on any failure.
  Future<Map<String, dynamic>?> updateNickname(String nickname) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/auth/update-nickname'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'nickname': nickname}),
        ));
    if (response == null || response.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Round 29 — server logout (revokes the refresh token), mirroring
  /// native `SettingsViewModel.logout` step 1. Best-effort: native
  /// proceeds with local cleanup even when this call fails, so callers
  /// treat the result as informational.
  Future<bool> logoutAccount() async {
    String? refresh;
    try {
      refresh = await _sessionStore.readRefreshToken();
    } catch (_) {
      refresh = null;
    }
    if (refresh == null || refresh.isEmpty) return false;
    // Round 31 — logout is a PUBLIC auth endpoint in the native
    // interceptor: it must NOT go through the 401→refresh path.
    return _postJson('/api/auth/logout', {'refreshToken': refresh},
        allowRefresh: false);
  }

  /// Round 29 — permanent account deletion, mirroring native
  /// `LogRepository.deleteAccountData()` step 1. True only on HTTP 200;
  /// callers must NOT clear the local session on failure (native keeps
  /// the account and surfaces the error).
  Future<bool> deleteAccount() => _delete('/api/auth/delete-account');

  // ── Takeover Phase 2 — Play Billing endpoints ────────────────────
  //
  // Server side is COMPLETE and authoritative (P0-billing §3); these
  // are thin client wrappers over the two existing routes — no
  // server change exists or is needed:
  // - `POST /api/billing/verify` `{productId, purchaseToken,
  //   quantity}` → `{success, isUnlimited}` or an error body. A
  //   purchase token verifies EXACTLY ONCE server-side (double-credit
  //   guard), so callers get the raw status + body, not a bool: the
  //   "already been processed" error is a distinct, meaningful state
  //   for the billing module (see billing_service.dart).
  // - `POST /api/billing/sync-subscriptions` `{activeTokens}` →
  //   `{success, isUnlimited}` — the restore/revoke reconciliation.
  //   An empty token list REVOKES server-side, so this must only be
  //   called with the store's real owned-purchase tokens.

  /// Verify one Play purchase with the server. Returns the HTTP
  /// status and decoded body (null body on transport failure or an
  /// undecodable response). The purchase token travels only in the
  /// request body over HTTPS — never logged.
  Future<({int? statusCode, Map<String, dynamic>? body})>
      verifyBillingPurchase({
    required String productId,
    required String purchaseToken,
    int quantity = 1,
  }) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/billing/verify'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'productId': productId,
            'purchaseToken': purchaseToken,
            'quantity': quantity,
          }),
        ));
    if (response == null) return (statusCode: null, body: null);
    try {
      final decoded = jsonDecode(response.body);
      return (
        statusCode: response.statusCode,
        body: decoded is Map<String, dynamic> ? decoded : null,
      );
    } catch (_) {
      return (statusCode: response.statusCode, body: null);
    }
  }

  /// Reconcile subscription state with the server from the store's
  /// currently owned purchase tokens. Returns the server's
  /// `isUnlimited`, or null when the call failed (unknown — NOT the
  /// same as "not premium").
  Future<bool?> syncBillingSubscriptions(List<String> activeTokens) async {
    final body = await _postJsonMap('/api/billing/sync-subscriptions', {
      'activeTokens': activeTokens,
    });
    if (body == null || body['success'] != true) return null;
    return body['isUnlimited'] == true;
  }

  /// Round 30 — link a Google account, mirroring native
  /// `SettingsViewModel.connectGoogleAccount` (SettingsViewModel.kt:
  /// 218-241) → `POST api/auth/link-google` (JotApi.kt:589-590) with
  /// `LinkGoogleRequest{idToken}` (JotApi.kt:133). Returns the decoded
  /// `GenericResponse` body ({success, message, error}, JotApi.kt:
  /// 146-150) on HTTP 200, null on any transport failure. The ID token
  /// is sent only in this request body — never logged. Native fails
  /// closed: local connected state changes only when the body reports
  /// success, and the caller enforces that.
  ///
  /// Round 31 fix pass (Vera SHOULD-FIX 2): routes through
  /// [_sendAuthed] like every other authenticated call, so an
  /// expired access token refreshes and retries once instead of
  /// failing silently. Non-401 semantics unchanged: decoded body on
  /// HTTP 200, null on anything else.
  Future<Map<String, dynamic>?> linkGoogle(String idToken) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/auth/link-google'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'idToken': idToken}),
        ));
    if (response == null || response.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Round 30 — disconnect the linked Google account, mirroring
  /// native `SettingsViewModel.disconnectGoogleAccount`
  /// (SettingsViewModel.kt:243-263) → `POST api/auth/disconnect-google`
  /// (JotApi.kt:592-593). Returns the decoded `GenericResponse` body
  /// on HTTP 200, null on any transport failure. Native treats the
  /// disconnect as done only when the body carries no error (the
  /// server refuses to remove the last usable sign-in method), and
  /// preserves local state otherwise — the caller enforces that.
  ///
  /// Round 31 fix pass (Vera SHOULD-FIX 2): routes through
  /// [_sendAuthed] like [linkGoogle] — an expired access token
  /// refreshes and retries once. Non-401 semantics unchanged.
  Future<Map<String, dynamic>?> disconnectGoogle() async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/auth/disconnect-google'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(const <String, dynamic>{}),
        ));
    if (response == null || response.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Authenticated POST with a JSON body → true on HTTP 200.
  /// Token used only in the header; never logged.
  ///
  /// Round 31 — routes through the 401→refresh→retry-once path
  /// unless [allowRefresh] is false (public auth endpoints such as
  /// logout, which native never intercepts).
  Future<bool> _postJson(String path, Map<String, dynamic> body,
      {bool allowRefresh = true}) async {
    if (!allowRefresh) {
      final token = await _sessionStore.readToken();
      if (token == null || token.trim().isEmpty) return false;
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
        return response.statusCode == 200;
      } catch (_) {
        return false;
      }
    }
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        ));
    return response?.statusCode == 200;
  }

  /// Authenticated DELETE → true on HTTP 200.
  Future<bool> _delete(String path) async {
    final response = await _sendAuthed((token) => _client.delete(
          Uri.parse('$_baseUrl$path'),
          headers: {'Authorization': 'Bearer $token'},
        ));
    return response?.statusCode == 200;
  }

  /// Authenticated GET → decoded JSON object, or null on any failure.
  /// The token is used only here, in the header; never logged anywhere.
  Future<Map<String, dynamic>?> _getJson(String path) async {
    final response = await _sendAuthed((token) => _client.get(
          Uri.parse('$_baseUrl$path'),
          headers: {'Authorization': 'Bearer $token'},
        ));
    if (response == null || response.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
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
    return FriendDto(
      id: '${json['id'] ?? ''}',
      nickname: '${json['nickname'] ?? ''}',
      tag: '${json['tag'] ?? ''}',
      status: '${json['status'] ?? ''}',
      // Tolerant: server numbers may arrive as strings.
      level: TabsBackend._asInt(json['level']) ?? 0,
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

  /// Round 48 — the pending friend request's id when [type] is
  /// `friend_request` (native `FriendNotificationDto.friendRequestId`,
  /// JotApi.kt). Round 18's port dropped this field, which is why
  /// accept/decline was impossible; native renders the buttons only
  /// when it is non-null.
  final int? friendRequestId;

  const FriendNotificationDto({
    required this.id,
    required this.type,
    required this.message,
    required this.isRead,
    required this.createdAt,
    this.senderNickname,
    this.senderTag,
    this.friendRequestId,
  });

  factory FriendNotificationDto.fromJson(Map<String, dynamic> json) {
    return FriendNotificationDto(
      // Tolerant: server numbers may arrive as strings.
      id: TabsBackend._asInt(json['id']) ?? 0,
      type: '${json['type'] ?? ''}',
      message: '${json['message'] ?? ''}',
      isRead: json['isRead'] == true,
      createdAt: '${json['createdAt'] ?? ''}',
      senderNickname: json['senderNickname']?.toString(),
      senderTag: json['senderTag']?.toString(),
      friendRequestId: TabsBackend._asInt(json['friendRequestId']),
    );
  }

  FriendNotificationDto copyWith({bool? isRead}) {
    return FriendNotificationDto(
      id: id,
      type: type,
      message: message,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt,
      senderNickname: senderNickname,
      senderTag: senderTag,
      friendRequestId: friendRequestId,
    );
  }
}

/// Round 48 — one friend's shared today stats from
/// `GET /api/friends/data/{friendId}`. Mirrors native
/// `FriendDetailDto` (JotApi.kt). Every stat is nullable: native
/// renders "·" for a missing stat, and [sharingEnabled] false shows
/// the "turned off data sharing" state instead of stats.
class FriendDetail {
  final String friendId;
  final String nickname;
  final String tag;
  final bool sharingEnabled;
  final int? todaySleepMins;
  final int? todayAvgHr;
  final int? todayScore;
  final int? todaySpikes;
  final int? todaySleepDebt;

  const FriendDetail({
    required this.friendId,
    required this.nickname,
    required this.tag,
    required this.sharingEnabled,
    this.todaySleepMins,
    this.todayAvgHr,
    this.todayScore,
    this.todaySpikes,
    this.todaySleepDebt,
  });

  /// Parses the `data` object of a `FriendDetailResponse`. Null when
  /// the payload isn't detail-shaped. Never throws.
  static FriendDetail? fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    try {
      return FriendDetail(
        friendId: '${raw['friendId'] ?? ''}',
        nickname: '${raw['nickname'] ?? ''}',
        tag: '${raw['tag'] ?? ''}',
        sharingEnabled: raw['sharingEnabled'] == true,
        todaySleepMins: TabsBackend._asInt(raw['todaySleepMins']),
        todayAvgHr: TabsBackend._asInt(raw['todayAvgHr']),
        todayScore: TabsBackend._asInt(raw['todayScore']),
        todaySpikes: TabsBackend._asInt(raw['todaySpikes']),
        todaySleepDebt: TabsBackend._asInt(raw['todaySleepDebt']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Round 31 — internal outcome of the single-flight refresh.
/// Never leaves this file; callers of the backend only see the
/// retried response or their normal failure result.
sealed class _RefreshOutcome {
  const _RefreshOutcome();
}

/// Refresh succeeded (or a concurrent caller already rotated the
/// token) — retry the original request with [token].
class _RefreshSucceeded extends _RefreshOutcome {
  final String token;
  const _RefreshSucceeded(this.token);
}

/// Temporary refresh failure — session preserved; the caller gets
/// its original 401 as its normal failure.
class _RefreshTemporary extends _RefreshOutcome {
  const _RefreshTemporary();
}

/// Definitive refresh failure — the session has already been
/// cleared and [TabsBackend.onSessionExpired] fired by the wrapper.
class _RefreshDefinitive extends _RefreshOutcome {
  const _RefreshDefinitive();
}
