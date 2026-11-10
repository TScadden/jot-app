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

/// Banner title for [status], or null when no banner may show
/// (connected, or status not known yet).
///
/// HC connection-honesty package (Juno ruling): the stale-grant
/// state gets its own plain-language title/body (items 1–2); the
/// ordinary not-connected / unavailable title/body are the shipped
/// single string split at its em dash (item 7); the
/// partially-connected copy is unchanged (condition 3). Diagnostic
/// exception codes NEVER render here in any state (condition 1) —
/// they belong in logs, never in user-visible UI.
String? healthConnectBannerTitle(
  HealthConnectStatus? status, {
  bool staleGrant = false,
}) {
  if (staleGrant) return 'Health Connect got disconnected';
  return switch (status) {
    HealthConnectStatus.partiallyConnected =>
      'Health Connect needs permissions — tap to fix',
    HealthConnectStatus.notConnected ||
    HealthConnectStatus.unavailable =>
      "Health Connect isn't connected",
    HealthConnectStatus.connected || null => null,
  };
}

/// Banner body line for [status] (see [healthConnectBannerTitle]).
/// Null when the title carries the whole message
/// (partially-connected) or when no banner may show.
String? healthConnectBannerBody(
  HealthConnectStatus? status, {
  bool staleGrant = false,
}) {
  if (staleGrant) {
    return "There's a problem with the connection. "
        'Tap to disconnect and connect again.';
  }
  return switch (status) {
    HealthConnectStatus.notConnected ||
    HealthConnectStatus.unavailable =>
      'Tap to reconnect',
    HealthConnectStatus.partiallyConnected ||
    HealthConnectStatus.connected ||
    null =>
      null,
  };
}

/// Exact banner copy for [status], or null when no banner may show
/// (connected, or status not known yet). Kept as the banner gate's
/// source: a non-null title means a banner may show.
String? healthConnectBannerText(HealthConnectStatus? status) =>
    healthConnectBannerTitle(status);

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
/// HC connection-honesty package (Juno ruling, condition 1): no
/// diagnostic code is rendered in ANY state — not the stale-grant
/// code, not a bridge code, not UNKNOWN. [staleGrant] only selects
/// the ruled plain-language stale copy (items 1–2); the exception
/// code itself stays in Home's internal plumbing for logs.
class HealthConnectBanner extends StatelessWidget {
  final HealthConnectStatus status;
  final bool staleGrant;
  final VoidCallback onTap;

  const HealthConnectBanner({
    super.key,
    required this.status,
    required this.onTap,
    this.staleGrant = false,
  });

  @override
  Widget build(BuildContext context) {
    final title = healthConnectBannerTitle(status, staleGrant: staleGrant) ??
        "Health Connect isn't connected";
    final body = healthConnectBannerBody(status, staleGrant: staleGrant);
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
            // Round 49 (audit H5): the tap area was ≈34dp tall (v8
            // padding + one text line). The 48dp minimum height makes
            // the whole banner a full-size target; the row's content
            // and padding are unchanged.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12.0, vertical: 8.0),
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              // Round 49 (audit H15): 12.5 was the app's
                              // only non-integer size; 12 is the caption
                              // step.
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: NotelColors.textPrimary,
                            ),
                          ),
                          if (body != null)
                            Text(
                              body,
                              style: const TextStyle(
                                fontSize: 12,
                                color: NotelColors.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
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
      ),
    );
  }
}
