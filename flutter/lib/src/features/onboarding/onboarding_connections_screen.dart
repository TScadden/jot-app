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

  bool get _connected => _status == HealthConnectStatus.connected;

  @override
  void initState() {
    super.initState();
    _service = widget.healthConnectService ?? HealthConnectService();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
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
          _error = '[${e.code}] ${e.message}';
        });
      }
    }
  }

  Future<void> _onConnectTap() async {
    if (_requesting) return;
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
          _error = '[${e.code}] ${e.message}';
        });
      }
    }
  }

  Future<void> _onManageInSettings() async {
    try {
      await _service.openHealthConnectSettings();
    } on HealthConnectException catch (e) {
      if (mounted) setState(() => _error = '[${e.code}] ${e.message}');
    }
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
              const SizedBox(height: 24),
              const Text(
                'Connect Health Data',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: NotelColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Sync your heart rate and sleep data so AI can '
                'personalize your insights.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: NotelColors.textSecondary,
                  height: 22 / 15,
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
                  child: const Text(
                    'Looks like you are already connected!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NotelColors.success,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                )
              else ...[
                OnboardingPrimaryButton(
                  label: 'Connect Health Data',
                  onPressed: _requesting ? null : _onConnectTap,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _onManageInSettings,
                  child: const Text(
                    'Manage access in settings',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: NotelColors.error,
                    fontSize: 13,
                  ),
                ),
              ],
              const Spacer(),
              OnboardingPrimaryButton(
                label: _connected ? 'Next' : 'Skip for now',
                onPressed: widget.onNavigateNext,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
