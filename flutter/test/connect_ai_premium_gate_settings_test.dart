import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';

import 'settings_r29_test.dart' as r29;
import 'settings_r30_google_test.dart' as r30g;
import 'settings_r51_connstate_test.dart' as r51;

/// Premium gate — Settings routing. The Connect an AI screen's
/// Upgrade to Premium button pops the route with the
/// upgrade-request result; Settings' `_openConnectAi` must then
/// switch the SAME Settings instance to its Membership page
/// (no new purchase flow). Driven through the real Settings
/// screen with the Round 51 harness: the fake backend's sync
/// pull reports a free account, so Connect an AI opens in
/// Juno's Premium state.
void main() {
  testWidgets(
      'free user: Connect an AI upgrade lands on Membership in '
      'the same Settings', (tester) async {
    final backend = r30g.LinkBackend()
      ..pullBody = r29.pull(isUnlimited: false);
    await r51.pumpSettings(
      tester,
      backend: backend,
      map: {},
      hc: r51.FakeHCService(HealthConnectStatus.connected),
    );
    await r51.openConnectedApps(tester);

    await tester.tap(find.byKey(const ValueKey('connect_ai_entry')));
    await tester.pumpAndSettle();
    expect(find.text('Connecting an AI needs Premium'), findsOneWidget);
    expect(find.text('Upgrade to Premium'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('upgrade_to_premium')));
    await tester.pumpAndSettle();

    // The Connect an AI route is gone and Settings is showing
    // its Membership page (app-bar title + segmented header).
    expect(find.text('Connecting an AI needs Premium'), findsNothing);
    expect(find.text('Upgrade to Premium'), findsNothing);
    expect(find.text('Membership'), findsWidgets);
  });
}
