import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_refresh.dart';
import 'package:tabs_lab/src/data/daily_score_refresh_owner.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/refresh_keep_alive.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';

/// Refresh keep-alive (founder-directed Oct 20, 2026): a native
/// foreground service (health type, stopWithTask="false") keeps
/// the process — and the Dart refresh running in it — alive
/// across a Recents swipe, carrying an ongoing notification with
/// Juno-ruled copy. These tests pin:
///
/// - the owner ↔ plugin channel contract over a MOCK platform
///   channel: start exactly once per flight with the DATE ONLY
///   (no score / health value ever crosses), stop on settle for
///   success AND capture-failure outcomes;
/// - Juno Ruling 3: a failed start never blocks the refresh, and
///   its flag is recorded per-refresh, consume-once, rendering
///   Juno's exact line exactly once on BOTH the witnessed and
///   the deferred day-screen paths — and never when start
///   succeeded;
/// - the strongest harness simulation of "swiped away": the
///   originating screen unmounts mid-flight, the capture
///   completes, the store holds the new score and stop fired;
/// - the manifest / Kotlin / background-isolate source pins.

class _FakeStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

List<String> _priorDates(String anchor, int count) {
  final a = DateTime.parse(anchor);
  return [
    for (var i = count; i >= 1; i--) _ds(a.subtract(Duration(days: i))),
  ];
}

HealthHistoryStore _fakeStore(_FakeStore fake) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

const _target = '2026-10-16';

/// Same seed as daily_score_refresh_test.dart: target scores 62;
/// a capture landing HRV 50 refreshes it to 100.
Future<HealthHistoryStore> _seededStore(_FakeStore fake) async {
  final store = _fakeStore(fake);
  await store.mergeRefresh([
    for (final d in _priorDates(_target, 28))
      DailyBiometrics(date: d, restingHrBpm: 60, hrvRmssdMs: 40),
    const DailyBiometrics(date: _target, restingHrBpm: 54, hrvRmssdMs: 32),
  ]);
  await DailyScoreEngine(store: store).computeMissingScores();
  final row = (await store.readAll())[_target]!;
  assert(row.dailyScore == 62);
  return store;
}

ScoreCapture _landingCapture(HealthHistoryStore store) {
  return ({bool force = false}) async {
    await store.mergeRefresh([
      const DailyBiometrics(date: _target, hrvRmssdMs: 50),
    ]);
    return true;
  };
}

/// Mock keep-alive channel over the real bridge channel: records
/// every call, and fails starts with a PlatformException shaped
/// like the native SecurityException mapping when [failStart].
class _MockKeepAliveChannel {
  static const MethodChannel channel =
      MethodChannel(HealthConnectService.channelName);

  final List<MethodCall> calls = [];
  bool failStart = false;
  String? pendingTap;

  /// When set, start calls return this completer's future
  /// instead of answering immediately (a hung channel).
  Completer<bool>? startGate;

  List<MethodCall> get starts =>
      calls.where((c) => c.method == 'startRefreshKeepAlive').toList();
  List<MethodCall> get stops =>
      calls.where((c) => c.method == 'stopRefreshKeepAlive').toList();

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'startRefreshKeepAlive':
          if (startGate != null) return startGate!.future;
          if (failStart) {
            throw PlatformException(
              code: 'FGS_START_FAILED',
              message: 'Refresh keep-alive could not start.',
              details: 'SecurityException',
            );
          }
          return true;
        case 'stopRefreshKeepAlive':
          return true;
        case 'takePendingScoreTap':
          final tap = pendingTap;
          pendingTap = null;
          return tap;
        default:
          return null;
      }
    });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockKeepAliveChannel mock;

  setUp(() {
    mock = _MockKeepAliveChannel()..install();
  });
  tearDown(() {
    mock.uninstall();
  });

  DailyScoreRefreshOwner ownerFor(
    HealthHistoryStore store,
    ScoreCapture capture,
  ) =>
      DailyScoreRefreshOwner.withCapture(store: store, capture: capture);

  group('wrapper: RefreshKeepAlive channel contract', () {
    test('takePendingScoreTap returns the held date once, then null',
        () async {
      mock.pendingTap = _target;
      const keepAlive = RefreshKeepAlive();
      expect(await keepAlive.takePendingScoreTap(), _target);
      expect(await keepAlive.takePendingScoreTap(), isNull);
    });

    test('a failing start returns false and never throws', () async {
      mock.failStart = true;
      const keepAlive = RefreshKeepAlive();
      expect(await keepAlive.start(_target), isFalse);
      expect(await keepAlive.stop(), isTrue);
    });
  });

  group('owner: keep-alive channel wiring (mock channel)', () {
    test(
        'start is called exactly once per flight, with the DATE '
        'ONLY as its argument; stop is called on settle (success)',
        () async {
      final store = await _seededStore(_FakeStore());
      final owner = ownerFor(store, _landingCapture(store));
      final outcome = await owner.startRefresh(_target);
      expect(outcome, isNotNull);
      expect(outcome!.status, DailyScoreRefreshStatus.refreshed);
      expect(mock.starts, hasLength(1));
      // Notification-content pin: the ONLY argument is the date —
      // no score, no health value ever crosses this channel.
      expect(mock.starts.single.arguments, {'date': _target});
      expect(mock.stops, hasLength(1));
      expect(mock.stops.single.arguments, isNull);
      expect(owner.consumeKeepAliveFailure(_target), isFalse);
    });

    test('stop is called on settle for a capture-failure outcome',
        () async {
      final store = await _seededStore(_FakeStore());
      final owner =
          ownerFor(store, ({bool force = false}) async => false);
      final outcome = await owner.startRefresh(_target);
      expect(outcome!.status, DailyScoreRefreshStatus.captureFailed);
      expect(mock.starts, hasLength(1));
      expect(mock.stops, hasLength(1));
      // The recorded outcome is still the refresh's own.
      expect(owner.consumeOutcome(_target)!.status,
          DailyScoreRefreshStatus.captureFailed);
    });

    test(
        'a failing start: the refresh still completes with its '
        'normal outcome AND the failure flag is recorded, '
        'consume-once', () async {
      final store = await _seededStore(_FakeStore());
      mock.failStart = true;
      final owner = ownerFor(store, _landingCapture(store));
      final outcome = await owner.startRefresh(_target);
      expect(outcome!.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.computation!.dailyScore, 100);
      expect((await store.readAll())[_target]!.dailyScore, 100);
      expect(mock.stops, hasLength(1)); // stop still attempted
      expect(owner.hasPendingOutcome(_target), isTrue);
      expect(owner.hasPendingKeepAliveFailure(_target), isTrue);
      expect(owner.consumeKeepAliveFailure(_target), isTrue);
      expect(owner.consumeKeepAliveFailure(_target), isFalse);
    });

    test(
        'flags are per-refresh: a later successful start shows '
        'nothing; a later failed start records its flag again',
        () async {
      final store = await _seededStore(_FakeStore());
      final owner = ownerFor(store, _landingCapture(store));
      // Refresh 1: failed start.
      mock.failStart = true;
      await owner.startRefresh(_target);
      expect(owner.consumeOutcome(_target), isNotNull);
      expect(owner.consumeKeepAliveFailure(_target), isTrue);
      // Refresh 2: successful start — no flag.
      mock.failStart = false;
      await owner.startRefresh(_target);
      expect(owner.consumeOutcome(_target), isNotNull);
      expect(owner.hasPendingKeepAliveFailure(_target), isFalse);
      expect(owner.consumeKeepAliveFailure(_target), isFalse);
      // Refresh 3: failed start again — its own flag, afresh.
      mock.failStart = true;
      await owner.startRefresh(_target);
      expect(owner.consumeOutcome(_target), isNotNull);
      expect(owner.consumeKeepAliveFailure(_target), isTrue);
      expect(mock.starts, hasLength(3));
      expect(mock.stops, hasLength(3));
    });

    test(
        'single-flight refusal stays exact: no second start call '
        'while a flight runs (same or different day)', () async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      var captureCalls = 0;
      final owner = ownerFor(store, ({bool force = false}) {
        captureCalls++;
        return completer.future;
      });
      final flight = owner.startRefresh(_target);
      expect(flight, isNotNull);
      expect(owner.startRefresh(_target), isNull);
      expect(owner.startRefresh('2026-10-15'), isNull);
      completer.complete(true);
      await flight!;
      expect(captureCalls, 1);
      expect(mock.starts, hasLength(1));
      expect(mock.stops, hasLength(1));
    });

    test(
        'a start that resolves only AFTER settle (hung channel) '
        'and failed attaches its flag to the still-pending '
        'outcome when it lands', () async {
      final store = await _seededStore(_FakeStore());
      mock.startGate = Completer<bool>();
      final owner = ownerFor(store, _landingCapture(store));
      final outcome = await owner.startRefresh(_target);
      // The refresh settled normally WITHOUT waiting on the
      // start: outcome recorded, stop fired, no flag yet.
      expect(outcome!.status, DailyScoreRefreshStatus.refreshed);
      expect(mock.stops, hasLength(1));
      expect(owner.hasPendingOutcome(_target), isTrue);
      expect(owner.hasPendingKeepAliveFailure(_target), isFalse);
      // The start finally reports failure (the wrapper maps the
      // channel error to false): the flag attaches to the pending
      // outcome, consume-once as usual.
      mock.startGate!.complete(false);
      await Future<void>.delayed(Duration.zero);
      expect(owner.hasPendingKeepAliveFailure(_target), isTrue);
      expect(owner.consumeOutcome(_target), isNotNull);
      expect(owner.consumeKeepAliveFailure(_target), isTrue);
      expect(owner.consumeKeepAliveFailure(_target), isFalse);
    });

    test(
        'clear() during flight: stop still fires at settle and '
        'the outcome (and its flag) are discarded as today',
        () async {
      final store = await _seededStore(_FakeStore());
      mock.failStart = true;
      final completer = Completer<bool>();
      final owner =
          ownerFor(store, ({bool force = false}) => completer.future);
      final flight = owner.startRefresh(_target);
      expect(flight, isNotNull);
      await Future<void>.delayed(Duration.zero);
      owner.clear();
      completer.complete(true);
      await flight!;
      expect(mock.stops, hasLength(1));
      expect(owner.isRefreshing, isFalse);
      expect(owner.hasPendingOutcome(_target), isFalse);
      expect(owner.consumeOutcome(_target), isNull);
      expect(owner.hasPendingKeepAliveFailure(_target), isFalse);
      expect(owner.consumeKeepAliveFailure(_target), isFalse);
    });
  });

  group('widgets: keep-alive across unmount + Juno line', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required HealthHistoryStore store,
      required DailyScoreRefreshOwner owner,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreDayScreen(
            store: store, date: _target, refreshOwner: owner),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    Future<void> pumpElsewhere(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text('elsewhere')),
      ));
      await tester.pump();
    }

    testWidgets(
        'swiped-away simulation: refresh started, screen unmounts '
        'mid-flight, capture completes — store holds the new '
        'score, stop was called, re-entry surfaces per existing '
        'rules (score present, no Juno line, no SnackBar)',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      final landing = _landingCapture(store);
      final owner = ownerFor(store, ({bool force = false}) async {
        await completer.future;
        return landing(force: force);
      });
      await pumpDetail(tester, store: store, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      expect(mock.starts, hasLength(1));
      expect(mock.starts.single.arguments, {'date': _target});
      // The "swipe away": the originating screen is gone while
      // the refresh still runs.
      await pumpElsewhere(tester);
      completer.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect((await store.readAll())[_target]!.dailyScore, 100);
      expect(mock.stops, hasLength(1));
      await pumpDetail(tester, store: store, owner: owner);
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(find.text(dailyScoreRefreshKeepAliveFailedLine), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
        'deferred path: Juno\'s line renders exactly once when '
        'the start failed (refresh completed while away), and a '
        'second entry does not re-show it', (tester) async {
      final store = await _seededStore(_FakeStore());
      mock.failStart = true;
      final completer = Completer<bool>();
      final landing = _landingCapture(store);
      final owner = ownerFor(store, ({bool force = false}) async {
        await completer.future;
        return landing(force: force);
      });
      await pumpDetail(tester, store: store, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await pumpElsewhere(tester);
      completer.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect((await store.readAll())[_target]!.dailyScore, 100);
      await pumpDetail(tester, store: store, owner: owner);
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      // The exact Juno string, verbatim.
      expect(
          find.text("Keep-alive couldn't start: this refresh wasn't "
              'protected if you swiped Tabs away. [FGS_START_FAILED]'),
          findsOneWidget);
      expect(find.text(dailyScoreRefreshKeepAliveFailedLine),
          findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      // Consumed: leave and re-enter — never shown again.
      await pumpElsewhere(tester);
      await pumpDetail(tester, store: store, owner: owner);
      expect(find.text(dailyScoreRefreshKeepAliveFailedLine), findsNothing);
    });

    testWidgets(
        'witnessed path: Juno\'s line renders when the start '
        'failed, after the refresh\'s own outcome rendering',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      mock.failStart = true;
      // A capture FAILURE gives the refresh its own inline error
      // line, so the ordering of Juno's line after it is testable.
      final owner =
          ownerFor(store, ({bool force = false}) async => false);
      await pumpDetail(tester, store: store, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      final failureLine = find.text('Refresh failed. Nothing was changed. '
          '[CAPTURE_FAILED]');
      final junoLine = find.text(dailyScoreRefreshKeepAliveFailedLine);
      expect(failureLine, findsOneWidget);
      expect(junoLine, findsOneWidget);
      // Juno's line is its own line AFTER the refresh's own
      // outcome rendering (Ruling 3).
      expect(tester.getTopLeft(junoLine).dy,
          greaterThan(tester.getTopLeft(failureLine).dy));
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    });

    testWidgets(
        'witnessed path: no Juno line when the start succeeded',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      final owner = ownerFor(store, _landingCapture(store));
      await pumpDetail(tester, store: store, owner: owner);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(find.text(dailyScoreRefreshKeepAliveFailedLine), findsNothing);
      expect(mock.starts, hasLength(1));
      expect(mock.stops, hasLength(1));
    });
  });

  group('source pins: manifest, Kotlin, background isolation', () {
    String read(String path) => File(path).readAsStringSync();

    test('plugin manifest declares the service + both permissions',
        () {
      final manifest = read('plugins/health_connect_bridge/android/'
          'src/main/AndroidManifest.xml');
      expect(manifest,
          contains('android.permission.FOREGROUND_SERVICE'));
      expect(manifest,
          contains('android.permission.FOREGROUND_SERVICE_HEALTH'));
      expect(manifest, contains('RefreshKeepAliveService'));
      expect(manifest, contains('android:stopWithTask="false"'));
      expect(manifest, contains('android:foregroundServiceType="health"'));
      expect(manifest, contains('android:exported="false"'));
      // Juno Ruling 4: dataSync was rejected — it appears nowhere.
      expect(manifest, isNot(contains('dataSync')));
    });

    test(
        'Kotlin service carries Juno\'s exact strings, PRIVATE '
        'visibility, id 7302 — and no score formatting', () {
      final service = read('plugins/health_connect_bridge/android/'
          'src/main/kotlin/com/notel/notel/playground/flutter/'
          'health_connect_bridge/RefreshKeepAliveService.kt');
      expect(service, contains('"daily_score_refresh_progress"'));
      expect(service, contains('"Daily Score refresh"'));
      expect(
          service,
          contains('"Shown while a Daily Score refresh you started '
              'is finishing."'));
      expect(service, contains('"Tabs"'));
      expect(service, contains('"Refreshing your Daily Score…"'));
      expect(service, contains('IMPORTANCE_LOW'));
      expect(service, contains('VISIBILITY_PRIVATE'));
      expect(service, contains('7302'));
      expect(service, contains('setOngoing(true)'));
      expect(service, contains('setOnlyAlertOnce(true)'));
      expect(service, contains('FOREGROUND_SERVICE_TYPE_HEALTH'));
      expect(service, contains('FLAG_IMMUTABLE'));
      expect(service, contains('FLAG_UPDATE_CURRENT'));
      // No score / health formatting anywhere in the notification
      // builder's file: no camelCase score identifiers, no format
      // strings, no public-version escape hatch.
      expect(service, isNot(contains('dailyScore')));
      expect(service, isNot(contains('DailyScore')));
      expect(service, isNot(contains('setPublicVersion')));
      expect(service, isNot(contains('%d')));
    });

    test(
        'plugin handler: start/stop/tap methods, structured '
        'errors, MainActivity forwards from onCreate + onNewIntent',
        () {
      final plugin = read('plugins/health_connect_bridge/android/'
          'src/main/kotlin/com/notel/notel/playground/flutter/'
          'health_connect_bridge/HealthConnectBridgePlugin.kt');
      expect(plugin, contains('"startRefreshKeepAlive"'));
      expect(plugin, contains('"stopRefreshKeepAlive"'));
      expect(plugin, contains('"takePendingScoreTap"'));
      expect(plugin, contains('startForegroundService'));
      expect(plugin, contains('"FGS_START_FAILED"'));
      final mainActivity = read('android/app/src/main/kotlin/com/'
          'notel/notel/playground/flutter/MainActivity.kt');
      expect(mainActivity, contains('onNewIntent'));
      expect(
          mainActivity,
          matches(RegExp(r'publishScoreTapFromIntent\(intent\)[\s\S]*'
              r'publishScoreTapFromIntent\(intent\)')));
    });

    test('the background isolate never references the keep-alive',
        () {
      final background = read('lib/src/data/daily_score_background.dart');
      expect(background, isNot(contains('KeepAlive')));
      expect(background, isNot(contains('keep_alive')));
      expect(background, isNot(contains('keepAlive')));
    });

    test(
        'exact Juno line constant: single bracketed code, no '
        'other failure vocabulary', () {
      expect(
          dailyScoreRefreshKeepAliveFailedLine,
          "Keep-alive couldn't start: this refresh wasn't protected "
          'if you swiped Tabs away. [FGS_START_FAILED]');
    });
  });
}
