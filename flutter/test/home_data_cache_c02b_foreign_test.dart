import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

/// In-memory fake for the cache's storage functions, so no test touches
/// platform channels.
class _FakeStore {
  final Map<String, String> values = {};
  int writes = 0;

  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Fake store whose reads can be made to throw (the C-02b window): a
/// transient storage failure during the pre-frame warm, healing before
/// the session's first persist.
class _FlakyStore extends _FakeStore {
  bool throwOnRead = false;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw StateError('storage read failed');
    return super.read(key);
  }
}

void main() {
  late _FakeStore store;

  setUp(() {
    store = _FakeStore();
    HomeDataCache.instance.debugSetStore(
        read: store.read, write: store.write, delete: store.delete);
    HomeDataCache.instance.debugReset();
  });

  tearDown(() {
    HomeDataCache.instance.debugReset();
  });

  group('C-02b follow-up (Vera PR #65 D1/D2)', () {
    test(
        'D1: persist after a failed owner-bound warm does NOT adopt a '
        'foreign blob — it takes the reset+delete path and writes no '
        'mixed blob', () async {
      final cache = HomeDataCache.instance;

      // Seed account A's blob through A's own applies + persist.
      const counter = EventCounterItem(
          id: 'ac1', name: 'A trip', targetDate: 1893456000000);
      cache.applyVitals(const TodayVitals(heartRate: 70, logCountToday: 2),
          ownerEmail: 'a@example.com');
      cache.applyStreak(12, 30, ownerEmail: 'a@example.com');
      cache.applyCounters(const [counter], ownerEmail: 'a@example.com');
      await cache.persist();
      final blobA = store.values[HomeDataCache.storageKey]!;
      expect(blobA, contains('"ownerEmail":"a@example.com"'));
      expect(blobA, contains('"currentStreak":12'));

      // Cold start for account B: the pre-frame warm is owner-bound
      // (main.dart) but its storage read throws — the exact C-02b
      // window. The cache stays unwarmed and nothing is bound yet.
      final flaky = _FlakyStore();
      flaky.values[HomeDataCache.storageKey] = blobA;
      flaky.throwOnRead = true;
      cache.debugSetStore(
          read: flaky.read, write: flaky.write, delete: flaky.delete);
      cache.debugReset();
      await cache.warmFromDisk(currentEmail: 'b@example.com');
      expect(cache.snapshot.streakLoaded, isFalse);

      // Storage heals. B's session applies its OWN vitals exactly as
      // _loadHealthData does (no ownerEmail argument) and persists.
      flaky.throwOnRead = false;
      cache.applyVitals(const TodayVitals(heartRate: 99, logCountToday: 1));
      await cache.persist();

      // The foreign blob must NOT be adopted: none of A's sections
      // may appear in B's session snapshot.
      final s = cache.snapshot;
      expect(s.streakLoaded, isFalse,
          reason: "A's streak must never render in B's session");
      expect(s.currentStreak, isNull);
      expect(s.bestStreak, isNull);
      expect(s.countersLoaded, isFalse,
          reason: "A's counters must never render in B's session");
      expect(s.counters, isEmpty);
      expect(s.ownerEmail, 'b@example.com',
          reason: 'the session owner is bound by the reset path, '
              'never overwritten by the foreign blob owner');

      // And persist must never write a mixed blob: the foreign blob
      // takes the reset+delete path, so the disk key is gone and
      // persist performed no write at all on the healed store.
      expect(flaky.writes, 0,
          reason: 'persist must not write after the foreign reset — '
              'certainly not a mixed blob under the foreign owner');
      expect(flaky.values.containsKey(HomeDataCache.storageKey), isFalse,
          reason: 'the foreign blob is deleted, never rewritten with '
              "B's data under A's ownerEmail");
    });

    test(
        'D2: persist ensure-warm does not regress fresh in-memory '
        'vitals to the older disk stamp', () async {
      final cache = HomeDataCache.instance;

      // Pre-existing disk blob stamped YESTERDAY (its vitals are
      // date-bound stale and must not be adopted — and must not
      // re-stamp today's data either).
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      cache.applyVitals(const TodayVitals(heartRate: 70, logCountToday: 2),
          now: yesterday);
      await cache.persist();
      final seeded = jsonDecode(store.values[HomeDataCache.storageKey]!)
          as Map<String, dynamic>;
      expect(seeded['fetchedAt'], yesterday.toIso8601String());

      // New process, no successful warm yet: today's fresh vitals are
      // applied in memory, then persist ensures its warm against the
      // older-stamped disk blob.
      cache.debugReset();
      final fresh = DateTime.now();
      cache.applyVitals(const TodayVitals(heartRate: 99, logCountToday: 5),
          now: fresh);
      await cache.persist();

      // The persisted stamp is the FRESH apply's stamp, and the fresh
      // vitals are still judged fresh (today) in the snapshot.
      final persisted = jsonDecode(store.values[HomeDataCache.storageKey]!)
          as Map<String, dynamic>;
      expect(persisted['fetchedAt'], fresh.toIso8601String(),
          reason: "today's vitals must keep today's stamp after the "
              'ensure-warm, not be regressed to the disk stamp');
      final s = cache.snapshot;
      expect(s.vitalsLoaded, isTrue,
          reason: "today's vitals must not be judged stale by their "
              'own persist');
      expect(s.vitals!.heartRate, 99);
    });
  });
}
