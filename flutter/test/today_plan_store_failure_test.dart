import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';

/// Pass-2 audit regression — TodayPlanStore (C-06, today-plan half):
/// `load()`'s catch returned `const TodayPlanLocalState()` for a
/// storage READ throw, indistinguishable from missing / corrupt /
/// other-day / other-owner. `setReminderCompleted` / `setMedAction`
/// then mutated that empty state and `_save`d the whole
/// `today_plan_state_v1` blob containing only the single new
/// completion/action — erasing that day's other reminder
/// completions and local dose statuses (SKIPPED/SNOOZED exist only
/// in this store).
///
/// Fix shape (verdict v-stores.md, C-06): mutations skip `_save`
/// when the load failed, instead of treating the failed load as an
/// authoritative empty state.
///
/// All assertions are behavioral (disk bytes + loads through a
/// fresh store over the same disk) so they run against the pre-fix
/// store unchanged and fail there.
class FakeDisk {
  final Map<String, String> mem = {};
  bool throwOnRead = false;

  static const String today = '2026-11-09';
  static const String email = 'a@x.com';

  TodayPlanStore store() {
    final s = TodayPlanStore.testInstance();
    s.debugSetStore(
      read: (k) async {
        if (throwOnRead) throw StateError('read boom');
        return mem[k];
      },
      write: (k, v) async => mem[k] = v,
      delete: (k) async => mem.remove(k),
    );
    return s;
  }

  /// A day blob holding two reminder completions and two local
  /// dose statuses that exist only in this store.
  String seedBlob() => jsonEncode({
    'ownerEmail': email,
    'date': today,
    'completedReminderIds': [7, 9],
    'medActions': {'medA|Daily': 'SKIPPED', 'medB|Morning': 'SNOOZED'},
  });

  void seed() => mem[TodayPlanStore.storageKey] = seedBlob();
}

void main() {
  group('C-06b — read throw is not "loaded, empty"', () {
    test('(a) setReminderCompleted during a read outage does not '
        'overwrite the blob', () async {
      final disk = FakeDisk()..seed();
      final original = disk.mem[TodayPlanStore.storageKey];
      disk.throwOnRead = true;
      final store = disk.store();

      await store.setReminderCompleted(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
        reminderId: 42,
        completed: true,
      );

      // The unread blob must be byte-identical: nothing persisted
      // over disk state the store never successfully read.
      expect(disk.mem[TodayPlanStore.storageKey], original);
    });

    test('(b) setMedAction during a read outage does not overwrite '
        'the blob incl. SKIPPED/SNOOZED statuses', () async {
      final disk = FakeDisk()..seed();
      final original = disk.mem[TodayPlanStore.storageKey];
      disk.throwOnRead = true;
      final store = disk.store();

      await store.setMedAction(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
        medKey: 'medC',
        slot: 'Evening',
        status: DoseStatus.taken,
      );

      expect(disk.mem[TodayPlanStore.storageKey], original);
      final decoded = jsonDecode(
        disk.mem[TodayPlanStore.storageKey]!,
      ) as Map<String, dynamic>;
      expect(decoded['completedReminderIds'], [7, 9]);
      expect(decoded['medActions'], {
        'medA|Daily': 'SKIPPED',
        'medB|Morning': 'SNOOZED',
      });
    });

    test('(c) after reads recover, the stored day state is intact '
        'and a new mutation persists on top of it', () async {
      final disk = FakeDisk()..seed();
      final store = disk.store();

      disk.throwOnRead = true;
      await store.setReminderCompleted(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
        reminderId: 42,
        completed: true,
      );
      await store.setMedAction(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
        medKey: 'medC',
        slot: 'Evening',
        status: DoseStatus.taken,
      );

      disk.throwOnRead = false;
      // The pre-existing day state survived the outage untouched.
      final intact = await disk.store().load(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
      );
      expect(intact.completedReminderIds, {7, 9});
      expect(intact.medActions, {
        'medA|Daily': DoseStatus.skipped,
        'medB|Morning': DoseStatus.snoozed,
      });

      // A new mutation now persists ON TOP of the recovered state,
      // not instead of it.
      await store.setReminderCompleted(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
        reminderId: 42,
        completed: true,
      );
      await store.setMedAction(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
        medKey: 'medC',
        slot: 'Evening',
        status: DoseStatus.taken,
      );
      final merged = await disk.store().load(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
      );
      expect(merged.completedReminderIds, {7, 9, 42});
      expect(merged.medActions, {
        'medA|Daily': DoseStatus.skipped,
        'medB|Morning': DoseStatus.snoozed,
        'medC|Evening': DoseStatus.taken,
      });
    });

    test('normal path still works: mutations on a readable disk '
        'round-trip', () async {
      final disk = FakeDisk();
      final store = disk.store();
      await store.setReminderCompleted(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
        reminderId: 7,
        completed: true,
      );
      await store.setMedAction(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
        medKey: 'k',
        slot: 'Daily',
        status: DoseStatus.taken,
      );
      final loaded = await disk.store().load(
        email: FakeDisk.email,
        todayStr: FakeDisk.today,
      );
      expect(loaded.completedReminderIds, {7});
      expect(loaded.medActions['k|Daily'], DoseStatus.taken);
    });
  });
}
