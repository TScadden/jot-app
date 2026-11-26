import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/onboarding_resume_gate.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/voice_input.dart';
import 'package:tabs_lab/src/features/billing/billing_panel.dart';
import 'package:tabs_lab/src/features/onboarding/gems_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/membership_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_flow.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/features/onboarding/post_onboarding_notification_card.dart';
import 'package:tabs_lab/src/features/onboarding/profile_setup_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Flow3 (Nov 19, 2026) — onboarding redesign tests, incl. the two
/// coordinator self-check cautions:
/// (a) resume advance is ONE-SHOT per login session;
/// (b) the membership billing gate routes needsVerification to
///     the VerifyEmailGate FIRST, never the subscriber panel.

OnboardingStore fakeStore(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

class FakeBackend extends TabsBackend {
  @override
  Future<Map<String, dynamic>?> fetchProfile() async => null;
  @override
  Future<bool> fetchIsUnlimited() async => false;
  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async => true;
}

class FakeHC extends HealthConnectService {
  @override
  Future<bool> hasPersistedConnection() async => false;
  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.notConnected;
  @override
  Future<Set<String>> requestPermissions() async => const {};
  @override
  Future<void> openHealthConnectSettings() async {}
}

class FakeVoice extends VoiceInput {
  @override
  Future<String> startVoiceInput() async =>
      'dictated words from the fake recognizer path';
}

Widget wrap(Widget child) => MaterialApp(home: child);

int filledSegments(WidgetTester tester) {
  var filled = 0;
  for (var i = 1; i <= OnboardingProgressBar.totalSegments; i++) {
    final container = tester.widget<Container>(
        find.byKey(ValueKey('onboarding_progress_segment_$i')));
    final decoration = container.decoration! as BoxDecoration;
    if (decoration.color == NotelColors.primary) filled++;
  }
  return filled;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pinned chrome', () {
    testWidgets('no progress bar on the sign-up (welcome) screen',
        (tester) async {
      await tester.pumpWidget(wrap(
          WelcomeScreen(onRegister: () {}, onLogin: () {})));
      await tester.pump();
      expect(find.byKey(const ValueKey('onboarding_progress_bar')),
          findsNothing);
      expect(find.text('Register'), findsOneWidget);
      expect(find.text('Log In'), findsOneWidget);
    });

    testWidgets('bar segment fills per setup step', (tester) async {
      final cases = <(OnboardingStep, int)>[
        (OnboardingStep.consent, 1),
        (OnboardingStep.profileSetup, 2),
        (OnboardingStep.conditions, 3),
        (OnboardingStep.connections, 4),
        (OnboardingStep.gems, 5),
        (OnboardingStep.membership, 6),
      ];
      for (final (step, expected) in cases) {
        await tester.pumpWidget(wrap(OnboardingFlow(
          initialStep: step,
          onboardingStore: fakeStore({}),
          backend: FakeBackend(),
          healthConnectService: FakeHC(),
          onComplete: () {},
          onDeclineConsent: () {},
        )));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('onboarding_progress_bar')),
          findsOneWidget,
          reason: 'step $step',
        );
        expect(filledSegments(tester), expected, reason: 'step $step');
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('profile step', () {
    testWidgets(
        'no skip affordance, shows Can\'t skip, example placeholder, mic',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(ProfileSetupScreen(
        onBack: () {},
        onNavigateNext: () {},
        onboardingStore: fakeStore({}),
        backend: FakeBackend(),
        voiceInput: FakeVoice(),
      )));
      await tester.pump();
      expect(find.text("Can't skip"), findsOneWidget);
      // The header trailing label is non-interactive text; there is
      // no Skip button anywhere on the step.
      expect(find.widgetWithText(TextButton, 'Skip'), findsNothing);
      expect(find.text("Let's get you set up!"), findsOneWidget);
      expect(
        find.textContaining(
            'Example: I have POTS and chronic migraines.'),
        findsOneWidget,
      );
      expect(find.text('Tap the mic to talk'), findsOneWidget);
      expect(find.byKey(const ValueKey('profile_mic_button')),
          findsOneWidget);
      expect(
        find.text('You can also add documents from your doctors'),
        findsOneWidget,
      );
      expect(
        find.text('Tabs builds your tracking categories from what '
            'you write here, and your coach uses it from day one.'),
        findsOneWidget,
      );
      // Mic appends dictated text through the VoiceInput path.
      await tester.ensureVisible(
          find.byKey(const ValueKey('profile_mic_button')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('profile_mic_button')));
      await tester.pump();
      expect(find.textContaining('dictated words'), findsOneWidget);
    });
  });

  group('connections step', () {
    Future<void> pumpFlow(WidgetTester tester) async {
      await tester.pumpWidget(wrap(OnboardingFlow(
        initialStep: OnboardingStep.connections,
        onboardingStore: fakeStore({}),
        backend: FakeBackend(),
        healthConnectService: FakeHC(),
        onComplete: () {},
        onDeclineConsent: () {},
      )));
      await tester.pump();
    }

    testWidgets('shipped body copy drops the AI-personalize clause',
        (tester) async {
      await pumpFlow(tester);
      expect(find.text('Sync your heart rate and sleep data.'),
          findsOneWidget);
      expect(find.textContaining('personalize your insights'),
          findsNothing);
      expect(find.text('This is what powers your Daily Score.'),
          findsOneWidget);
    });

    testWidgets(
        'skip opens the warning dialog; Connect instead stays; '
        'Skip anyway advances to gems', (tester) async {
      await pumpFlow(tester);
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.text('Skip Health Connect?'), findsOneWidget);
      expect(find.text('Heart rate'), findsWidgets);
      expect(find.text('HRV'), findsOneWidget);
      expect(
        find.textContaining('So there is no Daily Score'),
        findsOneWidget,
      );
      // Connect instead: dismisses, stays on connections.
      await tester.tap(find.text('Connect instead'));
      await tester.pumpAndSettle();
      expect(find.text('Skip Health Connect?'), findsNothing);
      expect(find.text('Connect Health Data'), findsWidgets);
      // Skip anyway: proceeds to the gems step.
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip anyway'));
      await tester.pumpAndSettle();
      expect(find.byType(GemsOnboardingScreen), findsOneWidget);
    });
  });

  group('gems step', () {
    testWidgets('three cards with verbatim copy, no progress dots',
        (tester) async {
      var continued = false;
      await tester.pumpWidget(wrap(GemsOnboardingScreen(
        onBack: () {},
        onContinue: () => continued = true,
      )));
      await tester.pump();
      expect(find.text('STREAKS, FREEZES & GEMS'), findsOneWidget);
      expect(find.text('Three little things that help you stick with it.'),
          findsOneWidget);
      expect(find.text('Streaks'), findsOneWidget);
      expect(
        find.text('Finish your Daily Summary each day and your '
            'streak grows. One day at a time.'),
        findsOneWidget,
      );
      expect(find.text('Streak Freezes'), findsOneWidget);
      expect(
        find.text('Miss a day? A freeze covers it, so your streak '
            'stays alive. You get one free every month, and you '
            'can buy more.'),
        findsOneWidget,
      );
      expect(find.text('Gems'), findsOneWidget);
      expect(
        find.text('Finish your day to earn 5 gems. Streak '
            'milestones and perfect weeks pay bonus gems. Trade '
            '300 gems for a streak freeze.'),
        findsOneWidget,
      );
      // No progress dots: the only progress indicator is the
      // pinned segment bar at 5/6 — no dot indicators anywhere.
      expect(find.byType(OnboardingProgressBar), findsOneWidget);
      expect(filledSegments(tester), 5);
      await tester.tap(find.text('Got it'));
      expect(continued, isTrue);
    });
  });

  group('membership step', () {
    testWidgets('prices, badges, compare table, trial button',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(MembershipOnboardingScreen(
        onBack: () {},
        onSkip: () {},
        backend: FakeBackend(),
      )));
      await tester.pump();
      expect(find.text('Unlock Tabs Premium'), findsOneWidget);
      expect(find.text('Monthly Plan'), findsOneWidget);
      expect(find.text(r'$5.99 / month'), findsOneWidget);
      expect(find.text('7-DAY FREE TRIAL'), findsOneWidget);
      expect(find.text('Yearly Plan'), findsOneWidget);
      expect(find.text(r'$39.99 / year'), findsOneWidget);
      expect(find.text('SAVE 44% · BEST VALUE'), findsOneWidget);
      expect(find.text('Pricing shown in Google Play'), findsNothing);
      expect(
          find.byKey(const ValueKey('membership_compare_table')),
          findsOneWidget);
      expect(find.text('Compare'), findsOneWidget);
      expect(find.text('Daily tracking, streaks & gems'), findsOneWidget);
      expect(find.text('Progress reports'), findsOneWidget);
      expect(find.text('Use free account for now'), findsOneWidget);
      expect(find.text('Start 7-Day Free Trial'), findsOneWidget);
      // Yearly selection: the button follows the plan (pre-flow3
      // subscribe label — flagged in the report).
      await tester.ensureVisible(find.text('Yearly Plan'));
      await tester.pump();
      await tester.tap(find.text('Yearly Plan'));
      await tester.pump();
      expect(find.text('Subscribe with Google Play'), findsOneWidget);
    });

    testWidgets(
        'unverified account sees the VerifyEmailGate, never the '
        'subscriber panel or purchase cards (caution b)',
        (tester) async {
      await tester.pumpWidget(wrap(MembershipOnboardingScreen(
        onBack: () {},
        onSkip: () {},
        backend: FakeBackend(),
        emailVerified: false,
      )));
      await tester.pump();
      expect(find.byType(VerifyEmailGate), findsOneWidget);
      expect(find.text("You're Premium"), findsNothing);
      expect(find.text('Monthly Plan'), findsNothing);
      expect(find.text('Start 7-Day Free Trial'), findsNothing);
    });
  });

  group('BillingPanel branch selection (caution b)', () {
    Future<void> pumpPanel(
        WidgetTester tester, BillingGateState state) async {
      await tester.pumpWidget(wrap(Scaffold(
        body: BillingPanel(
          state: state,
          purchasableChild: const Text('PURCHASABLE_CHILD'),
        ),
      )));
      await tester.pump();
    }

    testWidgets('needsVerification → VerifyEmailGate first',
        (tester) async {
      await pumpPanel(tester, BillingGateState.needsVerification);
      expect(find.byType(VerifyEmailGate), findsOneWidget);
      expect(find.text("You're Premium"), findsNothing);
      expect(find.text('PURCHASABLE_CHILD'), findsNothing);
    });

    testWidgets('activeSubscriber → subscriber panel', (tester) async {
      await pumpPanel(tester, BillingGateState.activeSubscriber);
      expect(find.text("You're Premium"), findsOneWidget);
      expect(find.text('Manage Subscription'), findsOneWidget);
      expect(find.byType(VerifyEmailGate), findsNothing);
    });

    testWidgets('signedOut → sign-in panel', (tester) async {
      await pumpPanel(tester, BillingGateState.signedOut);
      expect(find.text('Sign in to see plans'), findsOneWidget);
      expect(find.byType(VerifyEmailGate), findsNothing);
    });

    testWidgets('purchasable → the purchase child', (tester) async {
      await pumpPanel(tester, BillingGateState.purchasable);
      expect(find.text('PURCHASABLE_CHILD'), findsOneWidget);
      expect(find.byType(VerifyEmailGate), findsNothing);
    });
  });

  group('post-onboarding notification card', () {
    testWidgets('card copy, no banned phrase, buttons fire',
        (tester) async {
      var allowed = false;
      var denied = false;
      await tester.pumpWidget(wrap(Scaffold(
        body: PostOnboardingNotificationCard(
          onAllow: () => allowed = true,
          onDontAllow: () => denied = true,
        ),
      )));
      await tester.pump();
      expect(find.text('Allow Tabs to send you notifications?'),
          findsOneWidget);
      expect(
        find.text('Your evening check-in reminder and habit nudges.'),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing else.'), findsNothing);
      await tester.tap(find.text('Allow'));
      expect(allowed, isTrue);
      await tester.tap(find.text("Don't Allow"));
      expect(denied, isTrue);
    });

    test('gate: only flow3 completers, only once', () async {
      final old = <String, String>{};
      expect(
          await shouldShowPostOnboardingNotificationCard(fakeStore(old)),
          isFalse,
          reason: 'older-flow user: no flow3 flag, never shown');
      final fresh = <String, String>{
        OnboardingStore.flow3CompletedKey: 'true',
      };
      final store = fakeStore(fresh);
      expect(await shouldShowPostOnboardingNotificationCard(store),
          isTrue);
      await store.setFlow3NotifPromptShown(true);
      expect(await shouldShowPostOnboardingNotificationCard(store),
          isFalse,
          reason: 'not again after it was shown once');
    });
  });

  group('resume (caution a — one-shot per login session)', () {
    setUp(() => OnboardingResumeGate.startNewSession());

    test(
        'REGRESSION: login advances once; exit to Welcome + login '
        'again in the same session does NOT advance again',
        () async {
      // Marker at Conditions (index 2), profile text present.
      final map = <String, String>{
        OnboardingStore.stepMarkerKey: '2',
        OnboardingStore.userContextKey:
            'enough context words here to pass the profile clamp check',
      };
      final coordinator = OnboardingResumeCoordinator(fakeStore(map));
      // First login in the session: resume fires at the left step.
      expect(await coordinator.advanceOnLogin(), 2);
      // The user backs out to Welcome and logs in again in the
      // SAME session: no second auto-advance. (Pre-fix semantics —
      // marker present → advance — would return 2 here and fail.)
      expect(await coordinator.advanceOnLogin(), isNull);
      expect(await coordinator.advanceOnLogin(), isNull);
      // A genuinely new login session may resume again.
      OnboardingResumeGate.startNewSession();
      expect(await coordinator.advanceOnLogin(), 2);
    });

    test('no marker or completed onboarding → no advance', () async {
      final empty = OnboardingResumeCoordinator(fakeStore({}));
      expect(await empty.advanceOnLogin(), isNull);
      OnboardingResumeGate.startNewSession();
      final done = OnboardingResumeCoordinator(fakeStore({
        OnboardingStore.stepMarkerKey: '3',
        OnboardingStore.onboardingCompleteKey: 'true',
      }));
      expect(await done.advanceOnLogin(), isNull);
    });

    test('m1 clamp: marker past Profile without profile text '
        'clamps back to Profile', () async {
      final coordinator = OnboardingResumeCoordinator(fakeStore({
        OnboardingStore.stepMarkerKey: '5',
      }));
      expect(await coordinator.advanceOnLogin(),
          OnboardingStep.profileSetup.index);
    });

    testWidgets(
        'flow writes the resume marker as steps advance',
        (tester) async {
      final map = <String, String>{};
      final store = fakeStore(map);
      await tester.pumpWidget(wrap(OnboardingFlow(
        initialStep: OnboardingStep.consent,
        onboardingStore: store,
        backend: FakeBackend(),
        healthConnectService: FakeHC(),
        onComplete: () {},
        onDeclineConsent: () {},
      )));
      await tester.pump();
      expect(map[OnboardingStore.stepMarkerKey], '0');
      await tester.tap(find.text('I consent'));
      await tester.pump();
      expect(map[OnboardingStore.stepMarkerKey], '1');
      expect(find.byType(ProfileSetupScreen), findsOneWidget);
    });
  });
}
