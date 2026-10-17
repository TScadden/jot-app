import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/sleep_need.dart';

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

class _FakeHc extends HealthConnectService {
  List<({String date, int bpm})> hr = const [];
  List<({String date, int kcal})> cal = const [];
  List<({String date, int mins, int deep})> sleep = const [];
  List<({String date, int count})> spikes = const [];
  double? hrvValue;
  bool failHr = false;
  final List<String> calls = [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async {
    calls.add('hr$days');
    if (failHr) {
      lastReadErrorCode = 'READ_FAILED';
      return const [];
    }
    return hr;
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async {
    calls.add('cal$days');
    return cal;
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    calls.add('sleep$days');
    return sleep;
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async {
    calls.add('spikes$days');
    return spikes;
  }

  @override
  Future<double?> readHrvRmssd(String dateStr) async => hrvValue;
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  late _FakeStore fake;
  late HealthHistoryStore store;
  late _FakeHc hc;
  late HealthHistoryQueries queries;
  final today = DateTime.now();
  String ago(int n) => _ds(today.subtract(Duration(days: n)));

  setUp(() {
    fake = _FakeStore();
    store = HealthHistoryStore.testInstance();
    store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
    store.debugReset();
    hc = _FakeHc();
    queries = HealthHistoryQueries(hc: hc, store: store);
  });

  group('union helper (WS2)', () {
    test('store-only depth is served without any HC data', () async {
      await store.mergeRefresh([
        for (var i = 40; i >= 0; i--)
          DailyBiometrics(
              date: ago(i), restingHrBpm: 60, sleepMinutes: 420),
      ]);
      hc.hr = const [];
      hc.sleep = const [];
      final union = await queries.loadDays(41, metrics: {
        HistoryMetric.restingHr,
        HistoryMetric.sleep,
      });
      expect(union.restingHr.length, 41);
      expect(union.sleepMinutes[ago(40)], 420);
      expect(union.failedMetrics, isEmpty);
    });

    test('fresh HC wins inside its window, store fills older days',
        () async {
      await store.mergeRefresh([
        DailyBiometrics(date: ago(10), restingHrBpm: 55, sleepMinutes: 400),
        DailyBiometrics(date: ago(1), restingHrBpm: 55, sleepMinutes: 400),
      ]);
      hc.hr = [(date: ago(1), bpm: 63)];
      hc.sleep = [(date: ago(1), mins: 450, deep: 90)];
      final union = await queries.loadDays(14, metrics: {
        HistoryMetric.restingHr,
        HistoryMetric.sleep,
      });
      expect(union.restingHr[ago(1)], 63); // fresh wins
      expect(union.restingHr[ago(10)], 55); // store fills
      expect(union.sleepMinutes[ago(1)], 450);
      expect(union.sleepMinutes[ago(10)], 400);
      expect(union.deepSleepMinutes[ago(1)], 90);
    });

    test('HC data fetched by a read is persisted: a second, HC-less '
        'read serves the refreshed value from the store', () async {
      hc.hr = [(date: ago(1), bpm: 63)];
      final first = await queries
          .loadDays(7, metrics: {HistoryMetric.restingHr});
      expect(first.restingHr[ago(1)], 63);
      hc.hr = const []; // HC window has moved on / lost the day
      final second = await queries
          .loadDays(7, metrics: {HistoryMetric.restingHr});
      expect(second.restingHr[ago(1)], 63);
      final stored = await store.readAll();
      expect(stored[ago(1)]!.restingHrBpm, 63);
    });

    test('zero rule on HC inputs: 0/negative never returned or stored; '
        'spike 0 is real', () async {
      hc.hr = [(date: ago(1), bpm: 0), (date: ago(2), bpm: -3)];
      hc.sleep = [(date: ago(1), mins: 0, deep: 0)];
      hc.cal = [(date: ago(1), kcal: 0)];
      hc.spikes = [(date: ago(1), count: 0), (date: ago(2), count: -1)];
      final union = await queries.loadDays(7);
      expect(union.restingHr, isEmpty);
      expect(union.sleepMinutes, isEmpty);
      expect(union.deepSleepMinutes, isEmpty);
      expect(union.calories, isEmpty);
      expect(union.spikes, {ago(1): 0});
      expect(await store.dayCount(), 1); // only the real spike day
    });

    test('a failed HC read is flagged, and the store still serves',
        () async {
      await store.mergeRefresh([
        DailyBiometrics(date: ago(2), restingHrBpm: 58),
      ]);
      hc.failHr = true;
      final union = await queries
          .loadDays(7, metrics: {HistoryMetric.restingHr});
      expect(union.failed(HistoryMetric.restingHr), isTrue);
      expect(union.restingHr[ago(2)], 58);
    });

    test('rows outside the requested range do not leak in', () async {
      hc.hr = [(date: ago(60), bpm: 70), (date: ago(1), bpm: 61)];
      final union = await queries
          .loadDays(7, metrics: {HistoryMetric.restingHr});
      expect(union.restingHr, {ago(1): 61});
    });

    test('HRV: per-day reads join the union and persist', () async {
      hc.hrvValue = 48.5;
      final union = await queries.loadDays(3, metrics: {HistoryMetric.hrv});
      expect(union.hrv.length, 3);
      expect(union.hrv[ago(0)], 48.5);
      final stored = await store.readAll();
      expect(stored[ago(0)]!.hrvRmssdMs, 48.5);
    });
  });

  group('sleep need derivation', () {
    Map<String, int> historyOf(List<int> nightsNewestLast) {
      // nightsNewestLast[i] is i+1 days ago, oldest first reversed:
      // build a map ending yesterday.
      final out = <String, int>{};
      for (var i = 0; i < nightsNewestLast.length; i++) {
        out[ago(nightsNewestLast.length - i)] = nightsNewestLast[i];
      }
      return out;
    }

    test('stable sleeper: need ≈ his typical night, no debt', () {
      final est = estimateSleepNeed(historyOf(List.filled(28, 450)))!;
      expect(est.baseNeedMinutes, 450);
      expect(est.recentDebtMinutes, 0);
      expect(est.tonightNeedMinutes, 450);
    });

    test('short sleeper with debt: tonight = base + capped debt', () {
      // 21 nights at 480, then the most recent 7 at 420.
      final est = estimateSleepNeed(
          historyOf([...List.filled(21, 480), ...List.filled(7, 420)]))!;
      expect(est.baseNeedMinutes, 480);
      expect(est.recentDebtMinutes, 7 * 60);
      expect(est.tonightNeedMinutes, 480 + 120); // cap binds
    });

    test('sparse data: fewer than 7 nights → null estimate', () {
      expect(estimateSleepNeed(historyOf(List.filled(6, 480))), isNull);
      expect(estimateSleepNeed(const {}), isNull);
      expect(estimateSleepNeed(historyOf(List.filled(7, 480))),
          isNotNull);
    });

    test('missing nights are excluded, never treated as 0 sleep', () {
      // 7 nights with data spread over 20 calendar days, all 480:
      // no debt, base 480 — calendar gaps do not count as nights.
      final sparse = <String, int>{
        for (var i = 0; i < 7; i++) ago(20 - i * 3): 480,
      };
      final est = estimateSleepNeed(sparse)!;
      expect(est.baseNeedMinutes, 480);
      expect(est.recentDebtMinutes, 0);
      expect(est.debtNightsUsed, 7);
    });

    test('zero-minute entries are failed reads, not nights', () {
      final withZeros = <String, int>{
        for (var i = 1; i <= 7; i++) ago(i): 480,
        ago(8): 0,
        ago(9): 0,
      };
      final est = estimateSleepNeed(withZeros)!;
      expect(est.baseNightsUsed, 7);
      expect(est.baseNeedMinutes, 480);
    });

    test('per-night evaluation: need comes from prior nights only',
        () {
      final history = historyOf(List.filled(28, 480));
      final lastDate = ago(1);
      final eval = evaluateSleepNight(history, lastDate)!;
      expect(eval.asleepMinutes, 480);
      expect(eval.needMinutes, 480);
      expect(eval.balanceMinutes, 0);
      expect(eval.statusLabel, 'Near need');
      // A short latest night evaluates against the established need.
      final short = {...history, lastDate: 360};
      final evalShort = evaluateSleepNight(short, lastDate)!;
      expect(evalShort.needMinutes, 480);
      expect(evalShort.balanceMinutes, -120);
      expect(evalShort.statusLabel, 'Below need');
      expect(evalShort.asleepRatio, 360 / 480);
    });

    test('recent nights evaluation covers the last 7 nights with data',
        () {
      final history = historyOf(List.filled(20, 470));
      final evals = evaluateRecentNights(history);
      expect(evals.length, 7);
      expect(evals.last.date, ago(1));
      expect(evals.every((e) => e.needMinutes == 470), isTrue);
    });
  });
}
