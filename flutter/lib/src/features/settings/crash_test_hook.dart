import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// LAB-ONLY crash-reporting test hooks (Juno Ruling 2026-10-27, C6;
/// Step-2 extension: Juno Conditions 1 + 6 and §7 of the Step-2
/// verdict).
///
/// Renders a clearly-marked test card ONLY when [visible] is true.
/// Settings passes `visible: CrashReporting.isLabFlavor()`, which is
/// true exclusively for the `lab` Gradle flavor
/// (com.notel.notel.playground.flutter) — a production-flavor build
/// renders nothing here, and every action below is additionally
/// gated inside [CrashReporting] (and, for the native trigger, on
/// the Kotlin side), so no action is reachable in prod.
///
/// Three actions, each fired by a SINGLE TAP (founder direction,
/// Oct 27, 2026: the original long-press gate was unusable on
/// device — the settings scroll view's gesture arena ate the
/// press — so a plain tap fires, with no confirmation gate):
///
/// - Dart forced crash: [CrashReporting.forceTestCrash] throws an
///   uncaught error through the real uncaught path (C6 evidence).
/// - Native crash: [CrashReporting.triggerNativeTestCrash] invokes
///   the Lab-only MethodChannel whose Kotlin handler posts a fatal
///   RuntimeException to the main thread, OUTSIDE the channel call
///   stack, so the process genuinely dies and the event is captured
///   by the native/Java Sentry pipeline that bypasses the Dart
///   beforeSend allowlist (Condition 1 evidence).
/// - Canary event: [CrashReporting.triggerLabCanaryTestEvent] emits
///   the nine synthetic R11 canary seeds through the live pipeline
///   so the received event's raw JSON can be inspected in the
///   Sentry console (§7 console-level R11 repeat).
///
/// Channel failures are shown in the card with their error code —
/// never silently swallowed (team lesson).
class CrashTestHook extends StatefulWidget {
  const CrashTestHook({
    super.key,
    required this.visible,
    this.nativeCrashAction,
    this.canaryAction,
  });

  final bool visible;

  /// Test seams: when null, the real [CrashReporting] triggers run.
  final Future<bool> Function()? nativeCrashAction;
  final Future<bool> Function()? canaryAction;

  @override
  State<CrashTestHook> createState() => _CrashTestHookState();
}

class _CrashTestHookState extends State<CrashTestHook> {
  String? _status;

  void _setStatus(String status) {
    if (mounted) setState(() => _status = status);
  }

  Future<void> _fireNativeCrash() async {
    try {
      final fired =
          await (widget.nativeCrashAction ??
              CrashReporting.triggerNativeTestCrash)();
      if (!fired) {
        _setStatus(
          '[LAB_HOOK_INERT] Native crash not fired: this '
          'build is not the Lab flavor.',
        );
      }
      // When fired, the process is about to die — no success state
      // is meaningful (or reachable) to display.
    } on PlatformException catch (e) {
      _setStatus(
        '[${e.code}] Native crash channel error: '
        '${e.message ?? 'unknown error'}',
      );
    } on MissingPluginException {
      _setStatus(
        '[MISSING_PLUGIN] Native crash channel is not '
        'registered in this build (Lab flavor only).',
      );
    } catch (e) {
      _setStatus('[NATIVE_CRASH_FAILED] $e');
    }
  }

  Future<void> _fireCanary() async {
    try {
      final sent =
          await (widget.canaryAction ??
              CrashReporting.triggerLabCanaryTestEvent)();
      _setStatus(
        sent
            ? 'Canary event sent through the live pipeline. Inspect '
                  'its raw JSON in the Sentry console (project tabs, '
                  'environment lab): zero canary values may appear.'
            : '[LAB_HOOK_INERT] Canary not sent: this build is not '
                  'the Lab flavor, or Sentry is not enabled (empty DSN).',
      );
    } on PlatformException catch (e) {
      _setStatus(
        '[${e.code}] Canary send error: '
        '${e.message ?? 'unknown error'}',
      );
    } catch (e) {
      _setStatus('[CANARY_FAILED] $e');
    }
  }

  Widget _actionButton({
    required ValueKey<String> key,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        key: key,
        style: ElevatedButton.styleFrom(
          backgroundColor: NotelColors.surfaceHigh,
          foregroundColor: NotelColors.textPrimary,
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('crash_test_hook_card'),
      color: NotelColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'TEST ONLY — crash reporting check. This card exists '
              'only in the Tabs Lab build. Tap a button to '
              'fire it. The two crash '
              'buttons will close the app. Do not use on data you '
              'care about.',
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            _actionButton(
              key: const ValueKey('crash_test_hook_button'),
              label: 'Tap to force a test crash',
              onTap: CrashReporting.forceTestCrash,
            ),
            const SizedBox(height: 12),
            const Text(
              'Native crash (Condition 1): a Kotlin-side fatal, '
              'captured by the native Sentry pipeline that bypasses '
              'the Dart scrub. The app will close.',
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            _actionButton(
              key: const ValueKey('crash_test_hook_native_button'),
              label: 'Tap to force a NATIVE test crash',
              onTap: _fireNativeCrash,
            ),
            const SizedBox(height: 12),
            const Text(
              'Canary event (R11): sends the nine synthetic canary '
              'seeds through the live pipeline so the received '
              'event can be inspected in the Sentry console. '
              'Synthetic values only; the app does not crash.',
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            _actionButton(
              key: const ValueKey('crash_test_hook_canary_button'),
              label: 'Tap to send the canary test event',
              onTap: _fireCanary,
            ),
            const SizedBox(height: 12),
            // Phase 3 (Juno Ruling 2026-10-28 §1.6 Layer 1(2)):
            // the native C1 scrub registration outcome is surfaced
            // HERE — a registration failure shows its error code in
            // this card, never a silent no-op.
            Text(
              CrashReporting.nativeScrubRegistration?.display ??
                  'Native C1 scrub: registration not attempted in '
                      'this process (DSN-empty builds register '
                      'nothing by design).',
              key: const ValueKey('crash_test_hook_scrub_status'),
              style: const TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 12,
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(
                _status!,
                key: const ValueKey('crash_test_hook_status'),
                style: const TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
