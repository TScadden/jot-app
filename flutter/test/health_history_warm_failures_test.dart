import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';

/// H1-04 part B — warm-failure data loss in [HealthHistoryStore].
///
/// warmFromDisk used to wrap BOTH the storage read and the JSON
/// decode in a single catch: a TRANSIENT read throw (disk blob
/// perfectly valid) was treated exactly like a corrupt blob —
/// the store marked itself warmed with empty memory — and the
/// next capture's persist() then overwrote the on-disk blob
/// with only the new window, erasing older history (imported
/// CSV history beyond the Health Connect windows, unsynced
/// score provenance).
///
/// The fix splits the catches: a read throw leaves the store
/// NOT warmed (the next _ensureWarmed retries the read) and
/// persist() is a no-op until a warm has succeeded, so the
/// on-disk blob stays byte-identical. A decode/shape failure
/// (blob provably corrupt) keeps the R70 fix-D behavior
/// exactly: bind the known session owner, warm, start empty.

/// In-memory fake whose read can be made to throw (a transient
/// storage/transport failure) while the stored blob stays valid.
class _FlakyStore {
  final Map<String, String> values = {};
  bool throwOnRead = false;
  int readAttempts = 0;

  Future<String?> read(String key) async {
    readAttempts++;
    if (throwOnRead) throw StateError('transient storage failure');
    return values[key];
  }

  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

HealthHistoryStore _storeOver(_FlakyStore fake) {
  final s = HealthHistoryStore.testInstance();
  s.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return s;
}

void main() {
  late _FlakyStore fake;

  setUp(() {
    fake = _FlakyStore();
  });

  /// Seeds a valid, owned, populated blob: three days — one far
  /// outside any Health Connect window (imported-history shape)
  /// and one carrying a Daily Score (score provenance) — and
  /// returns the exact persisted blob string.
  Future<String> seedValidBlob() async {
    final seed = _storeOver(fake);
    await seed.mergeRefresh(const [
      DailyBiometrics(date: '2025-01-15', restingHrBpm: 58, sleepMinutes: 430),
      DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      DailyBiometrics(date: '2026-10-02', restingHrBpm: 61),
    ]);
    seed.bindToAccount('Owner@Example.com');
    expect(
      await seed.persistScore('2026-10-01', dailyScore: 77, scoreSleep: 80),
      isTrue,
    );
    await seed.persist();
    final blob = fake.values[HealthHistoryStore.storageKey]!;
    expect(jsonDecode(blob)['ownerEmail'], 'owner@example.com');
    return blob;
  }

  group('transient read failure (part B)', () {
    test('throwing read against a VALID blob: warm does not '
        'complete, persist writes nothing, and a later successful '
        'warm loads the full original history', () async {
      final originalBlob = await seedValidBlob();

      fake.throwOnRead = true;
      final store = _storeOver(fake);
      await store.warmFromDisk(currentEmail: 'owner@example.com');

      // Nothing was loaded, and a direct persist must not touch
      // the disk: the blob stays byte-identical.
      expect(await store.dayCount(), 0);
      await store.persist();
      expect(fake.values[HealthHistoryStore.storageKey], originalBlob);

      // The capture shape: a merge during the failed window must
      // not overwrite the blob with just the new window either.
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-03', restingHrBpm: 62),
      ]);
      expect(fake.values[HealthHistoryStore.storageKey], originalBlob);

      // The read recovers: the next warm retries and loads the
      // FULL original history, unioned with the in-memory merge.
      fake.throwOnRead = false;
      await store.warmFromDisk(currentEmail: 'owner@example.com');
      final all = await store.readAll();
      expect(all.length, 4);
      expect(all['2025-01-15']!.restingHrBpm, 58);
      expect(all['2025-01-15']!.sleepMinutes, 430);
      expect(all['2026-10-01']!.restingHrBpm, 60);
      expect(all['2026-10-01']!.dailyScore, 77); // provenance kept
      expect(all['2026-10-01']!.scoreSleep, 80);
      expect(all['2026-10-02']!.restingHrBpm, 61);
      expect(all['2026-10-03']!.restingHrBpm, 62);
      expect(store.ownerEmail, 'owner@example.com');

      // And a persist now writes the full union, owner intact.
      await store.persist();
      final decoded = jsonDecode(
        fake.values[HealthHistoryStore.storageKey]!,
      ) as Map<String, dynamic>;
      expect((decoded['days'] as Map).length, 4);
      expect(decoded['ownerEmail'], 'owner@example.com');
    });

    test('throwing read with NO account known: still no persist, '
        'blob byte-identical', () async {
      final originalBlob = await seedValidBlob();

      fake.throwOnRead = true;
      final store = _storeOver(fake);
      await store.warmFromDisk();
      await store.markCaptured(123456789);
      expect(fake.values[HealthHistoryStore.storageKey], originalBlob);

      fake.throwOnRead = false;
      await store.warmFromDisk();
      expect(await store.dayCount(), 3);
    });
  });

  group('corrupt blob keeps fix-D behavior exactly (part B)', () {
    test('undecodable blob + known session email: warm binds, '
        'starts empty, capture survives a simulated cold start', () async {
      fake.values[HealthHistoryStore.storageKey] = '{{{ not json';
      final store = _storeOver(fake);
      await store.warmFromDisk(currentEmail: 'owner@example.com');
      expect(store.ownerEmail, 'owner@example.com');
      expect(await store.dayCount(), 0);

      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-02', restingHrBpm: 61),
      ]);

      final cold = _storeOver(fake);
      await cold.warmFromDisk(currentEmail: 'owner@example.com');
      expect(cold.ownerEmail, 'owner@example.com');
      expect(await cold.dayCount(), 1);
      expect((await cold.readAll())['2026-10-02']!.restingHrBpm, 61);
    });

    test('valid JSON with the wrong shape (a list, not a map) is '
        'a decode failure, not a read failure: fix-D applies', () async {
      fake.values[HealthHistoryStore.storageKey] = '[1, 2, 3]';
      final store = _storeOver(fake);
      await store.warmFromDisk(currentEmail: 'owner@example.com');
      expect(store.ownerEmail, 'owner@example.com');
      expect(await store.dayCount(), 0);

      // Warmed (unlike the read-throw path): a persist is live
      // and stamps the bound owner over the corrupt blob.
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-02', restingHrBpm: 61),
      ]);
      final decoded = jsonDecode(
        fake.values[HealthHistoryStore.storageKey]!,
      ) as Map<String, dynamic>;
      expect(decoded['ownerEmail'], 'owner@example.com');
      expect((decoded['days'] as Map).length, 1);
    });
  });
}
