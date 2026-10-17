import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/billing/billing_plans_panel.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native `MembershipOnboardingScreen.kt` (route
/// `membership_onboarding`), the premium step.
///
/// Native behavior:
/// - "Unlock Tabs Premium" + the two premium features, verbatim.
/// - The Juno-signed medical disclaimer, verbatim:
///   "Tabs Premium is for education and personal self tracking only.
///   It does not provide medical advice, diagnosis, or treatment.
///   Talk to a qualified health professional about any health
///   decisions."
/// - Monthly / Yearly plan cards. Native reads prices + trial
///   periods from the live Play catalog; until it loads, native's own
///   fallback line is "Pricing shown in Google Play".
/// - Takeover Phase 2: when the app-owned billing service is
///   supplied (production build — the AND gate in
///   billing_service.dart), the cards + CTA
///   are the shared [BillingPlansPanel] over the real Play catalog —
///   the CTA names a trial only when Play actually returns one. In
///   the Lab the fallback line shows and the CTA claims neither a
///   price nor a trial (the old hardcoded "Start 7-day free trial"
///   label is removed).
/// - Subscribing in native launches Play Billing. In the Lab the
///   subscribe button shows the same honest dialog Round 29's
///   Settings uses and the step stays put — no fake purchase flow.
/// - "Use free account for now" skips to setup loading.
/// - If the account is already unlimited, native auto-advances to
///   setup loading (LaunchedEffect on isUnlimited) — mirrored here.
class MembershipOnboardingScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onSkip;
  final TabsBackend? backend;

  /// Takeover Phase 2 — the app-owned billing service (single
  /// instance, owned by the app flow via BillingAppSync; threaded
  /// through OnboardingFlow). This screen CONSUMES it only: it
  /// never constructs its own service and never disposes this
  /// one. Null in the Lab (and in tests that do not inject one):
  /// the step then keeps its honest cannot-purchase state.
  final BillingService? billingService;

  const MembershipOnboardingScreen({
    super.key,
    required this.onBack,
    required this.onSkip,
    this.backend,
    this.billingService,
  });

  @override
  State<MembershipOnboardingScreen> createState() =>
      _MembershipOnboardingScreenState();
}

class _MembershipOnboardingScreenState
    extends State<MembershipOnboardingScreen> {
  late final TabsBackend _backend;
  String _selectedPlan = 'monthly';
  bool _advanced = false;

  // Takeover Phase 2 — the app-owned billing service, consumed
  // via the widget parameter; null in the Lab. Read through the
  // widget on every use so the instance the app flow finishes
  // creating asynchronously is picked up when it arrives. This
  // screen never constructs or disposes a billing service —
  // disposal belongs to the app flow that owns the instance.
  BillingService? get _billing => widget.billingService;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _checkUnlimited();
  }

  /// Production purchase completed / status sync says unlimited:
  /// native auto-advances to setup loading.
  void _onBillingUnlimited() {
    if (_advanced) return;
    _advanced = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSkip();
    });
  }

  /// Native: LaunchedEffect(isUnlimited) → onSkip() (setup loading).
  Future<void> _checkUnlimited() async {
    try {
      final unlimited = await _backend.fetchIsUnlimited();
      if (!mounted || !unlimited || _advanced) return;
      _advanced = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSkip();
      });
    } catch (_) {}
  }

  void _showPurchaseUnavailable() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text(
          'Google Play',
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: const Text(
          'Subscriptions are purchased through Google Play in the Tabs '
          'app. The Flutter Lab cannot start a subscription yet.',
          style: TextStyle(color: NotelColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              'OK',
              style: TextStyle(color: NotelColors.primary),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OnboardingHeader(onBack: widget.onBack),
              ),
              const SizedBox(height: 16),
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: RadialGradient(
                    colors: [
                      NotelColors.primary.withValues(alpha: 0.6),
                      NotelColors.surface,
                    ],
                  ),
                ),
                child: const Icon(
                  Icons.workspace_premium,
                  color: Colors.white,
                  size: 48,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Unlock Tabs Premium',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: NotelColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Everything you need to understand your body and reach '
                'your goals.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: NotelColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
              const _FeatureRow(
                icon: Icons.auto_awesome,
                title: 'AI Clinical Advocate',
                description:
                    'Get a personalized AI coach that understands your '
                    'health history, goals, and biometric data.',
              ),
              const _FeatureRow(
                icon: Icons.insights,
                title: 'Smart Tiles & Trends',
                description:
                    'Intelligent tiles that analyze your logs and surface '
                    "patterns you didn't know existed.",
              ),
              const SizedBox(height: 32),
              const Text(
                'Tabs Premium is for education and personal self '
                'tracking only. It does not provide medical advice, '
                'diagnosis, or treatment. Talk to a qualified health '
                'professional about any health decisions.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 16),
              if (_billing != null) ...[
                // Takeover Phase 2 — production build: the real
                // Play flow (live catalog, user-picked offer,
                // server-verified purchase).
                BillingPlansPanel(
                  service: _billing!,
                  onUnlimited: _onBillingUnlimited,
                ),
              ] else ...[
                // Lab build — honest state: no price and NO trial
                // is claimed without a live catalog (the hardcoded
                // "Start 7-day free trial" label is removed).
                _PlanCard(
                  selected: _selectedPlan == 'monthly',
                  title: 'Monthly Plan',
                  chip: '',
                  chipColor: NotelColors.primary,
                  onTap: () => setState(() => _selectedPlan = 'monthly'),
                ),
                const SizedBox(height: 12),
                _PlanCard(
                  selected: _selectedPlan == 'yearly',
                  title: 'Yearly Plan',
                  // Takeover review fix (Juno): no "BEST VALUE" chip
                  // in the Lab — no catalog price data exists here to
                  // compute savings from, so it would be unbacked.
                  chip: '',
                  chipColor: NotelColors.success,
                  onTap: () => setState(() => _selectedPlan = 'yearly'),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    onPressed: _showPurchaseUnavailable,
                    style: FilledButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.workspace_premium,
                            color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Subscribe with Google Play',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Auto-renews until canceled. Billed by Google Play.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xBF7A8FAF),
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextButton(
                onPressed: widget.onSkip,
                child: const Text(
                  'Use free account for now',
                  style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: NotelColors.primary.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: NotelColors.primary.withValues(alpha: 0.15),
              ),
              child: Icon(icon, color: NotelColors.primary, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    description,
                    style: const TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 12,
                      height: 16 / 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final bool selected;
  final String title;
  final String chip;
  final Color chipColor;
  final VoidCallback onTap;

  const _PlanCard({
    required this.selected,
    required this.title,
    required this.chip,
    required this.chipColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? NotelColors.primary.withValues(alpha: 0.08)
              : NotelColors.surfaceHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? NotelColors.primary
                : NotelColors.primary.withValues(alpha: 0.15),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: selected
                  ? NotelColors.primary
                  : NotelColors.textSecondary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Native's own no-catalog fallback line (see the
                  // class doc) — the Lab has no Play catalog.
                  const Text(
                    'Pricing shown in Google Play',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            // Empty chip renders nothing (Takeover Phase 2: no
            // unverified FREE TRIAL claim in the Lab).
            if (chip.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  chip,
                  style: TextStyle(
                    color: chipColor,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
