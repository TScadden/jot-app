import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';

/// Regression pin for the PR #60 R70 hang (the sibling of
/// migraine_serialized_zone_test.dart, which pins the FIRST hang —
/// singleton CONSTRUCTION inside a FakeAsync zone).
///
/// This hang is about where the serializer's DRAIN starts. The
/// r70 wiring test drives the real account paths against the
/// shared [MigraineAttackStore.instance] with its real
/// platform-channel storage (the test injects storage only into
/// the health-history store):
///
///  * login (`main.dart` _onLoginSuccess) fires
///    [MigraineAttackStore.clearIfOwnerMismatch] unawaited, and
///  * session expiry (`main.dart` _onSessionExpired) fires
///    [MigraineAttackStore.clear] unawaited,
///
/// both from inside the widget test's FakeAsync zone. At the
/// broken head the first of those calls started `_drainOps` in
/// that zone; the in-flight op awaits the real
/// FlutterSecureStorage channel, whose replies can never be
/// delivered into a FakeAsync zone, so the drain sat on that
/// await forever with the draining flag stuck on. The
/// account-clear wipe (`AccountActions.clearDefaultCaches`,
/// driven via `tester.runAsync` — the real zone) then awaited a
/// `clear()` that queued behind the wedged drain and never ran:
/// the wiring test hit its 10-minute timeout with the isolate
/// idle. The queue now runs its machinery in Zone.root, so an op
/// enqueued from any zone awaits its storage IO in the real-async
/// root zone and the drain always progresses.
///
/// Bounded: the final clear carries a 5 s timeout, so at the
/// broken head this fails in seconds instead of hanging.
void main() {
  testWidgets(
      'drain started by unawaited FakeAsync-zone ops cannot wedge '
      'a later real-zone clear', (tester) async {
    // Login shape: unawaited owner-mismatch enforcement, FakeAsync.
    unawaited(MigraineAttackStore.instance.clearIfOwnerMismatch('b@x.com'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Session-expiry shape: unawaited clear, FakeAsync.
    unawaited(MigraineAttackStore.instance.clear());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Account-clear shape: awaited from the real zone, exactly as
    // the r70 test awaits AccountActions.clearDefaultCaches.
    await tester.runAsync(() async {
      await MigraineAttackStore.instance
          .clear()
          .timeout(const Duration(seconds: 5));
    });
  });
}
