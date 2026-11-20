import 'package:flutter/material.dart';

import 'package:tabs_lab/src/theme/notel_colors.dart';

/// The billing gate states the membership surfaces resolve before
/// rendering.
enum BillingGateState {
  /// Signed in but email not yet verified. EVERY fresh Register
  /// signup lands here until verification completes.
  needsVerification,

  /// Signed in with an active subscription.
  activeSubscriber,

  /// No signed-in account.
  signedOut,

  /// Signed in, verified, no active subscription — can purchase.
  purchasable,
}

/// Branch selection for the membership billing area.
///
/// BRANCH ORDER IS LOAD-BEARING: [BillingGateState
/// .needsVerification] is checked FIRST, before the
/// active-subscriber branch. Inverting this would show a
/// signed-in email-unverified user (every fresh Register
/// signup) the active-subscriber panel ("You're Premium" +
/// Manage Subscription), and they could never reach the
/// purchase panel or start the trial from onboarding. The
/// branch-pinning tests in `onboarding_flow3_test.dart` reach
/// this real selection for every state; do not reorder.
class BillingPanel extends StatelessWidget {
  final BillingGateState state;

  /// The purchase UI (plan cards + CTA) for the purchasable
  /// branch — supplied by the caller (the shared
  /// BillingPlansPanel in production, the priced fallback cards
  /// in the Lab).
  final Widget purchasableChild;

  final VoidCallback? onVerifyEmail;
  final VoidCallback? onManageSubscription;
  final VoidCallback? onSignIn;

  const BillingPanel({
    super.key,
    required this.state,
    required this.purchasableChild,
    this.onVerifyEmail,
    this.onManageSubscription,
    this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    // needsVerification FIRST — before activeSubscriber.
    if (state == BillingGateState.needsVerification) {
      return VerifyEmailGate(onVerifyEmail: onVerifyEmail);
    }
    if (state == BillingGateState.activeSubscriber) {
      return _ActiveSubscriberPanel(onManage: onManageSubscription);
    }
    if (state == BillingGateState.signedOut) {
      return _SignedOutPanel(onSignIn: onSignIn);
    }
    return purchasableChild;
  }
}

/// Shown to a signed-in user whose email is not yet verified:
/// purchasing stays behind verification, exactly as the parent
/// branch order required.
class VerifyEmailGate extends StatelessWidget {
  final VoidCallback? onVerifyEmail;

  const VerifyEmailGate({super.key, this.onVerifyEmail});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('verify_email_gate'),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        children: [
          const Icon(Icons.mark_email_unread,
              color: NotelColors.primary, size: 32),
          const SizedBox(height: 12),
          const Text(
            'Verify your email to continue',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'We sent a verification code to your email. Verify it '
            'to unlock purchasing and start your trial.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: NotelColors.textSecondary,
              height: 18 / 13,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: onVerifyEmail,
              style: FilledButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: const Text(
                'Verify Email',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveSubscriberPanel extends StatelessWidget {
  final VoidCallback? onManage;

  const _ActiveSubscriberPanel({this.onManage});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('active_subscriber_panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        children: [
          const Text(
            "You're Premium",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onManage,
            child: const Text(
              'Manage Subscription',
              style: TextStyle(
                color: NotelColors.primary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SignedOutPanel extends StatelessWidget {
  final VoidCallback? onSignIn;

  const _SignedOutPanel({this.onSignIn});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('signed_out_panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        children: [
          const Text(
            'Sign in to see plans',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onSignIn,
            child: const Text(
              'Sign In',
              style: TextStyle(
                color: NotelColors.primary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
