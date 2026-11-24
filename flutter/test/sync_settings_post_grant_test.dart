import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart' show HrSample;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/connections/connect_ai_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'connect_ai_screen_test.dart' as cai;
import 'settings_r29_test.dart' as r29;
import 'settings_r30_google_test.dart' as r30g;
import 'settings_r51_connstate_test.dart' as r51;
import 'test_helpers.dart';

/// Sync-settings package (Nov 23, 2026) — post-grant capture,
/// resume re-probe, honest end states, and the Connect an AI
/// copy/share additions.
///
/// Pins, in order:
/// - the F1 regression: a successful capture 10 minutes before
///   a grant must NOT floor out the post-grant capture (#161's
///   app-open floor does skip `captureOnAppOpen` there — the
///   post-grant entry is force, which bypasses both gates);
/// - the stamp distinction: an all-failed capture writes NO
///   successful-capture stamp; a clean-but-empty capture
///   stamps; a partial spike envelope is not a failure and
///   stamps;
/// - Settings + Connections re-probe on app resume;
/// - the post-grant working → success / no-data / failure
///   transitions with Juno's exact strings on the Settings
///   Connected Apps card, and the working mirror on Connections;
/// - Connect an AI: exact clipboard values, confirmations only
///   on success, the Meta row verbatim, the share sending
///   Juno's exact text, and all of it absent for non-Premium.

// ── Capture fakes ─────────────────────────────────────────────

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

HealthHistoryStore _fakeStore() {
  final fake = _FakeStore();
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

/// Capture HC fake driven at the outcome layer: every leg's
/// outcome is a field the test sets. Resting-HR calls count the
/// capture runs (one per run).
class _OutcomeHc extends HealthConnectService {
  int restingHrCalls = 0;
  Completer<void>? restingHrGate;

  HcReadOutcome<List<({String date, int bpm})>> restingHrOutcome =
      HcReadOutcome(value: const []);
  HcReadOutcome<List<({String date, int mins, int deep})>> sleepOutcome =
      HcReadOutcome(value: const []);
  HcReadOutcome<List<({int t, double ms, int tier})>> hrvOutcome =
      HcReadOutcome(value: const []);
  HcReadOutcome<List<({String date, int kcal})>> caloriesOutcome =
      HcReadOutcome(value: const []);
  HcReadOutcome<List<({String date, int count})>> spikesOutcome =
      HcReadOutcome(value: const []);

  @override
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) async {
    restingHrCalls++;
    final gate = restingHrGate;
    if (gate != null) await gate.future;
    return restingHrOutcome;
  }

  @override
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) async => sleepOutcome;

  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) async => hrvOutcome;

  @override
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) async => caloriesOutcome;

  @override
  Future<HcReadOutcome<List<({String date, int count})>>>
      readSpikeCountsWithOutcome(int days) async => spikesOutcome;

  @override
  Future<HcReadOutcome<List<HrSample>>> readHrSamplesRangeWithOutcome({
    required int startMs,
    required int endMs,
  }) async =>
      HcReadOutcome(value: const []);
}

/// HC fake whose resting-HR read THROWS (a bridge read that
/// throws instead of returning an outcome) — the capture body
/// does not complete, so `capture` returns false (`ran` is
/// false) and the whole-map row-count assignment at run end
/// never happens (Vera Condition 1 remainder probe shape).
class _ThrowingRestingHrHc extends _OutcomeHc {
  @override
  Future<HcReadOutcome<List<({String date, int bpm})>>>
      readRestingHrHistoryWithOutcome(int days) async {
    restingHrCalls++;
    throw StateError('bridge read failed');
  }
}

void _failAllLegs(_OutcomeHc hc) {
  const code = 'PERMISSION_DENIED';
  hc.restingHrOutcome = HcReadOutcome(value: const [], errorCode: code);
  hc.sleepOutcome = HcReadOutcome(value: const [], errorCode: code);
  hc.hrvOutcome = HcReadOutcome(value: const [], errorCode: code);
  hc.caloriesOutcome = HcReadOutcome(value: const [], errorCode: code);
  hc.spikesOutcome = HcReadOutcome(value: const [], errorCode: code);
}

HealthHistorySync _sync(_OutcomeHc hc, HealthHistoryStore store,
        {DateTime Function()? now}) =>
    HealthHistorySync.withDeps(hc: hc, store: store, now: now);

// ── Connections fake (grant flow) ─────────────────────────────

class _GrantHc extends HealthConnectService {
  _GrantHc({required this.grantResult});

  Set<String> grantResult;
  Set<String> probedGranted = const {};
  int probeCalls = 0;
  int requestCalls = 0;

  @override
  Future<bool> hasPersistedConnection() async => false;

  @override
  Future<HcAvailability> probeAvailability() async {
    probeCalls++;
    return HcAvailability(
      serviceAvailable: true,
      grantedPermissions: probedGranted,
      bridgeErrorCode: null,
      stepsProbe: null,
      persistedConnected: false,
    );
  }

  @override
  Future<Set<String>> requestPermissions() async {
    requestCalls++;
    probedGranted = grantResult;
    return grantResult;
  }
}

// ── Settings screen with an injectable history store (the
// r51 harness's pump cannot pass one; same fakes it uses) ────

Widget _settingsScreen({
  required r30g.LinkBackend backend,
  required HealthConnectService hc,
  required HealthHistoryStore store,
}) =>
    SettingsScreen(
      backend: backend,
      settingsStore: r51.store({}),
      notificationService: FakeReminderNotificationService(),
      googleSignInService: r30g.FakeGoogle(),
      healthConnectService: hc,
      historyStore: store,
      urlLauncher: (uri) async => true,
    );

void main() {
  setUp(() {
    HealthHistorySync.debugResetFlight();
    HealthHistorySync.debugResetPostGrantStatus();
  });
  tearDown(() {
    HealthHistorySync.debugResetFlight();
    HealthHistorySync.debugResetPostGrantStatus();
    ConnectAiShareService.debugSetShareFn(null);
  });

  group('post-grant capture entry (F1 regression)', () {
    test('captureOnAppOpen is floored at 10 min, captureAfterGrant is not',
        () async {
      final now = DateTime(2026, 11, 23, 12);
      final store = _fakeStore();
      await store.mergeRefresh([
        const DailyBiometrics(
            date: '2026-11-22', sleepMinutes: 480, restingHrBpm: 60),
      ]);
      await store.markCaptured(
          now.millisecondsSinceEpoch - const Duration(minutes: 10).inMilliseconds);
      final hc = _OutcomeHc()
        ..restingHrOutcome = HcReadOutcome(
            value: const [(date: '2026-11-23', bpm: 61)]);
      final sync = _sync(hc, store, now: () => now);

      // The #161 floor: the app-open entry skips.
      expect(await sync.captureOnAppOpen(), isFalse);
      expect(hc.restingHrCalls, 0);

      // The post-grant entry (force) runs anyway and lands on
      // the data-came-through outcome.
      final outcome = await sync.captureAfterGrant(relevantPermissions: {
        'android.permission.health.READ_RESTING_HEART_RATE',
      });
      expect(hc.restingHrCalls, 1);
      expect(outcome, PostGrantCaptureOutcome.dataCameThrough);
      expect(sync.postGrantStatus.phase, PostGrantCapturePhase.settled);
      expect(sync.postGrantStatus.outcome,
          PostGrantCaptureOutcome.dataCameThrough);
    });

    test('permission → capture-metric mapping', () {
      expect(
          HealthHistorySync.captureMetricsForPermissions(
              {'android.permission.health.READ_HEART_RATE'}),
          {'restingHr', 'spikes'});
      expect(
          HealthHistorySync.captureMetricsForPermissions(
              {'android.permission.health.READ_SLEEP'}),
          {'sleep'});
      expect(
          HealthHistorySync.captureMetricsForPermissions(
              {'android.permission.health.READ_STEPS'}),
          isEmpty);
    });
  });

  group('stamp distinction (throttle-poison hardening)', () {
    test('all-failed capture writes NO stamp', () async {
      final store = _fakeStore();
      final hc = _OutcomeHc();
      _failAllLegs(hc);
      final sync = _sync(hc, store);
      expect(await sync.capture(), isTrue);
      expect(store.lastCaptureMs, isNull);
    });

    test('clean-but-empty capture stamps', () async {
      final store = _fakeStore();
      final hc = _OutcomeHc(); // every leg clean, zero rows
      final sync = _sync(hc, store);
      expect(await sync.capture(), isTrue);
      expect(store.lastCaptureMs, isNotNull);
    });

    test('partial spike envelope is not a failure: stamps, no-data outcome',
        () async {
      final store = _fakeStore();
      final hc = _OutcomeHc()
        ..spikesOutcome = HcReadOutcome(
            value: const [],
            partialCode: 'SPIKE_COUNTS_PARTIAL',
            errorDetails: 'some chunks failed');
      final sync = _sync(hc, store);
      final outcome = await sync.captureAfterGrant(relevantPermissions: {
        'android.permission.health.READ_HEART_RATE',
      });
      expect(store.lastCaptureMs, isNotNull);
      expect(outcome, PostGrantCaptureOutcome.noDataYet);
    });

    test('all-failed post-grant capture derives readFailed', () async {
      final store = _fakeStore();
      final hc = _OutcomeHc();
      _failAllLegs(hc);
      final sync = _sync(hc, store);
      final outcome = await sync.captureAfterGrant(relevantPermissions: {
        'android.permission.health.READ_RESTING_HEART_RATE',
      });
      expect(outcome, PostGrantCaptureOutcome.readFailed);
    });

    test('derivePostGrantOutcome pure cases', () {
      CaptureMetricEvidence ev({bool failed = false, bool partial = false}) =>
          CaptureMetricEvidence(
            readFailed: failed,
            partialRead: partial,
            readSecurityException: false,
            errorCode: failed ? 'X' : null,
            partialCode: partial ? 'P' : null,
          );
      // Data beats everything.
      expect(
          HealthHistorySync.derivePostGrantOutcome(
            ran: true,
            evidence: {'restingHr': ev(failed: true)},
            rowCounts: {'restingHr': 3},
            relevantMetrics: {'restingHr'},
          ),
          PostGrantCaptureOutcome.dataCameThrough);
      // Irrelevant legs failing does not fail the verdict.
      expect(
          HealthHistorySync.derivePostGrantOutcome(
            ran: true,
            evidence: {'restingHr': ev(), 'sleep': ev(failed: true)},
            rowCounts: const {},
            relevantMetrics: {'restingHr'},
          ),
          PostGrantCaptureOutcome.noDataYet);
      // A partial relevant leg is not a failure.
      expect(
          HealthHistorySync.derivePostGrantOutcome(
            ran: true,
            evidence: {'spikes': ev(partial: true)},
            rowCounts: const {},
            relevantMetrics: {'spikes'},
          ),
          PostGrantCaptureOutcome.noDataYet);
      // Vera Condition 1 remainder: an incomplete run (ran ==
      // false) produced no evidence of its own — stale row
      // counts from a prior completed run must never settle
      // it as dataCameThrough.
      expect(
          HealthHistorySync.derivePostGrantOutcome(
            ran: false,
            evidence: {'restingHr': ev()},
            rowCounts: {'restingHr': 3},
            relevantMetrics: {'restingHr'},
          ),
          PostGrantCaptureOutcome.readFailed);
    });
  });

  group('cross-instance evidence (Vera Condition 1)', () {
    // Vera's proof shape: the flight state is static, so
    // captureAfterGrant (on an instance that never captured)
    // can JOIN a forced flight owned by a DIFFERENT instance
    // (DailyScoreRefresher's factory builds a fresh withDeps
    // instance; its refresh is the other force:true caller).
    // The settled outcome must derive from the JOINED run's
    // evidence, not the joining instance's own stale/empty
    // evidence.
    test(
        'captureAfterGrant joining a FOREIGN forced flight derives '
        'dataCameThrough from the joined run', () async {
      final hcA = _OutcomeHc()
        ..restingHrGate = Completer<void>()
        ..restingHrOutcome = HcReadOutcome(
            value: const [(date: '2026-11-23', bpm: 61)]);
      final a = _sync(hcA, _fakeStore());
      final hcB = _OutcomeHc();
      final b = _sync(hcB, _fakeStore()); // never captured

      final aFuture = a.capture(force: true);
      // Wait until A's forced run is in flight and inside its
      // (gated) resting-HR read.
      while (hcA.restingHrCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(b.captureInFlight, isTrue);

      // B joins A's forced flight (single-flight: no second
      // capture starts on B's dependencies).
      final bFuture = b.captureAfterGrant(relevantPermissions: {
        'android.permission.health.READ_HEART_RATE',
      });
      hcA.restingHrGate!.complete();

      expect(await aFuture, isTrue);
      final outcome = await bFuture;
      expect(hcA.restingHrCalls, 1);
      expect(hcB.restingHrCalls, 0);
      // The joined run returned a resting-HR row — a metric
      // READ_HEART_RATE is relevant to — so the outcome is the
      // joined run's, not readFailed from B's own empty evidence.
      expect(outcome, PostGrantCaptureOutcome.dataCameThrough);
      expect(b.postGrantStatus.outcome,
          PostGrantCaptureOutcome.dataCameThrough);
    });

    test(
        'captureAfterGrant joining a FOREIGN forced flight that '
        'returned no relevant rows does NOT claim dataCameThrough',
        () async {
      final hcA = _OutcomeHc()..restingHrGate = Completer<void>();
      // Every leg clean, zero rows (the _OutcomeHc defaults).
      final a = _sync(hcA, _fakeStore());
      final hcB = _OutcomeHc();
      final b = _sync(hcB, _fakeStore()); // never captured

      final aFuture = a.capture(force: true);
      while (hcA.restingHrCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final bFuture = b.captureAfterGrant(relevantPermissions: {
        'android.permission.health.READ_HEART_RATE',
      });
      hcA.restingHrGate!.complete();

      expect(await aFuture, isTrue);
      final outcome = await bFuture;
      expect(hcB.restingHrCalls, 0);
      // The joined run read cleanly but returned no relevant
      // rows: the honest outcome is noDataYet — never a false
      // dataCameThrough, and not readFailed either (the joined
      // run's relevant legs did not fail).
      expect(outcome, PostGrantCaptureOutcome.noDataYet);
      expect(
          b.postGrantStatus.outcome, PostGrantCaptureOutcome.noDataYet);
    });
  });

  group('incomplete run (Vera Condition 1 remainder)', () {
    // Vera's delta re-review probe: _lastCaptureRowCounts is
    // reassigned only at the end of a capture body that
    // COMPLETES. A post-grant run that throws / does not
    // complete never reassigns it, so it must never settle on
    // a prior completed run's counts.
    test(
        'post-grant run whose relevant read throws derives '
        'readFailed, never dataCameThrough from a prior run',
        () async {
      // Prior completed run with relevant rows (resting HR).
      final hcA = _OutcomeHc()
        ..restingHrOutcome = HcReadOutcome(
            value: const [(date: '2026-11-23', bpm: 61)]);
      final a = _sync(hcA, _fakeStore());
      expect(await a.capture(force: true), isTrue);
      expect(a.lastCaptureRowCounts['restingHr'], 1);

      // Fresh instance B: its captureAfterGrant run's resting-HR
      // read throws, so the capture does not complete.
      final hcB = _ThrowingRestingHrHc();
      final b = _sync(hcB, _fakeStore());
      final outcome = await b.captureAfterGrant(relevantPermissions: {
        'android.permission.health.READ_HEART_RATE',
      });
      expect(hcB.restingHrCalls, 1);
      expect(outcome, PostGrantCaptureOutcome.readFailed);
      expect(
          b.postGrantStatus.outcome, PostGrantCaptureOutcome.readFailed);
    });
  });

  group('resume re-probe', () {
    testWidgets('Connections re-probes on resume', (tester) async {
      final service = _GrantHc(grantResult: const {});
      await tester.pumpWidget(
          MaterialApp(home: ConnectionsScreen(healthConnectService: service)));
      await tester.pumpAndSettle();
      final before = service.probeCalls;
      expect(before, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.probeCalls, greaterThan(before));
    });

    testWidgets('Settings re-probes on resume', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = r51.FakeHCService(HealthConnectStatus.connected);
      await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
      // Baseline via the menu-tap load: this harness's initState
      // _load() never reaches _loadConnectionState under fake
      // async (a pre-existing harness trait — the r51/phase-2
      // suites all drive the probe via this same tap), so the
      // probe count is established by opening Connected Apps.
      await tester.tap(find.byKey(const ValueKey('menu_connected_apps')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final before = hc.statusCalls;
      expect(before, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(hc.statusCalls, greaterThan(before));
    });
  });

  group('Connections grant → post-grant capture', () {
    testWidgets(
        'grant success fires the capture (not floored by a 10-min-old '
        'stamp) and mirrors the working state', (tester) async {
      // The shared sync instance runs against a capture fake
      // whose store carries a successful stamp from 10 minutes
      // ago — the exact F1 regression setup.
      final store = _fakeStore();
      await store.mergeRefresh([
        const DailyBiometrics(
            date: '2026-11-22', sleepMinutes: 480, restingHrBpm: 60),
      ]);
      await store.markCaptured(DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch);
      final captureHc = _OutcomeHc()
        ..restingHrGate = Completer<void>()
        ..restingHrOutcome = HcReadOutcome(
            value: const [(date: '2026-11-23', bpm: 61)]);
      HealthHistorySync.instance
          .debugSetDeps(hc: captureHc, store: store);

      final service =
          _GrantHc(grantResult: HealthConnectService.requiredPermissions);
      await tester.pumpWidget(
          MaterialApp(home: ConnectionsScreen(healthConnectService: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Available'));
      await tester.pumpAndSettle();
      // MF-3 disclosure first — nothing has launched yet.
      expect(find.text('Continue'), findsOneWidget);
      expect(service.requestCalls, 0);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump();

      // The capture fired despite the fresh stamp, and the
      // working state mirrors on the row while it runs.
      expect(service.requestCalls, 1);
      expect(captureHc.restingHrCalls, 1);
      expect(find.text('Reading your health data now.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      captureHc.restingHrGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Reading your health data now.'), findsNothing);
      expect(HealthHistorySync.instance.postGrantStatus.outcome,
          PostGrantCaptureOutcome.dataCameThrough);
    });
  });

  group('Settings Connected Apps — post-grant states', () {
    Future<void> settleOutcome(
      _OutcomeHc captureHc, {
      required Set<String> relevant,
    }) async {
      final sync = _sync(captureHc, _fakeStore());
      await sync.captureAfterGrant(relevantPermissions: relevant);
    }

    testWidgets('working → success transition with Juno strings',
        (tester) async {
      final captureHc = _OutcomeHc()
        ..restingHrGate = Completer<void>()
        ..restingHrOutcome = HcReadOutcome(
            value: const [(date: '2026-11-23', bpm: 61)]);
      final sync = _sync(captureHc, _fakeStore());
      final future = sync.captureAfterGrant(relevantPermissions: {
        'android.permission.health.READ_RESTING_HEART_RATE',
      });
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = r51.FakeHCService(HealthConnectStatus.connected);
      await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
      // NOT openConnectedApps: pumpAndSettle would spin forever
      // on the working state's animated progress indicator.
      await tester.tap(find.byKey(const ValueKey('menu_connected_apps')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Reading your health data now.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      captureHc.restingHrGate!.complete();
      await future;
      await tester.pumpAndSettle();
      // The settle reload (scheduled by _loadConnectionState)
      // lands the card on the success line.
      expect(find.text('Connected. Your health data is coming through.'),
          findsOneWidget);
      expect(find.text('Live synchronization active'), findsNothing);
    });

    testWidgets('no-data outcome shows Juno no-data line, never '
        'not-connected styling', (tester) async {
      await settleOutcome(_OutcomeHc(), relevant: {
        'android.permission.health.READ_RESTING_HEART_RATE',
      });
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = r51.FakeHCService(HealthConnectStatus.connected);
      await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await r51.openConnectedApps(tester);
      expect(
          find.text(
              'Connected, but Health Connect does not have any of this data yet. It shows up here after your watch or phone records some.'),
          findsOneWidget);
      expect(find.text('Connect Health Data'), findsNothing);
      expect(find.text('Live synchronization active'), findsNothing);
    });

    testWidgets('failure outcome shows Juno failure line + Re-approve '
        'access button', (tester) async {
      final captureHc = _OutcomeHc();
      _failAllLegs(captureHc);
      await settleOutcome(captureHc, relevant: {
        'android.permission.health.READ_RESTING_HEART_RATE',
      });
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = r51.FakeHCService(HealthConnectStatus.connected);
      await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await r51.openConnectedApps(tester);
      expect(
          find.text(
              'Tabs could not read your health data this time. Tap Re-approve access to try again.'),
          findsOneWidget);
      expect(find.text('Re-approve access'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('post_grant_reapprove')), findsOneWidget);
    });

    testWidgets(
        'standing overclaim: a capture ran and the store holds no data '
        '→ no-data line replaces the live-sync claim', (tester) async {
      // A store whose only capture stamped but merged nothing.
      final store = _fakeStore();
      await store.markCaptured(DateTime.now().millisecondsSinceEpoch);
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = r51.FakeHCService(HealthConnectStatus.connected);
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: _settingsScreen(backend: backend, hc: hc, store: store),
        ),
      ));
      await tester.pumpAndSettle();
      await r51.openConnectedApps(tester);
      expect(
          find.text(
              'Connected, but Health Connect does not have any of this data yet. It shows up here after your watch or phone records some.'),
          findsOneWidget);
      expect(find.text('Live synchronization active'), findsNothing);
      expect(find.text('• Connected to local device sensors'), findsNothing);
    });
  });

  group('Connect an AI — copy + share (Part 3)', () {
    Future<void> pumpPremium(
      WidgetTester tester, {
      Future<bool> Function(String)? copy,
      bool premium = true,
    }) async {
      final backend = cai.FakeAiBackend(
        fetchResult: const [],
        membershipResult: premium
            ? const (isUnlimited: true, isAdmin: false)
            : const (isUnlimited: false, isAdmin: false),
      );
      await tester.pumpWidget(MaterialApp(
        home: ConnectAiScreen(backend: backend, copyToClipboard: copy),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('address row copies the exact address; confirmation '
        'only on success', (tester) async {
      final copied = <String>[];
      await pumpPremium(tester, copy: (t) async {
        copied.add(t);
        return true;
      });
      expect(find.text('https://api.jottracker.com/mcp'), findsOneWidget);
      expect(find.text('Copy address'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('copy_address_button')));
      await tester.pumpAndSettle();
      expect(copied, ['https://api.jottracker.com/mcp']);
      expect(find.text('Address copied'), findsOneWidget);
    });

    testWidgets('failed copy shows NO success text', (tester) async {
      await pumpPremium(tester, copy: (t) async => false);
      await tester.tap(find.byKey(const ValueKey('copy_address_button')));
      await tester.pumpAndSettle();
      expect(find.text('Address copied'), findsNothing);
    });

    testWidgets('Meta AI ID row is verbatim and copies the exact ID',
        (tester) async {
      final copied = <String>[];
      await pumpPremium(tester, copy: (t) async {
        copied.add(t);
        return true;
      });
      expect(find.text('Meta AI ID'), findsOneWidget);
      expect(
          find.text(
              'Meta AI asks for an ID too. This one is the same for everyone, and it is not a password.'),
          findsOneWidget);
      expect(find.text('6ESJxB8bNERxr3VtRulg0w'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('copy_meta_id_button')));
      await tester.pumpAndSettle();
      expect(copied, ['6ESJxB8bNERxr3VtRulg0w']);
      expect(find.text('ID copied'), findsOneWidget);
    });

    testWidgets('share sends Juno\'s exact steps text', (tester) async {
      String? shared;
      ConnectAiShareService.debugSetShareFn((text) async {
        shared = text;
      });
      await pumpPremium(tester);
      // The row sits below the fold of the premium list —
      // scroll it into the built tree before asserting/tapping.
      await tester.scrollUntilVisible(
          find.text('Send these steps to a friend'), 200);
      await tester.pumpAndSettle();
      expect(find.text('Send these steps to a friend'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('send_steps_row')));
      await tester.pumpAndSettle();
      expect(
          shared,
          'Connect your AI to Tabs:\n'
          '1. In your AI app, add a new connection and paste in this address: https://api.jottracker.com/mcp\n'
          '2. If it asks for an ID (Meta AI does), use this one, the same for everyone: 6ESJxB8bNERxr3VtRulg0w\n'
          '3. Sign in with your own Tabs account and tap Approve.\n'
          'This lets your AI read your own Tabs data. It gives me no access to anything, and nothing connects until you approve it.');
    });

    testWidgets('none of the Part 3 additions render for non-Premium',
        (tester) async {
      await pumpPremium(tester, premium: false);
      expect(find.text('https://api.jottracker.com/mcp'), findsNothing);
      expect(find.text('Copy address'), findsNothing);
      expect(find.text('Meta AI ID'), findsNothing);
      expect(find.text('6ESJxB8bNERxr3VtRulg0w'), findsNothing);
      expect(find.text('Send these steps to a friend'), findsNothing);
    });
  });
}
