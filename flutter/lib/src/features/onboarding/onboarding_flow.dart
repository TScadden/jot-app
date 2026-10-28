import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/conditions_screen.dart';
import 'package:tabs_lab/src/features/onboarding/consent_screen.dart';
import 'package:tabs_lab/src/features/onboarding/consultation_intro_screen.dart';
import 'package:tabs_lab/src/features/onboarding/membership_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/notification_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_connections_screen.dart';
import 'package:tabs_lab/src/features/onboarding/profile_setup_screen.dart';
import 'package:tabs_lab/src/features/onboarding/setup_loading_screen.dart';

/// The onboarding steps, in native NavHost order (`MainActivity.kt`):
/// consent → consultation_intro → profile_setup → conditions →
/// notification_onboarding → connections → membership_onboarding →
/// setup_loading → today (home).
enum OnboardingStep {
  consent,
  consultationIntro,
  profileSetup,
  conditions,
  notifications,
  connections,
  membership,
  setupLoading,
}

/// Round 32 — the onboarding flow shell. Owns the step sequence and
/// the flag writes each native route performs in `MainActivity.kt`:
///
/// - consent (onConsent): `setHasConsented(true)` → consultation intro.
/// - consultation intro (onContinue): `setIntroConsultationSeen(true)`
///   → profile setup.
/// - profile setup → conditions → notifications → connections →
///   membership → setup loading (each step owns its own data; see
///   the step files).
/// - setup loading sets `onboarding_complete` itself (native
///   finalizeSetup) and its button fires [onComplete] → home.
///
/// Back walks the sequence in reverse. Native clears the back stack
/// at the login→consent and consent→intro transitions
/// (`popUpTo(...) { inclusive = true }`), so back from those steps
/// exits the flow in native; here the entry step's back is a no-op,
/// matching the effective native behavior, and every later step's
/// back returns to the previous step (native pushes those routes
/// sequentially from profile_setup onward).
///
/// The Android system back follows the SAME path (founder fix,
/// Oct 27, 2026): the steps are body swaps inside AppFlow's single
/// root route, so the build wraps them in a PopScope that runs
/// [_OnboardingFlowState._stepBack] — the one back action every
/// step's arrow also calls — whenever the current step has an
/// in-flow back destination. On consent (the first step) the pop
/// is allowed through instead, so the gesture exits the app rather
/// than trapping the user on the arrow's deliberate no-op;
/// setup loading likewise stays poppable because it carries no
/// back affordance at all (see [_OnboardingFlowState._backTargetFor]).
///
/// [initialStep] is where a cold start resumes (AppFlow's startup
/// resolver maps the stored flags to a step, exactly like native's
/// splash routing); a fresh registration always starts at consent.
class OnboardingFlow extends StatefulWidget {
  final OnboardingStep initialStep;
  final OnboardingStore? onboardingStore;
  final TabsBackend? backend;
  final HealthConnectService? healthConnectService;
  final ReminderNotificationService? notificationService;

  /// The app-owned billing service (single instance), forwarded
  /// to the membership step — consumed there, never constructed
  /// or disposed by the flow or the step.
  final BillingService? billingService;

  /// Fired when setup loading's "Start keeping Tabs" is tapped.
  final VoidCallback onComplete;

  /// Fired when consent is declined via the decline dialog's
  /// "Log Out" (AppFlow clears the session and returns to welcome,
  /// mirroring native's onDecline).
  final VoidCallback onDeclineConsent;

  const OnboardingFlow({
    super.key,
    this.initialStep = OnboardingStep.consent,
    this.onboardingStore,
    this.backend,
    this.healthConnectService,
    this.notificationService,
    this.billingService,
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
  }

  void _go(OnboardingStep step) {
    if (mounted) setState(() => _step = step);
  }

  void _backTo(OnboardingStep step) => _go(step);

  /// The step the in-app back arrow returns to from [step] — the
  /// single source for every step's `onBack` below AND for the
  /// system-back interception in [build], so the two can never
  /// drift apart. Null where the step has no in-flow back
  /// destination: consent is the entry step (its arrow is a
  /// deliberate no-op — native clears the stack beneath it) and
  /// setup loading carries no back affordance at all (it is the
  /// auto-finalizing terminal step; see SetupLoadingScreen).
  OnboardingStep? _backTargetFor(OnboardingStep step) => switch (step) {
        OnboardingStep.consent => null,
        OnboardingStep.consultationIntro => OnboardingStep.consent,
        OnboardingStep.profileSetup => OnboardingStep.consultationIntro,
        OnboardingStep.conditions => OnboardingStep.profileSetup,
        OnboardingStep.notifications => OnboardingStep.conditions,
        OnboardingStep.connections => OnboardingStep.notifications,
        OnboardingStep.membership => OnboardingStep.connections,
        OnboardingStep.setupLoading => null,
      };

  /// The one back action for this flow: every step screen's arrow
  /// and the Android system back both call it, so the gesture
  /// inherits the arrow's exact destination per step. A no-op on
  /// steps whose [_backTargetFor] is null, matching the arrows
  /// there (system back never reaches this on those steps — the
  /// PopScope in [build] lets the pop through instead).
  void _stepBack() {
    final target = _backTargetFor(_step);
    if (target != null) _backTo(target);
  }

  Future<void> _onConsent() async {
    try {
      await _store.setHasConsented(true);
    } catch (_) {}
    _go(OnboardingStep.consultationIntro);
  }

  Future<void> _onConsultationContinue() async {
    try {
      await _store.setIntroConsultationSeen(true);
    } catch (_) {}
    _go(OnboardingStep.profileSetup);
  }

  @override
  Widget build(BuildContext context) {
    // System-back parity with the steps' back arrows (founder fix,
    // Oct 27, 2026): the steps are body swaps inside AppFlow's
    // single root route, so without interception the Navigator has
    // nothing to pop on Android back and the gesture exits the app
    // mid-wizard — while the arrow correctly steps back. Intercept
    // whenever the current step has an in-flow back destination
    // and run [_stepBack], the SAME action the arrow calls. On
    // consent (the first step) and setup loading — the steps with
    // no back destination — the pop goes through: the gesture
    // exits instead of trapping the user (see _backTargetFor).
    final bool interceptBack = _backTargetFor(_step) != null;
    return PopScope(
      canPop: !interceptBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _stepBack();
      },
      child: switch (_step) {
        OnboardingStep.consent => OnboardingConsentScreen(
            // Entry step: native's stack is cleared beneath consent,
            // so back has nowhere to go (see the class doc). The
            // arrow keeps its deliberate no-op (_stepBack is a no-op
            // at consent); only the system gesture is allowed to pop.
            onBack: _stepBack,
            onConsent: _onConsent,
            onDecline: widget.onDeclineConsent,
          ),
        OnboardingStep.consultationIntro => ConsultationIntroScreen(
            onBack: _stepBack,
            onContinue: _onConsultationContinue,
          ),
        OnboardingStep.profileSetup => ProfileSetupScreen(
            onBack: _stepBack,
            onNavigateNext: () => _go(OnboardingStep.conditions),
            onboardingStore: _store,
            backend: widget.backend,
          ),
        OnboardingStep.conditions => OnboardingConditionsScreen(
            onBack: _stepBack,
            onNavigateNext: () => _go(OnboardingStep.notifications),
            onSkip: () => _go(OnboardingStep.notifications),
            onboardingStore: _store,
            backend: widget.backend,
          ),
        OnboardingStep.notifications => NotificationOnboardingScreen(
            onBack: _stepBack,
            onNavigateNext: () => _go(OnboardingStep.connections),
            onSkip: () => _go(OnboardingStep.connections),
            notificationService: widget.notificationService,
          ),
        OnboardingStep.connections => OnboardingConnectionsScreen(
            onBack: _stepBack,
            onNavigateNext: () => _go(OnboardingStep.membership),
            healthConnectService: widget.healthConnectService,
          ),
        OnboardingStep.membership => MembershipOnboardingScreen(
            onBack: _stepBack,
            onSkip: () => _go(OnboardingStep.setupLoading),
            backend: widget.backend,
            billingService: widget.billingService,
          ),
        OnboardingStep.setupLoading => SetupLoadingScreen(
            onNavigateMain: widget.onComplete,
            onboardingStore: _store,
            backend: widget.backend,
          ),
      },
    );
  }
}
