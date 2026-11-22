import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/revenuecat_service.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/onboarding_sync_outbox.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/conditions_screen.dart';
import 'package:tabs_lab/src/features/onboarding/consent_screen.dart';
import 'package:tabs_lab/src/features/onboarding/gems_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/membership_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_connections_screen.dart';
import 'package:tabs_lab/src/features/onboarding/profile_setup_screen.dart';
import 'package:tabs_lab/src/features/onboarding/setup_loading_screen.dart';

/// The flow3 onboarding steps (founder, Nov 19, 2026):
/// consent → profileSetup → conditions → connections → gems →
/// membership → setupLoading → today (home).
///
/// Flow3 changes from the Round 32 sequence:
/// - The consultation-intro interstitial is CUT (its heading
///   folded into Profile).
/// - The notifications STEP is REMOVED — the permission ask is a
///   card over Home on the first post-onboarding landing.
/// - A NEW gems step sits between connections and membership.
/// - Enum order doubles as the persisted resume-marker index
///   (see [OnboardingStore.stepMarkerKey]): consent=0,
///   profileSetup=1, conditions=2, connections=3, gems=4,
///   membership=5, setupLoading=6. Do not reorder.
enum OnboardingStep {
  consent,
  profileSetup,
  conditions,
  connections,
  gems,
  membership,
  setupLoading,
}

/// Flow3 onboarding shell. Owns the step sequence, the flag writes
/// each step performs, and the resume marker: every advance writes
/// the NEXT step's index to [OnboardingStore.setStepMarker], so a
/// user who leaves mid-flow and logs back in resumes at the step
/// they left (the login routing consumes the marker through the
/// one-shot [OnboardingResumeGate] — see onboarding_resume_gate).
///
/// Back walks the sequence in reverse; consent is the entry step
/// and its back is a no-op (the system gesture pops instead), as
/// before. The Android system back follows the same path via the
/// PopScope below.
class OnboardingFlow extends StatefulWidget {
  final OnboardingStep initialStep;
  final OnboardingStore? onboardingStore;
  final TabsBackend? backend;
  final OnboardingSyncOutbox? onboardingSyncOutbox;
  final HealthConnectService? healthConnectService;
  final ReminderNotificationService? notificationService;

  /// The app-owned billing service (single instance), forwarded
  /// to the membership step — consumed there, never constructed
  /// or disposed by the flow or the step.
  final BillingService? billingService;

  /// The app-owned RevenueCat service (single instance, iOS),
  /// forwarded to the membership step beside [billingService] —
  /// consumed there, never constructed or disposed by the flow
  /// or the step.
  final RevenueCatService? revenueCatService;

  /// The account's email-verification state, forwarded to the
  /// membership step's billing gate.
  final bool emailVerified;

  /// Fired when the membership step's VerifyEmailGate is tapped.
  final VoidCallback? onVerifyEmail;

  /// Fired when setup loading's "Start keeping Tabs" is tapped.
  final VoidCallback onComplete;

  /// Fired when consent is declined via the decline dialog's
  /// "Log Out" (AppFlow clears the session and returns to welcome).
  final VoidCallback onDeclineConsent;

  const OnboardingFlow({
    super.key,
    this.initialStep = OnboardingStep.consent,
    this.onboardingStore,
    this.backend,
    this.onboardingSyncOutbox,
    this.healthConnectService,
    this.notificationService,
    this.billingService,
    this.revenueCatService,
    this.emailVerified = true,
    this.onVerifyEmail,
    required this.onComplete,
    required this.onDeclineConsent,
  });

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late final OnboardingStore _store;
  late OnboardingStep _step;

  @override
  void initState() {
    super.initState();
    _store = widget.onboardingStore ?? OnboardingStore();
    _step = widget.initialStep;
    // Entering the flow (fresh or resumed) records where the user
    // currently is, so leaving now still resumes here.
    unawaited(_writeMarker(_step));
  }

  Future<void> _writeMarker(OnboardingStep step) async {
    try {
      await _store.setStepMarker(step.index);
    } catch (_) {}
  }

  void _go(OnboardingStep step) {
    unawaited(_writeMarker(step));
    if (mounted) setState(() => _step = step);
  }

  void _backTo(OnboardingStep step) => _go(step);

  OnboardingStep? _backTargetFor(OnboardingStep step) => switch (step) {
        OnboardingStep.consent => null,
        OnboardingStep.profileSetup => OnboardingStep.consent,
        OnboardingStep.conditions => OnboardingStep.profileSetup,
        OnboardingStep.connections => OnboardingStep.conditions,
        OnboardingStep.gems => OnboardingStep.connections,
        OnboardingStep.membership => OnboardingStep.gems,
        OnboardingStep.setupLoading => OnboardingStep.membership,
      };

  void _stepBack() {
    final target = _backTargetFor(_step);
    if (target != null) _backTo(target);
  }

  Future<void> _onConsent() async {
    try {
      await _store.setHasConsented(true);
      // Legacy flag kept set so older readers (the startup gate's
      // pre-flow3 mapping) still see a coherent state; the intro
      // step itself no longer exists in the flow.
      await _store.setIntroConsultationSeen(true);
    } catch (_) {}
    _go(OnboardingStep.profileSetup);
  }

  /// Setup loading completed: stamp the flow3 completion flag
  /// (gates the one-time notification card on Home) and clear the
  /// resume marker before handing off to AppFlow's completion.
  Future<void> _onSetupComplete() async {
    try {
      await _store.setFlow3Completed(true);
      await _store.clearStepMarker();
    } catch (_) {}
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final bool interceptBack = _backTargetFor(_step) != null;
    return PopScope(
      canPop: !interceptBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _stepBack();
      },
      child: switch (_step) {
        OnboardingStep.consent => OnboardingConsentScreen(
            onBack: _stepBack,
            onConsent: _onConsent,
            onDecline: widget.onDeclineConsent,
          ),
        OnboardingStep.profileSetup => ProfileSetupScreen(
            onBack: _stepBack,
            onNavigateNext: () => _go(OnboardingStep.conditions),
            onboardingStore: _store,
            backend: widget.backend,
          ),
        OnboardingStep.conditions => OnboardingConditionsScreen(
            onBack: _stepBack,
            onNavigateNext: () => _go(OnboardingStep.connections),
            onSkip: () => _go(OnboardingStep.connections),
            onboardingStore: _store,
            backend: widget.backend,
          ),
        OnboardingStep.connections => OnboardingConnectionsScreen(
            onBack: _stepBack,
            onNavigateNext: () => _go(OnboardingStep.gems),
            healthConnectService: widget.healthConnectService,
          ),
        OnboardingStep.gems => GemsOnboardingScreen(
            onBack: _stepBack,
            onContinue: () => _go(OnboardingStep.membership),
          ),
        OnboardingStep.membership => MembershipOnboardingScreen(
            onBack: _stepBack,
            onSkip: () => _go(OnboardingStep.setupLoading),
            backend: widget.backend,
            billingService: widget.billingService,
            revenueCatService: widget.revenueCatService,
            emailVerified: widget.emailVerified,
            onVerifyEmail: widget.onVerifyEmail,
          ),
        OnboardingStep.setupLoading => SetupLoadingScreen(
            onNavigateMain: () => unawaited(_onSetupComplete()),
            onboardingStore: _store,
            backend: widget.backend,
            onboardingSyncOutbox: widget.onboardingSyncOutbox,
          ),
      },
    );
  }
}
