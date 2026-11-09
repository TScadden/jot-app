import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/lean_test_session.dart';
import 'package:tabs_lab/src/data/lean_test_strings.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/tools/lean_test_screen.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';

import 'test_helpers.dart';

/// Session #1 safety pull (2026-11-09) — the guided lean test's
/// entry point is removed; the guided screens and the session
/// store stay dormant in the tree, and recorded lean-test history
/// stays viewable. This suite pins both halves of the decision:
///  1. The Tools surface exposes NO entry that can start the
///     guided flow — in the default state, and in the stale
///     saved-order state a pre-pull install can carry.
///  2. A fixture past lean-test result still renders in History
///     (the surface that survives the pull: lean results are
///     ordinary log entries filed under Symptoms, body built from
///     the payload at close).
/// Decision record:
/// team/memory/decisions/2026-11-09-lean-test-guided-flow-pulled.md

ToolOrderStore _memoryOrderStore([Map<String, String>? backing]) {
  final store = ToolOrderStore();
  final map = backing ?? <String, String>{};
  store.debugSetIO(
    read: (key) async => map[key],
    write: (key, value) async => map[key] = value,
  );
  return store;
}

Future<void> _pumpTools(WidgetTester tester, ToolOrderStore store) async {
  await tester.pumpWidget(
    MaterialApp(home: ToolsScreen(orderStore: store)),
  );
  await tester.pumpAndSettle();
}

/// Scrolls every default tile into view (the grid builds lazily),
/// so an absence assertion afterwards has actually visited the
/// whole grid.
Future<void> _visitWholeGrid(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: find.byType(GridView),
    matching: find.byType(Scrollable),
  );
  for (final tile in defaultToolTiles) {
    await tester.scrollUntilVisible(
      find.text(tile.title),
      300,
      scrollable: scrollable,
    );
  }
}

/// Collects every tile id the grid can present by dragging it
/// end to end. Works regardless of tile order (a saved order
/// reshuffles the grid, which directional scroll-until-visible
/// traversal cannot assume).
Future<Set<String>> _collectAllTileIds(WidgetTester tester) async {
  final ids = <String>{};
  for (var i = 0; i < 10; i++) {
    for (final d in tester.widgetList<LongPressDraggable<ToolTile>>(
        find.byType(LongPressDraggable<ToolTile>))) {
      if (d.data != null) ids.add(d.data!.id);
    }
    await tester.drag(find.byType(GridView), const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  return ids;
}

LeanTestResult _fixtureResult() => LeanTestResult(
      startedAtMs: DateTime(2026, 10, 27, 9).millisecondsSinceEpoch,
      outcome: 'completed',
      baselineReadings: [
        LeanCapture(
          minute: 9,
          tMs: DateTime(2026, 10, 27, 9, 9).millisecondsSinceEpoch,
          hr: 70,
          sys: 118,
          dia: 76,
        ),
      ],
      checkpoints: [
        LeanCapture(
          minute: 0,
          tMs: DateTime(2026, 10, 27, 9, 11).millisecondsSinceEpoch,
          hr: 92,
        ),
      ],
    );

void main() {
  group('Tools surface exposes no guided lean test entry', () {
    test('default tile list carries no lean-test tile', () {
      expect(defaultToolTiles.any((t) => t.id == 'lean_test'), isFalse);
      expect(defaultToolTiles.any((t) => t.title == leanS1Label), isFalse);
      expect(defaultToolTiles.length, 16);
    });

    test('a stale saved order cannot resurrect the tile', () {
      // Saved orders from before the pull can still list the
      // removed id; applyTileOrder drops unknown ids.
      final ordered =
          applyTileOrder(defaultToolTiles, ['lean_test', 'habits']);
      expect(ordered.length, 16);
      expect(ordered.any((t) => t.id == 'lean_test'), isFalse);
      expect(ordered.first.id, 'habits');
    });

    testWidgets('default state: no lean tile anywhere in the grid',
        (tester) async {
      await _pumpTools(tester, _memoryOrderStore());
      await _visitWholeGrid(tester);
      expect(find.text(leanS1Label), findsNothing);
      expect(find.text(leanS1Subtitle), findsNothing);
      expect(find.byType(LeanTestScreen), findsNothing);
    });

    testWidgets('stale saved-order state: lean id dropped, grid intact',
        (tester) async {
      final store = _memoryOrderStore();
      await store.saveOrder(['lean_test', 'medications', 'habits']);
      await _pumpTools(tester, store);
      // The surviving saved order is still honored (checked before
      // any scrolling moves the lazy grid's built window).
      final grid = find.byType(GridView);
      final firstCell = tester
          .widgetList<DragTarget<ToolTile>>(find.descendant(
              of: grid, matching: find.byType(DragTarget<ToolTile>)))
          .first;
      final draggable = find.descendant(
          of: find.byWidget(firstCell),
          matching: find.byType(LongPressDraggable<ToolTile>));
      expect(tester.widget<LongPressDraggable<ToolTile>>(draggable).data?.id,
          'medications');
      final ids = await _collectAllTileIds(tester);
      expect(ids, defaultToolTiles.map((t) => t.id).toSet());
      expect(ids.contains('lean_test'), isFalse);
      expect(find.text(leanS1Label), findsNothing);
      expect(find.text(leanS1Subtitle), findsNothing);
      expect(find.byType(LeanTestScreen), findsNothing);
    });

    test('no lib code outside the dormant screen constructs it', () {
      // The guided screen stays in the tree (dormant), so its own
      // file legitimately declares the constructor. Every other
      // lib file must be free of constructions and of the removed
      // gateway plumbing.
      final constructors = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        if (source.contains('LeanTestScreen(')) {
          constructors.add(entity.path.replaceAll('\\', '/'));
        }
        if (entity.path.endsWith('lean_test_screen.dart')) continue;
        expect(source.contains('leanGateway'), isFalse,
            reason: '${entity.path} still wires the lean gateway');
        expect(source.contains('leanTestTile'), isFalse,
            reason: '${entity.path} still references the pulled tile');
      }
      expect(constructors,
          ['lib/src/features/tools/lean_test_screen.dart']);
    });
  });

  group('past lean-test history stays viewable', () {
    setUp(() => TabsBackend.debugResetSharedCaches());

    test('payload derivation round-trips a fixture past result', () {
      final result = _fixtureResult();
      final entry = buildLeanTestEntry(id: 3, categoryId: 3, result: result);
      // Filed under Symptoms with the reserved chip, body built
      // from the payload — the shape History renders.
      expect(entry.categoryId, 3);
      expect(leanEntryHasChip(entry), isTrue);
      expect(entry.body, result.bodyText());
      expect(entry.body, contains('Guided lean test recorded'));
      expect(entry.body, contains('Completed all 10 minutes'));
      expect(entry.body, contains('92 bpm'));

      final past = leanPastResults([entry]);
      expect(past, hasLength(1));
      expect(past.single.completionLine, result.completionLine);
      expect(past.single.valueLines().join('\n'), contains('92 bpm'));
      expect(past.single.valueLines().join('\n'), contains('70 bpm'));
      expect(past.single.valueLines().join('\n'), contains('118/76 mmHg'));
    });

    testWidgets('History renders the fixture past result, '
        'with no way to start a new test from it', (tester) async {
      final result = _fixtureResult();
      final entry = buildLeanTestEntry(id: 3, categoryId: 3, result: result);
      final serverEntry = <String, dynamic>{
        'id': entry.id,
        'categoryId': entry.categoryId,
        'body': entry.body,
        'chips': entry.chips,
        'manualText': entry.manualText,
        'timestamp': entry.timestamp,
      };
      const categories = <Map<String, dynamic>>[
        {
          'id': 3,
          'name': 'Symptoms',
          'icon': 'circle',
          'colorHex': '#4ECDC4',
          'isDefault': true,
          'sortOrder': 1,
        },
      ];
      final sessionStore = FakeSessionStore()..token = 'test-token';
      final client = MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': [serverEntry],
              'categories': categories,
              'profile': <String, dynamic>{},
              'isUnlimited': true,
              'isAdmin': false,
            }),
            200,
            // The lean body carries an em dash; without a UTF-8
            // charset the http package decodes as latin1 and the
            // payload string fails JSON decoding. The real API
            // serves JSON as UTF-8.
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('not found', 404);
      });
      final backend = TabsBackend(client: client, sessionStore: sessionStore);

      final disk = <String, String>{};
      final outbox = LogEntryOutbox.instance;
      outbox.debugReset();
      outbox.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async => disk[key] = value,
        delete: (key) async => disk.remove(key),
      );

      await tester.pumpWidget(
        MaterialApp(home: HistoryScreen(backend: backend, outbox: outbox)),
      );
      await tester.pumpAndSettle();

      // The recorded result renders: completion line + values.
      expect(find.textContaining('Guided lean test recorded'),
          findsOneWidget);
      expect(find.textContaining('Completed all 10 minutes'),
          findsOneWidget);
      expect(find.textContaining('92 bpm'), findsWidgets);
      // Display only: no start/retake affordance, no guided screen.
      expect(find.text(leanS5), findsNothing);
      expect(find.text(leanN3Discard), findsNothing);
      expect(find.byType(LeanTestScreen), findsNothing);
    });
  });
}
