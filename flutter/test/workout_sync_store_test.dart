import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/workout_sync_store.dart';

/// WorkoutSyncStore pins (workout sync package, DESIGN §7):
/// link round-trip, the decision-4 tombstone strip, reverse
/// lookup, and the owner-bound discipline (foreign blob dropped,
/// unowned blob never adopted ownerless).
void main() {
  WorkoutSyncStore makeStore(Map<String, String> disk) {
    final store = WorkoutSyncStore.testInstance();
    store.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    return store;
  }

  Map<String, dynamic> blobOf(Map<String, String> disk) =>
      jsonDecode(disk[WorkoutSyncStore.storageKey]!)
          as Map<String, dynamic>;

  group('links', () {
    test('link write/read round-trip across a fresh instance', () async {
      final disk = <String, String>{};
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      await store.recordLink(
        key: 'hc:uuid-1',
        entryId: 581,
        state: WorkoutLinkState.linked,
        origin: WorkoutLinkOrigin.synced,
        hcId: 'uuid-1',
      );
      await store.markSynced(123456);

      final fresh = makeStore(disk);
      await fresh.warmFromDisk(currentEmail: 'a@example.com');
      final link = fresh.linkForKey('hc:uuid-1');
      expect(link, isNotNull);
      expect(link!.state, WorkoutLinkState.linked);
      expect(link.entryId, 581);
      expect(link.origin, WorkoutLinkOrigin.synced);
      expect(link.hcId, 'uuid-1');
      expect(fresh.lastSyncMs, 123456);
      expect(fresh.ownerEmail, 'a@example.com');
    });

    test('reverse lookup entryId → session key', () async {
      final disk = <String, String>{};
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      await store.recordLink(
        key: 'hc:uuid-9',
        entryId: 42,
        state: WorkoutLinkState.adopted,
        origin: WorkoutLinkOrigin.manual,
      );
      expect(store.keyForEntry(42), 'hc:uuid-9');
      expect(store.linkForEntry(42)?.state, WorkoutLinkState.adopted);
      expect(store.linkForEntry(43), isNull);
      expect(store.keyForEntry(43), isNull);
    });
  });

  group('tombstone (DECISIONS decision 4 — the strip)', () {
    test('tombstone reduces the record to {state} only and persists',
        () async {
      final disk = <String, String>{};
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      await store.recordLink(
        key: 'hc:uuid-1',
        entryId: 581,
        state: WorkoutLinkState.linked,
        origin: WorkoutLinkOrigin.synced,
        hcId: 'uuid-1',
      );

      final prior = await store.tombstoneForEntry(581);
      expect(prior, isNotNull);
      expect(prior!.key, 'hc:uuid-1');
      expect(prior.link.entryId, 581);

      // In memory: stripped, reverse entry gone.
      final link = store.linkForKey('hc:uuid-1');
      expect(link, isNotNull);
      expect(link!.state, WorkoutLinkState.tombstoned);
      expect(link.entryId, isNull);
      expect(link.hcId, isNull);
      expect(link.origin, isNull);
      expect(store.linkForEntry(581), isNull);
      expect(store.keyForEntry(581), isNull);

      // On disk: the blob row is EXACTLY {state: tombstoned} —
      // entryId, hcId, and every other field are dropped; only
      // the map key (the session identifier) + the flag survive.
      final blob = blobOf(disk);
      expect(blob['links'], {
        'hc:uuid-1': {'state': 'tombstoned'},
      });

      // And across a fresh instance over the same disk.
      final fresh = makeStore(disk);
      await fresh.warmFromDisk(currentEmail: 'a@example.com');
      expect(fresh.linkForKey('hc:uuid-1')!.state,
          WorkoutLinkState.tombstoned);
      expect(fresh.linkForEntry(581), isNull);
    });

    test('restoreLink brings back the exact prior record', () async {
      final disk = <String, String>{};
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      await store.recordLink(
        key: 'hc:uuid-2',
        entryId: 77,
        state: WorkoutLinkState.adopted,
        origin: WorkoutLinkOrigin.manual,
        hcId: 'uuid-2',
      );
      final prior = await store.tombstoneForEntry(77);
      await store.restoreLink(prior!.key, prior.link);
      final link = store.linkForKey('hc:uuid-2');
      expect(link!.state, WorkoutLinkState.adopted);
      expect(link.entryId, 77);
      expect(link.origin, WorkoutLinkOrigin.manual);
      expect(store.keyForEntry(77), 'hc:uuid-2');
      // The restore persisted too.
      final fresh = makeStore(disk);
      await fresh.warmFromDisk(currentEmail: 'a@example.com');
      expect(fresh.linkForEntry(77)?.state, WorkoutLinkState.adopted);
    });

    test('tombstone of an unlinked entry is a no-op null', () async {
      final disk = <String, String>{};
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      expect(await store.tombstoneForEntry(999), isNull);
      expect(disk.containsKey(WorkoutSyncStore.storageKey), isFalse);
    });
  });

  group('owner binding', () {
    Map<String, String> seededDisk({String? owner}) => {
          WorkoutSyncStore.storageKey: jsonEncode({
            'ownerEmail': owner,
            'links': {
              'hc:uuid-1': {
                'state': 'linked',
                'entryId': 581,
                'origin': 'synced',
                'hcId': 'uuid-1',
              },
            },
          }),
        };

    test('foreign owner blob is dropped, never adopted', () async {
      final disk = seededDisk(owner: 'other@example.com');
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      expect(store.links, isEmpty);
      expect(store.ownerEmail, 'a@example.com');
      expect(disk.containsKey(WorkoutSyncStore.storageKey), isFalse);
    });

    test('clearIfOwnerMismatch drops a foreign store', () async {
      final disk = seededDisk(owner: 'other@example.com');
      final store = makeStore(disk);
      await store.warmFromDisk(); // unbound warm adopts the blob
      expect(store.links, hasLength(1));
      final dropped = await store.clearIfOwnerMismatch('a@example.com');
      expect(dropped, isTrue);
      expect(store.links, isEmpty);
      expect(store.ownerEmail, 'a@example.com');
    });

    test('matching owner keeps everything', () async {
      final disk = seededDisk(owner: 'a@example.com');
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      expect(store.links, hasLength(1));
      expect(await store.clearIfOwnerMismatch('a@example.com'), isFalse);
      expect(store.links, hasLength(1));
    });

    test('unowned blob is not adopted ownerless (C-01/F3 shape)',
        () async {
      final disk = seededDisk(owner: null);
      final store = makeStore(disk);
      // Unbound warm: the data is readable but flagged
      // owner-unverified — the store never claims it as
      // ownerless-owned, and a later account claim drops it.
      await store.warmFromDisk();
      expect(store.ownerEmail, isNull);
      expect(store.warmLoadedUnownedData, isTrue);
      final dropped = await store.clearIfOwnerMismatch('a@example.com');
      expect(dropped, isTrue);
      expect(store.links, isEmpty);
    });

    test('unowned populated blob under a known account is dropped',
        () async {
      final disk = seededDisk(owner: null);
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      expect(store.links, isEmpty);
      expect(store.ownerEmail, 'a@example.com');
      expect(disk.containsKey(WorkoutSyncStore.storageKey), isFalse);
    });

    test('unowned EMPTY blob binds to the known account', () async {
      final disk = <String, String>{
        WorkoutSyncStore.storageKey: jsonEncode({
          'ownerEmail': null,
          'links': <String, dynamic>{},
        }),
      };
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      expect(store.ownerEmail, 'a@example.com');
      expect(store.warmLoadedUnownedData, isFalse);
    });
  });

  group('run record (ROUND 3 diagnostics)', () {
    const record = WorkoutSyncRunRecord(
      startedAtMs: 1000,
      finishedAtMs: 2000,
      stage: 'done',
      grantVerdict: 'granted',
      sessionsRead: 28,
      entriesCreated: 27,
      entriesAdopted: 1,
      sessionsSkipped: 1,
      readPartial: true,
      abortCode: 'StateError',
    );

    void expectRecord(WorkoutSyncRunRecord? actual) {
      expect(actual, isNotNull);
      expect(actual!.startedAtMs, record.startedAtMs);
      expect(actual.finishedAtMs, record.finishedAtMs);
      expect(actual.stage, record.stage);
      expect(actual.grantVerdict, record.grantVerdict);
      expect(actual.sessionsRead, record.sessionsRead);
      expect(actual.entriesCreated, record.entriesCreated);
      expect(actual.entriesAdopted, record.entriesAdopted);
      expect(actual.sessionsSkipped, record.sessionsSkipped);
      expect(actual.readPartial, record.readPartial);
      expect(actual.abortCode, record.abortCode);
    }

    test('recordRun persists; a fresh instance reads it back '
        'identically', () async {
      final disk = <String, String>{};
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      await store.recordRun(record);
      expectRecord(store.lastRun);

      final fresh = makeStore(disk);
      await fresh.warmFromDisk(currentEmail: 'a@example.com');
      expectRecord(fresh.lastRun);
    });

    test('malformed lastRun blob value loads as null record and '
        'the store still works', () async {
      final disk = <String, String>{
        WorkoutSyncStore.storageKey: jsonEncode({
          'ownerEmail': 'a@example.com',
          'lastRun': 'not-a-record',
          'links': {
            'hc:uuid-1': {
              'state': 'linked',
              'entryId': 581,
              'origin': 'synced',
              'hcId': 'uuid-1',
            },
          },
        }),
      };
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      expect(store.lastRun, isNull);
      expect(store.links, hasLength(1));
      // Still fully functional: a new record records + persists.
      await store.recordRun(record);
      expectRecord(store.lastRun);
      final fresh = makeStore(disk);
      await fresh.warmFromDisk(currentEmail: 'a@example.com');
      expectRecord(fresh.lastRun);
      expect(fresh.links, hasLength(1));
    });

    test('record coexists with links; the tombstone strip is '
        'untouched by it', () async {
      final disk = <String, String>{};
      final store = makeStore(disk);
      await store.warmFromDisk(currentEmail: 'a@example.com');
      await store.recordRun(record);
      await store.recordLink(
        key: 'hc:uuid-1',
        entryId: 581,
        state: WorkoutLinkState.linked,
        origin: WorkoutLinkOrigin.synced,
        hcId: 'uuid-1',
      );
      await store.tombstoneForEntry(581);

      final blob = blobOf(disk);
      // The tombstoned link's JSON still carries ONLY {state}.
      expect(blob['links'], {
        'hc:uuid-1': {'state': 'tombstoned'},
      });
      // And the record rides alongside, counts/codes only.
      final lastRun = blob['lastRun'] as Map<String, dynamic>;
      expect(lastRun['stage'], 'done');
      expect(lastRun['entriesCreated'], 27);
      expect(lastRun['abortCode'], 'StateError');
    });
  });
}
