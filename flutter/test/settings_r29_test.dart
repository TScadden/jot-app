import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'test_helpers.dart';

/// Round 29 — Settings: native sections render, toggle persistence
/// round-trips (device store + profile push payload), membership
/// state comes from the (mocked) pull, logout clears the session and
/// ALL THREE account-bound caches, and the delete-account path keeps
/// the session intact on server failure.
class FakeSettingsBackend extends TabsBackend {
  Map<String, dynamic>? pullBody;
  final List<Map<String, dynamic>> profilePushes = [];
  bool pushResult = true;
  bool logoutResult = true;
  bool deleteResult = true;
  int invalidateCount = 0;

  FakeSettingsBackend({super.sessionStore});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pullBody;

  @override
  void invalidateSyncPull() {
    invalidateCount++;
  }

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePushes.add(fields);
    return pushResult;
  }

  @override
  Future<Map<String, dynamic>?> updateNickname(String nickname) async =>
      {'success': true, 'nickname': nickname, 'tag': '4242'};

  @override
  Future<bool> logoutAccount() async => logoutResult;

  @override
  Future<bool> deleteAccount() async => deleteResult;
}

SettingsStore fakeStore(Map<String, String> map) => SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

Map<String, dynamic> pull({
  bool isUnlimited = false,
  bool isAdmin = false,
  Map<String, dynamic> profile = const {},
}) =>
    {
      'isUnlimited': isUnlimited,
      'isAdmin': isAdmin,
      'nickname': 'Tyson',
      'tag': '1234',
      'profile': profile,
      'insights': const [],
    };

Widget host(SettingsScreen screen) =>
    MaterialApp(home: Scaffold(body: screen));

SettingsScreen screen({
  required FakeSettingsBackend backend,
  required SettingsStore store,
  AccountActions? actions,
  VoidCallback? onLogout,
  List<Uri>? launched,
}) =>
    SettingsScreen(
      backend: backend,
      settingsStore: store,
      accountActions: actions,
      onLogout: onLogout,
      urlLauncher: (uri) async {
        launched?.add(uri);
        return true;
      },
    );

void main() {
  group('SettingsProfileData.fromPull', () {
    test('free vs unlimited vs admin membership copy', () {
      final free = SettingsProfileData.fromPull(pull());
      expect(free.membershipTitle, 'No Active Membership');
      expect(free.membershipBadge, 'INACTIVE');
      expect(free.membershipLevel, 'Standard');

      final premium =
          SettingsProfileData.fromPull(pull(isUnlimited: true));
      expect(premium.membershipTitle, 'Tabs Premium');
      expect(premium.membershipBadge, 'ACTIVE');
      expect(premium.membershipLevel, 'Unlimited');

      final admin = SettingsProfileData.fromPull(pull(isAdmin: true));
      expect(admin.isUnlimited, isTrue); // server: isAdmin implies unlimited
      expect(admin.membershipTitle, 'Admin Account');
      expect(admin.membershipBadge, 'ADMIN');
      expect(admin.membershipSubtitle,
          'Developer Access · All Features Unlocked');
    });

    test('tolerant parsing: int8-style string fields', () {
      final d = SettingsProfileData.fromPull(pull(profile: {
        'age': '22',
        'spikeThreshold': '130',
        'habitReminderEnabled': 'true',
        'userContext': 'training',
      }));
      expect(d.age, 22);
      expect(d.spikeThreshold, 130);
      expect(d.habitReminderEnabled, isTrue);
      expect(d.userContext, 'training');
    });

    test('null body → native defaults', () {
      final d = SettingsProfileData.fromPull(null);
      expect(d.isUnlimited, isFalse);
      expect(d.spikeThreshold, 120);
      expect(d.spikeDeltaThreshold, 30);
      expect(d.projectReminderEnabled, isTrue);
      expect(d.shareDataWithFriends, isTrue);
    });
  });

  group('SettingsStore round-trip', () {
    test('toggle persistence round-trip', () async {
      final map = <String, String>{};
      final store = fakeStore(map);
      expect(await store.getShowNavLabels(), isTrue); // native default
      await store.setShowNavLabels(false);
      expect(await store.getShowNavLabels(), isFalse);
      await store.setThemeMode('LIGHT');
      expect(await store.getThemeMode(), 'LIGHT');
      await store.setCheckInReminderEnabled(false);
      expect(await store.getCheckInReminderEnabled(), isFalse);
      await store.setLastSyncTimeMs(12345);
      expect(await store.getLastSyncTimeMs(), 12345);
      await store.clear();
      expect(map, isEmpty);
      expect(await store.getThemeMode(), 'DARK'); // native default
    });
  });

  group('Settings screen', () {
    testWidgets('main page renders native sections and rows',
        (tester) async {
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Membership'), findsWidgets);
      expect(find.text('Personal Context'), findsOneWidget);
      expect(find.text('User Profile'), findsWidgets);
      expect(find.text('Customize'), findsOneWidget);
      expect(find.text('AI & Clinical Advocate'), findsOneWidget);
      expect(find.text('Event Counters'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Sync Settings'), findsOneWidget);
      expect(find.text('Connected Apps'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Tabs v1.0'), findsOneWidget);
      expect(find.text('Terms of Use'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Reset Account Status'), findsOneWidget);
      // Admin-only rows stay hidden for a free account.
      expect(find.text('Tabs Live Beta'), findsNothing);
      expect(find.text('Developer Terminal Options'), findsNothing);
    });

    testWidgets('terms and privacy open native URLs', (tester) async {
      final launched = <Uri>[];
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(host(screen(
          backend: backend,
          store: fakeStore(<String, String>{}),
          launched: launched)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terms of Use'));
      await tester.tap(find.text('Privacy Policy'));
      expect(
          launched.map((u) => u.toString()),
          containsAll([
            'https://api.jottracker.com/terms.html',
            'https://api.jottracker.com/privacy.html',
          ]));
    });

    testWidgets('membership segment shows free state + plan cards',
        (tester) async {
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Membership').last);
      await tester.pumpAndSettle();
      expect(find.text('No Active Membership'), findsOneWidget);
      expect(find.text('INACTIVE'), findsOneWidget);
      expect(find.text('Standard'), findsOneWidget);
      expect(find.text('Monthly Plan'), findsOneWidget);
      expect(find.text('Yearly Plan'), findsOneWidget);
      expect(find.text('Pricing shown in Google Play'), findsWidgets);
      expect(find.text('Start 7-day free trial'), findsOneWidget);
      expect(
          find.text(
              'Tabs Premium is for education and personal self tracking only. It does not provide medical advice, diagnosis, or treatment. Talk to a qualified health professional about any health decisions.'),
          findsOneWidget);
    });

    testWidgets('membership segment shows unlimited state from pull',
        (tester) async {
      final backend = FakeSettingsBackend()
        ..pullBody = pull(isUnlimited: true);
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Membership').last);
      await tester.pumpAndSettle();
      expect(find.text('Tabs Premium'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('Unlimited'), findsOneWidget);
      expect(find.text('You have full unlimited access to all AI features.'),
          findsOneWidget);
      expect(find.text('Monthly Plan'), findsNothing);
      expect(
          find.text(
              'Thank you for being a member! Your support keeps Tabs improving.'),
          findsOneWidget);
    });

    testWidgets('purchase CTA shows honest Google Play unavailable',
        (tester) async {
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Membership').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('membership_cta')));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Subscriptions are purchased through Google Play in the Tabs app. The Flutter Lab cannot start a subscription yet.'),
          findsOneWidget);
    });

    testWidgets('nav labels toggle persists to the device store',
        (tester) async {
      final map = <String, String>{};
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(
          host(screen(backend: backend, store: fakeStore(map))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Customize'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('nav_labels_toggle')).findSwitch());
      await tester.pumpAndSettle();
      expect(map[SettingsStore.showNavLabelsKey], 'false');
    });

    testWidgets('theme choice persists to the device store',
        (tester) async {
      final map = <String, String>{};
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(
          host(screen(backend: backend, store: fakeStore(map))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Customize'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('theme_LIGHT')));
      await tester.pumpAndSettle();
      expect(map[SettingsStore.themeModeKey], 'LIGHT');
    });

    testWidgets('share-data toggle pushes the profile field',
        (tester) async {
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync Settings'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('share_data_toggle')).findSwitch());
      await tester.pumpAndSettle();
      expect(backend.profilePushes,
          contains(equals({'shareDataWithFriends': false})));
    });

    testWidgets('habit reminder toggle pushes the profile field',
        (tester) async {
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find
          .byKey(const ValueKey('habit_reminder_toggle'))
          .findSwitch());
      await tester.pumpAndSettle();
      expect(backend.profilePushes,
          contains(equals({'habitReminderEnabled': true})));
    });

    testWidgets('check-in toggle persists locally only', (tester) async {
      final map = <String, String>{};
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(
          host(screen(backend: backend, store: fakeStore(map))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find
          .byKey(const ValueKey('checkin_reminder_toggle'))
          .findSwitch());
      await tester.pumpAndSettle();
      expect(map[SettingsStore.checkInReminderKey], 'false');
      // Native never pushes this key to the server.
      expect(backend.profilePushes, isEmpty);
    });

    testWidgets('auto AI toggle pushes the profile field', (tester) async {
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI & Clinical Advocate'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('auto_ai_toggle')).findSwitch());
      await tester.pumpAndSettle();
      expect(backend.profilePushes,
          contains(equals({'autoAiSuggestions': true})));
    });

    testWidgets('user profile shows nickname, tag and health values',
        (tester) async {
      final backend = FakeSettingsBackend()
        ..pullBody = pull(profile: {
          'age': 22,
          'heightCm': 177.8, // 70 in → 5'10"
          'weightKg': 68.0, // → 150 lbs
          'gender': 'Male',
        });
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
      await tester.pumpAndSettle();
      expect(find.text('Tyson'), findsOneWidget);
      expect(find.text('#1234'), findsOneWidget);
      expect(find.text('Age: 22'), findsOneWidget);
      expect(find.text('Height: 5\'10" (70 in)'), findsOneWidget);
      expect(find.text('Weight: 150 lbs'), findsOneWidget);
      expect(find.text('Gender: Male'), findsOneWidget);
    });

    testWidgets('sync now stamps last-sync on success', (tester) async {
      final map = <String, String>{};
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(
          host(screen(backend: backend, store: fakeStore(map))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sync_now_button')));
      await tester.pumpAndSettle();
      expect(map[SettingsStore.lastSyncTimeKey], isNotNull);
      expect(find.textContaining('Last synced:'), findsOneWidget);
    });

    testWidgets('event counter add pushes eventCounters JSON',
        (tester) async {
      final backend = FakeSettingsBackend()..pullBody = pull();
      await tester.pumpWidget(host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event Counters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add_counter')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('counter_name_field')),
          'Next Doctor Appt');
      await tester.tap(find.byKey(const ValueKey('counter_save')));
      await tester.pumpAndSettle();
      final push = backend.profilePushes
          .firstWhere((p) => p.containsKey('eventCounters'));
      expect(push['eventCounters'], contains('Next Doctor Appt'));
      expect(find.text('Next Doctor Appt'), findsOneWidget);
    });
  });

  group('AccountActions', () {
    test('logout clears session + all three caches + settings',
        () async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session);
      final storeMap = <String, String>{'settings_theme_mode': 'LIGHT'};
      final store = fakeStore(storeMap);

      // Seed all three account-bound caches with this account's data.
      final cacheDisk = <String, String>{};
      void wireCache(dynamic cache) => cache.debugSetStore(
            read: (k) async => cacheDisk[k],
            write: (k, v) async => cacheDisk[k] = v,
            delete: (k) async => cacheDisk.remove(k),
          );
      wireCache(HomeDataCache.instance);
      wireCache(QuickLogCache.instance);
      wireCache(HeartDataCache.instance);
      HomeDataCache.instance.debugReset();
      HomeDataCache.instance.applyVitals(
          const TodayVitals(heartRate: 80), ownerEmail: 'a@example.com');
      expect(HomeDataCache.instance.snapshot.vitalsLoaded, isTrue);

      QuickLogCache.instance.debugReset();
      QuickLogCache.instance.applyLoad(
        categories: const [
          QuickLogCategory(
              id: 1,
              name: 'Mood',
              icon: '',
              colorHex: '',
              isDefault: true,
              sortOrder: 0),
        ],
        recentSuggestions: const [],
        todayCount: 3,
        isUnlimited: false,
        isAdmin: false,
        ownerEmail: 'a@example.com',
      );
      expect(QuickLogCache.instance.snapshot.categoriesLoaded, isTrue);

      HeartDataCache.instance.debugReset();
      HeartDataCache.instance.apply('2026-10-12', [
        HrSample(
            timeMs: DateTime(2026, 10, 12, 9).millisecondsSinceEpoch,
            bpm: 82),
      ], ownerEmail: 'a@example.com');
      expect(HeartDataCache.instance.hasDate('2026-10-12'), isTrue);

      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: store,
      );
      final revoked = await actions.logout();
      expect(revoked, isTrue);
      expect(session.token, isNull);
      expect(session.refreshToken, isNull);
      expect(session.email, isNull);
      expect(HomeDataCache.instance.snapshot.vitalsLoaded, isFalse);
      expect(QuickLogCache.instance.snapshot.categoriesLoaded, isFalse);
      expect(HeartDataCache.instance.hasDate('2026-10-12'), isFalse);
      expect(storeMap, isEmpty);
    });

    test('logout still wipes locally when the server revoke fails',
        () async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session)
        ..logoutResult = false;
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(<String, String>{}),
        clearCaches: () async {},
      );
      final revoked = await actions.logout();
      expect(revoked, isFalse);
      expect(session.token, isNull);
    });

    test('delete success wipes the session', () async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session);
      var cachesCleared = false;
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(<String, String>{}),
        clearCaches: () async => cachesCleared = true,
      );
      expect(await actions.deleteAccount(), isTrue);
      expect(session.token, isNull);
      expect(cachesCleared, isTrue);
    });

    test('delete failure keeps the session and caches untouched',
        () async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session)
        ..deleteResult = false;
      var cachesCleared = false;
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(<String, String>{}),
        clearCaches: () async => cachesCleared = true,
      );
      expect(await actions.deleteAccount(), isFalse);
      expect(session.token, 'tok');
      expect(cachesCleared, isFalse);
    });
  });

  group('Settings screen account flows', () {
    testWidgets('logout dialog confirms → onLogout fires, session gone',
        (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session);
      var loggedOut = false;
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(<String, String>{}),
        clearCaches: () async {},
      );
      await tester.pumpWidget(host(screen(
        backend: backend,
        store: fakeStore(<String, String>{}),
        actions: actions,
        onLogout: () => loggedOut = true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('logout_button')));
      await tester.pumpAndSettle();
      expect(find.text('Logout?'), findsOneWidget);
      expect(
          find.text(
              'Your data will be synced to the cloud before logging out.'),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm_logout')));
      await tester.pumpAndSettle();
      expect(session.token, isNull);
      expect(loggedOut, isTrue);
    });

    testWidgets(
        'delete via Privacy & Deletion: failure keeps session, shows error',
        (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session)
        ..deleteResult = false;
      var loggedOut = false;
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(<String, String>{}),
        clearCaches: () async {},
      );
      await tester.pumpWidget(host(screen(
        backend: backend,
        store: fakeStore(<String, String>{}),
        actions: actions,
        onLogout: () => loggedOut = true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Privacy & Deletion'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('delete_account_button')));
      await tester.tap(find.byKey(const ValueKey('delete_account_button')));
      await tester.pumpAndSettle();
      expect(find.text('Delete Account and Data?'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('confirm_delete_account')));
      await tester.pumpAndSettle();
      expect(session.token, 'tok');
      expect(loggedOut, isFalse);
      expect(find.textContaining('Could not delete your account'),
          findsOneWidget);
    });
  });
}

extension on Finder {
  /// The Switch inside a keyed toggle row.
  Finder findSwitch() =>
      find.descendant(of: this, matching: find.byType(Switch));
}
