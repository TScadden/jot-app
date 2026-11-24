import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
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
import 'package:tabs_lab/src/features/home/bandit_reading_slot.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/event_counter_rotator.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';

import 'test_helpers.dart';

/// Gem pill fit package (Nov 23, 2026, founder direction: "The
/// gems don't really fit their box we need to make sure it has
/// enough room to look good").
///
/// Before: Home's corner band held the streak stack in a fixed
/// SizedBox(width: 62). The gem pill's intrinsic width is 66.40dp
/// at the founder's 415 balance, so the slot squeezed it — a
/// RenderFlex overflow of 4.4dp (the VC 100146 flag), ~12dp at
/// 1,000 and ~19dp at 10,000 — and the design's 8dp horizontal
/// padding never landed.
///
/// After: the band is a Stack whose layout Row keeps the center
/// slot (62..width−62) and the Daily Score slot in their exact
/// boxes (a 62dp placeholder carries the left slot's height),
/// and the stack overlays it at Positioned(left: 0, top: 0) in a
/// ConstrainedBox(minWidth: 62). These tests pin, on the real
/// Home surface and on the stack composition:
/// - both pills render at intrinsic width, growing ~7.13dp per
///   digit (Roboto 12sp bold), with SYMMETRIC 8dp design padding
///   (9dp measured edge-to-content: 1dp border + 8dp padding);
/// - no overflow exception at any tested value;
/// - pills that fit in 62dp keep the Nov 10 center axis (31dp);
/// - the center slot's counter line, the Daily Score face and
///   everything below the band do not move when the pills widen;
/// - clearance between the widest flame pill and the counter
///   line at 360dp stays positive.

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

class _Server {
  final int streak;
  final int gems;
  _Server({required this.streak, required this.gems});

  MockClient get client => MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      final now = DateTime.now();
      final target = DateTime(now.year, now.month, now.day + 7);
      return http.Response(
        jsonEncode({
          'entries': [
            {
              'id': 90,
              'categoryId': 6,
              'body': 'Feeling: 3/5 Today',
              'chips': '["Daily Ranking"]',
              'manualText': '',
              'timestamp': now.millisecondsSinceEpoch,
            },
          ],
          'categories': [
            {'id': 1, 'name': 'Symptoms'},
            {'id': 4, 'name': 'Goals & Habits'},
            {'id': 6, 'name': 'Mood & Energy'},
            {'id': 8, 'name': 'Medication'},
          ],
          'profile': {
            'currentStreak': streak,
            'bestStreak': streak,
            'gem_balance': gems,
            'medications': '[]',
            'reminders': '[]',
            'eventCounters': jsonEncode([
              {
                'id': 'a',
                'name': 'Alpha',
                'targetDate': target.millisecondsSinceEpoch,
                'isUp': false,
                'autoUp': false,
                'isFavorite': false,
                'isArchived': false,
              },
            ]),
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
    return http.Response('not found', 404);
  });
}

Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  }
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 31));
}

Future<void> _dismissCelebrationIfShown(WidgetTester tester) async {
  final yay = find.byKey(const Key('celebrationYay'));
  if (yay.evaluate().isEmpty) return;
  await tester.tap(yay);
  await tester.pump();
  final yayAgain = find.byKey(const Key('celebrationYay'));
  if (yayAgain.evaluate().isNotEmpty) {
    await tester.tap(yayAgain);
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _loadFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final loader = FontLoader('Roboto');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await loader.load();
  });
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
    final gemDisk = <String, String>{};
    GemService.instance.debugReset();
    GemService.instance.debugSetStore(
      read: (k) async => gemDisk[k],
      write: (k, v) async {
        gemDisk[k] = v;
      },
      delete: (k) async {
        gemDisk.remove(k);
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });
  tearDown(() {
    GemService.instance.debugReset();
    HomeDataCache.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  group('stack composition (the band overlay construction)', () {
    Future<void> pumpStack(
      WidgetTester tester, {
      required int streak,
      required int? gems,
    }) async {
      await _loadFonts(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              // The exact composition Home's corner band uses:
              // min-width 62 (the Nov 10 slot) under the stack.
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 62),
                child: HomeStreakStack(
                  currentStreak: streak,
                  animateCountUps: false,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  gemBalance: gems,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // Decode the gem icon before measuring (the capture
      // harnesses' precache pattern): an undecided image measures
      // 0 wide and the pill reads narrow.
      final ctx = tester.element(find.byType(HomeStreakStack));
      await tester.runAsync(
        () => precacheImage(const AssetImage(GemCopy.iconAsset), ctx),
      );
      await tester.pump();
    }

    testWidgets('gem pill width grows with digits, padding symmetric, '
        'no overflow', (tester) async {
      final widths = <int, double>{};
      for (final gems in [5, 415, 1000, 10000]) {
        await pumpStack(tester, streak: 32, gems: gems);
        expect(
          tester.takeException(),
          isNull,
          reason: 'no overflow at $gems gems',
        );
        final pill = tester.getRect(find.byKey(const Key('homeGemPill')));
        final stack = tester.getRect(find.byType(HomeStreakStack));
        // ignore: avoid_print
        print('STACK gems=$gems stack=$stack pill=$pill');
        widths[gems] = pill.width;
        expect(pill.height, 34);
        // Anchoring: the stack sits at the slot's left edge; the
        // pills share the column's center axis; a pill wider
        // than 62 IS the column width, so its left edge is 0.
        expect(stack.left, 0);
        expect(
          pill.center.dx,
          closeTo(stack.center.dx, 0.75),
          reason: 'pills share the stack center axis at $gems',
        );
        if (pill.width > 62) {
          expect(
            pill.left,
            0,
            reason: 'the widest pill anchors at the left edge',
          );
          expect(stack.width, closeTo(pill.width, 0.75));
        }
        // Symmetric design padding: 1dp border + 8dp padding on
        // BOTH sides (before the fix the right side was squeezed
        // to ~4.6dp at 415).
        final icon = tester.getRect(find.byKey(const Key('homeGemPillIcon')));
        final count = tester.getRect(find.byKey(const Key('homeGemPillCount')));
        final leftGap = icon.left - pill.left;
        final rightGap = pill.right - count.right;
        expect(leftGap, closeTo(9, 0.75), reason: 'left padding at $gems');
        expect(rightGap, closeTo(9, 0.75), reason: 'right padding at $gems');
        expect(
          leftGap,
          closeTo(rightGap, 0.75),
          reason: 'padding symmetric at $gems',
        );
      }
      // Measured intrinsic widths (Roboto): 52.13 / 66.40 /
      // 73.54 / 80.67 — strictly widening, ~7.13dp per digit.
      expect(widths[5], closeTo(52.13, 1.0));
      expect(widths[415], closeTo(66.40, 1.0));
      expect(widths[1000], closeTo(73.54, 1.0));
      expect(widths[10000], closeTo(80.67, 1.0));
      final ordered = [widths[5]!, widths[415]!, widths[1000]!, widths[10000]!];
      for (var i = 1; i < ordered.length; i++) {
        expect(ordered[i], greaterThan(ordered[i - 1]));
      }
    });

    testWidgets('flame pill width grows with digits, padding symmetric, '
        'no overflow', (tester) async {
      final widths = <int, double>{};
      for (final streak in [7, 32, 132]) {
        await pumpStack(tester, streak: streak, gems: null);
        expect(
          tester.takeException(),
          isNull,
          reason: 'no overflow at streak $streak',
        );
        final pill = tester.getRect(find.byKey(const Key('homeStreakPills')));
        widths[streak] = pill.width;
        expect(pill.height, 34);
        final icon = tester.getRect(
          find.descendant(
            of: find.byKey(const Key('homeStreakPills')),
            matching: find.byType(StreakPillFlame),
          ),
        );
        final text = tester.getRect(
          find.descendant(
            of: find.byKey(const Key('homeStreakPills')),
            matching: find.byType(Text),
          ),
        );
        expect(
          icon.left - pill.left,
          closeTo(9, 0.75),
          reason: 'flame left padding at $streak',
        );
        expect(
          pill.right - text.right,
          closeTo(9, 0.75),
          reason: 'flame right padding at $streak',
        );
      }
      expect(widths[7], closeTo(44.13, 1.0));
      expect(widths[32], closeTo(51.27, 1.0));
      expect(widths[132], closeTo(58.40, 1.0));
    });

    testWidgets('pills that fit keep the Nov 10 center axis at 31dp', (
      tester,
    ) async {
      await pumpStack(tester, streak: 7, gems: 5);
      final stack = tester.getRect(find.byType(HomeStreakStack));
      expect(stack.width, 62, reason: 'the min-width slot holds');
      expect(stack.left, 0);
      final flame = tester.getRect(find.byKey(const Key('homeStreakPills')));
      final gem = tester.getRect(find.byKey(const Key('homeGemPill')));
      expect(flame.center.dx, closeTo(31, 0.75));
      expect(gem.center.dx, closeTo(31, 0.75));
      expect(tester.takeException(), isNull);
    });
  });

  group('full Home band', () {
    Future<void> pumpHome(
      WidgetTester tester, {
      required Size physicalSize,
      required _Server server,
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

      await _loadFonts(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: HomeScreen(
              weatherApi: WeatherApiClient(client: _mockWeather()),
              tabsBackend: backend,
              logEntryOutbox: LogEntryOutbox.instance,
              healthConnectService: _FakeHc(),
              healthRepository: HealthRepository(
                hc: _FakeHc(),
                backend: backend,
              ),
              healthHistoryStore: scoreStore,
              dailyScoreSnapshotCapture: ({bool force = false}) async => true,
            ),
          ),
        ),
      );
      await _bridge(tester);
      await _dismissCelebrationIfShown(tester);
    }

    // The neighbor rects are deterministic in this fixture
    // (counter line 74..286, Daily Score center at width−31,
    // Bandit top at 144), so each case asserts them absolutely —
    // identical expectations across cases IS the no-move proof.
    testWidgets('at 360dp: 415 gems / 32 streak render at intrinsic width; '
        'neighbors at their fixed rects', (tester) async {
      await pumpHome(
        tester,
        physicalSize: const Size(1080, 2400),
        server: _Server(streak: 32, gems: 415),
      );
      expect(tester.takeException(), isNull);
      final gem = tester.getRect(find.byKey(const Key('homeGemPill')));
      final flame = tester.getRect(find.byKey(const Key('homeStreakPills')));
      final rotator = tester.getRect(find.byType(EventCounterRotator));
      final face = tester.getRect(find.byType(DailyScoreFace));
      final bandit = tester.getRect(find.byType(BanditReadingSlot));
      // ignore: avoid_print
      print(
        'HOME360 gems=415 gem=${gem.left}..${gem.right} '
        'w=${gem.width} flame=${flame.left}..${flame.right} '
        'rotator=${rotator.left}..${rotator.right} '
        'faceCx=${face.center.dx} banditTop=${bandit.top}',
      );
      expect(gem.width, closeTo(66.40, 1.0));
      expect(gem.left, 0);
      expect(flame.width, closeTo(51.27, 1.0));
      expect(face.center.dx, closeTo(360 - 31, 1.0));
      expect(rotator.left, closeTo(74, 0.6));
      expect(
        flame.right,
        lessThan(rotator.left),
        reason: 'flame pill clears the counter line',
      );
      expect(bandit.top, closeTo(144, 0.6));
    });

    testWidgets('at 360dp: 10000 gems / 132 streak render at intrinsic '
        'width; neighbors unmoved; counter clearance positive', (tester) async {
      await pumpHome(
        tester,
        physicalSize: const Size(1080, 2400),
        server: _Server(streak: 132, gems: 10000),
      );
      expect(tester.takeException(), isNull);
      final gem = tester.getRect(find.byKey(const Key('homeGemPill')));
      final flame = tester.getRect(find.byKey(const Key('homeStreakPills')));
      final rotator = tester.getRect(find.byType(EventCounterRotator));
      final face = tester.getRect(find.byType(DailyScoreFace));
      final bandit = tester.getRect(find.byType(BanditReadingSlot));
      // ignore: avoid_print
      print(
        'HOME360 gems=10000 gem=${gem.left}..${gem.right} '
        'w=${gem.width} flame=${flame.left}..${flame.right} '
        'rotator=${rotator.left}..${rotator.right} '
        'faceCx=${face.center.dx} banditTop=${bandit.top} '
        'clearance=${rotator.left - flame.right}',
      );
      expect(gem.width, closeTo(80.67, 1.0));
      expect(gem.left, 0);
      expect(flame.width, closeTo(58.40, 1.0));
      expect(face.center.dx, closeTo(360 - 31, 1.0));
      expect(rotator.left, closeTo(74, 0.6));
      expect(
        bandit.top,
        closeTo(144, 0.6),
        reason: 'band height unchanged — nothing below shifts',
      );
      // Clearance at the widest flame pill: the counter line's
      // box starts at 74 (62 slot + 12 padding); the 132 flame
      // pill ends at 69.54 → ~4.5dp clear.
      expect(rotator.left - flame.right, greaterThan(3));
    });

    testWidgets('at 390dp: 415 gems render at intrinsic width and '
        'the Daily Score axis holds', (tester) async {
      await pumpHome(
        tester,
        physicalSize: const Size(1170, 2532),
        server: _Server(streak: 32, gems: 415),
      );
      expect(tester.takeException(), isNull);
      final gem = tester.getRect(find.byKey(const Key('homeGemPill')));
      final face = tester.getRect(find.byType(DailyScoreFace));
      expect(gem.width, closeTo(66.40, 1.0));
      expect(gem.left, 0);
      expect(face.center.dx, closeTo(390 - 31, 1.0));
    });
  });
}
