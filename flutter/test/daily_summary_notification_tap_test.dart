import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/daily_summary_open_signal.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';

import 'test_helpers.dart';

/// Rich streak reminder (Juno ruling 2026-11-24; Mason recon §5)
/// — tap routing for the Daily Summary notification:
///
/// - NotificationBootstrap dispatch: the new payload and the
///   "Open Daily Summary" action id reach the registered Daily
///   Summary handler; score / migraine / report routing is
///   unchanged; unknown payloads (including the reminder's OLD
///   channel-id payload) still no-op.
/// - Cold start: the terminated-state launch payload is read
///   from the plugin's launch details, action taps included.
/// - DailySummaryOpenSignal: one-shot consumption + freshness.
/// - The sheet-open path: a request opens Today's sheet on the
///   mounted card, never stacks a second one, and a request
///   with no card mounted neither crashes nor is lost (the
///   cold-start shape — a later-mounted card honors it).
/// - MainShell: a pending request selects the Home tab.

/// In-memory secure-storage backing for the plan store / cache
/// (the today_summary_r35_test pattern).
class MemoryStore {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

TodayPlanStore planStoreWith(MemoryStore s) {
  final store = TodayPlanStore.testInstance();
  store.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return store;
}

TodaySummaryCache cacheWith(MemoryStore s) {
  final cache = TodaySummaryCache.testInstance();
  cache.debugSetStore(read: s.read, write: s.write, delete: s.delete);
  return cache;
}

/// Health Connect firmly unavailable (the heart_sleep_toggle
/// pattern): Home's load chain probes first and skips its
/// Health Connect capture entirely, so no bounded-read timeout
/// timers are ever armed in the shell test.
class UnavailableHc extends HealthConnectService {
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

class FakeSummaryHc extends HealthConnectService {
  @override
  Future<int?> readSleepMinutes(String dateStr) async => null;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];
}

/// Fake-backed migraine plumbing for the shell test (the
/// heart_sleep_toggle pattern): without it, the Today Summary
/// card creates its own production MigraineController, whose
/// async initialize can land after the test tree is disposed.
class FakeMigraineNotifier implements MigraineNotifier {
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

class FakeMigraineGateway implements MigraineTrendsGateway {
  @override
  Future<bool> postEntry(QuickLogEntry entry) async => true;
  @override
  Future<int> resolveMigraineCategoryId() async => 7;
  @override
  Future<int> generateEntryId() async => 100;
  @override
  Future<bool?> entryExists(int entryId) async => true;
}

MigraineController testMigraineController() {
  final map = <String, String>{};
  return MigraineController(
    store: MigraineAttackStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    ),
    notifier: FakeMigraineNotifier(),
    gateway: FakeMigraineGateway(),
  );
}

/// Lets real-async completions land in the fake-async test zone
/// (the today_summary_r35_test bridge).
Future<void> bridgeRealAsync(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
  }
  await tester.pump();
}

void main() {
  group('NotificationBootstrap dispatch — Daily Summary branch', () {
    var dailySummaryTaps = 0;
    var scoreTaps = 0;
    var migraineTaps = 0;
    var reportTaps = 0;

    setUp(() {
      NotificationBootstrap.debugReset();
      dailySummaryTaps = 0;
      scoreTaps = 0;
      migraineTaps = 0;
      reportTaps = 0;
      NotificationBootstrap.registerDailySummaryTapHandler(
          () => dailySummaryTaps++);
      NotificationBootstrap.registerScoreTapHandler((_) => scoreTaps++);
      NotificationBootstrap.registerMigraineTapHandler(
          () => migraineTaps++);
      NotificationBootstrap.registerReportReadyTapHandler(
          () => reportTaps++);
    });

    tearDown(NotificationBootstrap.debugReset);

    void dispatch({String? payload, String? actionId}) {
      NotificationBootstrap.dispatchNotificationResponse(
        NotificationResponse(
          notificationResponseType: actionId == null
              ? NotificationResponseType.selectedNotification
              : NotificationResponseType.selectedNotificationAction,
          payload: payload,
          actionId: actionId,
        ),
      );
    }

    test('the daily_summary payload reaches the handler', () {
      dispatch(payload: 'daily_summary');
      expect(dailySummaryTaps, 1);
      expect(scoreTaps + migraineTaps + reportTaps, 0);
    });

    test('the open_daily_summary action id reaches the handler '
        '(with and without the payload alongside)', () {
      dispatch(payload: 'daily_summary', actionId: 'open_daily_summary');
      dispatch(actionId: 'open_daily_summary');
      expect(dailySummaryTaps, 2);
      expect(scoreTaps + migraineTaps + reportTaps, 0);
    });

    test('score / migraine / report routing is unchanged', () {
      dispatch(payload: '2026-11-19');
      dispatch(payload: 'migraine_attack');
      dispatch(payload: 'report_ready');
      expect(scoreTaps, 1);
      expect(migraineTaps, 1);
      expect(reportTaps, 1);
      expect(dailySummaryTaps, 0);
    });

    test('unknown payloads still no-op — including the '
        'reminder\'s old channel-id payload', () {
      dispatch(payload: 'streak_reminders');
      dispatch(payload: 'habit_reminders');
      dispatch(payload: null);
      dispatch(actionId: 'some_other_action');
      expect(
          dailySummaryTaps + scoreTaps + migraineTaps + reportTaps, 0);
    });
  });

  group('cold start — launchedByDailySummaryTap', () {
    const channel =
        MethodChannel('dexterous.com/flutter/local_notifications');
    Map<dynamic, dynamic>? launchResult;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      NotificationBootstrap.debugReset();
      launchResult = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getNotificationAppLaunchDetails') {
          return launchResult;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
      NotificationBootstrap.debugReset();
    });

    Map<dynamic, dynamic> launchedWith(
            {String? payload, String? actionId, int type = 0}) =>
        <dynamic, dynamic>{
          'notificationLaunchedApp': true,
          'notificationResponse': <dynamic, dynamic>{
            'notificationId': 820001,
            'actionId': actionId,
            'input': null,
            'payload': payload,
            'notificationResponseType': type,
          },
        };

    test('a body-tap launch payload is consumed', () async {
      launchResult = launchedWith(payload: 'daily_summary');
      expect(
        await NotificationBootstrap.launchedByDailySummaryTap(
            FlutterLocalNotificationsPlugin()),
        isTrue,
      );
    });

    test('an action-tap launch payload is consumed', () async {
      launchResult = launchedWith(
          payload: 'daily_summary',
          actionId: 'open_daily_summary',
          type: 1);
      expect(
        await NotificationBootstrap.launchedByDailySummaryTap(
            FlutterLocalNotificationsPlugin()),
        isTrue,
      );
    });

    test('another notification\'s launch is not consumed', () async {
      launchResult = launchedWith(payload: '2026-11-19');
      expect(
        await NotificationBootstrap.launchedByDailySummaryTap(
            FlutterLocalNotificationsPlugin()),
        isFalse,
      );
    });

    test('no launch (or no details) is not consumed', () async {
      launchResult = <dynamic, dynamic>{
        'notificationLaunchedApp': false,
        'notificationResponse': null,
      };
      expect(
        await NotificationBootstrap.launchedByDailySummaryTap(
            FlutterLocalNotificationsPlugin()),
        isFalse,
      );
      launchResult = null;
      expect(
        await NotificationBootstrap.launchedByDailySummaryTap(
            FlutterLocalNotificationsPlugin()),
        isFalse,
      );
    });
  });

  group('DailySummaryOpenSignal', () {
    test('a request is consumed exactly once', () {
      final signal = DailySummaryOpenSignal();
      expect(signal.hasPendingRequest, isFalse);
      expect(signal.consumePendingRequest(), isFalse);
      signal.requestOpen();
      expect(signal.hasPendingRequest, isTrue);
      expect(signal.consumePendingRequest(), isTrue);
      expect(signal.hasPendingRequest, isFalse);
      expect(signal.consumePendingRequest(), isFalse);
    });

    test('listeners are notified on request', () {
      final signal = DailySummaryOpenSignal();
      var notified = 0;
      signal.addListener(() => notified++);
      signal.requestOpen();
      expect(notified, 1);
    });

    test('a stale request expires and can no longer be consumed',
        () {
      var now = DateTime(2026, 11, 24, 20, 5);
      final signal = DailySummaryOpenSignal(clock: () => now);
      signal.requestOpen();
      now = now.add(const Duration(seconds: 29));
      expect(signal.hasPendingRequest, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(signal.hasPendingRequest, isFalse);
      expect(signal.consumePendingRequest(), isFalse);
    });
  });

  group('sheet-open path', () {
    setUp(() {
      TabsBackend.debugResetSharedCaches();
      DailySummaryOpenSignal.instance.debugReset();
      final mem = <String, String>{};
      HealthHistoryStore.instance.debugSetStore(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      HealthHistoryStore.instance.debugReset();
    });

    tearDown(() => DailySummaryOpenSignal.instance.debugReset());

    Widget cardApp() {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@b.c';
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(jsonEncode({'profile': {}}), 200);
        }
        if (request.url.path == '/api/habits') {
          return http.Response(jsonEncode({'habits': []}), 200);
        }
        return http.Response('{}', 404);
      });
      return MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TodaySummaryCard(
              backend: TabsBackend(client: client, sessionStore: session),
              healthConnectService: FakeSummaryHc(),
              planStore: planStoreWith(MemoryStore()),
              summaryCache: cacheWith(MemoryStore()),
              sessionStore: session,
            ),
          ),
        ),
      );
    }

    testWidgets('a request opens the sheet on the mounted card, '
        'consumes the request, and never stacks a second sheet',
        (tester) async {
      await tester.pumpWidget(cardApp());
      await bridgeRealAsync(tester);
      expect(find.text("Today's Plan"), findsNothing);

      DailySummaryOpenSignal.instance.requestOpen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text("Today's Plan"), findsOneWidget);
      expect(DailySummaryOpenSignal.instance.hasPendingRequest,
          isFalse);

      // A second request while the sheet is open: consumed by
      // the card, and _openSheet's guard keeps exactly one sheet.
      DailySummaryOpenSignal.instance.requestOpen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text("Today's Plan"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a request with no card mounted does not crash '
        'and is not lost: a later-mounted card honors it',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: Text('no card here'))));
      DailySummaryOpenSignal.instance.requestOpen();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text("Today's Plan"), findsNothing);
      expect(DailySummaryOpenSignal.instance.hasPendingRequest,
          isTrue);

      // The cold-start shape: Home (and its card) mount after
      // the tap was already delivered.
      await tester.pumpWidget(cardApp());
      await bridgeRealAsync(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text("Today's Plan"), findsOneWidget);
      expect(DailySummaryOpenSignal.instance.hasPendingRequest,
          isFalse);
    });

    testWidgets('MainShell: a pending request selects the Home '
        'tab from another tab', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: MainShell(
        healthConnectService: UnavailableHc(),
        migraineController: testMigraineController(),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Switch to Tools via the dock (solid dock is the default
      // style).
      final toolsCell = find.descendant(
        of: find.byType(NavDockSolid),
        matching: find.byIcon(Icons.assignment),
      );
      expect(toolsCell, findsOneWidget);
      await tester.tap(toolsCell);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('tools_screen')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('home_screen')), findsNothing);

      // The notification tap lands: the shell returns to Home.
      // (Whether Home's own card can also open its sheet here
      // depends on its real-backend load in the test env; the
      // ruled degrade — landing on Home — is what this asserts.)
      DailySummaryOpenSignal.instance.requestOpen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('home_screen')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('tools_screen')), findsNothing);
      expect(tester.takeException(), isNull);

      // Drain Home's one-shot timers before teardown (the
      // test binding requires no timer left pending): Home's
      // daily-score load chain arms 30s bounded-read timers in
      // HealthHistorySync, and the chain advances through
      // real-async hops between reads — so interleave real
      // delays with long fake pumps until it has fully settled
      // and every bounded-read timer has fired or cancelled.
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(seconds: 31));
      }
    });
  });
}
