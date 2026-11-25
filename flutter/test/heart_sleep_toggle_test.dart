import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/shell/heart_sleep_mode.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

import 'test_helpers.dart';

/// Heart/Sleep nav toggle (founder direction, Nov 23, 2026):
/// - the heart nav slot hosts Heart or Sleep by a shell-owned mode;
/// - the dock's heart cell glyph + semantic label follow the mode;
/// - each screen's AppBar carries the switch to the other screen;
/// - the last mode persists and is restored on cold start;
/// - Sleep in the shell has no back/pop path; pushed (legacy)
///   Sleep keeps its back button exactly as before.

HeartSleepModeStore _memoryModeStore([Map<String, String>? backing]) {
  final store = HeartSleepModeStore();
  final map = backing ?? <String, String>{};
  store.debugSetIO(
    read: (key) async => map[key],
    write: (key, value) async => map[key] = value,
  );
  return store;
}

/// Health Connect firmly unavailable: both screens land in their
/// not-connected states deterministically, which is exactly where
/// the toggle buttons must still work.
class _UnavailableHc extends HealthConnectService {
  static const _snapshot = HcAvailability(
    serviceAvailable: false,
    grantedPermissions: {},
    bridgeErrorCode: null,
    stepsProbe: HcReadProbeOutcome.securityFailure,
    persistedConnected: false,
  );

  @override
  Future<HcAvailability> probeAvailability() async => _snapshot;

  @override
  Future<HcAvailability> probeGrantState() async => _snapshot;
}

class _FakeNotifier implements MigraineNotifier {
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> showAttack(int elapsedMin) async => true;
  @override
  Future<void> cancel() async {}
  @override
  Future<bool> areNotificationsEnabled() async => true;
  @override
  Future<bool> launchMigrainePayload() async => false;
}

class _FakeGateway implements MigraineTrendsGateway {
  @override
  Future<bool> postEntry(QuickLogEntry entry) async => true;
  @override
  Future<int> resolveMigraineCategoryId() async => 7;
  @override
  Future<int> generateEntryId() async => 100;
  @override
  Future<bool?> entryExists(int entryId) async => true;
}

MigraineController _testMigraineController() {
  final map = <String, String>{};
  return MigraineController(
    store: MigraineAttackStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    ),
    notifier: _FakeNotifier(),
    gateway: _FakeGateway(),
  );
}

WeatherApiClient _testWeather() => WeatherApiClient(
  client: MockClient((request) async {
    if (request.url.host == 'ipinfo.io') {
      return http.Response(
        '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
        200,
      );
    }
    return http.Response('not found', 404);
  }),
);

TabsBackend _testBackend() {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient((_) async => http.Response(jsonEncode({}), 200)),
    sessionStore: store,
  );
}

void main() {
  // The Sleep screen paints from the shared history store first;
  // give it an in-memory backing so cases stay isolated and no
  // platform channel is touched (same setUp as tools_r48b).
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  group('HeartSleepModeStore', () {
    test('round-trips sleep and heart', () async {
      final store = _memoryModeStore();
      await store.saveMode(HeartSleepMode.sleep);
      expect(await store.loadMode(), HeartSleepMode.sleep);
      await store.saveMode(HeartSleepMode.heart);
      expect(await store.loadMode(), HeartSleepMode.heart);
    });

    test('empty store defaults to heart', () async {
      expect(await _memoryModeStore().loadMode(), HeartSleepMode.heart);
    });

    test('corrupt value defaults to heart', () async {
      final store = _memoryModeStore({
        HeartSleepModeStore.storageKey: 'banana',
      });
      expect(await store.loadMode(), HeartSleepMode.heart);
    });

    test('a failing read defaults to heart instead of throwing', () async {
      final store = HeartSleepModeStore();
      store.debugSetIO(read: (key) async => throw StateError('boom'));
      expect(await store.loadMode(), HeartSleepMode.heart);
    });

    test('a failing write is swallowed', () async {
      final store = HeartSleepModeStore();
      store.debugSetIO(write: (key, value) async => throw StateError('boom'));
      await store.saveMode(HeartSleepMode.sleep); // must not throw
    });
  });

  group('SleepScreen hosting seam', () {
    Future<void> pumpSleep(WidgetTester tester, Widget screen) async {
      await tester.pumpWidget(MaterialApp(home: screen));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('legacy (no callback): back button, no heart button', (
      tester,
    ) async {
      await pumpSleep(
        tester,
        SleepScreen(backend: _testBackend(), healthConnect: _UnavailableHc()),
      );
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.favorite),
        ),
        findsNothing,
      );
    });

    testWidgets('hosted: no back button, heart button present in the '
        'not-connected state and fires the callback', (tester) async {
      var fired = 0;
      await pumpSleep(
        tester,
        SleepScreen(
          backend: _testBackend(),
          healthConnect: _UnavailableHc(),
          onShowHeart: () => fired++,
        ),
      );
      // Nothing to pop to in the shell: no back affordance at all.
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      // _connected is false (unavailable HC) — the heart switch is
      // NOT gated on it, and neither are the connected-only actions
      // present.
      expect(find.byIcon(Icons.sync), findsNothing);
      final heartButton = find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.favorite),
      );
      expect(heartButton, findsOneWidget);
      await tester.tap(heartButton);
      await tester.pump();
      expect(fired, 1);
    });
  });

  group('MainShell heart/sleep slot', () {
    Finder dockIcon(IconData icon) =>
        find.descendant(of: find.byType(NavDockSolid), matching: find.byIcon(icon));

    Finder appBarIcon(IconData icon) =>
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(icon));

    Future<void> pumpShell(
      WidgetTester tester,
      HeartSleepModeStore store,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(
            weatherApi: _testWeather(),
            healthConnectService: _UnavailableHc(),
            migraineController: _testMigraineController(),
            heartSleepModeStore: store,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    /// Flush any bounded-read timers Home's chains parked so none
    /// outlive the tree (the capture harness's teardown rule).
    Future<void> flush(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 31));
      }
    }

    testWidgets('cold start with persisted sleep: SleepScreen in the slot '
        'and the bedtime glyph in the dock', (tester) async {
      final backing = <String, String>{HeartSleepModeStore.storageKey: 'sleep'};
      await pumpShell(tester, _memoryModeStore(backing));
      await tester.tap(dockIcon(Icons.bedtime));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SleepScreen), findsOneWidget);
      expect(find.byType(HeartScreen), findsNothing);
      expect(dockIcon(Icons.bedtime), findsOneWidget);
      expect(dockIcon(Icons.favorite), findsNothing);
      // Hosted Sleep: no back button anywhere.
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      await flush(tester);
    });

    testWidgets('cold start with persisted heart (and with empty store): '
        'HeartScreen in the slot and the favorite glyph in the dock', (
      tester,
    ) async {
      for (final backing in [
        {HeartSleepModeStore.storageKey: 'heart'},
        <String, String>{},
      ]) {
        await pumpShell(tester, _memoryModeStore(backing));
        await tester.tap(dockIcon(Icons.favorite));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(HeartScreen), findsOneWidget);
        expect(find.byType(SleepScreen), findsNothing);
        expect(dockIcon(Icons.favorite), findsOneWidget);
        expect(dockIcon(Icons.bedtime), findsNothing);
        await flush(tester);
      }
    });

    testWidgets('toggle taps flip screen + dock glyph + persisted value, '
        'both directions', (tester) async {
      final backing = <String, String>{};
      await pumpShell(tester, _memoryModeStore(backing));

      // Heart mode first.
      await tester.tap(dockIcon(Icons.favorite));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(HeartScreen), findsOneWidget);
      // The moon is visible in the not-connected state (refresh is
      // gated on connected and stays hidden — the moon must not).
      expect(appBarIcon(Icons.refresh), findsNothing);
      final moon = find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.bedtime),
      );
      expect(moon, findsOneWidget);

      // Heart → Sleep.
      await tester.tap(moon);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SleepScreen), findsOneWidget);
      expect(find.byType(HeartScreen), findsNothing);
      expect(dockIcon(Icons.bedtime), findsOneWidget);
      expect(dockIcon(Icons.favorite), findsNothing);
      expect(backing[HeartSleepModeStore.storageKey], 'sleep');

      // Sleep → Heart.
      await tester.tap(appBarIcon(Icons.favorite));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(HeartScreen), findsOneWidget);
      expect(find.byType(SleepScreen), findsNothing);
      expect(dockIcon(Icons.favorite), findsOneWidget);
      expect(backing[HeartSleepModeStore.storageKey], 'heart');
      await flush(tester);
    });
  });
}
