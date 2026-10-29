import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/food_screen.dart';

import 'test_helpers.dart';

/// VC 100110 fix round — Vera Focus 5c regression tests.
///
/// The defect: `_enforceOwnerThenLoad` awaits
/// `SessionStore().readEmail()` with NO timeout before
/// `_loadEncyclopedia` is ever called. If that secure-storage
/// read wedges (never completes, never throws), the load never
/// runs, the in-memory encyclopedia stays history-less, and the
/// user's next successful check whole-value overwrites the
/// persisted `food_checker_history` store via
/// `_persistEncyclopedia` — silently destroying every previously
/// persisted checked-food entry.
///
/// The fix gates persists on the encyclopedia load having
/// SETTLED. These tests pin:
///  1. wedged enforcement read + successful check ⇒ the stored
///     JSON is byte-identical (NOT overwritten);
///  2. control: the normal settled path still persists checks
///     (merged with the restored history);
///  3. slow-load race: a check that completes while the load is
///     still pending persists nothing until the load settles,
///     then the deferred persist flushes the merged map.

const MethodChannel _secureChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void _mockSecureChannel(Future<Object?>? Function(MethodCall call) handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, handler);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });
}

String _seedJson() {
  final spinach = FoodCheckResult(foodName: 'spinach', levels: [
    for (final t in foodCoreTopics)
      FoodTopicLevel(topicName: t, level: 'High', reasoning: 'seed-$t'),
  ]);
  return encodeFoodEncyclopedia({'spinach': spinach});
}

TabsBackend _aiBackend() {
  final result = {
    'coffee': {
      'Histamine': {'level': 'Medium', 'reasoning': 'Some histamine.'},
      'Sugar': {'level': 'Low', 'reasoning': 'No sugar.'},
      'FODMAP': {'level': 'Low', 'reasoning': 'Low FODMAP.'},
      'Inflammation': {'level': 'Low', 'reasoning': 'Calm.'},
      'Oxalate': {'level': 'Medium', 'reasoning': 'Some oxalate.'},
    },
  };
  return TabsBackend(
    client: MockClient((request) async {
      if (request.url.path == '/api/ai/advice') {
        return http.Response(jsonEncode({'result': jsonEncode(result)}), 200);
      }
      return http.Response(jsonEncode({'profile': {}}), 200);
    }),
    sessionStore: FakeSessionStore()..token = 'tok',
  );
}

Future<void> _checkCoffee(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'coffee');
  await tester.pump();
  await tester.tap(find.text('Check Sensitivity'));
  await tester.pumpAndSettle();
  expect(find.text('Coffee'), findsWidgets);
  expect(find.text('Some histamine.'), findsOneWidget);
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  testWidgets(
      '5c: wedged enforcement read + successful check does NOT '
      'overwrite the stored encyclopedia', (tester) async {
    // The wedged sibling of tools_r48b's EMPTY-channel mock: the
    // secure-storage channel NEVER answers (the read future never
    // completes), so the owner-enforcement await never settles
    // and the encyclopedia load never runs.
    _mockSecureChannel((call) => Completer<Object?>().future);
    final store = _MemFoodStore()..value = _seedJson();
    final seeded = store.value;

    await tester.pumpWidget(MaterialApp(
      home: FoodToolScreen(backend: _aiBackend(), historyStore: store),
    ));
    await tester.pump();

    // The check still works in memory…
    await _checkCoffee(tester);
    expect(find.text('Results'), findsOneWidget);

    // …but the persisted history is byte-untouched: the history-
    // less in-memory map was never whole-value written over it.
    expect(store.value, seeded);
    expect(store.value, contains('"spinach"'));
    expect(store.value, isNot(contains('"coffee"')));
    expect(store.saveCount, 0);
  });

  testWidgets('5c control: settled path still persists checks, merged '
      'with the restored history', (tester) async {
    // EMPTY secure store (the tools_r48b idiom): readEmail
    // answers null, enforcement is the signed no-op, the load
    // runs and settles, and the gate opens.
    _mockSecureChannel((call) async => null);
    final store = _MemFoodStore()..value = _seedJson();

    await tester.pumpWidget(MaterialApp(
      home: FoodToolScreen(backend: _aiBackend(), historyStore: store),
    ));
    await tester.pumpAndSettle();
    // Restored history renders as a recent chip.
    expect(find.text('Recently Checked'), findsOneWidget);
    expect(find.text('Spinach'), findsOneWidget);

    await _checkCoffee(tester);

    // The persist happened and kept BOTH entries.
    expect(store.saveCount, greaterThan(0));
    expect(store.value, contains('"spinach"'));
    expect(store.value, contains('"coffee"'));
    final decoded = decodeFoodEncyclopedia(store.value);
    expect(decoded.keys, containsAll(['spinach', 'coffee']));
  });

  testWidgets('5c slow-load race: persist deferred while the load is '
      'pending, flushed merged once it settles', (tester) async {
    _mockSecureChannel((call) async => null);
    final loadGate = Completer<String?>();
    final store = _GatedFoodStore(loadGate)..value = _seedJson();
    final seeded = store.value;

    await tester.pumpWidget(MaterialApp(
      home: FoodToolScreen(backend: _aiBackend(), historyStore: store),
    ));
    // Let enforcement settle and the load START (still pending on
    // the gate). Small pumps keep fake time far under the load's
    // 3-second guard so the guard cannot fire first.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Run a successful check while the load is still pending,
    // pumping manually in small steps (same fake-time budget).
    await tester.enterText(find.byType(TextField), 'coffee');
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tap(find.text('Check Sensitivity'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.text('Some histamine.').evaluate().isNotEmpty) break;
    }
    expect(find.text('Some histamine.'), findsOneWidget);
    // Gate still closed: nothing was written over the seed.
    expect(store.value, seeded);
    expect(store.saveCount, 0);

    // Settle the load with the seeded history: the gate opens and
    // the deferred persist flushes the MERGED map.
    loadGate.complete(_seedJson());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(store.saveCount, greaterThan(0));
    final decoded = decodeFoodEncyclopedia(store.value);
    expect(decoded.keys, containsAll(['spinach', 'coffee']));
  });
}

class _MemFoodStore implements FoodHistoryStore {
  String? value;
  int saveCount = 0;

  @override
  Future<String?> loadEncyclopediaJson() async => value;

  @override
  Future<void> saveEncyclopediaJson(String json) async {
    saveCount++;
    value = json;
  }

  @override
  Future<bool> clearIfOwnerMismatch(String? email) async => false;
}

/// A store whose load hangs until the test completes [loadGate].
class _GatedFoodStore implements FoodHistoryStore {
  _GatedFoodStore(this.loadGate);

  final Completer<String?> loadGate;
  String? value;
  int saveCount = 0;

  @override
  Future<String?> loadEncyclopediaJson() => loadGate.future;

  @override
  Future<void> saveEncyclopediaJson(String json) async {
    saveCount++;
    value = json;
  }

  @override
  Future<bool> clearIfOwnerMismatch(String? email) async => false;
}
