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

/// Stateful fake: [statusFuture] overrides the canned status so a
/// test can hold the live check pending forever (the wedged case).
class FakeHCService extends HealthConnectService {
  FakeHCService({
    required this.persisted,
    this.statusResult = HealthConnectStatus.notConnected,
    this.statusFuture,
    this.settingsError,
  });

  bool persisted;
  HealthConnectStatus statusResult;
  Future<HealthConnectStatus>? statusFuture;
  HealthConnectException? settingsError;
  int disconnectCalls = 0;
  int settingsCalls = 0;

  @override
  Future<bool> hasPersistedConnection() async => persisted;

  @override
  Future<HealthConnectStatus> getStatus() =>
      statusFuture ?? Future.value(statusResult);

  @override
  Future<List<String>> getMissingPermissionLabels() async => const [];

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    persisted = false;
    statusFuture = null;
    statusResult = HealthConnectStatus.notConnected;
  }

  @override
  Future<void> openHealthConnectSettings() async {
    settingsCalls++;
    final e = settingsError;
    if (e != null) throw e;
  }
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
      expect(find.text('Deactivate in Tabs'), findsOneWidget);
      expect(find.text('Manage system permissions'), findsOneWidget);

      completer.complete(HealthConnectStatus.connected);
      await tester.pumpAndSettle();
    });

    testWidgets(
        'settled Connected — tap opens the manage sheet and '
        'Deactivate really disconnects', (tester) async {
      final service = FakeHCService(
        persisted: true,
        statusResult: HealthConnectStatus.connected,
      );
      await _pump(tester, service);
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);

      await tester.tap(find.text('Android Health (Google Fit, Samsung)'));
      await tester.pumpAndSettle();
      expect(find.text('Deactivate in Tabs'), findsOneWidget);
      expect(find.text('Manage system permissions'), findsOneWidget);

      await tester.tap(find.text('Deactivate in Tabs'));
      await tester.pumpAndSettle();
      expect(service.disconnectCalls, 1);
      expect(find.text('Deactivate in Tabs'), findsNothing);
      expect(find.text('No trackers connected yet.'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    });

    testWidgets(
        'Manage system permissions failure surfaces visibly as '
        '[CODE] after the sheet closes (not hidden, not wiped)',
        (tester) async {
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
        find.text('[NO_SETTINGS] No foreground activity is available.'),
        findsOneWidget,
      );
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
