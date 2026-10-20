import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';

import 'settings_r29_test.dart' as r29;
import 'settings_r30_google_test.dart' as r30g;
import 'settings_r51_connstate_test.dart' as r51;

/// Daily Score background Settings card — Juno-final copy
/// (correction round):
///
/// - MF-7 OFF body (grant known absent): the enablement copy
///   with the exact Health Connect settings path, and NO claim
///   that background Health Connect checking works on device
///   today; the `Open Health Connect Settings` button shows.
/// - MF-7 ON body (grant verified on): the background-work copy;
///   no button.
/// - MF-10 unknown state (grant not yet read, or the read threw):
///   a NEUTRAL checking line — not the off copy, not the on copy,
///   not the enablement button, no grant claim at all.
///
/// The card title (`Daily Score in the Background`) and the
/// button label are unchanged from the drafted round.

const _offBody =
    'Tabs can build your Daily Score in the background, so a score may be ready even on days you do not open the app. Android may delay background work to save battery, so a score is not guaranteed by a set time. To allow it, tap Open Health Connect Settings below, then tap Tabs, App permissions, Additional access, and turn on Background access.';
const _onBody =
    'Background access is on. Tabs can work on your Daily Score in the background a few times a day at most, and Android may delay that work to save battery. When a background run creates a new Daily Score, Tabs can notify you if notifications are turned on for Tabs.';

/// The r51 fake HC service with a controllable background-grant
/// read (the base fake's real implementation would hit the
/// unmocked bridge channel and throw — the MF-10 failure shape).
class _BgHc extends r51.FakeHCService {
  _BgHc(super.status, {this.bg = false, this.bgThrows = false});

  bool bg;
  bool bgThrows;

  @override
  Future<bool> hasBackgroundAccess() async {
    if (bgThrows) {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
    return bg;
  }
}

Future<void> _openCard(WidgetTester tester, _BgHc hc) async {
  final backend = r30g.LinkBackend()..pullBody = r29.pull();
  await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
  await r51.openConnectedApps(tester);
  await tester.scrollUntilVisible(
    find.text('Daily Score in the Background'),
    200,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Daily Score in the Background card (MF-7 / MF-10)', () {
    testWidgets('grant OFF: Juno-final off copy + settings button',
        (tester) async {
      await _openCard(
          tester, _BgHc(HealthConnectStatus.connected, bg: false));
      expect(find.text(_offBody), findsOneWidget);
      expect(find.text(_onBody), findsNothing);
      expect(find.text('Checking background access…'), findsNothing);
      expect(
          find.byKey(const ValueKey('open_hc_settings_background')),
          findsOneWidget);
      expect(find.text('Open Health Connect Settings'), findsOneWidget);
    });

    testWidgets('grant ON: Juno-final on copy, no button',
        (tester) async {
      await _openCard(
          tester, _BgHc(HealthConnectStatus.connected, bg: true));
      expect(find.text(_onBody), findsOneWidget);
      expect(find.text(_offBody), findsNothing);
      expect(find.text('Checking background access…'), findsNothing);
      expect(
          find.byKey(const ValueKey('open_hc_settings_background')),
          findsNothing);
    });

    testWidgets(
        'grant read FAILED: neutral checking state — no off copy, '
        'no on copy, no button, no grant claim', (tester) async {
      await _openCard(
          tester,
          _BgHc(HealthConnectStatus.connected, bgThrows: true));
      expect(find.text('Checking background access…'), findsOneWidget);
      expect(find.text(_offBody), findsNothing);
      expect(find.text(_onBody), findsNothing);
      expect(
          find.byKey(const ValueKey('open_hc_settings_background')),
          findsNothing);
    });
  });
}
