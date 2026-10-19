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
        'Active calories',
    'android.permission.health.READ_TOTAL_CALORIES_BURNED':
        'Total calories',
    'android.permission.health.READ_BASAL_METABOLIC_RATE':
        'Basal metabolic rate',
    'android.permission.health.READ_WEIGHT': 'Weight',
    'android.permission.health.READ_HEIGHT': 'Height',
    'android.permission.health.READ_HEART_RATE_VARIABILITY':
        'Heart rate variability',
    'android.permission.health.READ_RESPIRATORY_RATE': 'Breathing rate',
    'android.permission.health.READ_OXYGEN_SATURATION': 'Blood oxygen',
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
      'Health Connect lists this app as having permission, but a '
      'test read was blocked. This sometimes happens after an app '
      'update or reinstall. To fix it, open Health Connect, tap '
      'App permissions, tap this app, then tap Remove access. '
      'Return here and connect again.';

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

  /// Live status: availability + granted-set check. Persists the granted
  /// set when everything required is granted.
  Future<HealthConnectStatus> getStatus() async {
    final available = await isAvailable();
    if (!available) return HealthConnectStatus.unavailable;
    final granted = await getGrantedPermissions();
    if (granted.containsAll(requiredPermissions)) {
      // Grant-state probe before persisting (Juno J3): the defect
      // #3 population never re-requests permissions, so the status
      // path is where a blocked grant must surface. A SecurityException
      // probe = stale grant: throw, do not persist. Any other probe
      // outcome is soft and does not block the connected status.
      final probe = await probeReadAccess();
      if (probe == HcReadProbeOutcome.securityFailure) {
        throw const HealthConnectException(
            staleGrantCode, staleGrantMessage);
      }
      await _persist(granted);
      return HealthConnectStatus.connected;
    }
    if (granted.isEmpty) return HealthConnectStatus.notConnected;
    return HealthConnectStatus.partiallyConnected;
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
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async {
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
      return out;
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return const [];
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return const [];
    }
  }

  /// Per-day active calories `[{date: "YYYY-MM-DD", kcal}]`, `active ?:
  /// total` per day (native rule). Empty when unreadable.
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async {
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
      return out;
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return const [];
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return const [];
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
      int days) async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('readHrvSamples', {'days': days});
      List<dynamic> items = const [];
      if (raw is List) {
        items = raw;
      } else if (raw is Map) {
        final s = raw['items'];
        if (s is List) items = s;
        final partial = raw['partialError'];
        if (partial is String && partial.isNotEmpty) {
          // Partial is NOT a failure: its own field, like
          // HR_SAMPLES_PARTIAL / SLEEP_HISTORY_PARTIAL.
          lastPartialErrorCode = 'HRV_SAMPLES_PARTIAL';
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
      return out;
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return const [];
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return const [];
    }
  }

  /// Per-day sleep totals `[{date, mins, deep}]` over the last [days]
  /// days (bridge range read, native `readHistoricalSleepWithDeep`).
  /// Raw values pass through — callers apply the founder zero rule.
  /// Empty when unreadable.
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('readSleepHistory', {'days': days})
          ;
      // Kotlin reads the range in chunks: partial chunk failure
      // returns {items: [...], partialError: "<details>"} — keep the
      // days that read and record the failure (code SLEEP_HISTORY_PARTIAL).
      List<dynamic> items = const [];
      if (raw is List) {
        items = raw;
      } else if (raw is Map) {
        final s = raw['items'];
        if (s is List) items = s;
        final partial = raw['partialError'];
        if (partial is String && partial.isNotEmpty) {
          lastPartialErrorCode = 'SLEEP_HISTORY_PARTIAL';
          lastReadErrorDetails = partial;
        }
      }
      final out = <({String date, int mins, int deep})>[];
      for (final item in items) {
        if (item is Map) {
          final d = item['date'];
          final m = item['mins'];
          final deep = item['deep'];
          if (d is String && m is num) {
            out.add((
              date: d,
              mins: m.toInt(),
              deep: deep is num ? deep.toInt() : 0,
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

  /// Per-day HR spike counts `[{date, count}]` over the last [days]
  /// days (bridge range read, native spike rule). A count of 0 is
  /// REAL (a sampled day with no spikes) and is kept. Empty when
  /// unreadable.
  Future<List<({String date, int count})>> readSpikeCounts(int days) async {
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
      return out;
    } on PlatformException catch (e) {
      _notePlatformError(e);
      return const [];
    } on MissingPluginException {
      _noteReadError('NO_CHANNEL');
      return const [];
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
