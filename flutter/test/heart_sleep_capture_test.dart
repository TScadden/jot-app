import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';

/// Heart/Sleep toggle — visual capture harness (modeled on
/// drawer_nav_fade_capture_test.dart). Frames @ DPR 3.0 at the
/// founder's 360dp phone class and at 390dp, full screen including
/// the nav dock:
/// - heart_mode_{360,390}: Heart screen in the heart slot, moon
///   toggle in its AppBar, favorite glyph in the dock.
/// - sleep_mode_{360,390}: after tapping the moon — Sleep screen
///   hosted in the slot (no back button), heart toggle in its
///   AppBar, bedtime glyph in the dock.
///
/// Services are faked (unavailable Health Connect, memory migraine
/// controller, mock weather) so background chains settle
/// immediately instead of hanging on missing platform channels.
///
/// Output dir: $HEART_SLEEP_CAPTURE_OUT, default
/// ~/workspace/build-heart-sleep-toggle/captures.

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
  Future<String> resolveMigraineCategoryId() async => '7';
  @override
  Future<String> generateEntryId() async => '100';
  @override
  Future<bool?> entryExists(String entryId) async => true;
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
  late Directory outDir;
  final rootKey = GlobalKey();

  setUp(() {
    // The Sleep screen paints from the shared history store first;
    // an in-memory backing keeps its load off the (absent) platform
    // channel so the settled state, not the skeleton, is captured.
    final mem = <String, String>{};
    HealthHistoryStore.instance.debugSetStore(
      read: (k) async => mem[k],
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    HealthHistoryStore.instance.debugReset();
  });

  setUpAll(() async {
    outDir = Directory(
      Platform.environment['HEART_SLEEP_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}'
              '/workspace/build-heart-sleep-toggle/captures',
    );
    await outDir.create(recursive: true);
  });

  Future<void> loadFonts(WidgetTester tester) async {
    // Real glyphs, not test-font blocks (repo capture pattern).
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      final iconsFile = File(
        '${Platform.environment['HOME']}/workspace/tools/flutter/bin/cache/'
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

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${outDir.path}/$name.png')
          .writeAsBytes(byteData!.buffer.asUint8List());
    });
  }

  // Nav Bar Style update (Nov 24, 2026): the bare shell mounts
  // the default Solid dock; its cells carry the same glyphs, so
  // the tap finder scopes to it. The capture subject under test
  // is dock-agnostic.
  Finder dockIcon(IconData icon) => find.descendant(
    of: find.byType(NavDockSolid),
    matching: find.byIcon(icon),
  );

  for (final width in [360.0, 390.0]) {
    final tag = width.toInt();
    testWidgets('capture heart + sleep modes at $tag', (tester) async {
      await loadFonts(tester);
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            // Banner off: it would sit on top of the very AppBar
            // toggle buttons these frames exist to show.
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: MainShell(
              weatherApi: _testWeather(),
              healthConnectService: _UnavailableHc(),
              migraineController: _testMigraineController(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // Heart mode: select the heart slot and let the slide settle.
      await tester.tap(dockIcon(Icons.favorite));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await capture(tester, 'heart_mode_$tag');

      // Sleep mode: tap the Heart screen's moon toggle.
      await tester.tap(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.bedtime),
        ),
      );
      await tester.pump();
      // The Sleep load chain (store paint + grant probe) needs
      // longer than the slide to land its settled state.
      await tester.pump(const Duration(milliseconds: 2000));
      await capture(tester, 'sleep_mode_$tag');

      // Flush bounded-read timers so none outlive the tree
      // (the drawer capture harness's teardown rule).
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 31));
      }
    });
  }
}
