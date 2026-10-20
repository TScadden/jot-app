import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/daily_score_background.dart';
import 'package:tabs_lab/src/data/notification_service.dart';

/// V-1 correction (Vera MAJOR) — notification tap routing.
///
/// flutter_local_notifications is a singleton: every
/// plugin.initialize() replaces the response callback. The old
/// shape let [LocalReminderNotificationService.initialize] —
/// reached from ordinary screens, each building a fresh service —
/// re-initialize with NO callback and erase the Daily Score
/// notifier's tap routing in-session.
///
/// The correction: [NotificationBootstrap] owns plugin.initialize
/// for the foreground isolate, once, with a dispatching callback.
/// These tests drive the REAL plugin singleton over its method
/// channel (mocked platform side) and prove:
/// - initializing the reminder service AFTER the score notifier
///   (and the bootstrap) does NOT re-initialize the plugin, and
///   a score-payload tap still routes to the score handler;
/// - a non-score payload keeps the previous no-op behavior;
/// - MF-8: the score-ready notification posts the approved
///   tap-to-view title/body (never the number) with private
///   visibility and the date as its payload.

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final initializeCalls = <MethodCall>[];
  final showCalls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    NotificationBootstrap.debugReset();
    initializeCalls.clear();
    showCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'initialize':
          initializeCalls.add(call);
          return true;
        case 'show':
          showCalls.add(call);
          return null;
        default:
          // createNotificationChannel, getNotificationAppLaunchDetails,
          // areNotificationsEnabled, … — benign platform answers.
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
    NotificationBootstrap.debugReset();
  });

  /// Delivers a platform→framework notification response, exactly
  /// as a user tap on a posted notification arrives.
  Future<void> simulateTap(String? payload) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('didReceiveNotificationResponse', <String, dynamic>{
          'notificationId': LocalDailyScoreReadyNotifier.notificationId,
          'actionId': null,
          'input': null,
          'payload': payload,
          // NotificationResponseType.selectedNotification
          'notificationResponseType': 0,
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  test(
      'V-1 regression: reminder service initializing AFTER the '
      'score notifier/bootstrap does not wipe score tap routing',
      () async {
    final plugin = FlutterLocalNotificationsPlugin();
    final tappedDates = <String>[];

    // App start: the bootstrap initializes the plugin once, then
    // the score notifier registers its tap handler and joins.
    await NotificationBootstrap.initialize(plugin);
    final notifier = LocalDailyScoreReadyNotifier(
      plugin: plugin,
      onTap: tappedDates.add,
    );
    await notifier.initialize();
    expect(initializeCalls, hasLength(1));

    // An ordinary screen now builds a fresh reminder service and
    // initializes it (the old in-session wipe).
    final reminders = LocalReminderNotificationService(plugin: plugin);
    await reminders.initialize();
    await reminders.areNotificationsEnabled();

    // The plugin was still initialized exactly once — nobody
    // replaced the dispatching callback.
    expect(initializeCalls, hasLength(1));

    // A score-payload tap (foreground/backgrounded) still routes.
    await simulateTap('2026-10-20');
    expect(tappedDates, ['2026-10-20']);

    // A reminder payload keeps the previous no-op behavior.
    await simulateTap('habit_reminders');
    expect(tappedDates, ['2026-10-20']);
  });

  test(
      'V-1 delta-2: a notifier WITH onTap initializing FIRST (after '
      'a bootstrap reset) starts the bootstrap itself — plugin '
      'initialize count stays exactly 1 through a later reminder '
      'initialize, and a score-payload tap still routes', () async {
    final plugin = FlutterLocalNotificationsPlugin();
    final tappedDates = <String>[];

    // Bootstrap state is reset (setUp) — the state a failed
    // bootstrap attempt leaves behind once its in-flight guard
    // clears. NO bootstrap call happens before the notifier: the
    // foreground notifier is the first caller, and it must start
    // the bootstrap (with the dispatching callback) rather than
    // taking a callback-less own-initialize.
    final notifier = LocalDailyScoreReadyNotifier(
      plugin: plugin,
      onTap: tappedDates.add,
    );
    await notifier.initialize();
    expect(initializeCalls, hasLength(1));

    // A subsequent reminder-service initialize joins the same
    // bootstrap run — no second plugin initialize.
    final reminders = LocalReminderNotificationService(plugin: plugin);
    await reminders.initialize();
    expect(initializeCalls, hasLength(1));

    // The one initialize carried the dispatching callback: a
    // score-payload tap still routes to the notifier's handler.
    await simulateTap('2026-10-20');
    expect(tappedDates, ['2026-10-20']);
  });

  test(
      'MF-8: score-ready notification is tap-to-view only — '
      'approved title/body, no number, private visibility, date '
      'payload', () async {
    final plugin = FlutterLocalNotificationsPlugin();
    await NotificationBootstrap.initialize(plugin);
    final notifier = LocalDailyScoreReadyNotifier(plugin: plugin);
    // The runner plumbs the score in; it must NOT be rendered.
    await notifier.showScoreReady('2026-10-20', score: 87);

    expect(showCalls, hasLength(1));
    final args = showCalls.single.arguments as Map<dynamic, dynamic>;
    expect(args['id'], LocalDailyScoreReadyNotifier.notificationId);
    expect(args['title'], 'Your Daily Score is ready');
    expect(args['body'], 'Tap to see your Daily Score for Oct 20.');
    expect(args['body'], isNot(contains('87')));
    expect(args['payload'], '2026-10-20');
    final specifics = args['platformSpecifics'] as Map<dynamic, dynamic>;
    expect(specifics['visibility'], NotificationVisibility.private.index);
  });
}
