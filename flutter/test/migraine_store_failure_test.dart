import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';

/// Pass-2 regression tests for C-06a + C-10 (migraine cluster).
///
/// C-06a: MigraineAttackStore._loadBlob conflated a storage READ
/// throw with an empty/corrupt/owner-mismatch blob. save() then
/// upserted into the empty list and _writeBlob overwrote the whole
/// local-only migraine_attacks_v1 blob — permanent loss, no server
/// copy exists (Juno condition 4: never synced). The store's class
/// doc already promises save surfaces failures as a thrown
/// StateError; a read failure must abort the save without writing.
///
/// C-10: save() was a bare read-modify-write with no serialization,
/// while migraine_block fires unawaited updateActive saves per
/// keystroke/chip/slider move — concurrent saves interleaved
/// load/write and an earlier snapshot could land after a later one
/// and revert it. The controller also swallowed every save failure,
/// so an ended attack (incl. its trendsEntryPending save) could be
/// silently lost on restart.
///
/// All tests use only pre-fix public APIs and assert on disk bytes /
/// disk state, so they fail behaviorally on the base code.

MigraineAttack mkAttack({
  required int start,
  int? end,
  String meds = 'sumatriptan',
  int relief = 0,
  bool trendsPending = false,
  int? trendsId,
}) => MigraineAttack(
  id: start,
  startTimestamp: start,
  endTimestamp: end,
  auraPhase: 'VISUAL',
  medsTaken: meds,
  painPeak: 8,
  reliefRating: relief,
  updatedAt: end ?? start,
  trendsEntryId: trendsId,
  trendsEntryPending: trendsPending,
);

String blobOf(List<MigraineAttack> attacks, int? activeId) => jsonEncode({
  'ownerEmail': null,
  'attacks': attacks.map((a) => a.toJson()).toList(),
  'activeAttackId': activeId,
});

class FakeNotifier implements MigraineNotifier {
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> showAttack(int elapsedMin) async => true;
  @override
  Future<void> cancel() async {}
  @override
  Future<bool> areNotificationsEnabled() async => true;
  @override
  Future<bool> launchMigrainePayload() async => false;
}

class FakeGateway implements MigraineTrendsGateway {
  final List<QuickLogEntry> posted = [];
  int nextId = 100;
  @override
  Future<bool> postEntry(QuickLogEntry entry) async {
    posted.add(entry);
    return true;
  }

  @override
  Future<int> resolveMigraineCategoryId() async => 7;
  @override
  Future<int> generateEntryId() async => nextId++;
  @override
  Future<bool?> entryExists(int entryId) async => true;
}

void main() {
  group('C-06a — save aborts on a storage read throw', () {
    test('read throws → save throws StateError, blob byte-identical, '
        'history intact after the read recovers', () async {
      final history = [
        mkAttack(start: 1760000000000, end: 1760003600000),
        mkAttack(start: 1760010000000), // active
      ];
      final seeded = blobOf(history, 1760010000000);
      final disk = <String, String>{MigraineAttackStore.storageKey: seeded};
      var failReads = true;
      final store = MigraineAttackStore.withStorage(
        read: (k) async {
          if (failReads) throw Exception('secure storage unavailable');
          return disk[k];
        },
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );

      await expectLater(
        store.save(mkAttack(start: 1760020000000, end: 1760023600000)),
        throwsStateError,
      );
      expect(
        disk[MigraineAttackStore.storageKey],
        seeded,
        reason: 'an aborted save must not touch the blob at all',
      );

      failReads = false;
      final all = await store.loadAll();
      expect(
        all.map((a) => a.id),
        containsAll([1760000000000, 1760010000000]),
        reason: 'the pre-existing local-only history survives',
      );
      expect((await store.loadActive())?.id, 1760010000000);
    });

    test('control: a corrupt blob still behaves as empty base '
        '(save proceeds)', () async {
      final disk = <String, String>{
        MigraineAttackStore.storageKey: '{not json',
      };
      final store = MigraineAttackStore.withStorage(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      await store.save(mkAttack(start: 1760020000000, end: 1760023600000));
      expect((await store.loadAll()).map((a) => a.id), [1760020000000]);
    });
  });

  group('C-10 — concurrent saves are serialized', () {
    test('two concurrent saves: the first write landing last must '
        'not revert the second save', () async {
      final disk = <String, String>{};
      final firstWriteGate = Completer<void>();
      var writeCalls = 0;
      final store = MigraineAttackStore.withStorage(
        read: (k) async => disk[k],
        write: (k, v) async {
          writeCalls++;
          if (writeCalls == 1) {
            // Hold ONLY the first write: under the base code the
            // second save loads (empty), writes, and completes
            // first; the held first write then lands on top and
            // reverts it. Serialized, the second save cannot start
            // until the first lands, so no revert is possible.
            await firstWriteGate.future;
          }
          disk[k] = v;
        },
        delete: (k) async => disk.remove(k),
      );

      final a = mkAttack(start: 1760100000000, end: 1760103600000);
      final b = mkAttack(start: 1760110000000, end: 1760113600000);
      final saveA = store.save(a);
      final saveB = store.save(b);
      // Give any unserialized interleave time to run its second
      // load+write, then release the held first write.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      firstWriteGate.complete();
      await Future.wait([saveA, saveB]);

      final all = await store.loadAll();
      expect(
        all.map((x) => x.id),
        containsAll([a.id, b.id]),
        reason: 'final disk state must contain BOTH saves',
      );
    });
  });

  group('C-10 — controller end-path save failure is not lost', () {
    test('writes fail for the whole end, then recover: the pending '
        'retry lands the ended attack on disk', () async {
      final disk = <String, String>{};
      var failWrites = false;
      final store = MigraineAttackStore.withStorage(
        read: (k) async => disk[k],
        write: (k, v) async {
          if (failWrites) throw StateError('disk full');
          disk[k] = v;
        },
        delete: (k) async => disk.remove(k),
      );
      final gateway = FakeGateway();
      var now = DateTime(2026, 10, 26, 9, 12);
      final controller = MigraineController(
        store: store,
        notifier: FakeNotifier(),
        gateway: gateway,
        clock: () => now,
      );

      await controller.initialize();
      expect(await controller.startAttack(), isTrue);

      failWrites = true;
      now = DateTime(2026, 10, 26, 9, 57);
      expect(await controller.endWithReliefDialog(reliefRating: 3), isTrue);
      // Every save during the end threw: disk still holds the
      // ACTIVE attack from start — the end exists only in memory.
      final duringOutage = await store.loadAll();
      expect(
        duringOutage.single.isActive,
        isTrue,
        reason: 'sanity: the outage really kept the end off disk',
      );

      failWrites = false;
      // The documented retry point (app start / resume funnel).
      await controller.retryPendingTrends();

      final stored = (await store.loadAll()).single;
      expect(
        stored.isActive,
        isFalse,
        reason:
            'the ended attack must reach disk via the retry, '
            'not stay silently lost',
      );
      expect(stored.reliefRating, 3);
      expect(stored.trendsEntryPending, isFalse);
      expect(stored.trendsEntryId, 100);
      expect(await store.loadActive(), isNull);
    });
  });
}
