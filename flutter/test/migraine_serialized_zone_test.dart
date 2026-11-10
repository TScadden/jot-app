import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';

/// Regression pin for the PR #60 R35 regression: C-10 originally
/// serialized saves/clears through a stored tail future
/// (`_opChain = Future.value()` as a field initializer). A future's
/// callbacks are scheduled in the zone that created the future, and
/// the shared [MigraineAttackStore.instance] singleton is routinely
/// first constructed inside a `testWidgets` FakeAsync zone
/// (TodaySummaryCard's initState builds the production migraine
/// controller). Once that zone was discarded, the chain head could
/// never complete, so the first later `clear()` — e.g. the logout
/// wipe in `AccountActions.clearDefaultCaches`, called from a plain
/// test — hung forever (R35's two 30 s timeouts). The queue-based
/// serializer keeps no long-lived future in its state, so an op
/// enqueued from a different zone than the construction zone must
/// still run.
///
/// The two cases below must run in this order: the first touches
/// the singleton for the first time in this isolate, inside the
/// widget test's FakeAsync zone; the second operates on it from a
/// plain (real-zone) test.
void main() {
  final disk = <String, String>{};

  void wireSingleton() {
    MigraineAttackStore.instance.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
  }

  testWidgets('singleton is first constructed inside a FakeAsync zone',
      (tester) async {
    wireSingleton();
    disk[MigraineAttackStore.storageKey] = jsonEncode({
      'ownerEmail': null,
      'attacks': const [],
      'activeAttackId': null,
    });
    expect(disk.containsKey(MigraineAttackStore.storageKey), isTrue);
  });

  test('a serialized clear from a different zone still completes '
      'and wipes, and a later save still lands', () async {
    wireSingleton();
    // With the future-chain serializer this await never returns
    // (the chain head belongs to the dead FakeAsync zone above);
    // the explicit timeout turns that hang into a fast failure.
    await MigraineAttackStore.instance
        .clear()
        .timeout(const Duration(seconds: 5));
    expect(disk.containsKey(MigraineAttackStore.storageKey), isFalse);

    final attack = MigraineAttack(
      id: 1760000000000,
      startTimestamp: 1760000000000,
      updatedAt: 1760000000000,
    );
    await MigraineAttackStore.instance
        .save(attack)
        .timeout(const Duration(seconds: 5));
    final all = await MigraineAttackStore.instance.loadAll();
    expect(all.map((a) => a.id), [1760000000000]);
  });
}
