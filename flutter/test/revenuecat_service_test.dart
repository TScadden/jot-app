import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/revenuecat_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/billing/revenuecat_plans_panel.dart';
import 'package:tabs_lab/src/features/onboarding/membership_onboarding_screen.dart';

import 'test_helpers.dart';

/// RevenueCat (iOS) — service sequencing, entitlement mapping,
/// identity, restore, fail-closed config, and platform branching.
///
/// The fake store records ONE ordered event log, so the tests
/// assert the call sequence itself (configure → logIn → offerings /
/// customer-info; purchase → adopt; restore → adopt), not just end
/// states — the billing_takeover_test.dart pattern.
class FakeRevenueCatStore implements RevenueCatStore {
  final List<String> log;
  FakeRevenueCatStore(this.log);

  RevenueCatCustomerInfo currentInfo = RevenueCatCustomerInfo.inactive;
  List<RevenueCatPackage> packages = const [];
  Object? purchaseError;
  Object? offeringsError;
  Completer<void>? purchaseGate;

  final StreamController<RevenueCatCustomerInfo> updates =
      StreamController<RevenueCatCustomerInfo>.broadcast();

  @override
  Future<void> configure({required String apiKey, String? appUserId}) async {
    log.add('store.configure:$apiKey:${appUserId ?? 'anon'}');
  }

  @override
  Future<RevenueCatCustomerInfo> logIn(String appUserId) async {
    log.add('store.logIn:$appUserId');
    return currentInfo;
  }

  @override
  Future<RevenueCatCustomerInfo> logOut() async {
    log.add('store.logOut');
    currentInfo = RevenueCatCustomerInfo.inactive;
    return currentInfo;
  }

  @override
  Future<RevenueCatCustomerInfo> getCustomerInfo() async {
    log.add('store.getCustomerInfo');
    return currentInfo;
  }

  @override
  Future<List<RevenueCatPackage>> getOfferingPackages() async {
    log.add('store.getOfferingPackages');
    if (offeringsError != null) throw offeringsError!;
    return packages;
  }

  @override
  Future<RevenueCatCustomerInfo> purchasePackage(
      String packageIdentifier) async {
    log.add('store.purchase:$packageIdentifier');
    if (purchaseGate != null) await purchaseGate!.future;
    if (purchaseError != null) throw purchaseError!;
    currentInfo = const RevenueCatCustomerInfo(premiumActive: true);
    return currentInfo;
  }

  @override
  Future<RevenueCatCustomerInfo> restorePurchases() async {
    log.add('store.restore');
    return currentInfo;
  }

  @override
  Stream<RevenueCatCustomerInfo> get customerInfoUpdates => updates.stream;

  void emit(RevenueCatCustomerInfo info) {
    currentInfo = info;
    updates.add(info);
  }
}

class FakeRevenueCatCache implements RevenueCatCache {
  bool? stored;
  final List<bool> writes = [];

  @override
  Future<bool?> readPremium() async => stored;

  @override
  Future<void> writePremium(bool value) async {
    stored = value;
    writes.add(value);
  }

  @override
  Future<void> clearPremium() async {
    stored = null;
  }
}

/// Minimal TabsBackend for the membership onboarding screen
/// (its only backend read is fetchIsUnlimited) — mirrors
/// FakeMembershipBackend in billing_takeover_test.dart.
class FakeMembershipBackend extends TabsBackend {
  FakeMembershipBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<bool> fetchIsUnlimited() async => false;
}

const monthlyPackage = RevenueCatPackage(
  identifier: '\$rc_monthly',
  isYearly: false,
  priceString: '\$5.99',
  trialLabel: '7-day free trial',
);
const yearlyPackage = RevenueCatPackage(
  identifier: '\$rc_annual',
  isYearly: true,
  priceString: '\$39.99',
  trialLabel: '7-day free trial',
);

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('RevenueCatService', () {
    late List<String> log;
    late FakeRevenueCatStore store;
    late FakeRevenueCatCache cache;
    late RevenueCatService service;

    setUp(() {
      log = <String>[];
      store = FakeRevenueCatStore(log);
      cache = FakeRevenueCatCache();
      service = RevenueCatService(
        store: store,
        cache: cache,
        apiKeyOverride: 'appl_test_key',
      );
    });

    tearDown(() async {
      await service.dispose();
      await store.updates.close();
    });

    test('not configured: empty key → SDK never touched, honest phase',
        () async {
      final unconfigured = RevenueCatService(
        store: store,
        cache: cache,
        apiKeyOverride: '',
      );
      addTearDown(unconfigured.dispose);

      await unconfigured.initialize(accountUserId: 'user-1');
      expect(unconfigured.state.phase,
          RevenueCatPhase.unavailableNotConfigured);
      await unconfigured.buy(monthlyPackage);
      await unconfigured.restore();
      expect(unconfigured.state.phase,
          RevenueCatPhase.unavailableNotConfigured);
      // The store was NEVER called: no configure, no catalog, no
      // purchase, no restore — fail closed means fail silent-to-the-
      // SDK, with the UI carrying the honest unavailable state.
      expect(log, isEmpty);
    });

    test('entitlement mapping: active RC entitlement → gate opens',
        () async {
      store.currentInfo = const RevenueCatCustomerInfo(premiumActive: true);
      store.packages = const [monthlyPackage, yearlyPackage];

      await service.initialize(accountUserId: 'user-1');

      expect(service.state.phase, RevenueCatPhase.ready);
      expect(service.state.isPremium, isTrue);
      expect(cache.writes, contains(true));
      // Configure carried the account ID from the start.
      expect(log.first, 'store.configure:appl_test_key:user-1');
    });

    test('entitlement mapping: inactive/expired → gate stays closed',
        () async {
      store.currentInfo = RevenueCatCustomerInfo.inactive;
      store.packages = const [monthlyPackage];

      await service.initialize(accountUserId: 'user-1');

      expect(service.state.isPremium, isFalse);
      expect(cache.writes, contains(false));
    });

    test('listener update flips the gate without restart', () async {
      store.packages = const [monthlyPackage];
      await service.initialize(accountUserId: 'user-1');
      expect(service.state.isPremium, isFalse);

      store.emit(const RevenueCatCustomerInfo(premiumActive: true));
      await settle();
      expect(service.state.isPremium, isTrue);

      // Expiry arrives the same way (renewal failure / lapse).
      store.emit(RevenueCatCustomerInfo.inactive);
      await settle();
      expect(service.state.isPremium, isFalse);
    });

    test('identity: logIn is called with the server account ID on bind',
        () async {
      store.packages = const [monthlyPackage];
      await service.initialize();
      expect(log.first, 'store.configure:appl_test_key:anon');

      await service.bindAccount('server-user-42');
      expect(log, contains('store.logIn:server-user-42'));

      // Sign-out returns to anonymous and clears the cached verdict.
      cache.stored = true;
      await service.bindAccount(null);
      expect(log, contains('store.logOut'));
      expect(cache.stored, isNull);
    });

    test('last-known cache seeds the gate at initialize, then revalidates',
        () async {
      cache.stored = true;
      store.currentInfo = RevenueCatCustomerInfo.inactive;
      store.packages = const [monthlyPackage];

      await service.initialize(accountUserId: 'user-1');

      // The fresh validated read wins over the stale cache.
      expect(service.state.isPremium, isFalse);
      expect(cache.stored, isFalse);
    });

    test('purchase success refreshes the gate immediately', () async {
      store.packages = const [monthlyPackage, yearlyPackage];
      await service.initialize(accountUserId: 'user-1');
      expect(service.state.isPremium, isFalse);

      await service.buy(monthlyPackage);

      expect(log, contains('store.purchase:\$rc_monthly'));
      expect(service.state.isPremium, isTrue);
      expect(service.state.phase, RevenueCatPhase.ready);
      expect(service.state.errorMessage, isNull);
    });

    test('purchase cancellation is silent (no error, gate unchanged)',
        () async {
      store.packages = const [monthlyPackage];
      store.purchaseError = const RevenueCatPurchaseCancelled();
      await service.initialize(accountUserId: 'user-1');

      await service.buy(monthlyPackage);

      expect(service.state.phase, RevenueCatPhase.ready);
      expect(service.state.errorMessage, isNull);
      expect(service.state.isPremium, isFalse);
    });

    test('purchase failure surfaces the error state', () async {
      store.packages = const [monthlyPackage];
      store.purchaseError =
          const RevenueCatFailure(TODO_JUNO_RC_PURCHASE_FAILED);
      await service.initialize(accountUserId: 'user-1');

      await service.buy(monthlyPackage);

      expect(service.state.phase, RevenueCatPhase.error);
      expect(service.state.errorMessage, TODO_JUNO_RC_PURCHASE_FAILED);
      expect(service.state.isPremium, isFalse);
    });

    test('buy refuses a package that is not in the loaded offering',
        () async {
      store.packages = const [monthlyPackage];
      await service.initialize(accountUserId: 'user-1');
      log.clear();

      await service.buy(yearlyPackage);

      expect(log.where((e) => e.startsWith('store.purchase')), isEmpty);
      expect(service.state.phase, RevenueCatPhase.error);
    });

    test('empty offerings → visible catalog error, never a fake paywall',
        () async {
      store.packages = const [];
      await service.initialize(accountUserId: 'user-1');

      expect(service.state.phase, RevenueCatPhase.error);
      expect(service.state.errorMessage, TODO_JUNO_RC_CATALOG_FAILED);
    });

    test('restore with an active entitlement → gate opens', () async {
      store.packages = const [monthlyPackage];
      await service.initialize(accountUserId: 'user-1');
      expect(service.state.isPremium, isFalse);

      store.currentInfo = const RevenueCatCustomerInfo(premiumActive: true);
      await service.restore();

      expect(log, contains('store.restore'));
      expect(service.state.isPremium, isTrue);
      expect(service.state.noticeMessage, isNull);
      expect(service.state.errorMessage, isNull);
    });

    test(
        'restore with nothing → gate stays closed + truthful notice, '
        'no fake success', () async {
      store.packages = const [monthlyPackage];
      await service.initialize(accountUserId: 'user-1');

      await service.restore();

      expect(service.state.isPremium, isFalse);
      expect(service.state.phase, RevenueCatPhase.ready);
      expect(service.state.noticeMessage, TODO_JUNO_RC_RESTORE_NOTHING_FOUND);
      expect(service.state.errorMessage, isNull);
    });
  });

  group('Juno D10 identity rules (source scan)', () {
    // The seam exposes no attributes API at all; this scan pins
    // that the implementation files never reach around it — the
    // crash_reporting_test.dart source-scan precedent.
    test('no attributes / attribution / IDFA API is referenced', () {
      for (final path in const [
        'lib/src/data/revenuecat_service.dart',
        'lib/src/data/revenuecat_purchases_store.dart',
        'lib/src/features/billing/revenuecat_plans_panel.dart',
      ]) {
        final source = File(path).readAsStringSync();
        for (final forbidden in const [
          'setAttributes',
          'setEmail',
          'setPhoneNumber',
          'setDisplayName',
          'setPushToken',
          'collectDeviceIdentifiers',
          'setProxyURL',
          'Attribution',
          'IDFA',
          'advertisingIdentifier',
        ]) {
          expect(source.contains(forbidden), isFalse,
              reason: '$path must not reference $forbidden');
        }
      }
    });

    test('the only identity string configured is the entitlement id', () {
      expect(RevenueCatConfig.premiumEntitlementId, 'premium');
    });
  });

  group('RevenueCatPlansPanel', () {
    Future<RevenueCatService> pumpPanel(
      WidgetTester tester, {
      required RevenueCatService service,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: RevenueCatPlansPanel(service: service)),
      ));
      await tester.pump();
      await tester.pump();
      return service;
    }

    RevenueCatService configuredService(FakeRevenueCatStore store) {
      final service = RevenueCatService(
        store: store,
        cache: FakeRevenueCatCache(),
        apiKeyOverride: 'appl_test_key',
      );
      addTearDown(service.dispose);
      return service;
    }

    testWidgets('plans render from the offering; restore is visible',
        (tester) async {
      final log = <String>[];
      final store = FakeRevenueCatStore(log)
        ..packages = const [monthlyPackage, yearlyPackage];
      final service = configuredService(store);
      await service.initialize(accountUserId: 'user-1');
      await pumpPanel(tester, service: service);

      expect(find.text('Monthly Plan'), findsOneWidget);
      expect(find.text('Yearly Plan'), findsOneWidget);
      expect(find.text('7-day free trial, then \$5.99/month'), findsWidgets);
      expect(find.text('Start 7-day free trial'), findsOneWidget);
      // App Store rejection-checklist item: restore, visible.
      expect(find.byKey(const ValueKey('restore_purchases')),
          findsOneWidget);
      expect(find.text('Restore Purchases'), findsOneWidget);
      // iOS cancellation wording — never the Play Store's.
      expect(find.text('Cancel anytime in the App Store'), findsOneWidget);
      expect(find.textContaining('Google Play'), findsNothing);
    });

    testWidgets('restore tap with nothing found shows the truthful notice',
        (tester) async {
      final log = <String>[];
      final store = FakeRevenueCatStore(log)
        ..packages = const [monthlyPackage];
      final service = configuredService(store);
      await service.initialize(accountUserId: 'user-1');
      await pumpPanel(tester, service: service);

      await tester.tap(find.byKey(const ValueKey('restore_purchases')));
      await tester.pump();
      await tester.pump();

      expect(log, contains('store.restore'));
      expect(find.byKey(const ValueKey('revenuecat_notice')),
          findsOneWidget);
      expect(find.text(TODO_JUNO_RC_RESTORE_NOTHING_FOUND), findsOneWidget);
      expect(service.state.isPremium, isFalse);
    });

    testWidgets('not configured → honest unavailable, no paywall, no restore',
        (tester) async {
      final log = <String>[];
      final store = FakeRevenueCatStore(log);
      final service = RevenueCatService(
        store: store,
        cache: FakeRevenueCatCache(),
        apiKeyOverride: '',
      );
      addTearDown(service.dispose);
      await service.initialize();
      await pumpPanel(tester, service: service);

      expect(find.byKey(const ValueKey('revenuecat_unavailable')),
          findsOneWidget);
      expect(find.text('Monthly Plan'), findsNothing);
      expect(find.byKey(const ValueKey('restore_purchases')), findsNothing);
      expect(log, isEmpty);
    });
  });

  group('Platform branching — membership onboarding', () {
    // The Harbor HIGH finding: the Google Play dialog must never
    // appear on iOS; on Android it stays exactly as today (the
    // pre-existing membership tests pin the Android side and must
    // pass unmodified — these tests add the iOS side).
    //
    // Apply-time fix (the apple_sign_in_test.dart pattern): the
    // platform override is reset in a finally INSIDE the test
    // body — the test binding verifies foundation debug vars are
    // unset before tearDown callbacks run, so a tearDown reset
    // is too late.
    void iosTestWidgets(
        String name, Future<void> Function(WidgetTester tester) body) {
      testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    iosTestWidgets('iOS: purchase entry reaches the RC panel; no Play dialog',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final log = <String>[];
      final store = FakeRevenueCatStore(log)
        ..packages = const [monthlyPackage, yearlyPackage];
      final rc = RevenueCatService(
        store: store,
        cache: FakeRevenueCatCache(),
        apiKeyOverride: 'appl_test_key',
      );
      addTearDown(rc.dispose);
      await rc.initialize(accountUserId: 'user-1');

      await tester.pumpWidget(MaterialApp(
        home: MembershipOnboardingScreen(
          onBack: () {},
          onSkip: () {},
          backend: FakeMembershipBackend(),
          revenueCatService: rc,
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(RevenueCatPlansPanel), findsOneWidget);
      expect(find.text('Restore Purchases'), findsOneWidget);
      expect(find.textContaining('Google Play'), findsNothing);
      expect(
          find.text('Subscriptions are purchased through Google Play '
              'in the Tabs app. The Flutter Lab cannot start a '
              'subscription yet.'),
          findsNothing);
    });

    iosTestWidgets('iOS unconfigured: no Play dialog, honest App Store state',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final log = <String>[];
      final store = FakeRevenueCatStore(log);
      final rc = RevenueCatService(
        store: store,
        cache: FakeRevenueCatCache(),
        apiKeyOverride: '',
      );
      addTearDown(rc.dispose);
      await rc.initialize();

      await tester.pumpWidget(MaterialApp(
        home: MembershipOnboardingScreen(
          onBack: () {},
          onSkip: () {},
          backend: FakeMembershipBackend(),
          revenueCatService: rc,
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('revenuecat_unavailable')),
          findsOneWidget);
      expect(find.textContaining('Google Play'), findsNothing);
    });

    iosTestWidgets(
        'iOS no RC service: fallback cards carry no price/trial/'
        'savings claims; CTA is the App Store label for both plans',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: MembershipOnboardingScreen(
          onBack: () {},
          onSkip: () {},
          backend: FakeMembershipBackend(),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Monthly Plan'), findsOneWidget);
      expect(find.text('Yearly Plan'), findsOneWidget);
      expect(find.text('Pricing shown in the App Store'), findsNWidgets(2));
      expect(
          find.text('Auto-renews until canceled. Billed by the App Store.'),
          findsOneWidget);
      expect(find.text(r'$5.99 / month'), findsNothing);
      expect(find.text(r'$39.99 / year'), findsNothing);
      expect(find.text('7-DAY FREE TRIAL'), findsNothing);
      expect(find.text('SAVE 44% · BEST VALUE'), findsNothing);
      expect(find.textContaining('Google Play'), findsNothing);
      // Monthly selected by default: no trial claim on the CTA.
      expect(find.text('Subscribe with the App Store'), findsOneWidget);
      expect(find.text('Start 7-Day Free Trial'), findsNothing);
      // Yearly selection keeps the same App Store CTA.
      await tester.ensureVisible(find.text('Yearly Plan'));
      await tester.pump();
      await tester.tap(find.text('Yearly Plan'));
      await tester.pump();
      expect(find.text('Subscribe with the App Store'), findsOneWidget);
      expect(find.text('Start 7-Day Free Trial'), findsNothing);
    });
  });
}
