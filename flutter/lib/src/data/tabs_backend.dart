import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/daily_score_sync.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';

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

  /// VC 100129 (R-1 F2): the attempt failed BEFORE dispatch —
  /// the request body could not be encoded, or the stored
  /// session token could not be read. No network was involved;
  /// this must never be recorded as a connection failure.
  preDispatch,
}

/// VC 100131 (Round 3) — the outcome of a report-result pickup
/// (`GET /api/ai/report/result/:generationId`, owner-authenticated):
/// the server holds a detached generation's outcome under the
/// client's stable `reportGenerationId`, so a generation whose
/// POST socket died can still be collected. Sealed: every caller
/// handles every shape. Mapping is by HTTP status FIRST, the
/// body's `status` field SECOND (see
/// [TabsBackend.fetchReportPickup]).
sealed class ReportPickupOutcome {
  const ReportPickupOutcome();
}

/// 200 — the held narrative. Fetch-once server-side: the row is
/// gone after a successful delivery, so a later pickup of the
/// same identity answers not-found.
class PickupReady extends ReportPickupOutcome {
  /// The finished narrative, byte-identical to the POST success
  /// body's `result`.
  final String result;

  /// Server completion time, when the body carried one
  /// (`completedAt`, ISO-8601 or epoch ms); informational only.
  final DateTime? completedAt;
  const PickupReady(this.result, {this.completedAt});
}

/// 202 — the detached generation is still running server-side;
/// the caller polls. [retryAfterMs] is the server's hint, when
/// present (the pipeline's poll cadence is its own).
class PickupRunning extends ReportPickupOutcome {
  final int? retryAfterMs;
  const PickupRunning({this.retryAfterMs});
}

/// The stored mapped failure: the generation finished and
/// failed; the server stored ONLY the mapped HTTP status + the
/// generic mapped string. The pipeline records this through the
/// existing AiFailure mapping (status only — [error] is never
/// rendered, exactly like POST serverError).
class PickupFailed extends ReportPickupOutcome {
  final int httpStatus;
  final String? error;
  const PickupFailed(this.httpStatus, {this.error});
}

/// 404 — no such generation for this account: it never reached
/// the server (the pre-dispatch case), was already collected, or
/// never existed. A normal state, NOT an error: callers fall
/// back to a fresh POST with the SAME identity.
class PickupNotFound extends ReportPickupOutcome {
  const PickupNotFound();
}

/// 410 — the generation finished but its held narrative passed
/// the 24 h ceiling and was deleted (content-free tombstone,
/// Juno R8-1). Terminal for that identity: no POST, no retry;
/// the generation ends in the expired presentation state.
class PickupExpired extends ReportPickupOutcome {
  const PickupExpired();
}

/// The pickup ITSELF could not be completed (transport failure,
/// no session, or an unusable response talking to the pickup
/// endpoint). This is NOT a generation failure and must never
/// surface as one: callers fall through to their existing
/// behaviour (a POST dispatch).
class PickupUnreachable extends ReportPickupOutcome {
  const PickupUnreachable();
}

/// VC 100134 Package C — outcome of the authenticated email
/// verification call (`POST /api/auth/verify-email`). Status-first
/// mapping (see [TabsBackend.verifyEmailCode]): 200 is the ONLY
/// distinguishable success; every other definitive server answer
/// collapses to [VerifyEmailRejected] so the client can never
/// become a code-state oracle (Juno §2.2 / Vera R11); transport
/// and 5xx are [VerifyEmailUnreachable].
sealed class VerifyEmailOutcome {
  const VerifyEmailOutcome();
}

class VerifyEmailSuccess extends VerifyEmailOutcome {
  const VerifyEmailSuccess();
}

class VerifyEmailRejected extends VerifyEmailOutcome {
  const VerifyEmailRejected();
}

class VerifyEmailUnreachable extends VerifyEmailOutcome {
  const VerifyEmailUnreachable();
}

/// VC 100134 Package C — outcome of the authenticated resend call
/// (`POST /api/auth/resend-verification`).
sealed class ResendVerificationOutcome {
  const ResendVerificationOutcome();
}

class ResendVerificationSent extends ResendVerificationOutcome {
  const ResendVerificationSent();
}

/// 429 — the server's 60s cooldown (or limiter) is still running;
/// [retryAfterSeconds] is adopted as the new local countdown.
class ResendVerificationCooldown extends ResendVerificationOutcome {
  final int retryAfterSeconds;
  const ResendVerificationCooldown(this.retryAfterSeconds);
}

class ResendVerificationUnreachable extends ResendVerificationOutcome {
  const ResendVerificationUnreachable();
}

/// Any other definitive non-200/non-429 answer — the catch-all
/// failure shape on the screen.
class ResendVerificationFailed extends ResendVerificationOutcome {
  const ResendVerificationFailed();
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
  /// "no connection".
  ///
  /// Phase 3: raised to 90s, the report pipeline's per-attempt
  /// bound (ReportGenerationPipeline.aiAttemptTimeout): the
  /// server is being capped at ~50s per generation attempt with
  /// its own retries, so the client budget must comfortably
  /// exceed ONE full server attempt (1.8× the cap, ~3× the
  /// largest observed successful generation) — a healthy
  /// generation must never be abandoned client-side (Nov 9, 2026:
  /// the server completed a 13,058-char narrative the client had
  /// already walked away from). Whichever of the transport budget
  /// and the pipeline guard fires first, the classification is
  /// the same timeout class.
  static const Duration aiRequestTimeout = Duration(seconds: 90);

  /// R-1 F4 bounds: the refresh path's storage legs and the
  /// wait for an in-flight refresh. A single secure-storage
  /// operation is local and normally sub-second; 10s is far
  /// beyond any legitimate storage latency while still bounding
  /// a wedged Keystore read. The refresh await (45s) covers the
  /// refresh's own 20s network timeout plus its bounded storage
  /// legs with headroom.
  static const Duration refreshStorageTimeout = Duration(seconds: 10);
  static const Duration refreshAwaitTimeout = Duration(seconds: 45);

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
  /// Each entry records the pull-mutation epoch at which its fetch
  /// STARTED (see [_pullMutationEpoch]): a body whose fetch started
  /// before the latest successful profile push or entry write is
  /// never served as fresh, on ANY instance.
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

  /// Daily Summary race (Nov 20, 2026) — the ENTRIES twin of
  /// [_profileMutationEpoch]. Every successful [postLogEntries] and
  /// [deleteLogEntry] bumps it: both mutate the pull's `entries`
  /// view exactly as a profile push mutates its `profile` view.
  /// Before this counter existed, the entries path had NO epoch
  /// protection: a pull that started before a completion's POST
  /// could land after it and be stamped fresh for the full TTL,
  /// and a rapid second completion whose fetch joined that
  /// in-flight pull computed its entry id (maxId + 1) from the
  /// pre-post snapshot — allocating the SAME id as the first
  /// completion, whose server row its POST then upserted over.
  /// The first completion was destroyed in the log itself (the
  /// founder's "if I go too fast it doesn't even mark it done").
  /// Habit log posts do NOT bump it: habits are not pull-visible
  /// (separate /api/habits endpoint, own cache) — the habit
  /// completion ENTRY goes through [postLogEntries] and bumps it
  /// there.
  static int _entriesMutationEpoch = 0;

  /// The freshness epoch every sync-pull consumer checks: a pull
  /// body is fresh only for the combined mutation state in which
  /// its fetch started. Profile pushes and entry writes both move
  /// it, so a body that predates EITHER is never served or cached
  /// as fresh after the write lands.
  static int get _pullMutationEpoch =>
      _profileMutationEpoch + _entriesMutationEpoch;

  /// Round 19 — drops the cached sync pull so the next read hits the
  /// server. Called after local writes (log save/repeat/delete,
  /// category add/delete) so counts and lists refresh honestly.
  /// Oct 26, 2026: clears EVERY session entry — the cache is shared
  /// app-wide now, so one instance's write must invalidate for all.
  /// Nov 20, 2026: also drops the IN-FLIGHT slot. Callers already
  /// assume invalidation means the next read starts a NEW fetch;
  /// before this, a pull already in flight (started by any of the
  /// ~29 instances) was handed to the next reader as-is even when
  /// it started before the write that prompted the invalidation.
  /// Dropping the slot cannot strand its awaiters — they hold the
  /// future itself, whose epoch check still guards what it
  /// delivers — and the slot's completion cleanup is
  /// identical()-guarded, so it never removes a newer fetch.
  void invalidateSyncPull() {
    _syncPullCacheBySession.clear();
    _syncPullInFlight.clear();
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
    // Phase 3: if a token refresh is ALREADY in flight (started
    // by any caller — during a report generation, the collection
    // stage's sync reads), wait for it to settle BEFORE reading
    // the token and firing. The pre-fix code fired immediately
    // with the stale token IN PARALLEL with the refresh: the Nov
    // 9, 2026 report POST took a curable 401 that way, and its
    // refresh-retry landed in the same second as a twin request
    // (only the 401 kept the first from reaching Gemini). Waiting
    // here makes every authed call — the report call included —
    // order itself after the refresh instead of racing it. The
    // refresh future never completes with an error
    // ([_performRefresh] classifies every outcome), so awaiting
    // it cannot throw; the token read below then sees the rotated
    // pair the refresh saved (or the unchanged pair after a
    // temporary failure, whose 401 path below still applies).
    final refreshInFlight = _refreshInFlight;
    if (refreshInFlight != null) {
      // R-1 F4: this await is bounded — the refresh's network leg
      // carries its own 20s timeout and its storage legs are
      // bounded by [refreshStorageTimeout], so 45s comfortably
      // covers a legitimate refresh; a wedged refresh must not
      // wedge every authed call behind it. On timeout we proceed
      // to the token read, exactly as if the refresh had settled.
      try {
        await refreshInFlight.timeout(refreshAwaitTimeout);
      } on TimeoutException {
        // Proceed: the token read below sees whatever is stored.
      }
    }
    // R-1 F2: a token-read throw is a pre-dispatch failure with
    // its own honest class — previously it propagated to the
    // pipeline's catch-all and recorded as unknown/fatal.
    final String? token;
    try {
      token = await _sessionStore.readToken();
    } catch (_) {
      return (response: null, failure: AiTransportFailure.preDispatch);
    }
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
      final current =
          await _sessionStore.readToken().timeout(refreshStorageTimeout);
      if (current != null &&
          current.trim().isNotEmpty &&
          current != failedToken) {
        return _RefreshSucceeded(current);
      }
      final refreshToken = await _sessionStore
          .readRefreshToken()
          .timeout(refreshStorageTimeout);
      if (refreshToken == null || refreshToken.trim().isEmpty) {
        // A null/empty refresh-token READ is a local storage
        // outcome, NOT a server verdict: the server was never
        // asked, so it cannot have revoked anything. A transient
        // per-key secure-storage hiccup (e.g. an
        // EncryptedSharedPreferences/Keystore read coming back
        // empty for this one key on the first launch after an
        // update) must not destroy the session — this branch used
        // to route to _definitiveFailure and wipe the stored
        // session with zero server trace (the Nov 8, 2026 spurious
        // logout). Treat it exactly like a storage throw (caught
        // below): temporary failure, session preserved, the next
        // call/open retries the refresh. Only an actual server
        // response classified [RefreshDefinitiveFailure] by
        // [AuthApiClient.refreshSession] may clear the session.
        // This also covers the WorkManager background isolate,
        // which runs this same code with no onSessionExpired
        // registered: a local read outcome there must never wipe
        // the shared stored session silently either.
        return const _RefreshTemporary();
      }
      final result = await _authApi.refreshSession(refreshToken);
      if (result is RefreshSuccess) {
        // Both tokens rotate; the stored email stays unchanged.
        //
        // H1-02: the server has ALREADY rotated the refresh
        // token and invalidated the old one at this point, so
        // the rotated pair must ALWAYS be persisted — no
        // subsequent storage read may be able to discard it.
        // The pre-fix code read the email here inside the
        // outer try: a throwing readEmail escaped before
        // saveSession, the outer catch returned a temporary
        // failure, and the next refresh presented the old,
        // already-rotated token — which the server reads as
        // reuse and kills the session. A null read was just
        // as bad in the other direction: it persisted
        // user_email as '', silently unbinding every
        // email-scoped local store. The email read is now
        // isolated in its own try: on a throw, null, or empty
        // read the pair is saved token-only, leaving the
        // previously stored email untouched.
        String? email;
        try {
          email = await _sessionStore
              .readEmail()
              .timeout(refreshStorageTimeout);
        } catch (_) {
          email = null;
        }
        if (email != null && email.isNotEmpty) {
          await _sessionStore
              .saveSession(
                token: result.token,
                refreshToken: result.refreshToken,
                email: email,
              )
              .timeout(refreshStorageTimeout);
        } else {
          await _sessionStore
              .saveRotatedTokens(
                token: result.token,
                refreshToken: result.refreshToken,
              )
              .timeout(refreshStorageTimeout);
        }
        return _RefreshSucceeded(result.token);
      }
      if (result is RefreshDefinitiveFailure) {
        return await _definitiveFailure();
      }
      if (result is RefreshAlreadyRotated) {
        // Server grace response: the refresh token this call
        // presented had JUST been rotated — a racing isolate
        // (typically the WorkManager background isolate replaying
        // the token, or this app replaying the background's) won
        // the rotation, and the winner saves the rotated pair to
        // the shared session store. Re-read the stored pair NOW:
        // if storage already holds a DIFFERENT access token than
        // the one that failed, continue with it — the session
        // heals itself with no re-login. If storage still holds
        // the failed token (or none), fall through to the
        // temporary outcome. This path NEVER reaches
        // _definitiveFailure and never clears the session.
        final storedPair = (
          token: await _sessionStore
              .readToken()
              .timeout(refreshStorageTimeout),
          refreshToken: await _sessionStore
              .readRefreshToken()
              .timeout(refreshStorageTimeout),
        );
        final storedToken = storedPair.token;
        if (storedToken != null &&
            storedToken.trim().isNotEmpty &&
            storedToken != failedToken) {
          return _RefreshSucceeded(storedToken);
        }
      }
      return const _RefreshTemporary();
    } catch (_) {
      // Storage surprise mid-refresh: preserve the session.
      return const _RefreshTemporary();
    }
  }

  /// Definitive failure handling — the ONE place the session is
  /// cleared on refresh rejection. Clears first, then notifies.
  ///
  /// INVARIANT: this is reachable ONLY on an actual server verdict
  /// — a [RefreshDefinitiveFailure] returned by
  /// [AuthApiClient.refreshSession] from a real refresh response
  /// (HTTP 401/403, or a 200 body carrying a classified error).
  /// No local condition (a null/empty/throwing storage read, in
  /// the foreground or in the WorkManager background isolate) may
  /// route here: local outcomes are temporary failures and the
  /// session is preserved.
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

  /// One epoch-checked sync-pull GET: records the pull-mutation
  /// epoch at start; when the body lands after a successful profile
  /// push OR entry write (epoch moved), the body predates that
  /// write — discard it and re-issue the GET. The re-issue LOOPS
  /// while the epoch keeps moving (bounded at [_maxPullReissues]
  /// re-issues): a second write landing during the first re-issue
  /// must not let a body that predates it be delivered as fresh
  /// (Vera F3 — bulk archive in quick succession hit exactly that
  /// window).
  /// [fetchEpoch] is the epoch at which the fetch that produced
  /// [body] STARTED, so callers can refuse to cache a body that
  /// predates the latest write. If the bound is exhausted with the
  /// epoch STILL moving, delivery is refused outright (null body —
  /// the caller's ordinary failed-pull path) rather than handing
  /// out a body known to predate the latest write: a non-null body
  /// from this method always started at the current epoch.
  static const int _maxPullReissues = 3;

  Future<({Map<String, dynamic>? body, int fetchEpoch})>
      _getSyncPullEpochChecked() async {
    var fetchEpoch = _pullMutationEpoch;
    var body = await _getJson('/api/sync/pull');
    var reissues = 0;
    while (body != null &&
        _pullMutationEpoch != fetchEpoch &&
        reissues < _maxPullReissues) {
      reissues++;
      fetchEpoch = _pullMutationEpoch;
      body = await _getJson('/api/sync/pull');
    }
    if (body != null && _pullMutationEpoch != fetchEpoch) {
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
  /// still equals the current pull-mutation epoch — a successful
  /// profile push OR entry write on ANY instance makes every older
  /// cached body unservable, not just this instance's (the pre-fix
  /// per-instance invalidation in `_pushProfile` could not see
  /// other instances).
  Future<Map<String, dynamic>?> fetchSyncPull() async {
    final key = await _sessionKey();
    if (key != null) {
      final entry = _syncPullCacheBySession[key];
      if (entry != null &&
          entry.epoch == _pullMutationEpoch &&
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
  /// `POST /api/habits` with `{"title": ..., "target_time": ...}`
  /// → `{"habit": {...}}`. Returns the created habit, or null on any
  /// failure (the caller keeps the honest error path and re-fetches).
  /// Accepts 200 or 201 (resource-created) like the native client's
  /// 2xx handling; every other status is a failure.
  ///
  /// VC 100137 — [targetTime] is the stored-format value: exactly
  /// `'Anytime'` (the default, native parity) or a zero-padded 24h
  /// `'HH:mm'` string. It is sent verbatim; formatting/validation
  /// of a picked time lives in `habit_time.dart`.
  ///
  /// Fix-round hardening: a 2xx response whose body lacks a usable
  /// `habit` object is still a SUCCESS — the POST itself landed, so
  /// reporting failure would invite a retry that creates a
  /// duplicate. A placeholder carrying the requested title is
  /// returned and the caller's re-fetch confirms the real row.
  Future<HabitDto?> createHabit(String title,
      {String targetTime = 'Anytime'}) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/habits'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'title': title, 'target_time': targetTime}),
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
    return HabitDto(
        id: '', title: title, logs: const [], targetTime: targetTime);
  }

  /// VC 100137 — set (or clear) a habit's scheduled time:
  /// `PATCH /api/habits/{id}` with `{"target_time": ...}` →
  /// `{"habit": {...}}`. [targetTime] is the stored format
  /// (`'Anytime'` or zero-padded 24h `'HH:mm'`). True ONLY on
  /// HTTP 200; 400 (invalid value) and 404 (missing / not owned)
  /// are failures, as are transport failure and no session. The
  /// habits cache is invalidated on success only, so a caller's
  /// re-fetch sees the new value.
  ///
  /// There is no generic PATCH helper in this file (checked:
  /// `_postJson`/`_postJsonMap` are POST-only, `_delete` is
  /// DELETE-only), so this routes through [_sendAuthed] directly,
  /// exactly like [createHabit] does for its POST — the 401 →
  /// refresh → retry-once semantics are identical.
  Future<bool> updateHabitTargetTime({
    required String habitId,
    required String targetTime,
  }) async {
    final response = await _sendAuthed((token) => _client.patch(
          Uri.parse(
              '$_baseUrl/api/habits/${Uri.encodeComponent(habitId)}'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'target_time': targetTime}),
        ));
    if (response == null || response.statusCode != 200) return false;
    invalidateHabits();
    return true;
  }

  /// Round 47 — delete a habit: `DELETE /api/habits/{id}` (native).
  /// True on HTTP 200. A rename would need delete+recreate, which
  /// destroys the habit's server-side log history, so renaming is
  /// deliberately not built; the ONE update the server supports is
  /// the scheduled time ([updateHabitTargetTime], VC 100137).
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

  /// MCP v1.1 — the signed-in user's AI connections from
  /// `GET /api/api-tokens` (metadata only — the server never sends
  /// a connection's secret, and this app never displays one).
  /// Returns null on any failure so the Connect an AI screen can
  /// tell "couldn't load" apart from "nothing connected"; an
  /// empty list is a real answer. Revoked rows are filtered out
  /// here AND by the screen's contract (the list is connections
  /// that can still read, by definition). The payload is parsed
  /// tolerantly: the v1 envelope keys the list `tokens`, and
  /// additive v1.1 fields (or envelope aliases) must not break
  /// this screen — unknown fields are ignored, malformed rows
  /// are skipped, never fatal.
  Future<List<AiConnectionDto>?> fetchAiConnections() async {
    final body = await _getJson('/api/api-tokens');
    if (body == null) return null;
    dynamic raw = body['tokens'] ??
        body['connections'] ??
        body['apiTokens'] ??
        body['data'];
    if (raw is Map<String, dynamic>) {
      raw = raw['tokens'] ?? raw['connections'] ?? raw['items'];
    }
    if (raw is! List) return null;
    final out = <AiConnectionDto>[];
    for (final row in raw) {
      if (row is Map<String, dynamic>) {
        try {
          final dto = AiConnectionDto.fromJson(row);
          if (dto != null) out.add(dto);
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }

  /// MCP v1.1 — disconnect one AI connection via
  /// `POST /api/api-tokens/:id/revoke`. Revocation is immediate
  /// server-side. True on HTTP 200; the caller keeps the row and
  /// surfaces an error on false (never a silent no-op).
  Future<bool> revokeAiConnection(String id) =>
      _postJson('/api/api-tokens/${Uri.encodeComponent(id)}/revoke',
          const {});

  // ── Friend data sharing (MCP friend-sharing package, Nov 23,
  // 2026; jot-server PR #57, `src/routes/dataShares.js`) ──
  // Session-auth endpoints under `/api/data-shares`. Every list
  // method returns null on any failure so the Connect an AI
  // screen can tell "couldn't load" apart from "nothing there"
  // (the fetchAiConnections discipline); an empty list is a real
  // answer. Malformed rows are skipped, never fatal.

  /// Shares I created, from `GET /api/data-shares/outgoing` →
  /// `{shares: [...]}` (each row nests the recipient under
  /// `recipient`). Null on any failure.
  Future<List<DataShareDto>?> fetchOutgoingShares() =>
      _fetchShares('/api/data-shares/outgoing', outgoing: true);

  /// Shares offered to me, from `GET /api/data-shares/incoming`
  /// → `{shares: [...]}` (each row nests the sharer under
  /// `sharer`). Null on any failure.
  Future<List<DataShareDto>?> fetchIncomingShares() =>
      _fetchShares('/api/data-shares/incoming', outgoing: false);

  Future<List<DataShareDto>?> _fetchShares(String path,
      {required bool outgoing}) async {
    final body = await _getJson(path);
    if (body == null) return null;
    final raw = body['shares'];
    if (raw is! List) return null;
    final out = <DataShareDto>[];
    for (final row in raw) {
      if (row is Map<String, dynamic>) {
        try {
          final dto = DataShareDto.fromJson(row, outgoing: outgoing);
          if (dto != null) out.add(dto);
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    return out;
  }

  /// Create (or re-request) a share via `POST /api/data-shares`
  /// with `{recipientId, categories}` — the field name is the
  /// server's camelCase contract (dataShares.js destructures
  /// `recipientId`). The server answers 201 for a new share and
  /// 200 for a re-request, so success is either status with a
  /// parseable `share` row; anything else is null (the caller
  /// surfaces an honest error and keeps its state).
  Future<DataShareDto?> createDataShare(
      String recipientId, List<String> categories) async {
    final res = await _postAuthedWithStatus('/api/data-shares', {
      'recipientId': recipientId,
      'categories': categories,
    });
    if (res.statusCode != 200 && res.statusCode != 201) return null;
    final share = res.body?['share'];
    if (share is! Map<String, dynamic>) return null;
    try {
      return DataShareDto.fromJson(share, outgoing: true);
    } catch (_) {
      return null;
    }
  }

  /// Recipient accepts a pending share via
  /// `POST /api/data-shares/:id/accept`. True on HTTP 200.
  Future<bool> acceptDataShare(String id) =>
      _postJson('/api/data-shares/${Uri.encodeComponent(id)}/accept',
          const {});

  /// Recipient declines a pending share via
  /// `POST /api/data-shares/:id/decline`. True on HTTP 200.
  Future<bool> declineDataShare(String id) =>
      _postJson('/api/data-shares/${Uri.encodeComponent(id)}/decline',
          const {});

  /// Sharer revokes a pending or accepted share via
  /// `POST /api/data-shares/:id/revoke`. True on HTTP 200.
  /// NOTE: the server also exposes a recipient-side remove
  /// endpoint, but it has NO signed UI copy (Juno flag 8) — it is
  /// deliberately NOT wrapped here and must not be surfaced.
  Future<bool> revokeDataShare(String id) =>
      _postJson('/api/data-shares/${Uri.encodeComponent(id)}/revoke',
          const {});

  /// Sharer edits an accepted share's categories via
  /// `PUT /api/data-shares/:id/categories` `{categories}` —
  /// immediate effect server-side, no fresh accept. True on
  /// HTTP 200.
  Future<bool> updateDataShareCategories(
      String id, List<String> categories) async {
    final response = await _sendAuthed((token) => _client.put(
          Uri.parse('$_baseUrl/api/data-shares/${Uri.encodeComponent(id)}/categories'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'categories': categories}),
        ));
    return response?.statusCode == 200;
  }

  /// Last-read rows from `GET /api/data-shares/last-read` →
  /// `{lastReads: [...]}`: the latest successful shared read per
  /// (recipient, category) for shares where I am the sharer.
  /// Null on any failure.
  Future<List<ShareLastReadDto>?> fetchShareLastReads() async {
    final body = await _getJson('/api/data-shares/last-read');
    if (body == null) return null;
    final raw = body['lastReads'];
    if (raw is! List) return null;
    final out = <ShareLastReadDto>[];
    for (final row in raw) {
      if (row is Map<String, dynamic>) {
        try {
          final dto = ShareLastReadDto.fromJson(row);
          if (dto != null) out.add(dto);
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

  // ── Friend Streaks (Design §4, Nov 23, 2026) ─────────────────────
  //
  // Session-auth endpoints mounted under `/api/friends/streaks`:
  // - `GET /api/friends/streaks` → `{incoming, outgoingPending, pairs}`
  // - `POST /api/friends/streaks/invite` `{friendId, clientTabsDate}`
  // - `POST /api/friends/streaks/respond` `{pairId, accept, clientTabsDate}`
  // - `POST /api/friends/streaks/remove` `{pairId}`

  /// Friend Streaks payload from `GET /api/friends/streaks`.
  /// Returns [FriendStreaksDto.empty] on any failure — see
  /// [fetchFriendStreaksOrNull] for the failure-distinguishing variant
  /// used by the FRIENDS tab to render its load-failure state.
  Future<FriendStreaksDto> fetchFriendStreaks() async =>
      await fetchFriendStreaksOrNull() ?? FriendStreaksDto.empty;

  /// Nullable variant of [fetchFriendStreaks]: returns null when the
  /// fetch itself failed (no token, transport error, non-200, or a
  /// body without usable list fields), and the parsed payload only
  /// when the server actually answered.
  Future<FriendStreaksDto?> fetchFriendStreaksOrNull() async {
    final body = await _getJson('/api/friends/streaks');
    if (body == null) return null;
    if (body['incoming'] is! List &&
        body['outgoingPending'] is! List &&
        body['pairs'] is! List) {
      return null;
    }
    return FriendStreaksDto.fromJson(body);
  }

  /// Send a friend-streak invite via `POST /api/friends/streaks/invite`
  /// with `{friendId, clientTabsDate}`. Returns the decoded body on
  /// HTTP 200 (`{success: true, pairId, status}`), null on failure.
  Future<Map<String, dynamic>?> inviteFriendStreak(
    String friendId, {
    String? clientTabsDate,
  }) =>
      _postJsonMap('/api/friends/streaks/invite', {
        'friendId': friendId,
        'clientTabsDate': clientTabsDate ?? tabsDayStr(DateTime.now()),
      });

  /// Respond to an incoming friend-streak invite via
  /// `POST /api/friends/streaks/respond` with
  /// `{pairId, accept, clientTabsDate}`. Returns the decoded body on
  /// HTTP 200 (`{success: true, pairId, status}`), null on failure.
  Future<Map<String, dynamic>?> respondFriendStreak(
    String pairId,
    bool accept, {
    String? clientTabsDate,
  }) =>
      _postJsonMap('/api/friends/streaks/respond', {
        'pairId': pairId,
        'accept': accept,
        'clientTabsDate': clientTabsDate ?? tabsDayStr(DateTime.now()),
      });

  /// Remove (end an active pair, or cancel a pending invite) via
  /// `POST /api/friends/streaks/remove` with `{pairId}`. Returns the
  /// decoded body on HTTP 200 (`{success: true, pairId, status}`),
  /// null on failure.
  Future<Map<String, dynamic>?> removeFriendStreak(String pairId) =>
      _postJsonMap('/api/friends/streaks/remove', {'pairId': pairId});

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
    final result = await syncDocumentsDetailed(documents);
    return result != null;
  }

  /// Docfix (Oct 2026) — [syncDocuments] plus the server's additive
  /// import-dedupe report. The fixed sync/documents handler strips
  /// whitespace-wrapped base64 at the boundary and dedupes by
  /// content: when a sent row's bytes are byte-identical to a
  /// document already stored under a different id, the row is NOT
  /// stored again; it still counts toward `synced`, and the
  /// response carries `deduplicated: {sentId: canonicalId}` so the
  /// client adopts the existing row. Returns null when the batch is
  /// not fully accounted for (the [syncDocuments] failure rule);
  /// otherwise the deduplicated map (empty when nothing deduped,
  /// and also empty against a pre-fix server that never sends it).
  Future<Map<String, String>?> syncDocumentsDetailed(
      List<Map<String, dynamic>> documents) async {
    final res =
        await _postJsonMap('/api/sync/documents', {'documents': documents});
    if (!_syncedAll(res, documents.length)) return null;
    final deduped = <String, String>{};
    final raw = res?['deduplicated'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final from = '${e.key}';
        final to = '${e.value}';
        if (from.isNotEmpty && to.isNotEmpty) deduped[from] = to;
      }
    }
    return deduped;
  }

  /// Docfix (Oct 2026) — strips ALL whitespace (spaces, tabs, CR,
  /// LF) from a base64 payload. Native-era uploads stored
  /// CRLF-wrapped base64 (android.util.Base64.DEFAULT wraps at 76
  /// columns) and Gemini rejects wrapped data outright; the server
  /// now strips at every boundary too, and the client mirrors it
  /// (defense in depth) so a legacy wrapped row still extracts.
  static String stripBase64Whitespace(String data) =>
      data.replaceAll(RegExp(r'\s+'), '');

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
    if (result is String && result.isNotEmpty) {
      return stripBase64Whitespace(result);
    }
    final fileData = res['fileData'];
    if (fileData is String && fileData.isNotEmpty) {
      return stripBase64Whitespace(fileData);
    }
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
      // Docfix: never send whitespace-wrapped base64 (see
      // [stripBase64Whitespace]) — Gemini rejects it with a 500.
      'base64Data': stripBase64Whitespace(base64Data),
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
    //
    // R-1 F2: the body is encoded BEFORE dispatch, outside the
    // transport try/catch. Previously jsonEncode ran inside the
    // send closure, so an encode throw was caught as a transport
    // no-response and recorded as "no connection" — a local
    // failure wearing a network label. An encode throw now
    // returns the preDispatch classification and no request is
    // attempted.
    final String encodedBody;
    try {
      encodedBody = jsonEncode(body);
    } catch (_) {
      return (
        statusCode: null,
        body: null,
        serverError: null,
        transportFailure: AiTransportFailure.preDispatch,
      );
    }
    final sent = await _sendAuthedDetailed(
      (token) => _client.post(
        Uri.parse('$_baseUrl$path'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: encodedBody,
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

  /// VC 100131 (Round 3) — report-result pickup:
  /// `GET /api/ai/report/result/:generationId`, through the SAME
  /// authed detailed machinery as the report POST (in-flight
  /// refresh awaited, one refresh + resend on 401), so its
  /// session semantics match the POST exactly. Owner-scoped
  /// server-side by the JWT: another account's identity answers
  /// identically to a nonexistent one.
  ///
  /// This method NEVER throws and NEVER returns a generation
  /// failure for a pickup-side problem: any transport failure
  /// talking to the pickup endpoint maps to [PickupUnreachable],
  /// which callers treat as "pickup is best-effort recovery,
  /// fall through to a POST" — never as a user-visible failure.
  Future<ReportPickupOutcome> fetchReportPickup(String generationId) async {
    final sent = await _sendAuthedDetailed(
      (token) => _client.get(
        Uri.parse('$_baseUrl/api/ai/report/result/$generationId'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ),
      timeout: aiRequestTimeout,
    );
    final response = sent.response;
    if (response == null) return const PickupUnreachable();
    Map<String, dynamic>? decoded;
    try {
      final d = jsonDecode(response.body);
      if (d is Map<String, dynamic>) decoded = d;
    } catch (_) {
      decoded = null;
    }
    final bodyStatus = decoded?['status'];
    // Mapping: HTTP status first, body `status` field second.
    switch (response.statusCode) {
      case 200:
        final result = decoded?['result'];
        if (result is String && result.trim().isNotEmpty) {
          return PickupReady(result,
              completedAt: _parsePickupCompletedAt(decoded?['completedAt']));
        }
        // A 200 without a usable narrative is an unusable pickup
        // response, not a generation outcome: fall through to a
        // POST rather than inventing a failure.
        return const PickupUnreachable();
      case 202:
        final hint = decoded?['retryAfterMs'];
        return PickupRunning(
            retryAfterMs: hint is num ? hint.toInt() : null);
      case 410:
        return const PickupExpired();
      case 404:
        return const PickupNotFound();
    }
    // Body `status` second, for any other HTTP status.
    if (bodyStatus == 'expired') return const PickupExpired();
    if (bodyStatus == 'not_found') return const PickupNotFound();
    if (bodyStatus == 'running') {
      final hint = decoded?['retryAfterMs'];
      return PickupRunning(retryAfterMs: hint is num ? hint.toInt() : null);
    }
    // Anything else with an HTTP status IS the stored mapped
    // failure (the stored status + { error }), including the
    // stored cancelled answer (unreachable behind the client's
    // cancel tombstone, mapped here only for completeness).
    final e = decoded?['error'] ?? decoded?['message'];
    return PickupFailed(response.statusCode,
        error: e == null ? null : '$e');
  }

  static DateTime? _parsePickupCompletedAt(Object? raw) {
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    }
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  /// VC 100131 (Round 3) — cancel invalidation:
  /// `DELETE /api/ai/report/result/:generationId` (Juno R8-2:
  /// owner-scoped; a running row is marked cancelled and its
  /// completion write is discarded server-side; a ready/failed
  /// row is deleted). Fire-and-forget BY CONTRACT: every outcome
  /// — transport failure, no session, any status — is swallowed.
  /// The client's journal tombstone (written on the Cancel tap
  /// itself) is what guarantees the cancelled identity is never
  /// picked up or re-POSTed, independently of whether this
  /// DELETE landed.
  Future<void> invalidateReportGeneration(String generationId) async {
    try {
      await _sendAuthedDetailed(
        (token) => _client.delete(
          Uri.parse('$_baseUrl/api/ai/report/result/$generationId'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        ),
      );
    } catch (_) {
      // Best-effort by contract (see above).
    }
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

  /// The full authoritative streak record from `/api/sync/pull`
  /// (VC 100115): the counters plus the day-level `streakState`
  /// blob. [succeeded] is false ONLY when the pull itself failed —
  /// the streak store's anti-fabrication rule turns on that
  /// distinction (a successful pull with no streak fields is a
  /// confirmed-empty record, not a failure).
  Future<
      ({
        bool succeeded,
        int? current,
        int? best,
        String? stateJson,
        int? purchasedFreezes,
        int? gemBalance
      })> fetchStreakRecord() async {
    final body = await fetchSyncPull();
    if (body == null) {
      return (
        succeeded: false,
        current: null,
        best: null,
        stateJson: null,
        purchasedFreezes: null,
        gemBalance: null
      );
    }
    final profile = body['profile'];
    if (profile is! Map<String, dynamic>) {
      return (
        succeeded: true,
        current: null,
        best: null,
        stateJson: null,
        purchasedFreezes: null,
        gemBalance: null
      );
    }
    final rawState = profile['streakState'];
    return (
      succeeded: true,
      current: _asInt(profile['currentStreak']),
      best: _asInt(profile['bestStreak']),
      stateJson: rawState is String ? rawState : null,
      // The server purchased-freeze column (streak upgrade A2).
      // The server contract names the pull field
      // `purchased_freezes`; the camelCase twin is accepted so
      // either serialization of the profile row parses.
      purchasedFreezes: _asInt(
          profile['purchased_freezes'] ?? profile['purchasedFreezes']),
      // Gems (Nov 19, 2026; jot-server PR #41): the pull profile
      // carries `gem_balance` — the ONE balance source for the
      // Home pill and the buy surface. The camelCase twin is
      // accepted like purchasedFreezes above.
      gemBalance:
          _asInt(profile['gem_balance'] ?? profile['gemBalance']),
    );
  }

  /// Status-carrying authenticated POST (the verify-endpoint
  /// shape): returns the HTTP status and decoded body (null body
  /// on transport failure or an unparseable response).
  Future<({int? statusCode, Map<String, dynamic>? body})> _postAuthedWithStatus(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
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

  /// Gems grant (jot-server PR #41): `POST /api/gems/grant {key}`
  /// → 200 `{gemBalance, amount, alreadyGranted}`. The amount is
  /// derived SERVER-side from the key kind (daily +5, milestone
  /// 7/30/100+ +25/+50/+100, perfect week +20); a replay answers
  /// `alreadyGranted: true` with the current balance and never
  /// double-grants.
  Future<({int? statusCode, Map<String, dynamic>? body})> grantGems(
    String key,
  ) =>
      _postAuthedWithStatus('/api/gems/grant', {'key': key});

  /// Gems spend (jot-server PR #41): `POST /api/gems/spend/freeze
  /// {spendId}` → 200 `{gemBalance, purchasedFreezes,
  /// alreadyGranted}`; 409 `{error: freeze_cap_reached |
  /// insufficient_gems, gemBalance, purchasedFreezes}`. (Before
  /// the Nov 21, 2026 gem-buy rule change the server could also
  /// answer `purchased_already_held`; it no longer returns that
  /// code for gem spends, and [GemService.spendOnFreeze] maps a
  /// legacy answer to a silent re-sync.) The spendId is
  /// client-generated, unique per user intent; a replayed
  /// spendId is a replay, never a double charge.
  Future<({int? statusCode, Map<String, dynamic>? body})> spendGemsOnFreeze(
    String spendId,
  ) =>
      _postAuthedWithStatus('/api/gems/spend/freeze', {'spendId': spendId});

  /// Push one settled streak record to the profile (VC 100115):
  /// counters + day-level blob in a single partial profile push —
  /// the server's COALESCE upsert means no other field is touched.
  ///
  /// [purchasedFreezes] is sent ONLY when the settle being pushed
  /// consumed a purchased freeze (streak upgrade A2): the body
  /// then carries `purchased_freezes` with the decreased count,
  /// which the server applies only when the pushed blob justifies
  /// the decrease. It is never sent otherwise — an increase on
  /// this route is ignored by the server by design.
  Future<bool> pushStreakRecord(int current, int best, String stateJson,
      {int? purchasedFreezes}) {
    return postSyncProfile({
      'currentStreak': current,
      'bestStreak': best,
      'streakState': stateJson,
      'purchased_freezes': ?purchasedFreezes,
    });
  }

  /// Verify one streak-freeze purchase with the server (streak
  /// upgrade D9/A9; contract in BRIEF-SERVER.md):
  /// `POST /api/streak/purchase/verify` `{productId, purchaseToken,
  /// orderId}` → 200 `{purchasedFreezes}` (plus `alreadyGranted:
  /// true` on a replayed token — idempotent, never a double grant),
  /// 409 `{error: 'purchased_already_held'}` when a purchased freeze
  /// is already held, other 4xx with a stable error code on any
  /// verification failure (no grant). Returns the HTTP status and
  /// decoded body (null body on transport failure). The purchase
  /// token travels only in the request body over HTTPS — never
  /// logged.
  Future<({int? statusCode, Map<String, dynamic>? body})>
      verifyStreakFreezePurchase({
    required String productId,
    required String purchaseToken,
    required String orderId,
  }) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/streak/purchase/verify'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'productId': productId,
            'purchaseToken': purchaseToken,
            'orderId': orderId,
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
    _syncPullInFlight.clear();
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
    final parsed = await _manualBpSource();
    return parsed.records;
  }

  /// VC 100132 (Problem 3) — Juno Round 4 Ruling 2's approved
  /// clean-empty signal for manual BP: true ONLY when the sync
  /// pull succeeded AND its profile carried a
  /// `manualBloodPressureLogs` field that parsed successfully
  /// (a JSON string decoding to a list, or a list directly).
  /// [fetchManualBpLogs] folds every other outcome — failed pull,
  /// missing profile, absent/blank field, malformed JSON — into
  /// the same empty list, so without this signal a clean empty
  /// is indistinguishable from an unreadable source and the
  /// report collector must keep calling empty a retrieval
  /// failure (Ruling 2, R2-2). Never throws.
  Future<bool> manualBpSourceParsed() async =>
      (await _manualBpSource()).sourceParsed;

  /// The one manual-BP pull parse: the records plus whether the
  /// source field was present in a successful pull and parsed.
  /// (The pull itself is the shared TTL-cached fetch, so calling
  /// both public methods costs no extra network fetch.)
  Future<({List<BpRecord> records, bool sourceParsed})>
      _manualBpSource() async {
    // Shared TTL pull cache; see fetchStreak.
    final body = await fetchSyncPull();
    final profile = body?['profile'];
    if (profile is! Map<String, dynamic>) {
      return (records: const <BpRecord>[], sourceParsed: false);
    }
    final raw = profile['manualBloodPressureLogs'];
    List<dynamic>? list;
    if (raw is String) {
      if (raw.trim().isEmpty) {
        return (records: const <BpRecord>[], sourceParsed: false);
      }
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) list = decoded;
      } catch (_) {
        return (records: const <BpRecord>[], sourceParsed: false);
      }
    } else if (raw is List) {
      list = raw;
    }
    if (list == null) {
      return (records: const <BpRecord>[], sourceParsed: false);
    }
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
    return (records: out, sourceParsed: true);
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
  Future<({bool isUnlimited, bool isAdmin})> fetchMembership() async =>
      await fetchMembershipOrNull() ??
      (isUnlimited: false, isAdmin: false);

  /// Nullable variant of [fetchMembership] (the
  /// [fetchHabitsOrNull] house idiom): returns null when the
  /// fetch itself failed (no usable sync pull), and the parsed
  /// membership only when the server actually answered. Callers
  /// that must tell "membership unknown" apart from "known
  /// non-member" — the Patterns tri-state gate (H1-05P) — use
  /// this so a failed fetch never masquerades as a non-member.
  Future<({bool isUnlimited, bool isAdmin})?> fetchMembershipOrNull() async {
    final body = await fetchSyncPull();
    if (body == null) return null;
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
  Future<List<QuickLogCategory>> fetchLogCategories() async =>
      await fetchLogCategoriesOrNull() ?? const [];

  /// H1-01 — failure-distinguishing variant of [fetchLogCategories],
  /// mirroring [fetchHabitsOrNull] and the `fetchLogEntryDtosOrNull`
  /// extension: returns null when the sync pull itself failed (null
  /// body) or carries no usable `categories` list, and the parsed
  /// list — possibly genuinely empty — only when the server actually
  /// answered. Callers that persist state derived from the pull (the
  /// correlation refresher) use this to tell "the server has no
  /// categories" apart from "the pull failed", so a failed pull can
  /// never be recomputed over as an empty account.
  Future<List<QuickLogCategory>?> fetchLogCategoriesOrNull() async {
    final body = await fetchSyncPull();
    if (body == null) return null;
    final categories = body['categories'];
    if (categories is! List) return null;
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
  ///
  /// Daily Summary race (Nov 20, 2026): a successful post bumps
  /// the entries-mutation epoch (see [_entriesMutationEpoch]) —
  /// every sync pull that started before this post is discarded
  /// on landing / never cached as fresh, on every instance, so
  /// no reader can allocate an entry id or derive plan state
  /// from a snapshot that predates this write.
  Future<bool> postLogEntries(List<QuickLogEntry> entries) async {
    final ok = await _postJson(
      '/api/sync/entries',
      {'entries': entries.map((e) => e.toSyncJson()).toList()},
    );
    if (ok) _entriesMutationEpoch++;
    return ok;
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
  ///
  /// A successful delete mutates the pull's entries view exactly
  /// as a post does, so it bumps the same entries-mutation epoch:
  /// a pull that started before the delete must never resurrect
  /// the deleted row as fresh state.
  Future<bool> deleteLogEntry(int id) async {
    final ok = await _delete('/api/sync/entries/$id');
    if (ok) _entriesMutationEpoch++;
    return ok;
  }

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
  /// harmless). Callers emit after a successful profile push
  /// through the durable H1-07 outbox, which keeps the events
  /// queued whenever this returns false (see
  /// `medication_change_events.dart` /
  /// `medication_change_event_outbox.dart`).
  ///
  /// D-T04 — delivery is NOT keyed on the HTTP status alone: a
  /// 200 whose body explicitly reports `success: false` is a
  /// server refusal, not a delivery, and returns false so the
  /// outbox keeps the events queued (the old `_postJson` path
  /// dropped them as delivered). The check lives HERE, at the
  /// backend seam, because the outbox only ever sees this
  /// method's bool (its poster typedef carries no body) — and it
  /// matches how the sibling contracts already read the
  /// `success` field ([postDailyScores] requires it true;
  /// [fetchMedicationChangeEvents] rejects `success != true`).
  /// A 200 body with NO `success` field keeps the long-standing
  /// true-on-200 semantics (pinned by the contract test in
  /// medication_change_capture_test.dart); non-200 / transport
  /// failure is false as before.
  Future<bool> postMedicationChangeEvents(
      List<MedicationChangeEvent> events) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/sync/medication-events'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'events': events.map((e) => e.toJson()).toList(),
          }),
        ));
    if (response == null || response.statusCode != 200) return false;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> &&
          decoded.containsKey('success')) {
        return decoded['success'] == true;
      }
    } catch (_) {
      // No readable body: fall through to true-on-200.
    }
    return true;
  }

  /// Phase 1, items 2b + 3 — THE read path for the append-only
  /// medication change events: `GET /api/sync/medication-events`
  /// → `{success: true, events: [...]}` OLDEST FIRST, each event
  /// in the client contract shape (see [MedicationChangeEvent]),
  /// ONLY the caller's events. Unified at the VC 100109 combine
  /// (both branches had grown a copy): NULL on any failure
  /// (transport, non-200, `success != true`, or a body without a
  /// usable `events` list) so a caller can tell a failed fetch
  /// from a genuinely empty history — item 3's Z5 degrades to its
  /// declared form on null instead of mistaking a failure for
  /// "no changes captured" (spec §4.5: failures land in
  /// degradation, never in falsified content), and item 2b's
  /// timeline screen now maps null to its load-failure state
  /// (the H1-06 fix, reversing the VC 100109 combine's
  /// `?? const []` mapping — a failed fetch must not render as
  /// a genuinely empty history). Malformed event rows are
  /// skipped; never throws.
  Future<List<MedicationChangeEvent>?> fetchMedicationChangeEvents() async {
    final body = await _getJson('/api/sync/medication-events');
    if (body == null || body['success'] != true) return null;
    final raw = body['events'];
    if (raw is! List) return null;
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

  /// Daily Score sync (Oct 28, 2026) — push a batch of Daily
  /// Score records via `POST /api/sync/daily-scores` with
  /// `{"scores": [...]}` → `{success, inserted, replaced,
  /// ignored}`. Server write rules: `auto` inserts only when no
  /// row exists; `manual_refresh` replaces an `auto` row or an
  /// older `manual_refresh` row (see `daily_score_sync.dart`).
  ///
  /// True only when the server's body proves the batch landed:
  /// `success` must be true, and when the body carries the full
  /// count triple, inserted + replaced + ignored must account
  /// for EVERY record sent (the Round 57 verified-count pattern —
  /// a 200 that silently skipped rows must not clear the local
  /// pending queue). Callers (the sync queue's flush) treat false
  /// as "keep queued and retry on the next trigger".
  Future<bool> postDailyScores(List<DailyScoreSyncRecord> scores) async {
    final res = await _postJsonMap('/api/sync/daily-scores', {
      'scores': scores.map((s) => s.toJson()).toList(),
    });
    if (res == null || res['success'] != true) return false;
    final inserted = _asInt(res['inserted']);
    final replaced = _asInt(res['replaced']);
    final ignored = _asInt(res['ignored']);
    if (inserted != null && replaced != null && ignored != null) {
      return inserted + replaced + ignored == scores.length;
    }
    return true;
  }

  /// Daily biometrics sync (MCP spike-data package, Nov 23, 2026)
  /// — push a batch of daily biometrics rows via
  /// `POST /api/sync/daily-biometrics` with `{"days": [...]}` →
  /// `{synced: n}`. The server merge-upserts (COALESCE per field:
  /// a sent non-null fills/overwrites, a null/absent field never
  /// erases), so re-sending the store's series is idempotent and
  /// never shrinks server data. Row shape is
  /// [DailyBiometrics.toJson] (the store blob and the sync payload
  /// share one shape), spike-summary fields included.
  ///
  /// True only when the server's body proves the batch landed:
  /// when the body carries `synced`, it must account for EVERY
  /// row sent (the verified-count pattern from [postDailyScores]
  /// — a 200 that silently skipped rows must not read as synced).
  Future<bool> postDailyBiometrics(List<DailyBiometrics> days) async {
    if (days.isEmpty) return true;
    final res = await _postJsonMap('/api/sync/daily-biometrics', {
      'days': days.map((d) => d.toJson()).toList(),
    });
    if (res == null) return false;
    final synced = _asInt(res['synced']);
    if (synced != null) return synced == days.length;
    return true;
  }

  /// Daily biometrics sync (MCP spike-data package, Nov 23, 2026)
  /// — the caller's server rows via `GET /api/sync/daily-biometrics`
  /// → `{days: [...]}`, date-ascending, same field names as the
  /// POST body. Malformed rows are skipped; an empty list on any
  /// failure (the caller's honest outcome: nothing to merge).
  Future<List<DailyBiometrics>> fetchDailyBiometrics() async {
    final body = await _getJson('/api/sync/daily-biometrics');
    final days = body?['days'];
    if (days is! List) return const [];
    final out = <DailyBiometrics>[];
    for (final raw in days) {
      final row = DailyBiometrics.fromJson(raw);
      if (row != null && row.hasAnyValue) out.add(row);
    }
    return out;
  }

  /// Daily Score sync (Oct 28, 2026) — the caller's server scores
  /// via `GET /api/sync/daily-scores` → `{success, scores: [...]}`,
  /// date-ascending. Malformed rows are skipped; an empty list on
  /// any failure (the caller's honest outcome: nothing to merge).
  Future<List<DailyScoreSyncRecord>> fetchDailyScores() async {
    final body = await _getJson('/api/sync/daily-scores');
    final scores = body?['scores'];
    if (scores is! List) return const [];
    final out = <DailyScoreSyncRecord>[];
    for (final raw in scores) {
      final record = DailyScoreSyncRecord.fromJson(raw);
      if (record != null) out.add(record);
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

  /// VC 100134 Package C — submit the emailed 6-digit code:
  /// `POST /api/auth/verify-email` with `{code: <string>}`. The
  /// code travels ONLY in the request body (Vera R32), as a JSON
  /// string, so leading zeros survive end to end (Vera R2/R38:
  /// "001234" is sent as the string "001234", never a number).
  /// Authenticated via [_sendAuthed]: a user can sit on the code
  /// screen past the access token's life, so the 401→refresh
  /// wrapper is load-bearing here. Per the server contract a
  /// wrong/expired/burned code is a 400 — never a 401 — so a 401
  /// seen here is the stale-token case the wrapper already handled.
  /// The server's error string is deliberately NOT surfaced:
  /// every definitive non-200 below 500 maps to the single
  /// [VerifyEmailRejected] outcome (no oracle).
  Future<VerifyEmailOutcome> verifyEmailCode(String code) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/auth/verify-email'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'code': code}),
        ));
    if (response == null) return const VerifyEmailUnreachable();
    if (response.statusCode == 200) return const VerifyEmailSuccess();
    if (response.statusCode >= 500) return const VerifyEmailUnreachable();
    return const VerifyEmailRejected();
  }

  /// VC 100134 Package C — request a fresh code:
  /// `POST /api/auth/resend-verification` (authenticated, no body
  /// fields — the server reads the destination from the account
  /// row, Vera R17). 200 → sent (an already-verified account is a
  /// silent 200 no-op server-side, same shape). 429 → cooldown,
  /// adopting the server's `retryAfterSeconds` when present
  /// (defaulting to the 60s cooldown).
  Future<ResendVerificationOutcome> resendVerificationCode() async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/auth/resend-verification'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(const <String, dynamic>{}),
        ));
    if (response == null) return const ResendVerificationUnreachable();
    if (response.statusCode == 200) return const ResendVerificationSent();
    if (response.statusCode == 429) {
      var seconds = 60;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final raw = decoded['retryAfterSeconds'];
          final parsed = raw is num
              ? raw.toInt()
              : raw is String
                  ? int.tryParse(raw)
                  : null;
          if (parsed != null && parsed > 0) seconds = parsed;
        }
      } catch (_) {
        // Unparseable 429 body — the 60s default governs.
      }
      return ResendVerificationCooldown(seconds);
    }
    if (response.statusCode >= 500) {
      return const ResendVerificationUnreachable();
    }
    return const ResendVerificationFailed();
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

  /// Sign in with Apple — link an Apple account to the signed-in
  /// account, mirroring [linkGoogle]: `POST api/auth/link-apple`
  /// with `{"idToken": ...}`, routed through [_sendAuthed] (401 →
  /// refresh → retry-once). Returns the decoded body on HTTP 200.
  /// The identity token is sent only in this request body — never
  /// logged.
  ///
  /// CONTRACT DIVERGENCE from Google (flagged for Vera): Google's
  /// link/disconnect endpoints report errors inside a 200 body, so
  /// [linkGoogle]/[disconnectGoogle] decode ONLY on 200 and return
  /// null otherwise. The Apple endpoints return link/disconnect
  /// errors as NON-200 (400/401/409) with `{success: false, error}`
  /// bodies — so this method (and [disconnectApple]) decodes the
  /// body on error statuses too and returns it whenever it decodes
  /// to a JSON object. Without that, the server's refusal text
  /// (e.g. the 409 "already connected to another Tabs account")
  /// could never reach the caller. Null remains the outcome for
  /// transport failure / no session / an undecodable body.
  Future<Map<String, dynamic>?> linkApple(String idToken) async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/auth/link-apple'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'idToken': idToken}),
        ));
    if (response == null) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Sign in with Apple — disconnect the linked Apple account,
  /// mirroring [disconnectGoogle]: `POST api/auth/disconnect-apple`.
  /// Same contract divergence as [linkApple]: the body is decoded
  /// on error statuses too, because the 409 refusal ("Set or reset
  /// a password before disconnecting your only sign-in method")
  /// arrives as a NON-200 `{success: false, error}` body and the
  /// disconnect dialog must show it while local state is preserved
  /// (the caller enforces that, exactly like Google).
  Future<Map<String, dynamic>?> disconnectApple() async {
    final response = await _sendAuthed((token) => _client.post(
          Uri.parse('$_baseUrl/api/auth/disconnect-apple'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(const <String, dynamic>{}),
        ));
    if (response == null) return null;
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

/// The 8 shareable category keys, in Juno's signed order
/// (build-mcp-sharing/JUNO-COPY.md §a2). Stable server strings
/// (jot-server `CATEGORY_KEYS`); the server re-sorts any payload
/// into this order, and the app renders category lists in this
/// order too (Juno's {categories} slot rule).
const List<String> dataShareCategoryKeys = [
  'medications',
  'sleep',
  'daily_scores',
  'heart_rate_spikes',
  'streak',
  'badges_and_gems',
  'log_entries',
  'summaries',
];

/// Friend data sharing — one grant row from
/// `GET /api/data-shares/outgoing|incoming` (or the `share`
/// object a create/transition answers with). The other party is
/// nested under `recipient` (outgoing) or `sharer` (incoming);
/// the create/transition answers carry flat ids instead, which
/// parse with empty names (the screen re-fetches lists after a
/// write, so display rows always come from the list endpoints).
class DataShareDto {
  final String id;

  /// The other party's user id (recipient for outgoing, sharer
  /// for incoming).
  final String otherId;
  final String otherNickname;
  final String otherTag;

  /// Category keys (subset of [dataShareCategoryKeys]).
  final List<String> categories;

  /// pending | accepted | declined | revoked.
  final String status;
  final DateTime? createdAt;

  /// When the recipient responded (accept/decline) — the
  /// "since" date of an accepted share.
  final DateTime? respondedAt;

  const DataShareDto({
    required this.id,
    required this.otherId,
    required this.otherNickname,
    required this.otherTag,
    required this.categories,
    required this.status,
    this.createdAt,
    this.respondedAt,
  });

  bool get isPending => status == 'pending';
  bool get isAccepted => status == 'accepted';

  DataShareDto copyWith(
      {List<String>? categories, String? status, DateTime? respondedAt}) {
    return DataShareDto(
      id: id,
      otherId: otherId,
      otherNickname: otherNickname,
      otherTag: otherTag,
      categories: categories ?? this.categories,
      status: status ?? this.status,
      createdAt: createdAt,
      respondedAt: respondedAt ?? this.respondedAt,
    );
  }

  /// Tolerant parse; null for a row with no id. [outgoing]
  /// selects which nested party object to read.
  static DataShareDto? fromJson(Map<String, dynamic> json,
      {required bool outgoing}) {
    final rawId = json['id'];
    if (rawId == null) return null;
    final partyKey = outgoing ? 'recipient' : 'sharer';
    final party = json[partyKey];
    String otherId = '';
    String nickname = '';
    String tag = '';
    if (party is Map<String, dynamic>) {
      otherId = '${party['id'] ?? ''}';
      nickname = '${party['nickname'] ?? ''}';
      tag = '${party['tag'] ?? ''}';
    } else {
      // Flat create/transition shape: {recipientId} / {sharerId}.
      final flat = json[outgoing ? 'recipientId' : 'sharerId'];
      if (flat != null) otherId = '$flat';
    }
    final rawCats = json['categories'];
    final cats = <String>[];
    if (rawCats is List) {
      for (final c in rawCats) {
        if (c is String && dataShareCategoryKeys.contains(c)) {
          cats.add(c);
        }
      }
    }
    // Render order is Juno's §a2 order regardless of payload order.
    cats.sort((a, b) => dataShareCategoryKeys
        .indexOf(a)
        .compareTo(dataShareCategoryKeys.indexOf(b)));
    return DataShareDto(
      id: rawId.toString(),
      otherId: otherId,
      otherNickname: nickname,
      otherTag: tag,
      categories: cats,
      status: '${json['status'] ?? ''}',
      createdAt: AiConnectionDto._parseTimestamp(json['created_at']),
      respondedAt: AiConnectionDto._parseTimestamp(json['responded_at']),
    );
  }
}

/// Friend data sharing — one last-read row from
/// `GET /api/data-shares/last-read`: the latest successful shared
/// read of my data by one friend's AI, for one category.
class ShareLastReadDto {
  final String recipientId;
  final String nickname;
  final String tag;

  /// Category key (one of [dataShareCategoryKeys]).
  final String category;
  final DateTime? readAt;

  const ShareLastReadDto({
    required this.recipientId,
    required this.nickname,
    required this.tag,
    required this.category,
    this.readAt,
  });

  static ShareLastReadDto? fromJson(Map<String, dynamic> json) {
    final rawId = json['recipient_id'];
    final rawCat = json['category'];
    if (rawId == null || rawCat is! String || rawCat.isEmpty) {
      return null;
    }
    return ShareLastReadDto(
      recipientId: rawId.toString(),
      nickname: '${json['nickname'] ?? ''}',
      tag: '${json['tag'] ?? ''}',
      category: rawCat,
      readAt: AiConnectionDto._parseTimestamp(json['read_at']),
    );
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

  /// Community revamp (Option A, Nov 19, 2026): GAME stats from
  /// `GET /api/friends/list` — the server change is additive
  /// (`gemBalance` / `currentStreak` aliases on the joined profile
  /// row), so both default to 0 when the deployed server does not
  /// send them yet. Streak and gems are visible to confirmed
  /// friends; they are NOT gated by the health-data sharing opt-in.
  final int gemBalance;
  final int currentStreak;

  /// Profile picture (Nov 23, 2026): the friend's picked avatar id
  /// (`avatar_01`..`avatar_15`) from the friends list row's
  /// `avatarId` key. Null when the row carries no usable id — the
  /// row then renders its initials fallback, exactly as before.
  final String? avatarId;

  const FriendDto({
    required this.id,
    required this.nickname,
    required this.tag,
    required this.status,
    required this.level,
    this.gemBalance = 0,
    this.currentStreak = 0,
    this.avatarId,
  });

  factory FriendDto.fromJson(Map<String, dynamic> json) {
    final rawAvatarId = json['avatarId'];
    return FriendDto(
      id: '${json['id'] ?? ''}',
      nickname: '${json['nickname'] ?? ''}',
      tag: '${json['tag'] ?? ''}',
      status: '${json['status'] ?? ''}',
      // Tolerant: server numbers may arrive as strings.
      level: TabsBackend._asInt(json['level']) ?? 0,
      gemBalance:
          TabsBackend._asInt(json['gemBalance'] ?? json['gem_balance']) ??
              0,
      currentStreak: TabsBackend._asInt(json['currentStreak']) ?? 0,
      // Tolerant, mirroring the rest of this parser: only a
      // non-empty string is a picture id; anything else is none.
      avatarId: (rawAvatarId is String && rawAvatarId.trim().isNotEmpty)
          ? rawAvatarId
          : null,
    );
  }

  FriendDto copyWith({
    int? gemBalance,
    int? currentStreak,
    int? level,
    String? avatarId,
  }) {
    return FriendDto(
      id: id,
      nickname: nickname,
      tag: tag,
      status: status,
      level: level ?? this.level,
      gemBalance: gemBalance ?? this.gemBalance,
      currentStreak: currentStreak ?? this.currentStreak,
      avatarId: avatarId ?? this.avatarId,
    );
  }
}

/// MCP v1.1 — one AI connection row from `GET /api/api-tokens`.
/// Metadata only: the payload carries no secret material, and
/// [tokenPrefix] is deliberately NOT modelled — this app never
/// displays any part of a connection's credential.
class AiConnectionDto {
  final String id;
  final String name;
  final DateTime? connectedAt;
  final DateTime? lastUsedAt;

  const AiConnectionDto({
    required this.id,
    required this.name,
    this.connectedAt,
    this.lastUsedAt,
  });

  /// Tolerant parse (additive v1.1 fields are ignored). Returns
  /// null for a revoked row — the Connect an AI screen lists only
  /// connections that can still read — and for a row with no id.
  /// Revocation arrives either as the v1 `revoked_at` timestamp
  /// or a boolean `revoked` flag; both are honoured.
  static AiConnectionDto? fromJson(Map<String, dynamic> json) {
    if (json['revoked'] == true || json['revoked_at'] != null) {
      return null;
    }
    final rawId = json['id'];
    if (rawId == null) return null;
    final rawName = json['name'];
    return AiConnectionDto(
      id: rawId.toString(),
      name: (rawName is String && rawName.trim().isNotEmpty)
          ? rawName
          : 'Unknown app',
      connectedAt: _parseTimestamp(json['created_at']),
      lastUsedAt: _parseTimestamp(json['last_used_at']),
    );
  }

  /// ISO-8601 string or epoch (seconds or milliseconds) →
  /// device-local time; anything else is null (the row still
  /// renders, just without that line).
  static DateTime? _parseTimestamp(dynamic v) {
    if (v is String) {
      final parsed = DateTime.tryParse(v);
      return parsed?.toLocal();
    }
    if (v is num) {
      final n = v.toInt();
      if (n > 100000000000) {
        return DateTime.fromMillisecondsSinceEpoch(n).toLocal();
      }
      if (n > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch(n * 1000).toLocal();
      }
    }
    return null;
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

  /// Profile picture id (`avatar_01`..`avatar_15`) of the sender when
  /// present on the notification row (`senderAvatarId`).
  final String? senderAvatarId;

  const FriendNotificationDto({
    required this.id,
    required this.type,
    required this.message,
    required this.isRead,
    required this.createdAt,
    this.senderNickname,
    this.senderTag,
    this.friendRequestId,
    this.senderAvatarId,
  });

  factory FriendNotificationDto.fromJson(Map<String, dynamic> json) {
    final rawAvatarId = json['senderAvatarId'] ?? json['avatarId'];
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
      senderAvatarId:
          (rawAvatarId is String && rawAvatarId.trim().isNotEmpty)
              ? rawAvatarId
              : null,
    );
  }

  FriendNotificationDto copyWith({bool? isRead, String? senderAvatarId}) {
    return FriendNotificationDto(
      id: id,
      type: type,
      message: message,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt,
      senderNickname: senderNickname,
      senderTag: senderTag,
      friendRequestId: friendRequestId,
      senderAvatarId: senderAvatarId ?? this.senderAvatarId,
    );
  }
}

/// Friend Streaks (Design §4, Nov 23, 2026) — partner metadata nested
/// inside [FriendStreakIncomingDto] and [FriendStreakPairDto].
class FriendStreakPartnerDto {
  final String userId;
  final String nickname;
  final String tag;
  final String? avatarId;

  const FriendStreakPartnerDto({
    required this.userId,
    required this.nickname,
    required this.tag,
    this.avatarId,
  });

  factory FriendStreakPartnerDto.fromJson(Map<String, dynamic> json) {
    final rawAvatarId = json['avatarId'] ?? json['avatar_id'];
    return FriendStreakPartnerDto(
      userId: '${json['userId'] ?? json['id'] ?? ''}',
      nickname: '${json['nickname'] ?? ''}',
      tag: '${json['tag'] ?? ''}',
      avatarId: (rawAvatarId is String && rawAvatarId.trim().isNotEmpty)
          ? rawAvatarId
          : null,
    );
  }

  FriendStreakPartnerDto copyWith({
    String? userId,
    String? nickname,
    String? tag,
    String? avatarId,
  }) {
    return FriendStreakPartnerDto(
      userId: userId ?? this.userId,
      nickname: nickname ?? this.nickname,
      tag: tag ?? this.tag,
      avatarId: avatarId ?? this.avatarId,
    );
  }
}

/// Friend Streaks (Design §4) — one incoming invite row from
/// `GET /api/friends/streaks` (`incoming[]`).
class FriendStreakIncomingDto {
  final String pairId;
  final FriendStreakPartnerDto partner;
  final String? createdAt;

  const FriendStreakIncomingDto({
    required this.pairId,
    required this.partner,
    this.createdAt,
  });

  String get userId => partner.userId;
  String get nickname => partner.nickname;
  String get tag => partner.tag;
  String? get avatarId => partner.avatarId;

  factory FriendStreakIncomingDto.fromJson(Map<String, dynamic> json) {
    final rawPartner = json['partner'];
    final partner = rawPartner is Map<String, dynamic>
        ? FriendStreakPartnerDto.fromJson(rawPartner)
        : FriendStreakPartnerDto.fromJson(json);
    final rawCreated = json['createdAt'] ?? json['created_at'];
    return FriendStreakIncomingDto(
      pairId: '${json['pairId'] ?? json['id'] ?? ''}',
      partner: partner,
      createdAt: rawCreated?.toString(),
    );
  }

  FriendStreakIncomingDto copyWith({
    String? pairId,
    FriendStreakPartnerDto? partner,
    String? createdAt,
  }) {
    return FriendStreakIncomingDto(
      pairId: pairId ?? this.pairId,
      partner: partner ?? this.partner,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// Friend Streaks (Design §4) — one active pair view from
/// `GET /api/friends/streaks` (`pairs[]`).
class FriendStreakPairDto {
  final String pairId;
  final FriendStreakPartnerDto partner;
  final String status;
  final int count;
  final int best;
  final bool viewerFinishedToday;
  final bool partnerFinishedToday;
  final String statusKind;

  const FriendStreakPairDto({
    required this.pairId,
    required this.partner,
    this.status = 'active',
    this.count = 0,
    this.best = 0,
    this.viewerFinishedToday = false,
    this.partnerFinishedToday = false,
    this.statusKind = '',
  });

  String get userId => partner.userId;
  String get nickname => partner.nickname;
  String get tag => partner.tag;
  String? get avatarId => partner.avatarId;

  factory FriendStreakPairDto.fromJson(Map<String, dynamic> json) {
    final rawPartner = json['partner'];
    final partner = rawPartner is Map<String, dynamic>
        ? FriendStreakPartnerDto.fromJson(rawPartner)
        : FriendStreakPartnerDto.fromJson(json);
    return FriendStreakPairDto(
      pairId: '${json['pairId'] ?? json['id'] ?? ''}',
      partner: partner,
      status: '${json['status'] ?? 'active'}',
      count: TabsBackend._asInt(json['count']) ?? 0,
      best: TabsBackend._asInt(json['best']) ?? 0,
      viewerFinishedToday: json['viewerFinishedToday'] == true,
      partnerFinishedToday: json['partnerFinishedToday'] == true,
      statusKind: '${json['statusKind'] ?? ''}',
    );
  }

  FriendStreakPairDto copyWith({
    String? pairId,
    FriendStreakPartnerDto? partner,
    String? status,
    int? count,
    int? best,
    bool? viewerFinishedToday,
    bool? partnerFinishedToday,
    String? statusKind,
  }) {
    return FriendStreakPairDto(
      pairId: pairId ?? this.pairId,
      partner: partner ?? this.partner,
      status: status ?? this.status,
      count: count ?? this.count,
      best: best ?? this.best,
      viewerFinishedToday: viewerFinishedToday ?? this.viewerFinishedToday,
      partnerFinishedToday: partnerFinishedToday ?? this.partnerFinishedToday,
      statusKind: statusKind ?? this.statusKind,
    );
  }
}

/// Friend Streaks (Design §4) — full response envelope from
/// `GET /api/friends/streaks`:
/// `{ incoming: [...], outgoingPending: [friendId...], pairs: [pairView...] }`.
class FriendStreaksDto {
  final List<FriendStreakIncomingDto> incoming;
  final List<String> outgoingPending;

  /// Optional map of `friendId -> pairId` for outgoing pending invites
  /// when the server or a local invite response provides a pairId,
  /// enabling EDIT-mode cancellation via `POST /api/friends/streaks/remove`.
  final Map<String, String> outgoingPendingPairIds;
  final List<FriendStreakPairDto> pairs;

  const FriendStreaksDto({
    this.incoming = const [],
    this.outgoingPending = const [],
    this.outgoingPendingPairIds = const {},
    this.pairs = const [],
  });

  static const FriendStreaksDto empty = FriendStreaksDto();

  factory FriendStreaksDto.fromJson(Map<String, dynamic> json) {
    final incoming = <FriendStreakIncomingDto>[];
    final rawIncoming = json['incoming'];
    if (rawIncoming is List) {
      for (final item in rawIncoming) {
        if (item is Map<String, dynamic>) {
          try {
            incoming.add(FriendStreakIncomingDto.fromJson(item));
          } catch (_) {
            // Skip malformed rows — never fail the whole payload.
          }
        }
      }
    }

    final outgoingPending = <String>[];
    final outgoingPairIds = <String, String>{};
    final rawOutgoing = json['outgoingPending'];
    if (rawOutgoing is List) {
      for (final item in rawOutgoing) {
        if (item is String && item.trim().isNotEmpty) {
          outgoingPending.add(item);
        } else if (item is Map<String, dynamic>) {
          final partner = item['partner'];
          final friendId = '${item['friendId'] ?? item['userId'] ?? (partner is Map ? partner['userId'] : '') ?? ''}';
          final pairId = '${item['pairId'] ?? item['id'] ?? ''}';
          if (friendId.isNotEmpty) {
            outgoingPending.add(friendId);
            if (pairId.isNotEmpty) outgoingPairIds[friendId] = pairId;
          }
        }
      }
    }

    final pairs = <FriendStreakPairDto>[];
    final rawPairs = json['pairs'];
    if (rawPairs is List) {
      for (final item in rawPairs) {
        if (item is Map<String, dynamic>) {
          try {
            final dto = FriendStreakPairDto.fromJson(item);
            // Design §7: ended pairs are never listed in active pairs.
            if (dto.status != 'ended') {
              pairs.add(dto);
            }
          } catch (_) {
            // Skip malformed rows — never fail the whole payload.
          }
        }
      }
    }

    return FriendStreaksDto(
      incoming: incoming,
      outgoingPending: outgoingPending,
      outgoingPendingPairIds: outgoingPairIds,
      pairs: pairs,
    );
  }

  FriendStreaksDto copyWith({
    List<FriendStreakIncomingDto>? incoming,
    List<String>? outgoingPending,
    Map<String, String>? outgoingPendingPairIds,
    List<FriendStreakPairDto>? pairs,
  }) {
    return FriendStreaksDto(
      incoming: incoming ?? this.incoming,
      outgoingPending: outgoingPending ?? this.outgoingPending,
      outgoingPendingPairIds:
          outgoingPendingPairIds ?? this.outgoingPendingPairIds,
      pairs: pairs ?? this.pairs,
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

  /// Community revamp (Option A, Nov 19, 2026): GAME stats, shown
  /// to confirmed friends even when [sharingEnabled] is false —
  /// only the health stats above sit behind the sharing gate.
  /// Non-nullable with an honest 0 default: 0 streak / 0 gems are
  /// real values, unlike the nullable health stats' "·" rendering.
  final int gemBalance;
  final int currentStreak;

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
    this.gemBalance = 0,
    this.currentStreak = 0,
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
        gemBalance:
            TabsBackend._asInt(raw['gemBalance'] ?? raw['gem_balance']) ??
                0,
        currentStreak: TabsBackend._asInt(raw['currentStreak']) ?? 0,
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
