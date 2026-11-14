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
