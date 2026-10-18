import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/onboarding/conditions_screen.dart';
import 'package:tabs_lab/src/features/onboarding/membership_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/notification_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_connections_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_flow.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';

import 'test_helpers.dart';

/// Round 32 — onboarding flow tests.
///
/// Native source: MainActivity.kt onboarding routes, SplashScreen.kt
/// checkAuthState, LoginScreen.kt LoginViewModel (register leaves
/// onboarding incomplete; login/Google mark it complete),
/// SetupLoadingScreen.kt finalizeSetup, NotelPreferences.kt keys.

OnboardingStore fakeOnboardingStore(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

class FakeOnboardingBackend extends TabsBackend {
  Map<String, dynamic>? pullBody;
  bool unlimited = false;
  List<String>? generated;
  List<QuickLogCategory> categories = const [];
  final List<Map<String, dynamic>> profilePushes = [];
  List<QuickLogCategory>? pushedCategories;

  FakeOnboardingBackend({super.sessionStore});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pullBody;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async {
    final p = pullBody?['profile'];
    return p is Map<String, dynamic> ? p : null;
  }

  @override
  Future<bool> fetchIsUnlimited() async => unlimited;

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePushes.add(fields);
    return true;
  }

  @override
  Future<List<String>?> generateCategories(String userContext) async =>
      generated;

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => categories;

  @override
  Future<bool> postLogCategories(List<QuickLogCategory> cats) async {
    pushedCategories = cats;
    return true;
  }
}

class FakeOnboardingHC extends HealthConnectService {
  int requestCalls = 0;
  HealthConnectStatus status = HealthConnectStatus.notConnected;
  Set<String> grantedOnRequest = const {};

  @override
  Future<bool> hasPersistedConnection() async =>
      status == HealthConnectStatus.connected;

  @override
  Future<HealthConnectStatus> getStatus() async => status;

  @override
  Future<Set<String>> requestPermissions() async {
    requestCalls++;
    return grantedOnRequest;
  }

  @override
  Future<void> openHealthConnectSettings() async {}
}

MockClient _mockWeatherClient() {
  return MockClient((request) async {
    if (request.url.host == 'ipinfo.io') {
      return http.Response(
          '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
    }
    if (request.url.host == 'api.open-meteo.com') {
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
          200);
    }
    return http.Response('not found', 404);
  });
}

/// Pumps AppFlow and fast-forwards past the splash (650+1200+650).
Future<void> _pumpAppFlow(
  WidgetTester tester, {
  required FakeSessionStore session,
  required Map<String, String> onboardingMap,
  FakeOnboardingBackend? backend,
  AuthApiClient? authApi,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AppFlow(
      authApi: authApi ??
          AuthApiClient(
              client: MockClient((_) async => http.Response('nf', 404))),
      sessionStore: session,
      onboardingStore: fakeOnboardingStore(onboardingMap),
      tabsBackend: backend ?? FakeOnboardingBackend(sessionStore: session),
      weatherApi: WeatherApiClient(client: _mockWeatherClient()),
      healthConnectService: FakeOnboardingHC(),
      notificationService: FakeReminderNotificationService(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 1850));
  await tester.pump(const Duration(milliseconds: 650));
  await tester.pump();
}

void main() {
  group('OnboardingStore', () {
    test('defaults mirror native DataStore defaults', () async {
      final store = fakeOnboardingStore({});
      expect(await store.getOnboardingComplete(), isFalse);
      expect(await store.getHasConsented(), isFalse);
      expect(await store.getIntroConsultationSeen(), isFalse);
      expect(await store.getUserContext(), '');
      expect(await store.getConditions(), isEmpty);
      expect(await store.hasAnyState(), isFalse);
    });

    test('round-trips flags, context, and native conditions JSON shape',
        () async {
      final map = <String, String>{};
      final store = fakeOnboardingStore(map);
      await store.setOnboardingComplete(true);
      await store.setHasConsented(true);
      await store.setUserContext('my context');
      await store.setConditions(['POTS (Postural Orthostatic Tachycardia Syndrome)', 'Chronic Migraine']);
      expect(map['onboarding_complete'], 'true');
      expect(map['has_consented'], 'true');
      expect(map['user_context'], 'my context');
      // Native ConditionRepository persists a JSON array string.
      expect(map['user_conditions'],
          '["POTS (Postural Orthostatic Tachycardia Syndrome)","Chronic Migraine"]');
      expect(await store.getConditions(), hasLength(2));
      expect(await store.hasAnyState(), isTrue);
      await store.clear();
      expect(map, isEmpty);
    });
  });

  group('AuthApiClient.register', () {
    test('posts the native AuthRequest shape to /api/auth/register',
        () async {
      Uri? seenUrl;
      String? seenBody;
      final client = AuthApiClient(
        client: MockClient((request) async {
          seenUrl = request.url;
          seenBody = request.body;
          return http.Response(
            jsonEncode({
              'token': 'tok',
              'refreshToken': 'ref',
              'userId': 'u1',
              'email': 'new@tabs.app',
            }),
            200,
          );
        }),
      );
      final result = await client.register(
        email: 'new@tabs.app',
        password: 'secret',
        ageConfirmed: true,
      );
      expect(result, isA<LoginSuccess>());
      expect(seenUrl!.path, '/api/auth/register');
      final body = jsonDecode(seenBody!) as Map<String, dynamic>;
      expect(body['email'], 'new@tabs.app');
      expect(body['ageConfirmed'], isTrue);
      // The password travels in the request only — never in results.
      expect(body['password'], 'secret');
    });

    test('surfaces the server error verbatim, else the native fallback',
        () async {
      final client = AuthApiClient(
        client: MockClient((request) async {
          if (request.url.path.contains('register')) {
            return http.Response(
                jsonEncode({'error': 'Email already registered'}), 400);
          }
          return http.Response('nope', 500);
        }),
      );
      final dup = await client.register(
          email: 'a@b.c', password: 'x', ageConfirmed: true);
      expect(dup, isA<LoginFailure>());
      expect((dup as LoginFailure).message, 'Email already registered');
    });
  });

  group('LoginScreen registration', () {
    testWidgets('age gate blocks Sign Up before any request',
        (tester) async {
      var calls = 0;
      final api = AuthApiClient(
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await tester.pumpWidget(MaterialApp(
        home: LoginScreen(
          initialRegisterMode: true,
          authApi: api,
          sessionStore: FakeSessionStore(),
        ),
      ));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'new@tabs.app');
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
      await tester.pump();
      expect(
        find.text(
            'Tabs is for people 13 and older. You cannot create an account yet.'),
        findsOneWidget,
      );
      expect(calls, 0);
    });

    testWidgets('register success fires onRegisterSuccess, not login',
        (tester) async {
      String? registered;
      String? loggedIn;
      final store = FakeSessionStore();
      final api = AuthApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/api/auth/register');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['ageConfirmed'], isTrue);
          return http.Response(
            jsonEncode({
              'token': 'tok',
              'refreshToken': 'ref',
              'email': 'new@tabs.app',
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(MaterialApp(
        home: LoginScreen(
          initialRegisterMode: true,
          authApi: api,
          sessionStore: store,
          onLoginSuccess: (e) => loggedIn = e,
          onRegisterSuccess: (e) => registered = e,
        ),
      ));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'new@tabs.app');
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.text('I confirm I am 13 or older.'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(registered, 'new@tabs.app');
      expect(loggedIn, isNull);
      expect(store.token, 'tok');
    });
  });

  group('AppFlow startup routing (native splash rule)', () {
    testWidgets('no session lands on welcome', (tester) async {
      await _pumpAppFlow(
        tester,
        session: FakeSessionStore(),
        onboardingMap: {},
      );
      expect(find.text('Register'), findsOneWidget);
      expect(find.text('Log In'), findsOneWidget);
    });

    testWidgets('legacy session (no onboarding state) lands home and '
        'backfills complete', (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'founder@tabs.app';
      final map = <String, String>{};
      await _pumpAppFlow(tester, session: session, onboardingMap: map);
      expect(find.byType(MainShell), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(map['onboarding_complete'], 'true');
      expect(map['has_consented'], 'true');
      expect(map['intro_consultation_seen'], 'true');
    });

    testWidgets('signed-in, not consented resumes at consent',
        (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'new@tabs.app';
      final map = <String, String>{'onboarding_complete': 'false'};
      await _pumpAppFlow(tester, session: session, onboardingMap: map);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
    });

    testWidgets('signed-in, consented + intro seen, incomplete resumes '
        'at profile setup', (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'new@tabs.app';
      final map = <String, String>{
        'has_consented': 'true',
        'intro_consultation_seen': 'true',
        'onboarding_complete': 'false',
      };
      await _pumpAppFlow(tester, session: session, onboardingMap: map);
      expect(find.text('Next Step'), findsOneWidget);
      // Drain the placeholder rotation loop before teardown.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('completed onboarding lands home', (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'new@tabs.app';
      final map = <String, String>{
        'has_consented': 'true',
        'intro_consultation_seen': 'true',
        'onboarding_complete': 'true',
      };
      await _pumpAppFlow(tester, session: session, onboardingMap: map);
      expect(find.byType(MainShell), findsOneWidget);
    });

    testWidgets('fresh registration enters onboarding at consent and '
        'stamps fresh-account flags', (tester) async {
      final session = FakeSessionStore();
      final map = <String, String>{};
      final api = AuthApiClient(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/register') {
            return http.Response(
              jsonEncode({
                'token': 'tok',
                'refreshToken': 'ref',
                'email': 'new@tabs.app',
              }),
              200,
            );
          }
          return http.Response('nf', 404);
        }),
      );
      await _pumpAppFlow(
        tester,
        session: session,
        onboardingMap: map,
        authApi: api,
      );
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'new@tabs.app');
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.text('I confirm I am 13 or older.'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      expect(map['onboarding_complete'], 'false');
      expect(map['has_consented'], 'false');
    });

    testWidgets('consent decline logs out to welcome', (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'new@tabs.app';
      final map = <String, String>{'onboarding_complete': 'false'};
      await _pumpAppFlow(tester, session: session, onboardingMap: map);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(find.text('Data Consent Required'), findsOneWidget);
      await tester.tap(find.text('Log Out'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Register'), findsOneWidget);
      expect(session.token, isNull);
      expect(map['has_consented'], 'false');
    });
  });

  group('AppFlow login routing (reset-account-status fix)', () {
    AuthApiClient loginApi() => AuthApiClient(
          client: MockClient((request) async {
            if (request.url.path == '/api/auth/login') {
              return http.Response(
                jsonEncode({
                  'token': 'tok',
                  'refreshToken': 'ref',
                  'email': 'reset@tabs.app',
                }),
                200,
              );
            }
            return http.Response('nf', 404);
          }),
        );

    Future<void> driveLogin(
      WidgetTester tester, {
      required FakeSessionStore session,
      required Map<String, String> map,
      required FakeOnboardingBackend backend,
    }) async {
      await _pumpAppFlow(
        tester,
        session: session,
        onboardingMap: map,
        backend: backend,
        authApi: loginApi(),
      );
      await tester.tap(find.text('Log In'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'reset@tabs.app');
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    testWidgets(
        'login with explicit server onboardingComplete=false routes '
        'into onboarding (the reset account)', (tester) async {
      final session = FakeSessionStore();
      final map = <String, String>{};
      final backend = FakeOnboardingBackend(sessionStore: session)
        ..pullBody = {
          'profile': {'onboardingComplete': false},
          'entries': [
            {'id': 1}
          ],
          'categories': [
            {'id': 1}
          ],
        };
      await driveLogin(tester, session: session, map: map, backend: backend);
      expect(session.token, 'tok');
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      expect(map['onboarding_complete'], 'false');
      expect(map['has_consented'], 'false');
      expect(map['intro_consultation_seen'], 'false');
    });

    testWidgets(
        'login with server onboardingComplete=true lands home and '
        'marks complete (unchanged legacy behavior)', (tester) async {
      final session = FakeSessionStore();
      final map = <String, String>{};
      final backend = FakeOnboardingBackend(sessionStore: session)
        ..pullBody = {
          'profile': {'onboardingComplete': true},
          'entries': <dynamic>[],
          'categories': <dynamic>[],
        };
      await driveLogin(tester, session: session, map: map, backend: backend);
      expect(find.byType(MainShell), findsOneWidget);
      expect(map['onboarding_complete'], 'true');
      expect(map['has_consented'], 'true');
      // Drain MainShell's mount timers before teardown.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
        'login with no profile in the pull lands home (legacy '
        'accounts are never dropped into onboarding)', (tester) async {
      final session = FakeSessionStore();
      final map = <String, String>{};
      final backend = FakeOnboardingBackend(sessionStore: session)
        ..pullBody = {'entries': <dynamic>[], 'categories': <dynamic>[]};
      await driveLogin(tester, session: session, map: map, backend: backend);
      expect(find.byType(MainShell), findsOneWidget);
      expect(map['onboarding_complete'], 'true');
      // Drain MainShell's mount timers before teardown.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
        'cold start mid-re-onboarding: explicit server false beats '
        'the has-data reconcile heuristic', (tester) async {
      // A reset user who paused halfway through setup: server says
      // false AND the account has entries — before the fix, the
      // background reconcile marked the local flag complete from the
      // data alone, so the NEXT cold start skipped the rest of
      // onboarding entirely.
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'reset@tabs.app';
      final map = <String, String>{
        'has_consented': 'true',
        'intro_consultation_seen': 'true',
        'onboarding_complete': 'false',
      };
      final backend = FakeOnboardingBackend(sessionStore: session)
        ..pullBody = {
          'profile': {'onboardingComplete': false},
          'entries': [
            {'id': 1}
          ],
          'categories': <dynamic>[],
        };
      await _pumpAppFlow(
        tester,
        session: session,
        onboardingMap: map,
        backend: backend,
      );
      expect(find.text('Next Step'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(map['onboarding_complete'], 'false');
      // Drain the profile-setup placeholder rotation loop.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('Onboarding steps', () {
    testWidgets('notification step: Allow requests permission and '
        'advances; Don\'t Allow advances without requesting',
        (tester) async {
      final service = FakeReminderNotificationService();
      var next = 0;
      var skipped = 0;
      await tester.pumpWidget(MaterialApp(
        home: NotificationOnboardingScreen(
          onBack: () {},
          onNavigateNext: () => next++,
          onSkip: () => skipped++,
          notificationService: service,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text("Don't Allow"));
      await tester.pump();
      expect(skipped, 1);
      expect(service.requestCount, 0);

      await tester.pumpWidget(MaterialApp(
        home: NotificationOnboardingScreen(
          onBack: () {},
          onNavigateNext: () => next++,
          onSkip: () => skipped++,
          notificationService: service,
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('Allow'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(service.requestCount, 1);
      expect(next, 1);
    });

    testWidgets('connections step shows the MF-3 disclosure before '
        'any permission request', (tester) async {
      final hc = FakeOnboardingHC();
      await tester.pumpWidget(MaterialApp(
        home: OnboardingConnectionsScreen(
          onBack: () {},
          onNavigateNext: () {},
          healthConnectService: hc,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Skip for now'), findsOneWidget);
      await tester.tap(
          find.widgetWithText(FilledButton, 'Connect Health Data'));
      await tester.pumpAndSettle();
      // Disclosure is up; the system request has NOT fired.
      expect(find.text('Connect Health Connect?'), findsOneWidget);
      expect(hc.requestCalls, 0);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(hc.requestCalls, 1);
    });

    testWidgets('conditions step: search, select, persist, push',
        (tester) async {
      final map = <String, String>{};
      final backend = FakeOnboardingBackend();
      var next = 0;
      await tester.pumpWidget(MaterialApp(
        home: OnboardingConditionsScreen(
          onBack: () {},
          onNavigateNext: () => next++,
          onSkip: () {},
          onboardingStore: fakeOnboardingStore(map),
          backend: backend,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Search conditions...'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'POTS');
      await tester.pumpAndSettle();
      await tester.tap(
          find.text('POTS (Postural Orthostatic Tachycardia Syndrome)'));
      await tester.pumpAndSettle();
      // Selected row is on the main screen and persisted natively.
      expect(
        find.text('POTS (Postural Orthostatic Tachycardia Syndrome)'),
        findsOneWidget,
      );
      expect(map['user_conditions'],
          '["POTS (Postural Orthostatic Tachycardia Syndrome)"]');
      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(next, 1);
      expect(
        backend.profilePushes.any((p) =>
            p['conditions'] ==
            '["POTS (Postural Orthostatic Tachycardia Syndrome)"]'),
        isTrue,
      );
    });

    testWidgets('membership step: Juno disclaimer verbatim + free skip',
        (tester) async {
      var skipped = 0;
      await tester.pumpWidget(MaterialApp(
        home: MembershipOnboardingScreen(
          onBack: () {},
          onSkip: () => skipped++,
          backend: FakeOnboardingBackend(),
        ),
      ));
      await tester.pump();
      expect(find.text('Unlock Tabs Premium'), findsOneWidget);
      // Takeover review fix (Juno): the Lab yearly card carries no
      // "BEST VALUE" chip — no catalog prices back it here.
      expect(find.text('BEST VALUE'), findsNothing);
      expect(
        find.text(
            'Tabs Premium is for education and personal self tracking only. It does not provide medical advice, diagnosis, or treatment. Talk to a qualified health professional about any health decisions.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Use free account for now'));
      await tester.tap(find.text('Use free account for now'));
      await tester.pump();
      expect(skipped, 1);
    });

    testWidgets('membership step auto-advances when already unlimited',
        (tester) async {
      var skipped = 0;
      final backend = FakeOnboardingBackend()..unlimited = true;
      await tester.pumpWidget(MaterialApp(
        home: MembershipOnboardingScreen(
          onBack: () {},
          onSkip: () => skipped++,
          backend: backend,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(skipped, 1);
    });
  });

  group('Full onboarding walk', () {
    testWidgets('consent → setup loading → home, with native payloads',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final map = <String, String>{};
      final backend = FakeOnboardingBackend()
        ..generated = ['Focus', 'Calm']
        ..categories = const [
          QuickLogCategory(
            id: 1,
            name: 'Symptoms',
            icon: 'Favorite',
            colorHex: '#FF6B6B',
            isDefault: true,
            sortOrder: 0,
          ),
        ];
      var completed = 0;
      await tester.pumpWidget(MaterialApp(
        home: OnboardingFlow(
          onboardingStore: fakeOnboardingStore(map),
          backend: backend,
          healthConnectService: FakeOnboardingHC(),
          notificationService: FakeReminderNotificationService(),
          onComplete: () => completed++,
          onDeclineConsent: () {},
        ),
      ));
      await tester.pump();

      // Consent.
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      await tester.tap(find.text('I consent'));
      await tester.pumpAndSettle();
      expect(map['has_consented'], 'true');

      // Consultation intro.
      expect(find.text("Let's get you set up!"), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(map['intro_consultation_seen'], 'true');

      // Profile setup: Next is gated at 10 words (native rule).
      await tester.enterText(
        find.byType(TextField),
        'one two three four five six seven eight nine',
      );
      await tester.pump();
      await tester.enterText(
        find.byType(TextField),
        'one two three four five six seven eight nine ten eleven',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Next Step'));
      await tester.tap(find.text('Next Step'));
      await tester.pumpAndSettle();
      expect(map['user_context'],
          'one two three four five six seven eight nine ten eleven');
      expect(
        backend.profilePushes.any((p) =>
            p['userContext'] ==
            'one two three four five six seven eight nine ten eleven'),
        isTrue,
      );
      // Drain the placeholder rotation loop (screen disposed).
      await tester.pump(const Duration(seconds: 4));

      // Conditions (skip selection; step is skippable).
      expect(find.text('Add conditions'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      // Notifications.
      expect(
          find.text('Allow Tabs to send you\nnotifications?'),
          findsOneWidget);
      await tester.tap(find.text("Don't Allow"));
      await tester.pumpAndSettle();

      // Connections.
      expect(find.text('Connect Health Data'), findsWidgets);
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();

      // Membership.
      expect(find.text('Unlock Tabs Premium'), findsOneWidget);
      await tester.ensureVisible(find.text('Use free account for now'));
      await tester.tap(find.text('Use free account for now'));
      await tester.pumpAndSettle();

      // Setup loading: finalize runs (2s native settle), then the
      // completion writes land.
      expect(find.text('Welcome to Tabs'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Your profile is all set up!'), findsOneWidget);
      expect(map['onboarding_complete'], 'true');
      final finalizePush = backend.profilePushes.last;
      expect(finalizePush['onboardingComplete'], isTrue);
      expect(finalizePush['userContext'],
          'one two three four five six seven eight nine ten eleven');
      expect(finalizePush['conditions'], '[]');
      // Generated categories merged over the preserved defaults.
      expect(backend.pushedCategories, isNotNull);
      final names =
          backend.pushedCategories!.map((c) => c.name).toList();
      expect(names, containsAll(['Symptoms', 'Focus', 'Calm']));

      await tester.tap(find.text('Start keeping Tabs'));
      await tester.pump();
      expect(completed, 1);

      // Unmount to cancel the setup dot timer cleanly.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
