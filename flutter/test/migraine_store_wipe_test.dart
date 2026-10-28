import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';

/// Audit 4e (Oct 27, 2026) — migraine attack records are
/// account-bound: owner-stamped blob, wiped on logout / account
/// deletion (the AccountActions funnel), on session expiry (the
/// store clear main.dart calls), and on owner mismatch at login,
/// mirroring CoachMemoryStore. An in-progress attack is the
/// departing owner's data and wipes with the rest.
const ownerA = 'a@example.com';
const ownerB = 'b@example.com';

MigraineAttack attack({
  required int start,
  int? end,
  String meds = 'sumatriptan',
}) =>
    MigraineAttack(
      id: start,
      startTimestamp: start,
      endTimestamp: end,
      auraPhase: 'VISUAL',
      medsTaken: meds,
      painPeak: 8,
      reliefRating: 3,
      updatedAt: end ?? start,
    );

void main() {
  final disk = <String, String>{};
  final store = MigraineAttackStore.instance;

  void wireMigraine() {
    store.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
  }

  /// The AccountActions funnel clears every account-bound
  /// singleton; wire them all to in-memory IO (the settings_r29
  /// pattern) so the real funnel completes against fakes.
  void wireFunnelCaches() {
    final cacheDisk = <String, String>{};
    void wire(dynamic cache) => cache.debugSetStore(
          read: (k) async => cacheDisk[k],
          write: (k, v) async => cacheDisk[k] = v,
          delete: (k) async => cacheDisk.remove(k),
        );
    wire(HomeDataCache.instance);
    wire(QuickLogCache.instance);
    wire(HeartDataCache.instance);
    wire(TodaySummaryCache.instance);
    wire(TodayPlanStore.instance);
    wire(CoachMemoryStore.instance);
    wire(KnowledgeExtractionStore.instance);
    wire(HealthHistoryStore.instance);
  }

  setUp(() async {
    disk.clear();
    wireMigraine();
    await store.clear(); // unbinds any owner a prior test bound
    disk.clear();
  });

  group('MigraineAttackStore owner binding (audit 4e)', () {
    test('shared instance: the unnamed constructor returns it',
        () {
      expect(identical(MigraineAttackStore(), MigraineAttackStore.instance),
          isTrue);
    });

    test(
        "owner's records persist, active attack included, blob "
        'stamped with the normalized owner', () async {
      // Bind on empty storage (login on a clean device): no wipe.
      expect(await store.clearIfOwnerMismatch(' A@Example.com '), isFalse);
      final ended = attack(start: 1760000000000, end: 1760003600000);
      final active = attack(start: 1760010000000); // never ended
      await store.save(ended);
      await store.save(active);

      final all = await store.loadAll();
      expect(all.map((a) => a.id),
          containsAll([ended.id, active.id]));
      expect((await store.loadActive())?.id, active.id);
      expect((await store.loadById(ended.id))?.medsTaken, 'sumatriptan');

      final raw = disk[MigraineAttackStore.storageKey];
      expect(raw, isNotNull);
      final blob = jsonDecode(raw!) as Map<String, dynamic>;
      expect(blob['ownerEmail'], ownerA);
    });

    test('gone after the AccountActions wipe funnel (logout / '
        'account deletion), active attack included', () async {
      wireFunnelCaches();
      wireMigraine(); // funnel wiring must not disturb this store
      expect(await store.clearIfOwnerMismatch(ownerA), isFalse);
      await store.save(attack(start: 1760000000000, end: 1760003600000));
      await store.save(attack(start: 1760010000000)); // active
      expect(disk.containsKey(MigraineAttackStore.storageKey), isTrue);

      await AccountActions.clearDefaultCaches();

      expect(disk.containsKey(MigraineAttackStore.storageKey), isFalse);
      expect(await store.loadAll(), isEmpty);
      expect(await store.loadActive(), isNull);
    });

    test('gone after clear() — the session-expiry call', () async {
      expect(await store.clearIfOwnerMismatch(ownerA), isFalse);
      await store.save(attack(start: 1760010000000)); // active

      await store.clear();

      expect(disk.containsKey(MigraineAttackStore.storageKey), isFalse);
      expect(await store.loadAll(), isEmpty);
      expect(await store.loadActive(), isNull);
    });

    test('owner mismatch at login wipes and reports the wipe',
        () async {
      expect(await store.clearIfOwnerMismatch(ownerA), isFalse);
      await store.save(attack(start: 1760000000000, end: 1760003600000));

      expect(await store.clearIfOwnerMismatch(ownerB), isTrue);
      expect(disk.containsKey(MigraineAttackStore.storageKey), isFalse);
      expect(await store.loadAll(), isEmpty);
    });

    test('invisible to the next owner; the next owner saves under '
        'their own stamp and the old records never resurface',
        () async {
      expect(await store.clearIfOwnerMismatch(ownerA), isFalse);
      final aAttack = attack(start: 1760000000000, end: 1760003600000);
      await store.save(aAttack);

      expect(await store.clearIfOwnerMismatch(ownerB), isTrue);
      // Binding B again on the now-empty storage wipes nothing.
      expect(await store.clearIfOwnerMismatch(ownerB), isFalse);
      expect(await store.loadAll(), isEmpty);

      final bAttack = attack(
          start: 1760020000000, end: 1760023600000, meds: 'ibuprofen');
      await store.save(bAttack);
      final all = await store.loadAll();
      expect(all.map((a) => a.id), [bAttack.id]);
      final blob = jsonDecode(disk[MigraineAttackStore.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['ownerEmail'], ownerB);
    });

    test('same-owner login does not wipe', () async {
      expect(await store.clearIfOwnerMismatch(ownerA), isFalse);
      await store.save(attack(start: 1760000000000, end: 1760003600000));
      expect(await store.clearIfOwnerMismatch(ownerA), isFalse);
      expect(await store.loadAll(), hasLength(1));
    });

    test('null email binds nothing and wipes nothing', () async {
      expect(await store.clearIfOwnerMismatch(ownerA), isFalse);
      await store.save(attack(start: 1760000000000, end: 1760003600000));
      expect(await store.clearIfOwnerMismatch(null), isFalse);
      expect(await store.clearIfOwnerMismatch('  '), isFalse);
      expect(await store.loadAll(), hasLength(1));
    });

    test('unstamped legacy blob wipes on login even for the same '
        'owner (coach semantics: no recorded account → wipe)',
        () async {
      // A pre-4e production blob: no ownerEmail key at all.
      disk[MigraineAttackStore.storageKey] = jsonEncode({
        'attacks': [
          attack(start: 1760000000000, end: 1760003600000).toJson(),
        ],
        'activeAttackId': null,
      });
      expect(await store.clearIfOwnerMismatch(ownerA), isTrue);
      expect(disk.containsKey(MigraineAttackStore.storageKey), isFalse);
      expect(await store.loadAll(), isEmpty);
    });

    test('load enforcement: a blob stamped for another owner is '
        'wiped on load, never served', () async {
      // Defense-in-depth behind clearIfOwnerMismatch: an
      // independent store bound to B meets a blob stamped A.
      final otherDisk = <String, String>{};
      final other = MigraineAttackStore.withStorage(
        read: (k) async => otherDisk[k],
        write: (k, v) async => otherDisk[k] = v,
        delete: (k) async => otherDisk.remove(k),
      );
      expect(await other.clearIfOwnerMismatch(ownerB), isFalse);
      otherDisk[MigraineAttackStore.storageKey] = jsonEncode({
        'ownerEmail': ownerA,
        'attacks': [
          attack(start: 1760000000000, end: 1760003600000).toJson(),
        ],
        'activeAttackId': null,
      });
      expect(await other.loadAll(), isEmpty);
      expect(otherDisk.containsKey(MigraineAttackStore.storageKey),
          isFalse);
    });

    test('unbound writes preserve an existing owner stamp',
        () async {
      final otherDisk = <String, String>{};
      final other = MigraineAttackStore.withStorage(
        read: (k) async => otherDisk[k],
        write: (k, v) async => otherDisk[k] = v,
        delete: (k) async => otherDisk.remove(k),
      );
      otherDisk[MigraineAttackStore.storageKey] = jsonEncode({
        'ownerEmail': ownerA,
        'attacks': [
          attack(start: 1760000000000, end: 1760003600000).toJson(),
        ],
        'activeAttackId': null,
      });
      // Unbound serve + save: the stamp's owner is the only
      // account whose session could have written the blob.
      await other.save(attack(start: 1760010000000, end: 1760013600000));
      expect(await other.loadAll(), hasLength(2));
      final blob = jsonDecode(otherDisk[MigraineAttackStore.storageKey]!)
          as Map<String, dynamic>;
      expect(blob['ownerEmail'], ownerA);
    });
  });
}
