import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/onboarding_sync_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/auth/email_verification_screen.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_flow.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';

import 'onboarding_r32_test.dart' as r32;
import 'test_helpers.dart';

/// Onboarding reorder (Nov 27, 2026) — acceptance tests for the
/// ruled order Welcome → Consent → Profile → Conditions →
/// Connections → Gems → REGISTER → Membership → Setup Loading →
/// Home, under Juno's binding ruling (pre-account defer-sync,
/// carry-forward on register, wipe on login, 30-day expiry,
/// pre-account decline variant, byte-exact copy).

const _contextText =
    'I have POTS and chronic migraines and heat makes everything '
    'worse daily';
const _email = 'new@tabs.app';

OnboardingStore _store(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

/// The flow backend with a full call log (the zero-network
/// evidence surface) and switchable post failures (finalize leg).
class ReorderBackend extends r32.FakeOnboardingBackend {
  final List<String> calls = [];
  bool failPosts = false;
  VerifyEmailOutcome verifyOutcome = const VerifyEmailSuccess();

  ReorderBackend({super.sessionStore});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async {
    calls.add('fetchSyncPull');
    return super.fetchSyncPull();
  }

  @override
  Future<Map<String, dynamic>?> fetchProfile() async {
    calls.add('fetchProfile');
    return super.fetchProfile();
  }

  @override
  Future<bool> fetchIsUnlimited() async {
    calls.add('fetchIsUnlimited');
    return super.fetchIsUnlimited();
  }

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    calls.add('postSyncProfile');
    profilePushes.add(fields);
    return !failPosts;
  }

  @override
  Future<List<String>?> generateCategories(String userContext) async {
    calls.add('generateCategories');
    return super.generateCategories(userContext);
  }

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async {
    calls.add('fetchLogCategories');
    return super.fetchLogCategories();
  }

  @override
  Future<List<QuickLogCategory>?> fetchLogCategoriesOrNull() async =>
      fetchLogCategories();

  @override
  Future<bool> postLogCategories(List<QuickLogCategory> cats) async {
    calls.add('postLogCategories');
    pushedCategories = cats;
    return !failPosts;
  }

  @override
  Future<VerifyEmailOutcome> verifyEmailCode(String code) async {
    calls.add('verifyEmailCode');
    return verifyOutcome;
  }

  @override
  Future<ResendVerificationOutcome> resendVerificationCode() async =>
      const ResendVerificationSent();
}

MockClient _weather() => MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
            200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,'
          '"is_day":1}}',
          200);
    });

AuthApiClient _authApi({bool verified = true, bool login = false}) =>
    AuthApiClient(
      client: MockClient((request) async {
        final isRegister = request.url.path == '/api/auth/register';
        final isLogin = request.url.path == '/api/auth/login';
        if ((login && isLogin) || (!login && isRegister)) {
          return http.Response(
            jsonEncode({
              'token': 'tok',
              'refreshToken': 'ref',
              'email': _email,
              'emailVerified': verified,
            }),
            200,
          );
        }
        return http.Response('nf', 404);
      }),
    );

Future<ReorderBackend> _pumpApp(
  WidgetTester tester, {
  required FakeSessionStore session,
  required Map<String, String> map,
  AuthApiClient? authApi,
  ReorderBackend? backend,
}) async {
  final b = backend ?? ReorderBackend(sessionStore: session);
  await tester.pumpWidget(MaterialApp(
    home: AppFlow(
      authApi: authApi ?? _authApi(),
      sessionStore: session,
      onboardingStore: _store(map),
      tabsBackend: b,
      weatherApi: WeatherApiClient(client: _weather()),
      healthConnectService: r32.FakeOnboardingHC(),
      notificationService: FakeReminderNotificationService(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 1850));
  await tester.pump(const Duration(milliseconds: 650));
  await tester.pump();
  return b;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

/// Walks Welcome → … → Gems from a fresh AppFlow, asserting the
/// backend call log stays EMPTY the whole pre-account phase
/// (Juno ruling 3: defer flag on, zero network carrying or
/// derived from the answers).
Future<void> _walkToGems(
  WidgetTester tester, {
  required ReorderBackend backend,
  bool selectConditions = true,
}) async {
  await tester.tap(find.text('Get started'));
  await _settle(tester);
  expect(find.text('Privacy & Data Consent'), findsOneWidget);
  expect(backend.calls, isEmpty, reason: 'consent: zero backend calls');

  await tester.tap(find.widgetWithText(FilledButton, 'I consent'));
  await _settle(tester);
  expect(find.text("Let's get you set up!"), findsOneWidget);
  expect(backend.calls, isEmpty, reason: 'profile mount: no prefill fetch');

  await tester.enterText(find.byType(TextField), _contextText);
  await tester.pump();
  await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Next Step'));
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Next Step'));
  await _settle(tester);
  expect(find.text('Add conditions'), findsOneWidget);
  expect(backend.calls, isEmpty,
      reason: 'profile Next: local write only, no push');

  if (selectConditions) {
    for (final name in ['Asthma', 'Chronic Migraine']) {
      await tester.tap(find.text('Search conditions...'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), name);
      await tester.pump();
      // The row's Text (find.text also matches the search field's
      // own EditableText holding the query).
      await tester.tap(find.byWidgetPredicate(
          (w) => w is Text && w.data == name));
      await tester.pumpAndSettle();
    }
    expect(backend.calls, isEmpty,
        reason: 'condition toggles: local only, no debounced push');
  }
  await tester.tap(find.widgetWithText(FilledButton, 'Next'));
  await _settle(tester);
  expect(find.text('Connect Health Data'), findsWidgets);
  expect(backend.calls, isEmpty,
      reason: 'conditions Next: no final push pre-account');

  await tester.tap(find.text('Skip for now'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Skip anyway'));
  await tester.pumpAndSettle();
  expect(find.text('STREAKS, FREEZES & GEMS'), findsOneWidget);
  expect(backend.calls, isEmpty,
      reason: 'connections skip: still zero backend calls');
}

Future<void> _registerFromHandoff(WidgetTester tester) async {
  await tester.tap(find.text('Got it'));
  await _settle(tester);
  // The handoff disclosure (full text) is presented before the
  // register form can be submitted; the short form sits directly
  // above the create-account button.
  expect(find.byKey(const ValueKey('pre_account_handoff_disclosure')),
      findsOneWidget);
  expect(
      find.textContaining('Your answers so far are saved only on '
          'this device.'),
      findsOneWidget);
  expect(find.byKey(const ValueKey('pre_account_short_disclosure')),
      findsOneWidget);
  expect(
      find.text('Saved only on this device until you create your '
          'account.'),
      findsOneWidget);
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), _email);
  await tester.enterText(fields.at(1), 'secret');
  await tester.tap(find.text('I confirm I am 13 or older.'));
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
  await _settle(tester);
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);
  setUp(() => TabsBackend.onSessionExpired = null);
  tearDown(() => TabsBackend.onSessionExpired = null);

  group('(a) picks survive registration', () {
    testWidgets(
        'full pre-account walk → register → membership → setup '
        'loading posts exactly the pre-account answers → home',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final session = FakeSessionStore();
      final map = <String, String>{};
      final backend = await _pumpApp(tester,
          session: session, map: map);
      backend.generated = ['Focus', 'Calm'];

      await _walkToGems(tester, backend: backend);
      await _registerFromHandoff(tester);

      // Lands on MEMBERSHIP (never re-enters the value steps).
      expect(find.text('Unlock Tabs Premium'), findsOneWidget);
      // The store was NOT wiped: answers + consent preserved,
      // owner stamped to the new account, marker at membership.
      expect(map[OnboardingStore.userContextKey], _contextText);
      expect(
          map[OnboardingStore.userConditionsKey],
          jsonEncode(['Asthma', 'Chronic Migraine']));
      expect(map[OnboardingStore.hasConsentedKey], 'true');
      expect(map[OnboardingStore.ownerEmailKey], _email);
      expect(map[OnboardingStore.stepMarkerKey], '5');
      expect(map[OnboardingStore.preAccountInProgressKey], isNull);

      await tester.tap(find.text('Use free account for now'));
      await _settle(tester);
      // Setup loading finalize (2s settle inside the step).
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Start keeping Tabs'), findsOneWidget);
      // The finalize profile post carries EXACTLY the pre-account
      // answers.
      final finalize = backend.profilePushes.last;
      expect(finalize['userContext'], _contextText);
      expect(finalize['conditions'],
          jsonEncode(['Asthma', 'Chronic Migraine']));
      expect(finalize['onboardingComplete'], true);
      // Categories were generated from the pre-account context.
      expect(backend.calls, contains('generateCategories'));
      expect(backend.pushedCategories!.map((c) => c.name),
          containsAll(['Focus', 'Calm']));

      await tester.tap(find.text('Start keeping Tabs'));
      await _settle(tester);
      expect(find.byType(MainShell), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
        'unverified register → verify stage → success resumes at '
        'membership, picks intact', (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final session = FakeSessionStore();
      final map = <String, String>{};
      final backend = await _pumpApp(tester,
          session: session,
          map: map,
          authApi: _authApi(verified: false));

      await _walkToGems(tester, backend: backend, selectConditions: false);
      await _registerFromHandoff(tester);

      expect(find.byType(EmailVerificationScreen), findsOneWidget);
      expect(find.text('Unlock Tabs Premium'), findsNothing);
      await tester.enterText(
          find.byKey(const ValueKey('verify_digit_0')), '001234');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // Resumes at MEMBERSHIP — the value steps are not repeated.
      expect(find.text('Unlock Tabs Premium'), findsOneWidget);
      expect(map[OnboardingStore.userContextKey], _contextText);
      expect(map[OnboardingStore.ownerEmailKey], _email);
    });

    testWidgets(
        'seed guard: foreign unstamped state with NO in-progress '
        'marker is still wiped by registration', (tester) async {
      final session = FakeSessionStore();
      final map = <String, String>{
        OnboardingStore.userContextKey:
            'a foreign template goal that is not the new users own '
            'words at all',
        OnboardingStore.userConditionsKey: '["Asthma"]',
        OnboardingStore.hasConsentedKey: 'true',
      };
      await _pumpApp(tester, session: session, map: map);
      // Plain register via Log In -> Sign Up toggle.
      await tester.tap(find.text('Log In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Don't have an account? Sign Up"));
      await tester.pumpAndSettle();
      // No pre-account disclosures on a register that did not
      // come through the value flow.
      expect(
          find.byKey(const ValueKey('pre_account_handoff_disclosure')),
          findsNothing);
      expect(find.byKey(const ValueKey('pre_account_short_disclosure')),
          findsNothing);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), _email);
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.text('I confirm I am 13 or older.'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
      await _settle(tester);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.userConditionsKey], isNull);
      expect(map[OnboardingStore.ownerEmailKey], _email);
      expect(map['has_consented'], 'false');
    });
  });

  group('(a2) finalize failure stages the outbox under the new '
      'account', () {
    testWidgets(
        'setup loading with failing posts stages both payloads; '
        'a relaunch flush delivers them', (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = _email;
      final map = <String, String>{
        OnboardingStore.ownerEmailKey: _email,
        OnboardingStore.hasConsentedKey: 'true',
        OnboardingStore.userContextKey: _contextText,
        OnboardingStore.userConditionsKey: '["Asthma"]',
      };
      final backend = ReorderBackend(sessionStore: session)
        ..failPosts = true
        ..generated = ['Focus']
        // The outbox flush's recency guard pulls the current
        // profile: an empty server profile lets the staged
        // payload post on the relaunch flush.
        ..pullBody = {
          'profile': {'userContext': '', 'conditions': '[]'},
        };
      final disk = <String, String>{};
      final outbox = OnboardingSyncOutbox.withDeps(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      await tester.pumpWidget(MaterialApp(
        home: OnboardingFlow(
          initialStep: OnboardingStep.setupLoading,
          onboardingStore: _store(map),
          backend: backend,
          onboardingSyncOutbox: outbox,
          onComplete: () {},
          onDeclineConsent: () {},
        ),
      ));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Start keeping Tabs'), findsOneWidget);
      // Both payloads staged, owner-stamped to the new account.
      expect(await outbox.pendingProfile(backend), isNotNull);
      expect(await outbox.pendingCategories(backend), isNotNull);
      final stagedProfile = await outbox.pendingProfile(backend);
      expect(stagedProfile!.fields['userContext'], _contextText);
      expect(stagedProfile.fields['onboardingComplete'], true);

      // Relaunch: fresh outbox over the same disk, posts now
      // succeed — the home-landing flush delivers.
      backend.failPosts = false;
      final relaunched = OnboardingSyncOutbox.withDeps(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      expect(await relaunched.flush(backend), isTrue);
      expect(backend.profilePushes.last['userContext'], _contextText);
      expect(await relaunched.pendingProfile(backend), isNull);
      expect(await relaunched.pendingCategories(backend), isNull);
    });
  });

  group('(b) resume', () {
    testWidgets(
        'pre-account kill-and-resume: cold start with no token '
        'resumes at conditions, profile text intact', (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final map = <String, String>{};
      final backend1 = await _pumpApp(tester,
          session: FakeSessionStore(), map: map);
      // Walk to conditions, then "kill" the app.
      await tester.tap(find.text('Get started'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'I consent'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), _contextText);
      await tester.pump();
      await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Next Step'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Next Step'));
      await _settle(tester);
      expect(find.text('Add conditions'), findsOneWidget);
      expect(backend1.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());

      // Cold start, same device state, no session.
      await _pumpApp(tester, session: FakeSessionStore(), map: map);
      expect(find.text('Add conditions'), findsOneWidget,
          reason: 'resumed at the marked step (conditions)');
      expect(map[OnboardingStore.userContextKey], _contextText);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'Juno probe: marker past consent with hasConsented false '
        'routes to consent, not the marked step', (tester) async {
      final map = <String, String>{
        OnboardingStore.preAccountInProgressKey: 'true',
        OnboardingStore.preAccountLastActivityKey:
            DateTime.now().toIso8601String(),
        OnboardingStore.stepMarkerKey: '3', // connections
        OnboardingStore.hasConsentedKey: 'false',
        OnboardingStore.userContextKey: _contextText,
      };
      await _pumpApp(tester, session: FakeSessionStore(), map: map);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      expect(find.text('Connect Health Data'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'post-register kill-and-resume: cold start with a token '
        'at membership marker resumes at membership',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = _email
        ..emailVerified = true;
      final map = <String, String>{
        OnboardingStore.ownerEmailKey: _email,
        OnboardingStore.hasConsentedKey: 'true',
        OnboardingStore.introConsultationSeenKey: 'true',
        OnboardingStore.onboardingCompleteKey: 'false',
        OnboardingStore.stepMarkerKey: '5',
        OnboardingStore.userContextKey: _contextText,
      };
      await _pumpApp(tester, session: session, map: map);
      expect(find.text('Unlock Tabs Premium'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'one-shot: handoff → back to Welcome → Log In does not '
        're-enter the value flow, and login wipes the answers',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final session = FakeSessionStore();
      final map = <String, String>{};
      final backend = await _pumpApp(tester,
          session: session,
          map: map,
          authApi: _authApi(login: true));
      backend.pullBody = {
        'profile': {'onboardingComplete': true},
        'entries': <dynamic>[],
        'categories': <dynamic>[],
      };
      await _walkToGems(tester, backend: backend, selectConditions: false);
      await tester.tap(find.text('Got it'));
      await _settle(tester);
      expect(find.text('Create Your Account'), findsOneWidget);
      // Back out to Welcome, then take the plain Log In door.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await _settle(tester);
      expect(find.text('Get started'), findsOneWidget);
      await tester.tap(find.text('Log In'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome Back'), findsOneWidget);
      // No pre-account disclosures in login mode.
      expect(find.byKey(const ValueKey('pre_account_short_disclosure')),
          findsNothing);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), _email);
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
      await _settle(tester);
      // Lands home — the value flow does NOT re-enter.
      expect(find.byType(MainShell), findsOneWidget);
      expect(find.text('Privacy & Data Consent'), findsNothing);
      // Login wiped the pre-account answers + marker; nothing was
      // posted to this account carrying them.
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.stepMarkerKey], isNull);
      expect(map[OnboardingStore.preAccountInProgressKey], isNull);
      expect(
          backend.profilePushes
              .where((p) => p['userContext'] == _contextText),
          isEmpty);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('(c) returning / login unaffected + ruling extras', () {
    testWidgets(
        'Log In from Welcome never shows a pre-account step',
        (tester) async {
      final session = FakeSessionStore();
      final map = <String, String>{};
      final backend = await _pumpApp(tester,
          session: session, map: map, authApi: _authApi(login: true));
      backend.pullBody = {
        'profile': {'onboardingComplete': true},
        'entries': <dynamic>[],
        'categories': <dynamic>[],
      };
      await tester.tap(find.text('Log In'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), _email);
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
      await _settle(tester);
      expect(find.byType(MainShell), findsOneWidget);
      expect(find.text("Let's get you set up!"), findsNothing);
      expect(find.text('Add conditions'), findsNothing);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
        'pre-account decline shows the Juno variant verbatim and '
        'leaves without any session action', (tester) async {
      var declined = false;
      final map = <String, String>{};
      await tester.pumpWidget(MaterialApp(
        home: OnboardingFlow(
          onboardingStore: _store(map),
          backend: ReorderBackend(sessionStore: FakeSessionStore()),
          healthConnectService: r32.FakeOnboardingHC(),
          preAccount: true,
          onPreAccountComplete: () {},
          onComplete: () {},
          onDeclineConsent: () => declined = true,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(find.text('We need your consent to continue'),
          findsOneWidget);
      expect(
          find.text('Tabs saves the health notes you add so you '
              'can see them in one place. Without your consent, '
              'nothing can be saved, so setup can\'t continue. You '
              'can go back and read the Terms and Privacy Policy '
              'first, or leave setup for now. Nothing has been '
              'saved on this device.'),
          findsOneWidget);
      expect(find.text('Data Consent Required'), findsNothing);
      expect(find.text('Log Out'), findsNothing);
      // Go back: dismiss, stay on Consent, no decline fired.
      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(declined, isFalse);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      // Leave setup: decline fires (AppFlow returns to Welcome;
      // no session exists to clear).
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave setup'));
      await tester.pumpAndSettle();
      expect(declined, isTrue);
    });

    testWidgets(
        '30-day expiry: an expired pre-account run is wiped '
        'before any onboarding screen renders', (tester) async {
      final map = <String, String>{
        OnboardingStore.preAccountInProgressKey: 'true',
        OnboardingStore.preAccountLastActivityKey: DateTime.now()
            .subtract(const Duration(days: 31))
            .toIso8601String(),
        OnboardingStore.stepMarkerKey: '2',
        OnboardingStore.hasConsentedKey: 'true',
        OnboardingStore.userContextKey: _contextText,
      };
      await _pumpApp(tester, session: FakeSessionStore(), map: map);
      // Welcome, not a resumed conditions step — and the answers
      // are gone.
      expect(find.text('Get started'), findsOneWidget);
      expect(find.text('Add conditions'), findsNothing);
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.stepMarkerKey], isNull);
      expect(map[OnboardingStore.preAccountInProgressKey], isNull);
      await tester.pumpWidget(const SizedBox());
    });

    test('store: expiry boundary is 30 days from last activity',
        () async {
      final map = <String, String>{};
      final store = _store(map);
      await store.setPreAccountInProgress(true);
      await store.touchPreAccountActivity(
          now: DateTime(2026, 10, 28));
      expect(
          await store.isPreAccountExpired(now: DateTime(2026, 11, 26)),
          isFalse,
          reason: '29 days: still live');
      expect(
          await store.isPreAccountExpired(now: DateTime(2026, 11, 28)),
          isTrue,
          reason: '31 days: expired');
    });

    testWidgets(
        'register disclosures never appear on a plain register '
        'or in login mode', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: LoginScreen(initialRegisterMode: true),
      ));
      await tester.pump();
      expect(
          find.byKey(const ValueKey('pre_account_handoff_disclosure')),
          findsNothing);
      expect(find.byKey(const ValueKey('pre_account_short_disclosure')),
          findsNothing);
      await tester.pumpWidget(const MaterialApp(
        home: LoginScreen(
          initialRegisterMode: true,
          isPreAccountRegister: true,
        ),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('pre_account_short_disclosure')),
          findsOneWidget);
      // Toggle to login mode: both disclosures disappear.
      await tester.tap(find.text('Already have an account? Log In'));
      await tester.pump();
      expect(
          find.byKey(const ValueKey('pre_account_handoff_disclosure')),
          findsNothing);
      expect(find.byKey(const ValueKey('pre_account_short_disclosure')),
          findsNothing);
    });

    test('enum order is byte-identical (indices unchanged)', () {
      expect(OnboardingStep.consent.index, 0);
      expect(OnboardingStep.profileSetup.index, 1);
      expect(OnboardingStep.conditions.index, 2);
      expect(OnboardingStep.connections.index, 3);
      expect(OnboardingStep.gems.index, 4);
      expect(OnboardingStep.membership.index, 5);
      expect(OnboardingStep.setupLoading.index, 6);
    });
  });
}
