import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/onboarding/post_onboarding_notification_card.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

/// GAP-13 acceptance (break-it fixes): the named surfaces —
/// Home (Weekly Snapshot header), Tools tiles, Heart rows, the
/// Solid nav dock, and the post-onboarding notification card —
/// must lay out with ZERO framework exceptions at text scale
/// 2.0x and 3.0x. Harness follows the Cluster B audit pattern
/// (scratch-b): real MainShell, real Roboto, exceptions drained
/// per surface so one bad row cannot mask the rest; here the
/// drained list is asserted empty instead of just reported.
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

void main() {
  setUp(() {
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  Future<void> loadFonts(WidgetTester tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      final iconsFile = File(
        '${Platform.environment['HOME']}/workspace/flutter-sdk/bin/cache/'
        'artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await iconsFile.exists()) {
        final icons = await iconsFile.readAsBytes();
        final iconLoader = FontLoader('MaterialIcons');
        iconLoader.addFont(
          Future.value(ByteData.view(Uint8List.fromList(icons).buffer)),
        );
        await iconLoader.load();
      }
    });
  }

  List<String> drain(WidgetTester tester, String where, List<String> sink) {
    final out = <String>[];
    var e = tester.takeException();
    while (e != null) {
      final s = e.toString().replaceAll('\n', ' ');
      out.add('[$where] ${s.length > 400 ? s.substring(0, 400) : s}');
      e = tester.takeException();
    }
    sink.addAll(out);
    return out;
  }

  Future<List<String>> pumpShell(
    WidgetTester tester, {
    required double scale,
  }) async {
    final failures = <String>[];
    await loadFonts(tester);
    tester.view.physicalSize = const Size(360 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 72);
    tester.view.padding = const FakeViewPadding(top: 72, bottom: 72);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final map = <String, String>{
      SettingsStore.navBarStyleKey: 'solid',
    };
    final store = SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: notelDarkTheme(),
        home: MainShell(
          settingsStore: store,
          weatherApi: _testWeather(),
          healthConnectService: _UnavailableHc(),
          migraineController: _testMigraineController(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    drain(tester, 'home@$scale', failures);
    final homeScrollable = find.byType(Scrollable).first;
    await tester.fling(homeScrollable, const Offset(0, -600), 800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    drain(tester, 'home-scrolled@$scale', failures);

    for (final (icon, name) in <(IconData, String)>[
      (Icons.assignment, 'tools'),
      (Icons.edit, 'quicklog'),
      (Icons.favorite, 'heart'),
      (Icons.home, 'home-again'),
    ]) {
      final dockIcon = find.descendant(
        of: find.byType(NavDockSolid),
        matching: find.byIcon(icon),
      );
      if (dockIcon.evaluate().isEmpty) {
        failures.add('[$name@$scale] dock icon not found');
        continue;
      }
      await tester.tap(dockIcon);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      drain(tester, '$name@$scale', failures);
      // Scroll the tab body so lower rows lay out too.
      final scrollables = find.byType(Scrollable);
      if (scrollables.evaluate().length > 1) {
        await tester.fling(scrollables.last, const Offset(0, -600), 800);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        drain(tester, '$name-scrolled@$scale', failures);
      }
    }
    return failures;
  }

  for (final scale in [2.0, 3.0]) {
    testWidgets('shell surfaces survive text scale $scale', (tester) async {
      final failures = await pumpShell(tester, scale: scale);
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  }

  for (final scale in [2.0, 3.0]) {
    testWidgets('post-onboarding notification card survives $scale',
        (tester) async {
      final failures = <String>[];
      await loadFonts(tester);
      tester.view.physicalSize = const Size(360 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      await tester.pumpWidget(
        MaterialApp(
          theme: notelDarkTheme(),
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: PostOnboardingNotificationCard(
                  onAllow: () {},
                  onDontAllow: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      drain(tester, 'notif-card@$scale', failures);
      expect(failures, isEmpty, reason: failures.join('\n'));
      // Both actions stay tappable at scale.
      expect(find.text('Allow'), findsOneWidget);
      expect(find.text("Don't Allow"), findsOneWidget);
    });
  }
}
