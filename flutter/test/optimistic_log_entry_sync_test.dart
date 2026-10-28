import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';

import 'test_helpers.dart';

/// Optimistic logging + entry editing (founder directive, Oct 27,
/// 2026): a log tap or an entry edit must apply on screen instantly,
/// persist locally FIRST, and push to the server in the background.
///
/// The four required proofs:
/// (a) Quick Log submit reflects the entry immediately under a
///     deliberately slow (gated) fake server.
/// (b) A category edit renders the new category immediately under
///     the same slow-server condition.
/// (c) A change staged locally but "killed" before its push still
///     pushes on the next sync (History open).
/// (d) A failed push leaves the entry visibly Not synced, with the
///     new values kept — never silently Synced, never rolled back.
///
/// Plus the outbox durability units the widget proofs stand on:
/// stage-before-push ordering on disk, failed-state persistence,
/// account-owner binding, mid-flight edit survival, and the
/// merge-over-stale-pull overlay.

const _categories = <Map<String, dynamic>>[
  {
    'id': 6,
    'name': 'Mood & Energy',
    'icon': 'circle',
    'colorHex': '#FFD93D',
    'isDefault': true,
    'sortOrder': 5,
  },
  {
    'id': 3,
    'name': 'Symptoms',
    'icon': 'circle',
    'colorHex': '#4ECDC4',
    'isDefault': true,
    'sortOrder': 1,
  },
  {
    'id': 7,
    'name': 'General',
    'icon': 'circle',
    'colorHex': '#CCCCCC',
    'isDefault': true,
    'sortOrder': 0,
  },
];

const _owner = 'founder@example.com';

QuickLogEntry _entry({
  int id = 42,
  int categoryId = 3,
  String body = 'Brain fog all morning',
  int? ts,
}) {
  return QuickLogEntry(
    id: id,
    categoryId: categoryId,
    body: body,
    chips: '["Symptoms"]',
    manualText: '',
    timestamp: ts ?? DateTime(2026, 10, 12, 9, 30).millisecondsSinceEpoch,
  );
}

/// Fake server with a gateable, failable entries POST. The sync pull
/// always reflects only what a POST actually applied.
class _Server {
  _Server(this.entries, {this.failPosts = false});

  final List<Map<String, dynamic>> entries;
  bool failPosts;

  /// When set, POST attempts numbered at or above this value fail
  /// (500) without applying — for superseded-push scenarios.
  int? failFromAttempt;
  bool failDeletes = false;
  Completer<void>? postGate;
  final List<Map<String, dynamic>> capturedPosts = [];
  final List<int> deletedIds = [];
  int postAttempts = 0;
  int deleteAttempts = 0;
  final Completer<void> firstPostStarted = Completer<void>();

  TabsBackend backend() {
    final store = FakeSessionStore()
      ..token = 'test-token'
      ..email = _owner;
    final client = MockClient((request) async {
      if (request.url.path == '/api/sync/pull') {
        return http.Response(
          jsonEncode({
            'entries': entries,
            'categories': _categories,
            'profile': <String, dynamic>{},
            'isUnlimited': true,
            'isAdmin': false,
          }),
          200,
        );
      }
      if (request.url.path == '/api/sync/entries' && request.method == 'POST') {
        postAttempts++;
        if (!firstPostStarted.isCompleted) firstPostStarted.complete();
        final gate = postGate;
        if (gate != null) await gate.future;
        final failFrom = failFromAttempt;
        if (failPosts || (failFrom != null && postAttempts >= failFrom)) {
          return http.Response('server error', 500);
        }
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        final rows = (decoded['entries'] as List).cast<Map<String, dynamic>>();
        capturedPosts.addAll(rows);
        for (final row in rows) {
          final i = entries.indexWhere((e) => e['id'] == row['id']);
          if (i >= 0) {
            entries[i] = {...entries[i], ...row};
          } else {
            entries.add(row);
          }
        }
        return http.Response('{"ok":true}', 200);
      }
      if (request.url.path.startsWith('/api/sync/entries/') &&
          request.method == 'DELETE') {
        deleteAttempts++;
        if (failDeletes) return http.Response('server error', 500);
        final id = int.tryParse(request.url.path.split('/').last);
        if (id != null) {
          deletedIds.add(id);
          entries.removeWhere((e) => e['id'] == id);
        }
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    });
    return TabsBackend(client: client, sessionStore: store);
  }
}

/// Bounded settle: pump in 100ms steps until [condition] holds or
/// the cap is hit. Used for screen loads instead of pumpAndSettle —
/// the skeleton shimmer is a repeating animation, so pumpAndSettle
/// burns its whole timeout whenever a load spans more than one
/// frame (the repo's Quick Log suites use explicit timed pumps for
/// the same reason). The cap is deep on purpose: in the fake-async
/// zone each pump advances the load's future chain only so far, and
/// a primed outbox + shared pull makes that chain long. The
/// caller's expects still gate the result.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 300,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Map<String, String> disk;

  setUp(() {
    // The pull cache is a static session-keyed map (see the r42
    // suite) — reset it so no case inherits another's pull body.
    TabsBackend.debugResetSharedCaches();
    disk = <String, String>{};
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async => disk[key] = value,
      delete: (key) async => disk.remove(key),
    );
    final quickDisk = <String, String>{};
    QuickLogCache.instance.debugReset();
    QuickLogCache.instance.debugSetStore(
      read: (key) async => quickDisk[key],
      write: (key, value) async => quickDisk[key] = value,
      delete: (key) async => quickDisk.remove(key),
    );
    final homeDisk = <String, String>{};
    HomeDataCache.instance.debugReset();
    HomeDataCache.instance.debugSetStore(
      read: (key) async => homeDisk[key],
      write: (key, value) async => homeDisk[key] = value,
      delete: (key) async => homeDisk.remove(key),
    );
    WidgetSync.debugSetBridge(
      save: (key, value) async {},
      update: () async {},
    );
  });

  tearDown(() {
    WidgetSync.debugResetBridge();
    LogEntryOutbox.instance.debugReset();
    QuickLogCache.instance.debugReset();
    HomeDataCache.instance.debugReset();
  });

  group('outbox durability (unit)', () {
    test(
        'stage writes the disk blob BEFORE any push; a killed '
        'process reloads it and flushes exactly once', () async {
      final outbox = LogEntryOutbox.instance;
      final staged = await outbox.stage(
        _entry(id: 99),
        serverKnown: false,
        ownerEmail: _owner,
      );
      expect(staged, isTrue);
      // Ordering proof: the entry is already durable on disk, and
      // no backend has been touched yet.
      final blob =
          jsonDecode(disk[LogEntryOutbox.storageKey]!) as Map<String, dynamic>;
      expect(blob['ownerEmail'], _owner);
      final records = blob['records'] as List;
      expect(records, hasLength(1));
      expect((records.single as Map)['entry']['id'], 99);

      // Simulate the OS killing the app before the push: all
      // in-memory state is gone, the disk blob survives.
      outbox.debugReset();
      expect(outbox.records, isEmpty);
      await outbox.load(ownerEmail: _owner);
      expect(outbox.records.single.entry.id, 99);
      expect(outbox.statusFor(99), LogEntrySyncStatus.pending);

      final server = _Server([]);
      final ok = await outbox.flush(server.backend());
      expect(ok, isTrue);
      expect(server.capturedPosts, hasLength(1));
      expect(server.capturedPosts.single['id'], 99);
      expect(outbox.records, isEmpty);
    });

    test(
        'a failed push persists the failed state and the entry; '
        'the retry lands when the server recovers', () async {
      final outbox = LogEntryOutbox.instance;
      await outbox.stage(
        _entry(id: 7),
        serverKnown: true,
        ownerEmail: _owner,
      );
      final server = _Server([], failPosts: true);
      expect(await outbox.flush(server.backend()), isFalse);
      expect(outbox.statusFor(7), LogEntrySyncStatus.failed);

      // The failed state itself is durable across a kill.
      outbox.debugReset();
      await outbox.load(ownerEmail: _owner);
      expect(outbox.statusFor(7), LogEntrySyncStatus.failed);
      expect(outbox.records.single.entry.body, 'Brain fog all morning');

      server.failPosts = false;
      expect(await outbox.flush(server.backend()), isTrue);
      expect(server.capturedPosts.single['id'], 7);
      expect(outbox.records, isEmpty);
    });

    test(
        'a different account loading the outbox drops the queue '
        'instead of leaking it', () async {
      final outbox = LogEntryOutbox.instance;
      await outbox.stage(
        _entry(id: 5),
        serverKnown: false,
        ownerEmail: 'a@example.com',
      );
      outbox.debugReset();
      await outbox.load(ownerEmail: 'b@example.com');
      expect(outbox.records, isEmpty);
    });

    test('an edit staged mid-flight survives the older push landing', () async {
      final outbox = LogEntryOutbox.instance;
      final v1 = _entry(id: 42, categoryId: 3);
      await outbox.stage(v1, serverKnown: true, ownerEmail: _owner);
      final server = _Server([v1.toSyncJson()]);
      server.postGate = Completer<void>();
      final flushFuture = outbox.flush(server.backend());
      await server.firstPostStarted.future;
      // The user edits the same entry again while v1 is in flight.
      await outbox.stage(
        _entry(id: 42, categoryId: 7),
        serverKnown: true,
        ownerEmail: _owner,
      );
      server.postGate!.complete();
      expect(await flushFuture, isTrue);
      // Both versions pushed, in order; the server ends on v2 and
      // nothing was discarded by v1's late confirmation.
      expect(server.capturedPosts.map((r) => r['categoryId']), [3, 7]);
      expect(server.entries.single['categoryId'], 7);
      expect(outbox.records, isEmpty);
    });

    test('merge overlays pending versions over a stale pull', () async {
      final outbox = LogEntryOutbox.instance;
      await outbox.stage(
        _entry(id: 42, categoryId: 7),
        serverKnown: true,
        ownerEmail: _owner,
      );
      await outbox.stage(
        _entry(
          id: 100,
          categoryId: 7,
          body: 'New local entry',
          ts: DateTime(2026, 10, 12, 10, 0).millisecondsSinceEpoch,
        ),
        serverKnown: false,
        ownerEmail: _owner,
      );
      final merged = outbox.merge([_entry(id: 42, categoryId: 3)]);
      expect(merged, hasLength(2));
      expect(merged.firstWhere((e) => e.id == 42).categoryId, 7);
      expect(
        merged.firstWhere((e) => e.id == 100).body,
        'New local entry',
      );
    });

    test(
        'an in-flight push is joinable: settle waits for the gate, '
        'then the row is server-known', () async {
      final outbox = LogEntryOutbox.instance;
      await outbox.stage(
        _entry(id: 55),
        serverKnown: false,
        ownerEmail: _owner,
      );
      final server = _Server([]);
      server.postGate = Completer<void>();
      final flushFuture = outbox.flush(server.backend());
      for (var i = 0; i < 50 && !outbox.inFlightIds.contains(55); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(outbox.inFlightIds, contains(55));
      var settled = false;
      final settleFuture =
          outbox.settleInFlightPush().then((_) => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      server.postGate!.complete();
      await settleFuture;
      expect(await flushFuture, isTrue);
      expect(settled, isTrue);
      expect(outbox.records, isEmpty);
      // The confirmation outlives the queue record: classification
      // (delete staging, later edits) still knows the server holds
      // the row before any revalidating pull lands.
      expect(outbox.isServerKnown(55), isTrue);
    });

    test(
        'listeners are notified only after the staged write is '
        'durable — never before', () async {
      final outbox = LogEntryOutbox.instance;
      final gate = Completer<void>();
      outbox.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          await gate.future;
          disk[key] = value;
        },
        delete: (key) async => disk.remove(key),
      );
      final seenAtNotify = <List<int>>[];
      void listener() => seenAtNotify.add(
            [for (final r in outbox.records) r.entry.id],
          );
      outbox.addListener(listener);
      addTearDown(() => outbox.removeListener(listener));

      final stageFuture = outbox.stage(
        _entry(id: 56),
        serverKnown: false,
        ownerEmail: _owner,
      );
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      // The write is still gated: no notification may have observed
      // the staged record yet.
      expect(
        seenAtNotify.every((ids) => !ids.contains(56)),
        isTrue,
        reason: 'notifications before durability: $seenAtNotify',
      );
      gate.complete();
      expect(await stageFuture, isTrue);
      expect(seenAtNotify.last, contains(56));
    });

    test(
        'a failed stage write rolls back and never surfaces the '
        'entry to listeners', () async {
      final outbox = LogEntryOutbox.instance;
      outbox.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async => throw StateError('disk full'),
        delete: (key) async => disk.remove(key),
      );
      final seenAtNotify = <List<int>>[];
      void listener() => seenAtNotify.add(
            [for (final r in outbox.records) r.entry.id],
          );
      outbox.addListener(listener);
      addTearDown(() => outbox.removeListener(listener));

      final ok = await outbox.stage(
        _entry(id: 57),
        serverKnown: false,
        ownerEmail: _owner,
      );
      expect(ok, isFalse);
      expect(outbox.records, isEmpty);
      expect(seenAtNotify.every((ids) => !ids.contains(57)), isTrue);
    });
  });

  group('widget proofs', () {
    testWidgets(
        '(a) Quick Log submit completes on screen while the '
        'server push is still gated', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final server = _Server([_entry(id: 1, ts: now).toSyncJson()]);
      server.postGate = Completer<void>();
      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(
          backend: server.backend(),
          outbox: LogEntryOutbox.instance,
        ),
      ));
      // Bounded pumps (the Quick Log suites avoid pumpAndSettle).
      await _pumpUntil(
        tester,
        () => find.text('Symptoms').evaluate().isNotEmpty,
      );
      expect(find.text('Symptoms'), findsWidgets);

      await tester.enterText(find.byType(TextField).first, 'Dizzy spell');
      await tester.pump();
      await tester.tap(find.byTooltip('Log typed note'));
      await _pumpUntil(
        tester,
        () => find.text('Entry logged · 2 today').evaluate().isNotEmpty,
      );

      // The push was attempted and is STILL in flight (gate shut)…
      expect(server.postAttempts, 1);
      expect(server.capturedPosts, isEmpty);
      // …yet the log flow already completed on screen: confirmation
      // with the new count, the field cleared, no spinner anywhere.
      expect(find.text('Entry logged · 2 today'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, isEmpty);
      // And the entry sits in the outbox as pending, not "synced".
      expect(
        LogEntryOutbox.instance.statusFor(2),
        LogEntrySyncStatus.pending,
      );

      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      expect(LogEntryOutbox.instance.records, isEmpty);
      expect(server.capturedPosts.single['body'], 'Dizzy spell');
      // Flush the snackbar's dismiss timer and the backend
      // request-timeout timer so the test tears down clean (the
      // r19c suites do the same for stalled requests).
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets(
        '(b) category edit renders the new category while '
        'the server push is still gated', (tester) async {
      final server = _Server([_entry().toSyncJson()]);
      server.postGate = Completer<void>();
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: LogEntryOutbox.instance,
        ),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Brain fog all morning').evaluate().isNotEmpty,
      );
      expect(find.text('Brain fog all morning'), findsOneWidget);

      await tester.tap(find.text('Brain fog all morning'));
      await _pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('GENERAL'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The dialog adopted the tapped category immediately…
      // (the name renders twice in the dialog: the category chip
      // and the entry's current-category label — both are the new
      // category, which is exactly the adoption being proven).
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('General'),
        ),
        findsWidgets,
      );
      // …the card behind it already shows the pending badge…
      expect(find.text('Syncing'), findsOneWidget);
      // …and the server has received NOTHING yet.
      expect(server.postAttempts, 1);
      expect(server.capturedPosts, isEmpty);
      expect(server.entries.single['categoryId'], 3);

      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.records.isEmpty,
      );
      await tester.pump();
      await tester.pump();
      expect(server.capturedPosts.single['categoryId'], 7);
      await tester.tap(find.text('Close'));
      await _pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isEmpty,
      );
      expect(find.text('Synced'), findsOneWidget);
      expect(find.text('Syncing'), findsNothing);
      expect(LogEntryOutbox.instance.records, isEmpty);
    });

    testWidgets(
        '(c) an edit staged before an app kill pushes on '
        'the next History open', (tester) async {
      final server = _Server([_entry().toSyncJson()]);
      final outbox = LogEntryOutbox.instance;
      // A category edit saved locally in a session that died before
      // its background push could run.
      final edited = editedEntryCategory(
        _entry(),
        const QuickLogCategory(
          id: 7,
          name: 'General',
          icon: 'circle',
          colorHex: '#CCCCCC',
          isDefault: true,
          sortOrder: 0,
        ),
      );
      // Seeded through runAsync: a bare awaited outbox future in a
      // testWidgets body can stall in the fake-async zone (the same
      // reason the screens' chains are pump-driven below).
      await tester.runAsync(
        () => outbox.stage(edited, serverKnown: true, ownerEmail: _owner),
      );
      outbox.debugReset(); // process death: memory gone, disk stays

      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: LogEntryOutbox.instance,
        ),
      ));
      await _pumpUntil(
        tester,
        () =>
            server.capturedPosts.isNotEmpty &&
            find.text('Synced').evaluate().isNotEmpty,
      );

      // The next sync trigger (History open) pushed the staged edit…
      expect(server.capturedPosts, hasLength(1));
      expect(server.capturedPosts.single['id'], 42);
      expect(server.capturedPosts.single['categoryId'], 7);
      // …and the row renders the edited category, fully Synced.
      expect(find.text('General'), findsWidgets);
      expect(find.text('Synced'), findsOneWidget);
      expect(LogEntryOutbox.instance.records, isEmpty);
    });

    testWidgets(
        '(d) a failed push keeps the new category on screen '
        'and reads Not synced', (tester) async {
      final server = _Server([_entry().toSyncJson()], failPosts: true);
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: LogEntryOutbox.instance,
        ),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Brain fog all morning').evaluate().isNotEmpty,
      );
      expect(find.text('Brain fog all morning'), findsOneWidget);

      await tester.tap(find.text('Brain fog all morning'));
      await _pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('GENERAL'));
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.failedIds.contains(42),
      );

      // The edit stands (no revert, no inline save error)…
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('General'),
        ),
        findsWidgets,
      );
      expect(find.text("Couldn't save that change — try again."), findsNothing);
      await tester.tap(find.text('Close'));
      await _pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isEmpty,
      );
      // …the card honestly reads Not synced…
      expect(find.text('Not synced'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
      // …the server still holds the old category…
      expect(server.entries.single['categoryId'], 3);
      // …and the edit remains queued, marked failed, for retry.
      expect(LogEntryOutbox.instance.failedIds, contains(42));
      expect(
        LogEntryOutbox.instance.recordFor(42)!.entry.categoryId,
        7,
      );
    });

    testWidgets(
        '(e) deleting a row whose create is still in flight '
        'joins the push, then deletes on the server', (tester) async {
      final server = _Server([]);
      server.postGate = Completer<void>();
      final outbox = LogEntryOutbox.instance;
      // A local-only entry, staged before History opens (seeded via
      // runAsync — see (c) for why bare body awaits are avoided).
      await tester.runAsync(
        () => outbox.stage(
          _entry(id: 77, body: 'Local only note'),
          serverKnown: false,
          ownerEmail: _owner,
        ),
      );

      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: server.backend(), outbox: outbox),
      ));
      // History's open kicked the retry flush; the push is gated
      // mid-flight with the staged row on screen.
      await _pumpUntil(tester, () => server.postAttempts == 1);
      await _pumpUntil(
        tester,
        () => find.text('Local only note').evaluate().isNotEmpty,
      );
      expect(outbox.inFlightIds, contains(77));

      // Ask to delete it and confirm.
      await tester.tap(find.byTooltip('Delete entry'));
      await _pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // The delete is JOINING the in-flight push, not racing it:
      // the row is still on screen, no DELETE has been issued, and
      // the push has not landed yet either.
      expect(find.text('Local only note'), findsOneWidget);
      expect(server.deleteAttempts, 0);
      expect(server.entries, isEmpty);

      // The push lands — and only then does the delete proceed,
      // on the server, so the row cannot resurrect on the next pull.
      server.postGate!.complete();
      await _pumpUntil(
        tester,
        () =>
            server.deletedIds.contains(77) &&
            find.text('Local only note').evaluate().isEmpty,
      );
      expect(server.capturedPosts.map((e) => e['id']), contains(77));
      expect(server.entries.where((e) => e['id'] == 77), isEmpty);
      expect(find.text('Local only note'), findsNothing);
      expect(outbox.records, isEmpty);
    });

    testWidgets(
        '(f) before the outbox disk load lands, a staged '
        'row reads Syncing — never Synced', (tester) async {
      // Put a FAILED record for entry 42 on disk, then wipe memory:
      // the next History open must load it from the blob.
      final server = _Server([_entry(id: 42).toSyncJson()])..failPosts = true;
      final outbox = LogEntryOutbox.instance;
      await tester.runAsync(() async {
        await outbox.stage(
          _entry(id: 42),
          serverKnown: true,
          ownerEmail: _owner,
        );
        await outbox.flush(server.backend());
      });
      expect(outbox.failedIds, contains(42));
      outbox.debugReset();
      expect(outbox.isLoaded, isFalse);

      // Gate the disk read so the load stays in flight while the
      // pull renders the row.
      final readGate = Completer<void>();
      outbox.debugSetStore(
        read: (key) async {
          await readGate.future;
          return disk[key];
        },
        write: (key, value) async => disk[key] = value,
        delete: (key) async => disk.remove(key),
      );

      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: server.backend(), outbox: outbox),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Brain fog all morning').evaluate().isNotEmpty,
      );
      // The row is up from the pull, but its staged state is still
      // unknown: the badge must not claim Synced.
      expect(find.text('Syncing'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
      expect(find.text('Not synced'), findsNothing);

      // The load lands: the badge corrects itself to the truth.
      readGate.complete();
      await _pumpUntil(
        tester,
        () => find.text('Not synced').evaluate().isNotEmpty,
      );
      expect(find.text('Not synced'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
    });

    testWidgets('(g) a create confirmed mid-edit keeps its '
        'server-known classification: delete issues a server DELETE',
        (tester) async {
      // The first POST (v1) succeeds; every later POST (v2) fails.
      final server = _Server([]);
      final gate = Completer<void>();
      server.postGate = gate;
      server.failFromAttempt = 2;
      final outbox = LogEntryOutbox.instance;
      await tester.runAsync(
        () => outbox.stage(
          _entry(id: 88),
          serverKnown: false,
          ownerEmail: _owner,
        ),
      );

      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(backend: server.backend(), outbox: outbox),
      ));
      // The open kicked the flush; v1's push is gated mid-flight.
      await _pumpUntil(tester, () => server.postAttempts == 1);
      // Edit the row again while its create is on the wire (v2).
      await tester.runAsync(
        () => outbox.stage(
          _entry(id: 88, categoryId: 7),
          serverKnown: false,
          ownerEmail: _owner,
        ),
      );
      gate.complete();
      // v1 lands on the server; v2's push fails and stays queued.
      await _pumpUntil(tester, () => outbox.failedIds.contains(88));
      expect(server.entries.single['categoryId'], 3);
      // The superseded push's confirmation is NOT forgotten: the
      // surviving record is classified server-known.
      expect(outbox.recordFor(88)!.serverKnown, isTrue);
      expect(outbox.isServerKnown(88), isTrue);

      // Deleting now must cancel the queued edit AND issue the
      // server DELETE — a local-only classification would skip it
      // and the server's v1 would resurrect on the next pull.
      await tester.tap(find.byTooltip('Delete entry'));
      await _pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await _pumpUntil(
        tester,
        () =>
            server.deletedIds.contains(88) &&
            find.text('Brain fog all morning').evaluate().isEmpty,
      );
      expect(server.entries, isEmpty);
      expect(outbox.records, isEmpty);
    });
  });

  group('Vera fix regressions (F1/F2/F3/F5)', () {
    /// The AccountActions funnel clears every account-bound
    /// singleton; wire them all to in-memory IO (the migraine
    /// wipe suite's pattern) so the real funnel completes
    /// against fakes.
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
      wire(MigraineAttackStore.instance);
    }

    AccountActions actionsFor(_Server server, FakeSessionStore session) {
      final settingsMap = <String, String>{};
      return AccountActions(
        backend: server.backend(),
        sessionStore: session,
        settingsStore: SettingsStore.withStorage(
          read: (k) async => settingsMap[k],
          write: (k, v) async => settingsMap[k] = v,
          delete: (k) async => settingsMap.remove(k),
        ),
      );
    }

    test(
        'F1: allocateEntryId waits for the disk load and never '
        'reuses a killed session\'s pending id', () async {
      final outbox = LogEntryOutbox.instance;
      // Session 1: an entry staged offline; the app is killed
      // before its push. Its id (101) exists ONLY on disk.
      await outbox.stage(
        _entry(id: 101, body: 'Killed session entry'),
        serverKnown: false,
        ownerEmail: _owner,
      );
      outbox.debugReset();

      // Relaunch with the disk read gated (the shape of test (f)).
      // The old screen code allocated synchronously in exactly this
      // window: maxId was still 0 in memory, the server max was
      // 100, so the new entry took 101 and stage() overwrote the
      // pending record.
      final readGate = Completer<void>();
      outbox.debugSetStore(
        read: (key) async {
          await readGate.future;
          return disk[key];
        },
        write: (key, value) async => disk[key] = value,
        delete: (key) async => disk.remove(key),
      );
      var allocationDone = false;
      final allocFuture = outbox
          .allocateEntryId(serverMaxId: 100, ownerEmail: _owner)
          .then((id) {
        allocationDone = true;
        return id;
      });
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(allocationDone, isFalse,
          reason: 'allocation returned before the load landed — '
              'the F1 collision window is open');
      readGate.complete();
      final newId = await allocFuture;
      expect(newId, 102);
      // The raised high-water mark is itself durable, so even an
      // allocation that is never staged cannot be reused after
      // another kill.
      final blob =
          jsonDecode(disk[LogEntryOutbox.storageKey]!) as Map<String, dynamic>;
      expect(blob['nextIdHighWater'], 102);

      await outbox.stage(
        _entry(
          id: newId,
          body: 'Relaunch entry',
          ts: DateTime(2026, 10, 12, 10, 0).millisecondsSinceEpoch,
        ),
        serverKnown: false,
        ownerEmail: _owner,
      );
      // BOTH entries survive in the outbox…
      expect(outbox.records.map((r) => r.entry.id), containsAll([101, 102]));
      // …and both push.
      final server = _Server([]);
      expect(await outbox.flush(server.backend()), isTrue);
      expect(server.capturedPosts.map((r) => r['id']), containsAll([101, 102]));
      expect(
        server.capturedPosts.map((r) => r['body']),
        containsAll(['Killed session entry', 'Relaunch entry']),
      );
    });

    testWidgets(
        '(h) F1: Quick Log logged before the relaunch load lands '
        'gets a fresh id — the killed session\'s pending entry '
        'survives and both push', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final server = _Server([_entry(id: 1, ts: now).toSyncJson()]);
      final outbox = LogEntryOutbox.instance;
      // A pending entry from a session the OS killed before its
      // push: id 2 exists only in the disk blob.
      await tester.runAsync(
        () => outbox.stage(
          _entry(id: 2, body: 'Killed session entry', ts: now),
          serverKnown: false,
          ownerEmail: _owner,
        ),
      );
      outbox.debugReset();

      // Gate the relaunch disk read, exactly like test (f).
      final readGate = Completer<void>();
      outbox.debugSetStore(
        read: (key) async {
          await readGate.future;
          return disk[key];
        },
        write: (key, value) async => disk[key] = value,
        delete: (key) async => disk.remove(key),
      );

      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(backend: server.backend(), outbox: outbox),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Symptoms').evaluate().isNotEmpty,
      );
      await tester.enterText(find.byType(TextField).first, 'Fresh entry');
      await tester.pump();
      await tester.tap(find.byTooltip('Log typed note'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The save is parked on the outbox load: no confirmation yet,
      // and (on the old code this is where the entry took id 2 and
      // overwrote the pending record) nothing has been staged.
      expect(find.textContaining('Entry logged'), findsNothing);
      expect(outbox.records, isEmpty);

      readGate.complete();
      await _pumpUntil(
        tester,
        () => find.text('Entry logged · 3 today').evaluate().isNotEmpty,
      );
      await _pumpUntil(
        tester,
        () => server.capturedPosts.length >= 2,
      );
      // Both entries pushed, with their own ids and bodies — the
      // pending record was NOT overwritten by the relaunch entry.
      final byId = {for (final r in server.capturedPosts) r['id']: r['body']};
      expect(byId[2], 'Killed session entry');
      expect(byId[3], 'Fresh entry');
      expect(outbox.records, isEmpty);
      // Drain the snackbar + request timers (see test (a)).
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });

    test(
        'F2 logout: a failed flush retains pending entries '
        'owner-bound; the same account\'s return restores and '
        'flushes them', () async {
      wireFunnelCaches();
      final outbox = LogEntryOutbox.instance;
      await outbox.stage(
        _entry(id: 201, body: 'Offline logout entry'),
        serverKnown: false,
        ownerEmail: _owner,
      );
      // Offline logout: every entries POST fails, so the logout
      // flush cannot confirm the entry.
      final server = _Server([], failPosts: true);
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = _owner;
      await actionsFor(server, session).logout();
      // The logout itself completed (session gone)…
      expect(session.token, isNull);
      expect(session.email, isNull);
      // …but the pending entry was NOT wiped with the caches: the
      // owner-bound blob is still on disk.
      expect(disk.containsKey(LogEntryOutbox.storageKey), isTrue);
      outbox.debugReset();
      await outbox.load(ownerEmail: _owner);
      expect(outbox.records.single.entry.id, 201);
      expect(outbox.records.single.entry.body, 'Offline logout entry');
      // The same account returns and the entry finally pushes.
      server.failPosts = false;
      expect(await outbox.flush(server.backend()), isTrue);
      expect(server.capturedPosts.single['id'], 201);
      expect(outbox.records, isEmpty);
    });

    test(
        'F2 logout retention: a different account signing in '
        'afterwards never sees or pushes the retained entries',
        () async {
      wireFunnelCaches();
      final outbox = LogEntryOutbox.instance;
      await outbox.stage(
        _entry(id: 202, body: 'Retained entry'),
        serverKnown: false,
        ownerEmail: _owner,
      );
      final server = _Server([], failPosts: true);
      final session = FakeSessionStore()
        ..token = 'tok'
        ..refreshToken = 'ref'
        ..email = _owner;
      await actionsFor(server, session).logout();
      expect(outbox.records.single.entry.id, 202);

      // A DIFFERENT account signs in: main.dart's login wiring
      // runs the owner-mismatch enforcement before the shell
      // mounts, and the retained queue is dropped for them.
      final dropped = await outbox.clearIfOwnerMismatch('other@example.com');
      expect(dropped, isTrue);
      expect(outbox.records, isEmpty);
      outbox.debugReset();
      await outbox.load(ownerEmail: 'other@example.com');
      expect(outbox.records, isEmpty);
      // And there is nothing for the new account to push.
      final otherServer = _Server([]);
      expect(await outbox.flush(otherServer.backend()), isTrue);
      expect(otherServer.capturedPosts, isEmpty);
    });

    test(
        'F2 session expiry: retainUnconfirmed (the call main.dart\'s '
        'expiry handler makes) keeps failed entries for the owner\'s '
        'return, and only the owner\'s', () async {
      final outbox = LogEntryOutbox.instance;
      await outbox.stage(
        _entry(id: 203, body: 'Expiry entry'),
        serverKnown: false,
        ownerEmail: _owner,
      );
      final server = _Server([], failPosts: true);
      expect(await outbox.flush(server.backend()), isFalse);
      expect(outbox.statusFor(203), LogEntrySyncStatus.failed);

      // Session expiry: the session is dead, so no flush attempt
      // is possible — retention replaces the old unconditional wipe.
      expect(await outbox.retainUnconfirmed(), isTrue);
      expect(disk.containsKey(LogEntryOutbox.storageKey), isTrue);
      outbox.debugReset();
      await outbox.load(ownerEmail: _owner);
      expect(outbox.statusFor(203), LogEntrySyncStatus.failed);
      // The same account's next session flushes its own entry.
      server.failPosts = false;
      expect(await outbox.flush(server.backend()), isTrue);
      expect(server.capturedPosts.single['id'], 203);

      // Nothing pending → nothing retained; the ordinary wipe
      // stands (the blob, owner stamp included, is gone).
      expect(await outbox.retainUnconfirmed(), isFalse);
      expect(disk.containsKey(LogEntryOutbox.storageKey), isFalse);

      // And retained entries are the owner's alone: a different
      // account's sign-in drops them before they can be seen.
      await outbox.stage(
        _entry(id: 204, body: 'Owner-bound entry'),
        serverKnown: false,
        ownerEmail: _owner,
      );
      expect(await outbox.retainUnconfirmed(), isTrue);
      expect(await outbox.clearIfOwnerMismatch('other@example.com'), isTrue);
      expect(outbox.records, isEmpty);
    });

    test(
        'F3: an unowned record and a corrupt record load without '
        'losing either — both are quarantined and the signal '
        'exposes them', () async {
      final outbox = LogEntryOutbox.instance;
      // A blob whose owner stamp was lost (the readEmail()-threw
      // stage path), holding one valid record and one record whose
      // JSON no longer parses.
      disk[LogEntryOutbox.storageKey] = jsonEncode({
        'ownerEmail': null,
        'records': [
          LogEntryOutboxRecord(entry: _entry(id: 301), serverKnown: false)
              .toJson(),
          {'serverKnown': true}, // no entry: fromJson rejects it
        ],
      });
      await outbox.load(ownerEmail: _owner);
      // Nothing is adopted into the account…
      expect(outbox.records, isEmpty);
      // …nothing is deleted either: both records are quarantined,
      // and the signal exposes them.
      expect(outbox.hasQuarantinedRecords, isTrue);
      expect(outbox.quarantinedRecordCount, 2);
      // A later persist (a new entry staged for this account)
      // re-embeds the quarantined raw records — the data is not
      // lost as a side effect of the next write.
      await outbox.stage(
        _entry(id: 302),
        serverKnown: false,
        ownerEmail: _owner,
      );
      final blob =
          jsonDecode(disk[LogEntryOutbox.storageKey]!) as Map<String, dynamic>;
      expect(blob['records'], hasLength(1));
      expect(blob['quarantinedRecords'], hasLength(2));
      // And the quarantine survives a restart: still visible,
      // still not adopted.
      outbox.debugReset();
      await outbox.load(ownerEmail: _owner);
      expect(outbox.quarantinedRecordCount, 2);
      expect(outbox.records.single.entry.id, 302);
    });

    testWidgets(
        '(i) F5: a Quick Log entry whose push fails shows Not '
        'synced in Quick Log itself', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final server = _Server([_entry(id: 1, ts: now).toSyncJson()],
          failPosts: true);
      await tester.pumpWidget(MaterialApp(
        home: QuickLogScreen(
          backend: server.backend(),
          outbox: LogEntryOutbox.instance,
        ),
      ));
      await _pumpUntil(
        tester,
        () => find.text('Symptoms').evaluate().isNotEmpty,
      );
      await tester.enterText(find.byType(TextField).first, 'Dizzy spell');
      await tester.pump();
      await tester.tap(find.byTooltip('Log typed note'));
      // The entry stages and its push fails…
      await _pumpUntil(
        tester,
        () => LogEntryOutbox.instance.failedIds.contains(2),
      );
      await _pumpUntil(
        tester,
        () => find.text('Not synced').evaluate().isNotEmpty,
      );
      // …and Quick Log itself (not only History) shows the
      // per-entry Not synced signal, with the History badge's copy.
      expect(find.text('Not synced'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
      expect(LogEntryOutbox.instance.statusFor(2),
          LogEntrySyncStatus.failed);
      // Drain the snackbar + request timers (see test (a)).
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
    });
  });
}
