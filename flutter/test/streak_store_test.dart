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

  Future<bool> recordingPush(
    int current,
    int best,
    String json, {
    int? purchasedFreezes,
  }) async {
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
    // the adopted counters. V2 (A6): adoption seeding anchors the
    // assumed run on the PRIOR Tabs day — Nov 5 is not counted
    // (no summary has completed), so the 14-day run ends Nov 4.
    expect(pushes, hasLength(1));
    expect(pushes.single.current, 14);
    expect(pushes.single.best, 68);
    final blob = StreakState.fromJson(
      jsonDecode(pushes.single.json) as Map<String, dynamic>,
    );
    expect(blob.countedDays, hasLength(14));
    expect(blob.countedDays.contains('2026-11-05'), isFalse);
    expect(blob.countedDays.contains('2026-11-04'), isTrue);
    expect(blob.countedDays.contains('2026-10-22'), isTrue);
  });

  test('fresh-install adoption: a server blob is adopted wholesale '
      'and the run survives — never a fresh 1', () async {
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
    // V2 (D1/D3): app-open settles but never counts Nov 5 — the
    // adopted 14-day run stands, still alive through yesterday.
    expect(streakCurrent(s, at(2026, 11, 5)), 14);
    expect(streakBest(s), 68);
    expect(pushes.single.current, 14);
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
      'counts NOTHING at open under v2 (first completion counts 1)', () async {
    final s = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: null,
      seedBest: null,
      seedStateJson: null,
      now: at(2026, 11, 5),
      push: recordingPush,
    );
    expect(s.seeded, isTrue);
    expect(streakCurrent(s, at(2026, 11, 5)), 0);
    expect(s.countedDays, isEmpty);
    expect(pushes.single.current, 0);
  });

  test('offline open with an existing local record settles the '
      'gap (bridging a missed day) but counts no new day', () async {
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
    // Adoption seeded the run ending Nov 3 (6 days); the Nov 5
    // settle bridges missed Nov 4 with November's monthly grant,
    // so the run reads 7 — but Nov 5 itself is NOT counted.
    expect(s.restoredDays, contains('2026-11-04'));
    expect(s.countedDays.contains('2026-11-05'), isFalse);
    expect(streakCurrent(s, at(2026, 11, 5)), 7);
    expect(pushes, isEmpty);
  });

  test('a local record strictly newer than the server blob is '
      'kept and re-pushed (a lost push self-heals)', () async {
    // Local: adopted Nov 4 (run ending Nov 3, 6 days), then the
    // Nov 4 summary completes — counted through Nov 4 (7 days),
    // stamped Nov 4. Its push never landed.
    await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 6,
      seedBest: 12,
      seedStateJson: null,
      now: at(2026, 11, 4),
      push: recordingPush,
    );
    final local = (await store.recordSummaryComplete(
      pullSucceeded: false,
      seedCurrent: null,
      seedBest: null,
      seedStateJson: null,
      now: at(2026, 11, 4),
      summaryDay: at(2026, 11, 4),
      push: recordingPush,
    )).state;
    expect(streakCurrent(local, at(2026, 11, 4)), 7);
    pushes.clear();

    // Next open: the server still holds the older Nov 3 blob.
    final olderServer = streakSeed(current: 5, best: 12, now: at(2026, 11, 3));
    final s = await store.recordOpen(
      pullSucceeded: true,
      seedCurrent: 5,
      seedBest: 12,
      seedStateJson: jsonEncode(olderServer.toJson()),
      now: at(2026, 11, 4),
      push: recordingPush,
    );
    expect(streakCurrent(s, at(2026, 11, 4)), 7);
    expect(pushes, hasLength(1));
    expect(pushes.single.current, 7);
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
    // V2: the settle bridges Nov 3 (run now ends Nov 3, 6 days)
    // but does NOT count Nov 4 itself.
    expect(s.countedDays.contains('2026-11-04'), isFalse);
    expect(streakCurrent(s, at(2026, 11, 4)), 6);
    final pushedBlob = StreakState.fromJson(
      jsonDecode(pushes.single.json) as Map<String, dynamic>,
    );
    expect(pushedBlob.restoredDays, contains('2026-11-03'));
    expect(pushes.single.current, 6);
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

  group('C-04: a failed disk read is not an empty disk', () {
    late bool readFails;
    late String trueBlob;

    StreakStore wireFlakyStore() {
      final s = StreakStore.instance;
      s.debugReset();
      s.debugSetStore(
        read: (key) async {
          if (readFails) {
            throw StateError('transient storage failure');
          }
          return disk[key];
        },
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
      readFails = false;
      // The true local record: a 6-day run (Oct 30 – Nov 4) seeded
      // 6/12, settled Nov 4, stamped with its owner.
      // P0 adaptation (Bram, flagged for Vera): Nov 4 is recorded
      // as summary-completed — under the P0 open-day revalidation
      // a counted open day WITHOUT a completion record is a legacy
      // app-open artifact and is stripped at adoption, which is
      // not what these C-04 disk-failure tests are about. With the
      // completion record the fixture is a legitimate v2 record
      // and every assertion below stands unchanged.
      final settled = streakEvaluate(
        streakSeed(current: 6, best: 12, now: at(2026, 11, 4)),
        at(2026, 11, 4),
      ).copyWith(summaryCompletedDays: {'2026-11-04'});
      trueBlob = jsonEncode({
        'ownerEmail': 'owner@example.test',
        'state': settled.toJson(),
      });
    });

    test('read throws on load → recordOpen(pullSucceeded: true) '
        'does not persist, does not push, and the on-disk blob '
        'stays byte-identical', () async {
      disk[StreakStore.storageKey] = trueBlob;
      readFails = true;
      final flaky = wireFlakyStore();

      // The pull carries the server blob (settled Nov 4, 14/68):
      // adopting it and evaluating Nov 5 changes the state, which
      // is exactly the settle that persists + pushes on the buggy
      // path — over the true local 6/12 record.
      final serverState = streakEvaluate(
        streakSeed(current: 14, best: 68, now: at(2026, 11, 4)),
        at(2026, 11, 4),
      );
      final s = await flaky.recordOpen(
        pullSucceeded: true,
        seedCurrent: 14,
        seedBest: 68,
        seedStateJson: jsonEncode(serverState.toJson()),
        now: at(2026, 11, 5),
        push: recordingPush,
      );
      await pumpEventQueue();

      // The failed load must behave like the pullSucceeded: false
      // refusal: no adoption, no fabricated state.
      expect(s.seeded, isFalse);
      expect(flaky.state, isNull);
      expect(pushes, isEmpty);
      expect(disk[StreakStore.storageKey], trueBlob);
    });

    test('after reads recover, the true local record is intact '
        'and normal recordOpen behavior resumes', () async {
      disk[StreakStore.storageKey] = trueBlob;
      readFails = true;
      final flaky = wireFlakyStore();
      await flaky.recordOpen(
        pullSucceeded: true,
        seedCurrent: 14,
        seedBest: 68,
        seedStateJson: null,
        now: at(2026, 11, 5),
        push: recordingPush,
      );
      await pumpEventQueue();

      readFails = false;
      pushes.clear();

      // Same settled day, offline: the intact record surfaces
      // unchanged — the degraded 14/68 re-seed never landed.
      final s = await flaky.recordOpen(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: at(2026, 11, 4),
        push: recordingPush,
      );
      expect(s.seeded, isTrue);
      expect(streakCurrent(s, at(2026, 11, 4)), 6);
      expect(streakBest(s), 12);
      expect(s.countedDays, hasLength(6));
      expect(s.countedDays.contains('2026-11-04'), isTrue);
      expect(disk[StreakStore.storageKey], trueBlob);

      // And the next day settles again, as normal — under v2 the
      // open counts nothing, so the run still reads 6 (alive
      // through yesterday, Nov 4).
      final next = await flaky.recordOpen(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: at(2026, 11, 5),
        push: recordingPush,
      );
      expect(streakCurrent(next, at(2026, 11, 5)), 6);
    });

    test('a failed load never produces a blob stamped '
        'ownerEmail: null, and the owner claim survives it',
        () async {
      disk[StreakStore.storageKey] = trueBlob;
      readFails = true;
      final flaky = wireFlakyStore();

      // The production cold-start ordering: the claim is stamped
      // first (main.dart), then the load runs — and fails.
      await flaky.clearIfOwnerMismatch('owner@example.test');
      // Server-blob pull: adoption + a state-changing evaluation
      // is the settle that, on the buggy path, persists the
      // degraded record stamped with the nulled owner.
      final serverState = streakEvaluate(
        streakSeed(current: 14, best: 68, now: at(2026, 11, 4)),
        at(2026, 11, 4),
      );
      await flaky.recordOpen(
        pullSucceeded: true,
        seedCurrent: 14,
        seedBest: 68,
        seedStateJson: jsonEncode(serverState.toJson()),
        now: at(2026, 11, 5),
        push: recordingPush,
      );
      await pumpEventQueue();

      final raw = disk[StreakStore.storageKey];
      expect(raw, trueBlob);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['ownerEmail'], 'owner@example.test');

      // Because the claim survived, recovery surfaces the owner's
      // record instead of deleting it as foreign on the next load.
      readFails = false;
      final back = await flaky.recordOpen(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: at(2026, 11, 4),
        push: recordingPush,
      );
      expect(back.seeded, isTrue);
      expect(streakCurrent(back, at(2026, 11, 4)), 6);
      expect(streakBest(back), 12);
    });
  });
}
