import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/onboarding_sync_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/setup_loading_screen.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'test_helpers.dart';

/// C-08 (sub-claim 2) — pending-onboarding-sync OUTBOX.
///
/// The old finalize path awaited `postLogCategories` /
/// `postSyncProfile` in SetupLoadingScreen and DISCARDED both
/// bool results; both return false (never throw) on failure, so
/// an offline finalize lost the user's picked categories and
/// profile outright. The outbox contract pinned here:
///
/// (a) onboarding post fails → relaunch → flush succeeds →
///     categories present server-side;
/// (b) a category created AFTER onboarding survives a late
///     flush (the categories endpoint is a full-list replace,
///     so a stale replay would delete it — the flush must merge
///     against the server's CURRENT list);
/// (c) double flush is idempotent — the second flush posts
///     nothing and changes nothing;
/// (d) a profile flush never overwrites a NEWER profile, and
///     still delivers into a still-empty one;
/// (e) the outbox is per-user: account A's pending payload is
///     NEVER flushed into account B's session.
///
/// The fake backend reproduces the two server contracts from
/// jot-server's sync routes: categories = full-list replace
/// (payload IS the new server state), profile = partial
/// COALESCE upsert (non-null fields overwrite, others kept).

class _FakeDisk {
  final Map<String, String> values = {};

  Future<String?> read(String key) async => values[key];

  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Disk whose NEXT write (once armed) parks on a gate until
/// released — Vera's probe shape for the E-condition pins: it
/// lets a test land a clear() / owner switch INSIDE a flush's
/// attempts-persist await, between the post-pull identity
/// check and the post dispatch. The gated write's value only
/// lands when the gate releases, which is exactly the ordering
/// that resurrected the blob past an enforcement delete in
/// probes P1/P2.
class _GatedDisk {
  final Map<String, String> values = {};
  Completer<void>? _gate;
  bool _gateNextWrite = false;
  bool gatedWriteStarted = false;

  void gateNextWrite() {
    _gate = Completer<void>();
    _gateNextWrite = true;
    gatedWriteStarted = false;
  }

  void releaseGate() => _gate?.complete();

  Future<String?> read(String key) async => values[key];

  Future<void> write(String key, String value) async {
    if (_gateNextWrite) {
      _gateNextWrite = false;
      gatedWriteStarted = true;
      await _gate!.future;
    }
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Future<void> _untilParked(_GatedDisk disk) async {
  for (var i = 0; i < 1000 && !disk.gatedWriteStarted; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (!disk.gatedWriteStarted) {
    throw StateError('flush never reached the gated persist');
  }
}

OnboardingSyncOutbox _gatedOutbox(_GatedDisk disk) =>
    OnboardingSyncOutbox.withDeps(
      read: disk.read,
      write: disk.write,
      delete: disk.delete,
    );

QuickLogCategory _cat(int id, String name, {bool isDefault = false}) =>
    QuickLogCategory(
      id: id,
      name: name,
      icon: 'Favorite',
      colorHex: '#FF6B6B',
      isDefault: isDefault,
      sortOrder: id,
    );

List<QuickLogCategory> _defaults() => [
  for (var i = 1; i <= 7; i++) _cat(i, 'Default$i', isDefault: true),
];

class _FakeBackend extends TabsBackend {
  _FakeBackend({this.email});

  String? email;
  bool failPosts = false;
  bool failCategoriesPost = false;
  bool failProfilePost = false;
  bool failPull = false;

  List<QuickLogCategory> serverCategories = _defaults();
  Map<String, dynamic> serverProfile = {};

  int categoryPosts = 0;
  int profilePosts = 0;
  final List<List<QuickLogCategory>> categoryPayloads = [];
  final List<Map<String, dynamic>> profilePayloads = [];

  @override
  Future<String?> readEmail() async => email;

  @override
  Future<List<String>?> generateCategories(String userContext) async => [
    'Focus',
    'Calm',
  ];

  @override
  Future<List<QuickLogCategory>> fetchLogCategories() async =>
      List.of(serverCategories);

  @override
  Future<List<QuickLogCategory>?> fetchLogCategoriesOrNull() async =>
      failPull ? null : List.of(serverCategories);

  @override
  Future<Map<String, dynamic>?> fetchProfile() async =>
      failPull ? null : Map.of(serverProfile);

  @override
  Future<bool> postLogCategories(List<QuickLogCategory> cats) async {
    categoryPosts++;
    categoryPayloads.add(List.of(cats));
    if (failPosts || failCategoriesPost) return false;
    // Server contract: FULL-LIST REPLACE — the payload becomes
    // the server state; rows missing from it are deleted.
    serverCategories = List.of(cats);
    return true;
  }

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePosts++;
    profilePayloads.add(Map.of(fields));
    if (failPosts || failProfilePost) return false;
    // Server contract: COALESCE upsert — non-null fields
    // overwrite, omitted fields keep their server value.
    fields.forEach((k, v) {
      if (v != null) serverProfile[k] = v;
    });
    return true;
  }
}

/// The same fake backend, extended with the Settings screen's
/// pull surface so the P4 wiring pins can drive the REAL
/// `SettingsScreen._pushProfile` choke point: the pull body is
/// built from [serverProfile], exactly what Settings loads.
class _SettingsBackend extends _FakeBackend {
  _SettingsBackend({super.email});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => failPull
      ? null
      : {
          'isUnlimited': false,
          'isAdmin': false,
          'nickname': 'Tyson',
          'tag': '1234',
          'profile': Map<String, dynamic>.of(serverProfile),
          'insights': const [],
        };
}

OnboardingSyncOutbox _outbox(_FakeDisk disk) => OnboardingSyncOutbox.withDeps(
  read: disk.read,
  write: disk.write,
  delete: disk.delete,
);

const _ownerA = 'a@tabs.app';
const _ownerB = 'b@tabs.app';

void main() {
  group('OnboardingSyncOutbox (C-08)', () {
    test('(a) staged on failure, durable on disk owner-stamped, '
        'flush after relaunch delivers categories + profile', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);

      final staged = await outbox.stageCategories(backend, [
        _cat(8, 'Focus'),
        _cat(9, 'Calm'),
      ]);
      expect(staged, isTrue);
      expect(
        await outbox.stageProfile(backend, {
          'userContext': 'my context',
          'conditions': '["POTS"]',
          'onboardingComplete': true,
        }),
        isTrue,
      );

      // Durable + owner-stamped on disk (a process death here
      // loses nothing).
      final raw = disk.values[OnboardingSyncOutbox.storageKey];
      expect(raw, isNotNull);
      final blob = jsonDecode(raw!) as Map<String, dynamic>;
      expect(blob['ownerEmail'], _ownerA);
      final stagedCats = (blob['categories']['addedCategories'] as List)
          .cast<Map>();
      expect(stagedCats.map((c) => c['name']), ['Focus', 'Calm']);

      // Relaunch: a brand-new outbox over the SAME disk.
      final relaunched = _outbox(disk);
      expect(await relaunched.flush(backend), isTrue);

      final names = backend.serverCategories.map((c) => c.name).toSet();
      expect(names, containsAll(['Focus', 'Calm']));
      // The defaults finalize merged against are untouched.
      expect(names, containsAll([for (var i = 1; i <= 7; i++) 'Default$i']));
      expect(backend.serverProfile['userContext'], 'my context');
      expect(backend.serverProfile['conditions'], '["POTS"]');
      expect(backend.serverProfile['onboardingComplete'], true);
      expect(await relaunched.pendingCategories(backend), isNull);
      expect(await relaunched.pendingProfile(backend), isNull);
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
    });

    test('(b) a category created after onboarding survives a late '
        'flush, unmodified', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);

      // The user creates a category AFTER onboarding, before the
      // flush ever runs. Under a naive stale-list replay the
      // full-list-replace endpoint would DELETE it.
      backend.serverCategories = [..._defaults(), _cat(10, 'Journal')];

      expect(await outbox.flush(backend), isTrue);
      final byName = {for (final c in backend.serverCategories) c.name: c};
      expect(byName.keys, containsAll(['Focus', 'Journal']));
      expect(byName['Journal']!.id, 10);
      expect(byName['Focus']!.id, 8);
      // The posted payload rode the CURRENT list along.
      expect(
        backend.categoryPayloads.single.map((c) => c.name),
        containsAll(['Journal', 'Focus']),
      );
    });

    test('(b2) an id collision re-ids the staged category instead '
        'of overwriting the post-onboarding row', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);

      // Post-onboarding, the user created 'Journal' and it took
      // id 8 (the id finalize had allocated for 'Focus').
      backend.serverCategories = [..._defaults(), _cat(8, 'Journal')];

      expect(await outbox.flush(backend), isTrue);
      final byName = {for (final c in backend.serverCategories) c.name: c};
      expect(byName['Journal']!.id, 8);
      expect(byName['Focus'], isNotNull);
      expect(byName['Focus']!.id, isNot(8));
    });

    test('(c) double flush is idempotent: second flush posts '
        'nothing, server state unchanged', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);
      await outbox.stageProfile(backend, {
        'userContext': 'ctx',
        'conditions': '[]',
        'onboardingComplete': true,
      });

      expect(await outbox.flush(backend), isTrue);
      final catsAfterFirst = backend.serverCategories
          .map((c) => '${c.id}:${c.name}')
          .toList();
      final profileAfterFirst = Map.of(backend.serverProfile);
      final categoryPostsAfterFirst = backend.categoryPosts;
      final profilePostsAfterFirst = backend.profilePosts;

      expect(await outbox.flush(backend), isTrue);
      expect(backend.categoryPosts, categoryPostsAfterFirst);
      expect(backend.profilePosts, profilePostsAfterFirst);
      expect(
        backend.serverCategories.map((c) => '${c.id}:${c.name}').toList(),
        catsAfterFirst,
      );
      expect(backend.serverProfile, profileAfterFirst);
    });

    test('(c2) a flush whose post landed but whose removal was '
        'lost re-derives delivery and posts nothing harmful', () async {
      // Simulate the crash window by hand: stage, then apply the
      // payload server-side WITHOUT draining the queue (the post
      // landed, the local removal never persisted).
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);
      await outbox.stageProfile(backend, {
        'userContext': 'ctx',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });
      backend.serverCategories = [..._defaults(), _cat(8, 'Focus')];
      backend.serverProfile = {
        'userContext': 'ctx',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      };

      expect(await outbox.flush(backend), isTrue);
      // Nothing needed posting: delivery was already provable
      // from server state, and the queue drained.
      expect(backend.categoryPosts, 0);
      expect(backend.profilePosts, 0);
      expect(await outbox.pendingCategories(backend), isNull);
      expect(await outbox.pendingProfile(backend), isNull);
    });

    test('(d) profile flush does not overwrite a newer profile', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageProfile(backend, {
        'userContext': 'onboarding context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });

      // After onboarding the user edited BOTH fields in Settings.
      backend.serverProfile = {
        'userContext': 'edited later',
        'conditions': '["POTS","MCAS"]',
        'onboardingComplete': true,
      };

      expect(await outbox.flush(backend), isTrue);
      expect(backend.profilePosts, 0);
      expect(backend.serverProfile['userContext'], 'edited later');
      expect(backend.serverProfile['conditions'], '["POTS","MCAS"]');
      // Superseded per field: the slot is discharged, not kept
      // forever.
      expect(await outbox.pendingProfile(backend), isNull);
    });

    test('(d2) profile flush still delivers into a still-empty '
        'profile, field by field', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageProfile(backend, {
        'userContext': 'onboarding context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });
      // userContext was edited later; conditions never landed.
      backend.serverProfile = {'userContext': 'edited later'};

      expect(await outbox.flush(backend), isTrue);
      expect(backend.profilePosts, 1);
      final sent = backend.profilePayloads.single;
      expect(sent.containsKey('userContext'), isFalse);
      expect(sent['conditions'], '["POTS"]');
      expect(sent['onboardingComplete'], true);
      expect(backend.serverProfile['userContext'], 'edited later');
      expect(backend.serverProfile['conditions'], '["POTS"]');
    });

    test('(e) per-user: A\'s pending payload never flushes into '
        'B\'s session — dropped unsent on owner mismatch', () async {
      final disk = _FakeDisk();
      final outboxA = _outbox(disk);
      final backendA = _FakeBackend(email: _ownerA);
      await outboxA.stageCategories(backendA, [_cat(8, 'Focus')]);
      await outboxA.stageProfile(backendA, {
        'userContext': 'a context',
        'conditions': '[]',
        'onboardingComplete': true,
      });

      // A fresh process where B is the session owner.
      final outboxB = _outbox(disk);
      final backendB = _FakeBackend(email: _ownerB);
      await outboxB.flush(backendB);

      expect(backendB.categoryPosts, 0);
      expect(backendB.profilePosts, 0);
      expect(
        backendB.serverCategories.map((c) => c.name),
        isNot(contains('Focus')),
      );
      expect(backendB.serverProfile, isEmpty);
      expect(await outboxB.pendingCategories(backendB), isNull);
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
    });

    test('(e2) clearIfOwnerMismatch reports the drop and the '
        'same-owner case keeps the queue', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backendA = _FakeBackend(email: _ownerA);
      await outbox.stageCategories(backendA, [_cat(8, 'Focus')]);

      expect(await outbox.clearIfOwnerMismatch(_ownerA), isFalse);
      expect(await outbox.pendingCategories(backendA), isNotNull);

      expect(await outbox.clearIfOwnerMismatch(_ownerB), isTrue);
      final backendB = _FakeBackend(email: _ownerB);
      expect(await outbox.pendingCategories(backendB), isNull);
    });

    test('(f) Vera P1 shape: clear() landing during the profile '
        'flush persist window ⇒ zero posts, no blob '
        'resurrection', () async {
      final disk = _GatedDisk();
      final outbox = _gatedOutbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageProfile(backend, {
        'userContext': 'stale context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });

      disk.gateNextWrite();
      final flushFuture = outbox.flush(backend);
      await _untilParked(disk);
      // Reset Account Status's clear lands INSIDE the persist
      // window — after the pull check, before dispatch.
      await outbox.clear();
      disk.releaseGate();
      await flushFuture;

      expect(backend.profilePosts, 0);
      expect(backend.serverProfile, isEmpty);
      // The gated write landed after clear's delete; the
      // generation guard must not leave it resurrected.
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
      expect(await outbox.pendingProfile(backend), isNull);
    });

    test('(f2) clear() landing during the categories flush '
        'persist window ⇒ zero posts, no blob resurrection',
        () async {
      final disk = _GatedDisk();
      final outbox = _gatedOutbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);

      disk.gateNextWrite();
      final flushFuture = outbox.flush(backend);
      await _untilParked(disk);
      await outbox.clear();
      disk.releaseGate();
      await flushFuture;

      expect(backend.categoryPosts, 0);
      expect(
        backend.serverCategories.map((c) => c.name),
        isNot(contains('Focus')),
      );
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
      expect(await outbox.pendingCategories(backend), isNull);
    });

    test('(g) Vera P2 shape: owner switch landing during the '
        'flush persist window ⇒ zero posts under either token, '
        'no blob resurrection', () async {
      final disk = _GatedDisk();
      final outbox = _gatedOutbox(disk);
      // One backend object models the real TabsBackend's
      // token-at-dispatch read: switching its email mid-window
      // is B signing in, so any dispatch after the switch would
      // be counted here as a post under B's token.
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);
      await outbox.stageProfile(backend, {
        'userContext': 'a context',
        'conditions': '[]',
        'onboardingComplete': true,
      });

      disk.gateNextWrite();
      final flushFuture = outbox.flush(backend);
      await _untilParked(disk);
      backend.email = _ownerB;
      final dropped = await outbox.clearIfOwnerMismatch(_ownerB);
      expect(dropped, isTrue);
      disk.releaseGate();
      await flushFuture;

      expect(backend.categoryPosts, 0);
      expect(backend.profilePosts, 0);
      expect(
        backend.serverCategories.map((c) => c.name),
        isNot(contains('Focus')),
      );
      expect(backend.serverProfile, isEmpty);
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
      expect(await outbox.pendingCategories(backend), isNull);
      expect(await outbox.pendingProfile(backend), isNull);
    });

    test('(h) P4 (i): both-fields supersession in the '
        'lost-response shape — flush delivers neither cleared '
        'field; onboardingComplete still delivers', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageProfile(backend, {
        'userContext': 'stale context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });

      // Lost-response shape + deliberate clear: the finalize
      // post actually landed, the user then cleared BOTH fields
      // in Settings (successful pushes — the server now holds
      // the cleared empty values), and the staged slot was
      // never removed. The supersession call below is exactly
      // the call _pushProfile makes on ok == true for a push
      // carrying both fields.
      backend.serverProfile = {
        'userContext': '',
        'conditions': '[]',
        'onboardingComplete': false,
      };
      await outbox.supersedeStagedProfileFields(
          ['userContext', 'conditions']);

      // Per-field removal: ONLY onboardingComplete remains
      // staged — its delivery obligation is untouched.
      final pending = await outbox.pendingProfile(backend);
      expect(pending, isNotNull);
      expect(pending!.fields, {'onboardingComplete': true});
      // The supersession is durable, not just in memory.
      final relaunched = _outbox(disk);
      final reloaded = await relaunched.pendingProfile(backend);
      expect(reloaded!.fields, {'onboardingComplete': true});

      expect(await relaunched.flush(backend), isTrue);
      // Exactly one post, carrying NEITHER cleared field.
      expect(backend.profilePosts, 1);
      expect(backend.profilePayloads.single, {'onboardingComplete': true});
      expect(backend.serverProfile['userContext'], '');
      expect(backend.serverProfile['conditions'], '[]');
      expect(backend.serverProfile['onboardingComplete'], true);
      expect(await relaunched.pendingProfile(backend), isNull);
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
    });

    test('(i) P4 (ii): single-field supersession — clearing '
        'conditions only leaves a still-undelivered userContext '
        'deliverable (per-field, not whole-slot)', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageProfile(backend, {
        'userContext': 'onboarding context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });

      // Only conditions was cleared in Settings (successful
      // push, server holds the cleared value); userContext
      // never landed anywhere.
      backend.serverProfile = {'conditions': '[]'};
      await outbox.supersedeStagedProfileFields(['conditions']);

      final pending = await outbox.pendingProfile(backend);
      expect(pending, isNotNull);
      expect(pending!.fields.containsKey('conditions'), isFalse);
      expect(pending.fields['userContext'], 'onboarding context');
      expect(pending.fields['onboardingComplete'], true);

      expect(await outbox.flush(backend), isTrue);
      expect(backend.profilePosts, 1);
      final sent = backend.profilePayloads.single;
      expect(sent.containsKey('conditions'), isFalse);
      expect(sent['userContext'], 'onboarding context');
      expect(sent['onboardingComplete'], true);
      // The cleared conditions stay cleared; the undelivered
      // userContext lands.
      expect(backend.serverProfile['conditions'], '[]');
      expect(backend.serverProfile['userContext'], 'onboarding context');
      expect(await outbox.pendingProfile(backend), isNull);
    });

    test('(j) P4 (iii): supersession landing DURING a flush\'s '
        'persist window aborts the in-flight profile post at '
        'the dispatch re-check — zero posts carrying the '
        'cleared field', () async {
      final disk = _GatedDisk();
      final outbox = _gatedOutbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageProfile(backend, {
        'userContext': 'stale context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });

      disk.gateNextWrite();
      final flushFuture = outbox.flush(backend);
      await _untilParked(disk);
      // The Settings clear's supersession lands INSIDE the
      // persist window — after the pull, before dispatch. Its
      // in-memory amendment is synchronous, so it is in force
      // before the gate releases.
      final supersedeFuture = outbox
          .supersedeStagedProfileFields(['userContext', 'conditions']);
      disk.releaseGate();
      await flushFuture;
      await supersedeFuture;

      // The in-flight flush aborted at the re-check: it posted
      // NOTHING — above all, not the just-cleared fields.
      expect(backend.profilePosts, 0);
      expect(backend.serverProfile, isEmpty);
      // The slot survives with ONLY onboardingComplete, which
      // the next flush still delivers — alone.
      final pending = await outbox.pendingProfile(backend);
      expect(pending, isNotNull);
      expect(pending!.fields, {'onboardingComplete': true});
      expect(await outbox.flush(backend), isTrue);
      expect(backend.profilePosts, 1);
      expect(backend.profilePayloads.single, {'onboardingComplete': true});
      expect(backend.serverProfile.containsKey('userContext'), isFalse);
      expect(backend.serverProfile.containsKey('conditions'), isFalse);
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
    });

    test('failed pull keeps both slots queued for the next '
        'trigger (a failed pull is not an empty account)', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA)..failPull = true;
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);
      await outbox.stageProfile(backend, {
        'userContext': 'ctx',
        'conditions': '[]',
        'onboardingComplete': true,
      });

      expect(await outbox.flush(backend), isFalse);
      expect(backend.categoryPosts, 0);
      expect(backend.profilePosts, 0);

      backend.failPull = false;
      expect(await outbox.flush(backend), isTrue);
      expect(backend.serverCategories.map((c) => c.name), contains('Focus'));
    });

    test('failed flush keeps the payload and counts the attempt', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA)..failPosts = true;
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);

      expect(await outbox.flush(backend), isFalse);
      final pending = await outbox.pendingCategories(backend);
      expect(pending, isNotNull);
      expect(pending!.attempts, 1);
      expect(pending.addedCategories.single.name, 'Focus');

      backend.failPosts = false;
      expect(await outbox.flush(backend), isTrue);
    });

    test('retainUnconfirmed keeps the blob for the same '
        'account\'s return; clear wipes it', () async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      await outbox.stageCategories(backend, [_cat(8, 'Focus')]);

      expect(await outbox.retainUnconfirmed(backend), isTrue);
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNotNull);

      // Same account returns: the retained payload still flushes.
      final relaunched = _outbox(disk);
      expect(await relaunched.flush(backend), isTrue);
      expect(backend.serverCategories.map((c) => c.name), contains('Focus'));

      // Account deletion path: clear wipes.
      await relaunched.stageCategories(backend, [_cat(8, 'Focus')]);
      await relaunched.clear();
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
      expect(await relaunched.pendingCategories(backend), isNull);
    });
  });

  group('P4 supersession — Settings wiring (Juno §1.3.2)', () {
    SettingsStore storeFor(Map<String, String> map) =>
        SettingsStore.withStorage(
          read: (k) async => map[k],
          write: (k, v) async => map[k] = v,
          delete: (k) async => map.remove(k),
        );

    Future<void> pumpSettings(
        WidgetTester tester, _SettingsBackend backend,
        OnboardingSyncOutbox outbox, Map<String, String> storeMap) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(
              backend: backend,
              settingsStore: storeFor(storeMap),
              onboardingSyncOutbox: outbox,
              notificationService: FakeReminderNotificationService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('(k) P4 wiring: a successful Settings clear of '
        'userContext supersedes the staged field — a later '
        'flush does not resurrect it', (tester) async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _SettingsBackend(email: _ownerA);
      await outbox.stageProfile(backend, {
        'userContext': 'stale context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });
      // Lost-response shape: the finalize post landed, its
      // slot removal was lost.
      backend.serverProfile = {
        'userContext': 'stale context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      };

      await pumpSettings(tester, backend, outbox, {
        SettingsStore.userContextHiddenKey: 'false',
      });
      // Clear the Personal Context field; the 3 s debounce
      // pushes {'userContext': ''} through _pushProfile.
      await tester.enterText(
          find.byKey(const ValueKey('personal_context_field')), '');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      // The clear landed server-side (exactly one push)…
      expect(backend.profilePosts, 1);
      expect(backend.profilePayloads.single, {'userContext': ''});
      expect(backend.serverProfile['userContext'], '');
      // …and _pushProfile superseded ONLY that staged field.
      final pending = await outbox.pendingProfile(backend);
      expect(pending, isNotNull);
      expect(pending!.fields.containsKey('userContext'), isFalse);
      expect(pending.fields['conditions'], '["POTS"]');
      expect(pending.fields['onboardingComplete'], true);

      // The later flush resurrects nothing: conditions and
      // onboardingComplete already match the server, so it
      // posts nothing at all and the cleared value stands.
      expect(await outbox.flush(backend), isTrue);
      expect(backend.profilePosts, 1);
      expect(backend.serverProfile['userContext'], '');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('(l) P4 (iv): a FAILED Settings push supersedes '
        'nothing — the staged fields remain deliverable on the '
        'next flush', (tester) async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _SettingsBackend(email: _ownerA)..failProfilePost = true;
      // The finalize post truly failed: nothing ever landed.
      await outbox.stageProfile(backend, {
        'userContext': 'onboarding context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });

      await pumpSettings(tester, backend, outbox, {
        SettingsStore.userContextHiddenKey: 'false',
      });
      // A Settings edit whose push FAILS (the same ok == false
      // branch a failed clear takes): the value never lands
      // server-side, so nothing may be superseded — E's
      // protection must survive a failed clear exactly as it
      // survives a failed finalize.
      await tester.enterText(
          find.byKey(const ValueKey('personal_context_field')),
          'typed but unsaved');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(backend.profilePosts, 1);
      expect(backend.serverProfile, isEmpty);

      final pending = await outbox.pendingProfile(backend);
      expect(pending, isNotNull);
      expect(pending!.fields['userContext'], 'onboarding context');
      expect(pending.fields['conditions'], '["POTS"]');
      expect(pending.fields['onboardingComplete'], true);

      // The next (healthy) flush still delivers the ORIGINAL
      // staged values — not the failed edit, and not nothing.
      backend.failProfilePost = false;
      expect(await outbox.flush(backend), isTrue);
      expect(backend.serverProfile['userContext'], 'onboarding context');
      expect(backend.serverProfile['conditions'], '["POTS"]');
      expect(backend.serverProfile['onboardingComplete'], true);
      expect(await outbox.pendingProfile(backend), isNull);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Reset Account Status interplay (C-08)', () {
    test('reset clears a stale staged payload so its logout '
        'flush cannot resurrect onboardingComplete over the '
        'reset\'s explicit false', () async {
      final disk = _FakeDisk();
      final singleton = OnboardingSyncOutbox.instance;
      singleton.debugReset();
      singleton.debugSetStore(
        read: disk.read,
        write: disk.write,
        delete: disk.delete,
      );
      addTearDown(singleton.debugReset);

      final backend = _FakeBackend(email: _ownerA);
      await singleton.stageProfile(backend, {
        'userContext': 'stale context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      });
      backend.serverProfile = {
        'userContext': 'stale context',
        'conditions': '["POTS"]',
        'onboardingComplete': true,
      };

      final settingsMap = <String, String>{};
      final actions = AccountActions(
        backend: backend,
        sessionStore: FakeSessionStore()
          ..token = 'tok'
          ..email = _ownerA,
        settingsStore: SettingsStore.withStorage(
          read: (k) async => settingsMap[k],
          write: (k, v) async => settingsMap[k] = v,
          delete: (k) async => settingsMap.remove(k),
        ),
        clearCaches: () async {},
      );

      expect(await actions.resetAccountStatus(), isTrue);
      // The reset's false stands — no stale true was re-posted
      // over it by the logout flush — and the queue is gone.
      expect(backend.serverProfile['onboardingComplete'], false);
      expect(backend.profilePayloads, hasLength(1));
      // The blob delete is backgrounded (see AccountActions);
      // let it land before checking the disk.
      await Future<void>.delayed(Duration.zero);
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
    });
  });

  group('SetupLoadingScreen finalize (C-08)', () {
    OnboardingStore storeFor(Map<String, String> map) =>
        OnboardingStore.withStorage(
          read: (k) async => map[k],
          write: (k, v) async => map[k] = v,
          delete: (k) async => map.remove(k),
        );

    testWidgets('failed finalize posts stage both payloads; the '
        'next launch flush delivers them', (tester) async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA)..failPosts = true;
      final storeMap = <String, String>{
        'user_context': 'my context',
        'user_conditions': '["POTS"]',
      };

      await tester.pumpWidget(
        MaterialApp(
          home: SetupLoadingScreen(
            onNavigateMain: () {},
            onboardingStore: storeFor(storeMap),
            backend: backend,
            onboardingSyncOutbox: outbox,
          ),
        ),
      );
      // Let finalize run past its 2s settle.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      // Both direct posts were attempted and failed...
      expect(backend.categoryPosts, 1);
      expect(backend.profilePosts, 1);
      expect(
        backend.serverCategories.map((c) => c.name),
        isNot(contains('Focus')),
      );
      // ...and BOTH payloads are staged, not discarded.
      final stagedCats = await outbox.pendingCategories(backend);
      expect(stagedCats, isNotNull);
      expect(stagedCats!.addedCategories.map((c) => c.name), ['Focus', 'Calm']);
      final stagedProfile = await outbox.pendingProfile(backend);
      expect(stagedProfile, isNotNull);
      expect(stagedProfile!.fields['userContext'], 'my context');
      expect(stagedProfile.fields['conditions'], '["POTS"]');
      // The user is not trapped: finalize still completes.
      expect(find.text('Your profile is all set up!'), findsOneWidget);

      // Relaunch with a healthy backend: the flush delivers.
      final relaunched = _outbox(disk);
      backend.failPosts = false;
      expect(await relaunched.flush(backend), isTrue);
      expect(
        backend.serverCategories.map((c) => c.name),
        containsAll(['Focus', 'Calm']),
      );
      expect(backend.serverProfile['onboardingComplete'], true);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('successful finalize stages nothing', (tester) async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA);
      final storeMap = <String, String>{
        'user_context': 'my context',
        'user_conditions': '["POTS"]',
      };

      await tester.pumpWidget(
        MaterialApp(
          home: SetupLoadingScreen(
            onNavigateMain: () {},
            onboardingStore: storeFor(storeMap),
            backend: backend,
            onboardingSyncOutbox: outbox,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(
        backend.serverCategories.map((c) => c.name),
        containsAll(['Focus', 'Calm']),
      );
      expect(backend.serverProfile['userContext'], 'my context');
      expect(disk.values[OnboardingSyncOutbox.storageKey], isNull);
      expect(await outbox.pendingCategories(backend), isNull);
      expect(await outbox.pendingProfile(backend), isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('categories-only failure stages only the '
        'categories slot', (tester) async {
      final disk = _FakeDisk();
      final outbox = _outbox(disk);
      final backend = _FakeBackend(email: _ownerA)..failCategoriesPost = true;
      final storeMap = <String, String>{
        'user_context': 'my context',
        'user_conditions': '[]',
      };

      await tester.pumpWidget(
        MaterialApp(
          home: SetupLoadingScreen(
            onNavigateMain: () {},
            onboardingStore: storeFor(storeMap),
            backend: backend,
            onboardingSyncOutbox: outbox,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(backend.serverProfile['userContext'], 'my context');
      expect(await outbox.pendingProfile(backend), isNull);
      expect(await outbox.pendingCategories(backend), isNotNull);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
