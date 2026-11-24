import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/heart/heart_spike_review_screen.dart';

import 'test_helpers.dart';

/// Heart store-first fix (Nov 24, 2026) — fail-first tests for the
/// proven diagnosis (~/workspace/build-heart-not-loading/DIAGNOSIS.md):
///
/// 1. A store row for a PAST date renders its summary with the
///    bridge read never completing (store-first render).
/// 2. A read timeout with stored data shows the stored data + the
///    Juno §1 stale state, not placeholders; with NO stored data it
///    shows the Juno §2 state and no placeholder data at all.
/// 3. A date switch during a pending load loads the picked date
///    with its own data (both load races fixed).
/// 4. Spike Review with an empty series + stored spikes shows the
///    stored count (Juno §4), never the all-clear; the all-clear
///    survives only for an examined day with 0 events.
/// 5. The service's outcome path is bounded inside the service,
///    and Home's cache write-through gate claims the HR read's
///    own outcome (a sibling read's slot writes cannot block it).

class _FakeKv {
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
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

int _msOn(DateTime day, int hour, [int minute = 0]) =>
    DateTime(day.year, day.month, day.day, hour, minute)
        .millisecondsSinceEpoch;

/// HC fake whose HR read behavior is scripted per date.
class _ScriptedHc extends HealthConnectService {
  _ScriptedHc({required this.handler});

  /// Per-date read script; receives the date string.
  final Future<List<HrSample>> Function(String dateStr) handler;
  final List<String> readDates = [];

  @override
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
        serviceAvailable: true,
        grantedPermissions: HealthConnectService.requiredPermissions,
        bridgeErrorCode: null,
        stepsProbe: null,
        persistedConnected: true,
      );

  @override
  Future<bool> hasPersistedConnection() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) {
    readDates.add(dateStr);
    return handler(dateStr);
  }
}

Future<HealthHistoryStore> _seededStore(
    _FakeKv kv, List<DailyBiometrics> rows) async {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: kv.read, write: kv.write, delete: kv.delete);
  await store.mergeRefresh(rows);
  // The screen warms the store with the session email; an unowned
  // populated store is fail-closed dropped on an owner-known warm,
  // so the seed binds the same account the screen carries.
  store.bindToAccount('a@b.c');
  return store;
}

void main() {
  late _FakeKv cacheKv;

  setUp(() {
    cacheKv = _FakeKv();
    HeartDataCache.instance.debugReset();
    HeartDataCache.instance.debugSetStore(
      read: cacheKv.read,
      write: cacheKv.write,
      delete: cacheKv.delete,
    );
  });

  tearDown(() {
    HeartDataCache.instance.debugReset();
  });

  Future<void> pumpHeart(
    WidgetTester tester, {
    required HealthConnectService hc,
    required HealthHistoryStore store,
    required DateTime initialDate,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: HeartScreen(
        email: 'a@b.c',
        healthConnectService: hc,
        cache: HeartDataCache.instance,
        historyStore: store,
        initialDate: initialDate,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('Heart store-first render', () {
    testWidgets(
        '1. past-date store row renders summary while the bridge '
        'read never completes', (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final yStr = _ds(yesterday);
      final store = await _seededStore(_FakeKv(), [
        DailyBiometrics(
          date: yStr,
          restingHrBpm: 58,
          spikeCount: 24,
          maxHrBpm: 151,
          minutesOver100: 62,
          minutesOver120: 13,
        ),
      ]);
      final never = Completer<List<HrSample>>();
      final hc = _ScriptedHc(handler: (_) => never.future);

      await pumpHeart(tester, hc: hc, store: store, initialDate: yesterday);

      // The load is still in flight (spinner up, read never
      // answered) — and the stored day is already on screen.
      expect(find.text('Updating sync data...'), findsOneWidget);
      expect(find.text('24 significant spikes'), findsOneWidget);
      expect(find.text('Peak 151 bpm'), findsOneWidget);
      expect(find.text('151'), findsWidgets);
      expect(find.text(heartChartSummaryOnlyMessage), findsOneWidget);
      expect(hc.readDates, contains(yStr));

      // Drain the screen's 30 s caller-side timeout timer so the
      // test does not end with a pending timer.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
    });

    testWidgets(
        '2a. read timeout with stored data: stored data + Juno §1 '
        'stale state, spinner cleared, heartRead diagnostic written',
        (tester) async {
      final today = DateTime.now();
      final tStr = _ds(today);
      final store = await _seededStore(_FakeKv(), [
        DailyBiometrics(
          date: tStr,
          restingHrBpm: 60,
          spikeCount: 3,
          maxHrBpm: 116,
          minutesOver100: 3,
          minutesOver120: 0,
        ),
      ]);
      final hc = _ScriptedHc(
        handler: (_) =>
            Future<List<HrSample>>.delayed(const Duration(seconds: 60),
                () => const <HrSample>[]),
      );

      await pumpHeart(tester, hc: hc, store: store, initialDate: today);
      expect(find.text('3 significant spikes'), findsOneWidget);

      // Advance past the screen's 30 s bound; the fake's 60 s read
      // has still not answered — the timeout resolves the load.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      await tester.pump();

      expect(find.text('Updating sync data...'), findsNothing);
      expect(find.text(heartStaleDataMessage), findsOneWidget);
      // Stored data stays on screen.
      expect(find.text('3 significant spikes'), findsOneWidget);
      expect(find.text('Peak 116 bpm'), findsOneWidget);
      // The read-error line is above the fold now (same body).
      expect(find.text('Could not read heart rate data.'), findsOneWidget);
      // The Heart read's own outcome is in the capture diagnostics.
      final diag = store.lastCaptureDiagnostics['heartRead'];
      expect(diag, isNotNull);
      expect(diag!.errorCode, 'READ_TIMEOUT');

      // Drain the fake's 60 s delayed-read timer.
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
    });

    testWidgets(
        '2b. read timeout with NO stored data: Juno §2 state and '
        'no placeholder data rendered as data', (tester) async {
      final today = DateTime.now();
      final store = await _seededStore(_FakeKv(), const []);
      final hc = _ScriptedHc(
        handler: (_) =>
            Future<List<HrSample>>.delayed(const Duration(seconds: 60),
                () => const <HrSample>[]),
      );

      await pumpHeart(tester, hc: hc, store: store, initialDate: today);
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      await tester.pump();

      expect(find.text('Updating sync data...'), findsNothing);
      expect(find.text(heartNoDataTitle), findsOneWidget);
      expect(find.text(heartNoDataBody), findsOneWidget);
      // Binding §2: none of the placeholder data may render.
      expect(find.text('-- bpm'), findsNothing);
      expect(find.text('Awake average'), findsNothing);
      expect(find.text('0 significant spikes'), findsNothing);
      expect(find.text("Today’s pattern"), findsNothing);

      // Drain the fake's 60 s delayed-read timer.
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
    });

    testWidgets(
        '3. date switch during a pending load loads the picked '
        'date with its own data', (tester) async {
      final today = DateTime.now();
      final yesterday = today.subtract(const Duration(days: 1));
      final tStr = _ds(today);
      final yStr = _ds(yesterday);
      final store = await _seededStore(_FakeKv(), const []);
      final completers = <String, Completer<List<HrSample>>>{};
      final hc = _ScriptedHc(handler: (dateStr) {
        final c = Completer<List<HrSample>>();
        completers[dateStr] = c;
        return c.future;
      });

      await pumpHeart(tester, hc: hc, store: store, initialDate: today);
      expect(completers.containsKey(tStr), isTrue);

      // Pick yesterday while today's load is still pending. (No
      // pumpAndSettle anywhere here: the in-flight load's spinner
      // animates forever by design, so settle never comes — the
      // dialog is driven with bounded pumps instead.)
      await tester.tap(find.text('Today'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('${yesterday.day}'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      // The picked date started its OWN load (not dropped).
      expect(completers.containsKey(yStr), isTrue,
          reason: 'picked date load must start during a pending load');

      // The picked date's load lands with its own data.
      completers[yStr]!.complete([
        HrSample(timeMs: _msOn(yesterday, 9), bpm: 70),
        HrSample(timeMs: _msOn(yesterday, 10), bpm: 140),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.text('105 bpm'), findsOneWidget);

      // Today's load finishing late must NOT overwrite the picked
      // date's screen (it applies under today's key only).
      completers[tStr]!.complete([
        HrSample(timeMs: _msOn(today, 9), bpm: 80),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.text('105 bpm'), findsOneWidget);
      expect(find.text('80 bpm'), findsNothing);
    });
  });

  group('Spike Review truth (Juno §4)', () {
    testWidgets(
        '4a. empty series + stored spikes: stored count shown, '
        'all-clear and zero header suppressed', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: HeartSpikeReviewScreen(samples: [], storedSpikeCount: 24),
      ));
      await tester.pumpAndSettle();
      expect(find.text(spikeReviewStoredCountLine(24)), findsOneWidget);
      expect(find.text(spikeReviewDetailUnavailableLine), findsOneWidget);
      expect(find.text('0 Significant Spikes Detected'), findsNothing);
      expect(find.text('Normal Physiological Load'), findsNothing);
      expect(
          find.text(
              'All heart rate readings stayed within normal resting and active ranges.'),
          findsNothing);
    });

    testWidgets(
        '4b. empty series + no stored count: detail line alone',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: HeartSpikeReviewScreen(samples: []),
      ));
      await tester.pumpAndSettle();
      expect(find.text(spikeReviewDetailUnavailableLine), findsOneWidget);
      expect(find.textContaining('Spike count saved'), findsNothing);
      expect(find.text('0 Significant Spikes Detected'), findsNothing);
      expect(find.text('Normal Physiological Load'), findsNothing);
    });

    testWidgets(
        '4c. empty series + stored count 0: detail line alone, '
        'no zero-spike claim', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: HeartSpikeReviewScreen(samples: [], storedSpikeCount: 0),
      ));
      await tester.pumpAndSettle();
      expect(find.text(spikeReviewDetailUnavailableLine), findsOneWidget);
      expect(find.textContaining('Spike count saved'), findsNothing);
      expect(find.text('0 Significant Spikes Detected'), findsNothing);
    });

    testWidgets(
        '4d. examined day with 0 events keeps the all-clear',
        (tester) async {
      final base = DateTime(2026, 10, 12, 9).millisecondsSinceEpoch;
      await tester.pumpWidget(MaterialApp(
        home: HeartSpikeReviewScreen(samples: [
          HrSample(timeMs: base, bpm: 60),
          HrSample(timeMs: base + 60000, bpm: 65),
        ]),
      ));
      await tester.pumpAndSettle();
      expect(find.text('0 Significant Spikes Detected'), findsOneWidget);
      expect(find.text('Normal Physiological Load'), findsOneWidget);
      expect(
          find.text(
              'All heart rate readings stayed within normal resting and active ranges.'),
          findsOneWidget);
    });
  });

  group('Shared bounds', () {
    test('5a. the outcome path is bounded inside the service '
        '(READ_TIMEOUT, fail-closed); the legacy path still '
        'delegates on an answering bridge', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final channel =
          MethodChannel(HealthConnectService.channelName);
      var answer = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readHeartRateSamples') {
          if (!answer) {
            // A bridge that never answers inside the test window.
            return Future<dynamic>.delayed(const Duration(seconds: 10));
          }
          return [
            {'t': 1763937600000, 'bpm': 72},
          ];
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final svc = HealthConnectService(
        readTimeoutOverride: const Duration(milliseconds: 100),
      );
      // The outcome variant (Home's vitals path) inherits the
      // in-service bound: a wedged bridge fails closed as
      // READ_TIMEOUT instead of hanging the load forever.
      final outcome = await svc.readHeartRateSamplesWithOutcome('2026-11-23');
      expect(outcome.value, isEmpty);
      expect(outcome.errorCode, 'READ_TIMEOUT');
      expect(svc.lastReadErrorCode, 'READ_TIMEOUT');
      // The legacy method stays unbounded by design (a timeout
      // Timer would outlive wedged legacy reads in existing
      // callers' widget tests — see the core's comment); on an
      // answering bridge it delegates and returns the samples.
      answer = true;
      final legacy = await svc.readHeartRateSamples('2026-11-23');
      expect(legacy, hasLength(1));
      expect(legacy.single.bpm, 72);
    });

    test('5b. Home write-through gate claims the HR read own '
        'outcome: a sibling partial cannot block it', () async {
      HeartDataCache.instance.debugReset();
      final hc = _SiblingDirtHc();
      final backend = TabsBackend(
        client: MockClient((request) async =>
            http.Response(jsonEncode({'entries': [], 'categories': []}), 200)),
        sessionStore: FakeSessionStore()..token = 'fake-token',
      );
      addTearDown(TabsBackend.debugResetSharedCaches);
      TabsBackend.debugResetSharedCaches();
      final repo = HealthRepository(hc: hc, backend: backend);
      const snapshot = HcAvailability(
        serviceAvailable: true,
        grantedPermissions: HealthConnectService.requiredPermissions,
        bridgeErrorCode: null,
        stepsProbe: null,
        persistedConnected: true,
      );
      final vitals = await repo.loadTodayVitals(snapshot: snapshot);
      expect(vitals.heartRate, isNotNull);
      // The sleep sibling wrote the shared partial slot during
      // the parallel load — the old slot-based gate would have
      // skipped the write-through on exactly this evidence.
      expect(hc.lastPartialErrorCode, 'CAL_PARTIAL_SENTINEL');
      final today = _ds(DateTime.now());
      expect(HeartDataCache.instance.snapshot(today), isNotNull,
          reason:
              'clean HR read must write through even when a sibling '
              'read dirtied the shared slot fields');
      expect(
          HeartDataCache.instance.snapshot(today)!.samples, hasLength(1));
    });
  });
}

/// HR read clean; the SLEEP sibling dirties the shared partial
/// slot during the parallel load (the exact interleaving the old
/// slot-based gate misread: it claimed the shared slots at gate
/// time instead of the HR read's own outcome, so a sibling's
/// partial silently blocked the Heart cache write-through).
class _SiblingDirtHc extends HealthConnectService {
  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12);
    return [HrSample(timeMs: noon.millisecondsSinceEpoch, bpm: 72)];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => 500;

  @override
  Future<int?> readSleepMinutes(String dateStr) async {
    lastPartialErrorCode = 'CAL_PARTIAL_SENTINEL';
    return 420;
  }
}
