import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'package:tabs_lab/src/data/report_generation_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// The report share confirmation flow, extracted verbatim from
/// the Progress Reports page (PR #55's `_showShareConfirmation`)
/// so it can be presented from ANY in-app screen: the page itself
/// when the user is watching it, or the app-root presenter when a
/// generation completes while the user is elsewhere in the app.
///
/// Exactly-once is the [ReportGenerationService]'s app-level
/// claim: the first presenter to ask runs the flow; every other
/// ask (resume reveal, notification tap, the other presenter)
/// returns immediately. All user-visible strings are the page's
/// existing ones — this extraction adds no copy.
///
/// The held outcome is consumed once the dialog has actually
/// been answered: if the presenting context dies mid-dialog
/// (its page disposed under the modal), the answer is still
/// honored and the outcome consumed — only the snackbar extras
/// are skipped for want of a live context.
Future<void> presentReportShareConfirmation({
  required BuildContext context,
  required ReportGenerationService service,
  required SettingsStore store,
  Future<void> Function(List<int> bytes, String fileName)? sharePdf,
}) async {
  if (!service.tryClaimShareDialog()) return;
  try {
    final ready = service.pendingShare;
    if (ready == null) return;
    final share = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Share health report',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'This PDF contains your health data. Only share it with people you trust.',
                style:
                    TextStyle(color: NotelColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 8),
            Text(ready.fileName,
                style: const TextStyle(
                    color: NotelColors.textPrimary, fontSize: 12)),
            const SizedBox(height: 8),
            Text('For informational purposes only. Not medical advice.',
                style: TextStyle(
                    color: NotelColors.textSecondary.withValues(alpha: 0.7),
                    fontSize: 11)),
            if (ready.aiFailureReason != null) ...[
              const SizedBox(height: 8),
              Text('AI summary unavailable: ${ready.aiFailureReason}',
                  style: const TextStyle(
                      color: NotelColors.textSecondary, fontSize: 11)),
            ],
            // Juno Ruling 2: the Downloads attempt finished before
            // this dialog opened and its outcome travels with the
            // ready outcome — this line is its disclosure.
            if (ready.downloadsSaved != null) ...[
              const SizedBox(height: 8),
              Text(
                  ready.downloadsSaved!
                      ? 'A copy was also saved to your Downloads folder.'
                      : 'This report could not be saved to Downloads. It is saved in the app and you can still share it now.',
                  style: const TextStyle(
                      color: NotelColors.textSecondary, fontSize: 11)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Share',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (!context.mounted) {
      // The presenter went away mid-dialog (its page was
      // disposed under the modal during the navigation
      // transition), but the user HAS seen and answered this
      // dialog: consume the outcome so it is not held forever.
      // Only the UI extras (snackbars) are skipped — there is
      // no live context to show them on.
      if (share == true) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        await store.setReportLastExportMs(nowMs);
        service.consumePendingShare(exportMs: nowMs);
        final shareFn = sharePdf ??
            (bytes, name) => Printing.sharePdf(
                bytes: Uint8List.fromList(bytes), filename: name);
        try {
          await shareFn(ready.pdfBytes, ready.fileName);
        } catch (_) {
          // No context for the failure snackbar; the report is
          // saved in the app (and Downloads, when that copy
          // landed) regardless.
        }
      } else {
        service.consumePendingShare();
      }
      return;
    }
    if (share != true) {
      service.consumePendingShare();
      // Saved-file transparency (Juno Ruling 2 wording): the PDF
      // is already saved in the app even when the user declines to
      // share right now, and in Downloads too when that copy
      // landed.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ready.downloadsSaved == true
              ? 'Report saved in Downloads and in the app. Export again any time to share it.'
              : 'Report saved in the app. It could not be saved to Downloads. Export again any time to share it.')));
      return;
    }
    // Native marks the export when the share sheet is launched.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await store.setReportLastExportMs(nowMs);
    service.consumePendingShare(exportMs: nowMs);
    if (!context.mounted) return;
    final shareFn = sharePdf ??
        (bytes, name) => Printing.sharePdf(
            bytes: Uint8List.fromList(bytes), filename: name);
    try {
      await shareFn(ready.pdfBytes, ready.fileName);
    } catch (_) {
      if (context.mounted) {
        // Juno Ruling 2: name Downloads only when that copy landed.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ready.downloadsSaved == true
                ? 'Could not open the share sheet. The report is saved in Downloads and in the app.'
                : 'Could not open the share sheet. The report is saved in the app.')));
      }
    }
  } finally {
    service.releaseShareDialog();
  }
}
