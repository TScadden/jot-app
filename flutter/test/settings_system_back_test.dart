import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'settings_r30_google_test.dart' as r30g;
import 'test_helpers.dart';

/// Founder fix (Oct 27, 2026) — Android system back (edge swipe)
/// exited the app from every Settings sub-page. The sub-pages are
/// body swaps inside the single Settings route (the `_Page` enum),
/// so the Navigator had nothing to pop; only the app-bar arrow,
/// which flips the internal page state, behaved. The fix wraps the
/// Settings scaffold in a PopScope that intercepts the pop on any
/// sub-page and runs the same `_back()` logic as the arrow.
///
/// These tests push Settings over a launcher route so a wrongful
/// pop is observable (the launcher would reappear), and drive a
/// REAL system back via [WidgetsBinding.handlePopRoute] — the
/// entry point the Android back gesture funnels into.
class MemorySecureStore implements SecureStore {
  final Map<String, String> map = {};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
  @override
  Future<void> delete(String key) async => map.remove(key);
}

class FakeHCService extends HealthConnectService {
  FakeHCService() : super(store: MemorySecureStore());

  // Phase 2 PR-2 re-point: Settings derives from the probe
  // snapshot — a known empty grant is the notConnected state.
  @override
  Future<HcAvailability> probeAvailability() async =>
      const HcAvailability(
        serviceAvailable: true,
        grantedPermissions: {},
        bridgeErrorCode: null,
        stepsProbe: null,
        persistedConnected: false,
      );
}

SettingsStore _store(Map<String, String> map) => SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

/// Pushes a [SettingsScreen] over a minimal launcher page. The
/// launcher stays in the tree under the pushed route, so any pop
/// that leaves Settings is directly observable.
Future<void> pumpPushedSettings(
  WidgetTester tester, {
  bool openEventCounters = false,
  bool openAiKnowledge = false,
}) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final backend = r30g.LinkBackend()..pullBody = r29.pull();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  backend: backend,
                  settingsStore: _store({}),
                  notificationService: FakeReminderNotificationService(),
                  googleSignInService: r30g.FakeGoogle(),
                  healthConnectService: FakeHCService(),
                  urlLauncher: (uri) async => true,
                  openEventCounters: openEventCounters,
                  openAiKnowledge: openAiKnowledge,
                ),
              ),
            ),
            child: const Text('OPEN SETTINGS'),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OPEN SETTINGS'));
  await tester.pumpAndSettle();
}

/// One Android system-back press, delivered the way the OS
/// delivers it.
Future<void> systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

String appBarTitle(WidgetTester tester) {
  final title = tester.widget<Text>(find.descendant(
    of: find.byType(AppBar),
    matching: find.byType(Text),
  ));
  return title.data!;
}

void expectOnMenu(WidgetTester tester) {
  expect(find.byType(SettingsScreen), findsOneWidget,
      reason: 'the Settings route must still be on top');
  expect(find.text('OPEN SETTINGS'), findsNothing,
      reason: 'the route under Settings must not be exposed');
  expect(appBarTitle(tester), 'Settings');
  expect(find.byKey(const ValueKey('menu_user_profile')), findsOneWidget);
}

void expectPoppedToLauncher(WidgetTester tester) {
  expect(find.byType(SettingsScreen), findsNothing,
      reason: 'the Settings route should have been popped');
  expect(find.text('OPEN SETTINGS'), findsOneWidget);
}

void main() {
  group('Settings system back (Oct 27, 2026 founder fix)', () {
    testWidgets('User Profile: system back returns to the Settings menu',
        (tester) async {
      await pumpPushedSettings(tester);
      await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
      await tester.pumpAndSettle();
      expect(appBarTitle(tester), 'User Profile');

      await systemBack(tester);

      expectOnMenu(tester);
    });

    testWidgets('Event Counters: system back returns to the Settings menu',
        (tester) async {
      await pumpPushedSettings(tester);
      await tester.tap(find.text('Event Counters'));
      await tester.pumpAndSettle();
      expect(appBarTitle(tester), 'Event Counters');

      await systemBack(tester);

      expectOnMenu(tester);
    });

    testWidgets('Membership segment: system back returns to the menu page',
        (tester) async {
      await pumpPushedSettings(tester);
      await tester.tap(find.text('Membership'));
      await tester.pumpAndSettle();
      expect(appBarTitle(tester), 'Membership');

      await systemBack(tester);

      expectOnMenu(tester);
    });

    testWidgets(
        'Progress Reports: system back returns to the AI page, then the menu',
        (tester) async {
      await pumpPushedSettings(tester);
      await tester.tap(find.text('AI & Clinical Advocate'));
      await tester.pumpAndSettle();
      expect(appBarTitle(tester), 'AI & Clinical Advocate');

      await tester.ensureVisible(find.text('Progress Reports'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Progress Reports'));
      await tester.pumpAndSettle();
      expect(appBarTitle(tester), 'Progress Reports');

      // Same target as the app-bar arrow: the AI page this was
      // opened from, NOT the menu.
      await systemBack(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(appBarTitle(tester), 'AI & Clinical Advocate');

      await systemBack(tester);
      expectOnMenu(tester);
    });

    testWidgets('menu page: system back keeps the default pop behavior',
        (tester) async {
      await pumpPushedSettings(tester);
      expectOnMenu(tester);

      await systemBack(tester);

      expectPoppedToLauncher(tester);
    });

    testWidgets(
        'pushed straight at Event Counters: system back pops to the caller',
        (tester) async {
      await pumpPushedSettings(tester, openEventCounters: true);
      expect(appBarTitle(tester), 'Event Counters');

      await systemBack(tester);

      expectPoppedToLauncher(tester);
    });

    // Home redesign mirror: the drawer's "AI Advocate" row pushes
    // Settings with openAiKnowledge, modeled exactly on
    // openEventCounters — it must land on the AI page and system
    // back must pop straight to the caller (Home), NOT step to
    // the Settings menu.
    testWidgets(
        'pushed straight at AI Knowledge (openAiKnowledge): lands on '
        'the AI page; system back pops to the caller', (tester) async {
      await pumpPushedSettings(tester, openAiKnowledge: true);
      expect(appBarTitle(tester), 'AI & Clinical Advocate');

      await systemBack(tester);

      expectPoppedToLauncher(tester);
    });

    testWidgets(
        'openAiKnowledge: the AppBar arrow also pops to the caller',
        (tester) async {
      await pumpPushedSettings(tester, openAiKnowledge: true);
      expect(appBarTitle(tester), 'AI & Clinical Advocate');

      await tester.tap(find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.arrow_back),
      ));
      await tester.pumpAndSettle();

      expectPoppedToLauncher(tester);
    });

    // Home redesign: the watch IconButton lives in the Settings
    // AppBar now, gated to the main menu page.
    testWidgets(
        'watch button: present on the main page only, and tapping it '
        'pushes Connections', (tester) async {
      const watchKey = ValueKey('settings_watch_connections');
      await pumpPushedSettings(tester);
      expect(find.byKey(watchKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(watchKey),
          matching: find.byIcon(Icons.watch),
        ),
        findsOneWidget,
      );

      // Sub-page: the button leaves the AppBar.
      await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
      await tester.pumpAndSettle();
      expect(appBarTitle(tester), 'User Profile');
      expect(find.byKey(watchKey), findsNothing);

      // Back to the menu; the button returns and pushes
      // ConnectionsScreen.
      await systemBack(tester);
      expectOnMenu(tester);
      expect(find.byKey(watchKey), findsOneWidget);
      await tester.tap(find.byKey(watchKey));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionsScreen), findsOneWidget);
    });
  });
}
