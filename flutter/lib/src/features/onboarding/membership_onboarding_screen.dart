import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/tabs_backend.dart';
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
///   fallback line is "Pricing shown in Google Play" — the Flutter
///   Lab has no Play Billing client (production billing activates
///   when the Flutter app takes over the production package), so the
///   fallback line is what shows, and the trial CTA follows the
///   Round 29 Settings precedent ("Start 7-day free trial").
/// - Subscribing in native launches Play Billing (and, in the
///   onboarding route, navigates to Settings → Membership). In the
///   Lab the subscribe button shows the same honest dialog Round 29's
///   Settings uses and the step stays put — no fake purchase flow.
/// - "Use free account for now" skips to setup loading.
/// - If the account is already unlimited, native auto-advances to
///   setup loading (LaunchedEffect on isUnlimited) — mirrored here.
class MembershipOnboardingScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onSkip;
  final TabsBackend? backend;

  const MembershipOnboardingScreen({
    super.key,
    required this.onBack,
    required this.onSkip,
    this.backend,
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

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _checkUnlimited();
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
              _PlanCard(
                selected: _selectedPlan == 'monthly',
                title: 'Monthly Plan',
                chip: 'FREE TRIAL',
                chipColor: NotelColors.primary,
                onTap: () => setState(() => _selectedPlan = 'monthly'),
              ),
              const SizedBox(height: 12),
              _PlanCard(
                selected: _selectedPlan == 'yearly',
                title: 'Yearly Plan',
                chip: 'BEST VALUE',
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
                        'Start 7-day free trial',
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
