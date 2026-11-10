import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';

/// Nov 2, 2026 — founder report: tapping the "Android Health
/// (Google Fit, Samsung)" row on the Data connections screen did
/// nothing. It showed "Connected" (green) with a chevron.
///
/// Root cause pinned by these tests: the row ALSO renders as
/// "Connected" from persisted state while the live status check is
/// still pending (`_status == null`), but `_openManageSheet`'s
/// guard read only the live status and silently returned in that
/// state. The live check's first bridge calls carry no timeout
/// (`getStatus` → `isAvailable` / `getGrantedPermissions`), so a
/// wedged Health Connect leaves it pending for the whole visit —
/// the tap is dead the entire time the user is on the screen.
///
/// The fix acts on the EFFECTIVE (displayed) status, so the sheet
/// opens for the connection the row says it is, and these tests
/// pin that behavior plus the honest-affordance chevron rule.

const _explainer = 'Your connection is managed in Health Connect. '
    'To stop Tabs from reading your health data, tap Manage system '
    'permissions and remove access for Tabs there.';
const _sheetStatusStale =
    "Connection problem: Tabs can't read your health data right now.";

/// Fake modeled on the REAL service (Phase 2 PR-2: the screen now
/// derives from probeAvailability(), so the fake fakes the PROBE):
/// the stale state arrives as snapshot DATA — a full grant whose
/// steps probe was a securityFailure ([HcAvailability.staleWedged])
/// — exactly what the real probe reports when grants report
/// complete but the read probe is blocked; a canned
/// [statusException] with any other code becomes the UNKNOWN
/// snapshot (grant layer null, the exception recorded verbatim,
/// its code as the bridge error code). There is NO disconnect()
/// fake: the real disconnect never flipped any status (it only
/// deleted two persisted keys), and the Deactivate control that
/// called it is removed. [statusFuture] overrides the canned
/// status so a test can hold the live check pending forever (the
/// wedged case).
class FakeHCService extends HealthConnectService {
  FakeHCService({
    required this.persisted,
    this.statusResult = HealthConnectStatus.notConnected,
    this.statusFuture,
    this.settingsError,
    this.statusException,
  });

  bool persisted;
  HealthConnectStatus statusResult;
  Future<HealthConnectStatus>? statusFuture;
  HealthConnectException? settingsError;
  HealthConnectException? statusException;
  int settingsCalls = 0;

  HcAvailability _snapshotFor(HealthConnectStatus status) {
    return switch (status) {
      HealthConnectStatus.connected => HcAvailability(
          serviceAvailable: true,
          grantedPermissions: HealthConnectService.requiredPermissions,
          bridgeErrorCode: null,
          stepsProbe: HcReadProbeOutcome.ok,
          persistedConnected: persisted,
        ),
      HealthConnectStatus.partiallyConnected => HcAvailability(
          serviceAvailable: true,
          grantedPermissions: HealthConnectService.requiredPermissions
              .difference(
                  const {'android.permission.health.READ_HEART_RATE_VARIABILITY'}),
          bridgeErrorCode: null,
          stepsProbe: null,
          persistedConnected: persisted,
        ),
      HealthConnectStatus.notConnected => HcAvailability(
          serviceAvailable: true,
          grantedPermissions: const {},
          bridgeErrorCode: null,
          stepsProbe: null,
          persistedConnected: persisted,
        ),
      HealthConnectStatus.unavailable => HcAvailability(
          serviceAvailable: false,
          grantedPermissions: null,
          bridgeErrorCode: null,
          stepsProbe: null,
          persistedConnected: persisted,
        ),
    };
  }

  @override
  Future<bool> hasPersistedConnection() async => persisted;

  @override
  Future<HcAvailability> probeAvailability() {
    final e = statusException;
    if (e != null) {
      if (e.code == HealthConnectService.staleGrantCode) {
        return Future.value(HcAvailability(
          serviceAvailable: true,
          grantedPermissions: HealthConnectService.requiredPermissions,
          bridgeErrorCode: null,
          stepsProbe: HcReadProbeOutcome.securityFailure,
          persistedConnected: persisted,
        ));
      }
      return Future.value(HcAvailability(
        serviceAvailable: false,
        grantedPermissions: null,
        bridgeErrorCode: e.code,
        grantError: e,
        stepsProbe: null,
        persistedConnected: persisted,
      ));
    }
    final future = statusFuture;
    if (future != null) return future.then(_snapshotFor);
    return Future.value(_snapshotFor(statusResult));
  }

  @override
  Future<void> openHealthConnectSettings() async {
    settingsCalls++;
    final e = settingsError;
    if (e != null) throw e;
  }
}

/// No bracketed diagnostic code anywhere in the tree (Juno
/// condition 1 applied to this screen, D5 item: the stale error
/// presents the recovery text with NO '[STALE_GRANT]' prefix).
void expectNoBracketedCode(WidgetTester tester) {
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final data = widget.data ?? '';
    expect(data, isNot(matches(RegExp(r'\[[A-Z][A-Z0-9_]*\]'))),
        reason: 'screen rendered a bracketed code: "$data"');
  }
  expect(find.textContaining('[STALE_GRANT]'), findsNothing);
}

Future<void> _pump(WidgetTester tester, FakeHCService service) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: ConnectionsScreen(healthConnectService: service)),
  );
}

void main() {
  group('Data connections — Android Health row tap (Nov 2, 2026)', () {
    testWidgets(
        'REGRESSION: persisted Connected row, live status still '
        'pending (wedged check) — tap opens the manage sheet',
        (tester) async {
      final completer = Completer<HealthConnectStatus>();
      final service = FakeHCService(
        persisted: true,
        statusFuture: completer.future,
      );
      await _pump(tester, service);
      await tester.pump();
      await tester.pump();

      // The row is in its persisted first-paint state: it SAYS
      // Connected and shows the chevron while _status is null.
      expect(find.text('Connected'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsWidgets);

      await tester.tap(find.text('Android Health (Google Fit, Samsung)'));
      await tester.pumpAndSettle();

      // Before the fix this found nothing: the tap silently no-oped.
      // HC honesty: there is NO "Deactivate in Tabs" control —
      // the healthy sheet carries the ruled explainer (item 6) and
      // "Manage system permissions" as the only revoke path.
      expect(find.text('Deactivate in Tabs'), findsNothing);
      expect(find.text(_explainer), findsOneWidget);
      expect(find.text('Manage system permissions'), findsOneWidget);

      completer.complete(HealthConnectStatus.connected);
      await tester.pumpAndSettle();
    });

    testWidgets(
        'settled Connected — tap opens the manage sheet: no Deactivate '
        'control, ruled explainer, Manage system permissions',
        (tester) async {
      final service = FakeHCService(
        persisted: true,
        statusResult: HealthConnectStatus.connected,
      );
      await _pump(tester, service);
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);

      await tester.tap(find.text('Android Health (Google Fit, Samsung)'));
      await tester.pumpAndSettle();
      expect(find.text('Deactivate in Tabs'), findsNothing);
      expect(find.text(_explainer), findsOneWidget);
      expect(find.text('Manage system permissions'), findsOneWidget);
      expectNoBracketedCode(tester);
    });

    testWidgets(
        'stale grant (snapshot staleWedged, persisted flag set) '
        '→ row shows "Connection problem", never "Connected"; sheet '
        'shows item 4 + recovery steps (item 5) + Manage system '
        'permissions; no [STALE_GRANT] anywhere', (tester) async {
      final service = FakeHCService(
        persisted: true,
        statusException: const HealthConnectException(
          HealthConnectService.staleGrantCode,
          HealthConnectService.staleGrantMessage,
        ),
      );
      await _pump(tester, service);
      await tester.pumpAndSettle();

      // The persisted-flag fallback must NOT manufacture "Connected"
      // out of the stale throw.
      expect(find.text('Connection problem'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      // The screen's stale error line presents item 5 with no prefix.
      expect(
          find.text(HealthConnectService.staleGrantMessage), findsOneWidget);
      expectNoBracketedCode(tester);

      await tester.tap(find.text('Android Health (Google Fit, Samsung)'));
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text(_sheetStatusStale)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: sheet,
            matching: find.text(HealthConnectService.staleGrantMessage)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: sheet, matching: find.text('Manage system permissions')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: sheet, matching: find.text('Deactivate in Tabs')),
        findsNothing,
      );
      expectNoBracketedCode(tester);
    });

    testWidgets(
        'Manage system permissions failure surfaces visibly as the '
        'plain message after the sheet closes (not hidden, not wiped, '
        'no bracketed code)', (tester) async {
      final service = FakeHCService(
        persisted: true,
        statusResult: HealthConnectStatus.connected,
        settingsError: const HealthConnectException(
            'NO_SETTINGS', 'No foreground activity is available.'),
      );
      await _pump(tester, service);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Android Health (Google Fit, Samsung)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage system permissions'));
      await tester.pumpAndSettle();

      expect(service.settingsCalls, 1);
      expect(find.text('Deactivate in Tabs'), findsNothing);
      expect(
        find.text('No foreground activity is available.'),
        findsOneWidget,
      );
      expect(
        find.text('[NO_SETTINGS] No foreground activity is available.'),
        findsNothing,
      );
      expectNoBracketedCode(tester);
    });

    testWidgets(
        'unavailable row is honestly non-interactive: no chevron',
        (tester) async {
      final service = FakeHCService(
        persisted: false,
        statusResult: HealthConnectStatus.unavailable,
      );
      await _pump(tester, service);
      await tester.pumpAndSettle();

      expect(find.text('Not available on this device'), findsOneWidget);
      // Before the fix the disabled row still rendered a chevron.
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      // The retired Fitbit card stays plain text/card, no chevron.
      expect(find.text('Fitbit (Direct Sync)'), findsOneWidget);
      expect(find.text('No longer available'), findsOneWidget);
    });
  });
}
