import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// LAB-ONLY forced-crash test hook (Juno Ruling 2026-10-27, C6).
///
/// Renders a clearly-marked test card ONLY when [visible] is true.
/// Settings passes `visible: CrashReporting.isLabFlavor`, which is
/// true exclusively for the `lab` Gradle flavor
/// (com.notel.notel.playground.flutter) — a production-flavor build
/// renders nothing here, and the hook is unreachable there.
///
/// Long-pressing the button calls [CrashReporting.forceTestCrash],
/// which throws an uncaught error so the crash-reporting evidence
/// ("app visibly crashes; event arrives") can be exercised on a Lab
/// device once a Lab DSN exists. A normal tap does nothing on
/// purpose: this must never fire by accident.
class CrashTestHook extends StatelessWidget {
  const CrashTestHook({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
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
              'only in the Tabs Lab build. Long-press the button to '
              'force an uncaught test crash; the app will close or '
              'show an error. Do not use on data you care about.',
              style: TextStyle(
                  color: NotelColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: GestureDetector(
                onLongPress: CrashReporting.forceTestCrash,
                child: ElevatedButton(
                  key: const ValueKey('crash_test_hook_button'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: NotelColors.surfaceHigh,
                      foregroundColor: NotelColors.textPrimary),
                  // A plain tap is inert by design (see class doc).
                  onPressed: () {},
                  child: const Text('Long-press to force a test crash',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
