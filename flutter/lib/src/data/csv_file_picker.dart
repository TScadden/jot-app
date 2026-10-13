import 'package:flutter/services.dart';

/// Round 48 — failure from the CSV file picker channel. [code] is
/// the Kotlin side's stable error code (`TOO_LARGE`, `READ_FAILED`,
/// `UNAVAILABLE`, `IN_FLIGHT`, `LAUNCH_FAILED`); [message] is the
/// user-facing text the native side supplies (native
/// `MSG_TOO_LARGE` / `MSG_READ_FAILED` wording).
class CsvPickException implements Exception {
  final String code;
  final String? message;

  const CsvPickException(this.code, [this.message]);

  @override
  String toString() => 'CsvPickException($code)';
}

/// Round 48 — picks a text file through the Android Storage Access
/// Framework (the Flutter host's MainActivity registers a
/// `GetContent` launcher, mirroring native `BloodPressureScreen`'s
/// CSV picker) and returns its text, capped at 5 MB on the Kotlin
/// side like native `readCsvTextCapped`.
///
/// Returns null when the user cancels the picker. Throws
/// [CsvPickException] on too-large / unreadable / unavailable.
class CsvFilePicker {
  static const String channelName =
      'com.notel.notel.playground.flutter/file_picker';

  final MethodChannel _channel;

  CsvFilePicker({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  Future<String?> pickCsvText() async {
    try {
      return await _channel.invokeMethod<String>('pickCsvText');
    } on PlatformException catch (e) {
      throw CsvPickException(e.code, e.message);
    } on MissingPluginException {
      throw const CsvPickException('UNAVAILABLE',
          "Couldn't read this file. Please try a different CSV.");
    }
  }
}
