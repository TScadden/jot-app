import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/features/connections/health_connect_disclosure.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native's onboarding `ConnectionsScreen.kt`
/// (route `connections` — NOT the post-onboarding DataConnections
/// screen), the Health Connect step.
///
/// Native behavior:
/// - Title "Connect Health Data", body "Sync your heart rate and
///   sleep data so AI can personalize your insights."
/// - Already connected → a success card "Looks like you are already
///   connected!" and the bottom button reads "Next".
/// - Not connected → a primary "Connect Health Data" button (launches
///   the Health Connect permission UI) plus a "Manage access in
///   settings" text button (opens Health Connect settings); the
///   bottom button reads "Skip for now". Both bottom labels advance
///   to the membership step — connecting is optional.
///
/// Juno MF-3 (standing): the Flutter build shows the app's prominent
/// Health Connect disclosure ([showHealthConnectDisclosure] — the
/// exact dialog the Connections screen uses) BEFORE any system
/// permission UI. Native launches the permission UI directly; the
/// disclosure-first order is a Play policy requirement and the task's
/// explicit instruction, so it wins over byte-parity here. "Not now"
/// never triggers a permission request.
class OnboardingConnectionsScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onNavigateNext;
  final HealthConnectService? healthConnectService;

  const OnboardingConnectionsScreen({
    super.key,
    required this.onBack,
    required this.onNavigateNext,
    this.healthConnectService,
  });

  @override
  State<OnboardingConnectionsScreen> createState() =>
      _OnboardingConnectionsScreenState();
}

class _OnboardingConnectionsScreenState
    extends State<OnboardingConnectionsScreen> {
  late final HealthConnectService _service;
  HealthConnectStatus? _status;
  bool _requesting = false;
  String? _error;

  /// Chunk 5/6 — the iOS availability snapshot, used instead of
  /// the Android status on iOS (HealthKit has no grant list for
  /// [HealthConnectService.getStatus] to read). The FLOW is wired
  /// here (probe + request through the same service surface); the
  /// iOS copy on this screen is Juno's signed onboarding addendum
  /// (2026-11-22), implemented verbatim.
  IosHealthAvailability? _iosAvailability;

  bool get _connected => _service.isIOS
      ? _iosAvailability?.state == IosHealthAvailabilityState.connected
      : _status == HealthConnectStatus.connected;

  /// Juno onboarding addendum §3 — State 4 on iOS: HealthKit
  /// unavailable on this device. The connect-button area is
  /// replaced by the signed unavailable string and the bottom
  /// button becomes a plain Next (no skip dialog — its premise is
  /// false where the connection cannot exist).
  bool get _iosUnavailable =>
      _service.isIOS &&
      _iosAvailability?.state == IosHealthAvailabilityState.unavailable;

  @override
  void initState() {
    super.initState();
    _service = widget.healthConnectService ?? HealthConnectService();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    if (_service.isIOS) {
      final snapshot = await _service.probeIosAvailability();
      if (mounted) setState(() => _iosAvailability = snapshot);
      return;
    }
    try {
      final persisted = await _service.hasPersistedConnection();
      if (mounted && persisted) {
        setState(() => _status = HealthConnectStatus.connected);
      }
    } catch (_) {}
    try {
      final status = await _service.getStatus();
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } on HealthConnectException catch (e) {
      if (mounted) {
        setState(() {
          _status ??= HealthConnectStatus.notConnected;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _onConnectTap() async {
    if (_requesting) return;
    if (_service.isIOS) {
      // Chunk 6 — the iOS request flow through the same surface:
      // the read-only HealthKit authorization sheet, then a
      // re-probe. No Health Connect disclosure dialog on iOS (that
      // dialog is the Android/Play prominent disclosure; the iOS
      // rationale lives in the system purpose string and Juno's
      // Connections detail sheet). A completed request is never an
      // error here: shared-nothing lands on "No data yet" in the
      // availability surfaces, and this step simply stays
      // not-connected with Skip available, exactly like a declined
      // Android grant.
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
      final snapshot = await _service.probeIosAvailability();
      if (mounted) setState(() => _iosAvailability = snapshot);
      return;
    }
    // MF-3: prominent disclosure BEFORE the system permission UI.
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
        if (granted.containsAll(HealthConnectService.requiredPermissions)) {
          _status = HealthConnectStatus.connected;
        } else if (granted.isEmpty) {
          _error = 'No permissions were granted.';
          _status = HealthConnectStatus.notConnected;
        } else {
          _status = HealthConnectStatus.partiallyConnected;
        }
      });
    } on HealthConnectException catch (e) {
      if (mounted) {
        setState(() {
          _requesting = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _onManageInSettings() async {
    try {
      await _service.openHealthConnectSettings();
    } on HealthConnectException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// Flow3 skip warning (mock flow3_05_connections_skip_warning):
  /// tapping "Skip for now" shows this FIRST. "Connect instead"
  /// (primary) dismisses and stays; "Skip anyway" proceeds.
  /// Bullets are DRAWN dot markers, not "•" text glyphs (Juno
  /// ruling — harness tofu risk). The "So there is no Daily
  /// Score…" line is founder-dictated verbatim and ships as-is.
  Future<void> _onSkipTap() async {
    // Juno onboarding addendum §1 (#4/#5/#6): the dialog's title,
    // intro, and closing sentence fork on iOS — the bullets and
    // the founder-dictated first closing sentence stay shared and
    // byte-identical on both platforms.
    final isIOS = _service.isIOS;
    final skip = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('connections_skip_warning'),
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: Text(
          isIOS ? 'Skip Apple Health?' : 'Skip Health Connect?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isIOS
                  ? "Without it, Tabs can't read your:"
                  : "Without it, Tabs can't sync in your:",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            for (final item in const ['Heart rate', 'Sleep', 'HRV'])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: NotelColors.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      item,
                      style: TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              // First sentence founder-dictated, byte-identical on
              // both platforms; only the final sentence forks
              // (addendum §1 #6).
              isIOS
                  ? 'So there is no Daily Score, and your trends and AI '
                      'insights only use what you log by hand. You can '
                      'connect anytime in Tabs: Settings, then Connected '
                      'Apps, then Apple Health.'
                  : 'So there is no Daily Score, and your trends and AI '
                      'insights only use what you log by hand. You can '
                      'connect anytime in Settings.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
                height: 20 / 14,
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  style: FilledButton.styleFrom(
                    backgroundColor: NotelColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text(
                    'Connect instead',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(
                  'Skip anyway',
                  style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (skip == true && mounted) widget.onNavigateNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OnboardingHeader(onBack: widget.onBack),
              ),
              const SizedBox(height: 12),
              const OnboardingProgressBar(currentSegment: 4),
              // Flow3: content vertically centered; "Skip for now"
              // stays pinned at the bottom.
              Expanded(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight:
                          MediaQuery.of(context).size.height * 0.62,
                    ),
                    child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 32),
                      // Three icon discs over a soft purple glow.
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              NotelColors.primary.withValues(alpha: 0.30),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _IconDisc(
                              icon: Icons.favorite,
                              color: Color(0xFFEC407A),
                            ),
                            SizedBox(width: 16),
                            _IconDisc(
                              icon: Icons.nightlight_round,
                              color: Color(0xFF5C6BC0),
                            ),
                            SizedBox(width: 16),
                            _IconDisc(
                              icon: Icons.monitor_heart,
                              color: NotelColors.primary,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Juno onboarding addendum §1 (#1/#3): title
                      // and first body line fork on iOS.
                      Text(
                        _service.isIOS
                            ? 'Connect Apple Health'
                            : 'Connect Health Data',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Juno ruling (fix): the "so AI can personalize
                      // your insights" clause is DROPPED. Shipped
                      // body is the short line + the separate Daily
                      // Score line.
                      Text(
                        _service.isIOS
                            ? 'Read your heart rate and sleep data '
                                'from Apple Health.'
                            : 'Sync your heart rate and sleep data.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: NotelColors.textSecondary,
                          height: 22 / 15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'This is what powers your Daily Score.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: NotelColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 32),
              if (_connected)
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: NotelColors.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: NotelColors.cardBorder),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Looks like you are already connected!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NotelColors.success,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                )
              else if (_iosUnavailable) ...[
                // Juno onboarding addendum §3: the signed State 4
                // string replaces the connect-button area verbatim.
                Text(
                  'Apple Health is not available on this device, so '
                  'Tabs cannot read health data from it here. Your '
                  'logging, check-ins, and notes in Tabs still work.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: NotelColors.textSecondary,
                    height: 22 / 15,
                  ),
                ),
              ] else ...[
                OnboardingPrimaryButton(
                  // Addendum §1 #2: same signed literal as the title.
                  label: _service.isIOS
                      ? 'Connect Apple Health'
                      : 'Connect Health Data',
                  onPressed: _requesting ? null : _onConnectTap,
                ),
                // The manage-in-settings hand-off opens Health
                // Connect settings, an Android-only surface; on iOS
                // there is no analogue to hand off to (access is
                // managed in the Health app, per Juno's Connections
                // copy), so the button is Android-only.
                if (!_service.isIOS) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _onManageInSettings,
                    child: Text(
                      'Manage access in Settings',
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: NotelColors.error,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      const SizedBox(height: 32),
                    ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.only(bottom: kOnboardingBottomPadding),
                child: OnboardingPrimaryButton(
                  // Connected → Next. iOS State 4 (addendum §3) →
                  // also Next, advancing directly with NO skip
                  // dialog. Otherwise → "Skip for now" and the
                  // skip-warning dialog FIRST.
                  label:
                      _connected || _iosUnavailable ? 'Next' : 'Skip for now',
                  onPressed: _connected || _iosUnavailable
                      ? widget.onNavigateNext
                      : _onSkipTap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the three Health Connect icon discs (heart rate / sleep
/// / HRV) over the connections glow.
class _IconDisc extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _IconDisc({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      child: Icon(icon, color: Colors.white, size: 28),
    );
  }
}
