import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

import 'test_helpers.dart';

/// R70 — Personal Sleep Need section, inside the existing Sleep tool.

String _key(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _ago(int n) => _key(DateTime.now().subtract(Duration(days: n)));

class _NeedHc extends HealthConnectService {
  _NeedHc({required this.history, required this.perDay});

  /// Full sleep history the range read serves (date → minutes).
  final Map<String, int> history;

  /// Per-day minutes the per-day reads serve.
  final Map<String, int> perDay;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => perDay[dateStr];

  @override
  Future<SleepStages?> readSleepStages(String dateStr) async => null;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    final dates = history.keys.toList()..sort();
    return [
      for (final d in dates) (date: d, mins: history[d]!, deep: 60),
    ];
  }
}

TabsBackend _backend() {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient(
        (_) async => http.Response(jsonEncode({'profile': {}}), 200)),
    sessionStore: store,
  );
}

class _MemStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  Future<void> pumpNeed(
    WidgetTester tester, {
    required Map<String, int> history,
    required Map<String, int> perDay,
  }) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final mem = _MemStore();
    final store = HealthHistoryStore.testInstance();
    store.debugSetStore(read: mem.read, write: mem.write, delete: mem.delete);
    store.debugReset();
    final hc = _NeedHc(history: history, perDay: perDay);
    await tester.pumpWidget(MaterialApp(
      home: SleepScreen(
        backend: _backend(),
        healthConnect: hc,
        historyQueries: HealthHistoryQueries(hc: hc, store: store),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('need section: last night vs its need, tonight need, '
      'balance bars with a plain status', (tester) async {
    // 27 nights at 8h, then last night 7h — all inside the store's
    // depth via the range read; per-day reads cover the last 14.
    final history = <String, int>{
      for (var i = 28; i >= 2; i--) _ago(i): 480,
      _ago(1): 420,
    };
    final perDay = <String, int>{
      for (var i = 13; i >= 2; i--) _ago(i): 480,
      _ago(1): 420,
    };
    await pumpNeed(tester, history: history, perDay: perDay);

    expect(find.text('Sleep Need'), findsOneWidget);
    expect(find.text('Your usual need, from your recent nights'),
        findsOneWidget);
    // Last night: asleep 7h0m against that night's need 8h0m.
    expect(find.text('Last night asleep'), findsOneWidget);
    expect(find.text('That night\'s need'), findsOneWidget);
    // Tonight: base 8h0m + 1h0m recent shortfall = 9h0m.
    expect(find.text('Tonight\'s need'), findsOneWidget);
    expect(find.text('9h0m'), findsOneWidget);
    expect(
      find.text(
          'Recent shortfall: 1h0m across your last 7 recorded nights'),
      findsOneWidget,
    );
    // Balance bars: the latest night is Below need by 1h0m.
    expect(find.text('This week\'s balance'), findsOneWidget);
    expect(find.text('Below need'), findsOneWidget);
    expect(find.text('-1h0m'), findsOneWidget);
    // No borrowed rating words anywhere in the section.
    expect(find.textContaining('Great'), findsNothing);
  });

  testWidgets('insufficient data: honest still-learning state, '
      'no invented number', (tester) async {
    final history = <String, int>{
      _ago(3): 480,
      _ago(2): 470,
      _ago(1): 460,
    };
    await pumpNeed(tester, history: history, perDay: history);
    expect(find.text('Sleep Need'), findsOneWidget);
    expect(
      find.textContaining('Still learning your pattern'),
      findsOneWidget,
    );
    expect(find.text('Tonight\'s need'), findsNothing);
    expect(find.text('This week\'s balance'), findsNothing);
  });
}
