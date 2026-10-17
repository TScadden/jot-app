import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
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

/// A session store whose clear() throws, simulating a secure-storage
/// failure in the middle of the account wipe (R29b fault isolation).
class ThrowingSessionStore extends FakeSessionStore {
  @override
  Future<void> clear() async {
    throw StateError('secure storage unavailable');
  }
}

/// Seeds the REAL account-bound cache singletons with this
/// account's data (the same wiring the logout test originally used).
/// The Round 35 Today Summary stores joined the logout wipe in
/// Vera's R35 re-review (HIGH 2), so they are wired to the same
/// fake disk — otherwise their clears would await the real secure-
/// storage channel, whose futures never complete under FakeAsync.
void seedRealCaches() {
  final cacheDisk = <String, String>{};
  void wireCache(dynamic cache) => cache.debugSetStore(
        read: (k) async => cacheDisk[k],
        write: (k, v) async => cacheDisk[k] = v,
        delete: (k) async => cacheDisk.remove(k),
      );
  wireCache(HomeDataCache.instance);
  wireCache(QuickLogCache.instance);
  wireCache(HeartDataCache.instance);
  wireCache(TodaySummaryCache.instance);
  wireCache(TodayPlanStore.instance);
  // Round 55: coach memory joined the account-bound caches — wire
  // its singleton to the same in-memory disk so the real wipe in
  // these flows completes against it too.
  CoachMemoryStore.instance.debugSetStore(
    read: (k) async => cacheDisk[k],
    write: (k, v) async => cacheDisk[k] = v,
    delete: (k) async => cacheDisk.remove(k),
  );
  // Round 65: the extracted-text cache joined the account-bound
  // caches — wire its singleton to the same fake disk.
  KnowledgeExtractionStore.instance.debugSetStore(
    read: (k) async => cacheDisk[k],
    write: (k, v) async => cacheDisk[k] = v,
    delete: (k) async => cacheDisk.remove(k),
  );
  // R70 fix pass A4: the historical health store joined the logout
  // wipe — wire it to the same fake disk for the same FakeAsync
  // reason (a real secure-storage channel's futures never complete
  // under FakeAsync and the wipe would hang).
  HealthHistoryStore.instance.debugSetStore(
    read: (k) async => cacheDisk[k],
    write: (k, v) async => cacheDisk[k] = v,
    delete: (k) async => cacheDisk.remove(k),
  );
  HealthHistoryStore.instance.debugReset();
  HomeDataCache.instance.debugReset();
  HomeDataCache.instance.applyVitals(
      const TodayVitals(heartRate: 80), ownerEmail: 'a@example.com');
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
  HeartDataCache.instance.debugReset();
  HeartDataCache.instance.apply('2026-10-12', [
    HrSample(
        timeMs: DateTime(2026, 10, 12, 9).millisecondsSinceEpoch,
        bpm: 82),
  ], ownerEmail: 'a@example.com');
}

void expectRealCachesSeeded() {
  expect(HomeDataCache.instance.snapshot.vitalsLoaded, isTrue);
  expect(QuickLogCache.instance.snapshot.categoriesLoaded, isTrue);
  expect(HeartDataCache.instance.hasDate('2026-10-12'), isTrue);
}

void expectRealCachesEmpty() {
  expect(HomeDataCache.instance.snapshot.vitalsLoaded, isFalse);
  expect(QuickLogCache.instance.snapshot.categoriesLoaded, isFalse);
  expect(HeartDataCache.instance.hasDate('2026-10-12'), isFalse);
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


/// Pumps with a tall viewport: the native Settings pages are long
/// ListViews and the default 800x600 test surface leaves lower rows
/// below the fold (unbuilt / untappable).
Future<void> pumpSettings(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(w);
  await tester.pumpAndSettle();
}

Widget host(SettingsScreen screen) =>
    MaterialApp(home: Scaffold(body: screen));

SettingsScreen screen({
  required FakeSettingsBackend backend,
  required SettingsStore store,
  AccountActions? actions,
  VoidCallback? onLogout,
  List<Uri>? launched,
  FakeReminderNotificationService? notifs,
}) =>
    SettingsScreen(
      backend: backend,
      settingsStore: store,
      accountActions: actions,
      onLogout: onLogout,
      // Round 30: reminder toggles now run the permission gate before
      // persisting; the fake reports notifications already granted so
      // the Round 29 persistence assertions exercise the same path a
      // granted device takes.
      notificationService: notifs ?? FakeReminderNotificationService(),
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
      await pumpSettings(tester, host(screen(
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
      await pumpSettings(tester, host(screen(
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
      await pumpSettings(tester, host(screen(
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
      await pumpSettings(tester, host(screen(
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
      await pumpSettings(tester, host(screen(
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
      await pumpSettings(tester, host(screen(backend: backend, store: fakeStore(map))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Customize'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('nav_labels_toggle')).findSwitch());
      await tester.pumpAndSettle();
      expect(map[SettingsStore.showNavLabelsKey], 'false');
      // Round 30: the Juno MF-R29-1 honesty note is retired — the
      // dock renders labels now (see settings_r30_navlabels_test).
      expect(
          find.text(
              'Your choice is saved on this device. The Flutter Lab dock does not show labels yet.'),
          findsNothing);
    });

    testWidgets('theme choice persists to the device store',
        (tester) async {
      final map = <String, String>{};
      final backend = FakeSettingsBackend()..pullBody = pull();
      await pumpSettings(tester, host(screen(backend: backend, store: fakeStore(map))));
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
      await pumpSettings(tester, host(screen(
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
      await pumpSettings(tester, host(screen(
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
      // Footer copy (Round 30): reminders now schedule and fire;
      // the HR alerts stay preference-only and the copy says so
      // (Juno N1 — footer covers alerts as well as reminders).
      expect(
          find.textContaining(
              'the alerts do not fire from the Flutter app yet'),
          findsOneWidget);
    });

    testWidgets('check-in toggle persists locally only', (tester) async {
      final map = <String, String>{};
      final backend = FakeSettingsBackend()..pullBody = pull();
      await pumpSettings(tester, host(screen(backend: backend, store: fakeStore(map))));
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
      await pumpSettings(tester, host(screen(
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
      await pumpSettings(tester, host(screen(
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
      await pumpSettings(tester, host(screen(backend: backend, store: fakeStore(map))));
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
      await pumpSettings(tester, host(screen(
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

  group('HR threshold fields (native guards)', () {
    Future<void> openNotifications(
        WidgetTester tester, FakeSettingsBackend backend) async {
      await pumpSettings(tester, host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'spike: out-of-range submits are not pushed and the field reverts',
        (tester) async {
      final backend = FakeSettingsBackend()
        ..pullBody = pull(profile: {
          'hrSpikeAlertsEnabled': true,
          'spikeThreshold': 120,
        });
      await openNotifications(tester, backend);
      final field = find.byKey(const ValueKey('spike_threshold_field'));
      expect(field, findsOneWidget);
      // 0 is below native's 40..250 save range.
      await tester.enterText(field, '0');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
          backend.profilePushes
              .where((p) => p.containsKey('spikeThreshold')),
          isEmpty);
      expect(tester.widget<TextField>(field).controller!.text, '120');
      // 999 fits the 3-char cap but is above the range.
      await tester.enterText(field, '999');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
          backend.profilePushes
              .where((p) => p.containsKey('spikeThreshold')),
          isEmpty);
      expect(tester.widget<TextField>(field).controller!.text, '120');
    });

    testWidgets('spike: in-range value pushes; input capped at 3 digits',
        (tester) async {
      final backend = FakeSettingsBackend()
        ..pullBody = pull(profile: {
          'hrSpikeAlertsEnabled': true,
          'spikeThreshold': 120,
        });
      await openNotifications(tester, backend);
      final field = find.byKey(const ValueKey('spike_threshold_field'));
      await tester.enterText(field, '150');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(backend.profilePushes,
          contains(equals({'spikeThreshold': 150})));
      // Length cap: from an empty field, a 4-digit entry truncates
      // to 3 digits (LengthLimitingTextInputFormatter(3)).
      await tester.enterText(field, '');
      await tester.enterText(field, '1234');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '123');
    });

    testWidgets(
        'delta: below-5 submit is not pushed and reverts; in-range pushes; cap 2 digits',
        (tester) async {
      final backend = FakeSettingsBackend()
        ..pullBody = pull(profile: {
          'hrDeltaEnabled': true,
          'spikeDeltaThreshold': 30,
        });
      await openNotifications(tester, backend);
      final field = find.byKey(const ValueKey('delta_threshold_field'));
      expect(field, findsOneWidget);
      await tester.enterText(field, '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
          backend.profilePushes
              .where((p) => p.containsKey('spikeDeltaThreshold')),
          isEmpty);
      expect(tester.widget<TextField>(field).controller!.text, '30');
      // Length cap: from an empty field, a 3-digit entry truncates
      // to 2 digits (LengthLimitingTextInputFormatter(2)).
      await tester.enterText(field, '');
      await tester.enterText(field, '123');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '12');
      await tester.enterText(field, '45');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(backend.profilePushes,
          contains(equals({'spikeDeltaThreshold': 45})));
    });
  });

  group('Edit Profile save (omit-blank)', () {
    Future<void> openEditProfile(
        WidgetTester tester, FakeSettingsBackend backend) async {
      await pumpSettings(tester, host(screen(
          backend: backend, store: fakeStore(<String, String>{}))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit_profile_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile_save')), findsOneWidget);
    }

    testWidgets('save after a failed pull sends nothing (no zero-clobber)',
        (tester) async {
      final backend = FakeSettingsBackend(); // pullBody null → pull failed
      await openEditProfile(tester, backend);
      await tester.tap(find.byKey(const ValueKey('profile_save')));
      await tester.pumpAndSettle();
      expect(backend.profilePushes, isEmpty);
      expect(find.byKey(const ValueKey('profile_save')), findsNothing);
    });

    testWidgets('only non-blank parseable fields are pushed',
        (tester) async {
      final backend = FakeSettingsBackend()..pullBody = pull();
      await openEditProfile(tester, backend);
      await tester.enterText(
          find.widgetWithText(TextField, 'Age'), '30');
      await tester.tap(find.byKey(const ValueKey('profile_save')));
      await tester.pumpAndSettle();
      // Exactly one push with exactly one key — no age/height/weight/
      // gender zeroed companions.
      expect(backend.profilePushes, [equals({'age': 30})]);
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
      seedRealCaches();
      expectRealCachesSeeded();

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
      expectRealCachesEmpty();
      expect(storeMap, isEmpty);
    });

    test(
        'logout still clears caches + settings when session clear throws',
        () async {
      // R29b fault isolation: SessionStore.clear() is the one clear
      // that can throw on a storage error; the wipe must not stop
      // there — caches and settings still get cleared.
      final session = ThrowingSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session);
      final storeMap = <String, String>{'settings_theme_mode': 'LIGHT'};
      seedRealCaches();
      expectRealCachesSeeded();

      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(storeMap),
      );
      final revoked = await actions.logout();
      expect(revoked, isTrue);
      expectRealCachesEmpty();
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

    test('delete success wipes the session and all three real caches',
        () async {
      // Juno N5 (R29b): seed the REAL cache singletons (as the
      // logout test does) instead of the injected clearCaches stub,
      // so the delete path is proven against the production wipe.
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session);
      final storeMap = <String, String>{'settings_theme_mode': 'LIGHT'};
      seedRealCaches();
      expectRealCachesSeeded();
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(storeMap),
      );
      expect(await actions.deleteAccount(), isTrue);
      expect(session.token, isNull);
      expectRealCachesEmpty();
      expect(storeMap, isEmpty);
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
      await pumpSettings(tester, host(screen(
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
        'logout flushes a Personal Context edit still inside its debounce',
        (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session)
        ..pullBody = pull();
      var loggedOut = false;
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(<String, String>{}),
        clearCaches: () async {},
      );
      await pumpSettings(tester, host(screen(
        backend: backend,
        store: fakeStore(<String, String>{}),
        actions: actions,
        onLogout: () => loggedOut = true,
      )));
      await tester.pumpAndSettle();
      // Edit inside the 3 s debounce window, then log out at once:
      // the pending push must flush before the wipe, not be lost.
      await tester.enterText(
          find.byKey(const ValueKey('personal_context_field')),
          'training for a marathon');
      await tester.tap(find.byKey(const ValueKey('logout_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm_logout')));
      await tester.pumpAndSettle();
      expect(backend.profilePushes,
          contains(equals({'userContext': 'training for a marathon'})));
      expect(loggedOut, isTrue);
    });

    testWidgets(
        'logout dialog: session clear throws → onLogout still fires, caches cleared',
        (tester) async {
      // R29b: a storage throw during the wipe must not wedge the
      // logout dialog in its logging-out state or skip the rest of
      // the wipe.
      final session = ThrowingSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = FakeSettingsBackend(sessionStore: session);
      var loggedOut = false;
      seedRealCaches();
      expectRealCachesSeeded();
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: fakeStore(<String, String>{}),
      );
      await pumpSettings(tester, host(screen(
        backend: backend,
        store: fakeStore(<String, String>{}),
        actions: actions,
        onLogout: () => loggedOut = true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('logout_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm_logout')));
      await tester.pumpAndSettle();
      expect(loggedOut, isTrue);
      expectRealCachesEmpty();
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
      await pumpSettings(tester, host(screen(
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
