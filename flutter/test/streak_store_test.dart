import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';

/// StreakStore, release line (VC 100115) — the authoritative
/// pipeline: the server profile record (counters + streakState
/// blob) is adopted on settle, settled records push back, and a
/// fresh install can NEVER mint a 1 over an existing server
/// streak (the founder's Lab bug: production Home frozen at 14,
/// Lab streak screen at 1).
void main() {
  DateTime at(int y, int m, int d) => DateTime(y, m, d, 12);

  late Map<String, String> disk;
  late StreakStore store;
  late List<({int current, int best, String json})> pushes;

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

  Future<bool> recordingPush(int current, int best, String json) async {
    pushes.add((current: current, best: best, json: json));
    return true;
  }

  setUp(() {
    disk = {};
    pushes = [];
    store = wireStore();
  });

  test('founder migration: counters-only pull (14/68, no blob) is '
      'adopted as the base and pushed back as a full record', () async {
    final s = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 14,
      seedBest: 68,
      seedStateJson: null,
      now: at(2026, 11, 5),
      push: recordingPush,
    );
    expect(s.seeded, isTrue);
    expect(streakCurrent(s, at(2026, 11, 5)), 14);
    expect(streakBest(s), 68);
    // The settled record returns to the server exactly once, with
    // the adopted counters and a 14-day counted run ending today.
    expect(pushes, hasLength(1));
    expect(pushes.single.current, 14);
    expect(pushes.single.best, 68);
    final blob = StreakState.fromJson(
        jsonDecode(pushes.single.json) as Map<String, dynamic>);
    expect(blob.countedDays, hasLength(14));
    expect(blob.countedDays.contains('2026-11-05'), isTrue);
    expect(blob.countedDays.contains('2026-10-23'), isTrue);
  });

  test('fresh-install adoption: a server blob is adopted wholesale '
      'and the run continues — never a fresh 1', () async {
    // Server record settled Nov 4: run Oct 22 – Nov 4 (14 days).
    final serverState = streakEvaluate(
      streakSeed(current: 14, best: 68, now: at(2026, 11, 4)),
      at(2026, 11, 4),
    );
    final serverJson = jsonEncode(serverState.toJson());

    // Brand-new install: empty disk, first ever settle.
    final s = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 14,
      seedBest: 68,
      seedStateJson: serverJson,
      now: at(2026, 11, 5),
      push: recordingPush,
    );
    expect(s.seeded, isTrue);
    expect(streakCurrent(s, at(2026, 11, 5)), 15);
    expect(streakBest(s), 68);
    expect(pushes.single.current, 15);
  });

  test('anti-fabrication: no local record + failed pull evaluates '
      'NOTHING (no minted 1, no persist, no push)', () async {
    final s = await store.recordOpen(
      pullSucceeded: false,
      seedCurrent: null,
      seedBest: null,
      seedStateJson: null,
      now: at(2026, 11, 5),
      push: recordingPush,
    );
    expect(s.seeded, isFalse);
    expect(streakCurrent(s, at(2026, 11, 5)), 0);
    expect(store.state, isNull);
    expect(disk.containsKey(StreakStore.storageKey), isFalse);
    expect(pushes, isEmpty);
  });

  test('confirmed-empty server record: a genuinely new account '
      'starts at 1 (the legacy first-open rule)', () async {
    final s = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: null,
      seedBest: null,
      seedStateJson: null,
      now: at(2026, 11, 5),
      push: recordingPush,
    );
    expect(s.seeded, isTrue);
    expect(streakCurrent(s, at(2026, 11, 5)), 1);
    expect(pushes.single.current, 1);
  });

  test('offline open with an existing local record still counts '
      'the day and pushes nothing', () async {
    await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 6,
      seedBest: 12,
      seedStateJson: null,
      now: at(2026, 11, 4),
      push: recordingPush,
    );
    pushes.clear();
    final s = await store.recordOpen(
      pullSucceeded: false,
      seedCurrent: null,
      seedBest: null,
      seedStateJson: null,
      now: at(2026, 11, 5),
      push: recordingPush,
    );
    expect(s.seeded, isTrue);
    expect(streakCurrent(s, at(2026, 11, 5)), 7);
    expect(pushes, isEmpty);
  });

  test('a local record strictly newer than the server blob is '
      'kept and re-pushed (a lost push self-heals)', () async {
    // Local settled through Nov 5 (its push never landed).
    final local = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 6,
      seedBest: 12,
      seedStateJson: null,
      now: at(2026, 11, 5),
      push: recordingPush,
    );
    expect(streakCurrent(local, at(2026, 11, 5)), 6);
    pushes.clear();

    // Next open: the server still holds the older Nov 4 blob.
    final olderServer = streakSeed(current: 5, best: 12, now: at(2026, 11, 4));
    final s = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 5,
      seedBest: 12,
      seedStateJson: jsonEncode(olderServer.toJson()),
      now: at(2026, 11, 5),
      push: recordingPush,
    );
    expect(streakCurrent(s, at(2026, 11, 5)), 6);
    expect(pushes, hasLength(1));
    expect(pushes.single.current, 6);
  });

  test('restore flows through the store: a single missed day is '
      'bridged, marked restored, and pushed in the record', () async {
    // Run ends Nov 2; November save unused.
    final seeded = streakSeed(current: 5, best: 12, now: at(2026, 11, 2));
    final s = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 5,
      seedBest: 12,
      seedStateJson: jsonEncode(seeded.toJson()),
      now: at(2026, 11, 4), // Nov 3 missed
      push: recordingPush,
    );
    expect(s.restoredDays, contains('2026-11-03'));
    expect(s.consumedSaveMonths, contains('2026-11'));
    expect(streakCurrent(s, at(2026, 11, 4)), 7);
    final pushedBlob = StreakState.fromJson(
        jsonDecode(pushes.single.json) as Map<String, dynamic>);
    expect(pushedBlob.restoredDays, contains('2026-11-03'));
    expect(pushes.single.current, 7);
  });

  test('persistence round-trip: a cold store reads the identical '
      'settled state back from disk', () async {
    final s = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 6,
      seedBest: 12,
      seedStateJson: null,
      now: at(2026, 11, 4),
      push: recordingPush,
    );
    await store.persist();
    expect(disk.containsKey(StreakStore.storageKey), isTrue);

    final cold = wireStore();
    final back = await cold.recordOpen(
      pullSucceeded: false,
      seedCurrent: null,
      seedBest: null,
      seedStateJson: null,
      now: at(2026, 11, 4),
      push: recordingPush,
    );
    expect(back, s);
    expect(streakCurrent(back, at(2026, 11, 4)), 6);
    expect(streakBest(back), 12);
  });

  test('owner binding: another account\'s blob never surfaces',
      () async {
    await store.clearIfOwnerMismatch('owner@example.test');
    await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 6,
      seedBest: 12,
      seedStateJson: null,
      now: at(2026, 11, 4),
      push: recordingPush,
    );
    await store.persist();

    final cold = wireStore();
    await cold.clearIfOwnerMismatch('someone-else@example.test');
    final s = await cold.recordOpen(
      pullSucceeded: false,
      seedCurrent: null,
      seedBest: null,
      seedStateJson: null,
      now: at(2026, 11, 4),
      push: recordingPush,
    );
    // The other account's record was wiped by the claim: with no
    // pull confirmation there is nothing to show and nothing is
    // fabricated.
    expect(s.seeded, isFalse);
    expect(streakCurrent(s, at(2026, 11, 4)), 0);
  });
}
