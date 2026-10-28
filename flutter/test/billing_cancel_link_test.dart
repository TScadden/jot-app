import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/billing_models.dart';

/// Conformance audit 2026-10-27, item 1c — the Settings
/// manage/cancel deep link into Play's Subscription Center.
///
/// Google Play Billing documents the specific-subscription form as
/// `https://play.google.com/store/account/subscriptions?sku=<productId>&package=<app package>`
/// (developer.android.com/google/play/billing/subscriptions,
/// "Link to a specific subscription management page"), where the
/// `sku` value is the purchased subscription's `productId`.
///
/// Play's catalog for Tabs is ONE subscription product,
/// `jot_membership_monthly`, with two base plans
/// (`premium-monthly`, `premium-yearly`). The old Settings link
/// sent `sku=jot_membership_yearly` whenever the yearly plan was
/// selected — that is not a product ID in the catalog, so the
/// parameter may not resolve. These tests pin the corrected link.
void main() {
  group('BillingProducts.subscriptionManagementUrl (audit 1c)', () {
    test('is the exact documented Play Subscription Center URL', () {
      expect(
        BillingProducts.subscriptionManagementUrl,
        'https://play.google.com/store/account/subscriptions'
        '?sku=jot_membership_monthly&package=com.notel.notel',
      );
    });

    test('parsed components: host, path, sku and package', () {
      final uri = Uri.parse(BillingProducts.subscriptionManagementUrl);
      expect(uri.scheme, 'https');
      expect(uri.host, 'play.google.com');
      expect(uri.path, '/store/account/subscriptions');
      expect(uri.queryParameters, {
        'sku': 'jot_membership_monthly',
        'package': 'com.notel.notel',
      });
    });

    test('sku is the single real product ID, never the yearly name', () {
      final uri = Uri.parse(BillingProducts.subscriptionManagementUrl);
      expect(uri.queryParameters['sku'], BillingProducts.monthly);
      expect(uri.queryParameters['sku'], isNot('jot_membership_yearly'));
      expect(
        BillingProducts.subscriptionManagementUrl,
        isNot(contains('jot_membership_yearly')),
      );
    });

    test('package is the production package', () {
      final uri = Uri.parse(BillingProducts.subscriptionManagementUrl);
      expect(uri.queryParameters['package'], BillingProducts.productionPackage);
      expect(uri.queryParameters['package'], 'com.notel.notel');
    });
  });
}
