import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';

/// StreakStore v2 (streak upgrade, Nov 18, 2026): recordOpen
/// settles but never counts; recordSummaryComplete is the only
/// counted-day path, with anti-fabrication parity; the A2
/// purchased-freeze field-level merge and the justified-decrease
/// push.
void main() {
  DateTime at(int y, int m, int d) => DateTime(y, m, d, 12);

  late Map<String, String> disk;
  late StreakStore store;
  late List<({int current, int best, String json, int? purchased})> pushes;

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
    pushes.add((
      current: current,
      best: best,
      json: json,
      purchased: purchasedFreezes,
    ));
    return true;
  }

  void seedDisk(StreakState s) {
    disk[StreakStore.storageKey] = jsonEncode({
      'ownerEmail': null,
      'state': s.toJson(),
    });
  }

  setUp(() {
    disk = {};
    pushes = [];
    store = wireStore();
  });

  group('recordSummaryComplete', () {
    test('anti-fabrication parity: no pull + no local record = '
        'no counted day, no persist, no push', () async {
      final out = await store.recordSummaryComplete(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: at(2026, 11, 5),
        summaryDay: at(2026, 11, 5),
        push: recordingPush,
      );
      expect(out.state.seeded, isFalse);
      expect(out.completion, isNull);
      expect(store.state, isNull);
      expect(disk.containsKey(StreakStore.storageKey), isFalse);
      expect(pushes, isEmpty);
    });

    test('confirmed-empty server record: the first completion '
        'counts 1', () async {
      final out = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: at(2026, 11, 5),
        summaryDay: at(2026, 11, 5),
        push: recordingPush,
      );
      expect(out.state.seeded, isTrue);
      expect(out.completion!.newCount, 1);
      expect(out.state.countedDays, {'2026-11-05'});
      expect(pushes.single.current, 1);
      expect(pushes.single.purchased, isNull);
    });

    test('offline completion on an existing local record counts '
        'the summary day', () async {
      // Adopt 6/12 at Nov 4: the assumed run ends Nov 3.
      await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 6,
        seedBest: 12,
        seedStateJson: null,
        now: at(2026, 11, 4),
        push: recordingPush,
      );
      pushes.clear();
      final out = await store.recordSummaryComplete(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: at(2026, 11, 4),
        summaryDay: at(2026, 11, 4),
        push: recordingPush,
      );
      expect(out.completion!.newCount, 7);
      expect(out.state.countedDays, contains('2026-11-04'));
      expect(pushes, isEmpty); // offline: nothing pushed
    });

    test('counters-only completion seeding anchors the attested '
        'run on the summary day (A6)', () async {
      final out = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: 14,
        seedBest: 68,
        seedStateJson: null,
        now: at(2026, 11, 5),
        summaryDay: at(2026, 11, 5),
        push: recordingPush,
      );
      expect(out.state.countedDays, hasLength(14));
      expect(out.state.countedDays, contains('2026-11-05'));
      expect(out.completion!.newCount, 14);
      expect(streakBest(out.state), 68);
    });

    test('a completion between 00:00–03:59 counts the still-open '
        'Tabs day (D2 seam)', () async {
      final out = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: DateTime(2026, 11, 6, 2, 30),
        summaryDay: DateTime(2026, 11, 5, 4), // Nov 5 feeling day
        push: recordingPush,
      );
      expect(out.state.countedDays, {'2026-11-05'});
      expect(out.completion!.newCount, 1);
    });
  });

  group('A2: purchased-freeze merge + justified-decrease push', () {
    StreakState heldState({
      required int purchased,
      required String lastDay,
      Set<String> counted = const {'2026-11-01', '2026-11-02'},
    }) => StreakState(
      seeded: true,
      seededCurrent: 2,
      seededBest: 12,
      countedDays: counted,
      purchasedFreezes: purchased,
      accrualMonth: '2026-11',
      lastEvaluatedDay: lastDay,
    );

    test('a settle that consumes a purchased freeze pushes the '
        'decreased count in the SAME push', () async {
      final server = heldState(purchased: 1, lastDay: '2026-11-02');
      seedDisk(server);
      final s = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 2,
        seedBest: 12,
        seedStateJson: jsonEncode(server.toJson()),
        seedPurchasedFreezes: 1,
        now: at(2026, 11, 4), // Nov 3 missed → purchased bridges it
        push: recordingPush,
      );
      expect(s.restoredDays, contains('2026-11-03'));
      expect(s.purchasedFreezes, 0);
      expect(pushes, hasLength(1));
      expect(pushes.single.purchased, 0);
      final blob = StreakState.fromJson(
        jsonDecode(pushes.single.json) as Map<String, dynamic>,
      );
      expect(blob.purchasedFreezes, 0);
      expect(blob.restoredDays, contains('2026-11-03'));
    });

    test('a settle with NO purchased consumption sends no '
        'purchased_freezes field', () async {
      final server = heldState(purchased: 1, lastDay: '2026-11-02');
      seedDisk(server);
      final s = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 2,
        seedBest: 12,
        seedStateJson: jsonEncode(server.toJson()),
        seedPurchasedFreezes: 1,
        now: at(2026, 11, 3), // consecutive — nothing consumed
        push: recordingPush,
      );
      expect(s.purchasedFreezes, 1);
      expect(pushes.single.purchased, isNull);
    });

    test('the server column wins when the server record\'s stamp '
        'is at least the local one', () async {
      // Local blob says the purchased freeze is gone (stamp
      // Nov 2); the server record is newer (stamp Nov 5) and its
      // column still holds 1 — the column governs.
      seedDisk(heldState(purchased: 0, lastDay: '2026-11-02'));
      final server = heldState(
        purchased: 0,
        lastDay: '2026-11-05',
        counted: {'2026-11-04', '2026-11-05'},
      );
      final s = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 2,
        seedBest: 12,
        seedStateJson: jsonEncode(server.toJson()),
        seedPurchasedFreezes: 1,
        now: at(2026, 11, 6),
        push: recordingPush,
      );
      expect(s.purchasedFreezes, 1);
    });

    test('a strictly newer local blob keeps its purchased count '
        'over a lower server column (no resurrection, no loss)', () async {
      // Local settled Nov 6 still holding the freeze; the server
      // blob is older (Nov 5) and its column reads 0 — the local
      // blob's value governs per the stamp formula.
      seedDisk(
        heldState(
          purchased: 1,
          lastDay: '2026-11-06',
          counted: {'2026-11-05', '2026-11-06'},
        ),
      );
      final server = heldState(
        purchased: 0,
        lastDay: '2026-11-05',
        counted: {'2026-11-04', '2026-11-05'},
      );
      final s = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 2,
        seedBest: 12,
        seedStateJson: jsonEncode(server.toJson()),
        seedPurchasedFreezes: 0,
        now: at(2026, 11, 6),
        push: recordingPush,
      );
      expect(s.purchasedFreezes, 1);
    });
  });
}
