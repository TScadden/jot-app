import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/tools/food_screen.dart';
import 'package:tabs_lab/src/features/tools/tips_tricks_screen.dart';

import 'test_helpers.dart';

/// Founder seed findings (Oct 28, 2026) — a brand-new account's
/// walkthrough found content pre-added by default: the onboarding
/// goal text prefilled with a Jot-era productivity template, "Acid
/// Reflux / GERD" pre-listed under Your conditions, pre-created
/// reminders, a pre-added habit, and a completed mock Project Focus
/// experiment. Provenance: the server seeds NOTHING at registration
/// and current app code contains no seed literals; the goal text
/// and the condition rendered from ON-DEVICE state the new account
/// never wrote. OnboardingStore was the one account-bound store
/// with no owner binding and no login/register clearing — state
/// left on the device by a previous account (or an older app
/// generation) prefilled the next account's onboarding and, on
/// Next, was pushed into its server profile (the goal text feeds
/// Coach context; conditions feed clinical surfaces).
///
/// These tests pin the fix: onboarding state is owner-stamped and
/// wiped on account mismatch at login/register, so a fresh account
/// starts with an EMPTY goal field (0 words) and an EMPTY Your
/// conditions list, and completing onboarding saves none of the
/// foreign content. The same owner pattern is pinned for the three
/// other never-cleared content stores the audit found
/// (SettingsStore identity keys, Tips cache, food history).

const _templateGoal =
    'I want to organize daily notes and productivity for my work and '
    'personal life.';
const _seedCondition = 'Acid Reflux / GERD';

OnboardingStore _fakeOnboardingStore(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

class FakeSeedBackend extends TabsBackend {
  Map<String, dynamic>? pullBody;
  final List<Map<String, dynamic>> profilePushes = [];

  FakeSeedBackend({super.sessionStore});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pullBody;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async {
    final p = pullBody?['profile'];
    return p is Map<String, dynamic> ? p : null;
  }

  @override
  Future<bool> fetchIsUnlimited() async => false;

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePushes.add(fields);
    return true;
  }

  @override
  Future<List<String>?> generateCategories(String userContext) async =>
      null;

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async => const [];

  @override
  Future<bool> postLogCategories(List<QuickLogCategory> cats) async =>
      true;
}

class FakeSeedHC extends HealthConnectService {
  @override
  Future<bool> hasPersistedConnection() async => false;

  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.notConnected;

  @override
  Future<Set<String>> requestPermissions() async => const {};

  @override
  Future<void> openHealthConnectSettings() async {}

  // The capture's history reads must complete immediately: the real
  // implementations call the platform channel, which never answers
  // in tests, so each read would sit out its 30 s bounded-read
  // timeout and leave guard timers pending at teardown.
  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
          int days) async =>
      const [];
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

Future<void> _pumpAppFlow(
  WidgetTester tester, {
  required FakeSessionStore session,
  required Map<String, String> onboardingMap,
  FakeSeedBackend? backend,
  AuthApiClient? authApi,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AppFlow(
      authApi: authApi ??
          AuthApiClient(
              client: MockClient((_) async => http.Response('nf', 404))),
      sessionStore: session,
      onboardingStore: _fakeOnboardingStore(onboardingMap),
      tabsBackend: backend ?? FakeSeedBackend(sessionStore: session),
      weatherApi: WeatherApiClient(client: _mockWeatherClient()),
      healthConnectService: FakeSeedHC(),
      notificationService: FakeReminderNotificationService(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 1850));
  await tester.pump(const Duration(milliseconds: 650));
  await tester.pump();
}

/// The device state the founder's walkthrough account inherited:
/// the template goal text + the GERD condition, with NO owner
/// stamp (written before the binding existed).
Map<String, String> _foreignOnboardingMap() => <String, String>{
      OnboardingStore.userContextKey: _templateGoal,
      OnboardingStore.userConditionsKey: '["$_seedCondition"]',
    };

void main() {
  group('OnboardingStore.clearIfOwnerMismatch', () {
    test('foreign unstamped state (the walkthrough seed) is wiped '
        'and re-stamped', () async {
      final map = _foreignOnboardingMap();
      final store = _fakeOnboardingStore(map);
      expect(await store.clearIfOwnerMismatch('new@tabs.app'), isTrue);
      expect(await store.getUserContext(), '');
      expect(await store.getConditions(), isEmpty);
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.userConditionsKey], isNull);
      expect(map[OnboardingStore.ownerEmailKey], 'new@tabs.app');
    });

    test('state stamped to a different account is wiped', () async {
      final map = <String, String>{
        OnboardingStore.ownerEmailKey: 'other@tabs.app',
        OnboardingStore.userContextKey: 'someone else context text',
        OnboardingStore.userConditionsKey: '["POTS"]',
        OnboardingStore.onboardingCompleteKey: 'true',
      };
      final store = _fakeOnboardingStore(map);
      expect(await store.clearIfOwnerMismatch('new@tabs.app'), isTrue);
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.userConditionsKey], isNull);
      expect(map[OnboardingStore.onboardingCompleteKey], isNull);
      expect(map[OnboardingStore.ownerEmailKey], 'new@tabs.app');
    });

    test('the account\'s own state is preserved (same-account resume)',
        () async {
      final map = <String, String>{
        OnboardingStore.ownerEmailKey: 'me@tabs.app',
        OnboardingStore.userContextKey: 'my own goal text here',
        OnboardingStore.userConditionsKey: '["Chronic Migraine"]',
      };
      final store = _fakeOnboardingStore(map);
      expect(await store.clearIfOwnerMismatch('  ME@tabs.app '), isFalse);
      expect(await store.getUserContext(), 'my own goal text here');
      expect(await store.getConditions(), ['Chronic Migraine']);
    });

    test('an empty store is stamped without a wipe', () async {
      final map = <String, String>{};
      final store = _fakeOnboardingStore(map);
      expect(await store.clearIfOwnerMismatch('new@tabs.app'), isFalse);
      expect(map[OnboardingStore.ownerEmailKey], 'new@tabs.app');
      expect(await store.hasAnyState(), isTrue);
    });

    test('null/blank email is a no-op', () async {
      final map = _foreignOnboardingMap();
      final store = _fakeOnboardingStore(map);
      expect(await store.clearIfOwnerMismatch(null), isFalse);
      expect(await store.clearIfOwnerMismatch('  '), isFalse);
      expect(map[OnboardingStore.userContextKey], _templateGoal);
    });

    test('clear() also removes the owner stamp', () async {
      final map = <String, String>{
        OnboardingStore.ownerEmailKey: 'me@tabs.app',
        OnboardingStore.userContextKey: 'x',
      };
      await _fakeOnboardingStore(map).clear();
      expect(map, isEmpty);
    });
  });

  group('fresh account onboarding (founder findings 2+3)', () {
    AuthApiClient registerApi() => AuthApiClient(
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

    Future<void> driveRegister(
      WidgetTester tester, {
      required FakeSessionStore session,
      required Map<String, String> map,
      FakeSeedBackend? backend,
    }) async {
      await _pumpAppFlow(
        tester,
        session: session,
        onboardingMap: map,
        backend: backend,
        authApi: registerApi(),
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
    }

    testWidgets(
        'registration wipes inherited goal text + conditions before '
        'onboarding starts', (tester) async {
      final session = FakeSessionStore();
      final map = _foreignOnboardingMap();
      await driveRegister(tester, session: session, map: map);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      expect(map[OnboardingStore.userContextKey], isNull,
          reason: 'the template goal text must not survive into the '
              'new account');
      expect(map[OnboardingStore.userConditionsKey], isNull,
          reason: 'the pre-listed condition must not survive into '
              'the new account');
      expect(map[OnboardingStore.ownerEmailKey], 'new@tabs.app');
      expect(map['onboarding_complete'], 'false');
      expect(map['has_consented'], 'false');
    });

    testWidgets(
        'goal step opens EMPTY (0 words, Next gated) and conditions '
        'step opens with an empty Your conditions; completing saves '
        'no seeded content', (tester) async {
      final session = FakeSessionStore();
      final map = _foreignOnboardingMap();
      final backend = FakeSeedBackend(sessionStore: session);
      await driveRegister(tester, session: session, map: map,
          backend: backend);

      // Consent → consultation intro → profile setup.
      await tester.tap(find.widgetWithText(FilledButton, 'I consent'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      // Profile setup: the goal field is EMPTY — the founder's
      // screenshot showed the template here at 14/100 words.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '');
      expect(find.text('0 / 100 words'), findsOneWidget);
      final nextButton =
          tester.widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Next Step'));
      expect(nextButton.onPressed, isNull,
          reason: 'an untouched empty field cannot be saved — the '
              'seed used to satisfy this gate by itself');
      expect(
          backend.profilePushes
              .where((p) => p.containsKey('userContext')),
          isEmpty,
          reason: 'nothing was saved for the goal field');

      // Type the account's OWN goal (12 words) and proceed. The
      // button sits below the fold of the scrollable step, so
      // scroll it into view before tapping.
      await tester.enterText(find.byType(TextField),
          'I want to sleep through the night without waking in pain');
      await tester.pump();
      await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Next Step'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Next Step'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      // Conditions: Your conditions starts EMPTY — the founder's
      // screenshot showed Acid Reflux / GERD pre-listed here.
      expect(find.text('Add conditions'), findsOneWidget);
      expect(find.text('Your conditions'), findsOneWidget);
      expect(find.text(_seedCondition), findsNothing,
          reason: 'the pre-listed condition must not appear as '
              'one of Your conditions — the step starts empty '
              '(the screen renders no chips when none are added)');

      // Complete the step untouched: the saved conditions are an
      // EMPTY list, and no push anywhere carries the seed.
      await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Next'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Next'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      final conditionPushes = backend.profilePushes
          .where((p) => p.containsKey('conditions'))
          .toList();
      expect(conditionPushes, hasLength(1));
      expect(jsonDecode(conditionPushes.single['conditions'] as String),
          isEmpty);
      for (final push in backend.profilePushes) {
        expect(push.toString(), isNot(contains(_seedCondition)));
        expect(push.toString(), isNot(contains(_templateGoal)));
      }
      // Drain the categories step before teardown.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
        'login into a reset account also wipes inherited onboarding '
        'content', (tester) async {
      final session = FakeSessionStore();
      final map = _foreignOnboardingMap();
      final backend = FakeSeedBackend(sessionStore: session)
        ..pullBody = {
          'profile': {'onboardingComplete': false},
          'entries': [
            {'id': 1}
          ],
          'categories': [
            {'id': 1}
          ],
        };
      final api = AuthApiClient(
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
      await _pumpAppFlow(tester,
          session: session,
          onboardingMap: map,
          backend: backend,
          authApi: api);
      await tester.tap(find.text('Log In'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'reset@tabs.app');
      await tester.enterText(fields.at(1), 'secret');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.userConditionsKey], isNull);
      expect(map[OnboardingStore.ownerEmailKey], 'reset@tabs.app');
    });
  });

  group('SettingsStore account-identity owner scoping', () {
    SettingsStore fakeSettings(Map<String, String> map) =>
        SettingsStore.withStorage(
          read: (k) async => map[k],
          write: (k, v) async => map[k] = v,
          delete: (k) async => map.remove(k),
        );

    Map<String, String> foreignIdentity() => <String, String>{
          SettingsStore.googleAccountEmailKey: 'old@example.com',
          SettingsStore.googleAccountConnectedKey: 'true',
          SettingsStore.googleCalendarEmailKey: 'old@example.com',
          SettingsStore.googleCalendarConnectedKey: 'true',
          SettingsStore.reportAppointmentDateKey: '2026-11-09',
          SettingsStore.reportAppointmentTypeKey: 'Checkup',
          SettingsStore.themeModeKey: 'LIGHT',
        };

    test('foreign identity keys are wiped on mismatch; device prefs '
        'survive', () async {
      final map = foreignIdentity();
      final store = fakeSettings(map);
      expect(await store.clearIdentityIfOwnerMismatch('new@tabs.app'),
          isTrue);
      for (final k in [
        SettingsStore.googleAccountEmailKey,
        SettingsStore.googleAccountConnectedKey,
        SettingsStore.googleCalendarEmailKey,
        SettingsStore.googleCalendarConnectedKey,
        SettingsStore.reportAppointmentDateKey,
        SettingsStore.reportAppointmentTypeKey,
      ]) {
        expect(map[k], isNull, reason: '$k must not be inherited');
      }
      expect(map[SettingsStore.themeModeKey], 'LIGHT',
          reason: 'device-level preferences are not account data');
      expect(map[SettingsStore.identityOwnerEmailKey], 'new@tabs.app');
    });

    test('the account\'s own identity keys are preserved', () async {
      final map = foreignIdentity()
        ..[SettingsStore.identityOwnerEmailKey] = 'old@example.com';
      final store = fakeSettings(map);
      expect(await store.clearIdentityIfOwnerMismatch('old@example.com'),
          isFalse);
      expect(map[SettingsStore.googleAccountEmailKey], 'old@example.com');
      expect(map[SettingsStore.reportAppointmentDateKey], '2026-11-09');
    });

    test('clearAccountIdentity wipes only the identity keys',
        () async {
      final map = foreignIdentity()
        ..[SettingsStore.identityOwnerEmailKey] = 'old@example.com';
      await fakeSettings(map).clearAccountIdentity();
      expect(map[SettingsStore.googleAccountEmailKey], isNull);
      expect(map[SettingsStore.identityOwnerEmailKey], isNull);
      expect(map[SettingsStore.themeModeKey], 'LIGHT');
    });
  });

  group('TipsCacheStore.clearIfOwnerMismatch', () {
    TipsCacheStore fakeTips(Map<String, String> map) {
      final store = TipsCacheStore();
      store.debugSetIO(
        read: (k) async => map[k],
        write: (k, v) async => map[k] = v,
        delete: (k) async => map.remove(k),
      );
      return store;
    }

    test('a previous account\'s cached topics/answers are wiped',
        () async {
      final map = <String, String>{
        TipsCacheStore.topicsKey: '["Old account topic"]',
        TipsCacheStore.answersKey: '{"Old account topic":["a tip"]}',
      };
      final store = fakeTips(map);
      expect(await store.clearIfOwnerMismatch('new@tabs.app'), isTrue);
      expect(await store.loadTopics(), isEmpty);
      expect(await store.loadAnswers(), isEmpty);
      expect(map[TipsCacheStore.ownerKey], 'new@tabs.app');
    });

    test('the account\'s own cache is preserved', () async {
      final map = <String, String>{
        TipsCacheStore.ownerKey: 'me@tabs.app',
        TipsCacheStore.topicsKey: '["My topic"]',
      };
      final store = fakeTips(map);
      expect(await store.clearIfOwnerMismatch('me@tabs.app'), isFalse);
      expect(await store.loadTopics(), ['My topic']);
    });
  });

  group('food history owner enforcement', () {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    void mockSecureStorage(Map<String, String> secure) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments is Map
            ? (call.arguments as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure['${args['key']}'] = '${args['value']}';
            return null;
          case 'delete':
            secure.remove(args['key']);
            return null;
          case 'deleteAll':
            secure.clear();
            return null;
          case 'readAll':
            return Map<String, String>.of(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
    }

    String historyJson() => encodeFoodEncyclopedia({
          'Peanuts': const FoodCheckResult(
            foodName: 'Peanuts',
            levels: [
              FoodTopicLevel(
                  topicName: 'Peanut', level: 'High', reasoning: 'r'),
            ],
          ),
        });

    test('SecureFoodHistoryStore wipes foreign unstamped history',
        () async {
      final secure = <String, String>{
        SecureFoodHistoryStore.storageKey: historyJson(),
      };
      mockSecureStorage(secure);
      const store = SecureFoodHistoryStore();
      expect(await store.clearIfOwnerMismatch('new@tabs.app'), isTrue);
      expect(secure[SecureFoodHistoryStore.storageKey], isNull);
      expect(secure[SecureFoodHistoryStore.ownerKey], 'new@tabs.app');
      // Same account again: nothing left to wipe.
      expect(await store.clearIfOwnerMismatch('new@tabs.app'), isFalse);
    });

    testWidgets(
        'the Food screen never renders a previous account\'s history',
        (tester) async {
      final secure = <String, String>{
        'user_email': 'new@tabs.app',
        SecureFoodHistoryStore.storageKey: historyJson(),
      };
      mockSecureStorage(secure);
      await tester.pumpWidget(const MaterialApp(home: FoodToolScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(secure[SecureFoodHistoryStore.storageKey], isNull,
          reason: 'mount enforcement wipes the foreign history');
      expect(find.text('Peanuts'), findsNothing);
      expect(find.text('Recently Checked'), findsNothing);
    });
  });

  group('session expiry identity wipe (AppFlow)', () {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    testWidgets(
        'forced expiry wipes the SettingsStore identity keys (and '
        'only those)', (tester) async {
      final secure = <String, String>{
        SettingsStore.googleAccountEmailKey: 'old@example.com',
        SettingsStore.googleAccountConnectedKey: 'true',
        SettingsStore.googleCalendarEmailKey: 'old@example.com',
        SettingsStore.reportAppointmentDateKey: '2026-11-09',
        SettingsStore.identityOwnerEmailKey: 'old@example.com',
        SettingsStore.themeModeKey: 'LIGHT',
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments is Map
            ? (call.arguments as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure['${args['key']}'] = '${args['value']}';
            return null;
          case 'delete':
            secure.remove(args['key']);
            return null;
          case 'deleteAll':
            secure.clear();
            return null;
          case 'readAll':
            return Map<String, String>.of(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        TabsBackend.onSessionExpired = null;
      });
      // Home's Daily Score chain captures through a real
      // HealthConnectService (HomeScreen builds its snapshot sync
      // without the injected service; the designated seam is the
      // snapshot-capture override, which AppFlow does not thread).
      // Answer the bridge channel with null — reads come back
      // empty and complete — so no bounded-read guard timer is
      // left pending at teardown.
      const hcChannel =
          MethodChannel(HealthConnectService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hcChannel, (_) async => null);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(hcChannel, null);
      });

      final session = FakeSessionStore()
        ..token = 'fake-token-expiry'
        ..refreshToken = 'fake-refresh-expiry'
        ..email = 'old@example.com';
      await tester.pumpWidget(MaterialApp(
        home: AppFlow(
          authApi: AuthApiClient(
              client: MockClient((_) async => http.Response('{}', 200))),
          sessionStore: session,
          onboardingStore: OnboardingStore.withStorage(
            read: (k) async => null,
            write: (k, v) async {},
            delete: (k) async {},
          ),
          tabsBackend: FakeSeedBackend(sessionStore: session),
          weatherApi: WeatherApiClient(client: _mockWeatherClient()),
          healthConnectService: FakeSeedHC(),
          notificationService: FakeReminderNotificationService(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(secure[SettingsStore.googleAccountEmailKey],
          'old@example.com');

      TabsBackend.onSessionExpired?.call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(secure.containsKey(SettingsStore.googleAccountEmailKey),
          isFalse,
          reason: 'expiry must wipe the expired account\'s Google '
              'identity');
      expect(
          secure.containsKey(SettingsStore.googleAccountConnectedKey),
          isFalse);
      expect(secure.containsKey(SettingsStore.reportAppointmentDateKey),
          isFalse);
      expect(secure[SettingsStore.themeModeKey], 'LIGHT',
          reason: 'the targeted wipe leaves device prefs alone');
      // The login/register funnels re-stamp ownership for whoever
      // signs in next; the expiry wipe also drops the stamp.
      expect(secure.containsKey(SettingsStore.identityOwnerEmailKey),
          isFalse);
      await tester.pump(const Duration(milliseconds: 300));
    });
  });
}
