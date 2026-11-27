import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/revenuecat_service.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// The iOS plan-picker for Settings → Membership and the
/// onboarding paywall — the RevenueCat counterpart of
/// `BillingPlansPanel`, rendered ONLY on iOS (Android renders the
/// Play panel / Lab fallback exactly as before).
///
/// Everything price/trial-shaped comes from the RevenueCat
/// offering ([RevenueCatState.packages], loaded by
/// [RevenueCatService]): prices and trial labels are read off the
/// actual store products RevenueCat returned. There is NO hardcoded
/// price and NO hardcoded trial anywhere in this widget — when the
/// catalog has not loaded, the panel falls back to the honest line
/// "Pricing shown in the App Store" and a plain CTA.
///
/// Restore Purchases lives here (App Store review requirement):
/// a visible action under the CTA on every iOS membership surface
/// that renders this panel, wired to [RevenueCatService.restore].
/// Its outcomes are the service's: active entitlement → the gate
/// opens via [onUnlimited]; nothing found → the service's truthful
/// notice line; failure → the service's error line.
class RevenueCatPlansPanel extends StatefulWidget {
  final RevenueCatService service;

  /// Fired once when the service reports premium is active
  /// (onboarding auto-advances; Settings reloads its data) — the
  /// `BillingPlansPanel.onUnlimited` contract.
  final VoidCallback? onUnlimited;

  /// Key for the subscribe CTA (tests address it, mirroring the
  /// Play panel's `ctaKey`).
  final Key? ctaKey;

  const RevenueCatPlansPanel({
    super.key,
    required this.service,
    this.onUnlimited,
    this.ctaKey,
  });

  @override
  State<RevenueCatPlansPanel> createState() => _RevenueCatPlansPanelState();
}

class _RevenueCatPlansPanelState extends State<RevenueCatPlansPanel> {
  StreamSubscription<RevenueCatState>? _sub;
  String? _selectedPackageId;
  bool _unlimitedFired = false;

  RevenueCatService get _service => widget.service;
  RevenueCatState get _state => _service.state;

  @override
  void initState() {
    super.initState();
    _sub = _service.states.listen((_) {
      if (!mounted) return;
      setState(() {});
      _maybeFireUnlimited();
    });
    if (_state.phase == RevenueCatPhase.idle) {
      unawaited(_service.initialize());
    }
    _maybeFireUnlimited();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _maybeFireUnlimited() {
    if (_state.isPremium == true && !_unlimitedFired) {
      _unlimitedFired = true;
      widget.onUnlimited?.call();
    }
  }

  /// The user's pick: their explicit selection when it still
  /// exists, else the monthly package (the Play panel's default),
  /// else the first package.
  RevenueCatPackage? get _selectedPackage {
    final packages = _state.packages;
    if (packages.isEmpty) return null;
    for (final p in packages) {
      if (p.identifier == _selectedPackageId) return p;
    }
    for (final p in packages) {
      if (!p.isYearly) return p;
    }
    return packages.first;
  }

  bool get _busy =>
      _state.phase == RevenueCatPhase.loadingOfferings ||
      _state.phase == RevenueCatPhase.purchasing ||
      _state.phase == RevenueCatPhase.restoring;

  String get _ctaLabel {
    final phase = _state.phase;
    if (phase == RevenueCatPhase.loadingOfferings) return 'Loading plans…';
    if (phase == RevenueCatPhase.purchasing) {
      // TODO_JUNO: in-flight purchase label (App Store wording).
      return 'Waiting for the App Store…';
    }
    if (phase == RevenueCatPhase.restoring) return 'Restoring…';
    final package = _selectedPackage;
    if (package == null) return 'Plans unavailable';
    final trial = package.trialLabel;
    if (trial != null) return 'Start $trial';
    final price = package.priceString;
    if (price != null) {
      return 'Subscribe — $price/${package.isYearly ? 'year' : 'month'}';
    }
    return 'Subscribe';
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;

    // Not configured in this build: the honest unavailable state.
    // No plan cards, no CTA, no restore — nothing that could read
    // as a paywall (the fail-closed rule in revenuecat_service.dart).
    if (state.phase == RevenueCatPhase.unavailableNotConfigured) {
      return Text(
        // TODO_JUNO: unconfigured-build copy — mirrors the Lab's
        // Play wording with the store name corrected for iOS.
        'Subscriptions are purchased through the App Store in the '
        'Tabs app. This build cannot start a subscription yet.',
        key: ValueKey('revenuecat_unavailable'),
        textAlign: TextAlign.center,
        style: TextStyle(color: NotelColors.textSecondary, fontSize: 13),
      );
    }

    final selected = _selectedPackage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final package in state.packages) ...[
          _planCard(package, selected: package == selected),
          const SizedBox(height: 12),
        ],
        if (state.packages.isEmpty &&
            state.phase != RevenueCatPhase.loadingOfferings)
          Text(
            'Pricing shown in the App Store',
            textAlign: TextAlign.center,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 13),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton(
            key: widget.ctaKey,
            onPressed: (!_busy && selected != null)
                ? () => unawaited(_service.buy(selected))
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: NotelColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_busy) ...[
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                ] else ...[
                  const Icon(Icons.workspace_premium,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    _ctaLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Cancellation method adjacent to the CTA — the Play
        // panel's F-4 rule, with the store name corrected for iOS.
        // TODO_JUNO: confirm this line in the Juno pass (the Play
        // wording is register-verified; this is its iOS twin).
        const Text(
          'Cancel anytime in the App Store',
          key: ValueKey('rc_paywall_cancel_method'),
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xBF7A8FAF), fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          _termsLine(selected),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xBF7A8FAF), fontSize: 11),
        ),
        const SizedBox(height: 8),
        // Restore Purchases — always visible on this surface,
        // including when the catalog failed to load (a restoring
        // user is exactly who must not need the catalog first).
        Center(
          child: TextButton(
            key: const ValueKey('restore_purchases'),
            onPressed: _busy ? null : () => unawaited(_service.restore()),
            child: const Text(
              'Restore Purchases',
              style: TextStyle(
                color: NotelColors.primary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        if (state.noticeMessage != null) ...[
          const SizedBox(height: 6),
          Text(
            state.noticeMessage!,
            key: const ValueKey('revenuecat_notice'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: NotelColors.textSecondary, fontSize: 12),
          ),
        ],
        if (state.errorMessage != null) ...[
          const SizedBox(height: 6),
          Text(
            state.errorMessage!,
            key: const ValueKey('revenuecat_error'),
            textAlign: TextAlign.center,
            style: TextStyle(color: NotelColors.error, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// Terms from the SELECTED package's real store data; the bare
  /// honest line when no package data is available.
  String _termsLine(RevenueCatPackage? package) {
    final summary = package?.summaryLabel;
    if (summary == null) {
      return 'Auto-renews until canceled. Billed by the App Store.';
    }
    return '${package!.planName}: $summary. Auto-renews until '
        'canceled. Billed by the App Store.';
  }

  Widget _planCard(RevenueCatPackage package, {required bool selected}) {
    final priceLine = package.summaryLabel ?? 'Pricing shown in the App Store';
    return GestureDetector(
      onTap: () => setState(() => _selectedPackageId = package.identifier),
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
              color:
                  selected ? NotelColors.primary : NotelColors.textSecondary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${package.planName} Plan',
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    priceLine,
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (package.trialLabel != null && !package.isYearly)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: NotelColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'FREE TRIAL',
                  style: TextStyle(
                    color: NotelColors.primary,
                    fontSize: 10,
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
