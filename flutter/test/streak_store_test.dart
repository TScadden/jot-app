import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';

/// Lab (streak screen package, Nov 4, 2026) — StreakStore:
/// persistence round-trip (the read-back proof), seeding discipline,
/// and account-owner binding.
void main() {
  DateTime at(int y, int m, int d) => DateTime(y, m, d, 12);

  late Map<String, String> disk;
  late StreakStore store;

  StreakStore wireStore() {
    final s = StreakStore.instance;
    s.debugReset();
    s.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async {
        disk[key] = value;
      },
      delete: (key) async {
        disk.remove(key);
      },
    );
    return s;
  }

  setUp(() {
    disk = {};
    store = wireStore();
  });

  test('recordOpen seeds from the pull and persists; a cold store '
      'reads the identical state back', () async {
    final s = await store.recordOpen(
      seedCurrent: 6,
      seedBest: 12,
      now: at(2026, 11, 4),
    );
    await store.persist();
    expect(s.seeded, isTrue);
    expect(streakCurrent(s, at(2026, 11, 4)), 6);
    expect(disk.containsKey(StreakStore.storageKey), isTrue);

    // Cold start: memory wiped, same disk → identical state.
    final cold = wireStore();
    final back = await cold.recordOpen(
      seedCurrent: null,
      seedBest: null,
      now: at(2026, 11, 4),
    );
    expect(back, s);
    expect(streakCurrent(back, at(2026, 11, 4)), 6);
    expect(streakBest(back), 12);
  });

  test('a failed pull (null seeds) never seeds and never erases', () async {
    final s = await store.recordOpen(
      seedCurrent: null,
      seedBest: null,
      now: at(2026, 11, 4),
    );
    expect(s.seeded, isFalse);
    // Today is still recorded locally (an app open happened), so a
    // later successful pull merges instead of replacing.
    expect(s.countedDays, contains('2026-11-04'));
  });

  test('a later pull merges with offline history: local days kept, '
      'best taken as a floor', () async {
    // Day 1 offline open; day 2 missed; day 3 offline open (save
    // consumed locally, still unseeded).
    await store.recordOpen(seedCurrent: null, seedBest: null, now: at(2026, 11, 1));
    final day3 = await store.recordOpen(
      seedCurrent: null,
      seedBest: null,
      now: at(2026, 11, 3),
    );
    expect(day3.restoredDays, contains('2026-11-02'));
    expect(day3.seeded, isFalse);

    // The pull finally lands with the profile's older counters.
    final merged = await store.recordOpen(
      seedCurrent: 1,
      seedBest: 9,
      now: at(2026, 11, 3),
    );
    expect(merged.seeded, isTrue);
    expect(merged.restoredDays, contains('2026-11-02'));
    expect(streakCurrent(merged, at(2026, 11, 3)), 3);
    expect(streakBest(merged), 9);
  });

  test('the same pull pair never re-seeds: local opens keep '
      'growing the run past the frozen counters', () async {
    await store.recordOpen(seedCurrent: 6, seedBest: 12, now: at(2026, 11, 4));
    final next = await store.recordOpen(
      seedCurrent: 6,
      seedBest: 12,
      now: at(2026, 11, 5),
    );
    expect(streakCurrent(next, at(2026, 11, 5)), 7);
    expect(streakBest(next), 12);
  });

  test('a changed pull pair re-seeds: new server truth is adopted',
      () async {
    await store.recordOpen(seedCurrent: 6, seedBest: 12, now: at(2026, 11, 4));
    final reseeded = await store.recordOpen(
      seedCurrent: 2,
      seedBest: 3,
      now: at(2026, 11, 5),
    );
    expect(streakCurrent(reseeded, at(2026, 11, 5)), 2);
    expect(streakBest(reseeded), 3);
    expect(reseeded.countedDays.contains('2026-11-04'), isTrue);
    expect(reseeded.countedDays.contains('2026-11-03'), isFalse);
  });

  test('owner mismatch drops the record; the same owner keeps it',
      () async {
    await store.clearIfOwnerMismatch('a@example.com');
    final s = await store.recordOpen(
      seedCurrent: 4,
      seedBest: 4,
      now: at(2026, 11, 4),
    );
    await store.persist();
    expect(streakCurrent(s, at(2026, 11, 4)), 4);

    // Same owner: no drop.
    await store.clearIfOwnerMismatch('a@example.com');
    expect(store.state, isNotNull);
    expect(streakCurrent(store.state!, at(2026, 11, 4)), 4);

    // Different owner: memory wiped synchronously, disk dropped.
    await store.clearIfOwnerMismatch('b@example.com');
    expect(store.state, isNull);
    expect(disk.containsKey(StreakStore.storageKey), isFalse);

    // And B's first open starts from B's own pull, not A's numbers.
    final bs = await store.recordOpen(
      seedCurrent: 2,
      seedBest: 2,
      now: at(2026, 11, 4),
    );
    expect(streakCurrent(bs, at(2026, 11, 4)), 2);
  });

  test('a blob with no owner is dropped once an account is known',
      () async {
    await store.recordOpen(seedCurrent: 3, seedBest: 3, now: at(2026, 11, 4));
    await store.persist();
    expect(disk.containsKey(StreakStore.storageKey), isTrue);

    final cold = wireStore();
    await cold.clearIfOwnerMismatch('a@example.com');
    expect(cold.state, isNull);
    expect(disk.containsKey(StreakStore.storageKey), isFalse);
  });
}
