import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// Paint-first score screens (Oct 22, 2026): the History screen
/// and the Home header circle must paint the PERSISTED store
/// scores immediately on open, before the snapshot capture lands.
/// Scoring order never changes: computeMissingScores still runs
/// only after the snapshot completes (founder rule, Oct 20).

class _FakeStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

List<String> _priorDates(String anchor, int count) {
  final a = DateTime.parse(anchor);
  return [
    for (var i = count; i >= 1; i--) _ds(a.subtract(Duration(days: i))),
  ];
}

HealthHistoryStore _fakeStore(_FakeStore fake) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

/// 28 baseline days of resting HR 60 before 2026-10-16 plus the
/// Oct 16 day itself at 54 (RHR-only, saturated 100 once scored).
Future<HealthHistoryStore> _seededStore({required bool scoreIt}) async {
  final store = _fakeStore(_FakeStore());
  await store.mergeRefresh([
    for (final d in _priorDates('2026-10-16', 28))
      DailyBiometrics(date: d, restingHrBpm: 60),
    const DailyBiometrics(date: '2026-10-16', restingHrBpm: 54),
  ]);
  if (scoreIt) {
    await DailyScoreEngine(store: store).computeMissingScores();
    expect((await store.readAll())['2026-10-16']!.dailyScore, 100);
  } else {
    expect((await store.readAll())['2026-10-16']!.dailyScore, isNull);
  }
  return store;
}

void main() {
  group('history: paint-first', () {
    testWidgets(
        'paints stored scored days while the snapshot is still pending; '
        'pre-paint body is a loading indicator, not a blank',
        (tester) async {
      final store = await _seededStore(scoreIt: true);
      final gate = Completer<bool>();
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(
          store: store,
          snapshotCapture: ({bool force = false}) => gate.future,
        ),
      ));
      // Before the first store paint lands: a real loading
      // indicator (never the old blank SizedBox.shrink body).
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump();
      // The stored days paint even though the snapshot future
      // has NOT completed — no capture, no compute ran first.
      expect(find.text('Fri, Oct 16'), findsOneWidget);
      expect(find.text('Last 14 scored days'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(gate.isCompleted, isFalse);
      // Let the background chain land so nothing pends at teardown.
      gate.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Fri, Oct 16'), findsOneWidget);
    });

    testWidgets(
        'repaints when the snapshot lands: a day the capture brings in '
        'is scored by the real chain and appears without reopening',
        (tester) async {
      // Priors are scored; Oct 16 itself is NOT in the store yet.
      final store = _fakeStore(_FakeStore());
      await store.mergeRefresh([
        for (final d in _priorDates('2026-10-16', 28))
          DailyBiometrics(date: d, restingHrBpm: 60),
      ]);
      await DailyScoreEngine(store: store).computeMissingScores();
      expect((await store.readAll())['2026-10-16'], isNull);
      final gate = Completer<bool>();
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(
          store: store,
          // The capture stand-in: when the gated snapshot lands
          // it writes the fresh day's raw row into the store,
          // exactly what a real capture does before the chain's
          // compute runs.
          snapshotCapture: ({bool force = false}) async {
            await gate.future;
            await store.mergeRefresh([
              const DailyBiometrics(date: '2026-10-16', restingHrBpm: 54),
            ]);
            return true;
          },
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // First paint: stored scored days are up, Oct 16 is not.
      expect(find.text('Fri, Oct 16'), findsNothing);
      gate.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // The background chain scored Oct 16 (write-once engine,
      // RHR 54 vs a 60 baseline saturates at 100) and repainted.
      expect((await store.readAll())['2026-10-16']!.dailyScore, 100);
      expect(find.text('Fri, Oct 16'), findsOneWidget);
    });

    testWidgets(
        'order pin: a past day computeMissingScores would score does NOT '
        'appear before the snapshot completes and DOES after',
        (tester) async {
      final store = await _seededStore(scoreIt: false);
      final gate = Completer<bool>();
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(
          store: store,
          snapshotCapture: ({bool force = false}) => gate.future,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // First paint performed no compute: the scoreable Oct 16
      // day stays unscored in the store and absent on screen —
      // the screen lands in the building state instead.
      expect((await store.readAll())['2026-10-16']!.dailyScore, isNull);
      expect(find.text('Fri, Oct 16'), findsNothing);
      expect(find.text('Building baseline'), findsWidgets);
      gate.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // Only after the snapshot did the compute run score it.
      expect((await store.readAll())['2026-10-16']!.dailyScore, 100);
      expect(find.text('Fri, Oct 16'), findsOneWidget);
    });

    testWidgets(
        'a background chain failure keeps the painted stored days up',
        (tester) async {
      final store = await _seededStore(scoreIt: true);
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(
          store: store,
          snapshotCapture: ({bool force = false}) async =>
              throw StateError('capture failed'),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Fri, Oct 16'), findsOneWidget);
      expect(find.text('Building baseline'), findsNothing);
    });
  });

  group('home: paint-first', () {
    testWidgets(
        'stored today score shows in the circle while the snapshot is '
        'stalled; after it completes an updated score replaces it',
        (tester) async {
      final store = _fakeStore(_FakeStore());
      final today = DateTime.now();
      final todayStr = _ds(DateTime(today.year, today.month, today.day));
      await store.mergeRefresh([
        for (final d in _priorDates(todayStr, 28))
          DailyBiometrics(date: d, restingHrBpm: 60),
        DailyBiometrics(date: todayStr, restingHrBpm: 54),
      ]);
      // Today's score already persisted (the post-capture run's
      // job in production; Home's own compute never scores today).
      await DailyScoreEngine(store: store).computeMissingScores();
      expect((await store.readAll())[todayStr]!.dailyScore, 100);
      final gate = Completer<bool>();
      final mockWeather = MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
        }
        return http.Response(
            '{"current":{"temperature_2m":55.0,"weather_code":2,"is_day":1}}',
            200);
      });
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(client: mockWeather),
          healthHistoryStore: store,
          // The capture stand-in: gated, and when it lands it
          // carries a refreshed persisted score for today (72)
          // with it — the repaint must pick that up.
          dailyScoreSnapshotCapture: ({bool force = false}) async {
            await gate.future;
            await store.replaceScore(todayStr,
                dailyScore: 72, scoreRestingHr: 72);
            return true;
          },
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      // Stored score painted while the snapshot is still stalled.
      expect(gate.isCompleted, isFalse);
      expect(find.text('100'), findsOneWidget);
      expect(find.text('Great'), findsOneWidget);
      gate.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('72'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('100'), findsNothing);
    });
  });
}
