/// Daily biometrics server sync (MCP spike-data package,
/// Nov 23, 2026): push the [HealthHistoryStore]'s daily rows to
/// `POST /api/sync/daily-biometrics` and merge the server's rows
/// back via `GET /api/sync/daily-biometrics`, so the server holds
/// the same per-day biometrics the phone does — resting HR,
/// sleep, spike count, calories, HRV, and (new in this package)
/// the spike summary: max HR + when, minutes over 100/120, and
/// the top-5 spike events.
///
/// Until this package the server endpoint existed but NO app
/// client called it: the Flutter capture wrote only the local
/// store. This service is that client, modeled on
/// [DailyScoreSync]'s discipline with two deliberate
/// simplifications the endpoint's semantics make safe:
///
/// - NO durable queue: the POST is a merge-upsert (server-side
///   COALESCE per field — a sent value fills/overwrites, an
///   absent field never erases), and every run re-sends the
///   store's FULL series. A failed run therefore needs no retry
///   state: the next capture's run re-sends everything and the
///   server converges. Nothing can be lost by a dropped run and
///   nothing can shrink on either side.
/// - The GET merge is FILL-ONLY ([HealthHistoryStore.mergeFillGaps]):
///   Health Connect (via the local store) is the source of truth
///   for biometrics, so a server row fills only fields the local
///   day does not hold — it never overwrites a local value. This
///   is the same hydration discipline [DailyScoreSync] applies to
///   biometric inputs.
///
/// OWNER DISCIPLINE (the VC 100107 lesson, same as
/// [DailyScoreSync]): a run resolves the session owner (the
/// backend's stored session email, falling back to the store's
/// bound owner) and refuses to send or merge when it conflicts
/// with the store's bound owner, when the owner changes mid-run,
/// or while the store sits in its owner-unverified read-only
/// state ([HealthHistoryStore.warmLoadedUnownedData]). The
/// server scopes every row to the session user, so a run under
/// the wrong account could only ever write that account's rows —
/// the checks exist so it never even tries with another
/// account's local data in flight.
///
/// TRIGGERS: after every successful history capture
/// ([HealthHistorySync] calls [syncAfterCapture] when wired).
/// Fire-and-forget from the caller: sync never blocks or delays
/// capture, scoring, or display, and never throws.
///
/// NO user-visible copy exists in this file and sync adds none
/// anywhere: this sync is invisible, exactly like the Daily
/// Score sync.
library;

import 'dart:async';

import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

class DailyBiometricsSync {
  static final DailyBiometricsSync instance = DailyBiometricsSync._internal();
  DailyBiometricsSync._internal()
      : store = HealthHistoryStore.instance,
        _backend = TabsBackend();

  /// Injectable for tests: [poster] / [fetcher] replace the
  /// backend calls, [ownerProvider] replaces the session-email
  /// read. Production uses [instance].
  DailyBiometricsSync.withDeps({
    required this.store,
    required Future<bool> Function(List<DailyBiometrics> days) this._poster,
    required Future<List<DailyBiometrics>> Function() this._fetcher,
    required Future<String?> Function() this._ownerProvider,
  }) : _backend = null;

  final HealthHistoryStore store;
  final TabsBackend? _backend;
  Future<bool> Function(List<DailyBiometrics> days)? _poster;
  Future<List<DailyBiometrics>> Function()? _fetcher;
  Future<String?> Function()? _ownerProvider;

  /// Rows per POST — far under the server's batch cap (5000);
  /// keeps any single request body modest even with spike-event
  /// JSON on every row.
  static const int postChunkSize = 1000;

  Future<bool> _post(List<DailyBiometrics> days) =>
      _poster?.call(days) ?? _backend!.postDailyBiometrics(days);

  Future<List<DailyBiometrics>> _fetch() =>
      _fetcher?.call() ?? _backend!.fetchDailyBiometrics();

  Future<String?> _sessionEmail() async {
    final provider = _ownerProvider;
    if (provider != null) return provider();
    try {
      return await _backend!.readEmail();
    } catch (_) {
      return null;
    }
  }

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  /// The session owner for this run: the provider (the backend's
  /// stored session email) first, the store's bound owner as the
  /// fallback — the [DailyScoreSync] resolution order.
  Future<String?> _resolveOwner() async {
    final fromProvider = _normalizeEmail(await _sessionEmail());
    if (fromProvider != null) return fromProvider;
    return _normalizeEmail(store.ownerEmail);
  }

  Future<bool>? _inFlight;

  /// One full sync run: POST the store's series, then GET-merge
  /// the server's rows fill-only. Concurrent calls join the
  /// in-flight run. Returns true when the POST landed in full;
  /// the GET merge's outcome never fails the run (nothing to
  /// merge is an honest result). Never throws.
  Future<bool> syncAfterCapture() {
    final existing = _inFlight;
    if (existing != null) return existing;
    late final Future<bool> future;
    future = _run().whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  Future<bool> _run() async {
    try {
      // Owner-unverified store state is read-only (H1-04): never
      // send its rows under an account we cannot prove owns them.
      if (store.warmLoadedUnownedData) return false;
      final owner = await _resolveOwner();
      final storeOwner = _normalizeEmail(store.ownerEmail);
      if (owner != null && storeOwner != null && owner != storeOwner) {
        return false;
      }

      // POST the full series, chunked. Any chunk failing stops
      // the run: the next trigger re-sends everything (the merge
      // is idempotent), so a partial run leaves no corrupt state.
      final all = await store.readAll();
      final rows = all.values.toList()
        ..sort((a, b) => a.date.compareTo(b.date));
      for (var i = 0; i < rows.length; i += postChunkSize) {
        final end =
            i + postChunkSize > rows.length ? rows.length : i + postChunkSize;
        final ok = await _post(rows.sublist(i, end));
        if (!ok) return false;
      }

      // The session may have changed while the POST was in
      // flight: refuse to merge under a different owner than the
      // one the run started with.
      final ownerNow = await _resolveOwner();
      if (owner != null && ownerNow != null && ownerNow != owner) {
        return true; // the POST landed; only the merge is refused
      }
      if (ownerNow != null &&
          storeOwner != null &&
          ownerNow != storeOwner) {
        return true;
      }

      // GET + fill-only merge: server rows populate fields the
      // local day lacks (e.g. days synced from another device);
      // local values always win.
      final serverRows = await _fetch();
      if (serverRows.isNotEmpty) {
        await store.mergeFillGaps(serverRows);
      }
      return true;
    } catch (_) {
      // Sync must never break a capture or a screen.
      return false;
    }
  }
}
