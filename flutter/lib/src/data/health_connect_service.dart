import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/health_data.dart';

/// Round 12 — Health Connect service.
///
/// Standalone, onboarding-ready API with NO screen-specific coupling: both
/// the connections screen and the future onboarding connections step use
/// this same service. State is shared through persisted storage, so a
/// connection made in onboarding is already reflected here (and vice versa).
///
/// - [getStatus]: availability + live granted-permission check.
/// - [isConnected]: true when every required permission is granted.
/// - [requestPermissions]: launches the full Health Connect permission flow;
///   persists the granted set + timestamp on success.
/// - [disconnect]: Dart-side deactivation (clears persisted state; system
///   permissions can only be revoked in Health Connect settings, matching
///   the native app's behavior).
/// - [hasPersistedConnection]: fast storage-only read for first paint.
///
/// Scope: connection + permissions ONLY. No health data is read here.
class HealthConnectService {
  static const String channelName =
      'com.notel.notel.playground.flutter/health_connect';

  /// Must stay in sync with MainActivity.hcPermissions (Kotlin):
  /// the 14 record-type reads + history. Never includes background access.
  static const Set<String> requiredPermissions = {
    'android.permission.health.READ_HEART_RATE',
    'android.permission.health.READ_SLEEP',
    'android.permission.health.READ_STEPS',
    'android.permission.health.READ_ACTIVE_CALORIES_BURNED',
    'android.permission.health.READ_TOTAL_CALORIES_BURNED',
    'android.permission.health.READ_BASAL_METABOLIC_RATE',
    'android.permission.health.READ_WEIGHT',
    'android.permission.health.READ_HEIGHT',
    'android.permission.health.READ_HEART_RATE_VARIABILITY',
    'android.permission.health.READ_RESPIRATORY_RATE',
    'android.permission.health.READ_OXYGEN_SATURATION',
    'android.permission.health.READ_RESTING_HEART_RATE',
    'android.permission.health.READ_POWER',
    'android.permission.health.READ_BLOOD_PRESSURE',
    'android.permission.health.READ_HEALTH_DATA_HISTORY',
  };

  /// Plain-language label for every required permission (HRV grant
  /// visibility fix): a partial grant must be able to NAME the data
  /// type that is not shared, in words the founder recognizes —
  /// never the raw `android.permission.health.*` string.
  static const Map<String, String> permissionLabels = {
    'android.permission.health.READ_HEART_RATE': 'Heart rate',
    'android.permission.health.READ_SLEEP': 'Sleep',
    'android.permission.health.READ_STEPS': 'Steps',
    'android.permission.health.READ_ACTIVE_CALORIES_BURNED':
        'Active calories burned',
    'android.permission.health.READ_TOTAL_CALORIES_BURNED':
        'Total calories burned',
    'android.permission.health.READ_BASAL_METABOLIC_RATE':
        'Basal metabolic rate',
    'android.permission.health.READ_WEIGHT': 'Weight',
    'android.permission.health.READ_HEIGHT': 'Height',
    'android.permission.health.READ_HEART_RATE_VARIABILITY':
        'Heart rate variability',
    'android.permission.health.READ_RESPIRATORY_RATE': 'Respiratory rate',
    'android.permission.health.READ_OXYGEN_SATURATION': 'Oxygen saturation',
    'android.permission.health.READ_RESTING_HEART_RATE':
        'Resting heart rate',
    'android.permission.health.READ_POWER': 'Power',
    'android.permission.health.READ_BLOOD_PRESSURE': 'Blood pressure',
    'android.permission.health.READ_HEALTH_DATA_HISTORY':
        'Health data history',
  };

  /// The plain-language label for one permission; an unrecognized
  /// permission falls back to its raw name (visible, never silent).
  static String permissionLabel(String permission) =>
      permissionLabels[permission] ?? permission;

  /// The required permissions NOT in [granted] — the missing set
  /// behind a `partiallyConnected` status.
  static Set<String> missingPermissions(Set<String> granted) =>
      requiredPermissions.difference(granted);

  /// The missing permissions' plain-language labels, in
  /// [requiredPermissions] order (deterministic for display).
  static List<String> missingPermissionLabels(Set<String> granted) => [
        for (final p in requiredPermissions)
          if (!granted.contains(p)) permissionLabel(p),
      ];

  /// The partial-grant copy for the Connected Apps / Data
  /// Connections surfaces (HRV grant visibility fix), following
  /// the [staleGrantMessage] pattern: plain language naming what
  /// is missing and the exact remedy, no codes. One shared builder
  /// so every surface words it identically.
  static String missingPermissionsMessage(List<String> labels) {
    final names = labels.join(', ');
    return 'Some health data is not shared: $names. To fix it, '
        'open Health Connect, tap App permissions, tap Tabs, '
        'and turn on $names.';
  }

  static const String _kGrantedKey = 'hc_granted_permissions';
  static const String _kConnectedAtKey = 'hc_connected_at';

  /// Native allows up to 5 minutes in the HC UI; Dart gives up just before
  /// so it can cancel the native pending request and stay retryable.
  static const Duration requestTimeout = Duration(minutes: 4, seconds: 30);

  /// HC read hardening — the bound callers wrap bridge reads with
  /// (founder defect #3: the HR read had no timeout anywhere and
  /// wedged the Heart screen's "Updating sync data..." strip
  /// forever). The bound lives at the CALLER, matching the codebase's
  /// established guard pattern (Sleep screen `_guarded`): the Heart
  /// screen wraps its HR read with this duration and surfaces
  /// READ_TIMEOUT on expiry. It is deliberately NOT a
  /// `Future.timeout` inside this service: dozens of widget tests
  /// drive screens through subclass fakes / unmocked channels whose
  /// futures legitimately pend, and a service-owned timer on every
  /// call fails those suites' teardown — while a caller-side guard
  /// resolves during the screen's own loading lifecycle.
  static const Duration readTimeout = Duration(seconds: 30);

  /// Error code thrown when Health Connect reports every required
  /// permission granted but a real read probe is blocked with a
  /// SecurityException — the stale/wedged grant state seen after an
  /// app update or reinstall, where the package previously belonged
  /// to another build. Grants report OK; reads throw.
  static const String staleGrantCode = 'STALE_GRANT';

  /// Plain-language recovery directions for [staleGrantCode]. No
  /// stack traces, no exception text — Juno-reviewed wording: it
  /// tells the user exactly how to clear the stale grant. The app
  /// never revokes access or opens settings on the user's behalf;
  /// removing the app inside Health Connect is the user's tap.
  static const String staleGrantMessage =
      'Tabs is disconnected from Health Connect. Health Connect lists '
      'Tabs as having permission, but a test read was blocked. This '
      'sometimes happens after an app update or reinstall. To fix it, '
      'open Health Connect, tap App permissions, tap Tabs, then tap '
      'Remove access. Return here and connect again.';

  final MethodChannel _channel;
  final SecureStore _store;

  /// Probe bound for this instance — [readTimeout] in production;
  /// tests inject a short override so a wedged-probe test does not
  /// wait 30 real seconds. Only the probe is timed inside the
  /// service (Vera F1); data reads are bounded by their callers.
  final Duration _probeTimeout;

  HealthConnectService(
      {MethodChannel? channel, SecureStore? store, Duration? probeTimeoutOverride})
      : _channel = channel ?? const MethodChannel(channelName),
        _store = store ?? const FlutterSecureStore(),
        _probeTimeout = probeTimeoutOverride ?? readTimeout;

  /// True when Health Connect is installed and available on this device.
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ??
          false;
    } on PlatformException catch (e) {
      throw HealthConnectException(e.code, e.message ?? 'Availability check failed.');
    } on MissingPluginException {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
  }

  /// The permissions currently granted to this app (empty when HC is
  /// unavailable or nothing was granted).
  Future<Set<String>> getGrantedPermissions() async {
    try {
      final granted = await _channel
          .invokeMethod<List>('getGrantedPermissions')
          ;
      return (granted ?? []).map((e) => e.toString()).toSet();
    } on PlatformException catch (e) {
      throw HealthConnectException(e.code, e.message ?? 'Could not read granted permissions.');
    } on MissingPluginException {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
  }

  /// The background-read permission (founder amendment #2, Oct 20,
  /// 2026). DECLARED in the manifest so Health Connect can grant it,
  /// but NEVER part of [requiredPermissions] and never in the
  /// runtime request set: it is a Dart-side gate, granted by the
  /// user inside Health Connect settings (app permissions →
  /// additional access). Background scoring checks it via
  /// [hasBackgroundAccess] and stays silently off without it.
  static const String backgroundPermission =
      'android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND';

  /// Whether the background-read grant is present in the live
  /// granted set. Throws [HealthConnectException] when the bridge
  /// read fails — background callers treat a failure as "unknown",
  /// never as granted.
  Future<bool> hasBackgroundAccess() async =>
      (await getGrantedPermissions()).contains(backgroundPermission);

  /// Report Reliability Phase 2 (§2) — the unified availability
  /// snapshot. NEVER throws and NEVER persists anything: every
  /// bridge failure is captured in the snapshot ([HcAvailability]
  /// .bridgeErrorCode, with the grant layer UNKNOWN) instead of
  /// propagating. A KNOWN state — including the stale/wedged
  /// state, which arrives as DATA ([HcAvailability.staleWedged]),
  /// not as an exception or a special case — is authoritative and
  /// is never overridden by the persisted flag; the persisted flag
  /// rides along as a first-paint hint only.
  ///
  /// The grant layer is read through [getMissingPermissions] (the
  /// live granted set's complement), so the granted set in the
  /// snapshot is `required − missing` — the same bridge read the
  /// legacy status path always made.
  Future<HcAvailability> probeAvailability() =>
      _probeAvailability(readPersisted: true);

  /// The probe core. [readPersisted] controls only the
  /// first-paint hint: [getStatus] runs the same probe WITHOUT
  /// the storage read, because its legacy contract is exactly the
  /// bridge-call sequence it has always made (availability,
  /// grants, steps probe) — an extra awaited storage read on
  /// that path is an observable behavior change for its
  /// un-migrated consumers.
  ///
  /// [stopOnAvailabilityError] is [getStatus]'s half of the same
  /// legacy contract (Vera Item 3): base `getStatus()` called
  /// `isAvailable()` FIRST and propagated its throw, so the grant
  /// layer was never consulted on an availability failure. The
  /// public probe passes false and keeps reading the grant layer
  /// for its snapshot; [getStatus] passes true and rethrows the
  /// recorded availability failure from the short-circuited
  /// snapshot before any grant-derived return or persist.
  Future<HcAvailability> _probeAvailability(
      {required bool readPersisted,
      bool stopOnAvailabilityError = false}) async {
    var persisted = false;
    if (readPersisted) {
      try {
        persisted = await hasPersistedConnection();
      } catch (_) {
        // A storage failure is not availability evidence.
        persisted = false;
      }
    }
    String? bridgeErrorCode;
    HealthConnectException? availabilityError;
    HealthConnectException? grantError;
    bool? available;
    try {
      available = await isAvailable();
    } catch (e) {
      availabilityError = e is HealthConnectException
          ? e
          : HealthConnectException('UNKNOWN', e.toString());
      bridgeErrorCode = availabilityError.code;
      available = null;
    }
    if (available == false) {
      return HcAvailability(
        serviceAvailable: false,
        grantedPermissions: null,
        bridgeErrorCode: bridgeErrorCode,
        availabilityError: availabilityError,
        grantError: grantError,
        stepsProbe: null,
        persistedConnected: persisted,
      );
    }
    if (available == null && stopOnAvailabilityError) {
      // Availability errored and the caller is getStatus():
      // short-circuit with the failure recorded — the grant
      // layer stays unread, exactly as base's throw left it.
      return HcAvailability(
        serviceAvailable: false,
        grantedPermissions: null,
        bridgeErrorCode: bridgeErrorCode,
        availabilityError: availabilityError,
        grantError: grantError,
        stepsProbe: null,
        persistedConnected: persisted,
      );
    }
    Set<String>? granted;
    try {
      final missing = await getMissingPermissions();
      granted = requiredPermissions.difference(missing);
    } catch (e) {
      grantError = e is HealthConnectException
          ? e
          : HealthConnectException('UNKNOWN', e.toString());
      bridgeErrorCode ??= grantError.code;
      granted = null;
    }
    // The Steps read probe runs ONLY on a full grant (the legacy
    // getStatus rule): it is the stale/wedged evidence, and on a
    // partial or absent grant it could prove nothing.
    HcReadProbeOutcome? stepsProbe;
    if (granted != null && granted.containsAll(requiredPermissions)) {
      stepsProbe = await probeReadAccess();
    }
    return HcAvailability(
      serviceAvailable: available ?? false,
      grantedPermissions: granted,
      bridgeErrorCode: bridgeErrorCode,
      availabilityError: availabilityError,
      grantError: grantError,
      stepsProbe: stepsProbe,
      persistedConnected: persisted,
    );
  }

  /// Live status: availability + granted-set check. Persists the granted
  /// set when everything required is granted.
  ///
  /// Phase 2: re-implemented OVER [probeAvailability] with the
  /// EXACT legacy contract preserved for un-migrated consumers
  /// (onboarding, background): a bridge failure propagates
  /// EXACTLY as the legacy direct calls threw it — the recorded
  /// availability failure first (code AND native message, before
  /// any grant-derived return or persist; the grant layer is not
  /// even read, per [stopOnAvailabilityError]), then the recorded
  /// grant failure (again code AND native message, nothing
  /// persisted); a stale/wedged full grant throws
  /// [staleGrantCode] and persists NOTHING (Juno J3); a full
  /// healthy grant persists the granted set before returning
  /// [HealthConnectStatus.connected].
  Future<HealthConnectStatus> getStatus() async {
    final snapshot = await _probeAvailability(
        readPersisted: false, stopOnAvailabilityError: true);
    // Vera Item 3 parity: base getStatus() threw the isAvailable()
    // failure before touching the grant layer, and the
    // getGrantedPermissions() failure in place of any status.
    // The probe recorded both failures verbatim (the actual
    // HealthConnectException each bridge call threw); rethrow
    // them in base's order, before deriving or persisting
    // anything.
    final availabilityError = snapshot.availabilityError;
    if (availabilityError != null) throw availabilityError;
    final grantError = snapshot.grantError;
    if (grantError != null) throw grantError;
    final status = snapshot.status;
    if (status == null) {
      throw HealthConnectException(
          snapshot.bridgeErrorCode ?? 'NO_CHANNEL',
          'Health Connect status check failed.');
    }
    if (snapshot.staleWedged) {
      throw const HealthConnectException(
          staleGrantCode, staleGrantMessage);
    }
    if (status == HealthConnectStatus.connected) {
      await _persist(snapshot.grantedPermissions!);
    }
    return status;
  }

  /// The required permissions not currently granted (live bridge
  /// read, like [getGrantedPermissions]). Empty when fully granted.
  /// Throws [HealthConnectException] when the bridge read fails —
  /// callers surface it visibly, never swallow it.
  Future<Set<String>> getMissingPermissions() async =>
      missingPermissions(await getGrantedPermissions());

  /// Plain-language labels for [getMissingPermissions] — the names
  /// a partial-grant message shows.
  Future<List<String>> getMissingPermissionLabels() async =>
      missingPermissionLabels(await getGrantedPermissions());

  /// True when every required permission is currently granted.
  Future<bool> isConnected() async =>
      await getStatus() == HealthConnectStatus.connected;

  /// Fast storage-only read — for first paint before the live check lands.
  /// Shared with onboarding: a connection persisted there reads true here.
  Future<bool> hasPersistedConnection() async {
    final raw = await _store.read(_kGrantedKey);
    if (raw == null || raw.isEmpty) return false;
    final persisted = raw.split(',').toSet();
    return persisted.containsAll(requiredPermissions);
  }

  /// Launches the Health Connect permission UI. Returns the granted set
  /// (possibly partial or empty if the user declined). Throws
  /// [HealthConnectException] with a visible code on failure/timeout.
  /// Safe to call from the connections screen OR onboarding — no UI coupling.
  Future<Set<String>> requestPermissions() async {
    try {
      final granted = await _channel
          .invokeMethod<List>('requestPermissions')
          .timeout(requestTimeout);
      final set = (granted ?? []).map((e) => e.toString()).toSet();
      if (set.containsAll(requiredPermissions)) {
        // Grant-state probe: grants reporting OK is not proof reads
        // work (stale grant after update/reinstall — reads throw
        // SecurityException while the grant list looks complete).
        // Verify with one lightweight REAL read before persisting
        // the connection, so a blocked grant is never stored as a
        // healthy "connected" state.
        final probe = await probeReadAccess();
        if (probe == HcReadProbeOutcome.securityFailure) {
          throw const HealthConnectException(
              staleGrantCode, staleGrantMessage);
        }
      }
      await _persist(set);
      return set;
    } on TimeoutException {
      // Keep native + Dart in sync so a retry is never wedged.
      try {
        await _channel.invokeMethod('cancelRequest');
      } catch (_) {}
      throw const HealthConnectException('REQUEST_TIMEOUT',
          'The permission request timed out. Please try again.');
    } on PlatformException catch (e) {
      throw HealthConnectException(
          e.code, e.message ?? 'Permission request failed.');
    } on MissingPluginException {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
  }

  /// Details of the most recent probe failure (exception class only — never health values), for diagnostics.
  String? lastProbeErrorDetails;

  /// Lightweight REAL read probe over the bridge (Kotlin
  /// `probeReadAccess`: one tiny record-path StepsRecord read, first
  /// page only, results discarded). Distinguishes a working
  /// connection from a stale grant: when Health Connect reports
  /// every permission granted but the probe is blocked with a
  /// SecurityException, the grant is wedged and only removing +
  /// re-granting the app inside Health Connect settings clears it.
  /// A successful probe means THIS record read worked — it is not
  /// proof every read works.
  ///
  /// NEVER throws — an unexpected probe failure is a soft [failed]
  /// outcome, not a blocked connection.
  Future<HcReadProbeOutcome> probeReadAccess() async {
    try {
      // Internally timeout-bounded (Vera F1): every caller
      // (requestPermissions, getStatus) inherits the bound, so a
      // wedged probe can never wedge the permission flow. Expiry is
      // a SOFT timedOut — never a stale-grant verdict.
      await _channel
          .invokeMethod<bool>('probeReadAccess')
          .timeout(_probeTimeout);
      lastProbeErrorDetails = null;
      return HcReadProbeOutcome.ok;
    } on TimeoutException {
      lastProbeErrorDetails = 'Probe read timed out.';
      return HcReadProbeOutcome.timedOut;
    } on PlatformException catch (e) {
      final details = _detailsOf(e);
      lastProbeErrorDetails = details ?? e.code;
      return (details != null && details.contains('SecurityException'))
          ? HcReadProbeOutcome.securityFailure
          : HcReadProbeOutcome.failed;
    } catch (_) {
      // MissingPluginException and anything unexpected: the probe
      // could not run — never a stale-grant verdict on its own.
      lastProbeErrorDetails = 'Probe read could not run.';
      return HcReadProbeOutcome.failed;
    }
  }

  /// Dart-side deactivation: clears persisted state. System permissions can
  /// only be revoked in Health Connect settings (same as the native app).
  ///
  /// HC connection-honesty package: no in-app control calls this any
  /// more — the Connections sheet's "Deactivate in Tabs" control was
  /// removed (Juno ruling #8) because clearing these two keys never
  /// stopped any read and the status re-verified straight back to
  /// "Connected". The method is retained as the service's
  /// persisted-state clear and is exercised directly by a test of
  /// record (health_connect_test.dart, "disconnect clears persisted
  /// state"); the keys it clears are still written by [_persist] and
  /// read by [hasPersistedConnection].
  Future<void> disconnect() async {
    await _store.delete(_kGrantedKey);
    await _store.delete(_kConnectedAtKey);
  }

  /// Opens the Health Connect system settings screen.
  Future<void> openHealthConnectSettings() async {
    try {
      await _channel.invokeMethod('openHealthConnectSettings');
    } on PlatformException catch (e) {
      throw HealthConnectException(
          e.code, e.message ?? 'Could not open Health Connect settings.');
    } on MissingPluginException {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
  }

  // ── Round 13: thin typed reads over the same channel ────────────────────
  //
  // Kotlin side (MainActivity.kt) ports the native
  // `HealthConnectManager.kt` query patterns: mock records (priority
  // ≤ -100) are dropped natively, pagination is handled natively, and no
  // health values are logged there.
  //
  // Each method returns null (or an empty list) on PlatformException /
  // MissingPluginException — the UI's "--"/empty states are the visible,
  // honest outcome. The failing exception's code is kept in
  // [lastReadErrorCode] and the native exception class only in
  // [lastReadErrorDetails] (Kotlin passes them through the channel
  // error details — instrument, don't swallow), so a screenshot of
  // the surfaced error identifies the real failure. Health VALUES
  // are never logged or retained beyond the returned objects.
  //
  // HC read hardening: reads record their failures here instead of
  // swallowing them; callers bound the wait with [readTimeout] (see
  // its doc) so a wedged bridge call surfaces as READ_TIMEOUT at the
  // screen instead of a permanent spinner.
  String? lastReadErrorCode;
  String? lastReadErrorDetails;

  /// Code of the most recent PARTIAL read (`HR_SAMPLES_PARTIAL` /
  /// `SLEEP_HISTORY_PARTIAL`): the read returned real data with some
  /// chunks missing. Kept separate from [lastReadErrorCode] so
  /// failure checks never discard partial data as an outage (F2).
  String? lastPartialErrorCode;

  void _noteReadError(String code, [String? details]) {
    lastReadErrorCode = code;
    lastReadErrorDetails = details;
  }

  // ── Phase 2 (§1): outcome-carrying reads ─────────────────────
  //
  // Each of the five history reads has ONE implementation (its
  // `_...Core` method below), which returns an [HcReadOutcome]
  // carrying the read's OWN failure/partial signals alongside its
  // fail-closed value — errors travel with their own read's
  // result, so concurrent readers on one shared instance cannot
  // cross-talk attribution through the legacy slot fields. The
  // core still writes the legacy slot fields as a best-effort
  // diagnostic side channel for the screens that display a read
  // error immediately after their own read (Heart, Sleep, Key
  // Metrics, HealthRepository diagnostics) — but no availability
  // attribution reads the slots. (The capture path claimed from
  // the slots under its legacy protocol until PR-3 migrated it
  // to the outcome objects, health_history_sync.dart.)
  //
  // The public legacy method delegates to the outcome variant and
  // returns `.value`, byte-identical to the pre-Phase-2 returns.
  //
  // [_outcomeOf] is the delegation bridge: the legacy method calls
  // the outcome variant, whose outer frame re-enters the legacy
  // method inside a Zone carrying a per-call capture box. When
  // the re-entered call is THIS class's legacy method, it
  // delegates back into the outcome variant, the Zone marks that
  // inner frame, and the inner frame runs the core and stashes
  // its outcome in the box — the outer frame returns the stashed
  // outcome untouched (never reconstructed from the shared
  // slots), so concurrent outcome reads attribute EXACTLY. When
  // a subclass overrides the legacy method instead (the existing
  // test fakes), the box stays empty and the outcome is
  // reconstructed from the slot fields the override set — since
  // VC 100133 (Phase 5 parallel union reads) that reconstruction
  // runs under a per-instance gate until the read's box shape
  // is proven (see [_outcomeOf]), because the shared slots
  // cannot attribute concurrent reads; the union's loaders
  // claim ONLY from outcome objects after this change.
  static final Object _restingHrOutcomeZoneKey = Object();
  static final Object _sleepOutcomeZoneKey = Object();
  static final Object _hrvOutcomeZoneKey = Object();
  static final Object _caloriesOutcomeZoneKey = Object();
  static final Object _spikesOutcomeZoneKey = Object();

  /// VC 100133 (Phase 5 follow-up) — the gate serializing
  /// UNPROVEN reads in [_outcomeOf] (see there). Chained-future
  /// mutex: each holder appends its gate to the chain and runs
  /// when the previous gate completes. A read whose Zone-box
  /// shape is proven never waits on it.
  Future<void> _slotGate = Future<void>.value();

  Future<HcReadOutcome<T>> _withSlotGate<T>(
      Future<HcReadOutcome<T>> Function() body) {
    final previous = _slotGate;
    final gate = Completer<void>();
    _slotGate = gate.future;
    return previous.then((_) => body()).whenComplete(gate.complete);
  }

  /// Zone keys (one per read) whose outcome is KNOWN to arrive
  /// through the per-call Zone box on this instance — i.e. the
  /// legacy method is this class's own delegation, not a
  /// subclass override reporting through the shared slots.
  /// Proven once, on the read's first (gated) run; see
  /// [_outcomeOf].
  final Set<Object> _boxProvenReads = <Object>{};

  Future<HcReadOutcome<T>> _outcomeOf<T>(
    Object zoneKey,
    Future<T> Function() virtualRead,
    Future<HcReadOutcome<T>> Function() coreRead,
  ) async {
    final box = Zone.current[zoneKey];
    if (box is List<HcReadOutcome<T>>) {
      // Inner frame (reached via this class's legacy delegation):
      // run the single implementation and hand its outcome to the
      // outer frame through the per-call box. The diagnostic slots
      // are cleared HERE (VC 100133: the outer frame clears them
      // only on its gated path — see below), preserving the slot
      // lifecycle the screens rely on: cleared at read start,
      // set by the core on failure, untouched by a successful
      // core.
      lastReadErrorCode = null;
      lastReadErrorDetails = null;
      lastPartialErrorCode = null;
      final outcome = await coreRead();
      box.add(outcome);
      return outcome;
    }
    if (_boxProvenReads.contains(zoneKey)) {
      // Proven box shape: attribution rides the per-call box and
      // never touches the shared slots, so this read runs at
      // full concurrency with no gate and no slot clearing.
      final capture = <HcReadOutcome<T>>[];
      final value = await runZoned<Future<T>>(
        () => virtualRead(),
        zoneValues: {zoneKey: capture},
      );
      if (capture.isNotEmpty) return capture.single;
      // Defensive: a proven read whose delegation is somehow
      // conditional left the box empty — fall back to the slot
      // reconstruction rather than throwing.
      return HcReadOutcome<T>(
        value: value,
        errorCode: lastReadErrorCode,
        errorDetails: lastReadErrorDetails,
        partialCode: lastPartialErrorCode,
      );
    }
    // Unproven shape: run under the gate — clear → read →
    // claim, atomically with respect to every other unproven
    // read on this instance. Before VC 100133 the outer frame
    // did exactly this WITHOUT a gate, which was sound only
    // while outcome reads on one instance ran sequentially
    // (the union's loaders did); Phase 5 runs the union's five
    // reads concurrently, and for a subclass override — which
    // reports through the shared slot fields — concurrent
    // frames clear and write the slots under each other, so a
    // reconstruction could claim a NEIGHBOUR read's signals
    // (cross-attribution: a metric marked failed/partial by
    // another metric's slot writes). The gate restores the
    // sequential soundness for that shape with each read issued
    // exactly once. If this run's outcome arrives through the
    // box (this class's own legacy delegation), the read is
    // marked proven and every later run takes the ungated path
    // above — so the production service pays the gate only for
    // the first read of each metric per instance, and override
    // subclasses (today: test fakes only; no production code
    // overrides the legacy reads) stay serialized, as their
    // slot contract requires. Residual, documented: a proven
    // core's diagnostic slot writes can still land inside an
    // unproven read's gated window on a MIXED instance (some
    // reads overridden, some not) — the slots are a diagnostic
    // side channel, and attribution for proven reads never
    // reads them.
    return _withSlotGate(() async {
      // Re-check inside the gate: a queued same-metric read may
      // have proven the shape while this frame waited.
      if (_boxProvenReads.contains(zoneKey)) {
        final capture = <HcReadOutcome<T>>[];
        final value = await runZoned<Future<T>>(
          () => virtualRead(),
          zoneValues: {zoneKey: capture},
        );
        if (capture.isNotEmpty) return capture.single;
        return HcReadOutcome<T>(
          value: value,
          errorCode: lastReadErrorCode,
          errorDetails: lastReadErrorDetails,
          partialCode: lastPartialErrorCode,
        );
      }
      // Slot reconstruction (the subclass-override path) must
      // see ONLY this read's signals: clear the diagnostic
      // slots before the read, exactly as the union's deleted
      // entry drain did.
      lastReadErrorCode = null;
      lastReadErrorDetails = null;
      lastPartialErrorCode = null;
      final capture = <HcReadOutcome<T>>[];
      final value = await runZoned<Future<T>>(
        () => virtualRead(),
        zoneValues: {zoneKey: capture},
      );
      if (capture.isNotEmpty) {
        _boxProvenReads.add(zoneKey);
        return capture.single;
      }
      return HcReadOutcome<T>(
        value: value,
        errorCode: lastReadErrorCode,
        errorDetails: lastReadErrorDetails,
        partialCode: lastPartialErrorCode,
      );
    });
  }

  void _notePlatformError(PlatformException e) =>
      _noteReadError(e.code, _detailsOf(e));

  /// The exception info Kotlin attached to a channel error: the
  /// details slot carries the exception CLASS ONLY (Juno J1 — raw
  /// exception messages never reach the UI). Returns the details
  /// string, or null when no details crossed; there is deliberately
  /// NO fallback to the raw error message.
  static String? _detailsOf(PlatformException e) {
    final d = e.details;
    if (d is String && d.isNotEmpty) return d;
    return null;
  }

  /// Raw intraday HR samples `[{t: epochMs, bpm}]`, distinct by time,
  /// sorted ascending. Empty when unreadable.
  ///
  /// Kotlin reads the day in 6-hour chunks: when some chunks fail,
  /// the bridge returns `{samples: [...], partialError: "<details>"}`
  /// instead of a bare list — the samples that DID read are returned
  /// and the partial failure is recorded in [lastPartialErrorCode]
  /// (code `HR_SAMPLES_PARTIAL`, details in [lastReadErrorDetails])
  /// so the UI can show both the partial data and the warning.
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('readHeartRateSamples', {'dateStr': dateStr})
          ;
      List<dynamic> items = const [];
      if (raw is List) {
        items = raw;
      } else if (raw is Map) {
        final s = raw['samples'];
        if (s is List) items = s;
        final partial = raw['partialError'];
        if (partial is String && partial.isNotEmpty) {
          // Partial is NOT a failure (Vera F2): it gets its own
          // field so union/callers never mistake partial data for
          // an outage. Details stay available for the UI warning.
          lastPartialErrorCode = 'HR_SAMPLES_PARTIAL';
          lastReadErrorDetails = partial;
        }
      }
      final out = <HrSample>[];
      for (final item in items) {
        if (item is Map) {
          final t = item['t'];
          final bpm = item['bpm'];
          if (t is num && bpm is num) {
            out.add(HrSample(timeMs: t.toInt(), bpm: bpm.toInt()));
          }
        }
      }
      return out;
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return const [];
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return const [];
    }
  }

  /// Active calories (kcal) for the day — `active ?: total`, native rule.
  /// Null when unavailable.
  Future<int?> readActiveCalories(String dateStr) =>
      _readInt('readActiveCalories', {'dateStr': dateStr});

  /// Sleep minutes for the day (duration − merged awake stages).
  /// Null when no session.
  Future<int?> readSleepMinutes(String dateStr) =>
      _readInt('readSleepMinutes', {'dateStr': dateStr});

  /// Round 18b — per-stage sleep breakdown for the Sleep Profile screen.
  /// Null when no session. Zero stage values are possible from the
  /// bridge (a stage with no intervals); the UI treats them as missing
  /// per the founder's biometric rule, same as elsewhere.
  Future<SleepStages?> readSleepStages(String dateStr) async {
    try {
      final raw = await _channel
          .invokeMethod<Map>('readSleepStages', {'dateStr': dateStr})
          ;
      if (raw == null) return null;
      int? asInt(dynamic v) {
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
        return null;
      }

      return SleepStages(
        minutesAsleep: asInt(raw['minutesAsleep']),
        deepMinutes: asInt(raw['deepMinutes']),
        lightMinutes: asInt(raw['lightMinutes']),
        remMinutes: asInt(raw['remMinutes']),
        efficiency: asInt(raw['efficiency']),
      );
    } on PlatformException catch (e) {
      // Was catch-all swallow: a failed sleep read looked identical
      // to "no session" and the Sleep Profile rendered blank with no
      // diagnosable error. Now the failure is recorded like every
      // other read (the null return contract is unchanged).
      _notePlatformError(e);
      return null;
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return null;
    }
  }

  /// Resting heart rate (bpm): non-mock records, highest package priority,
  /// latest by time. Null when none.
  Future<int?> readRestingHeartRate(String dateStr) =>
      _readInt('readRestingHeartRate', {'dateStr': dateStr});

  /// Steps for the day. Null when unavailable.
  Future<int?> readSteps(String dateStr) =>
      _readInt('readSteps', {'dateStr': dateStr});

  /// Per-day resting HR history `[{date: "YYYY-MM-DD", bpm}]` over
  /// `[now - days, tomorrow start)`; per-day aggregate BPM_AVG fallback
  /// when a day has no RestingHeartRateRecord (native rule).
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async =>
      (await readRestingHrHistoryWithOutcome(days)).value;

  /// Outcome-carrying variant of [readRestingHrHistory] (Phase 2
  /// §1): the single implementation is [_readRestingHrHistoryCore];
  /// this variant returns its outcome object.
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) => _outcomeOf(
            _restingHrOutcomeZoneKey,
            () => readRestingHrHistory(days),
            () => _readRestingHrHistoryCore(days),
          );

  Future<HcReadOutcome<List<({String date, int bpm})>>>
      _readRestingHrHistoryCore(int days) async {
    try {
      final raw = await _channel
          .invokeMethod<List>('readRestingHrHistory', {'days': days});
      final out = <({String date, int bpm})>[];
      for (final item in raw ?? const []) {
        if (item is Map) {
          final d = item['date'];
          final v = item['bpm'];
          if (d is String && v is num) out.add((date: d, bpm: v.toInt()));
        }
      }
      return HcReadOutcome(value: out);
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return HcReadOutcome(
          value: const [], errorCode: e.code, errorDetails: _detailsOf(e));
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return HcReadOutcome(value: const [], errorCode: 'NO_CHANNEL');
    }
  }

  /// Per-day active calories `[{date: "YYYY-MM-DD", kcal}]`, `active ?:
  /// total` per day (native rule). Empty when unreadable.
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async =>
      (await readCaloriesHistoryWithOutcome(days)).value;

  /// Outcome-carrying variant of [readCaloriesHistory] (Phase 2 §1).
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) => _outcomeOf(
            _caloriesOutcomeZoneKey,
            () => readCaloriesHistory(days),
            () => _readCaloriesHistoryCore(days),
          );

  Future<HcReadOutcome<List<({String date, int kcal})>>>
      _readCaloriesHistoryCore(int days) async {
    try {
      final raw = await _channel
          .invokeMethod<List>('readCaloriesHistory', {'days': days});
      final out = <({String date, int kcal})>[];
      for (final item in raw ?? const []) {
        if (item is Map) {
          final d = item['date'];
          final v = item['kcal'];
          if (d is String && v is num) out.add((date: d, kcal: v.toInt()));
        }
      }
      return HcReadOutcome(value: out);
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return HcReadOutcome(
          value: const [], errorCode: e.code, errorDetails: _detailsOf(e));
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return HcReadOutcome(value: const [], errorCode: 'NO_CHANNEL');
    }
  }

  /// Blood pressure records `[{t, sys, dia}]` over `[now - days, now)`,
  /// sorted desc. Empty when unreadable.
  Future<List<BpRecord>> readBloodPressure(int days) async {
    try {
      final raw = await _channel
          .invokeMethod<List>('readBloodPressure', {'days': days});
      final out = <BpRecord>[];
      for (final item in raw ?? const []) {
        if (item is Map) {
          final t = item['t'];
          final sys = item['sys'];
          final dia = item['dia'];
          if (t is num && sys is num && dia is num) {
            out.add(BpRecord(
              systolic: sys.toInt(),
              diastolic: dia.toInt(),
              timeEpochMs: t.toInt(),
            ));
          }
        }
      }
      return out;
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return const [];
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return const [];
    }
  }

  // ── Round 48: Key Metrics reads + range reads + CSV export ──────────

  /// Respiratory rate (breaths/min): native lookback rule — best
  /// record in the 30 days ending on [dateStr]. Null when none.
  Future<double?> readRespiratoryRate(String dateStr) =>
      _readDouble('readRespiratoryRate', {'dateStr': dateStr});

  /// Blood oxygen (%): same 30-day lookback + best record; the bridge
  /// already scales fraction values (≤ 1.0) to percent, native-style.
  /// Null when none.
  Future<double?> readOxygenSaturation(String dateStr) =>
      _readDouble('readOxygenSaturation', {'dateStr': dateStr});

  /// HRV RMSSD (ms) for the day: average of the day's highest-priority
  /// tier (native `readHeartRateVariability` daily rule). Null when
  /// none.
  Future<double?> readHrvRmssd(String dateStr) =>
      _readDouble('readHrvRmssd', {'dateStr': dateStr});

  /// R71 — raw HRV RMSSD samples `[{t: epochMs, ms, tier}]` over
  /// `[tomorrowStart - days, tomorrowStart)` (bridge range read,
  /// native `readHeartRateVariability` mechanism: ≤31-day chunks,
  /// paginated, mock records dropped natively). `tier` is the
  /// record origin's package-priority VALUE — no package names
  /// cross the bridge. Sorted ascending by `t`. Day attribution
  /// (local calendar date, top-tier average) lives in Dart:
  /// see [attributeDailyHrv]. Empty when unreadable.
  ///
  /// Defect 0 — the bridge reads each chunk in isolation (the
  /// readSleepHistory contract): when some chunks fail, it returns
  /// `{items: [...], partialError: "<details>"}` instead of a bare
  /// list or a total failure — the samples that DID read are
  /// returned and the partial failure is recorded in
  /// [lastPartialErrorCode] (code `HRV_SAMPLES_PARTIAL`, details in
  /// [lastReadErrorDetails]), exactly as the sleep history read
  /// does. Only a failure of EVERY chunk errors the call.
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async =>
      (await readHrvSamplesWithOutcome(days)).value;

  /// Outcome-carrying variant of [readHrvSamples] (Phase 2 §1).
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) => _outcomeOf(
            _hrvOutcomeZoneKey,
            () => readHrvSamples(days),
            () => _readHrvSamplesCore(days),
          );

  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      _readHrvSamplesCore(int days) async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('readHrvSamples', {'days': days});
      List<dynamic> items = const [];
      String? partialCode;
      String? partialDetails;
      if (raw is List) {
        items = raw;
      } else if (raw is Map) {
        final s = raw['items'];
        if (s is List) items = s;
        final partial = raw['partialError'];
        if (partial is String && partial.isNotEmpty) {
          // Partial is NOT a failure: its own field, like
          // HR_SAMPLES_PARTIAL / SLEEP_HISTORY_PARTIAL.
          partialCode = 'HRV_SAMPLES_PARTIAL';
          partialDetails = partial;
          lastPartialErrorCode = partialCode;
          lastReadErrorDetails = partial;
        }
      }
      final out = <({int t, double ms, int tier})>[];
      for (final item in items) {
        if (item is Map) {
          final t = item['t'];
          final ms = item['ms'];
          final tier = item['tier'];
          if (t is num && ms is num && tier is num) {
            out.add((t: t.toInt(), ms: ms.toDouble(), tier: tier.toInt()));
          }
        }
      }
      return HcReadOutcome(
          value: out, errorDetails: partialDetails, partialCode: partialCode);
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return HcReadOutcome(
          value: const [], errorCode: e.code, errorDetails: _detailsOf(e));
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return HcReadOutcome(value: const [], errorCode: 'NO_CHANNEL');
    }
  }

  /// Parses one raw interval list from the bridge (`[[startMs,
  /// endMs], ...]`). Malformed entries are skipped; a non-list
  /// value yields no intervals.
  static List<({int startMs, int endMs})> _parseSleepIntervals(
      dynamic v) {
    if (v is! List) return const [];
    final out = <({int startMs, int endMs})>[];
    for (final entry in v) {
      if (entry is List && entry.length >= 2) {
        final s = entry[0];
        final e = entry[1];
        if (s is num && e is num) {
          out.add((startMs: s.toInt(), endMs: e.toInt()));
        }
      }
    }
    return out;
  }

  /// Parses one session map from the `readSleepHistory` bridge
  /// payload into a [SleepSessionRaw]. Returns null for a malformed
  /// entry (missing/invalid date, startMs or endMs) — malformed
  /// entries are skipped, never thrown.
  static SleepSessionRaw? _parseSleepSession(dynamic item) {
    if (item is! Map) return null;
    final d = item['date'];
    final start = item['startMs'];
    final end = item['endMs'];
    if (d is! String || d.isEmpty) return null;
    if (start is! num || end is! num) return null;
    return SleepSessionRaw(
      date: d,
      startMs: start.toInt(),
      endMs: end.toInt(),
      awake: _parseSleepIntervals(item['awake']),
      deep: _parseSleepIntervals(item['deep']),
    );
  }

  /// Per-day sleep totals `[{date, mins, deep}]` over the last [days]
  /// days (bridge range read). The bridge now returns per-SESSION
  /// maps (`{date, startMs, endMs, awake, deep}`); the per-day
  /// totals are the union of all the night's bouts, computed in
  /// Dart by [summarizeSleepSessions] (founder decision Oct 28,
  /// 2026: a night's total is all of its bouts added up, overlaps
  /// never double-counted).
  /// Raw values pass through — callers apply the founder zero rule.
  /// Empty when unreadable.
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async =>
      (await readSleepHistoryWithOutcome(days)).value;

  /// Outcome-carrying variant of [readSleepHistory] (Phase 2 §1).
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) => _outcomeOf(
            _sleepOutcomeZoneKey,
            () => readSleepHistory(days),
            () => _readSleepHistoryCore(days),
          );

  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      _readSleepHistoryCore(int days) async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('readSleepHistory', {'days': days})
          ;
      // Kotlin reads the range in chunks: partial chunk failure
      // returns {items: [...], partialError: "<details>"} — keep the
      // days that read and record the failure (code SLEEP_HISTORY_PARTIAL).
      List<dynamic> items = const [];
      String? partialCode;
      String? partialDetails;
      if (raw is List) {
        items = raw;
      } else if (raw is Map) {
        final s = raw['items'];
        if (s is List) items = s;
        final partial = raw['partialError'];
        if (partial is String && partial.isNotEmpty) {
          partialCode = 'SLEEP_HISTORY_PARTIAL';
          partialDetails = partial;
          lastPartialErrorCode = partialCode;
          lastReadErrorDetails = partial;
        }
      }
      final sessions = <SleepSessionRaw>[];
      for (final item in items) {
        final session = _parseSleepSession(item);
        if (session != null) sessions.add(session);
      }
      return HcReadOutcome(
          value: summarizeSleepSessions(sessions),
          errorDetails: partialDetails,
          partialCode: partialCode);
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return HcReadOutcome(
          value: const [], errorCode: e.code, errorDetails: _detailsOf(e));
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return HcReadOutcome(value: const [], errorCode: 'NO_CHANNEL');
    }
  }

  /// Per-day HR spike counts `[{date, count}]` over the last [days]
  /// days (bridge range read, native spike rule). A count of 0 is
  /// REAL (a sampled day with no spikes) and is kept. Empty when
  /// unreadable.
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      (await readSpikeCountsWithOutcome(days)).value;

  /// Outcome-carrying variant of [readSpikeCounts] (Phase 2 §1).
  Future<HcReadOutcome<List<({String date, int count})>>>
      readSpikeCountsWithOutcome(int days) => _outcomeOf(
            _spikesOutcomeZoneKey,
            () => readSpikeCounts(days),
            () => _readSpikeCountsCore(days),
          );

  Future<HcReadOutcome<List<({String date, int count})>>>
      _readSpikeCountsCore(int days) async {
    try {
      final raw =
          await _channel.invokeMethod<List>('readSpikeCounts', {'days': days});
      final out = <({String date, int count})>[];
      for (final item in raw ?? const []) {
        if (item is Map) {
          final d = item['date'];
          final c = item['count'];
          if (d is String && c is num) out.add((date: d, count: c.toInt()));
        }
      }
      return HcReadOutcome(value: out);
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return HcReadOutcome(
          value: const [], errorCode: e.code, errorDetails: _detailsOf(e));
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return HcReadOutcome(value: const [], errorCode: 'NO_CHANNEL');
    }
  }

  /// Round 48 — CSV export hand-off (native `exportMetricsCsvAsync`):
  /// the bridge writes the file to Downloads and opens the share
  /// sheet. True only when the share sheet was launched.
  Future<bool> exportCsvFile({
    required String fileName,
    required String content,
  }) async {
    try {
      return await _channel.invokeMethod<bool>(
            'exportCsvFile',
            {'fileName': fileName, 'content': content},
          ) ??
          false;
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return false;
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return false;
    }
  }

  Future<double?> _readDouble(String method, Map<String, Object> args) async {
    try {
      final v =
          await _channel.invokeMethod<dynamic>(method, args);
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return null;
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return null;
    }
  }

  Future<int?> _readInt(String method, Map<String, Object> args) async {
    try {
      return await _channel.invokeMethod<int>(method, args);
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return null;
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return null;
    }
  }

  /// Round 30 — latest Health Connect weight in kilograms, for the
  /// User Profile Auto-Fill. Port of native
  /// `HealthConnectManager.readLatestWeight` (records from the last
  /// ~90 days, best record by package priority then recency, mock
  /// records dropped). Native's bridge returns pounds because its
  /// DataStore is imperial; the Flutter profile is metric end-to-end,
  /// so this bridge returns kilograms. Null when no record exists —
  /// Auto-Fill never invents a value.
  Future<double?> readLatestWeightKg() async {
    try {
      return await _channel.invokeMethod<double>('readLatestWeightKg');
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return null;
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return null;
    }
  }

  /// Round 30 — latest Health Connect height in centimetres. Port of
  /// native `HealthConnectManager.readLatestHeight` (records from the
  /// last 365 days, same best-record rule). Null when no record.
  Future<double?> readLatestHeightCm() async {
    try {
      return await _channel.invokeMethod<double>('readLatestHeightCm');
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return null;
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return null;
    }
  }

  Future<void> _persist(Set<String> granted) async {
    await _store.write(_kGrantedKey, granted.join(','));
    await _store.write(
        _kConnectedAtKey, DateTime.now().toUtc().toIso8601String());
  }
}

/// One raw sleep session as returned by the `readSleepHistory`
/// bridge: the session interval plus its raw (unmerged) awake and
/// deep stage intervals. [date] is the session's wake/end date
/// ("YYYY-MM-DD") as attributed natively.
class SleepSessionRaw {
  final String date;
  final int startMs;
  final int endMs;
  final List<({int startMs, int endMs})> awake;
  final List<({int startMs, int endMs})> deep;

  const SleepSessionRaw({
    required this.date,
    required this.startMs,
    required this.endMs,
    this.awake = const [],
    this.deep = const [],
  });
}

/// Merges [intervals] with Kotlin `mergeIntervals` semantics:
/// degenerate intervals (end <= start) are dropped, the rest are
/// sorted by start and merged whenever the next interval starts at
/// or before the current merged interval ends
/// (`next.start <= current.end`).
List<({int startMs, int endMs})> _mergeSleepIntervals(
    Iterable<({int startMs, int endMs})> intervals) {
  final cleaned = [
    for (final iv in intervals)
      if (iv.endMs > iv.startMs) iv,
  ]..sort((a, b) {
      final byStart = a.startMs.compareTo(b.startMs);
      return byStart != 0 ? byStart : a.endMs.compareTo(b.endMs);
    });
  final merged = <({int startMs, int endMs})>[];
  for (final iv in cleaned) {
    if (merged.isEmpty || iv.startMs > merged.last.endMs) {
      merged.add(iv);
    } else if (iv.endMs > merged.last.endMs) {
      merged[merged.length - 1] =
          (startMs: merged.last.startMs, endMs: iv.endMs);
    }
  }
  return merged;
}

/// The asleep pieces of one session: its merged awake intervals,
/// clamped to the session interval, subtracted from it.
List<({int startMs, int endMs})> _asleepPieces(SleepSessionRaw session) {
  if (session.endMs <= session.startMs) return const [];
  final clampedAwake = <({int startMs, int endMs})>[];
  for (final iv in _mergeSleepIntervals(session.awake)) {
    final start = iv.startMs < session.startMs ? session.startMs : iv.startMs;
    final end = iv.endMs > session.endMs ? session.endMs : iv.endMs;
    if (end > start) clampedAwake.add((startMs: start, endMs: end));
  }
  final pieces = <({int startMs, int endMs})>[];
  var cursor = session.startMs;
  for (final iv in clampedAwake) {
    if (iv.startMs > cursor) {
      pieces.add((startMs: cursor, endMs: iv.startMs));
    }
    if (iv.endMs > cursor) cursor = iv.endMs;
  }
  if (cursor < session.endMs) {
    pieces.add((startMs: cursor, endMs: session.endMs));
  }
  return pieces;
}

/// Sleep-bouts-summed (founder decision Oct 28, 2026): a night's
/// sleep total is ALL of that night's sleep bouts added up, with
/// overlaps never double-counted. Per date (sessions grouped by
/// their wake/end [SleepSessionRaw.date]):
/// - each session's asleep time is the session interval minus its
///   merged awake stages (clamped to the session);
/// - `mins` is the duration of the UNION of every session's asleep
///   pieces for the date, in whole minutes;
/// - `deep` is the duration of the UNION of every session's deep
///   stage intervals for the date, in whole minutes.
///
/// Returns one entry per date that has at least one session,
/// sorted ascending by date — INCLUDING a date whose union totals
/// 0: raw values pass through and callers apply the founder zero
/// rule, exactly as the per-day totals always have.
List<({String date, int mins, int deep})> summarizeSleepSessions(
    Iterable<SleepSessionRaw> sessions) {
  final asleepByDate = <String, List<({int startMs, int endMs})>>{};
  final deepByDate = <String, List<({int startMs, int endMs})>>{};
  for (final session in sessions) {
    asleepByDate
        .putIfAbsent(session.date, () => [])
        .addAll(_asleepPieces(session));
    deepByDate.putIfAbsent(session.date, () => []).addAll(session.deep);
  }
  final dates = asleepByDate.keys.toList()..sort();
  final out = <({String date, int mins, int deep})>[];
  for (final date in dates) {
    var asleepMs = 0;
    for (final iv in _mergeSleepIntervals(asleepByDate[date]!)) {
      asleepMs += iv.endMs - iv.startMs;
    }
    var deepMs = 0;
    for (final iv in _mergeSleepIntervals(deepByDate[date]!)) {
      deepMs += iv.endMs - iv.startMs;
    }
    out.add((date: date, mins: asleepMs ~/ 60000, deep: deepMs ~/ 60000));
  }
  return out;
}

/// R71 — attribute raw HRV samples to local calendar days and
/// reduce each day to its daily RMSSD value (the native
/// `readHeartRateVariability` daily rule, moved into Dart where it
/// is testable):
/// - a sample belongs to the LOCAL calendar date of its timestamp
///   (`DateTime.fromMillisecondsSinceEpoch`);
/// - samples with `ms <= 0` are failed reads (founder zero rule)
///   and are dropped;
/// - only dates in [dates] are kept;
/// - per date, only the highest tier present that day counts, and
///   the value is that tier's average.
///
/// Returns a map of "YYYY-MM-DD" → daily RMSSD (ms); days with no
/// usable sample are absent, never zero-filled.
Map<String, double> attributeDailyHrv(
  Iterable<({int t, double ms, int tier})> samples,
  Set<String> dates,
) {
  String dateStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // date → tier → (sum, count)
  final byDate = <String, Map<int, (double, int)>>{};
  for (final s in samples) {
    if (s.ms <= 0) continue;
    final date = dateStr(DateTime.fromMillisecondsSinceEpoch(s.t));
    if (!dates.contains(date)) continue;
    final tiers = byDate.putIfAbsent(date, () => {});
    final prev = tiers[s.tier];
    tiers[s.tier] = prev == null ? (s.ms, 1) : (prev.$1 + s.ms, prev.$2 + 1);
  }
  final out = <String, double>{};
  for (final entry in byDate.entries) {
    var bestTier = entry.value.keys.first;
    for (final tier in entry.value.keys) {
      if (tier > bestTier) bestTier = tier;
    }
    final (sum, count) = entry.value[bestTier]!;
    out[entry.key] = sum / count;
  }
  return out;
}

enum HealthConnectStatus {
  unavailable,
  notConnected,
  partiallyConnected,
  connected,
}

/// Phase 2 (§1) — one history read's result WITH its own signals:
/// errors travel with their own read's result, so attribution
/// never depends on the shared legacy slot fields and concurrent
/// readers on one service instance cannot cross-talk.
class HcReadOutcome<T> {
  /// The fail-closed value — identical to the legacy method's
  /// return for the same read.
  final T value;

  /// THIS read's failure code; null on success (and on a partial
  /// read — a partial is not a failure).
  final String? errorCode;

  /// THIS read's detail: the native exception CLASS only (Juno
  /// J1), for a failure the failing exception's class, for a
  /// partial read the partial failure's class — mirroring exactly
  /// what the read leaves in `lastReadErrorDetails`.
  final String? errorDetails;

  /// THIS read's partial code; null unless the read returned real
  /// data with some chunks missing.
  final String? partialCode;

  const HcReadOutcome({
    required this.value,
    this.errorCode,
    this.errorDetails,
    this.partialCode,
  });

  bool get failed => errorCode != null;
  bool get partial => partialCode != null;
  bool get failedWithSecurityException =>
      errorDetails?.contains('SecurityException') ?? false;
}

/// Phase 2 (§2) — one availability snapshot from
/// [HealthConnectService.probeAvailability]. A KNOWN state
/// (including [staleWedged]) is authoritative and is never
/// overridden by [persistedConnected]; the persisted flag is a
/// first-paint hint only, and for the unknown-grant case.
class HcAvailability {
  /// `isAvailable()` answered true. False both when it answered
  /// false and when the bridge errored before answering.
  final bool serviceAvailable;

  /// The live granted set; null = the bridge errored and the
  /// grant layer is UNKNOWN.
  final Set<String>? grantedPermissions;

  /// The bridge failure's code when any probe layer errored —
  /// for logs only, never rendered.
  final String? bridgeErrorCode;

  /// The availability layer's actual failure, verbatim (the
  /// [HealthConnectException] `isAvailable()` threw — code AND
  /// native message), when that step errored; null when it
  /// answered. Recorded so [HealthConnectService.getStatus] can
  /// propagate the failure EXACTLY as base did (Vera Item 3):
  /// probing stays throw-free, but the legacy status contract
  /// throws, and it throws THIS, not a synthesized generic.
  final HealthConnectException? availabilityError;

  /// The grant layer's actual failure, verbatim (the
  /// [HealthConnectException] the granted-permissions read
  /// threw — code AND native message), when that step errored;
  /// null when the grant layer answered (or was never read).
  /// Rides the same getStatus() rethrow as [availabilityError],
  /// after it.
  final HealthConnectException? grantError;

  /// The Steps read probe's outcome; null when not run (the
  /// grant was not full, so the probe could prove nothing).
  final HcReadProbeOutcome? stepsProbe;

  /// The persisted-connection flag — first-paint hint ONLY.
  final bool persistedConnected;

  const HcAvailability({
    required this.serviceAvailable,
    required this.grantedPermissions,
    required this.bridgeErrorCode,
    this.availabilityError,
    this.grantError,
    required this.stepsProbe,
    required this.persistedConnected,
  });

  bool get grantKnown => grantedPermissions != null;

  /// Required − granted. Meaningful ONLY when [grantKnown]; when
  /// the grant layer is unknown this is empty and callers must
  /// consult [grantKnown] instead of treating it as a full grant.
  Set<String> get missingPermissions => grantKnown
      ? HealthConnectService.missingPermissions(grantedPermissions!)
      : const {};

  bool get fullGrant =>
      grantKnown &&
      grantedPermissions!
          .containsAll(HealthConnectService.requiredPermissions);

  /// Full grant, but the real read probe was blocked with a
  /// SecurityException — the stale/wedged grant state, as DATA.
  bool get staleWedged =>
      fullGrant && stepsProbe == HcReadProbeOutcome.securityFailure;

  /// The derived legacy status; null ONLY when the bridge errored
  /// and the grant layer is unknown. A confirmed-unavailable
  /// device (isAvailable answered false, no bridge error, grant
  /// layer unread) derives [HealthConnectStatus.unavailable];
  /// every known grant layer derives its status from the grant
  /// itself (a full grant whose probe is wedged still derives
  /// [HealthConnectStatus.connected] here — the wedge is carried
  /// by [staleWedged], and [HealthConnectService.getStatus]
  /// translates it back into the legacy throw).
  HealthConnectStatus? get status {
    final granted = grantedPermissions;
    if (granted == null) {
      if (!serviceAvailable && bridgeErrorCode == null) {
        return HealthConnectStatus.unavailable;
      }
      return null;
    }
    if (granted.isEmpty) return HealthConnectStatus.notConnected;
    if (granted.containsAll(HealthConnectService.requiredPermissions)) {
      return HealthConnectStatus.connected;
    }
    return HealthConnectStatus.partiallyConnected;
  }
}

/// Outcome of the grant-state read probe ([HealthConnectService.probeReadAccess]).
enum HcReadProbeOutcome {
  /// The probe read succeeded — reads genuinely work.
  ok,

  /// The probe was blocked with a SecurityException while grants
  /// report OK — the stale/wedged grant state.
  securityFailure,

  /// The probe failed for another reason (or could not run).
  failed,

  /// Reserved: the probe could not complete in time.
  timedOut,
}

class HealthConnectException implements Exception {
  final String code;
  final String message;

  const HealthConnectException(this.code, this.message);

  @override
  String toString() => 'HealthConnectException[$code]: $message';
}

/// Round 18b — per-stage sleep breakdown from the `readSleepStages`
/// bridge call (ports native `HealthConnectManager.readSleepSession`).
/// All fields nullable; null means the bridge had no session.
/// A 0 stage value is a missing reading per the founder's biometric
/// rule (never displayed as real data) — the UI maps 0 → null.
class SleepStages {
  final int? minutesAsleep;
  final int? deepMinutes;
  final int? lightMinutes;
  final int? remMinutes;
  final int? efficiency; // percent 0–100

  const SleepStages({
    this.minutesAsleep,
    this.deepMinutes,
    this.lightMinutes,
    this.remMinutes,
    this.efficiency,
  });
}

/// Minimal storage abstraction so tests can inject an in-memory fake.
/// Production uses Android Keystore-backed flutter_secure_storage.
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureStore implements SecureStore {
  final FlutterSecureStorage _storage;

  const FlutterSecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
