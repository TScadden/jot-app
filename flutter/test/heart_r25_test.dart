import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/heart/heart_spike_review_screen.dart';

/// Round 25 — Heart screen tests.
///
/// Pure-logic tests pin the NATIVE algorithms (traced in
/// heart_data.dart): the Heart ViewModel's awake/asleep split (hours
/// 7..22 / 23..6), the spikes card's 5-minute window, the review
/// screen's 3-minute gap rule, the p10 baseline, load thresholds, and
/// the founder's zero rule. Widget tests run the real screens against
/// a fake Health Connect service.

int _ms(int hour, [int minute = 0]) =>
    DateTime(2026, 10, 12, hour, minute).millisecondsSinceEpoch;

HrSample _s(int hour, int bpm, [int minute = 0]) =>
    HrSample(timeMs: _ms(hour, minute), bpm: bpm);

class FakeHeartHc extends HealthConnectService {
  FakeHeartHc({this.connected = true, this.byDate = const {}});

  final bool connected;
  final Map<String, List<HrSample>> byDate;
  int readCount = 0;

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<bool> hasPersistedConnection() async => connected;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    readCount++;
    return byDate[dateStr] ?? const [];
  }
}

String _todayStr() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

int _todayMs(int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute)
      .millisecondsSinceEpoch;
}

void main() {
  group('heart_data pure logic', () {
    test('zero samples are filtered before every computation', () {
      final samples = [_s(8, 0), _s(9, 80), _s(10, 0)];
      final data = HeartDayData.fromSamples(samples);
      expect(data.samples, hasLength(1));
      expect(data.awakeAvg, 80);
      expect(data.peakBpm, 80);
      expect(data.latest!.bpm, 80);
    });

    test('all-zero input is honestly empty', () {
      final data = HeartDayData.fromSamples([_s(8, 0), _s(9, 0)]);
      expect(data.samples, isEmpty);
      expect(data.awakeAvg, isNull);
      expect(data.asleepAvg, isNull);
      expect(data.peakBpm, isNull);
      expect(data.spikesCard.spikeCount, 0);
      expect(data.spikesCard.loadLevel, 'Normal load');
      expect(data.spikeEvents, isEmpty);
    });

    test('awake window is hours 7..22, asleep 23..6 (Round 26 unified)', () {
      // 2:00 asleep, 6:00 asleep, 7:00 awake, 22:30 awake (the
      // Round 26 alignment hour), 23:30 asleep.
      final samples = [_s(2, 50), _s(6, 40), _s(7, 70), _s(22, 90, 30), _s(23, 60, 30)];
      expect(heartAwakeAverage(samples), 80); // (70+90)/2
      expect(heartAsleepAverage(samples), 50); // (50+40+60)/3
    });

    test('awake average has NO fallback when the window is empty', () {
      expect(heartAwakeAverage([_s(2, 50)]), isNull);
      expect(heartAsleepAverage([_s(12, 70)]), isNull);
    });

    test('averages truncate like Kotlin Double.average().toInt()', () {
      // (70 + 71) / 2 = 70.5 -> 70, not 71.
      expect(heartAwakeAverage([_s(8, 70), _s(9, 71)]), 70);
    });

    test('p10 baseline uses index (size * 0.10).toInt()', () {
      final samples = [
        for (var bpm = 50; bpm < 60; bpm++) _s(8, bpm),
      ];
      // sorted 50..59, index 1 -> 51.
      expect(heartBaselineP10(samples), 51);
      expect(heartBaselineP10(const []), isNull);
    });

    test('card spikes: 5-minute window after the last >=100 sample', () {
      final base = _ms(10);
      HrSample at(int minuteOffset, int bpm) => HrSample(
          timeMs: base + minuteOffset * 60000, bpm: bpm);
      // 0m, 4m, 8m: each within 5 min of the previous spike sample,
      // so the card counts ONE event.
      final samples = [at(0, 120), at(4, 125), at(8, 130), at(60, 70)];
      final card = computeHeartSpikesCard(samples);
      expect(card.spikeCount, 1);
      expect(card.maxBpm, 130);
      // p10 of [70,120,125,130] -> index 0 -> 70; delta = 130-70.
      expect(card.baselineP10, 70);
      expect(card.maxDelta, 60);
    });

    test('card spikes: a gap over 5 minutes starts a new event', () {
      final base = _ms(10);
      HrSample at(int minuteOffset, int bpm) => HrSample(
          timeMs: base + minuteOffset * 60000, bpm: bpm);
      final card = computeHeartSpikesCard([at(0, 120), at(6, 121)]);
      expect(card.spikeCount, 2);
    });

    test('review spikes: 3-minute gap rule splits what the card joins', () {
      final base = _ms(10);
      HrSample at(int minuteOffset, int bpm) => HrSample(
          timeMs: base + minuteOffset * 60000, bpm: bpm);
      // Same series as the card test above: card = 1 event, review = 3.
      final samples = [at(0, 120), at(4, 125), at(8, 130), at(60, 70)];
      final events = detectSpikeEvents(samples);
      expect(events, hasLength(3));
      // Sorted by peak descending.
      expect(events.map((e) => e.peakBpm), [130, 125, 120]);
    });

    test('review events: jump is peak minus p10, duration floors at 1m', () {
      final base = _ms(9);
      HrSample at(int minuteOffset, int bpm) => HrSample(
          timeMs: base + minuteOffset * 60000, bpm: bpm);
      // 10 low readings pin p10 at 60; one spike at 150 for 1 sample.
      final samples = [
        for (var i = 0; i < 10; i++) at(i, 60),
        at(30, 150),
        at(31, 155),
      ];
      final events = detectSpikeEvents(samples);
      expect(events, hasLength(1));
      expect(events.single.peakBpm, 155);
      expect(events.single.jumpDelta, 95); // 155 - 60
      expect(events.single.durationMins, 1); // (31-30) min
      expect(events.single.source, 'Health Connect');
    });

    test('load thresholds match native exactly', () {
      expect(heartLoadLevel(maxBpm: 130, spikeCount: 0), 'High load');
      expect(heartLoadLevel(maxBpm: 100, spikeCount: 5), 'High load');
      expect(heartLoadLevel(maxBpm: 110, spikeCount: 0), 'Moderate load');
      expect(heartLoadLevel(maxBpm: 90, spikeCount: 2), 'Moderate load');
      expect(heartLoadLevel(maxBpm: 109, spikeCount: 1), 'Normal load');
      expect(heartLoadLevel(maxBpm: 0, spikeCount: 0), 'Normal load');
    });

    test('formatHrTime matches SimpleDateFormat h:mm a', () {
      expect(formatHrTime(_ms(9, 5)), '9:05 AM');
      expect(formatHrTime(_ms(12, 0)), '12:00 PM');
      expect(formatHrTime(_ms(0, 0)), '12:00 AM');
      expect(formatHrTime(_ms(13, 30)), '1:30 PM');
    });

    test('date label: Today or MMM d', () {
      expect(heartDateLabel('2026-10-12', '2026-10-12'), 'Today');
      expect(heartDateLabel('today', '2026-10-12'), 'Today');
      expect(heartDateLabel('2026-10-03', '2026-10-12'), 'Oct 3');
    });

    test('synced-ago labels derive from the real timestamp', () {
      final now = DateTime(2026, 10, 12, 12, 0);
      expect(formatSyncedAgo(null, now), 'Not synced yet');
      expect(formatSyncedAgo(now, now), 'Synced just now');
      expect(
          formatSyncedAgo(now.subtract(const Duration(minutes: 1)), now),
          'Synced 1 min ago');
      expect(
          formatSyncedAgo(now.subtract(const Duration(minutes: 2)), now),
          'Synced 2 min ago');
      expect(formatSyncedAgo(now.subtract(const Duration(hours: 3)), now),
          'Synced 3 hr ago');
    });

    test('spike context readings span +-10 minutes', () {
      final base = _ms(10);
      HrSample at(int minuteOffset, int bpm) => HrSample(
          timeMs: base + minuteOffset * 60000, bpm: bpm);
      final samples = [at(-11, 60), at(-10, 61), at(0, 120), at(10, 62), at(11, 63)];
      final event = detectSpikeEvents(samples).single;
      final ctx = spikeContextReadings(samples, event);
      expect(ctx.map((s) => s.bpm), [61, 120, 62]);
    });
  });

  group('HeartDataCache', () {
    final store = <String, String>{};

    setUp(() {
      HeartDataCache.instance.debugReset();
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
      store.clear();
    });

    test('apply filters zeros so they are never cached', () async {
      final data = HeartDataCache.instance.apply(
          '2026-10-12', [_s(8, 0), _s(9, 80)],
          ownerEmail: 'a@b.c');
      expect(data.samples, hasLength(1));
      await HeartDataCache.instance.persist();
      expect(store[HeartDataCache.storageKey], isNotNull);
      expect(store[HeartDataCache.storageKey], isNot(contains('"bpm":0')));
    });

    test('snapshot renders instantly for a loaded date only', () {
      HeartDataCache.instance
          .apply('2026-10-12', [_s(9, 80)], ownerEmail: 'a@b.c');
      expect(
          HeartDataCache.instance.snapshot('2026-10-12')?.awakeAvg, 80);
      expect(HeartDataCache.instance.snapshot('2026-10-11'), isNull);
    });

    test('owner mismatch wipes the cache', () async {
      HeartDataCache.instance
          .apply('2026-10-12', [_s(9, 80)], ownerEmail: 'a@b.c');
      final wiped = await HeartDataCache.instance
          .clearIfOwnerMismatch('other@b.c');
      expect(wiped, isTrue);
      expect(HeartDataCache.instance.snapshot('2026-10-12'), isNull);
    });

    test('disk warm restores samples and drops zeros', () async {
      HeartDataCache.instance
          .apply('2026-10-12', [_s(8, 0), _s(9, 80)], ownerEmail: 'a@b.c');
      await HeartDataCache.instance.persist();
      HeartDataCache.instance.debugReset();
      // debugReset cleared the in-memory store hooks? No: hooks persist;
      // only memory state resets. Re-set hooks to be safe.
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
      await HeartDataCache.instance.warmFromDisk(currentEmail: 'a@b.c');
      final snap = HeartDataCache.instance.snapshot('2026-10-12');
      expect(snap?.samples, hasLength(1));
      expect(snap?.awakeAvg, 80);
      expect(HeartDataCache.instance.lastSyncAt, isNotNull);
    });
  });

  group('HeartScreen widgets', () {
    setUp(() {
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
    });

    List<HrSample> todaySamples() => [
          HrSample(timeMs: _todayMs(2), bpm: 50),
          HrSample(timeMs: _todayMs(8), bpm: 70),
          HrSample(timeMs: _todayMs(9), bpm: 80),
          HrSample(timeMs: _todayMs(10), bpm: 120),
          HrSample(timeMs: _todayMs(10, 2), bpm: 125),
          HrSample(timeMs: _todayMs(11), bpm: 130),
        ];

    Future<void> pumpHeart(WidgetTester tester, FakeHeartHc hc) async {
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: hc,
          cache: HeartDataCache.instance,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('connected: renders native summary, pattern, spikes',
        (tester) async {
      await pumpHeart(
        tester,
        FakeHeartHc(byDate: {_todayStr(): todaySamples()}),
      );
      expect(find.text('Heart'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      // Awake avg over 7..22 samples: (70+80+120+125+130)/5 = 105.
      expect(find.text('Awake average'), findsOneWidget);
      expect(find.text('105 bpm'), findsOneWidget);
      expect(find.text('Asleep 50 bpm'), findsOneWidget);
      expect(find.text('Last 130 bpm · 11:00 AM'), findsOneWidget);
      expect(find.text('Today’s pattern'), findsOneWidget);
      expect(find.text('Heart rate from 12 AM to 11:59 PM'),
          findsOneWidget);
      expect(find.text('Resting range (45 to 70 bpm)'), findsOneWidget);
      expect(find.text('Peak 130 bpm'), findsOneWidget);
      // Card algorithm: 10:00 cluster + 11:00 = 2 events; max 130.
      expect(find.text('2 significant spikes'), findsOneWidget);
      expect(find.text('High load'), findsWidgets);
      expect(find.text('130'), findsOneWidget); // PEAK metric
      expect(find.text('+80'), findsOneWidget); // 130 - p10(50)
      expect(find.text('Review spikes'), findsOneWidget);
      expect(find.text('Health Connect'), findsOneWidget);
      expect(find.text('Synced just now'), findsOneWidget);
    });

    testWidgets('connected with no data: honest -- states', (tester) async {
      await pumpHeart(tester, FakeHeartHc(byDate: const {}));
      expect(find.text('-- bpm'), findsOneWidget);
      expect(find.text('Asleep -- bpm'), findsOneWidget);
      expect(find.text('Last -- bpm'), findsOneWidget);
      expect(find.text('Peak --'), findsOneWidget);
      expect(find.text('0 significant spikes'), findsOneWidget);
      expect(find.text('Normal load'), findsWidgets);
    });

    testWidgets('not connected: native Connect Vital Signs state',
        (tester) async {
      await pumpHeart(tester, FakeHeartHc(connected: false));
      expect(find.text('Connect Vital Signs'), findsOneWidget);
      expect(
          find.text(
              'Link Health Connect to automatically sync your heart rate and sleep data.'),
          findsOneWidget);
      expect(find.text('Link Health Connect'), findsOneWidget);
      expect(find.text('Awake average'), findsNothing);
    });

    testWidgets('info dialog carries the native copy', (tester) async {
      await pumpHeart(
        tester,
        FakeHeartHc(byDate: {_todayStr(): todaySamples()}),
      );
      await tester.tap(find.byIcon(Icons.info));
      await tester.pumpAndSettle();
      expect(find.text('Heart Rate Insights'), findsOneWidget);
      expect(
          find.text(
              "Tabs tracks your 'Awake Average' to better understand your physiological load throughout the day."),
          findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);
    });

    testWidgets('Review spikes pushes the review screen',
        (tester) async {
      await pumpHeart(
        tester,
        FakeHeartHc(byDate: {_todayStr(): todaySamples()}),
      );
      await tester.ensureVisible(find.text('Review spikes'));
      await tester.tap(find.text('Review spikes'));
      await tester.pumpAndSettle();
      expect(find.text('Spike Review'), findsOneWidget);
      // Review algorithm on the same series: also 2 events.
      expect(find.text('2 Significant Spikes Detected'), findsOneWidget);
      expect(find.text('Showing heart rate spikes ≥100 bpm for today'),
          findsOneWidget);
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('130 bpm'), findsOneWidget);
      // Expand the top spike: context readings appear.
      await tester.tap(find.text('#1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Surrounding Context'), findsOneWidget);
    });
  });

  group('HeartSpikeReviewScreen widgets', () {
    testWidgets('empty: native normal-load state', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: HeartSpikeReviewScreen(samples: []),
      ));
      await tester.pumpAndSettle();
      expect(find.text('0 Significant Spikes Detected'), findsOneWidget);
      expect(find.text('No spikes ≥100 bpm recorded for this time range'),
          findsOneWidget);
      expect(find.text('Normal Physiological Load'), findsOneWidget);
      expect(
          find.text(
              'All heart rate readings stayed within normal resting and active ranges.'),
          findsOneWidget);
    });

    testWidgets('zero samples never appear as spikes', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: HeartSpikeReviewScreen(samples: [_s(9, 0), _s(10, 0)]),
      ));
      await tester.pumpAndSettle();
      expect(find.text('0 Significant Spikes Detected'), findsOneWidget);
    });
  });
}
