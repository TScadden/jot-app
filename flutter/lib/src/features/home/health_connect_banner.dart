import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 23 — the slim Health Connect banner under the vitals strip.
///
/// Problem: every Health Connect failure mode used to collapse into the
/// same silent "--" vitals — not connected, partial permission grant,
/// bridge error, and connected-but-no-data-yet all looked identical.
/// The founder hit this when his Fitbit was dead: the app gave no hint
/// whether the connection or the data was the problem.
///
/// Fix (this file + the status plumbing in `home_screen.dart`):
/// - Home tracks the live [HealthConnectStatus] enum, not just a bool.
/// - Status ≠ connected AND biometrics empty → this banner shows, so
///   the empty "--" cells are explained and tappable through to the
///   Connections screen.
/// - Connected but data simply empty → NO banner: the plain honest
///   "--" stands on its own (nothing is wrong with the connection).
/// - Partial grant → its own honest wording: some permissions are
///   missing, so "needs permissions", never "isn't connected".
///   (Native check, Oct 2026: the native Home has no banner and its
///   Connections screen only carries the "Partially connected" row
///   label + the manage sheet's "require additional permissions"
///   copy — there is no native Home banner copy to mirror, so the
///   wording below follows the diagnostic's spec.)
///
/// No spinner and no animation here: the banner appears/disappears
/// quietly inside Home's stale-while-revalidate flow.

/// Exact banner copy for [status], or null when no banner may show
/// (connected, or status not known yet).
String? healthConnectBannerText(HealthConnectStatus? status) {
  return switch (status) {
    HealthConnectStatus.partiallyConnected =>
      'Health Connect needs permissions — tap to fix',
    HealthConnectStatus.notConnected ||
    HealthConnectStatus.unavailable =>
      "Health Connect isn't connected — tap to reconnect",
    HealthConnectStatus.connected || null => null,
  };
}

/// True when the vitals carry NO biometric reading. The log count is
/// deliberately excluded: it comes from the Tabs backend, not Health
/// Connect, so a day with logs but no HC data still counts as empty
/// here — and a day with any real biometric never shows the banner,
/// even when the connection has since dropped (cached values render
/// first and stand on their own).
bool healthBiometricsEmpty(TodayVitals? vitals) {
  if (vitals == null) return true;
  return vitals.heartRate == null &&
      vitals.activeCalories == null &&
      vitals.sleepMinutes == null;
}

/// The full banner gate: a known not-fully-connected status AND empty
/// biometrics. Connected-but-empty and not-connected-but-cached-data
/// both return false.
bool shouldShowHealthConnectBanner({
  required HealthConnectStatus? status,
  required TodayVitals? vitals,
}) {
  return healthConnectBannerText(status) != null &&
      healthBiometricsEmpty(vitals);
}

/// Slim tappable banner. The whole row is the tap target; [onTap]
/// deep-links to the Connections screen (the same destination/flow as
/// the header watch icon).
///
/// When the status check itself failed at the bridge, [errorCode]
/// carries the Health Connect exception code and renders as a small
/// `[CODE]` suffix — the visible-handling rule from LESSONS.md (a
/// screenshot must be able to diagnose a channel failure).
class HealthConnectBanner extends StatelessWidget {
  final HealthConnectStatus status;
  final String? errorCode;
  final VoidCallback onTap;

  const HealthConnectBanner({
    super.key,
    required this.status,
    required this.onTap,
    this.errorCode,
  });

  @override
  Widget build(BuildContext context) {
    final text = healthConnectBannerText(status) ??
        "Health Connect isn't connected — tap to reconnect";
    final isPartial = status == HealthConnectStatus.partiallyConnected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
      child: Container(
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (isPartial ? NotelColors.warning : NotelColors.primary)
                .withValues(alpha: 0.45),
            width: 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
              child: Row(
                children: [
                  Icon(
                    isPartial ? Icons.lock_outline : Icons.link_off,
                    size: 16,
                    color: isPartial
                        ? NotelColors.warning
                        : NotelColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: NotelColors.textPrimary,
                      ),
                    ),
                  ),
                  if (errorCode != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '[$errorCode]',
                      style: const TextStyle(
                        fontSize: 10,
                        color: NotelColors.error,
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: NotelColors.textSecondary.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
