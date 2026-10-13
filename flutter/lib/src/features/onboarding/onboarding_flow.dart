import 'package:flutter/material.dart';

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
/// [initialStep] is where a cold start resumes (AppFlow's startup
/// resolver maps the stored flags to a step, exactly like native's
/// splash routing); a fresh registration always starts at consent.
class OnboardingFlow extends StatefulWidget {
  final OnboardingStep initialStep;
  final OnboardingStore? onboardingStore;
  final TabsBackend? backend;
  final HealthConnectService? healthConnectService;
  final ReminderNotificationService? notificationService;

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
    return switch (_step) {
      OnboardingStep.consent => OnboardingConsentScreen(
          // Entry step: native's stack is cleared beneath consent,
          // so back has nowhere to go (see the class doc).
          onBack: () {},
          onConsent: _onConsent,
          onDecline: widget.onDeclineConsent,
        ),
      OnboardingStep.consultationIntro => ConsultationIntroScreen(
          onBack: () => _backTo(OnboardingStep.consent),
          onContinue: _onConsultationContinue,
        ),
      OnboardingStep.profileSetup => ProfileSetupScreen(
          onBack: () => _backTo(OnboardingStep.consultationIntro),
          onNavigateNext: () => _go(OnboardingStep.conditions),
          onboardingStore: _store,
          backend: widget.backend,
        ),
      OnboardingStep.conditions => OnboardingConditionsScreen(
          onBack: () => _backTo(OnboardingStep.profileSetup),
          onNavigateNext: () => _go(OnboardingStep.notifications),
          onSkip: () => _go(OnboardingStep.notifications),
          onboardingStore: _store,
          backend: widget.backend,
        ),
      OnboardingStep.notifications => NotificationOnboardingScreen(
          onBack: () => _backTo(OnboardingStep.conditions),
          onNavigateNext: () => _go(OnboardingStep.connections),
          onSkip: () => _go(OnboardingStep.connections),
          notificationService: widget.notificationService,
        ),
      OnboardingStep.connections => OnboardingConnectionsScreen(
          onBack: () => _backTo(OnboardingStep.notifications),
          onNavigateNext: () => _go(OnboardingStep.membership),
          healthConnectService: widget.healthConnectService,
        ),
      OnboardingStep.membership => MembershipOnboardingScreen(
          onBack: () => _backTo(OnboardingStep.connections),
          onSkip: () => _go(OnboardingStep.setupLoading),
          backend: widget.backend,
        ),
      OnboardingStep.setupLoading => SetupLoadingScreen(
          onNavigateMain: widget.onComplete,
          onboardingStore: _store,
          backend: widget.backend,
        ),
    };
  }
}
