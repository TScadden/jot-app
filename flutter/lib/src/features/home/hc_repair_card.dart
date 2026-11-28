import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/features/connections/health_connect_disclosure.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// HC Grant Hardening §3.3 — the ONE shared repair card for the
/// wedged-grant state (Health Connect reports the permissions
/// granted, but real reads are blocked — the Nov 20, 2026 incident
/// shape). Shown by Home (banner slot under the vitals strip) and
/// by the Heart screen (above the pattern card); nowhere else, and
/// NEVER for a plain not-granted state — that state keeps its
/// existing Link Health Connect layout and banner copy.
///
/// Copy is Juno's, approved verbatim (JUNO-COPY.md item 1) — do
/// not paraphrase, shorten, or re-punctuate:
/// title [hcRepairCardTitle], body [hcRepairCardBody], button
/// [hcRepairCardButton]. No diagnostic codes render here, ever
/// (Juno condition 1 from the connection-honesty package).
const String hcRepairCardTitle =
    'Health Connect needs a quick re-approval to keep syncing';
const String hcRepairCardBody =
    'Tabs is listed as connected, but health data is not coming through right now.';
const String hcRepairCardButton = 'Re-approve access';

/// Outcome of one repair attempt ([runHcRepairFlow]).
enum HcRepairOutcome {
  /// The flow ran and the wedge is cleared — the host force-
  /// reloads its surface; the card's disappearance is derived
  /// from that reloaded state, never from this value alone.
  cleared,

  /// The in-place flow did NOT clear the wedge (the request threw
  /// the stale-grant code, or the re-probe still reports the
  /// wedge): the card swaps to its second step — the existing
  /// Juno-reviewed remove-access directions
  /// ([HealthConnectService.staleGrantMessage]).
  stillWedged,

  /// The user dismissed the MF-3 disclosure (or the host went
  /// away): nothing was launched, nothing changed.
  aborted,

  /// The permission request failed for a reason other than the
  /// stale grant. The failure's code travels in
  /// [HcRepairFlowResult.errorCode] for logs/diagnostics — codes
  /// never render in the card (Juno condition 1).
  failed,
}

/// The result of [runHcRepairFlow]: the outcome plus, for
/// [HcRepairOutcome.failed], the request failure's code and
/// message (the Heart screen surfaces the message through its
/// existing error line, exactly like its link flow does; Home
/// surfaces it under its repair card the same way — the code
/// itself never renders on either surface, Juno condition 1).
class HcRepairFlowResult {
  final HcRepairOutcome outcome;
  final String? errorCode;
  final String? errorMessage;

  const HcRepairFlowResult(this.outcome, {this.errorCode, this.errorMessage});
}

/// Runs the in-place repair: the MF-3 prominent disclosure FIRST
/// (Juno's binding ruling — MF-3 attaches to each permission
/// request, so the disclosure precedes the system permission UI
/// every time, with its own Continue tap; a dismissal launches
/// nothing), then the service's existing
/// [HealthConnectService.requestPermissions] — the HC permissions
/// page for Tabs, in place; no Settings navigation, no disconnect
/// step. A stale-grant throw from the request, or a re-probe that
/// still reports the wedge, reads [HcRepairOutcome.stillWedged];
/// any other request failure reads [HcRepairOutcome.failed] with
/// its code attached (never swallowed silently).
Future<HcRepairFlowResult> runHcRepairFlow(
    BuildContext context, HealthConnectService service) async {
  final proceed = await showHealthConnectDisclosure(context);
  if (!proceed) {
    return const HcRepairFlowResult(HcRepairOutcome.aborted);
  }
  try {
    await service.requestPermissions();
  } on HealthConnectException catch (e) {
    if (e.code == HealthConnectService.staleGrantCode) {
      return const HcRepairFlowResult(HcRepairOutcome.stillWedged);
    }
    return HcRepairFlowResult(HcRepairOutcome.failed,
        errorCode: e.code, errorMessage: e.message);
  } catch (_) {
    return const HcRepairFlowResult(HcRepairOutcome.failed,
        errorCode: 'UNKNOWN');
  }
  // The request's own grant-state probe already ran inside
  // requestPermissions; re-probe so a surviving wedge is decided
  // from a fresh snapshot, not assumed away.
  final snapshot = await service.probeAvailability();
  if (snapshot.staleWedged || snapshot.wedgedPermissions.isNotEmpty) {
    return const HcRepairFlowResult(HcRepairOutcome.stillWedged);
  }
  return const HcRepairFlowResult(HcRepairOutcome.cleared);
}

/// The repair card itself. Stateless on purpose: the HOST owns
/// the wedge state, the second-step flag, and the repair handler
/// (the flow's post-conditions — force-reload, second-step
/// derivation — are surface-specific). [secondStep] swaps the
/// body to the remove-access directions; the button stays, since
/// after removing access its tap IS the "connect again" step the
/// directions end with.
class HcRepairCard extends StatelessWidget {
  final bool secondStep;
  final bool requesting;
  final VoidCallback? onRepairTap;

  const HcRepairCard({
    super.key,
    required this.secondStep,
    required this.requesting,
    required this.onRepairTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: NotelColors.primary.withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.link_off,
                    size: 16, color: NotelColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hcRepairCardTitle,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        secondStep
                            ? HealthConnectService.staleGrantMessage
                            : hcRepairCardBody,
                        style: TextStyle(
                          fontSize: 12,
                          color: NotelColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                onPressed: requesting ? null : onRepairTap,
                child: requesting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(hcRepairCardButton),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
