import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Round 19 — voice input for the Quick Log details field.
///
/// Mirrors the native mic flow (`QuickLogScreen` → `VoiceLogActivity`):
/// the user speaks, recognized text lands in the details field, and
/// tapping Log saves the entry. The native activity does continuous
/// `SpeechRecognizer` listening with its own UI; the Flutter Lab port
/// uses Android's intent-based recognizer
/// (`RecognizerIntent.ACTION_RECOGNIZE_SPEECH`) — no `RECORD_AUDIO`
/// permission, no extra dependency — and returns the top result.
///
/// Team lesson (silent channel failures): every call surfaces its error
/// code visibly (`[CODE] message`), never a silent no-op.
class VoiceInput {
  static const MethodChannel _channel =
      MethodChannel('com.notel.notel.playground.flutter/voice');

  /// Whether voice input can work on this platform. The recognizer
  /// handler exists only in Android's MainActivity.kt — iOS has no
  /// handler registered, so every call there throws
  /// [MissingPluginException]. Surfaces consult this gate and hide
  /// their mic affordances where it is false (Juno pre-submission
  /// sweep, Nov 22, 2026). When an iOS handler is built, this getter
  /// is the only Dart change needed.
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android;

  /// Launches the system voice recognizer and returns the recognized
  /// text. Throws [VoiceInputException] with a visible `[CODE]` on any
  /// failure (no recognizer app, cancelled, empty result, timeout).
  Future<String> startVoiceInput() async {
    try {
      final text = await _channel.invokeMethod<String>('startVoiceInput');
      if (text == null || text.trim().isEmpty) {
        throw const VoiceInputException(
            'No speech was recognized — try again.');
      }
      return text.trim();
    } on PlatformException catch (e) {
      throw VoiceInputException(
          e.message ?? 'Voice input failed.');
    } on MissingPluginException {
      throw const VoiceInputException(
          'Voice input is not available on this device.');
    }
  }
}

class VoiceInputException implements Exception {
  final String message;
  const VoiceInputException(this.message);

  @override
  String toString() => message;
}
