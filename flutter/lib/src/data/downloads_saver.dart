/// Downloads saver — Dart side of the automatic Downloads copy
/// for generated report PDFs (founder requirement, Oct 22, 2026;
/// state model per Juno Ruling 2).
///
/// The native writer lives in the Health Connect bridge plugin
/// (HealthConnectBridgePlugin.kt, `savePdfToDownloads`): the same
/// plugin/channel whose `exportCsvFile` already writes the Key
/// Metrics CSV into Downloads via MediaStore — this extends that
/// existing bridge with a BYTE hand-off instead of adding a plugin
/// dependency. MediaStore inserts into the Downloads collection
/// need no storage permission on Android 10+ (scoped storage); on
/// older Android the native side fails honestly rather than
/// requesting a broad storage permission.
///
/// Contract:
/// - The bytes cross the channel EXACTLY as generated — the caller
///   passes the same byte list the share sheet will share, so the
///   Downloads copy is byte-identical to the shared file. The PDF
///   is never regenerated for this copy.
/// - NOTHING here ever throws: every channel failure (platform
///   error, missing plugin in tests/background engines, unexpected
///   error) reports `false`, so a failed Downloads copy can never
///   block report generation or sharing.
library;

import 'package:flutter/services.dart';

import 'package:tabs_lab/src/data/health_connect_service.dart';

/// Thin, never-throwing wrapper over the bridge channel's
/// Downloads writer. See the file header for the full contract.
class ReportDownloadsSaver {
  final MethodChannel _channel;

  const ReportDownloadsSaver({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(HealthConnectService.channelName);

  /// The shared app-scope wrapper over the bridge channel.
  static const ReportDownloadsSaver instance = ReportDownloadsSaver();

  /// Saves [bytes] as [fileName] into the device's public
  /// Downloads folder via MediaStore. Returns true only when the
  /// native side confirms the copy landed; false on ANY failure.
  Future<bool> savePdf({
    required List<int> bytes,
    required String fileName,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('savePdfToDownloads', {
        'fileName': fileName,
        'bytes': Uint8List.fromList(bytes),
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
