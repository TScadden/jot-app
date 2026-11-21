import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/hc_availability.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/home/hc_repair_card.dart';

import 'test_helpers.dart';

/// HC Grant Hardening (§3.5) — the per-type grant tests:
/// - upgrade simulation: the 15 core permissions granted and a
///   NEW optional permission (READ_EXERCISE) ungranted ⇒ core
///   reads resolve; the new type degrades alone;
/// - isolation: one type verified missing (READ_WEIGHT) ⇒ every
///   other surface behaves as fully connected; one type
///   SecurityException-blocked ⇒ the other types still render;
/// - wedge/card behavior: the repair card shows for the wedged
///   state only, its button runs disclosure → request → reload,
///   and a surviving wedge swaps it to the second step;
/// - not-granted distinctness: an empty grant keeps the Link
///   layout and never shows the repair card.

const _exercise = 'android.permission.health.READ_EXERCISE';
const _weight = 'android.permission.health.READ_WEIGHT';
const _totalCal = 'android.permission.health.READ_TOTAL_CALORIES_BURNED';
const _hr = 'android.permission.health.READ_HEART_RATE';

Set<String> _core15() => HealthConnectService.requiredPermissions.toSet();

/// Repository-level HC fake: configurable vitals reads, with a
/// sleep read that can fail the way a wedged grant fails (the
/// service records the failure code + the SecurityException in
/// the details, exactly as the channel path records them).
class _RepoHc extends HealthConnectService {
  List<HrSample> hrSamples = const [];
  int? calories = 300;
  int? sleep = 420;
  bool sleepSecurityFail = false;
  bool hrSecurityFail = false;
  int readCalls = 0;

  void _securityFail() {
    lastReadErrorCode = 'READ_FAILED';
    lastReadErrorDetails =
        'PlatformException(READ_FAILED, java.lang.SecurityException: '
        'Permission denied)';
  }

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    readCalls++;
    if (hrSecurityFail) {
      _securityFail();
      return const [];
    }
    return hrSamples;
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async {
    readCalls++;
    return calories;
  }

  @override
  Future<int?> readSleepMinutes(String dateStr) async {
    readCalls++;
    if (sleepSecurityFail) {
      _securityFail();
      return null;
    }
    return sleep;
  }
}

HealthRepository _repo(_RepoHc hc) => HealthRepository(
      hc: hc,
      backend: TabsBackend(
        client: MockClient((_) async => http.Response('not found', 404)),
        sessionStore: FakeSessionStore(),
      ),
    );

int _todayMs(int hour) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour).millisecondsSinceEpoch;
}

void main() {
  group('grant-state helper', () {
    test('per-feature states: full / partial / none / unknown', () {
      expect(hcGrantStateFor(heartPermissions, const {}),
          HcGrantState.full);
      expect(hcGrantStateFor(vitalsCaloriesPermissions, const {_totalCal}),
          HcGrantState.partial);
      expect(hcGrantStateFor(heartPermissions, const {_hr}),
          HcGrantState.none);
      // Unknown grant layer (missing == null): state is unknown
      // (never "none"), and the attempt rule still attempts.
      expect(hcGrantStateFor(heartPermissions, null),
          HcGrantState.unknown);
      expect(hcShouldAttemptRead(heartPermissions, null), isTrue);
    });

    test('calories pair: anySufficient attempts on one leg, not none', () {
      expect(
          hcShouldAttemptRead(vitalsCaloriesPermissions, const {_totalCal},
              anySufficient: true),
          isTrue);
      expect(
          hcShouldAttemptRead(vitalsCaloriesPermissions, const {_totalCal}),
          isFalse);
      expect(
          hcShouldAttemptRead(
              vitalsCaloriesPermissions,
              const {
                'android.permission.health.READ_ACTIVE_CALORIES_BURNED',
                _totalCal,
              },
              anySufficient: true),
          isFalse);
    });

    test('report parity: hcMetricGrantState rides the generalized helper',
        () {
      final missing = {_hr};
      expect(hcMetricGrantState(HistoryMetric.spikes, missing),
          HcMetricGrantState.none);
      // The resting-HR report pair loses one leg with HR.
      expect(hcMetricGrantState(HistoryMetric.restingHr, missing),
          HcMetricGrantState.partial);
      expect(hcMetricGrantState(HistoryMetric.sleep, missing),
          HcMetricGrantState.full);
    });
  });

  group('upgrade simulation (15 core granted, READ_EXERCISE new)', () {
    test('core vitals resolve; the exercise gate alone is closed',
        () async {
      final hc = _RepoHc()
        ..hrSamples = [
          HrSample(timeMs: _todayMs(10), bpm: 70),
          HrSample(timeMs: _todayMs(12), bpm: 80),
        ];
      // The snapshot the probe reports after the upgrade: the 15
      // core permissions granted; READ_EXERCISE exists in the
      // manifest but was never granted (it is not part of the
      // required set, so it never appears in missingIfKnown —
      // consumers gate it on grantedPermissions, like the badge
      // capture does).
      final snapshot = fakeHcSnapshot(granted: _core15());
      expect(snapshot.missingIfKnown, isEmpty);
      expect(snapshot.grantedPermissions!.contains(_exercise), isFalse);
      expect(snapshot.status, HealthConnectStatus.connected);

      final vitals = await _repo(hc).loadTodayVitals(snapshot: snapshot);
      expect(vitals.heartRate, 75);
      expect(vitals.activeCalories, 300);
      expect(vitals.sleepMinutes, 420);
      expect(vitals.coreReadWedged, isFalse);
    });
  });

  group('isolation', () {
    test('READ_WEIGHT missing ⇒ vitals behave as fully connected',
        () async {
      final hc = _RepoHc()
        ..hrSamples = [
          HrSample(timeMs: _todayMs(10), bpm: 70),
          HrSample(timeMs: _todayMs(12), bpm: 80),
        ];
      final granted = _core15()..remove(_weight);
      final snapshot = fakeHcSnapshot(granted: granted);
      expect(snapshot.missingIfKnown, {_weight});
      // The old global verdict would have nulled every vital.
      final vitals = await _repo(hc).loadTodayVitals(snapshot: snapshot);
      expect(vitals.heartRate, 75);
      expect(vitals.activeCalories, 300);
      expect(vitals.sleepMinutes, 420);
    });

    test('one type SecurityException-blocked ⇒ the others still land',
        () async {
      final hc = _RepoHc()
        ..sleepSecurityFail = true
        ..hrSamples = [
          HrSample(timeMs: _todayMs(10), bpm: 70),
          HrSample(timeMs: _todayMs(12), bpm: 80),
        ];
      final vitals =
          await _repo(hc).loadTodayVitals(snapshot: fakeHcSnapshot());
      expect(vitals.heartRate, 75);
      expect(vitals.activeCalories, 300);
      expect(vitals.sleepMinutes, isNull);
      // Every attempted type was fully granted, so the blocked
      // read IS wedge evidence for the load.
      expect(vitals.coreReadWedged, isTrue);
    });

    test('wedge evidence is conservative under a partial grant', () async {
      // HR read security-fails while the calories pair is partial
      // (TOTAL missing): the failure cannot be attributed past
      // the missing leg, so no wedge is claimed.
      final hc = _RepoHc()..hrSecurityFail = true;
      final granted = _core15()..remove(_totalCal);
      final vitals = await _repo(hc)
          .loadTodayVitals(snapshot: fakeHcSnapshot(granted: granted));
      expect(vitals.heartRate, isNull);
      expect(vitals.coreReadWedged, isFalse);
    });

    test('empty grant ⇒ no reads attempted, log count still resolves',
        () async {
      final hc = _RepoHc();
      final vitals = await _repo(hc).loadTodayVitals(
          snapshot: fakeHcSnapshot(granted: const {}, persistedConnected: false));
      expect(vitals.heartRate, isNull);
      expect(vitals.activeCalories, isNull);
      expect(vitals.sleepMinutes, isNull);
      expect(vitals.coreReadWedged, isFalse);
      expect(hc.readCalls, 0);
    });
  });

  group('wedgedPermissions derivation', () {
    test('steps probe security failure + steps granted ⇒ {READ_STEPS}',
        () {
      final s = fakeHcSnapshot(stepsProbe: HcReadProbeOutcome.securityFailure);
      expect(s.wedgedPermissions,
          {'android.permission.health.READ_STEPS'});
      expect(s.staleWedged, isTrue);
    });

    test('probe failure without the grant is not a wedge', () {
      final granted = _core15()
        ..remove('android.permission.health.READ_STEPS');
      final s = fakeHcSnapshot(
          granted: granted, stepsProbe: HcReadProbeOutcome.securityFailure);
      expect(s.wedgedPermissions, isEmpty);
      expect(s.staleWedged, isFalse);
    });

    test('missingIfKnown is null when the grant layer is unknown', () {
      const s = HcAvailability(
        serviceAvailable: false,
        grantedPermissions: null,
        bridgeErrorCode: 'BRIDGE_DOWN',
        stepsProbe: null,
        persistedConnected: false,
      );
      expect(s.grantKnown, isFalse);
      expect(s.missingIfKnown, isNull);
      expect(s.wedgedPermissions, isEmpty);
    });
  });

  group('Heart repair card (widget)', () {
    setUp(() {
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
    });

    Future<void> pumpHeart(WidgetTester tester, HealthConnectService hc) {
      return tester.pumpWidget(MaterialApp(
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: hc,
          cache: HeartDataCache.instance,
        ),
      ));
    }

    /// Bounded pumps for the dialog steps: while the MF-3
    /// disclosure is open, the card's button shows its progress
    /// spinner, so pumpAndSettle can never settle — pump fixed
    /// steps instead (the dialog's entry animation completes
    /// within them).
    Future<void> pumpDialogSteps(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets(
        'wedged grant → repair card with Juno copy; button runs '
        'disclosure FIRST, then the request; cleared wedge removes '
        'the card', (tester) async {
      final hc = _HeartWedgeHc();
      await pumpHeart(tester, hc);
      await tester.pumpAndSettle();

      expect(find.byType(HcRepairCard), findsOneWidget);
      expect(find.text(hcRepairCardTitle), findsOneWidget);
      expect(find.text(hcRepairCardBody), findsOneWidget);
      expect(find.text(hcRepairCardButton), findsOneWidget);
      // The wedged state is NOT the not-granted state.
      expect(find.text('Link Health Connect'), findsNothing);

      await tester.tap(find.text(hcRepairCardButton));
      await pumpDialogSteps(tester);
      // MF-3: the disclosure is up and NOTHING has launched yet.
      expect(find.text('Continue'), findsOneWidget);
      expect(hc.requestCalls, 0);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(hc.requestCalls, 1);
      // The flow cleared the wedge and the reload removed the
      // card — dismissal derived from state, not latched.
      expect(find.byType(HcRepairCard), findsNothing);
    });

    testWidgets(
        'repair that stays wedged → card swaps to the second step '
        '(remove-access directions)', (tester) async {
      final hc = _HeartWedgeHc()..requestThrowsStale = true;
      await pumpHeart(tester, hc);
      await tester.pumpAndSettle();
      expect(find.byType(HcRepairCard), findsOneWidget);

      await tester.tap(find.text(hcRepairCardButton));
      await pumpDialogSteps(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.byType(HcRepairCard), findsOneWidget);
      expect(find.text(HealthConnectService.staleGrantMessage),
          findsOneWidget);
      expect(find.text(hcRepairCardBody), findsNothing);
    });

    testWidgets(
        'dismissing the disclosure launches nothing and keeps the '
        'card', (tester) async {
      final hc = _HeartWedgeHc();
      await pumpHeart(tester, hc);
      await tester.pumpAndSettle();
      await tester.tap(find.text(hcRepairCardButton));
      await pumpDialogSteps(tester);
      expect(find.text('Continue'), findsOneWidget);
      // The disclosure's dismissive action (its non-Continue
      // button) closes it without a request.
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(hc.requestCalls, 0);
      expect(find.byType(HcRepairCard), findsOneWidget);
    });

    testWidgets(
        'not granted → Link layout, and NO repair card (distinct '
        'states)', (tester) async {
      final hc = _HeartWedgeHc()..granted = const {};
      await pumpHeart(tester, hc);
      await tester.pumpAndSettle();
      expect(find.text('Link Health Connect'), findsOneWidget);
      expect(find.byType(HcRepairCard), findsNothing);
      expect(find.text(hcRepairCardButton), findsNothing);
    });

    testWidgets(
        'unrelated permission missing (Weight) → Heart still '
        'connects and reads (no global verdict)', (tester) async {
      final hc = _HeartWedgeHc()
        ..wedged = false
        ..granted = (_core15()..remove(_weight));
      await pumpHeart(tester, hc);
      await tester.pumpAndSettle();
      expect(find.text('Link Health Connect'), findsNothing);
      expect(find.byType(HcRepairCard), findsNothing);
      expect(hc.readCalls, greaterThan(0));
    });
  });
}

/// Heart-screen fake for the wedge tests: full grant, but every
/// HR read is SecurityException-blocked while [wedged] — the
/// Nov 20, 2026 incident shape. [requestPermissions] unwedges
/// (unless [requestThrowsStale]).
class _HeartWedgeHc extends HealthConnectService {
  bool wedged = true;
  bool requestThrowsStale = false;
  Set<String> granted = _core15();
  int requestCalls = 0;
  int readCalls = 0;

  @override
  Future<HcAvailability> probeAvailability() async => fakeHcSnapshot(
        granted: granted,
        stepsProbe: wedged
            ? HcReadProbeOutcome.securityFailure
            : HcReadProbeOutcome.ok,
        persistedConnected: granted.isNotEmpty,
      );

  @override
  Future<bool> hasPersistedConnection() async => granted.isNotEmpty;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    readCalls++;
    if (wedged) {
      lastReadErrorCode = 'READ_FAILED';
      lastReadErrorDetails =
          'PlatformException(READ_FAILED, java.lang.SecurityException: '
          'Permission denied)';
      return const [];
    }
    return [
      HrSample(timeMs: _todayMs(10), bpm: 70),
      HrSample(timeMs: _todayMs(12), bpm: 80),
    ];
  }

  @override
  Future<Set<String>> requestPermissions() async {
    requestCalls++;
    if (requestThrowsStale) {
      throw const HealthConnectException(
        HealthConnectService.staleGrantCode,
        HealthConnectService.staleGrantMessage,
      );
    }
    wedged = false;
    return HealthConnectService.requiredPermissions;
  }
}
