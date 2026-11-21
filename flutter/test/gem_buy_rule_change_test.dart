import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';

/// Gem-buy rule change (Nov 21, 2026) — adoption/clamp pins.
///
/// Founder direction: gems can buy a streak freeze while a
/// purchased freeze is held, never over the cap. Class decision:
/// gem-bought freezes join the PURCHASED-CLASS bucket
/// (`purchasedFreezes`), so a server count of 2 or 3 is now
/// legitimate on every adoption surface. Before this change every
/// surface clamped the adopted count to 0..1, which would have
/// silently eaten gem-bought freezes; these pins hold every
/// clamp/adoption site at the true 0..3 bound.
void main() {
  group('StreakState persistence (fromJson/toJson)', () {
    test('purchasedFreezes 2 and 3 survive a JSON round-trip', () {
      for (final n in [2, 3]) {
        final s = StreakState(
          seeded: true,
          seededCurrent: 5,
          seededBest: 12,
          countedDays: const {'2026-11-18'},
          accrualMonth: '2026-11',
          lastEvaluatedDay: '2026-11-18',
          purchasedFreezes: n,
        );
        final back = StreakState.fromJson(s.toJson());
        expect(back.purchasedFreezes, n,
            reason: 'purchased-class count $n must not clamp to 1 '
                'on reload');
      }
    });

    test('the earned bucket keeps its 0..1 bound (the split is '
        'deliberate: freeze earning is untouched by this change)',
        () {
      final s = StreakState(
        seeded: true,
        seededCurrent: 5,
        seededBest: 12,
        countedDays: const {'2026-11-18'},
        accrualMonth: '2026-11',
        lastEvaluatedDay: '2026-11-18',
        earnedFreezes: 2,
      );
      final back = StreakState.fromJson(s.toJson());
      expect(back.earnedFreezes, 1);
    });
  });

  group('profile-pull seeding', () {
    test('streakSeedForAdoption keeps purchasedFreezes 2 and 3',
        () {
      for (final n in [2, 3]) {
        final s = streakSeedForAdoption(
          current: 5,
          best: 12,
          now: DateTime(2026, 11, 19, 12),
          purchasedFreezes: n,
        );
        expect(s.purchasedFreezes, n);
      }
    });

    test('streakSeedForCompletion keeps purchasedFreezes 3', () {
      final s = streakSeedForCompletion(
        current: 5,
        best: 12,
        summaryTabsDay: '2026-11-19',
        purchasedFreezes: 3,
      );
      expect(s.purchasedFreezes, 3);
    });
  });

  group('StreakStore adoption', () {
    late Map<String, String> disk;
    late StreakStore store;
    final pushes = <String>[];

    Future<bool> push(
      int current,
      int best,
      String json, {
      int? purchasedFreezes,
    }) async {
      pushes.add(json);
      return true;
    }

    setUp(() {
      disk = {};
      pushes.clear();
      store = StreakStore.instance;
      store.debugReset();
      store.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
        delete: (key) async {
          disk.remove(key);
        },
      );
    });

    tearDown(() => store.debugReset());

    Future<void> seedLocalRecord() async {
      disk[StreakStore.storageKey] = jsonEncode({
        'ownerEmail': null,
        'state': StreakState(
          seeded: true,
          seededCurrent: 5,
          seededBest: 12,
          countedDays: const {'2026-11-18'},
          accrualMonth: '2026-11',
          lastEvaluatedDay: '2026-11-18',
          purchasedFreezes: 1,
        ).toJson(),
      });
      await store.ensureLoaded();
      expect(store.state!.purchasedFreezes, 1);
    }

    test('adoptPurchasedFreezes(2) and (3) land unclamped and '
        'persist', () async {
      await seedLocalRecord();
      await store.adoptPurchasedFreezes(2);
      expect(store.state!.purchasedFreezes, 2);
      await store.adoptPurchasedFreezes(3);
      expect(store.state!.purchasedFreezes, 3);
      // The persisted blob carries the full count too.
      final raw = jsonDecode(disk[StreakStore.storageKey]!);
      final persisted =
          StreakState.fromJson(raw['state'] as Map<String, dynamic>);
      expect(persisted.purchasedFreezes, 3);
    });

    test('the A2 profile adoption merge keeps a server column '
        'of 2 and of 3', () async {
      for (final n in [2, 3]) {
        store.debugReset();
        disk.clear();
        final blob = jsonEncode(
          StreakState(
            seeded: true,
            seededCurrent: 27,
            seededBest: 68,
            countedDays: {
              for (var i = 0; i < 27; i++)
                streakDayStr(DateTime(2026, 11, 18)
                    .subtract(Duration(days: i))),
            },
            restoredDays: const {'2026-11-07'},
            consumedSaveMonths: const {'2026-11'},
            spoiledMonths: const {'2026-11'},
            accrualMonth: '2026-11',
            lastEvaluatedDay: '2026-11-18',
          ).toJson(),
        );
        final s = await store.recordOpen(
          pullSucceeded: true,
          seedCurrent: 27,
          seedBest: 68,
          seedStateJson: blob,
          seedPurchasedFreezes: n,
          now: DateTime(2026, 11, 18, 19),
          push: push,
        );
        expect(s.purchasedFreezes, n,
            reason: 'server purchased column $n must survive the '
                'adoption merge');
      }
    });
  });
}
