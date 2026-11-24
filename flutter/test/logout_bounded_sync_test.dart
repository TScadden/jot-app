import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/onboarding_sync_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'test_helpers.dart';

/// Logout-blocked-by-silent-sync (Nov 24, 2026) — the bounded
/// sign-out contract:
///
/// (a) a revoke whose secure-storage read never completes must
///     not park logout: the wipe still runs and logout returns
///     within the bound;
/// (b) a stalled outbox flush (its POST never completes) must not
///     park logout either, and the unconfirmed entries are
///     RETAINED owner-bound (F2), never wiped;
/// (c) the account boundary: retained entries restore + flush on
///     the SAME account's return and are dropped UNSENT on a
///     DIFFERENT account's sign-in;
/// (d) a second logout() while one is running joins it — the
///     chain executes exactly once;
/// (e) the dialog shows a real progress indicator from the first
///     frame of the wait and cannot be dismissed mid-sign-out.
///
/// These tests race logout against a wall-clock budget instead of
/// awaiting it directly, so on the unbounded base they FAIL in
/// bounded time instead of hanging the suite.
Future<bool> _completesWithin(Future<dynamic> future, Duration budget) =>
    Future.any([
      future.then((_) => true, onError: (_) => true),
      Future<void>.delayed(budget).then((_) => false),
    ]);

SettingsStore _fakeSettings(Map<String, String> map) =>
    SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

QuickLogEntry _entry(int id) => QuickLogEntry(
      id: id,
      categoryId: 3,
      body: 'entry $id',
      chips: '[]',
      manualText: '',
      timestamp: DateTime(2026, 11, 24, 9).millisecondsSinceEpoch,
    );

/// A session store whose refresh-token read NEVER completes —
/// the wedged secure-storage channel from the diagnosis, at the
/// exact leg logoutAccount() awaits first.
class _HangingRefreshReadStore extends FakeSessionStore {
  @override
  Future<String?> readRefreshToken() => Completer<String?>().future;
}

/// Backend whose entry POST can be parked forever and whose
/// revoke is instant; records what actually reached the "server".
class _FlushBackend extends TabsBackend {
  _FlushBackend({required this.email, super.sessionStore});

  final String? email;
  Completer<void>? postGate;
  bool postSucceeds = true;
  final List<int> postedIds = [];
  int postAttempts = 0;
  int logoutCalls = 0;

  @override
  Future<String?> readEmail() async => email;

  @override
  Future<bool> postLogEntries(List<QuickLogEntry> entries) async {
    postAttempts++;
    final gate = postGate;
    if (gate != null) await gate.future;
    if (!postSucceeds) return false;
    postedIds.addAll(entries.map((e) => e.id));
    return true;
  }

  @override
  Future<bool> logoutAccount() async {
    logoutCalls++;
    return true;
  }

  // The onboarding outbox leg of logout reads these; keep them
  // local and instant (its queue is empty in these tests).
  @override
  Future<Map<String, dynamic>?> fetchProfile() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>?> fetchLogCategoriesOrNull() async =>
      const [];

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async => true;
}

/// Backend for the single-flight pin: revoke is slow enough that
/// a second logout() call lands while the first is still running.
class _SlowRevokeBackend extends TabsBackend {
  int logoutCalls = 0;

  @override
  Future<String?> readEmail() async => 'a@example.com';

  @override
  Future<bool> postLogEntries(List<QuickLogEntry> entries) async => true;

  @override
  Future<bool> logoutAccount() async {
    logoutCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return true;
  }

  @override
  Future<Map<String, dynamic>?> fetchProfile() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>?> fetchLogCategoriesOrNull() async =>
      const [];

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async => true;
}

/// Backend for the onboarding H1 pin: the profile POST can be
/// parked on a gate while sign-out begins.
class _OnboardingBackend extends TabsBackend {
  Completer<void>? postGate;
  int profilePostAttempts = 0;

  @override
  Future<String?> readEmail() async => 'a@example.com';

  @override
  Future<Map<String, dynamic>?> fetchProfile() async =>
      <String, dynamic>{};

  @override
  Future<List<QuickLogCategory>?> fetchLogCategoriesOrNull() async =>
      const [];

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async {
    profilePostAttempts++;
    final gate = postGate;
    if (gate != null) await gate.future;
    return true;
  }

  @override
  Future<bool> postLogCategories(List<QuickLogCategory> cats) async =>
      true;
}

/// Minimal Settings backend for the dialog widget test (the
/// settings_r29 FakeSettingsBackend shape), with a gated revoke.
class _DialogBackend extends TabsBackend {
  _DialogBackend({super.sessionStore});

  final Completer<void> logoutGate = Completer<void>();

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => {
        'isUnlimited': false,
        'isAdmin': false,
        'nickname': 'Tyson',
        'tag': '1234',
        'profile': <String, dynamic>{},
        'insights': const [],
      };

  @override
  Future<List<HabitDto>?> fetchHabitsOrNull() async => const [];

  @override
  Future<bool> postSyncProfile(Map<String, dynamic> fields) async => true;

  @override
  Future<Map<String, dynamic>?> updateNickname(String nickname) async =>
      {'success': true, 'nickname': nickname, 'tag': '4242'};

  @override
  Future<bool> logoutAccount() async {
    await logoutGate.future;
    return true;
  }

  @override
  Future<bool> deleteAccount() async => true;
}

void main() {
  late Map<String, String> disk;

  setUp(() {
    disk = <String, String>{};
    LogEntryOutbox.instance.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    LogEntryOutbox.instance.debugReset();
  });

  tearDown(() {
    LogEntryOutbox.instance.debugReset();
  });

  group('bounded sign-out', () {
    test(
        '(a) logout completes within the bound and the wipe runs '
        'when the revoke storage read never completes', () async {
      final store = _HangingRefreshReadStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = TabsBackend(
        client: MockClient((_) async => http.Response('{}', 200)),
        sessionStore: store,
      );
      final settingsMap = <String, String>{'settings_theme_mode': 'LIGHT'};
      var cachesCleared = false;
      final actions = AccountActions(
        backend: backend,
        sessionStore: store,
        settingsStore: _fakeSettings(settingsMap),
        clearCaches: () async => cachesCleared = true,
      );

      final completed = await _completesWithin(
          actions.logout(), const Duration(seconds: 8));
      expect(completed, isTrue,
          reason: 'a wedged secure-storage read must not park logout');
      // The wipe ran despite the revoke never answering.
      expect(store.token, isNull);
      expect(settingsMap, isEmpty);
      expect(cachesCleared, isTrue);
    });

    test(
        '(a2) TabsBackend.logoutAccount itself returns when the '
        'refresh-token read never completes', () async {
      final store = _HangingRefreshReadStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = TabsBackend(
        client: MockClient((_) async => http.Response('{}', 200)),
        sessionStore: store,
      );
      var result = true;
      final completed = await _completesWithin(
        backend.logoutAccount().then((v) => result = v),
        const Duration(seconds: 8),
      );
      expect(completed, isTrue,
          reason: 'logoutAccount must bound its own storage reads');
      expect(result, isFalse,
          reason: 'no token could be read, so no revoke happened');
    });

    test(
        '(b) stalled outbox flush: logout completes within the '
        'bound and the entries are retained owner-bound', () async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = _FlushBackend(
        email: 'a@example.com',
        sessionStore: session,
      )..postGate = Completer<void>(); // the POST never lands
      expect(
        await LogEntryOutbox.instance.stage(
          _entry(42),
          serverKnown: false,
          ownerEmail: 'a@example.com',
        ),
        isTrue,
      );
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: _fakeSettings(<String, String>{}),
        clearCaches: () async {},
      );

      final completed = await _completesWithin(
          actions.logout(), const Duration(seconds: 5));
      expect(completed, isTrue,
          reason: 'a stalled flush must not park logout');
      expect(session.token, isNull);
      // F2 retention: the unconfirmed entry survives, owner-bound,
      // in memory AND on disk — not wiped, not posted.
      expect(LogEntryOutbox.instance.records.map((r) => r.entry.id),
          contains(42));
      expect(backend.postedIds, isEmpty);
      final blob = disk[LogEntryOutbox.storageKey];
      expect(blob, isNotNull);
      expect(blob, contains('a@example.com'));
    });

    test(
        '(c) retained entries flush on the SAME account\'s return '
        'and are dropped unsent for a DIFFERENT account', () async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final stalled = _FlushBackend(
        email: 'a@example.com',
        sessionStore: session,
      )..postGate = Completer<void>();
      await LogEntryOutbox.instance.stage(
        _entry(42),
        serverKnown: false,
        ownerEmail: 'a@example.com',
      );
      final actions = AccountActions(
        backend: stalled,
        sessionStore: session,
        settingsStore: _fakeSettings(<String, String>{}),
        clearCaches: () async {},
      );
      expect(
        await _completesWithin(actions.logout(), const Duration(seconds: 5)),
        isTrue,
      );
      expect(LogEntryOutbox.instance.records.map((r) => r.entry.id),
          contains(42));

      // H1: the abandoned flush's POST finally lands AFTER the
      // sign-out completed. It must not mutate the retained queue
      // (on the base it removes the entry as if confirmed, and the
      // same-account return below then has nothing to flush).
      stalled.postGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(LogEntryOutbox.instance.records.map((r) => r.entry.id),
          contains(42),
          reason: 'a flush abandoned at the sign-out timeout must '
              'stop mutating the queue it was retained from');

      // Same account signs back in: the retained entry restores
      // and flushes through that account's session.
      final backA = _FlushBackend(email: 'a@example.com');
      expect(await LogEntryOutbox.instance.flush(backA), isTrue);
      expect(backA.postedIds, [42]);
      expect(LogEntryOutbox.instance.records, isEmpty);

      // Retain a second entry the same way, then a DIFFERENT
      // account signs in: the entry is dropped unsent — it must
      // never post under the new account's session.
      final session2 = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final stalled2 = _FlushBackend(
        email: 'a@example.com',
        sessionStore: session2,
      )..postGate = Completer<void>();
      await LogEntryOutbox.instance.stage(
        _entry(43),
        serverKnown: false,
        ownerEmail: 'a@example.com',
      );
      final actions2 = AccountActions(
        backend: stalled2,
        sessionStore: session2,
        settingsStore: _fakeSettings(<String, String>{}),
        clearCaches: () async {},
      );
      expect(
        await _completesWithin(
            actions2.logout(), const Duration(seconds: 5)),
        isTrue,
      );
      expect(LogEntryOutbox.instance.records.map((r) => r.entry.id),
          contains(43));
      // The second abandoned POST lands late too; the retained
      // entry must still be intact for the owner check below.
      stalled2.postGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(LogEntryOutbox.instance.records.map((r) => r.entry.id),
          contains(43));

      expect(
        await LogEntryOutbox.instance
            .clearIfOwnerMismatch('b@example.com'),
        isTrue,
      );
      expect(LogEntryOutbox.instance.records, isEmpty);
      final backB = _FlushBackend(email: 'b@example.com');
      expect(await LogEntryOutbox.instance.flush(backB), isTrue);
      expect(backB.postedIds, isEmpty,
          reason: 'account A\'s retained entry must never reach '
              'the server under account B');
    });

    test('(d) double-invoke logout joins the in-flight run', () async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = _SlowRevokeBackend();
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: _fakeSettings(<String, String>{}),
        clearCaches: () async {},
      );
      final first = actions.logout();
      final second = actions.logout();
      final results = await Future.wait([first, second]);
      expect(results, [isTrue, isTrue]);
      expect(backend.logoutCalls, 1,
          reason: 'the second invocation must join, not re-run, '
              'the sign-out chain');
      expect(session.token, isNull);
    });
  });

  group('abandoned-flush race (H1)', () {
    test(
        '(f1) a log-entry flush abandoned by beginSignOut posts '
        'nothing further and mutates nothing when its POST lands',
        () async {
      final backend = _FlushBackend(email: 'a@example.com')
        ..postGate = Completer<void>();
      final outbox = LogEntryOutbox.instance;
      await outbox.stage(_entry(42),
          serverKnown: false, ownerEmail: 'a@example.com');
      await outbox.stage(_entry(43),
          serverKnown: false, ownerEmail: 'a@example.com');

      final flushFuture = outbox.flush(backend);
      for (var i = 0; i < 200 && backend.postAttempts == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(backend.postAttempts, 1,
          reason: 'the flush should be parked inside its first POST');

      // Sign-out abandons the run; the parked POST then lands.
      outbox.beginSignOut();
      backend.postGate!.complete();
      expect(await flushFuture, isFalse);
      expect(backend.postAttempts, 1,
          reason: 'the abandoned run must not post the second entry');
      expect(outbox.records.map((r) => r.entry.id),
          containsAll([42, 43]),
          reason: 'the abandoned run must not remove or re-mark '
              'the retained entries when its POST lands');
    });

    test(
        '(f2) an onboarding flush abandoned by beginSignOut keeps '
        'its slot when its POST lands', () async {
      final obDisk = <String, String>{};
      final outbox = OnboardingSyncOutbox.withDeps(
        read: (k) async => obDisk[k],
        write: (k, v) async => obDisk[k] = v,
        delete: (k) async => obDisk.remove(k),
      );
      final backend = _OnboardingBackend()..postGate = Completer<void>();
      expect(
        await outbox.stageProfile(backend, {
          'userContext': 'ctx',
          'onboardingComplete': true,
        }),
        isTrue,
      );

      final flushFuture = outbox.flush(backend);
      for (var i = 0; i < 200 && backend.profilePostAttempts == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(backend.profilePostAttempts, 1,
          reason: 'the flush should be parked inside its POST');

      outbox.beginSignOut();
      backend.postGate!.complete();
      expect(await flushFuture, isFalse);
      expect(outbox.hasPending, isTrue,
          reason: 'the abandoned run must not remove the retained '
              'slot when its POST lands');
      expect(await outbox.pendingProfile(backend), isNotNull);
    });
  });

  group('logout dialog', () {
    testWidgets(
        '(e) confirm shows a progress indicator from the first '
        'frame and the dialog cannot be dismissed mid-sign-out',
        (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = 'a@example.com';
      final backend = _DialogBackend(sessionStore: session);
      var loggedOut = false;
      final actions = AccountActions(
        backend: backend,
        sessionStore: session,
        settingsStore: _fakeSettings(<String, String>{}),
        clearCaches: () async {},
      );
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            backend: backend,
            settingsStore: _fakeSettings(<String, String>{}),
            accountActions: actions,
            onLogout: () => loggedOut = true,
            notificationService: FakeReminderNotificationService(),
            urlLauncher: (_) async => true,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('logout_button')));
      await tester.pumpAndSettle();
      expect(find.text('Logout?'), findsOneWidget);
      // Juno-signed idle copy (JUNO-COPY.md, Nov 24, 2026).
      expect(
          find.text(
              "You'll be signed out of this account on this device."),
          findsOneWidget);
      expect(
          find.text(
              "This only takes a few seconds. Anything that hasn't synced yet stays saved on this device and syncs the next time you sign in."),
          findsOneWidget);
      // The bounded wait drops the old "minute or two" warning.
      expect(find.textContaining('minute or two'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('confirm_logout')));
      await tester.pump();
      // Real feedback from the first frame of the wait.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Signing out...'), findsOneWidget);

      // Neither a barrier tap nor the system back button may
      // dismiss the dialog into a silent half-state mid-sign-out.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(find.text('Logout?'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Logout?'), findsOneWidget);
      expect(loggedOut, isFalse);

      // The bounded chain completes once the revoke lands.
      backend.logoutGate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Logout?'), findsNothing);
      expect(session.token, isNull);
      expect(loggedOut, isTrue);
    });
  });
}
