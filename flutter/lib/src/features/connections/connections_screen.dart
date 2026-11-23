import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/features/connections/health_connect_disclosure.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 12 — data connections screen.
///
/// Faithful port of the native `DataConnectionsScreen.kt`:
/// - TopAppBar: centered "Data connections" (20sp Bold), purple back arrow,
///   48dp spacer balancing the nav icon.
/// - "Your connections" / "Add connections" sections with tappable
///   ConnectionItem rows (20dp radius, NotelSurface, 1dp surfaceHigh@30%
///   border, 44dp logo circle, 14sp Bold name + 12sp status, chevron).
/// - "Unavailable" section: the retired Fitbit card with the native copy
///   verbatim (Google retired the Fitbit Web API Oct 30, 2026).
/// - "How to connect a tracker" help section, native copy verbatim.
/// - Management bottom sheet for a connected row (status, grant-remaining
///   when partial, "Manage system permissions"). There is NO in-app
///   deactivate/disconnect control: Tabs cannot revoke its own Health
///   Connect access — the user removes it in Health Connect (Juno
///   ruling #8, HC connection-honesty package).
///
/// Health Connect row states: Connected (green) / Partially connected
/// (warning) / Connection problem (stale grant — the live probe was
/// blocked while grants report complete) / Available (tap → permission
/// flow) / Not available on this device (disabled). Channel failures
/// surface as their plain-language message — never a bracketed code.
///
/// Nov 2, 2026 fix (founder report): the Connected row is also rendered
/// from persisted state while the live check is still pending, but the
/// manage sheet's guard read only the live status and silently
/// returned — a dead tap on a row showing "Connected" + chevron,
/// permanent for the whole visit when the (unbounded) live check
/// wedged. The sheet now opens on the EFFECTIVE (displayed) status,
/// and a tap in any other state re-verifies instead of no-oping.
class ConnectionsScreen extends StatefulWidget {
  final HealthConnectService? healthConnectService;
  final VoidCallback? onBack;

  const ConnectionsScreen({super.key, this.healthConnectService, this.onBack});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

/// Chunk 5 — Juno's SIGNED iOS availability copy, verbatim
/// (`build-apple-readiness/juno/ios-availability-copy.md`,
/// 2026-11-22; HealthKit wiring design §1c/§4). These strings are
/// the ONLY iOS health-availability strings in the app: the
/// Connections detail sheet below and the Settings Connected Apps
/// row both read from here — one source of truth, never forked.
///
/// Juno's blocklist binds this surface: no "Partially connected",
/// no "Connection problem" / stale-grant language, no "Grant New
/// Permissions", no "No permissions were granted.", no per-type
/// grant lines, no background-access row, and no string naming
/// Health Connect, Google, Android, or App permissions may render
/// on iOS. "Connected" renders ONLY in the requested + has-data
/// state ([IosHealthAvailabilityState.connected]).
class IosHealthCopy {
  static const String rowName = 'Apple Health';

  /// Row status per state (Connections row; Juno §1).
  static String rowStatus(IosHealthAvailabilityState state) =>
      switch (state) {
        IosHealthAvailabilityState.notYetRequested => 'Available',
        IosHealthAvailabilityState.connected => 'Connected',
        IosHealthAvailabilityState.noDataYet => 'No data yet',
        IosHealthAvailabilityState.unavailable =>
          'Not available on this device',
      };

  /// Status line per state (detail sheet, Juno §1; the Settings
  /// row uses the same lines, Juno §2).
  static String statusLine(IosHealthAvailabilityState state) =>
      switch (state) {
        IosHealthAvailabilityState.notYetRequested => 'Not connected',
        IosHealthAvailabilityState.connected => 'Connected',
        IosHealthAvailabilityState.noDataYet => 'No data yet',
        IosHealthAvailabilityState.unavailable =>
          'Not available on this device',
      };

  // State 1 — not yet requested (Juno §1).
  static const String state1Body =
      'Tabs can read your heart rate, resting heart rate, heart rate '
      'variability, sleep, steps, and energy from Apple Health, so you '
      'can see your own daily values together in Tabs. Tabs reads this '
      'data only. It does not write anything to Apple Health.';
  static const String state1Button = 'Connect Apple Health';

  // State 2 — requested, data returning (Juno §1).
  static const String state2Body =
      'Tabs is reading your health data from Apple Health.';
  static const String state2ManageButton = 'Manage in Health app';
  static const String state2Footer =
      'Your connection is managed in Apple Health. To stop Tabs from '
      'reading your health data, open the Health app, tap your profile, '
      'tap Apps, tap Tabs, and turn off the data types you no longer '
      'want to share. You can also go to Settings, then Health, then '
      'Data Access & Devices, then Tabs.';

  // State 3 — requested, no data yet (Juno §1).
  static const String state3Body =
      'Tabs has asked Apple Health for your health data, and nothing '
      'has come back yet. That is normal if you do not have an Apple '
      'Watch or another app writing to Apple Health: heart rate, '
      'resting heart rate, and heart rate variability are recorded by '
      'a watch, and sleep is recorded by a watch or another sleep app. '
      'Steps and energy from your iPhone can take a little while to '
      'appear. Your logging, check-ins, and notes in Tabs work either '
      'way.';
  static const String state3Secondary =
      'If you expected data to be here, check that Tabs is allowed to '
      'read it: open the Health app, tap your profile, tap Apps, tap '
      'Tabs, and make sure the data types you want are on.';
  static const String state3Button = 'Check again';

  // State 4 — HealthKit unavailable on this device (Juno §1).
  static const String state4Detail =
      'Apple Health is not available on this device, so Tabs cannot '
      'read health data from it here. Your logging, check-ins, and '
      'notes in Tabs still work.';
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  late final HealthConnectService _service;
  HealthConnectStatus? _status;
  bool _persistedConnected = false;
  bool _requesting = false;
  String? _error;

  /// Chunk 5 — the iOS availability snapshot. Null until the first
  /// probe lands (the iOS body renders its loading row meanwhile).
  /// Only ever read on the iOS path ([HealthConnectService.isIOS]);
  /// the Android path below is untouched.
  IosHealthAvailability? _iosAvailability;

  /// True when the availability snapshot reports the stale/wedged
  /// grant ([HcAvailability.staleWedged]): Health Connect lists
  /// Tabs as granted, but the real read probe was blocked. In this
  /// state the row must show "Connection problem" (Juno ruling
  /// #3) — the persisted-flag fallback must NEVER manufacture
  /// "Connected" out of this known state.
  bool _staleGrant = false;

  // HRV grant visibility — plain-language names of the data types
  // NOT shared when the grant is partial (e.g. "Heart rate
  // variability"), so the missing type is named here instead of a
  // bare "Partially connected". Empty when fully granted or when
  // the missing-set read failed.
  List<String> _missingLabels = const [];

  /// The status the UI may act on. The live check ([_status]) is
  /// authoritative once it lands, but the row also renders as
  /// "Connected" from persisted state while the live check is still
  /// pending (fast first paint, see [_loadStatus]) — and the live
  /// check's first bridge calls carry no timeout, so a wedged
  /// Health Connect can leave it pending indefinitely. In that
  /// window the displayed status IS the persisted one: a row that
  /// says "Connected" with a chevron must open the manage sheet
  /// for that connection, never silently no-op.
  HealthConnectStatus? get _effectiveStatus =>
      _status ??
      (_persistedConnected ? HealthConnectStatus.connected : null);

  @override
  void initState() {
    super.initState();
    _service = widget.healthConnectService ?? HealthConnectService();
    _loadStatus();
  }

  /// Phase 2 PR-2 — derives every presented state from ONE
  /// probeAvailability() snapshot (the snapshot never throws, so
  /// there is no catch path here any more). A KNOWN state —
  /// including stale, which arrives as DATA ([HcAvailability]
  /// .staleWedged) — is authoritative and is never overridden by
  /// the persisted flag; the persisted flag serves first paint
  /// (via [_effectiveStatus] before the first snapshot) and the
  /// UNKNOWN fallback only. [errorOverride] keeps a caller-owned
  /// failure message (the permission-request failure in
  /// [_onConnectTap]) when the snapshot itself is a known state.
  void _applySnapshot(HcAvailability snapshot, {String? errorOverride}) {
    _persistedConnected = snapshot.persistedConnected;
    if (snapshot.staleWedged) {
      // Stale grant (Juno ruling #3/#5): the live probe was
      // blocked, so the row tells the truth — "Connection
      // problem" — and the error line presents the ruled
      // recovery text with NO bracketed code prefix. The
      // persisted flag must not turn this state into
      // "Connected": _status lands on notConnected and
      // _staleGrant drives the row/sheet presentation.
      _staleGrant = true;
      _status = HealthConnectStatus.notConnected;
      _error = HealthConnectService.staleGrantMessage;
      _missingLabels = const [];
      return;
    }
    final status = snapshot.status;
    if (status == null) {
      // UNKNOWN — the grant layer itself errored at the bridge.
      // Present exactly as the old generic exception path did:
      // the persisted-flag fallback status plus the failure's
      // plain-language message (the code goes to logs only).
      if (snapshot.bridgeErrorCode != null) {
        debugPrint(
            'Connections HC status check failed [${snapshot.bridgeErrorCode}]');
      }
      _staleGrant = false;
      _status = snapshot.persistedConnected
          ? HealthConnectStatus.connected
          : HealthConnectStatus.notConnected;
      _error = errorOverride ??
          snapshot.availabilityError?.message ??
          snapshot.grantError?.message ??
          'Status check failed.';
      _missingLabels = const [];
      return;
    }
    _staleGrant = false;
    _status = status;
    _error = errorOverride;
    // Partial grant: the missing types derive from the snapshot's
    // own granted set — plain-language labels in required order.
    _missingLabels = status == HealthConnectStatus.partiallyConnected
        ? [
            for (final p in HealthConnectService.requiredPermissions)
              if (snapshot.missingPermissions.contains(p))
                HealthConnectService.permissionLabel(p),
          ]
        : const [];
  }

  Future<void> _loadStatus() async {
    if (_service.isIOS) {
      // Chunk 5 — the iOS probe: the honest four-state snapshot.
      // There is no persisted-grant first paint on iOS (the
      // persisted record is the authorization request itself, which
      // the probe reads as one of its three facts).
      final snapshot = await _service.probeIosAvailability();
      if (!mounted) return;
      setState(() => _iosAvailability = snapshot);
      return;
    }
    // Fast first paint from persisted state (shared with onboarding),
    // then confirm with the live probe snapshot.
    try {
      final persisted = await _service.hasPersistedConnection();
      if (mounted) setState(() => _persistedConnected = persisted);
    } catch (_) {}
    final snapshot = await _service.probeAvailability();
    if (!mounted) return;
    setState(() => _applySnapshot(snapshot));
  }

  Future<void> _onConnectTap() async {
    if (_requesting) return;
    // MF-3 (Juno compliance): prominent in-app disclosure BEFORE the
    // system permission UI. "Not now" or dismissal never triggers it.
    final proceed = await showHealthConnectDisclosure(context);
    if (!proceed || !mounted) return;
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      final granted = await _service.requestPermissions();
      if (!mounted) return;
      setState(() {
        _requesting = false;
        _staleGrant = false;
        if (granted.containsAll(HealthConnectService.requiredPermissions)) {
          _status = HealthConnectStatus.connected;
          _missingLabels = const [];
        } else if (granted.isEmpty) {
          _error = 'No permissions were granted.';
          _status = HealthConnectStatus.notConnected;
          _missingLabels = const [];
        } else {
          _status = HealthConnectStatus.partiallyConnected;
          _missingLabels =
              HealthConnectService.missingPermissionLabels(granted);
        }
      });
    } on HealthConnectException catch (e) {
      // requestPermissions() may still throw — including the
      // stale-grant code when its internal read probe is blocked.
      // The code is NOT special-cased: the authoritative state
      // comes from a fresh probe snapshot (stale arrives there as
      // data), and the request failure's own plain message stays
      // as the error line for non-stale failures.
      if (!mounted) return;
      setState(() => _requesting = false);
      final snapshot = await _service.probeAvailability();
      if (!mounted) return;
      setState(() => _applySnapshot(snapshot,
          errorOverride: snapshot.staleWedged ? null : e.message));
    }
  }

  /// Chunk 6 — the iOS connect action (from the detail sheet's
  /// "Connect Apple Health" button): runs the read-only HealthKit
  /// authorization request through the SAME
  /// [HealthConnectService.requestPermissions] surface Android
  /// uses, then re-probes. No Health Connect disclosure dialog is
  /// shown on iOS: the rationale-before-dialog step is the detail
  /// sheet itself, whose Juno-signed body names the data types and
  /// the read-only fact before the system sheet appears. A
  /// completed request never shows an error here — if nothing was
  /// shared, the re-probe lands on "No data yet" (Juno §1, State 1
  /// note), which is a state, not a failure.
  Future<void> _onIosConnect() async {
    if (_requesting) return;
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      await _service.requestPermissions();
    } on HealthConnectException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (!mounted) return;
    setState(() => _requesting = false);
    await _loadStatus();
  }

  /// The iOS sheet's "Manage in Health app" action. Tabs cannot
  /// deep-link into the Health app's per-app page on iOS v1, so a
  /// failed settings hand-off surfaces Juno's footer text — the
  /// manual path — as the visible instruction instead of failing
  /// silently (LESSONS: silent channel failures).
  Future<void> _onIosManage() async {
    try {
      await _service.openHealthConnectSettings();
    } on HealthConnectException {
      if (mounted) setState(() => _error = IosHealthCopy.state2Footer);
    }
  }

  /// Opens the iOS detail sheet for States 1–3 (State 4's row is
  /// disabled and opens nothing, matching Juno §2).
  Future<void> _openIosSheet() async {
    final snapshot = _iosAvailability;
    if (snapshot == null) return;
    if (snapshot.state == IosHealthAvailabilityState.unavailable) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: NotelColors.surface,
      builder: (sheetContext) => _IosHealthSheet(
        availability: snapshot,
        requesting: _requesting,
        onConnect: () async {
          Navigator.of(sheetContext).pop();
          await _onIosConnect();
        },
        onCheckAgain: () async {
          Navigator.of(sheetContext).pop();
          await _loadStatus();
        },
        onManage: () async {
          Navigator.of(sheetContext).pop();
          await _onIosManage();
        },
      ),
    );
  }

  Future<void> _openManageSheet() async {
    // Act on the EFFECTIVE status — the one the row displays. The
    // old guard read only the live [_status] and silently returned
    // while it was still pending, which is exactly the dead tap on
    // the persisted "Connected" row (founder report, Nov 2, 2026).
    var status = _effectiveStatus;
    // Stale grant: the sheet IS the recovery surface (Juno ruling
    // #4/#5), so it opens directly on the stale presentation — the
    // connected/partial guard below must not re-verify-and-return
    // it away.
    final isStale = _staleGrant;
    if (!isStale &&
        status != HealthConnectStatus.connected &&
        status != HealthConnectStatus.partiallyConnected) {
      // Never a silent no-op (LESSONS: silent channel failures):
      // re-verify live. A bridge failure surfaces visibly via
      // _loadStatus, and a changed grant re-renders the row in
      // its true state.
      await _loadStatus();
      if (!mounted) return;
      status = _effectiveStatus;
      if (status != HealthConnectStatus.connected &&
          status != HealthConnectStatus.partiallyConnected) {
        return;
      }
    }
    // A settings-open failure from inside the sheet is kept here and
    // applied AFTER the post-sheet re-verify below: setting _error
    // while the sheet was open hid it behind the sheet, and the
    // re-verify's success path then cleared it — a silent failure.
    String? sheetError;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: NotelColors.surface,
      builder: (sheetContext) => _ManageSheet(
        status: status!,
        isConnectionProblem: isStale,
        onGrantRemaining: () async {
          Navigator.of(sheetContext).pop();
          await _onConnectTap();
        },
        onManageSystem: () async {
          Navigator.of(sheetContext).pop();
          try {
            await _service.openHealthConnectSettings();
          } on HealthConnectException catch (e) {
            sheetError = e.message;
          }
        },
      ),
    );
    // Re-verify after the sheet closes (user may have changed permissions).
    await _loadStatus();
    if (sheetError != null && mounted) {
      setState(() => _error = sheetError);
    }
  }

  /// Chunk 5 — the iOS body: the "Apple Health" row in Juno's four
  /// states (see [IosHealthCopy]). The Android-shaped sections of
  /// the Android body (the Health Connect help text, the Fitbit
  /// card, the partial/stale presentations) never render here —
  /// Juno's blocklist forbids their strings on iOS. Loading renders
  /// the spinner row only: Juno's file carries no iOS loading
  /// string, and none is invented.
  Widget _buildIosScaffold() {
    final snapshot = _iosAvailability;
    final state = snapshot?.state;
    final inYourConnections =
        state == IosHealthAvailabilityState.connected ||
            state == IosHealthAvailabilityState.noDataYet;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
          icon: animationsDisabled(context)
              ? const Icon(Icons.arrow_back, color: NotelColors.primary)
              : const Hero(
                  tag: watchConnectionsHeroTag,
                  child: Icon(Icons.arrow_back, color: NotelColors.primary),
                ),
          tooltip: 'Back',
        ),
        title: const Text(
          'Data connections',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        centerTitle: true,
        actions: const [SizedBox(width: 48)],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionLabel('Your connections'),
            const SizedBox(height: 8),
            if (snapshot == null)
              const _LoadingRow()
            else if (inYourConnections)
              _ConnectionItem(
                logo: const _AppleHealthLogo(),
                name: IosHealthCopy.rowName,
                statusText: IosHealthCopy.rowStatus(state!),
                statusColor: state == IosHealthAvailabilityState.connected
                    ? NotelColors.success
                    : NotelColors.textSecondary,
                onTap: _openIosSheet,
              )
            else
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  'No trackers connected yet.',
                  style: TextStyle(
                    color: Color(0x807A8FAF),
                    fontSize: 14,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            _SectionLabel('Add connections'),
            const SizedBox(height: 8),
            if (snapshot == null)
              const _LoadingRow()
            else if (state == IosHealthAvailabilityState.notYetRequested)
              _ConnectionItem(
                logo: const _AppleHealthLogo(),
                name: IosHealthCopy.rowName,
                statusText: IosHealthCopy.rowStatus(state!),
                statusColor: NotelColors.textSecondary,
                onTap: _requesting ? null : _openIosSheet,
                trailing: _requesting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NotelColors.primary,
                        ),
                      )
                    : null,
              )
            else if (state == IosHealthAvailabilityState.unavailable) ...[
              _ConnectionItem(
                logo: const _AppleHealthLogo(),
                name: IosHealthCopy.rowName,
                statusText: IosHealthCopy.rowStatus(state!),
                statusColor: NotelColors.textSecondary,
                onTap: null,
              ),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  IosHealthCopy.state4Detail,
                  style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 13,
                    height: 18 / 13,
                  ),
                ),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  "You've connected every supported tracker.",
                  style: TextStyle(
                    color: Color(0x807A8FAF),
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: NotelColors.error,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_service.isIOS) return _buildIosScaffold();
    final status = _status;
    final effectiveStatus = _effectiveStatus;
    final showLoading = status == null && !_persistedConnected;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
          // Round 14 — shared-element counterpart to the home header's
          // watch icon: it flies here during the push. Omitted under
          // reduced motion.
          icon: animationsDisabled(context)
              ? const Icon(Icons.arrow_back, color: NotelColors.primary)
              : const Hero(
                  tag: watchConnectionsHeroTag,
                  child: Icon(Icons.arrow_back, color: NotelColors.primary),
                ),
          tooltip: 'Back',
        ),
        title: const Text(
          'Data connections',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        centerTitle: true,
        actions: const [SizedBox(width: 48)],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionLabel('Your connections'),
            const SizedBox(height: 8),
            if (showLoading)
              const _LoadingRow()
            else if (_staleGrant)
              _ConnectionItem(
                logo: const _HealthConnectLogo(),
                name: 'Android Health (Google Fit, Samsung)',
                statusText: 'Connection problem',
                statusColor: NotelColors.error,
                onTap: _openManageSheet,
              )
            else if (effectiveStatus == HealthConnectStatus.connected ||
                effectiveStatus == HealthConnectStatus.partiallyConnected)
              _ConnectionItem(
                logo: const _HealthConnectLogo(),
                name: 'Android Health (Google Fit, Samsung)',
                statusText:
                    effectiveStatus == HealthConnectStatus.partiallyConnected
                        ? 'Partially connected'
                        : 'Connected',
                statusColor:
                    effectiveStatus == HealthConnectStatus.partiallyConnected
                        ? NotelColors.warning
                        : NotelColors.success,
                onTap: _openManageSheet,
              )
            else
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  'No trackers connected yet.',
                  style: TextStyle(
                    color: Color(0x807A8FAF),
                    fontSize: 14,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            _SectionLabel('Add connections'),
            const SizedBox(height: 8),
            if (showLoading)
              const _LoadingRow()
            else if (status == HealthConnectStatus.unavailable)
              const _ConnectionItem(
                logo: _HealthConnectLogo(),
                name: 'Android Health (Google Fit, Samsung)',
                statusText: 'Not available on this device',
                statusColor: NotelColors.textSecondary,
                onTap: null,
              )
            else if (!_staleGrant &&
                (status == HealthConnectStatus.notConnected ||
                    (!_persistedConnected && status == null)))
              _ConnectionItem(
                logo: const _HealthConnectLogo(),
                name: 'Android Health (Google Fit, Samsung)',
                statusText: 'Available',
                statusColor: NotelColors.textSecondary,
                onTap: _requesting ? null : _onConnectTap,
                trailing: _requesting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NotelColors.primary,
                        ),
                      )
                    : null,
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  "You've connected every supported tracker.",
                  style: TextStyle(
                    color: Color(0x807A8FAF),
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: NotelColors.error,
                  fontSize: 13,
                ),
              ),
            ],
            // HRV grant visibility: a partial grant names the data
            // types that are not shared + the exact remedy (plain
            // language, STALE_GRANT copy pattern — no codes).
            if (status == HealthConnectStatus.partiallyConnected &&
                _missingLabels.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                HealthConnectService.missingPermissionsMessage(
                    _missingLabels),
                style: const TextStyle(
                  color: NotelColors.warning,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 24),
            _SectionLabel('Unavailable'),
            const SizedBox(height: 8),
            const _FitbitCard(),
            const SizedBox(height: 32),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'How to connect a tracker',
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Most trackers (Fitbit, Garmin, Samsung) sync their data to a central hub like Health Connect. \n\nWe recommend using Android Health (Health Connect) as it acts as a universal bridge for Google Fit, Samsung Health, Oura, and more. This ensures Tabs always has your latest heart rate, sleep phases, and activity patterns.',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 14,
                      height: 20 / 14,
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Fitbit devices can still sync through Health Connect, so your Fitbit data keeps flowing into Tabs that way.',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 14,
                      height: 20 / 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: NotelColors.textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: NotelColors.primary,
          ),
        ),
      ),
    );
  }
}

class _ConnectionItem extends StatelessWidget {
  final Widget logo;
  final String name;
  final String statusText;
  final Color statusColor;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _ConnectionItem({
    required this.logo,
    required this.name,
    required this.statusText,
    required this.statusColor,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.6 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: NotelColors.legacyDarkHairlineFaint,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: logo,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          statusText,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // The chevron advertises a tap: show it ONLY on a
                  // row that actually has one. The disabled
                  // "Not available on this device" row (onTap null)
                  // previously rendered one too — the same dishonest
                  // affordance class as the dead Connected tap.
                  trailing ??
                      (onTap == null
                          ? const SizedBox.shrink()
                          : Icon(
                              Icons.chevron_right,
                              color: NotelColors.textSecondary
                                  .withValues(alpha: 0.5),
                              size: 20,
                            )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HealthConnectLogo extends StatelessWidget {
  const _HealthConnectLogo();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/ic_health_connect.png',
      width: 28,
      height: 28,
      errorBuilder: (_, _, _) => const Icon(
        Icons.favorite,
        color: NotelColors.primary,
        size: 24,
      ),
    );
  }
}

/// Port of the native FitbitLogo(): teal dot-grid, 24dp.
class _FitbitLogo extends StatelessWidget {
  const _FitbitLogo();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(24, 24),
      painter: _FitbitLogoPainter(),
    );
  }
}

class _FitbitLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const color = Color(0xFF00B0B9);
    final dotRadius = 2 * size.width / 24;
    final spacing = 5 * size.width / 24;
    final paint = Paint()..color = color;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final points = [
      Offset(cx, cy),
      Offset(cx - spacing, cy),
      Offset(cx + spacing, cy),
      Offset(cx - spacing * 2, cy),
      Offset(cx + spacing * 2, cy),
      Offset(cx, cy - spacing),
      Offset(cx, cy + spacing),
      Offset(cx - spacing, cy - spacing),
      Offset(cx + spacing, cy - spacing),
      Offset(cx - spacing, cy + spacing),
      Offset(cx + spacing, cy + spacing),
      Offset(cx, cy - spacing * 2),
      Offset(cx, cy + spacing * 2),
    ];
    for (final p in points) {
      canvas.drawCircle(p, dotRadius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FitbitCard extends StatelessWidget {
  const _FitbitCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: NotelColors.legacyDarkHairlineFaint,
                    shape: BoxShape.circle,
                  ),
                  child: Center(child: _FitbitLogo()),
                ),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fitbit (Direct Sync)',
                      style: TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'No longer available',
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            'Google retired the Fitbit Web API, so direct syncing from Fitbit is no longer possible. Your previously saved history stays in Tabs. Health Connect keeps working as before.',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
              height: 18 / 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ManageSheet extends StatelessWidget {
  final HealthConnectStatus status;

  /// Stale-grant presentation (Juno ruling #4/#5): the status line
  /// names the connection problem and its one receipted consequence,
  /// and the sheet carries the full recovery steps — the single
  /// source is [HealthConnectService.staleGrantMessage].
  final bool isConnectionProblem;
  final Future<void> Function() onGrantRemaining;
  final Future<void> Function() onManageSystem;

  const _ManageSheet({
    required this.status,
    required this.onGrantRemaining,
    required this.onManageSystem,
    this.isConnectionProblem = false,
  });

  @override
  Widget build(BuildContext context) {
    final isPartial = !isConnectionProblem &&
        status == HealthConnectStatus.partiallyConnected;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: NotelColors.legacyDarkHairlineFaint,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const _HealthConnectLogo(),
          ),
          const SizedBox(height: 16),
          const Text(
            'Android Health (Google Fit, Samsung)',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
            textAlign: TextAlign.center,
          ),
          Text(
            isConnectionProblem
                ? "Connection problem: Tabs can't read your health data "
                    'right now.'
                : isPartial
                    ? 'Partially connected'
                    : 'Connected',
            style: TextStyle(
              color: isConnectionProblem
                  ? NotelColors.error
                  : isPartial
                      ? NotelColors.warning
                      : NotelColors.success,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
          if (isConnectionProblem) ...[
            const SizedBox(height: 24),
            const Text(
              HealthConnectService.staleGrantMessage,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
                height: 18 / 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (isPartial) ...[
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                color: NotelColors.error.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: NotelColors.error.withValues(alpha: 0.2),
                ),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    'New Metrics Available!',
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Tabs now supports Blood Oxygen, Resting HR, and Breathing Rate, but they require additional permissions.',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () => onGrantRemaining(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Grant New Permissions',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: isPartial || isConnectionProblem ? 24 : 48),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => onManageSystem(),
              child: const Text(
                'Manage system permissions',
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          if (!isConnectionProblem) ...[
            const SizedBox(height: 32),
            Text(
              'Your connection is managed in Health Connect. To stop '
              'Tabs from reading your health data, tap Manage system '
              'permissions and remove access for Tabs there.',
              style: TextStyle(
                color: NotelColors.textSecondary.withValues(alpha: 0.7),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

/// The Apple Health row's logo: the heart glyph in the same disc
/// the Android row's Health Connect logo sits in. (No Health
/// Connect asset renders on iOS.)
class _AppleHealthLogo extends StatelessWidget {
  const _AppleHealthLogo();

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.favorite,
      color: NotelColors.primary,
      size: 24,
    );
  }
}

/// Chunk 5 — the iOS detail sheet (Juno §1): one sheet for States
/// 1–3, every string from [IosHealthCopy] verbatim. State 4 never
/// opens this sheet (its row is disabled).
class _IosHealthSheet extends StatelessWidget {
  final IosHealthAvailability availability;
  final bool requesting;
  final Future<void> Function() onConnect;
  final Future<void> Function() onCheckAgain;
  final Future<void> Function() onManage;

  const _IosHealthSheet({
    required this.availability,
    required this.requesting,
    required this.onConnect,
    required this.onCheckAgain,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final state = availability.state;
    final isConnected = state == IosHealthAvailabilityState.connected;
    final isNoData = state == IosHealthAvailabilityState.noDataYet;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: NotelColors.legacyDarkHairlineFaint,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const _AppleHealthLogo(),
          ),
          const SizedBox(height: 16),
          const Text(
            IosHealthCopy.rowName,
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
            textAlign: TextAlign.center,
          ),
          Text(
            IosHealthCopy.statusLine(state),
            style: TextStyle(
              color: isConnected
                  ? NotelColors.success
                  : NotelColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            isConnected
                ? IosHealthCopy.state2Body
                : isNoData
                    ? IosHealthCopy.state3Body
                    : IosHealthCopy.state1Body,
            style: const TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
              height: 18 / 13,
            ),
            textAlign: TextAlign.center,
          ),
          if (isNoData) ...[
            const SizedBox(height: 12),
            const Text(
              IosHealthCopy.state3Secondary,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
                height: 18 / 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          if (isConnected)
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => onManage(),
                child: const Text(
                  IosHealthCopy.state2ManageButton,
                  style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            )
          else if (isNoData)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => onCheckAgain(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  IosHealthCopy.state3Button,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: requesting ? null : () => onConnect(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  IosHealthCopy.state1Button,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          if (isConnected) ...[
            const SizedBox(height: 32),
            Text(
              IosHealthCopy.state2Footer,
              style: TextStyle(
                color: NotelColors.textSecondary.withValues(alpha: 0.7),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
