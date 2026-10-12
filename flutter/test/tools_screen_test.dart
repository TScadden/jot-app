import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart';
import 'package:tabs_lab/src/features/tools/tool_placeholder_screen.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';

ToolOrderStore _memoryStore([Map<String, String>? backing]) {
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

void main() {
  group('default tile list (native DEFAULT_INFO_TILES)', () {
    test('has all 16 tiles in native order', () {
      final ids = defaultToolTiles.map((t) => t.id).toList();
      expect(ids, [
        'habits',
        'reminders',
        'lists',
        'notes',
        'project_focus',
        'sleep',
        'body_info',
        'medications',
        'tips_and_tricks',
        'health_coach',
        'key_metrics',
        'trends',
        'blood_pressure',
        'food',
        'research',
        'community',
      ]);
    });

    test('titles and subtitles match native copy', () {
      final byId = {for (final t in defaultToolTiles) t.id: t};
      expect(byId['medications']!.title, 'Medications');
      expect(byId['medications']!.description, 'Prescriptions & Doses');
      expect(byId['habits']!.description, 'Daily routine tracking');
      expect(byId['reminders']!.description, 'Scheduled alerts');
      expect(byId['lists']!.description, 'Checklists & Tasks');
      expect(byId['notes']!.description, 'Quick notes & thoughts');
      expect(byId['project_focus']!.description, 'Track experiments');
      expect(byId['sleep']!.description, 'Analysis & Debt');
      expect(byId['body_info']!.description, 'Impact & Side Effects');
      expect(byId['blood_pressure']!.description, 'Systolic & Diastolic');
      expect(byId['food']!.description, 'Sensitivity Checker');
      expect(byId['research']!.description, 'Health research library');
      expect(byId['community']!.description, 'Friends & Leaderboard');
      expect(byId['tips_and_tricks']!.description, 'Master your data');
      expect(byId['health_coach']!.description, 'Personalized Advice');
      expect(byId['key_metrics']!.description, 'Your Body Data');
      expect(byId['trends']!.description, 'Patterns over time');
    });
  });

  group('applyTileOrder', () {
    test('saved order is respected', () {
      final ordered = applyTileOrder(defaultToolTiles, ['medications', 'habits']);
      expect(ordered.first.id, 'medications');
      expect(ordered[1].id, 'habits');
      expect(ordered.length, 16);
    });

    test('unknown ids are dropped', () {
      final ordered = applyTileOrder(defaultToolTiles, ['nope', 'habits']);
      expect(ordered.length, 16);
      expect(ordered.first.id, 'habits');
      expect(ordered.any((t) => t.id == 'nope'), isFalse);
    });

    test('tiles missing from saved order are appended in default order', () {
      final ordered = applyTileOrder(defaultToolTiles, ['notes']);
      expect(ordered.first.id, 'notes');
      // 'habits' was the native default first; it should follow 'notes'.
      expect(ordered[1].id, 'habits');
    });
  });

  group('moveTile', () {
    test('moves a tile forward', () {
      final next = moveTile(defaultToolTiles, 'habits', 'notes');
      expect(next.map((t) => t.id).take(4).toList(),
          ['reminders', 'lists', 'notes', 'habits']);
    });

    test('moves a tile backward', () {
      final next = moveTile(defaultToolTiles, 'notes', 'habits');
      expect(next.first.id, 'notes');
      expect(next[1].id, 'habits');
    });

    test('same position is a no-op returning the same instance', () {
      final next = moveTile(defaultToolTiles, 'habits', 'habits');
      expect(identical(next, defaultToolTiles), isTrue);
    });

    test('unknown ids are a no-op', () {
      expect(
          identical(
              moveTile(defaultToolTiles, 'nope', 'habits'), defaultToolTiles),
          isTrue);
      expect(
          identical(
              moveTile(defaultToolTiles, 'habits', 'nope'), defaultToolTiles),
          isTrue);
    });
  });

  group('ToolOrderStore', () {
    test('save/load round trip', () async {
      final store = _memoryStore();
      await store.saveOrder(['medications', 'habits']);
      expect(await store.loadOrder(), ['medications', 'habits']);
    });

    test('empty store returns null', () async {
      expect(await _memoryStore().loadOrder(), isNull);
    });

    test('corrupt JSON returns null instead of throwing', () async {
      final store = _memoryStore({ToolOrderStore.storageKey: 'not-json{'});
      expect(await store.loadOrder(), isNull);
    });

    test('non-list JSON returns null', () async {
      final store = _memoryStore({ToolOrderStore.storageKey: '{"a":1}'});
      expect(await store.loadOrder(), isNull);
    });
  });

  group('ToolsScreen widget', () {
    testWidgets('renders header, banner, and all tiles', (tester) async {
      await _pumpTools(tester, _memoryStore());
      expect(find.text('Tools'), findsOneWidget);
      expect(
          find.text('Explore your health resources. Long-press to reorder.'),
          findsOneWidget);
      // The grid is lazy: scroll each tile into view before asserting.
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
        expect(find.text(tile.title), findsWidgets);
        expect(find.text(tile.description), findsWidgets);
      }
    });

    testWidgets('applies a saved order on load', (tester) async {
      final store = _memoryStore();
      await store.saveOrder(['medications', 'habits']);
      await _pumpTools(tester, store);
      final grid = find.byType(GridView);
      final firstCell = tester
          .widgetList<DragTarget<ToolTile>>(
              find.descendant(of: grid, matching: find.byType(DragTarget<ToolTile>)))
          .first;
      // The first cell's draggable carries the first tile's data.
      final draggable = find.descendant(
          of: find.byWidget(firstCell),
          matching: find.byType(LongPressDraggable<ToolTile>));
      final data = tester
          .widget<LongPressDraggable<ToolTile>>(draggable)
          .data;
      expect(data?.id, 'medications');
    });

    testWidgets('tapping a card opens its real screen', (tester) async {
      await _pumpTools(tester, _memoryStore());
      await tester.tap(find.text('Habits').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(HabitsScreen), findsOneWidget);
    });

    testWidgets('back pops the tool screen', (tester) async {
      await _pumpTools(tester, _memoryStore());
      await tester.tap(find.text('Habits').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(HabitsScreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(HabitsScreen), findsNothing);
      expect(find.text('Tools'), findsOneWidget);
    });

    testWidgets('reorder button enters edit mode with Done pill',
        (tester) async {
      await _pumpTools(tester, _memoryStore());
      expect(find.text('Done'), findsNothing);
      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
      expect(find.text("Drag tiles to reorder. Tap 'Done' to save."),
          findsOneWidget);
      // Tapping a card in edit mode does not navigate.
      await tester.tap(find.text('Habits').first);
      await tester.pumpAndSettle();
      expect(find.byType(ToolPlaceholderScreen), findsNothing);
      // Done exits edit mode.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsNothing);
    });

    testWidgets('long-press drag enters edit mode', (tester) async {
      await _pumpTools(tester, _memoryStore());
      expect(find.text('Done'), findsNothing);
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('Habits').first));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump();
      expect(find.text('Done'), findsOneWidget);
    });
  });
}
