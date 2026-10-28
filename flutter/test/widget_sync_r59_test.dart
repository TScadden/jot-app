import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';

import 'test_helpers.dart';

/// Round 59 — widget parity fix (founder phone test of Round 58,
/// same minute, 1:25 PM MDT Oct 14 2026):
/// - Home strip: HR 66, flame 62, entries 7, sleep 8h36m.
/// - Widget:     HR 66, flame 2, entries 1, sleep 8h36 wrapped.
///
/// Three defects, three groups of pins:
/// 1. PARITY: Round 50 put STREAK DAYS in the widget's flame cell
///    while the strip's flame cell shows active calories (62 vs 2).
///    The payload must now consume exactly the fields [VitalsStrip]
///    consumes — the streak must not leak into ANY cell.
/// 2. ENTRIES: the widget's logs cell and the strip's both read
///    `logCountToday`, but (a) entry creation outside Home updated
///    only QuickLogCache — HomeDataCache (and therefore the widget)
///    was never told, and (b) WidgetSync pushes were unserialized:
///    Home's cached-snapshot push and its fresh-load push overlap
///    and interleave per-key saves, so the stale push (logs 1) can
///    land its logs save after the fresh push (logs 7) with no
///    later push to correct it. Pins: pushes run strictly in call
///    order, and the entry-creation path (Quick Log save) triggers
///    a widget push carrying the new count.
/// 3. WRAP: the sleep cell must stay on one line — source pins on
///    the RemoteViews layout (singleLine/maxLines on every value,
///    16sp sleep cell, no ellipsize) in the layout group below.

class _FakeBridge {
  final Map<String, Object?> saved = {};
  final List<String> saveAttempts = [];
  var updateAttempts = 0;

  /// When set, saving the logs key with the gated value blocks
  /// until [gate] completes — a deterministic stand-in for a slow
  /// platform-channel save in the FIRST of two overlapping pushes.
  String? gateLogsValue;
  Completer<void>? gate;

  Future<void> save(String key, Object? value) async {
    saveAttempts.add(key);
    if (key == WidgetSync.keyLogs &&
        value == gateLogsValue &&
        gate != null &&
        !gate!.isCompleted) {
      await gate!.future;
    }
    saved[key] = value;
  }

  Future<void> update() async {
    updateAttempts++;
  }

  void install() => WidgetSync.debugSetBridge(save: save, update: update);

  void reset() {
    saved.clear();
    saveAttempts.clear();
    updateAttempts = 0;
    gateLogsValue = null;
    gate = null;
  }
}

/// The founder's snapshot: the exact values from the Round 58
/// phone test. currentStreak is 2 (the number the old widget
/// wrongly showed in the flame cell).
HomeCacheSnapshot _founderSnap({int logCountToday = 7}) {
  return HomeCacheSnapshot(
    vitals: TodayVitals(
      heartRate: 66,
      activeCalories: 62,
      sleepMinutes: 516, // 8h36m
      logCountToday: logCountToday,
    ),
    vitalsLoaded: true,
    currentStreak: 2,
    bestStreak: 9,
    streakLoaded: true,
  );
}

void main() {
  final bridge = _FakeBridge();

  setUp(() {
    bridge.reset();
    bridge.install();
  });

  tearDown(WidgetSync.debugResetBridge);

  group('R59 parity: the payload IS the strip, field for field', () {
    test('founder snapshot → HR 66, flame = calories 62 (not the '
        'streak 2), logs 7, sleep "8h36m"', () {
      final payload =
          WidgetSync.buildPayload(_founderSnap(), signedIn: true);
      expect(payload.heartRate, '66');
      expect(payload.calories, '62');
      expect(payload.logs, '7');
      expect(payload.sleep, '8h36m');
      // The streak leaks into NO cell.
      for (final value in payload.toMap().values) {
        expect(value.toString(), isNot('2'));
      }
    });

    test('flame cell reads vitals.activeCalories when the streak '
        'disagrees — changing ONLY the streak changes nothing', () {
      final a = WidgetSync.buildPayload(_founderSnap(), signedIn: true);
      final b = WidgetSync.buildPayload(
        const HomeCacheSnapshot(
          vitals: TodayVitals(
            heartRate: 66,
            activeCalories: 62,
            sleepMinutes: 516,
            logCountToday: 7,
          ),
          vitalsLoaded: true,
          currentStreak: 44,
          bestStreak: 90,
          streakLoaded: true,
        ),
        signedIn: true,
      );
      expect(b, a);
    });

    test('sleep string is the strip formatter\'s string, verbatim, '
        'across the format\'s whole range', () {
      for (final minutes in [45, 60, 516, 600, 725]) {
        final payload = WidgetSync.buildPayload(
          HomeCacheSnapshot(
            vitals: TodayVitals(sleepMinutes: minutes),
            vitalsLoaded: true,
            currentStreak: null,
            bestStreak: null,
            streakLoaded: true,
          ),
          signedIn: true,
        );
        expect(payload.sleep, formatSleepMinutes(minutes),
            reason: '$minutes minutes');
      }
      // Long forms, spelled out (the formatter does NOT zero-pad
      // minutes): the layout must fit these on one line.
      expect(formatSleepMinutes(725), '12h5m');
      expect(formatSleepMinutes(659), '10h59m');
    });

    test('logs cell is the strip counter field (logCountToday), '
        'including a loaded 0', () {
      expect(
        WidgetSync.buildPayload(_founderSnap(logCountToday: 0),
                signedIn: true)
            .logs,
        '0',
      );
      expect(
        WidgetSync.buildPayload(_founderSnap(logCountToday: 23),
                signedIn: true)
            .logs,
        '23',
      );
    });
  });

  group('R59 push serialization: last initiated push wins, whole', () {
    test('a stale push blocked mid-sequence cannot overwrite a '
        'fresh push that was initiated after it', () async {
      bridge.gateLogsValue = '1';
      bridge.gate = Completer<void>();

      final stale =
          WidgetSync.pushSnapshot(_founderSnap(logCountToday: 1),
              signedIn: true);
      final fresh = WidgetSync.pushSnapshot(_founderSnap(),
          signedIn: true);
      await pumpEventQueue();

      // The fresh push has NOT started: pushes run one payload at a
      // time, in call order (pre-fix, its saves interleaved with
      // the stale push's and whichever logs save landed last won).
      expect(bridge.saveAttempts, const [
        WidgetSync.keySignedIn,
        WidgetSync.keyHeartRate,
        WidgetSync.keyCalories,
        WidgetSync.keyLogs, // blocked here, mid-stale-payload
      ]);
      expect(bridge.updateAttempts, 0);

      bridge.gate!.complete();
      await Future.wait([stale, fresh]);

      // Both pushes completed, in order; the store ends on the
      // FRESH payload — the founder's exact strip values.
      expect(bridge.saveAttempts, const [
        WidgetSync.keySignedIn,
        WidgetSync.keyHeartRate,
        WidgetSync.keyCalories,
        WidgetSync.keyLogs,
        WidgetSync.keySleep,
        WidgetSync.keySignedIn,
        WidgetSync.keyHeartRate,
        WidgetSync.keyCalories,
        WidgetSync.keyLogs,
        WidgetSync.keySleep,
      ]);
      expect(bridge.saved, <String, Object?>{
        WidgetSync.keySignedIn: true,
        WidgetSync.keyHeartRate: '66',
        WidgetSync.keyCalories: '62',
        WidgetSync.keyLogs: '7',
        WidgetSync.keySleep: '8h36m',
      });
      expect(bridge.updateAttempts, 2);
    });

    test('a clear initiated after a push lands after it (logout '
        'can never be overwritten back by the push\'s tail)',
        () async {
      final push = WidgetSync.pushSnapshot(_founderSnap(),
          signedIn: true);
      final clear = WidgetSync.clear();
      await Future.wait([push, clear]);
      expect(bridge.saved, const <String, Object?>{
        WidgetSync.keySignedIn: false,
        WidgetSync.keyHeartRate: '--',
        WidgetSync.keyCalories: '--',
        WidgetSync.keyLogs: '--',
        WidgetSync.keySleep: '--',
      });
      expect(bridge.updateAttempts, 2);
    });
  });

  group('R59 HomeDataCache.applyLogCountToday', () {
    final disk = <String, String>{};

    setUp(() {
      disk.clear();
      HomeDataCache.instance.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async => disk[key] = value,
        delete: (key) async => disk.remove(key),
      );
      HomeDataCache.instance.debugReset();
    });

    tearDown(() => HomeDataCache.instance.debugReset());

    test('mirrors the new count, preserves the other vitals, and '
        'persist() pushes the founder strip values with logs moved '
        '1 → 7', () async {
      final cache = HomeDataCache.instance;
      cache.applyVitals(const TodayVitals(
        heartRate: 66,
        activeCalories: 62,
        sleepMinutes: 516,
        logCountToday: 1,
      ));
      cache.applyStreak(2, 9);
      await cache.persist();
      await pumpEventQueue();
      expect(bridge.saved[WidgetSync.keyLogs], '1');
      expect(bridge.updateAttempts, 1);

      // What an entry creation does (Quick Log / History call this
      // exact pair after a successful post).
      expect(cache.applyLogCountToday(7), isTrue);
      await cache.persist();
      await pumpEventQueue();

      expect(bridge.saved, <String, Object?>{
        WidgetSync.keySignedIn: true,
        WidgetSync.keyHeartRate: '66',
        WidgetSync.keyCalories: '62',
        WidgetSync.keyLogs: '7',
        WidgetSync.keySleep: '8h36m',
      });
      expect(bridge.updateAttempts, 2);
      final snap = cache.snapshot;
      expect(snap.vitals!.logCountToday, 7);
      expect(snap.vitals!.heartRate, 66);
      expect(snap.currentStreak, 2);
    });

    test('same count re-applied reports no change', () {
      final cache = HomeDataCache.instance;
      cache.applyVitals(const TodayVitals(logCountToday: 4));
      expect(cache.applyLogCountToday(4), isFalse);
      expect(cache.applyLogCountToday(5), isTrue);
    });

    test('no vitals yet: seeds a count-only section (biometrics '
        'stay "--", never invented) and persist() still pushes',
        () async {
      final cache = HomeDataCache.instance;
      expect(cache.applyLogCountToday(3), isTrue);
      await cache.persist();
      await pumpEventQueue();
      expect(bridge.saved, <String, Object?>{
        WidgetSync.keySignedIn: true,
        WidgetSync.keyHeartRate: '--',
        WidgetSync.keyCalories: '--',
        WidgetSync.keyLogs: '3',
        WidgetSync.keySleep: '--',
      });
    });

    test('yesterday\'s vitals are NOT resurrected by a count '
        'mirror: stale biometrics drop, only the count carries',
        () {
      final cache = HomeDataCache.instance;
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      cache.applyVitals(
        const TodayVitals(
          heartRate: 70,
          activeCalories: 300,
          sleepMinutes: 400,
          logCountToday: 2,
        ),
        now: yesterday,
      );
      expect(cache.applyLogCountToday(5), isTrue);
      final snap = cache.snapshot;
      expect(snap.vitalsLoaded, isTrue);
      expect(snap.vitals!.logCountToday, 5);
      expect(snap.vitals!.heartRate, isNull);
      expect(snap.vitals!.activeCalories, isNull);
      expect(snap.vitals!.sleepMinutes, isNull);
    });
  });

  group('R59 RemoteViews layout: no value can wrap', () {
    final layout = File('android/app/src/main/res/layout/'
        'vitals_widget.xml');

    String textViewBlock(String xml, String id) {
      final start = xml.indexOf('android:id="@+id/$id"');
      expect(start, isNonNegative, reason: '$id must exist');
      final end = xml.indexOf('/>', start);
      return xml.substring(start, end);
    }

    test('every value TextView is single-line capped, with no '
        'ellipsize (the sleep unit must never be amputated)', () {
      final xml = layout.readAsStringSync();
      for (final id in [
        'widget_heart_rate',
        'widget_streak',
        'widget_logs',
        'widget_sleep',
      ]) {
        final block = textViewBlock(xml, id);
        expect(block, contains('android:singleLine="true"'),
            reason: id);
        expect(block, contains('android:maxLines="1"'), reason: id);
        // Ellipsize is only partially honored by RemoteViews
        // TextViews and would cut "8h36m" to "8h36…" — the fix
        // must be fit, not truncation.
        expect(block, isNot(contains('ellipsize')), reason: id);
      }
      // Autosize is AppCompat-only: it silently does nothing in a
      // launcher-inflated RemoteViews TextView, so it must not be
      // what the fix relies on.
      expect(xml, isNot(contains('autoSizeTextType="')));
    });

    test('the variable-length sleep cell is shrunk to 16sp; the '
        'fixed-width numeric cells stay at the widget\'s 20sp', () {
      final xml = layout.readAsStringSync();
      expect(textViewBlock(xml, 'widget_sleep'),
          contains('android:textSize="16sp"'));
      for (final id in [
        'widget_heart_rate',
        'widget_streak',
        'widget_logs',
      ]) {
        expect(textViewBlock(xml, id),
            contains('android:textSize="20sp"'),
            reason: id);
      }
    });

    test('the provider still binds all four ids the layout '
        'declares (the R58 artifact gate\'s contract)', () {
      final provider = File(
              'android/app/src/main/kotlin/com/notel/notel/playground/'
              'flutter/VitalsWidgetProvider.kt')
          .readAsStringSync();
      for (final id in [
        'widget_heart_rate',
        'widget_streak',
        'widget_logs',
        'widget_sleep',
      ]) {
        expect(provider, contains('R.id.$id'), reason: id);
      }
      // The calories value travels under the Round 50 wire key.
      expect(provider, contains('KEY_CALORIES = "widget_streak"'));
    });
  });

  testWidgets('entry creation (Quick Log save) triggers a widget '
      'push carrying the new today count', (tester) async {
    // Server state: six entries today; the save below makes seven.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final serverEntries = <Map<String, dynamic>>[
      for (var i = 1; i <= 6; i++)
        QuickLogEntry(
          id: i,
          categoryId: 3,
          body: 'Entry $i',
          chips: '',
          manualText: '',
          timestamp: nowMs,
        ).toSyncJson(),
    ];
    const cat = QuickLogCategory(
      id: 3,
      name: 'Symptoms',
      icon: 'circle',
      colorHex: '#4ECDC4',
      isDefault: true,
      sortOrder: 0,
    );
    final backend = TabsBackend(
      sessionStore: FakeSessionStore()..token = 'test-token',
      client: MockClient((http.Request request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': serverEntries,
              'categories': [cat.toSyncJson()],
              'profile': <String, dynamic>{},
              'isUnlimited': false,
              'isAdmin': false,
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/entries' &&
            request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          for (final e in body['entries'] as List) {
            serverEntries.add(e as Map<String, dynamic>);
          }
          return http.Response('{}', 200);
        }
        return http.Response('not found', 404);
      }),
    );

    // Home state as Home's last load left it: the founder's strip
    // values with the STALE count (1) — what the widget showed.
    final homeDisk = <String, String>{};
    HomeDataCache.instance.debugSetStore(
      read: (key) async => homeDisk[key],
      write: (key, value) async => homeDisk[key] = value,
      delete: (key) async => homeDisk.remove(key),
    );
    HomeDataCache.instance.debugReset();
    HomeDataCache.instance.applyVitals(const TodayVitals(
      heartRate: 66,
      activeCalories: 62,
      sleepMinutes: 516,
      logCountToday: 1,
    ));
    HomeDataCache.instance.applyStreak(2, 9);

    final quickDisk = <String, String>{};
    QuickLogCache.instance.debugReset();
    QuickLogCache.instance.debugSetStore(
      read: (key) async => quickDisk[key],
      write: (key, value) async => quickDisk[key] = value,
      delete: (key) async => quickDisk.remove(key),
    );
    // Optimistic logging (Oct 27, 2026): the save path stages the
    // entry in the log-entry outbox before anything else — keep the
    // singleton on an in-memory disk here too.
    final outboxDisk = <String, String>{};
    LogEntryOutbox.instance.debugReset();
    LogEntryOutbox.instance.debugSetStore(
      read: (key) async => outboxDisk[key],
      write: (key, value) async => outboxDisk[key] = value,
      delete: (key) async => outboxDisk.remove(key),
    );
    addTearDown(() {
      HomeDataCache.instance.debugReset();
      QuickLogCache.instance.debugReset();
      LogEntryOutbox.instance.debugReset();
    });

    await tester.pumpWidget(MaterialApp(
      home: QuickLogScreen(backend: backend),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('Symptoms'), findsWidgets);

    // Type a note and save it through the details field's add
    // button — the real `_saveEntry` entry-creation path.
    await tester.enterText(find.byType(TextField).first, 'Headache');
    await tester.pump();
    await tester.tap(find.byTooltip('Log typed note'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The save landed (the screen's own count says 7)…
    expect(find.text('Entry logged · 7 today'), findsOneWidget);
    // …and exactly one widget push carried the new count, with the
    // rest of the strip untouched.
    await tester.pump();
    expect(bridge.saved, <String, Object?>{
      WidgetSync.keySignedIn: true,
      WidgetSync.keyHeartRate: '66',
      WidgetSync.keyCalories: '62',
      WidgetSync.keyLogs: '7',
      WidgetSync.keySleep: '8h36m',
    });
    expect(bridge.updateAttempts, 1);
    expect(HomeDataCache.instance.snapshot.vitals!.logCountToday, 7);
  });
}
