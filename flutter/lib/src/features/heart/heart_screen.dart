import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/hc_availability.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/connections/health_connect_disclosure.dart';
import 'package:tabs_lab/src/features/home/hc_repair_card.dart';
import 'package:tabs_lab/src/features/heart/heart_spike_review_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Dark ink on a primary fill (native LegacyDarkChipInk) — the in-app
/// passing precedent for text on Tabs purple: 5.21:1 vs white's 3.80:1
/// (R49 audit S1/HE5).
const _chipInk = Color(0xFF0A0A0E);

// ── Juno copy ruling (JUNO-COPY.md, BINDING, Nov 24, 2026) ──────
// Every new user-facing string in this package is a named constant
// here (or in heart_spike_review_screen.dart for §4), verbatim from
// the ruling — no paraphrase. JUNO-COPY.md is the source of truth.

/// §1 — stale-data state: the live read for the selected date
/// finished and failed/timed out AND stored data for that date is
/// on screen. Renders above the summary card, in place of the
/// "Updating sync data..." strip, only after the load finished.
const heartStaleDataMessage = "Couldn't update — showing last saved data";

/// §2 — no-data failure state title: the live read finished and
/// failed/timed out AND no stored data exists for the date. In
/// this state the screen must NOT render "-- bpm", an empty chart,
/// or "0 spikes" as if they were data.
const heartNoDataTitle = "Couldn't load heart data for this day.";

/// §2 — no-data failure state body (the refresh icon at the top of
/// the screen is the real control it names).
const heartNoDataBody = 'Tap refresh at the top to try again.';

/// §3 — chart stored-summary-only marker: a stored summary renders
/// for the date but no intraday series is on the phone, so the
/// chart itself has nothing to draw.
const heartChartSummaryOnlyMessage =
    "Saved summary only — chart detail isn't available for this day";

/// §1b.2 (Juno addendum — Vera Condition 1b ruling, Nov 24, 2026) —
/// the spikes card's successful-but-empty state: the live read for
/// the selected date finished successfully and returned zero
/// samples, and no other examined data backs the card (no valid or
/// cached series, no non-null stored spike count / stored
/// summary). That is an UNEXAMINED day: these two lines render in
/// place of the spike count and the load level, with no count
/// number, no load-level label, and no zero claim alongside. This
/// is NOT §2 — the load did not fail, so §2's wording is never
/// reused here.
const heartNoReadingsTitle = 'No readings were returned for this day.';

/// §1b.2 line 2 — see [heartNoReadingsTitle].
const heartNoReadingsBody = "Spikes can't be checked without readings.";

/// Round 25 — the Heart tab, port of native `FitbitScreen.kt`
/// (legacy filename; it IS the native Heart screen).
///
/// Layout, traced from the Kotlin source (dp/sp/colors are native
/// values, dark palette — the Flutter Lab is dark-only):
/// - TopAppBar: "Heart" (28sp, FontWeight Black), and when connected a
///   date pill (surfaceHigh, radius 20, "Today"/"MMM d" 13sp SemiBold
///   + 16dp chevron-down) and a refresh icon button.
/// - The date pill opens a date picker (native: Material3
///   DatePickerDialog, selectable range = today minus 180 days
///   through today). Picking a date reloads that date's series.
/// - Refresh = native `viewModel.sync(force = true)`: bypasses the
///   native 5-minute sync throttle; here it simply re-reads Health
///   Connect for the selected date (the Dart bridge has no throttle).
/// - While a load runs AND data is already on screen, native's inline
///   "Updating sync data..." strip shows (14dp spinner + 12sp text)
///   — values are never wiped for a spinner (stale-while-revalidate
///   via [HeartDataCache]: cached values render on the first frame,
///   the refresh swaps in quietly).
/// - Not connected: native's full-screen "Connect Vital Signs" state.
///   Its Link button launches the HC permission flow directly in
///   native; here the house compliance rule (Juno MF-3, round 12)
///   puts the prominent disclosure BEFORE the system dialog, exactly
///   like the Connections screen. Flagged in the round report.
///
/// Data definitions live in heart_data.dart with file/line traces.
/// Awake window unified in Round 26 (founder decision Oct 12, 2026):
/// hours 7..22 everywhere — the Heart VM and the snapshot code agree.
class HeartScreen extends StatefulWidget {
  final String? email;

  /// Injectable for tests; defaults to a real HealthConnectService.
  final HealthConnectService? healthConnectService;

  /// Injectable for tests; defaults to the shared [HeartDataCache].
  final HeartDataCache? cache;

  /// Injectable for tests; defaults to the shared
  /// [HealthHistoryStore] — the store-first source this screen now
  /// seeds its first paint from (Heart store-first fix).
  final HealthHistoryStore? historyStore;

  /// Test seam: the date the screen opens on. Production leaves it
  /// null and the screen opens on today, exactly as before.
  final DateTime? initialDate;

  /// Heart/Sleep toggle (founder, Nov 23, 2026) — supplied by the
  /// shell, which owns the heart slot's mode. The moon button in
  /// the AppBar calls it to switch the slot to the Sleep screen.
  final VoidCallback? onShowSleep;

  const HeartScreen(
      {super.key,
      this.email,
      this.healthConnectService,
      this.cache,
      this.historyStore,
      this.initialDate,
      this.onShowSleep});

  @override
  State<HeartScreen> createState() => _HeartScreenState();
}

class _HeartScreenState extends State<HeartScreen> {
  late final HealthConnectService _service;
  late final HeartDataCache _cache;
  late final HealthHistoryStore _store;

  bool? _connected; // null = first check not landed yet
  bool _requesting = false;
  String? _error;
  late DateTime _selectedDate;
  HeartDayData? _data;
  DateTime? _lastSyncAt;

  /// Heart store-first fix — per-date in-flight load tracking,
  /// replacing the single `_loading` flag whose `if (_loading)
  /// return` guard DROPPED a date pick made during a pending load
  /// (and the finishing load then applied its result under the NEW
  /// date's key). A picked date now starts its own load; a
  /// same-date duplicate still joins the in-flight one.
  final Set<String> _inFlightDates = <String>{};

  /// Whether a load for the SELECTED date is in flight — the
  /// spinner strip and the refresh button key off this, exactly as
  /// they keyed off the old single flag.
  bool get _loading => _inFlightDates.contains(_dateStr);

  /// The date whose most recent finished load FAILED (any read
  /// error, including READ_TIMEOUT), or null. Juno §1/§2: the
  /// failure states render only for the selected date, only after
  /// its load finished (spinner cleared — [_loading] false), and a
  /// successful refresh for the date clears the flag in the same
  /// update that swaps the fresh data in.
  String? _failedDateStr;

  /// The date whose most recent finished load SUCCEEDED with zero
  /// samples (no error, no partial), or null. Juno §1b.1/§1b.2: a
  /// successful-but-empty read is an UNEXAMINED day — the spikes
  /// card renders the two ruled no-readings lines for it when no
  /// examined data backs the card. Set/cleared in the same update
  /// that resolves the date's load, exactly like [_failedDateStr].
  String? _noReadingsDateStr;

  /// The history-store row for the selected date, when one exists
  /// — the store-first seed's source and Spike Review's stored
  /// count. Kept beside [_data] because a series-derived [_data]
  /// carries no stored fields.
  DailyBiometrics? _storeRow;

  /// HC Grant Hardening §3.4 — the availability snapshot the last
  /// connection check probed; the wedge derivation and the repair
  /// card read from it (plus [_hrReadBlocked]).
  HcAvailability? _lastSnapshot;

  /// iOS surface truth (Juno Heart/Home addendum, 2026-11-22) — on
  /// iOS this screen's gate derives from [probeIosAvailability]
  /// ONLY: the Android grant snapshot, the Android persisted-grant
  /// key, and the Android status pipeline never paint this screen
  /// on iOS. Null until the first iOS probe lands.
  IosHealthAvailability? _iosAvailability;

  /// This screen's HR-read wedge evidence from the most recent
  /// load: true when the HR read failed with a SecurityException,
  /// false when it completed (data or honest empty), null when no
  /// load has run since the last check — the snapshot's probe
  /// evidence decides then (see [_hrWedged]).
  bool? _hrReadBlocked;

  /// The repair card's second step (remove-access directions) —
  /// set when an in-place repair attempt did not clear the wedge.
  bool _repairSecondStep = false;
  bool _repairing = false;

  /// HC Grant Hardening §3.2 — this screen's wedged state: HR is
  /// granted (verified, from the snapshot) AND the HR read path is
  /// blocked — proven either by this screen's own read outcome or,
  /// before any load has run, by the snapshot's stale-wedged probe
  /// evidence. A completed HR read (data or honest empty) clears
  /// it: dismissal is derived from the state, never latched.
  bool get _hrWedged {
    final snapshot = _lastSnapshot;
    if (snapshot == null || !snapshot.grantKnown) return false;
    if (snapshot.missingPermissions
        .contains('android.permission.health.READ_HEART_RATE')) {
      return false;
    }
    final blocked = _hrReadBlocked;
    if (blocked != null) return blocked;
    return snapshot.staleWedged;
  }

  String get _dateStr => _fmtDate(_selectedDate);
  String get _todayStr => _fmtDate(DateTime.now());

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The stored-summary seed for [dateStr] from [row], or null
  /// when the row holds no heart summary fields. Pure: callers
  /// own the state assignment.
  HeartDayData? _storeSeedFor(String dateStr, DailyBiometrics? row) {
    if (row == null) return null;
    if (row.spikeCount == null && row.maxHrBpm == null) return null;
    return HeartDayData.fromStoredSummary(
      spikeCount: row.spikeCount,
      maxHrBpm: row.maxHrBpm,
      minutesOver100: row.minutesOver100,
      minutesOver120: row.minutesOver120,
      restingHrBpm: row.restingHrBpm,
    );
  }

  /// Seeds [_data] / [_storeRow] for the selected date from what
  /// is already in memory: the cache's raw series wins where
  /// present; otherwise the store row's summary renders (ANY date,
  /// including past days, with zero bridge reads). Never replaces
  /// a renderable series with a summary. Call inside setState or
  /// initState.
  void _seedFromLocalSources() {
    _storeRow = _store.peekDay(_dateStr);
    final cached = _cache.snapshot(_dateStr);
    if (cached != null && cached.samples.isNotEmpty) {
      _data = cached;
      return;
    }
    final seed = _storeSeedFor(_dateStr, _storeRow);
    if (seed != null) {
      _data = seed;
      return;
    }
    if (cached != null) _data = cached;
  }

  /// The Health Connect row's sync stamp: the Heart cache's stamp
  /// floored by the capture's stamp (Heart store-first fix). The
  /// row previously read ONLY the cache stamp, which failed Heart
  /// loads are forbidden from advancing — so it said "Not synced
  /// yet" forever over a store the capture had already synced.
  /// The floor can never move the stamp BACKWARD: the later of
  /// the two real stamps wins.
  DateTime? _effectiveLastSyncAt() {
    var t = _cache.lastSyncAt ?? _lastSyncAt;
    final capMs = _store.lastCaptureMs;
    if (capMs != null) {
      final cap = DateTime.fromMillisecondsSinceEpoch(capMs);
      if (t == null || cap.isAfter(t)) t = cap;
    }
    return t;
  }

  /// Records this screen's own live-read outcome into the capture
  /// diagnostics (a `heartRead` entry — see
  /// [HealthHistoryStore.recordCaptureDiagnostics]). Fire-and-
  /// forget by design: diagnostics must never fail a load, and the
  /// store call itself never throws.
  Future<void> _recordHeartRead({
    required bool failed,
    required String? errorCode,
    required int sampleCount,
  }) async {
    try {
      await _store.recordCaptureDiagnostics(
        failures: failed
            ? {'heartRead': errorCode ?? 'HEART_READ_FAILED'}
            : const {},
        succeeded: failed ? const {} : const {'heartRead'},
        atMs: DateTime.now().millisecondsSinceEpoch,
        heartReadErrorCode: failed ? (errorCode ?? 'HEART_READ_FAILED') : null,
        heartReadSampleCount: sampleCount,
      );
    } catch (_) {
      // Diagnostics are best-effort; the load's outcome stands.
    }
  }

  @override
  void initState() {
    super.initState();
    _service = widget.healthConnectService ?? HealthConnectService();
    _cache = widget.cache ?? HeartDataCache.instance;
    _store = widget.historyStore ?? HealthHistoryStore.instance;
    _selectedDate = widget.initialDate ?? DateTime.now();
    // Instant first paint from local sources (memory): the cache's
    // series, or the history store's summary for the date — the
    // store-first seed. The live read refreshes BEHIND this paint.
    _seedFromLocalSources();
    _lastSyncAt = _effectiveLastSyncAt();
    unawaited(_init());
  }

  Future<void> _init() async {
    await _cache.clearIfOwnerMismatch(widget.email);
    if (_data == null) {
      await _cache.warmFromDisk(currentEmail: widget.email);
    }
    if (!mounted) return;
    setState(() {
      _seedFromLocalSources();
      _lastSyncAt = _effectiveLastSyncAt();
    });
    // Warm the history store CONCURRENTLY — first paint and the
    // connection check never gate on a storage read (a slow or
    // wedged store must not reproduce the original "nothing
    // loads" failure in a new costume). When the warm lands, a
    // seed-only screen upgrades from the store (a cold start's
    // disk blob may hold the selected date's summary even when
    // memory started empty); live samples on screen are never
    // replaced by a seed.
    unawaited(_store.warmFromDisk(currentEmail: widget.email).then((_) {
      if (!mounted) return;
      final d = _data;
      if (d == null || d.storedSummaryOnly || d.samples.isEmpty) {
        setState(() {
          _seedFromLocalSources();
          _lastSyncAt = _effectiveLastSyncAt() ?? _lastSyncAt;
        });
      }
    }));
    await _checkConnectionAndLoad();
  }

  Future<void> _checkConnectionAndLoad({bool forceLoad = false}) async {
    if (_service.isIOS) {
      // iOS surface truth (Juno Heart/Home addendum §2.0): the gate
      // is the four-state iOS probe and nothing else. State 2
      // (requested AND a real read returned data) is the only state
      // that earns the connected body; States 1/3/4 get their own
      // signed presentations (see _iosBody). The probe never throws
      // by contract; the catch-all maps any platform surprise to
      // unavailable rather than to the Android persisted fallback.
      IosHealthAvailability iosSnapshot;
      try {
        iosSnapshot = await _service.probeIosAvailability();
      } catch (_) {
        iosSnapshot = const IosHealthAvailability(
          state: IosHealthAvailabilityState.unavailable,
          requested: false,
          hasData: false,
        );
      }
      if (!mounted) return;
      final iosConnected =
          iosSnapshot.state == IosHealthAvailabilityState.connected;
      setState(() {
        _iosAvailability = iosSnapshot;
        _connected = iosConnected;
      });
      if (iosConnected) await _load(force: forceLoad);
      return;
    }
    // HC Grant Hardening §3.4 — the layout gate is the grant state
    // for HEART's permission set alone (READ_HEART_RATE), derived
    // from ONE availability probe — never the global
    // all-15-required verdict the old isConnected() check imposed:
    // a missing unrelated permission (Weight, say) no longer
    // paints this screen "not connected", and a granted HR with an
    // unknown grant layer still attempts its read.
    // Bounded (same defect class as the BP screen's check and the
    // Heart read wedge): a stalled HC platform call used to leave
    // _connected null forever — no date pill, no load, all "--".
    // The bound uses the shared readTimeout; expiry synthesizes
    // an unknown snapshot, which falls through to the persisted
    // fallback exactly like any other failure.
    HcAvailability snapshot;
    try {
      snapshot = await _service
          .probeAvailability()
          .timeout(HealthConnectService.readTimeout);
    } catch (_) {
      // Timeout or throw: an unknown snapshot, which falls
      // through to the persisted fallback exactly like the old
      // check's catch-all did. (The real probe never throws by
      // contract; the catch-all keeps that parity for any
      // platform-channel surprise underneath it.)
      snapshot = const HcAvailability(
        serviceAvailable: false,
        grantedPermissions: null,
        bridgeErrorCode: 'PROBE_TIMEOUT',
        stepsProbe: null,
        persistedConnected: false,
      );
    }
    bool connected;
    if (snapshot.status == HealthConnectStatus.unavailable) {
      connected = false;
    } else if (snapshot.grantKnown) {
      // Verified-missing HR → the Link layout; granted HR → body.
      connected =
          hcGrantStateFor(heartPermissions, snapshot.missingIfKnown) !=
              HcGrantState.none;
    } else {
      // Grant layer unknown (bridge error): fall back to persisted
      // state, like the connections screen. The fallback only
      // PAINTS the connected layout: the load below is the real
      // proof, and its error surfaces even over cached data (see
      // _load) — persisted state can no longer silently mask dead
      // reads (hardening #6, Vera F8: the behavior lives in _load's
      // error path, no separate flag).
      try {
        connected = await _service.hasPersistedConnection();
      } catch (_) {
        connected = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _connected = connected;
      _lastSnapshot = snapshot;
      // A fresh check re-derives the wedge from the probe; the
      // load below replaces the read evidence for this check.
      _hrReadBlocked = null;
      if (!_hrWedged) _repairSecondStep = false;
    });
    if (connected) await _load(force: forceLoad);
  }

  Future<void> _load({bool force = false}) async {
    // Heart store-first fix — capture the date at entry and apply
    // the result under THAT key. The old code re-evaluated the
    // `_dateStr` getter after the await, so a load that finished
    // after a date switch applied the OLD date's result under the
    // NEW date's key.
    final dateStr = _dateStr;
    // Per-date in-flight tracking: a load already running for THIS
    // date joins (returns); a load running for ANOTHER date no
    // longer drops this one — the picked date starts its own load.
    if (_inFlightDates.contains(dateStr)) return;
    // Perf package (Nov 2, 2026) — freshness skip: when this date's
    // series was successfully loaded within HeartDataCache's fresh
    // window (by this screen, or by Home's vitals load writing
    // through to the same cache), the painted cache IS the current
    // data — re-reading the full raw day from Health Connect would
    // return the same series and only cost the wait. The skip never
    // applies to a forced load (refresh button, Connections return,
    // permission grant), and a date with no cached series always
    // loads as before.
    if (!force && _cache.isFresh(dateStr)) {
      final cached = _cache.snapshot(dateStr);
      if (cached != null) {
        if (mounted && dateStr == _dateStr) {
          setState(() {
            _data = cached;
            _lastSyncAt = _effectiveLastSyncAt();
            _error = null;
            if (_failedDateStr == dateStr) _failedDateStr = null;
            if (_noReadingsDateStr == dateStr) _noReadingsDateStr = null;
          });
        }
        return;
      }
    }
    _inFlightDates.add(dateStr);
    if (mounted) {
      // Repaint for the spinner strip (derived from _inFlightDates);
      // stored/cached data stays on screen behind it — the load no
      // longer gates first paint.
      setState(() => _error = null);
    }
    List<HrSample> raw = const [];
    String? errCode;
    String? partialCode;
    String? errDetails;
    var threw = false;
    try {
      // Vera Condition 2 — this load claims its OWN outcome object
      // (readHeartRateSamplesWithOutcome, the same per-load claim
      // Home's write-through gate uses), never the service's SHARED
      // slot fields. Per-date loads now run concurrently, and the
      // slots are written/reset by every load on the instance: a
      // sibling load's entry reset could wipe this load's recorded
      // error before it was captured (a failed read stamped as a
      // sync), and a sibling's timeout write could land after this
      // load's reset and be captured as THIS load's outcome (a
      // successful date marked failed, wrong heartRead diagnostic
      // for both). The outcome carries this read's own error /
      // partial / details, so each load's classification,
      // diagnostics, and cache-apply decision derive from its own
      // read alone. This load neither resets nor writes the slots.
      // Subclass fakes that override only the legacy method keep
      // working: the service reconstructs their outcome from the
      // slots they set, serialized under its per-instance gate
      // until the read's box shape is proven (see _outcomeOf).
      //
      // Bounded wait (hardening #2): the bridge read itself had NO
      // timeout, so a never-returning channel call wedged this
      // screen's "Updating sync data..." spinner forever (defect
      // #3). On expiry THIS load fails closed as READ_TIMEOUT via
      // its own synthesized outcome — the shared slots are not
      // written, so the timeout can never be attributed to a
      // sibling load — and the failed-load path below surfaces it:
      // never a permanent spinner. (The service's outcome path
      // carries the same bound internally; this caller-side bound
      // keeps the identical semantics for subclass fakes, whose
      // futures are theirs alone.)
      final outcome = await _service
          .readHeartRateSamplesWithOutcome(dateStr)
          .timeout(HealthConnectService.readTimeout, onTimeout: () {
        return const HcReadOutcome<List<HrSample>>(
          value: <HrSample>[],
          errorCode: 'READ_TIMEOUT',
          errorDetails:
              'Health Connect did not respond in time. Please try again.',
        );
      });
      raw = outcome.value;
      errCode = outcome.errorCode;
      partialCode = outcome.partialCode;
      errDetails = outcome.errorDetails;
    } catch (_) {
      threw = true;
    }
    // A hard failure must NOT stamp the cache's lastSyncAt —
    // "Synced just now" over a failed load is founder defect #3 —
    // and must not be persisted as a fresh blob. A partial read
    // delivered real data and counts as a sync.
    final hardFailed = threw || errCode != null;
    // B-01: a partial read that collected NOTHING is not a sync
    // either — passing it as succeeded would let the empty series
    // overwrite the cached series for the date and stamp it fresh
    // (HeartDataCache.apply also refuses an empty overwrite, so
    // the guard holds even if a caller forgets this one). A
    // partial read WITH samples still counts as a sync, exactly
    // as before, and the partial banner below still shows.
    final partialEmpty = partialCode != null && raw.isEmpty;
    // Vera Condition 1c: a partial-empty read takes the FAILED
    // path for the Juno §1/§2 state decision — its own B-01 rule
    // already holds it is "not a sync" because nothing was
    // collected, so with stored data it derives §1 and with none
    // it derives §2, never the success path's placeholder claims.
    // (Its error LINE stays the partial sentence — Juno J4: the
    // partial copy must not claim total failure — and its
    // heartRead diagnostic stays the partial's, not a failure's.)
    final failed = hardFailed || partialEmpty;
    final countsAsSync = !failed;
    HeartDayData data;
    if (threw) {
      // Keep whatever local data the date already has — the cache's
      // series or the store seed — instead of swapping in empties.
      data = _cache.snapshot(dateStr) ??
          _storeSeedFor(dateStr, _store.peekDay(dateStr)) ??
          HeartDayData.empty;
    } else {
      data = _cache.apply(dateStr, raw,
          ownerEmail: widget.email, succeeded: countsAsSync);
      if (countsAsSync) unawaited(_cache.persist());
      // A failed (or honestly empty) apply with nothing cached
      // falls back to the store seed for THIS date, so stored data
      // stays on screen behind the Juno §1 stale state.
      if (!data.hasRenderableData) {
        final seed = _storeSeedFor(dateStr, _store.peekDay(dateStr));
        if (seed != null) data = seed;
      }
    }
    // The Heart read's own outcome lands in the capture
    // diagnostics (heartRead entry) — the next wedge is diagnosable
    // from the store instead of invisible. Keyed on the HARD
    // failure only, from THIS load's outcome object (Condition 2):
    // a partial read — even a partial-empty one — is not a failed
    // read diagnostically, exactly as before.
    unawaited(_recordHeartRead(
      failed: hardFailed,
      errorCode: threw ? 'HEART_READ_FAILED' : errCode,
      sampleCount: raw.length,
    ));
    _inFlightDates.remove(dateStr);
    if (!mounted) return;
    setState(() {
      _lastSyncAt = _effectiveLastSyncAt();
      // Juno §1/§2 bookkeeping: success clears the date's failure
      // in the same update that swaps its fresh data in; failure
      // marks the date so the honest state renders above the cards
      // (with the spinner now cleared).
      if (failed) {
        _failedDateStr = dateStr;
        if (_noReadingsDateStr == dateStr) _noReadingsDateStr = null;
      } else if (_failedDateStr == dateStr) {
        _failedDateStr = null;
      }
      // Juno §1b bookkeeping: a load that finished successfully
      // with zero samples (no error, no partial) marks its date
      // successful-but-empty; a successful non-empty load clears
      // its date's mark (the failed branch above clears it too).
      if (!failed && errCode == null && partialCode == null) {
        if (raw.isEmpty) {
          _noReadingsDateStr = dateStr;
        } else if (_noReadingsDateStr == dateStr) {
          _noReadingsDateStr = null;
        }
      }
      // Only the SELECTED date's completion paints. A load that
      // finishes after a date switch has already applied its
      // result to the cache under its own key above; the picked
      // date's own load paints its own data when it lands.
      if (dateStr == _dateStr) {
        _data = data;
        _storeRow = _store.peekDay(dateStr);
        // HC Grant Hardening §3.2 — this load's own wedge
        // evidence: a hard failure whose native exception class
        // is a SecurityException is the granted-but-blocked
        // signature for THIS screen's type; any completed read
        // (data, honest empty, or partial) clears it.
        _hrReadBlocked = hardFailed &&
            (errDetails?.contains('SecurityException') ?? false);
        if (!_hrWedged) _repairSecondStep = false;
        if (hardFailed) {
          _error = 'Could not read heart rate data.';
        } else if (partialCode != null) {
          // Juno J4: partial copy must not claim total failure —
          // a partial-empty read takes the §1/§2 failure path for
          // its STATE (Condition 1c) but keeps this sentence.
          _error = 'Some heart rate data could not be read and may be missing.';
        } else {
          _error = null;
        }
      }
    });
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final firstDate = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 180));
    final lastDate = DateTime(today.year, today.month, today.day);
    final initialDate = _selectedDate.isBefore(firstDate)
        ? firstDate
        : (_selectedDate.isAfter(lastDate) ? lastDate : _selectedDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null || !mounted) return;
    final pickedDay = DateTime(picked.year, picked.month, picked.day);
    final currentDay =
        DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    if (pickedDay == currentDay) return;
    setState(() {
      _selectedDate = pickedDay;
      // Local sources for the new date render instantly when
      // present: the cached series, or the store summary (the
      // store-first seed — a past day with no cached series no
      // longer paints placeholders while its load runs).
      _data = null;
      _seedFromLocalSources();
      _lastSyncAt = _effectiveLastSyncAt();
    });
    // Per-date in-flight tracking: this starts the picked date's
    // OWN load even when another date's load is still pending —
    // the old single-flag guard dropped this call entirely.
    await _load();
  }

  Future<void> _onLinkTap() async {
    if (_requesting) return;
    if (_service.isIOS) {
      // Juno Heart/Home addendum §2.1: NO MF-3 Health Connect
      // disclosure dialog on iOS — the tap goes straight to the
      // HealthKit request. The service's empty-set return is by
      // design (HealthKit discloses no grant list), so the Android
      // "No permissions were granted." verdict NEVER renders here:
      // a completed request simply re-probes and lands on State 2
      // (data returned) or the State 3 presentation. Only a FAILED
      // request surfaces an error, and only the service's approved
      // iOS strings can reach this slot.
      setState(() {
        _requesting = true;
        _error = null;
      });
      try {
        await _service.requestPermissions();
      } on HealthConnectException catch (e) {
        if (mounted) {
          setState(() {
            _requesting = false;
            _error = e.message;
          });
        }
        return;
      }
      if (!mounted) return;
      setState(() => _requesting = false);
      await _checkConnectionAndLoad(forceLoad: true);
      return;
    }
    // Juno MF-3: prominent disclosure BEFORE the system permission UI.
    final proceed = await showHealthConnectDisclosure(context);
    if (!proceed || !mounted) return;
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      final wasConnected = _connected ?? false;
      final granted = await _service.requestPermissions();
      if (!mounted) return;
      // HC Grant Hardening §3.4 — the post-request verdict judges
      // THIS screen's permission alone: a grant that includes
      // heart rate connects the Heart screen even when some other
      // type was declined.
      final connected = granted.containsAll(heartPermissions);
      setState(() {
        _requesting = false;
        _connected = connected;
        if (!connected && granted.isEmpty) {
          _error = 'No permissions were granted.';
        }
      });
      if (connected) {
        // Sync-settings package (Nov 23, 2026) — a NEW heart
        // grant (this screen was not connected before) runs
        // the post-grant capture, in addition to this screen's
        // own reload.
        if (!wasConnected) {
          unawaited(HealthHistorySync.instance.captureAfterGrant(
              relevantPermissions: heartPermissions));
        }
        await _load(force: true);
      }
    } on HealthConnectException catch (e) {
      if (mounted) {
        setState(() {
          _requesting = false;
          _error = e.message;
        });
      }
    }
  }

  /// HC Grant Hardening §3.3 — the repair card's tap: runs the
  /// shared in-place repair flow (MF-3 disclosure first, then the
  /// permission request; see [runHcRepairFlow]). A cleared flow
  /// force-reloads through a fresh check; if the wedge survives
  /// the reload, the card swaps to its second step (the
  /// remove-access directions). A failed request surfaces its
  /// message through the screen's existing error line, exactly
  /// like the link flow's failures.
  Future<void> _onRepairTap() async {
    if (_repairing) return;
    setState(() => _repairing = true);
    final result = await runHcRepairFlow(context, _service);
    if (!mounted) return;
    setState(() => _repairing = false);
    switch (result.outcome) {
      case HcRepairOutcome.aborted:
        break;
      case HcRepairOutcome.failed:
        setState(() {
          _error = result.errorMessage ?? 'Health Connect request failed.';
        });
      case HcRepairOutcome.stillWedged:
        setState(() => _repairSecondStep = true);
      case HcRepairOutcome.cleared:
        // Sync-settings package — the shared repair flow's
        // cleared path runs the post-grant capture too (see
        // Home's repair handler).
        unawaited(HealthHistorySync.instance.captureAfterGrant(
            relevantPermissions:
                HealthConnectService.requiredPermissions));
        await _checkConnectionAndLoad(forceLoad: true);
        if (mounted && _hrWedged) {
          setState(() => _repairSecondStep = true);
        }
    }
  }

  void _showHrInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Heart Rate Insights',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Tabs tracks your 'Awake Average' to better understand your physiological load throughout the day.",
              style: TextStyle(fontSize: 14, color: NotelColors.textSecondary),
            ),
            SizedBox(height: 12),
            Text(
              'Clinical Benchmarks:\n'
              '• Resting (RHR): 60 - 80 bpm\n'
              '• Tachycardia: >100 bpm at rest\n'
              '• Bradycardia: <60 bpm at rest',
              style: TextStyle(fontSize: 14, color: NotelColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it', style: TextStyle(color: NotelColors.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _openSpikeReview() async {
    final data = _data;
    // Heart store-first fix: the review receives the RENDERED day
    // (plus the store row's count), not only the raw series — a
    // summary-only day hands the review an empty series AND the
    // stored count, and the review renders Juno §4's
    // detail-unavailable state instead of wording the empty list
    // as an all-clear.
    final storedCount =
        data?.storedSpikeCount ?? _storeRow?.spikeCount;
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => HeartSpikeReviewScreen(
          samples: data?.samples ?? const [],
          dateStr: _dateStr,
          heartData: data,
          storedSpikeCount: storedCount,
        ),
      ),
    );
  }

  Future<void> _openConnections() async {
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => ConnectionsScreen(healthConnectService: _service),
      ),
    );
    if (!mounted) return;
    // Native returns to the same shared state; re-check + refresh.
    // Forced: a permission fix made in Connections must take effect
    // on this load, never be freshness-skipped.
    await _checkConnectionAndLoad(forceLoad: true);
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connected;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        title: const Text(
          'Heart',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 22,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          // Date selector pill (native: Surface radius 20,
          // surfaceHigh fill, textSecondary @20% border). Always
          // visible — NOT gated on the connection verdict: a
          // stalled or negative check must never take the day
          // picker away. (The refresh button below stays gated
          // on connected, exactly as before.)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Material(
                color: NotelColors.surfaceHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: NotelColors.textSecondary.withValues(alpha: 0.2),
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _pickDate,
                  // R49 HE2: hit area ≥48dp tall (was ≈30dp);
                  // glyphs and pill padding unchanged.
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            heartDateLabel(_dateStr, _todayStr),
                            style: const TextStyle(
                              color: NotelColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.keyboard_arrow_down,
                            color: NotelColors.textSecondary,
                            size: 16,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Heart/Sleep toggle (founder, Nov 23, 2026): the moon
          // sits immediately beside the refresh ("sync") button
          // and is ALWAYS visible — unlike refresh it is NOT gated
          // on the connection verdict, so the slot can be switched
          // to Sleep in the not-connected state too.
          IconButton(
            onPressed: widget.onShowSleep,
            icon: const Icon(Icons.bedtime,
                size: 24,
                color: NotelColors.textSecondary,
                semanticLabel: 'Sleep'),
            tooltip: 'Sleep',
          ),
          if (connected == true)
            IconButton(
              onPressed: _loading ? null : () => unawaited(_load(force: true)),
              icon: const Icon(Icons.refresh,
                  size: 24, color: NotelColors.textSecondary),
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: _service.isIOS
          ? _iosBody()
          : connected == false
              ? _notConnectedBody()
              : _connectedBody(),
    );
  }

  /// iOS surface truth (Juno Heart/Home addendum §2.0) — the Heart
  /// presentation is chosen by the iOS probe state alone. Before
  /// the first probe lands, the connected body paints (its cached
  /// values / "--" placeholders are a data state, not a connection
  /// claim), exactly as the pre-check first frame has always done.
  Widget _iosBody() {
    final snapshot = _iosAvailability;
    if (snapshot == null) return _connectedBody();
    return switch (snapshot.state) {
      IosHealthAvailabilityState.connected => _connectedBody(),
      IosHealthAvailabilityState.notYetRequested => _iosState1Body(),
      IosHealthAvailabilityState.noDataYet => _iosState3Body(),
      IosHealthAvailabilityState.unavailable => _iosState4Body(),
    };
  }

  /// The shared centered column for the iOS State 1/3/4
  /// presentations (the not-connected layout's shape). All strings
  /// are Juno-signed verbatim — see the per-state builders.
  Widget _iosStateBody({
    required String headline,
    required String body,
    String? secondary,
    String? buttonLabel,
    VoidCallback? onButtonTap,
    bool buttonBusy = false,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 48),
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: 0.1,
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: NotelColors.primary,
                    ),
                  ),
                ),
                const Icon(Icons.favorite,
                    size: 64, color: NotelColors.primary),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Text(
            headline,
            style: const TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: const TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 14,
              height: 22 / 14,
            ),
            textAlign: TextAlign.center,
          ),
          if (secondary != null) ...[
            const SizedBox(height: 12),
            Text(
              secondary,
              style: const TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
                height: 22 / 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (buttonLabel != null) ...[
            const SizedBox(height: 40),
            FractionallySizedBox(
              widthFactor: 0.9,
              child: _GlassyButton(
                color: NotelColors.primary,
                onTap: buttonBusy ? null : onButtonTap,
                child: buttonBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _chipInk,
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          buttonLabel,
                          style: const TextStyle(
                            color: _chipInk,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: NotelColors.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  /// State 1 — not yet requested (addendum §2.1). Headline shared;
  /// body and button are the signed iOS literals. No disclosure
  /// dialog precedes the tap (see [_onLinkTap]).
  Widget _iosState1Body() {
    return _iosStateBody(
      headline: 'Connect Vital Signs',
      body: 'Connect Apple Health to read your heart rate and sleep data.',
      buttonLabel: 'Connect Apple Health',
      onButtonTap: _onLinkTap,
      buttonBusy: _requesting,
    );
  }

  /// State 3 — requested, no data yet (addendum §2.2). Every string
  /// reused verbatim from Juno's signed availability file, State 3.
  /// Never labeled not-connected; "Check again" re-runs the probe.
  Widget _iosState3Body() {
    return _iosStateBody(
      headline: 'No data yet',
      body: 'Tabs has asked Apple Health for your health data, and '
          'nothing has come back yet. That is normal if you do not '
          'have an Apple Watch or another app writing to Apple '
          'Health: heart rate, resting heart rate, and heart rate '
          'variability are recorded by a watch, and sleep is '
          'recorded by a watch or another sleep app. Steps and '
          'energy from your iPhone can take a little while to '
          'appear. Your logging, check-ins, and notes in Tabs work '
          'either way.',
      secondary: 'If you expected data to be here, check that Tabs '
          'is allowed to read it: open the Health app, tap your '
          'profile, tap Apps, tap Tabs, and make sure the data '
          'types you want are on.',
      buttonLabel: 'Check again',
      onButtonTap: () =>
          unawaited(_checkConnectionAndLoad(forceLoad: true)),
    );
  }

  /// State 4 — unavailable (addendum §2.3): signed copy, NO button,
  /// and never the State 1 headline.
  Widget _iosState4Body() {
    return _iosStateBody(
      headline: 'Not available on this device',
      body: 'Apple Health is not available on this device, so Tabs '
          'cannot read health data from it here. Your logging, '
          'check-ins, and notes in Tabs still work.',
    );
  }

  // Native not-connected state (FitbitScreen.kt): centered column,
  // 120dp circle (primary @10%) with a 64dp heart, title, copy, and
  // the Link Health Connect button at 90% width.
  Widget _notConnectedBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 48),
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: 0.1,
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: NotelColors.primary,
                    ),
                  ),
                ),
                const Icon(Icons.favorite,
                    size: 64, color: NotelColors.primary),
              ],
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Connect Vital Signs',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Link Health Connect to automatically sync your heart rate and sleep data.',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 14,
              height: 22 / 14,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 40),
          FractionallySizedBox(
            widthFactor: 0.9,
            child: _GlassyButton(
              color: NotelColors.primary,
              onTap: _requesting ? null : _onLinkTap,
              child: _requesting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _chipInk,
                      ),
                    )
                  : const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'Link Health Connect',
                        style: TextStyle(
                          color: _chipInk,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: NotelColors.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  /// Juno §1 — the stale-data state, rendered above the summary
  /// card in place of the loading strip (same slot, same shape).
  Widget _staleDataBanner() {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline, size: 14, color: NotelColors.error),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              heartStaleDataMessage,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Juno §2 — the no-data failure state. Renders in place of the
  /// summary/pattern/spikes cards: in this state the screen must
  /// NOT render "-- bpm", an empty chart, or "0 spikes" as if they
  /// were the day's data.
  Widget _noDataFailureState() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Text(
            heartNoDataTitle,
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 4),
          Text(
            heartNoDataBody,
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _connectedBody() {
    final data = _data ?? HeartDayData.empty;
    // Juno §1/§2 derivation (BINDING conditions): a failure state
    // renders only when the selected date's load has FINISHED
    // failed (spinner cleared) — never while its load is in
    // flight. Stored data on screen → §1 stale; no stored data →
    // §2 no-data, which suppresses the data cards entirely.
    final loadFailed = !_loading && _failedDateStr == _dateStr;
    final hasData = data.hasRenderableData;
    final showNoDataFailure = loadFailed && !hasData;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) ...[
            Container(
              decoration: BoxDecoration(
                color: NotelColors.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              padding:
                  const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: NotelColors.primary,
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Updating sync data...',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          // Juno §1 — stale state above the summary card, in place
          // of the strip, stored data still on screen below it.
          if (loadFailed && hasData) ...[
            _staleDataBanner(),
            const SizedBox(height: 16),
          ],
          // Juno §2 — no-data failure state, same slot; the data
          // cards are suppressed below while this renders. The
          // error line and the wedge repair card are NOT data —
          // they are the diagnosis and the fix path — so they
          // still render in this state (below); §2 suppresses
          // only the placeholder data cards.
          if (showNoDataFailure) ...[
            _noDataFailureState(),
            const SizedBox(height: 16),
          ],
          // The read-error line renders ABOVE the summary card
          // (Heart store-first fix): it previously sat below the
          // Health Connect row, below the fold — the VC 100161
          // violation pattern. It renders in every failure state,
          // §2 included: the Juno block carries the plain-words
          // state, this line carries the specific read failure.
          if (_error != null) ...[
            Text(
              _error!,
              style: const TextStyle(color: NotelColors.error, fontSize: 12),
            ),
            const SizedBox(height: 12),
          ],
          if (showNoDataFailure && _hrWedged) ...[
            HcRepairCard(
              secondStep: _repairSecondStep,
              requesting: _repairing,
              onRepairTap:
                  _repairing ? null : () => unawaited(_onRepairTap()),
            ),
            const SizedBox(height: 16),
          ],
          if (!showNoDataFailure) ...[
            _summaryCard(data),
            // HC Grant Hardening §3.3 — the repair card sits above
            // the pattern card, visible without scrolling (the
            // Nov 20 wedge error line sat below the fold; that must
            // not recur for the wedge state).
            if (_hrWedged) ...[
              const SizedBox(height: 16),
              HcRepairCard(
                secondStep: _repairSecondStep,
                requesting: _repairing,
                onRepairTap:
                    _repairing ? null : () => unawaited(_onRepairTap()),
              ),
            ],
            const SizedBox(height: 16),
            _patternCard(data),
            const SizedBox(height: 16),
            _spikesCard(data),
            const SizedBox(height: 16),
          ],
          _healthConnectRow(),
          // Native: 72dp tail spacer above the floating nav bar; the
          // shell's dock floats too, so keep the same clearance.
          const SizedBox(height: 72),
        ],
      ),
    );
  }

  // ── 1. Summary card ─────────────────────────────────────────────────
  Widget _summaryCard(HeartDayData data) {
    return _GlassyCard(
      onTap: _showHrInfo,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.favorite,
                  color: NotelColors.primary, size: 48),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Awake average',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: data.awakeAvg != null
                              ? '${data.awakeAvg}'
                              : '--',
                          style: const TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 40,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const TextSpan(
                          text: ' bpm',
                          style: TextStyle(
                            color: NotelColors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 5, // native weight 1.0 vs 1.2
                child: _pill(
                  color: NotelColors.legacyDarkAsleepPill,
                  borderColor: NotelColors.legacyDarkAsleepPillBorder,
                  icon: Icons.nights_stay,
                  iconColor: NotelColors.legacyDarkAsleepInk,
                  text: data.asleepAvg != null
                      ? 'Asleep ${data.asleepAvg} bpm'
                      : 'Asleep -- bpm',
                  textColor: NotelColors.legacyDarkAsleepInk,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 6, // native weight 1.2 vs 1.0
                child: _pill(
                  color: NotelColors.legacyDarkLastPill,
                  borderColor: NotelColors.legacyDarkLastPillBorder,
                  icon: Icons.bar_chart,
                  iconColor: NotelColors.info,
                  text: data.latest != null
                      ? 'Last ${data.latest!.bpm} bpm · ${formatHrTime(data.latest!.timeMs)}'
                      : 'Last -- bpm',
                  textColor: NotelColors.info,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required Color color,
    required Color borderColor,
    required IconData icon,
    required Color iconColor,
    required String text,
    required Color textColor,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── 2. Today's pattern card ─────────────────────────────────────────
  Widget _patternCard(HeartDayData data) {
    return _GlassyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Today’s pattern',
                style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 6),
              // R49 HE3: 48dp hit area around the 16dp glyph
              // (was a bare 16dp target).
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showHrInfo,
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(Icons.info,
                        size: 16, color: NotelColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
          const Text(
            'Heart rate from 12 AM to 11:59 PM',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 210,
            child: CustomPaint(
              size: Size.infinite,
              painter: _HeartPatternPainter(
                // Perf package: the painter draws a bucketed
                // min/max downsample (every point a real sample,
                // the day peak preserved exactly) instead of the
                // full raw series. Cards and spike math above keep
                // the raw series — see downsampleHrForChart.
                samples: downsampleHrForChart(data.samples, 512),
                date: _selectedDate,
                use24Hour: MediaQuery.of(context).alwaysUse24HourFormat,
              ),
            ),
          ),
          // Juno §3 — stored-summary-only marker, directly under
          // the chart area: the summary above is real stored data,
          // but the chart has no intraday series to draw for this
          // day. Never shown when a series is present.
          if (data.storedSummaryOnly) ...[
            const SizedBox(height: 8),
            const Text(
              heartChartSummaryOnlyMessage,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Legend (native FlowRow, SpaceBetween).
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 16,
                    height: 3,
                    decoration: BoxDecoration(
                      color: NotelColors.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('Heart rate',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 11)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 10,
                    decoration: BoxDecoration(
                      color: NotelColors.restingSwatch,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('Resting range (45 to 70 bpm)',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 11)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: NotelColors.error,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    data.peakBpm != null
                        ? 'Peak ${data.peakBpm} bpm'
                        : 'Peak --',
                    style: const TextStyle(
                        color: NotelColors.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 3. Spikes card ──────────────────────────────────────────────────
  Widget _spikesCard(HeartDayData data) {
    final card = data.spikesCard;
    // Juno §4 all-clear gate on this card (Vera Conditions 1a/1b):
    // the count and load-level claims render ONLY when examined
    // data backs them — a non-empty valid series, or a non-null
    // stored spike count for the date (a stored 0 is recorded data
    // and may render). Every other state is an UNEXAMINED day and
    // renders no "0 significant spikes" / "Normal load" claim:
    // - a stored summary whose spike count is null (1a): the
    //   stored fields that DO exist (peak, largest jump, the
    //   minutes-over metrics below) still render; the count claim
    //   and the Total metric are suppressed, not zero-filled.
    // - a successful-but-empty read with no examined backing
    //   (1b, Juno §1b.2): the two ruled no-readings lines render in
    //   place of the count and the load level, nothing alongside.
    // - the first load still in flight with no seed painted (Juno
    //   §1b.3): no spike claims at all — the header shows only the
    //   loading spinner until the load resolves.
    final examined = data.hasExaminedSpikeData;
    final noReadings = !examined &&
        !data.storedSummaryOnly &&
        !_loading &&
        _failedDateStr != _dateStr &&
        _noReadingsDateStr == _dateStr;
    final loadLevel = card.loadLevel;
    final high = examined && loadLevel == 'High load';
    return Container(
      decoration: BoxDecoration(
        color: high ? NotelColors.errorTint : NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: high
              ? NotelColors.primary.withValues(alpha: 0.18)
              : NotelColors.cardBorder,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: NotelColors.errorTintStrong,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.whatshot,
                    color: NotelColors.error, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (noReadings) ...[
                      // Juno §1b.2 — ONLY these two lines, in place
                      // of the count and the load level.
                      const Text(
                        heartNoReadingsTitle,
                        style: TextStyle(
                          color: NotelColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        heartNoReadingsBody,
                        style: TextStyle(
                          color: NotelColors.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ] else if (examined) ...[
                      Text(
                        '${card.spikeCount} significant spikes',
                        style: const TextStyle(
                          color: NotelColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        loadLevel,
                        style: const TextStyle(
                          color: NotelColors.error,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ] else
                      // Unexamined day (null stored count, or the
                      // pending first paint): the section label
                      // only — no count, no load level, no claim.
                      Row(
                        children: [
                          const Text(
                            'Significant spikes',
                            style: TextStyle(
                              color: NotelColors.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (_loading) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: NotelColors.primary,
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
              if (examined)
                Container(
                  decoration: BoxDecoration(
                    color: NotelColors.errorTintStrong,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Text(
                    loadLevel,
                    style: const TextStyle(
                      color: NotelColors.error,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          if (examined) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _spikeMetric('Peak',
                    card.maxBpm > 0 ? '${card.maxBpm}' : '--', 'bpm',
                    color: NotelColors.error),
                _spikeMetric(
                    'Largest jump',
                    card.maxDelta > 0 ? '+${card.maxDelta}' : '--',
                    'bpm'),
                _spikeMetric('Total', '${card.spikeCount}', 'events'),
              ],
            ),
          ] else if (data.storedSummaryOnly) ...[
            // Stored-summary day with a null stored count (1a): the
            // stored peak / jump are recorded data and still
            // render; the Total metric is the count claim, so it is
            // suppressed with the count.
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _spikeMetric('Peak',
                    card.maxBpm > 0 ? '${card.maxBpm}' : '--', 'bpm',
                    color: NotelColors.error),
                _spikeMetric(
                    'Largest jump',
                    card.maxDelta > 0 ? '+${card.maxDelta}' : '--',
                    'bpm'),
              ],
            ),
          ],
          // Stored-summary-only days (Heart store-first fix): the
          // store row's remaining summary fields — minutes over
          // the thresholds and resting HR — render as metrics in
          // the same shape, from the stored values only.
          if (data.storedSummaryOnly &&
              (data.storedMinutesOver100 != null ||
                  data.storedMinutesOver120 != null ||
                  data.storedRestingHrBpm != null)) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (data.storedMinutesOver100 != null)
                  _spikeMetric(
                      'Over 100', '${data.storedMinutesOver100}', 'min'),
                if (data.storedMinutesOver120 != null)
                  _spikeMetric(
                      'Over 120', '${data.storedMinutesOver120}', 'min'),
                if (data.storedRestingHrBpm != null)
                  _spikeMetric('Resting', '${data.storedRestingHrBpm}', 'bpm'),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _GlassyButton(
            color: NotelColors.legacyDarkReviewButton,
            onTap: _openSpikeReview,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Review spikes',
                  style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(Icons.arrow_forward,
                    size: 18, color: NotelColors.textSecondary),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _spikeMetric(String label, String value, String unit,
      {Color color = NotelColors.textPrimary}) {
    return Column(
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          unit,
          style: const TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  // ── 4. Health Connect row ───────────────────────────────────────────
  Widget _healthConnectRow() {
    return _GlassyCard(
      onTap: _openConnections,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: NotelColors.legacyDarkConnectCircle,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            // Gate 10 (Vera): on iOS the row must NOT render the
            // Health Connect brand mark next to the "Apple Health"
            // title — that is a false source attribution. iOS renders
            // the row's existing heart-icon fallback instead (same
            // glyph the errorBuilder below uses, so the layout is
            // unchanged in shape); Android keeps the asset exactly.
            child: _service.isIOS
                ? const Icon(Icons.favorite,
                    color: NotelColors.primary, size: 20)
                : Image.asset(
                    'assets/images/ic_health_connect.png',
                    width: 24,
                    height: 24,
                    errorBuilder: (_, _, _) => const Icon(Icons.favorite,
                        color: NotelColors.primary, size: 20),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Juno Heart/Home addendum §2.4: the source-row
                // title is the signed row name on iOS, and the
                // logo above forks on the same signal (Gate 10).
                Text(
                  _service.isIOS ? 'Apple Health' : 'Health Connect',
                  style: const TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                Text(
                  // Floored by the capture's stamp (see
                  // _effectiveLastSyncAt): the row can no longer
                  // say "Not synced yet" over a synced store.
                  formatSyncedAgo(_effectiveLastSyncAt(), DateTime.now()),
                  style: const TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward,
              color: NotelColors.textSecondary, size: 18),
        ],
      ),
    );
  }
}

/// Native GlassyCard (LiquidGlass.kt): solid fill, radius 16, 1dp
/// primary @18% border, 16dp padding.
class _GlassyCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const _GlassyCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      padding: padding,
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: card,
      ),
    );
  }
}

/// Native GlassyButton (LiquidGlass.kt): padding h24 v12,
/// 1dp border of the container color @60%.
/// R49 HE4/HE6: radius aligned to the screen's 16dp card family
/// (was 14) and a 48dp minimum height (the Review-spikes instance
/// measured ≈44dp).
class _GlassyButton extends StatelessWidget {
  final Widget child;
  final Color color;
  final VoidCallback? onTap;

  const _GlassyButton({required this.child, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Port of native `HeartPatternGraph` (FitbitScreen.kt):
/// - plot paddings: left 36, right 16, top 24, bottom 28 (dp);
/// - y range 20–180, ticks 180/140/100/60/20, dashed grid #222F4C,
///   10sp labels;
/// - resting band 45–70 bpm: fill #1B2847 @60% (hardcoded in native —
///   NOT computed from data and NOT read from stored settings);
/// - x across the selected date 00:00 → 23:59:59, ticks at
///   0/6/12/18/24h, dashed verticals #1D2A47, labels per the device
///   12h/24h setting;
/// - the HR polyline (primary, 2.5dp, round caps/joins) drawn only
///   with ≥ 2 samples;
/// - peak marker: 5dp error circle, 2dp white center, bold 12sp error
///   value label above it.
class _HeartPatternPainter extends CustomPainter {
  final List<HrSample> samples;
  final DateTime date;
  final bool use24Hour;

  const _HeartPatternPainter({
    required this.samples,
    required this.date,
    required this.use24Hour,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 36.0;
    const rightPad = 16.0;
    const topPad = 24.0;
    const bottomPad = 28.0;
    final graphW = size.width - leftPad - rightPad;
    final graphH = size.height - topPad - bottomPad;
    const minY = 20.0;
    const maxY = 180.0;

    final dayStart = DateTime(date.year, date.month, date.day);
    final startMs = dayStart.millisecondsSinceEpoch;
    final endMs =
        dayStart.add(const Duration(hours: 23, minutes: 59, seconds: 59))
            .millisecondsSinceEpoch;

    double yToPx(double bpm) {
      final clamped = bpm.clamp(minY, maxY);
      final ratio = (clamped - minY) / (maxY - minY);
      return topPad + graphH * (1 - ratio);
    }

    double xToPx(int tMs) {
      final duration = math.max(1, endMs - startMs);
      final ratio = ((tMs - startMs) / duration).clamp(0.0, 1.0);
      return leftPad + graphW * ratio;
    }

    void drawLabel(String text, Offset topLeft,
        {double fontSize = 10,
        FontWeight weight = FontWeight.normal,
        Color color = NotelColors.textSecondary}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
              color: color, fontSize: fontSize, fontWeight: weight),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, topLeft);
    }

    Size measureLabel(String text,
        {double fontSize = 10, FontWeight weight = FontWeight.normal}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: fontSize, fontWeight: weight),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return painter.size;
    }

    void dashedHLine(double y, Color color, double dash, double gap) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1;
      var x = leftPad;
      final endX = size.width - rightPad;
      while (x < endX) {
        final segEnd = math.min(x + dash, endX);
        canvas.drawLine(Offset(x, y), Offset(segEnd, y), paint);
        x += dash + gap;
      }
    }

    void dashedVLine(double x, Color color, double dash, double gap) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1;
      var y = topPad;
      final endY = topPad + graphH;
      while (y < endY) {
        final segEnd = math.min(y + dash, endY);
        canvas.drawLine(Offset(x, y), Offset(x, segEnd), paint);
        y += dash + gap;
      }
    }

    // 1. Y grid + labels.
    for (final tick in [180, 140, 100, 60, 20]) {
      final y = yToPx(tick.toDouble());
      dashedHLine(y, NotelColors.heartChartGridY, 6, 6);
      final labelSize = measureLabel('$tick');
      drawLabel('$tick',
          Offset(leftPad - labelSize.width - 8, y - labelSize.height / 2));
    }

    // 2. Resting band 45–70.
    final bandTop = yToPx(70);
    final bandBottom = yToPx(45);
    canvas.drawRect(
      Rect.fromLTWH(leftPad, bandTop, graphW, bandBottom - bandTop),
      Paint()..color = NotelColors.restingBand.withValues(alpha: 0.6),
    );

    // 3. X grid + labels at 0/6/12/18/24h.
    for (final hr in [0, 6, 12, 18, 24]) {
      final tickMs = dayStart.add(Duration(hours: hr)).millisecondsSinceEpoch;
      final x = xToPx(tickMs);
      dashedVLine(x, NotelColors.heartChartGridX, 4, 4);
      final String label;
      if (use24Hour) {
        label = hr == 24
            ? '00:00'
            : '${hr.toString().padLeft(2, '0')}:00';
      } else {
        label = switch (hr) {
          0 || 24 => '12 AM',
          12 => '12 PM',
          > 12 => '${hr - 12} PM',
          _ => '$hr AM',
        };
      }
      final labelSize = measureLabel(label, weight: FontWeight.w500);
      final clampedX = (x - labelSize.width / 2)
          .clamp(leftPad, size.width - rightPad - labelSize.width);
      drawLabel(label, Offset(clampedX, size.height - bottomPad + 6),
          weight: FontWeight.w500);
    }

    // 4. HR polyline (≥ 2 samples, native rule). Samples are already
    // valid-filtered (bpm > 0) by HeartDayData.
    if (samples.length >= 2) {
      final path = Path();
      for (var i = 0; i < samples.length; i++) {
        final x = xToPx(samples[i].timeMs);
        final y = yToPx(samples[i].bpm.toDouble());
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = NotelColors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // 5. Peak marker + value.
    HrSample? peak;
    for (final s in samples) {
      if (peak == null || s.bpm > peak.bpm) peak = s;
    }
    if (peak != null && peak.bpm > 0) {
      final px = xToPx(peak.timeMs);
      final py = yToPx(peak.bpm.toDouble());
      canvas.drawCircle(Offset(px, py), 5, Paint()..color = NotelColors.error);
      canvas.drawCircle(Offset(px, py), 2, Paint()..color = Colors.white);
      final label = '${peak.bpm}';
      final labelSize =
          measureLabel(label, fontSize: 12, weight: FontWeight.bold);
      final clampedX = (px - labelSize.width / 2)
          .clamp(leftPad, size.width - rightPad - labelSize.width);
      drawLabel(label, Offset(clampedX, py - labelSize.height - 6),
          fontSize: 12, weight: FontWeight.bold, color: NotelColors.error);
    }
  }

  @override
  bool shouldRepaint(covariant _HeartPatternPainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.date != date ||
      oldDelegate.use24Hour != use24Hour;
}
