import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/workout_sync_store.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';

import 'test_helpers.dart';

/// Video-lessons Wave A REMAINDER — the pieces of PR #187 that did
/// not land in release via PR #188, ported onto release/vc100116:
/// - tabular figures on numeric readouts (SCORECARD-9 #16),
/// - History delete Undo toast (SCORECARD-9 #5) with Vera
///   Condition 1 (the outbox stage/restore bool is checked) and
///   Condition 3 (fetch generation guard) semantics.
///
/// Ported from PR #187's wave_a_video_lessons_test.dart. The port
/// initially kept release's workout-sync delete CONFIRM dialog
/// (PR #189) and pinned its presence; Juno's PR #190 ruling
/// reversed that: the dialog's "This cannot be undone." copy is
/// false on every path where the delete offers Undo, and every
/// History single-entry delete path in this screen offers Undo,
/// so the dialog is removed entirely. The Undo tests below pin
/// the dialog's ABSENCE before the delete (the original Wave A
/// assertion), and the tombstone group pins the Undo ↔
/// workout-sync interaction: Undo of a synced-workout delete
/// restores the entry AND lifts the tombstone via
/// WorkoutSyncStore.restoreLink.

void main() {
  setUp(() {
    TabsBackend.debugResetSharedCaches();
    WorkoutSyncStore.instance.debugReset();
  });

  group('tabular figures (SCORECARD-9 #16)', () {
    testWidgets('CountUp renders tabular figures and preserves the '
        'caller style', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: CountUp(
            value: 42,
            animate: false,
            style: TextStyle(fontSize: 20),
          ),
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.text('42'));
      expect(
        text.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(text.style!.fontSize, 20);
    });

    testWidgets('CountUp with no caller style still renders tabular',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CountUp(value: 7, animate: false)),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.text('7'));
      expect(
        text.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    testWidgets('vitals strip values render tabular', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: VitalsStrip(animateCountUps: false)),
      ));
      await tester.pump();
      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(texts, isNotEmpty);
      for (final t in texts) {
        expect(
          t.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
          reason: 'vitals text "${t.data}"',
        );
      }
    });

    testWidgets('Daily Score face number renders tabular',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: DailyScoreFace(score: 78, size: 100, showInnerLabel: true),
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.text('78'));
      expect(
        text.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    testWidgets('gem pill balance renders tabular', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: HomeGemPill(gemBalance: 1234)),
      ));
      await tester.pump();
      final text = tester.widget<Text>(
        find.byKey(const Key('homeGemPillCount')),
      );
      expect(
        text.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });
  });

  group('History delete Undo (SCORECARD-9 #5)', () {
    testWidgets(
        'delete shows NO confirm dialog (Juno ruling); Undo '
        'restores the entry at its index and re-posts it to the '
        'server', (tester) async {
      final server = _HistoryServer([
        _historyEntry(42, 'newest entry'),
        _historyEntry(7, 'oldest entry'),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: server.freshOutbox(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('newest entry'), findsOneWidget);
      expect(find.text('oldest entry'), findsOneWidget);

      // Delete the newest entry via its card delete button.
      // Juno ruling (PR #190): NO confirm dialog precedes a
      // deletion that will offer Undo — the delete proceeds
      // directly to the "Entry removed" snackbar.
      await tester.tap(find.byIcon(Icons.delete).first);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Delete entry?'), findsNothing);
      expect(find.text('This cannot be undone.'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      expect(find.text('newest entry'), findsNothing);
      expect(find.text('oldest entry'), findsOneWidget);
      expect(server.deletedIds, [42]);
      // The toast offers Undo.
      expect(find.text('Entry removed'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      // Restored at its original (top) position, and re-created on
      // the server through the entries upsert with its original id.
      expect(find.text('newest entry'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('newest entry')).dy,
        lessThan(tester.getTopLeft(find.text('oldest entry')).dy),
      );
      expect(server.upsertedIds, contains(42));
      expect(server.entries.map((e) => e['id']), contains(42));
    });

    testWidgets(
        'Undo with a failing outbox store surfaces the failure and '
        'does not restore the entry as Synced (Vera Condition 1)',
        (tester) async {
      final server = _HistoryServer([
        _historyEntry(42, 'newest entry'),
        _historyEntry(7, 'oldest entry'),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: server.failingOutbox(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('newest entry'), findsOneWidget);
      expect(find.text('oldest entry'), findsOneWidget);

      // Delete succeeds server-side with no confirm dialog
      // (Juno ruling, PR #190); the entry is gone.
      await tester.tap(find.byIcon(Icons.delete).first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('newest entry'), findsNothing);
      expect(server.deletedIds, [42]);
      expect(find.text('Undo'), findsOneWidget);

      // Undo: the outbox write fails, so stageForBackend returns
      // false. The failure must be surfaced and the entry must NOT
      // come back — a bool-ignoring _undoDelete reinserts it with
      // a Synced badge despite having no server row and no outbox
      // record, and this test fails against that mutation.
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't undo that delete — try again."),
        findsOneWidget,
      );
      expect(find.text('newest entry'), findsNothing);
      expect(find.text('oldest entry'), findsOneWidget);
      // The only Synced badge on screen is the oldest entry's:
      // the deleted entry is not shown as restored/Synced.
      expect(find.text('Synced'), findsOneWidget);
      // And nothing was re-created on the server.
      expect(server.upsertedIds, isNot(contains(42)));
      expect(server.entries.map((e) => e['id']), isNot(contains(42)));
    });
  });

  group('History Undo × workout-sync tombstone', () {
    testWidgets(
        'Undo of a synced-workout delete restores the entry AND '
        'lifts the tombstone (restoreLink)', (tester) async {
      // Warmed workout store holding the live link for entry 581,
      // over an in-memory disk (the workout_sync_history_test
      // harness pattern).
      final disk = <String, String>{};
      final store = WorkoutSyncStore.instance;
      store.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async => disk[key] = value,
        delete: (key) async => disk.remove(key),
      );
      await store.warmFromDisk(currentEmail: 'a@example.com');
      await store.recordLink(
        key: 'hc:uuid-581',
        entryId: 581,
        state: WorkoutLinkState.linked,
        origin: WorkoutLinkOrigin.synced,
        hcId: 'uuid-581',
      );

      final server = _HistoryServer([_syncedWorkoutEntry()]);
      await tester.pumpWidget(MaterialApp(
        home: HistoryScreen(
          backend: server.backend(),
          outbox: server.freshOutbox(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Walking · 34 min'), findsOneWidget);

      // Delete (no confirm dialog — Juno ruling, PR #190): the
      // link is tombstoned by the delete hook.
      await tester.tap(find.byIcon(Icons.delete).first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(server.deletedIds, [581]);
      expect(find.text('Walking · 34 min'), findsNothing);
      expect(
        store.linkForKey('hc:uuid-581')!.state,
        WorkoutLinkState.tombstoned,
      );
      expect(find.text('Undo'), findsOneWidget);

      // Undo: the entry returns AND the tombstone is lifted — the
      // link is live again, bound to the restored entry, so the
      // next workout sync keeps treating it as the live synced
      // entry instead of resurrecting-or-suppressing it as a
      // deleted one.
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Walking · 34 min'), findsOneWidget);
      expect(server.upsertedIds, contains(581));
      final link = store.linkForKey('hc:uuid-581');
      expect(link!.state, WorkoutLinkState.linked);
      expect(link.entryId, 581);
      expect(store.keyForEntry(581), 'hc:uuid-581');
    });
  });
}

Map<String, dynamic> _historyEntry(int id, String body) => {
      'id': id,
      'categoryId': 7,
      'body': body,
      'chips': '["General"]',
      'manualText': '',
      'timestamp':
          DateTime(2026, 11, 12, 12, id).millisecondsSinceEpoch,
    };

Map<String, dynamic> _syncedWorkoutEntry() => {
      'id': 581,
      'categoryId': 7,
      'body': 'Walking · 34 min',
      'chips': 'Workout, Health Connect',
      'manualText': 'avg HR 85 · max HR 119',
      'timestamp':
          DateTime(2026, 11, 26, 11).millisecondsSinceEpoch,
    };

const _historyCategories = <Map<String, dynamic>>[
  {
    'id': 7,
    'name': 'General',
    'icon': 'circle',
    'colorHex': '#CCCCCC',
    'isDefault': true,
    'sortOrder': 0,
  },
];

/// Stateful fake server: DELETE removes the row, the entries POST
/// (the outbox upsert) re-creates it — exactly the contract the Undo
/// path relies on.
class _HistoryServer {
  final List<Map<String, dynamic>> entries;
  final List<int> deletedIds = [];
  final List<int> upsertedIds = [];

  _HistoryServer(this.entries);

  TabsBackend backend() {
    final store = FakeSessionStore()..token = 'wave-a-token';
    final client = MockClient((request) async {
      if (request.url.path == '/api/sync/pull') {
        return http.Response(
          jsonEncode({
            'entries': entries,
            'categories': _historyCategories,
            'profile': <String, dynamic>{},
            'isUnlimited': true,
            'isAdmin': false,
          }),
          200,
        );
      }
      if (request.url.path.startsWith('/api/sync/entries/') &&
          request.method == 'DELETE') {
        final id = int.parse(request.url.pathSegments.last);
        deletedIds.add(id);
        entries.removeWhere((e) => e['id'] == id);
        return http.Response('{"ok":true}', 200);
      }
      if (request.url.path == '/api/sync/entries' &&
          request.method == 'POST') {
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        for (final raw in (decoded['entries'] as List)) {
          final entry = (raw as Map).cast<String, dynamic>();
          upsertedIds.add(entry['id'] as int);
          entries.removeWhere((e) => e['id'] == entry['id']);
          entries.add(entry);
        }
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('not found', 404);
    });
    return TabsBackend(client: client, sessionStore: store);
  }

  LogEntryOutbox freshOutbox() {
    final disk = <String, String>{};
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async => disk[key] = value,
      delete: (key) async => disk.remove(key),
    );
    return outbox;
  }

  /// Vera Condition 1: an outbox whose disk load succeeds (empty
  /// disk) but whose every WRITE fails, so stage/restore persist
  /// fails and returns false — the C-01 failure mode.
  LogEntryOutbox failingOutbox() {
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => null,
      write: (key, value) async {
        throw StateError('failing outbox store: write failed');
      },
      delete: (key) async {},
    );
    return outbox;
  }
}
