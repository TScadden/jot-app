import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:tabs_lab/src/features/home/event_counter_rotator.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

/// Home polish round 6 — the events-band CENTERING gate.
///
/// Founder defect (live VC 100124, screenshot 1000026003_2):
/// the event-counter group in the Home band ("Since
/// Appointment with Brad (4)" + "1 Days") renders pushed to
/// the RIGHT of its band instead of centered in it. Root
/// cause: EventCounterRotator._counterPage is the legacy
/// right-aligned presentation (Row end / TextAlign.end) from
/// the old Home; the band reuses that widget, so its group
/// hugs the slot's right edge. The fix is an opt-in
/// `centerContent` flag on the rotator, passed ONLY by the
/// band (home_screen.dart's _bandCounters); the legacy
/// streak-row surface (vitals_strip.dart) keeps end alignment.
///
/// Measurement method: PIXEL SCAN of the captured band
/// region, the round-4/5 capture-harness pattern. The real
/// HomeScreen is pumped in the logged (scored) state inside a
/// RepaintBoundary, the frame is captured at DPR 3.0, and the
/// midpoint of the ink EXTENT is computed over the pixels
/// inside the band slot's x-range (between the two 62dp end
/// slots) and the counter texts' y-range (label + day count +
/// "Days" — the page dots live below that range and are
/// excluded). Ink = a pixel differing from the page background
/// (NotelColors.background, #0A0A0B) by > 30 in any channel.
/// The group's ink-extent center is compared against the slot
/// center, which is exactly the screen midpoint: the end
/// slots are symmetric 62dp, so slot center = width / 2. The
/// text-rect union center is printed alongside as a cross-
/// check; the two agree to well under a dp.

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
    int days,
  ) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async =>
      const [];
}

MockClient _mockWeather() => MockClient((request) async {
  if (request.url.host == 'ipinfo.io') {
    return http.Response(
      '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
      200,
    );
  }
  return http.Response(
    '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
    200,
  );
});

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
            {
              'id': 1,
              'name': 'Symptoms',
              'icon': 'Pulse',
              'colorHex': '#FF6B6B',
              'isDefault': true,
              'sortOrder': 1,
            },
            {
              'id': 4,
              'name': 'Goals & Habits',
              'icon': 'Target',
              'colorHex': '#4ECDC4',
              'isDefault': true,
              'sortOrder': 4,
            },
            {
              'id': 6,
              'name': 'Mood & Energy',
              'icon': 'Mood',
              'colorHex': '#FFD93D',
              'isDefault': true,
              'sortOrder': 6,
            },
            {
              'id': 8,
              'name': 'Medication',
              'icon': 'Pill',
              'colorHex': '#95E1D3',
              'isDefault': true,
              'sortOrder': 8,
            },
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
    if (request.url.path == '/api/sync/entries' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final e in (body['entries'] as List)) {
        entries.add((e as Map).cast<String, dynamic>());
      }
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  });
}

Map<String, dynamic> _scoredEntry() => {
  'id': 90,
  'categoryId': 6,
  'body': 'Feeling: 3/5 Today',
  'chips': '["Daily Ranking"]',
  'manualText': '',
  'timestamp': DateTime.now().millisecondsSinceEpoch,
};

DateTime _midnightPlus(DateTime from, int days) =>
    DateTime(from.year, from.month, from.day + days);

Map<String, dynamic> _counter({
  required String id,
  required String name,
  required DateTime target,
  bool isUp = false,
}) => {
  'id': id,
  'name': name,
  'targetDate': target.millisecondsSinceEpoch,
  'isUp': isUp,
  'autoUp': false,
  'isFavorite': false,
  'isArchived': false,
};

Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  }
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await _drainScoreChain(tester);
}

Future<void> _drainScoreChain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 31));
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required Size physicalSize,
  required _BandServer server,
  required GlobalKey boundaryKey,
}) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final disk = <String, String>{};
  Future<String?> read(String k) async => disk[k];
  Future<void> write(String k, String v) async => disk[k] = v;
  Future<void> delete(String k) async => disk.remove(k);
  LogEntryOutbox.instance.debugSetStore(
    read: read,
    write: write,
    delete: delete,
  );
  LogEntryOutbox.instance.debugReset();

  final scoreStore = HealthHistoryStore.testInstance();
  scoreStore.debugSetStore(read: read, write: write, delete: delete);
  scoreStore.debugReset();
  final today = historyDateStr(DateTime.now());
  await scoreStore.mergeRefresh([
    DailyBiometrics(date: today, restingHrBpm: 60),
  ]);
  await scoreStore.replaceScore(
    today,
    dailyScore: 73,
    scoreHrv: 73,
    scoreRestingHr: 73,
  );

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
      home: RepaintBoundary(
        key: boundaryKey,
        child: MediaQuery(
          // Reduced motion: in the rotating case the PageView
          // path is exercised structurally while its 3s timer
          // stays parked, so the captured frame is settled on
          // the first counter.
          data: const MediaQueryData(disableAnimations: true),
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
    ),
  );
  await _bridge(tester);
}

/// The shown counter text rect for [text] inside the rotator:
/// in the PageView path neighbor pages sit in the tree too, so
/// only the element whose center lies inside the pager's
/// viewport counts as shown (the round-5 harness's rule).
Rect _shownTextRect(WidgetTester tester, String text) {
  final rotator = find.byType(EventCounterRotator);
  final viewport = find.byType(PageView).evaluate().isEmpty
      ? tester.getRect(rotator)
      : tester.getRect(find.byType(PageView));
  final finder = find.descendant(of: rotator, matching: find.text(text));
  for (final e in finder.evaluate()) {
    final r = tester.getRect(find.byWidget(e.widget));
    if (viewport.contains(r.center)) return r;
  }
  throw StateError('no shown text rect for "$text" in $viewport');
}

/// Captures the pumped Home frame and returns the band group's
/// ink-center offset from the screen midpoint, in dp (plus the
/// ink pixel count, for the sanity assertion).
Future<({double offsetDp, int inkPixels})> _measureBandInkOffset(
  WidgetTester tester,
  GlobalKey boundaryKey, {
  required double widthDp,
}) async {
  const label = 'Since Appointment with Brad (4)';
  final rects = [
    _shownTextRect(tester, label),
    _shownTextRect(tester, '1'),
    _shownTextRect(tester, 'Days'),
  ];
  var yMin = rects.first.top;
  var yMax = rects.first.bottom;
  for (final r in rects) {
    if (r.top < yMin) yMin = r.top;
    if (r.bottom > yMax) yMax = r.bottom;
  }

  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  ByteData? raw;
  var imgW = 0;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3.0);
    imgW = image.width;
    raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  final bytes = raw!.buffer.asUint8List();
  const dpr = 3.0;
  final bg = NotelColors.background;
  final bgR = (bg.r * 255).round();
  final bgG = (bg.g * 255).round();
  final bgB = (bg.b * 255).round();
  final x0 = (62 * dpr).round();
  final x1 = ((widthDp - 62) * dpr).round();
  final y0 = (yMin * dpr).floor();
  final y1 = (yMax * dpr).ceil();
  var count = 0;
  var minX = imgW;
  var maxX = -1;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * imgW + x) * 4;
      final dr = (bytes[i] - bgR).abs();
      final dg = (bytes[i + 1] - bgG).abs();
      final db = (bytes[i + 2] - bgB).abs();
      if (dr > 30 || dg > 30 || db > 30) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        count++;
      }
    }
  }
  expect(
    count,
    greaterThan(500),
    reason:
        'the band group must render substantial ink '
        '(label + count + Days), got $count px',
  );
  // The group's visual center is the midpoint of its ink
  // EXTENT (leftmost to rightmost inked pixel) — what a viewer
  // judges as "centered in the band". (An ink-mass centroid is
  // NOT used: the count column carries extent but little ink
  // mass — a thin "1" beside "Days" — so a centroid sits ~6dp
  // left of the visual center even for a perfectly centered
  // group; verified on the fixed build, where the text-rect
  // union and the ink extent both center at ~0 while the
  // centroid reads -6.43dp at both widths.)
  final inkCenterDp = ((minX + maxX + 1) / 2) / dpr;
  final offset = inkCenterDp - widthDp / 2;
  var union = rects.first;
  for (final r in rects.skip(1)) {
    union = union.expandToInclude(r);
  }
  // ignore: avoid_print
  print(
    'BAND INK width=${widthDp.toStringAsFixed(0)} '
    'inkExtentCenter=${inkCenterDp.toStringAsFixed(2)}dp '
    'slotCenter=${(widthDp / 2).toStringAsFixed(2)}dp '
    'offset=${offset >= 0 ? '+' : ''}${offset.toStringAsFixed(2)}dp '
    'textRectUnionOffset='
    '${(union.center.dx - widthDp / 2).toStringAsFixed(2)}dp '
    'inkPx=$count',
  );
  return (offsetDp: offset, inkPixels: count);
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

  group('band group centering (founder defect, VC 100124)', () {
    for (final (widthLabel, size) in [
      ('360', const Size(1080, 2400)),
      ('390', const Size(1170, 2532)),
    ]) {
      for (final multi in [false, true]) {
        testWidgets('${multi ? 'rotating (PageView)' : 'single'} counter: '
            'the group ink is centered in the band slot at ${widthLabel}dp', (
          tester,
        ) async {
          final now = DateTime.now();
          final server = _BandServer(
            entries: [_scoredEntry()],
            counters: [
              // The founder's real counter, verbatim: counting
              // up from yesterday renders "Since Appointment
              // with Brad (4)" beside "1 Days".
              _counter(
                id: 'brad',
                name: 'Appointment with Brad (4)',
                target: _midnightPlus(now, -1),
                isUp: true,
              ),
              if (multi)
                _counter(
                  id: 'beta',
                  name: 'Beta',
                  target: _midnightPlus(now, 7),
                ),
            ],
          );
          final boundaryKey = GlobalKey();
          await _pumpHome(
            tester,
            physicalSize: size,
            server: server,
            boundaryKey: boundaryKey,
          );

          expect(find.byType(EventCounterRotator), findsOneWidget);
          expect(find.byType(PageView), multi ? findsOneWidget : findsNothing);
          expect(find.text('Since Appointment with Brad (4)'), findsWidgets);

          final widthDp = size.width / 3.0;
          final m = await _measureBandInkOffset(
            tester,
            boundaryKey,
            widthDp: widthDp,
          );
          expect(
            m.offsetDp,
            closeTo(0, 1.5),
            reason:
                'the band group (label + 6dp gap + count '
                'column) must sit centered as one group in its '
                'slot; measured ink offset ${m.offsetDp}dp at '
                '${widthDp}dp wide',
          );
          await _drainScoreChain(tester);
        });
      }
    }
  });

  group('rotator flag semantics', () {
    Future<Rect> pumpRotatorGroupRect(
      WidgetTester tester, {
      required bool centerContent,
    }) async {
      final now = DateTime.now();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: EventCounterRotator(
                  counters: [
                    EventCounterItem(
                      id: 'brad',
                      name: 'Appointment with Brad (4)',
                      targetDate: _midnightPlus(now, -1).millisecondsSinceEpoch,
                      isUp: true,
                    ),
                  ],
                  now: now,
                  centerContent: centerContent,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final label = tester.getRect(
        find.text('Since Appointment with Brad (4)'),
      );
      final days = tester.getRect(find.text('Days'));
      return label.expandToInclude(days);
    }

    testWidgets('default (legacy) rotator keeps the group right-aligned: '
        'the vitals_strip surface is unchanged', (tester) async {
      final group = await pumpRotatorGroupRect(tester, centerContent: false);
      // The 400dp slot is centered on the 800dp test surface, so
      // it spans 200..600; the legacy group hugs its right edge.
      expect(group.right, closeTo(600, 1.5));
      expect(group.center.dx, greaterThan(400 + 10));
    });

    testWidgets('centerContent centers the group in its slot', (tester) async {
      final group = await pumpRotatorGroupRect(tester, centerContent: true);
      expect(group.center.dx, closeTo(400, 3));
    });
  });
}
