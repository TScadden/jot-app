import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show historyDateStr;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/event_counter_rotator.dart';
import 'package:tabs_lab/src/features/home/home_checkin_strip.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'test_helpers.dart';

/// Home polish round 5, workstream (f) + addendum — the
/// event-counters BAND in the check-in strip's slot.
///
/// Founder (Nov 10, 2026): the events show up where the 1–5
/// score is; while the score is there the events are hidden;
/// the moment the user logs the score, the events fade back
/// into view. Multiple events swipe between them and
/// auto-advance every ~3 seconds (addendum); archived or
/// deleted counters never show, and the band tracks counter
/// state live. Presentation is the old Home's own
/// EventCounterRotator, unchanged.

class _FakeHc extends HealthConnectService {
  @override
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
        serviceAvailable: true,
        grantedPermissions: HealthConnectService.requiredPermissions,
        bridgeErrorCode: null,
        stepsProbe: HcReadProbeOutcome.ok,
        persistedConnected: true,
      );

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12);
    return [HrSample(timeMs: noon.millisecondsSinceEpoch, bpm: 74)];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => 159;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => 510;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async =>
      const [];
}

MockClient _mockWeather() => MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
          200);
    });

/// Stateful fake backend: the pull serves the CURRENT [entries]
/// and [counters] (tests mutate [counters] to model a state
/// change while Home is open); POSTs are reflected into later
/// pulls, like production.
class _BandServer {
  List<Map<String, dynamic>> entries;
  List<Map<String, dynamic>> counters;

  _BandServer({required this.entries, required this.counters});

  MockClient get client => MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': entries,
              'categories': [
                {'id': 1, 'name': 'Symptoms', 'icon': 'Pulse', 'colorHex': '#FF6B6B', 'isDefault': true, 'sortOrder': 1},
                {'id': 4, 'name': 'Goals & Habits', 'icon': 'Target', 'colorHex': '#4ECDC4', 'isDefault': true, 'sortOrder': 4},
                {'id': 6, 'name': 'Mood & Energy', 'icon': 'Mood', 'colorHex': '#FFD93D', 'isDefault': true, 'sortOrder': 6},
                {'id': 8, 'name': 'Medication', 'icon': 'Pill', 'colorHex': '#95E1D3', 'isDefault': true, 'sortOrder': 8},
              ],
              'profile': {
                'currentStreak': 18,
                'bestStreak': 68,
                'medications': '[]',
                'reminders': '[]',
                'eventCounters': jsonEncode(counters),
              },
              'isUnlimited': true,
              'isAdmin': false,
            }),
            200,
          );
        }
        if (request.url.path == '/api/habits') {
          return http.Response('{"habits":[]}', 200);
        }
        if (request.url.path == '/api/sync/entries' &&
            request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          for (final e in (body['entries'] as List)) {
            entries.add((e as Map).cast<String, dynamic>());
          }
          return http.Response('{}', 200);
        }
        return http.Response('not found', 404);
      });
}

Map<String, dynamic> _entry({
  required int id,
  required int categoryId,
  required String body,
  String chips = '[]',
}) =>
    {
      'id': id,
      'categoryId': categoryId,
      'body': body,
      'chips': chips,
      'manualText': '',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

Map<String, dynamic> _scoredEntry() => _entry(
      id: 90,
      categoryId: 6,
      body: 'Feeling: 3/5 Today',
      chips: '["Daily Ranking"]',
    );

DateTime _midnightPlus(DateTime from, int days) =>
    DateTime(from.year, from.month, from.day + days);

Map<String, dynamic> _counter({
  required String id,
  required String name,
  required DateTime target,
  bool isUp = false,
  bool isArchived = false,
  int? deletedAt,
}) =>
    {
      'id': id,
      'name': name,
      'targetDate': target.millisecondsSinceEpoch,
      'isUp': isUp,
      'autoUp': false,
      'isFavorite': false,
      'isArchived': isArchived,
      'deletedAt': ?deletedAt,
    };

Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
  }
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await _drainScoreChain(tester);
}

Future<void> _drainScoreChain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 31));
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required Size physicalSize,
  required _BandServer server,
  bool disableAnimations = true,
}) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final disk = <String, String>{};
  Future<String?> read(String k) async => disk[k];
  Future<void> write(String k, String v) async => disk[k] = v;
  Future<void> delete(String k) async => disk.remove(k);
  LogEntryOutbox.instance.debugSetStore(
      read: read, write: write, delete: delete);
  LogEntryOutbox.instance.debugReset();

  final scoreStore = HealthHistoryStore.testInstance();
  scoreStore.debugSetStore(read: read, write: write, delete: delete);
  scoreStore.debugReset();
  final today = historyDateStr(DateTime.now());
  await scoreStore.mergeRefresh([DailyBiometrics(date: today, restingHrBpm: 60)]);
  await scoreStore.replaceScore(today,
      dailyScore: 73, scoreHrv: 73, scoreRestingHr: 73);

  final backend = TabsBackend(
    client: server.client,
    sessionStore: FakeSessionStore()..token = 'tok',
  );

  await tester.runAsync(() async {
    final loader = FontLoader('Roboto');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await loader.load();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: HomeScreen(
          weatherApi: WeatherApiClient(client: _mockWeather()),
          tabsBackend: backend,
          logEntryOutbox: LogEntryOutbox.instance,
          healthConnectService: _FakeHc(),
          healthRepository: HealthRepository(hc: _FakeHc(), backend: backend),
          healthHistoryStore: scoreStore,
          dailyScoreSnapshotCapture: ({bool force = false}) async => true,
        ),
      ),
    ),
  );
  await _bridge(tester);
}

EventCounterItem _item(
        String id, String name, DateTime target, bool isUp) =>
    EventCounterItem(
      id: id,
      name: name,
      targetDate: target.millisecondsSinceEpoch,
      isUp: isUp,
      autoUp: false,
      isFavorite: false,
      isArchived: false,
    );

Finder _revealBuilder() => find.byWidgetPredicate(
    (w) => w is TweenAnimationBuilder<double>);

double _bandOpacity(WidgetTester tester) {
  final opacity = find.descendant(
    of: _revealBuilder(),
    matching: find.byType(Opacity),
  );
  return tester.widget<Opacity>(opacity).opacity;
}

void main() {
  setUp(() {
    TabsBackend.debugResetSharedCaches();
    HomeDataCache.instance.debugSetStore(
      read: (k) async => null,
      write: (k, v) async {},
      delete: (k) async {},
    );
    HomeDataCache.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
  });
  tearDown(() {
    HomeDataCache.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  group('band state machine', () {
    testWidgets(
        'unscored: the strip owns the band and no event is in the tree',
        (tester) async {
      final now = DateTime.now();
      final server = _BandServer(
        entries: [_entry(id: 41, categoryId: 1, body: 'headache')],
        counters: [
          _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
          _counter(
              id: 'b',
              name: 'Beta',
              target: _midnightPlus(now, -3),
              isUp: true),
        ],
      );
      await _pumpHome(tester,
          physicalSize: const Size(1080, 2400), server: server);

      expect(find.byType(HomeCheckInStrip), findsOneWidget);
      expect(find.byType(EventCounterRotator), findsNothing);
      expect(find.textContaining('Alpha'), findsNothing);
      expect(find.textContaining('Beta'), findsNothing);
      expect(_revealBuilder(), findsNothing);
      await _drainScoreChain(tester);
    });

    testWidgets(
        'logging the score fades the events in (opacity animates 0 to 1)',
        (tester) async {
      final now = DateTime.now();
      final server = _BandServer(
        entries: [_entry(id: 41, categoryId: 1, body: 'headache')],
        counters: [
          _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
        ],
      );
      await _pumpHome(tester,
          physicalSize: const Size(1080, 2400), server: server);
      expect(find.byType(EventCounterRotator), findsNothing);

      await tester.tap(find.descendant(
        of: find.byType(HomeCheckInStrip),
        matching: find.text('3'),
      ));
      // Sample the reveal: the strip's commit lands, the counters
      // mount under a TweenAnimationBuilder, and the opacity must
      // pass through intermediate values on its way to 1.
      final seen = <double>[];
      for (var i = 0; i < 60 && (seen.isEmpty || seen.last < 1.0); i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (_revealBuilder().evaluate().isNotEmpty) {
          seen.add(_bandOpacity(tester));
        }
      }
      expect(seen, isNotEmpty,
          reason: 'the counters must mount under the reveal builder');
      expect(seen.first, lessThan(0.5),
          reason: 'the fade starts near 0, not at full opacity');
      expect(
        seen.any((v) => v > 0.05 && v < 0.95),
        isTrue,
        reason: 'the fade animates through intermediate values',
      );
      expect(seen.last, 1.0);
      expect(find.byType(HomeCheckInStrip), findsNothing);
      expect(find.byType(EventCounterRotator), findsOneWidget);
      expect(find.text('Until Alpha'), findsOneWidget);
      await _drainScoreChain(tester);
    });

    testWidgets(
        'cold open already scored: counters simply there, no fade',
        (tester) async {
      final now = DateTime.now();
      final server = _BandServer(
        entries: [_scoredEntry()],
        counters: [
          _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
        ],
      );
      await _pumpHome(tester,
          physicalSize: const Size(1080, 2400), server: server);

      expect(find.byType(HomeCheckInStrip), findsNothing);
      expect(find.byType(EventCounterRotator), findsOneWidget);
      expect(find.text('Until Alpha'), findsOneWidget);
      // No reveal machinery at all on a cold open.
      expect(_revealBuilder(), findsNothing);
      await _drainScoreChain(tester);
    });

    testWidgets(
        'zero active counters: after logging, the band is simply empty',
        (tester) async {
      final now = DateTime.now();
      final server = _BandServer(
        entries: [_entry(id: 41, categoryId: 1, body: 'headache')],
        counters: [
          _counter(
              id: 'x',
              name: 'ArchivedOne',
              target: _midnightPlus(now, 5),
              isArchived: true),
          _counter(
              id: 'y',
              name: 'DeletedOne',
              target: _midnightPlus(now, 5),
              deletedAt: _midnightPlus(now, -1).millisecondsSinceEpoch),
        ],
      );
      await _pumpHome(tester,
          physicalSize: const Size(1080, 2400), server: server);
      expect(find.byType(HomeCheckInStrip), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(HomeCheckInStrip),
        matching: find.text('3'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.byType(HomeCheckInStrip), findsNothing);
      expect(find.byType(EventCounterRotator), findsNothing);
      expect(find.text('Days'), findsNothing);
      expect(find.textContaining('ArchivedOne'), findsNothing);
      expect(find.textContaining('DeletedOne'), findsNothing);
      await _drainScoreChain(tester);
    });
  });

  group('band rotation (founder addendum)', () {
    // The band harness below runs with animations ENABLED: the
    // redesign harness's disableAnimations MediaQuery reads as
    // reduced motion to the rotator and stops its timer. The
    // heavy _bridge also leaves the pager's timer phase unknown,
    // so both tests first take a manual swipe — pointer-up
    // restarts the interval, which pins the phase — and then
    // reason about the cyclic order from whichever counter the
    // swipe landed on.
    const cycle = ['Until Alpha', 'Since Beta', 'Until Gamma'];
    const cycle2 = ['Until Alpha', 'Since Beta'];
    // The SHOWN counter, read the way a user sees it: a PageView
    // keeps neighbor pages in the tree mid-transition, so plain
    // text presence is ambiguous — the shown label is the one
    // whose center lies inside the pager's viewport.
    String shownIn(WidgetTester tester, List<String> labels) {
      final view = tester.getRect(find.byType(PageView));
      for (final label in labels) {
        for (final e in find.text(label).evaluate()) {
          if (view.contains(tester.getRect(find.byWidget(e.widget)).center)) {
            return label;
          }
        }
      }
      return '';
    }
    String nextIn(List<String> labels, String label) =>
        labels[(labels.indexOf(label) + 1) % labels.length];
    String shownLabel(WidgetTester tester) => shownIn(tester, cycle);
    String nextLabel(String label) => nextIn(cycle, label);

    Future<void> swipeBand(WidgetTester tester) async {
      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets(
        'auto-advances every ~3s in order, loops, with page dots',
        (tester) async {
      final now = DateTime.now();
      final server = _BandServer(
        entries: [_scoredEntry()],
        counters: [
          _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
          _counter(
              id: 'b',
              name: 'Beta',
              target: _midnightPlus(now, -3),
              isUp: true),
          _counter(id: 'g', name: 'Gamma', target: _midnightPlus(now, 1)),
        ],
      );
      await _pumpHome(tester,
          physicalSize: const Size(1080, 2400),
          server: server,
          disableAnimations: false);
      expect(shownLabel(tester), isNotEmpty);

      // Page dots: one per counter, under the count (native
      // treatment, carried over with the rotator).
      final dots = tester
          .widgetList<Container>(find.descendant(
            of: find.byType(EventCounterRotator),
            matching: find.byType(Container),
          ))
          .where((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).shape == BoxShape.circle)
          .toList();
      expect(dots.length, 3);

      await swipeBand(tester);
      final start = shownLabel(tester);
      expect(start, isNotEmpty);
      // No advance before the ~3s interval elapses...
      await tester.pump(const Duration(milliseconds: 2500));
      expect(shownLabel(tester), start);
      // ...an advance just after it, in cyclic order...
      await tester.pump(const Duration(seconds: 1));
      expect(shownLabel(tester), nextLabel(start));
      // ...and the cycle loops through the third counter and
      // back to the start.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 500));
      expect(shownLabel(tester), nextLabel(nextLabel(start)));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 500));
      expect(shownLabel(tester), start);
      await _drainScoreChain(tester);
    });

    testWidgets('a manual swipe resets the auto-advance interval',
        (tester) async {
      final now = DateTime.now();
      final server = _BandServer(
        entries: [_scoredEntry()],
        counters: [
          _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
          _counter(
              id: 'b',
              name: 'Beta',
              target: _midnightPlus(now, -3),
              isUp: true),
        ],
      );
      await _pumpHome(tester,
          physicalSize: const Size(1080, 2400),
          server: server,
          disableAnimations: false);

      // Pin the phase: a swipe lands on some counter and the
      // interval restarts at pointer-up.
      await swipeBand(tester);
      final first = shownIn(tester, cycle2);
      expect(first, isNotEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(shownIn(tester, cycle2), first);

      // Swipe again 2s into the cycle. Without a reset, the
      // pending fire would land 1s after this swipe; with the
      // reset, the new counter must still be up 2s later...
      await swipeBand(tester);
      final second = shownIn(tester, cycle2);
      expect(second, nextIn(cycle2, first));
      await tester.pump(const Duration(seconds: 2));
      expect(shownIn(tester, cycle2), second);
      // ...and the advance lands a full interval after the swipe.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(shownIn(tester, cycle2), nextIn(cycle2, second));
      await _drainScoreChain(tester);
    });

    testWidgets('a single active event never moves', (tester) async {
      final now = DateTime.now();
      final server = _BandServer(
        entries: [_scoredEntry()],
        counters: [
          _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
        ],
      );
      await _pumpHome(tester,
          physicalSize: const Size(1080, 2400), server: server);
      expect(find.text('Until Alpha'), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
      await tester.pump(const Duration(seconds: 12));
      expect(find.text('Until Alpha'), findsOneWidget);
      await _drainScoreChain(tester);
    });
  });

  group('band liveness + geometry', () {
    testWidgets(
        'archiving a counter in Settings removes it from the band '
        'when Home reloads (band tap route, back, settled)',
        (tester) async {
      final now = DateTime.now();
      final server = _BandServer(
        entries: [_scoredEntry()],
        counters: [
          _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
          _counter(
              id: 'b',
              name: 'Beta',
              target: _midnightPlus(now, -3),
              isUp: true),
        ],
      );
      await _pumpHome(tester,
          physicalSize: const Size(1080, 2400), server: server);
      expect(find.text('Until Alpha'), findsOneWidget);

      // The counter is archived elsewhere (server state changes);
      // the band tap opens the Event Counters page and returning
      // re-reads the counters (the production reload path).
      server.counters = [
        _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
        _counter(
            id: 'b',
            name: 'Beta',
            target: _midnightPlus(now, -3),
            isUp: true,
            isArchived: true),
      ];
      await tester.tap(find.byType(EventCounterRotator));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(SettingsScreen), findsNothing);

      // Settled: only Alpha remains — no blank page, no pager.
      expect(find.text('Until Alpha'), findsOneWidget);
      expect(find.textContaining('Beta'), findsNothing);
      expect(find.byType(PageView), findsNothing);
      await tester.pump(const Duration(seconds: 7));
      expect(find.text('Until Alpha'), findsOneWidget);
      await _drainScoreChain(tester);
    });

    for (final (label, size) in [
      ('360', const Size(1080, 2400)),
      ('390', const Size(1170, 2532)),
    ]) {
      testWidgets(
          'band content stays inside the strip slot at ${label}dp: '
          'no collision with the streak stack or Daily Score',
          (tester) async {
        final now = DateTime.now();
        final server = _BandServer(
          entries: [_scoredEntry()],
          counters: [
            _counter(id: 'a', name: 'Alpha', target: _midnightPlus(now, 7)),
          ],
        );
        await _pumpHome(tester, physicalSize: size, server: server);

        final band = tester.getRect(find.byType(EventCounterRotator));
        final width = size.width / 3.0;
        // The center slot runs between the two 62dp end slots.
        expect(band.left, greaterThanOrEqualTo(62 - 1));
        expect(band.right, lessThanOrEqualTo(width - 62 + 1));

        final streak = tester.getRect(find.byType(HomeStreakStack));
        final face = tester.getRect(find.byType(DailyScoreFace));
        expect(band.overlaps(streak), isFalse);
        expect(band.overlaps(face), isFalse);
        await _drainScoreChain(tester);
      });
    }
  });

  group('rotator addendum units', () {
    Future<void> pumpRotator(
      WidgetTester tester,
      List<({String id, String name, DateTime target, bool isUp})> specs,
    ) async {
      final now = DateTime.now();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: EventCounterRotator(
                counters: [
                  for (final s in specs)
                    // The rotator consumes EventCounterItem via
                    // settings_profile; build through its fromMap
                    // twin by way of the public constructor below.
                    _item(s.id, s.name, s.target, s.isUp),
                ],
                now: now,
                advanceInterval: const Duration(seconds: 3),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets(
        'auto-advance suspends while the app is backgrounded and '
        'resumes in the foreground', (tester) async {
      final now = DateTime.now();
      await pumpRotator(tester, [
        (id: 'a', name: 'Alpha', target: _midnightPlus(now, 7), isUp: false),
        (id: 'b', name: 'Beta', target: _midnightPlus(now, -3), isUp: true),
      ]);
      expect(find.text('Until Alpha'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Until Alpha'), findsOneWidget);

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Since Beta'), findsOneWidget);
    });

    testWidgets(
        'when the shown counter leaves the set, the band settles '
        'on the remaining counter (no blank page)', (tester) async {
      final now = DateTime.now();
      await pumpRotator(tester, [
        (id: 'a', name: 'Alpha', target: _midnightPlus(now, 7), isUp: false),
        (id: 'b', name: 'Beta', target: _midnightPlus(now, -3), isUp: true),
      ]);
      expect(find.text('Until Alpha'), findsOneWidget);
      await pumpRotator(tester, [
        (id: 'b', name: 'Beta', target: _midnightPlus(now, -3), isUp: true),
      ]);
      expect(find.text('Since Beta'), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('Since Beta'), findsOneWidget);
    });
  });
}
