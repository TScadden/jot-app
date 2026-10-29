import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/sleep_need.dart';

/// Sleep-bouts-summed (founder decision Oct 28, 2026): a night's
/// sleep total = all of that night's sleep bouts added up, overlaps
/// never double-counted. The interval-union math lives in Dart
/// (`summarizeSleepSessions`); the bridge returns per-session maps.

/// Local DateTime in 2026 (all fixtures are device-local, matching
/// the bridge's local-day attribution).
DateTime _dt(int month, int day, int hour, [int minute = 0]) =>
    DateTime(2026, month, day, hour, minute);

int _ms(DateTime d) => d.millisecondsSinceEpoch;

List<({int startMs, int endMs})> _ivs(List<(DateTime, DateTime)> pairs) => [
      for (final p in pairs)
        (startMs: _ms(p.$1), endMs: _ms(p.$2)),
    ];

SleepSessionRaw _session(
  String date,
  DateTime start,
  DateTime end, {
  List<(DateTime, DateTime)> awake = const [],
  List<(DateTime, DateTime)> deep = const [],
}) =>
    SleepSessionRaw(
      date: date,
      startMs: _ms(start),
      endMs: _ms(end),
      awake: _ivs(awake),
      deep: _ivs(deep),
    );

Map<String, Object> _sessionMap(
  String date,
  DateTime start,
  DateTime end, {
  List<(DateTime, DateTime)> awake = const [],
  List<(DateTime, DateTime)> deep = const [],
}) =>
    <String, Object>{
      'date': date,
      'startMs': _ms(start),
      'endMs': _ms(end),
      'awake': <List<int>>[
        for (final p in awake) [_ms(p.$1), _ms(p.$2)],
      ],
      'deep': <List<int>>[
        for (final p in deep) [_ms(p.$1), _ms(p.$2)],
      ],
    };

/// In-memory SecureStore fake — no platform channels.
class _MemStore implements SecureStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
  @override
  Future<void> delete(String key) async => _map.remove(key);
}

/// Reference merge used ONLY by the single-session regression
/// anchor (case e): an independent re-implementation of the OLD
/// per-session arithmetic so the anchor does not just compare
/// `summarizeSleepSessions` against itself.
List<({int startMs, int endMs})> _mergeRef(
    List<({int startMs, int endMs})> intervals) {
  final sorted = [
    for (final iv in intervals)
      if (iv.endMs > iv.startMs) iv,
  ]..sort((a, b) => a.startMs.compareTo(b.startMs));
  final out = <({int startMs, int endMs})>[];
  for (final iv in sorted) {
    if (out.isEmpty || iv.startMs > out.last.endMs) {
      out.add(iv);
    } else if (iv.endMs > out.last.endMs) {
      out[out.length - 1] = (startMs: out.last.startMs, endMs: iv.endMs);
    }
  }
  return out;
}

/// The OLD algorithm for the single-session case: duration minus
/// merged awake, and merged deep minutes.
({int mins, int deep}) _oldSingleSession(SleepSessionRaw s) {
  var awakeMs = 0;
  for (final iv in _mergeRef(s.awake)) {
    final start = iv.startMs < s.startMs ? s.startMs : iv.startMs;
    final end = iv.endMs > s.endMs ? s.endMs : iv.endMs;
    if (end > start) awakeMs += end - start;
  }
  var deepMs = 0;
  for (final iv in _mergeRef(s.deep)) {
    deepMs += iv.endMs - iv.startMs;
  }
  return (
    mins: ((s.endMs - s.startMs) - awakeMs) ~/ 60000,
    deep: deepMs ~/ 60000,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('summarizeSleepSessions', () {
    test('a. two non-overlapping bouts, same wake date -> full sum', () {
      final out = summarizeSleepSessions([
        _session('2026-10-28', _dt(10, 27, 23), _dt(10, 28, 1),
            deep: [(_dt(10, 27, 23, 30), _dt(10, 28, 0))]),
        _session('2026-10-28', _dt(10, 28, 3), _dt(10, 28, 7),
            deep: [(_dt(10, 28, 4), _dt(10, 28, 4, 30))]),
      ]);
      // 120 + 240 = 360 asleep; deep 30 + 30 = 60.
      expect(out, [(date: '2026-10-28', mins: 360, deep: 60)]);
    });

    test('b. two overlapping sessions -> union, no double count', () {
      final out = summarizeSleepSessions([
        _session('2026-10-28', _dt(10, 27, 23), _dt(10, 28, 6)),
        _session('2026-10-28', _dt(10, 27, 23, 30), _dt(10, 28, 7)),
      ]);
      // Union 23:00-07:00 = 480, not 420 + 450.
      expect(out, [(date: '2026-10-28', mins: 480, deep: 0)]);
    });

    test('c. overlapping awake stages inside a bout excluded once', () {
      final out = summarizeSleepSessions([
        _session('2026-10-28', _dt(10, 27, 22), _dt(10, 28, 6),
            awake: [
              (_dt(10, 28, 1), _dt(10, 28, 1, 30)),
              (_dt(10, 28, 1, 15), _dt(10, 28, 1, 45)),
            ]),
      ]);
      // Session 480; merged awake 01:00-01:45 = 45; asleep 435.
      expect(out, [(date: '2026-10-28', mins: 435, deep: 0)]);
    });

    test('d. nap + main bout on the same wake date both count', () {
      final out = summarizeSleepSessions([
        _session('2026-10-28', _dt(10, 28, 13), _dt(10, 28, 14, 30)),
        _session('2026-10-28', _dt(10, 27, 23), _dt(10, 28, 6, 30)),
      ]);
      // Nap 90 + main 450 = 540.
      expect(out, [(date: '2026-10-28', mins: 540, deep: 0)]);
    });

    test('e. single-session regression anchor vs the OLD algorithm', () {
      final session = _session(
        '2026-10-28',
        _dt(10, 27, 22),
        _dt(10, 28, 6),
        awake: [
          (_dt(10, 28, 2), _dt(10, 28, 2, 20)),
          (_dt(10, 28, 2, 10), _dt(10, 28, 2, 30)),
        ],
        deep: [
          (_dt(10, 28, 0), _dt(10, 28, 1)),
          (_dt(10, 28, 0, 30), _dt(10, 28, 1, 30)),
        ],
      );
      final old = _oldSingleSession(session);
      // Old arithmetic: 480 - merged awake 30 = 450; merged deep
      // 00:00-01:30 = 90.
      expect(old, (mins: 450, deep: 90));
      final out = summarizeSleepSessions([session]);
      expect(out, [(date: '2026-10-28', mins: old.mins, deep: old.deep)]);
    });

    test('entries are sorted ascending by date', () {
      final out = summarizeSleepSessions([
        _session('2026-10-28', _dt(10, 27, 23), _dt(10, 28, 6)),
        _session('2026-10-27', _dt(10, 26, 23), _dt(10, 27, 6)),
      ]);
      expect(out.map((e) => e.date), ['2026-10-27', '2026-10-28']);
    });

    test('f. awake covering the whole session -> raw 0 returned, '
        'and the store treats 0 as absent', () async {
      final out = summarizeSleepSessions([
        _session('2026-10-28', _dt(10, 27, 23), _dt(10, 28, 6),
            awake: [(_dt(10, 27, 23), _dt(10, 28, 6))]),
      ]);
      // Raw passthrough: the date IS emitted, with a 0 total.
      expect(out, [(date: '2026-10-28', mins: 0, deep: 0)]);

      final mem = <String, String>{};
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      store.debugReset();
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-10-28', sleepMinutes: 0),
      ]);
      final all = await store.readAll();
      // Founder zero rule: 0 is a failed read, never stored.
      expect(all['2026-10-28']?.sleepMinutes, isNull);
    });

    test('i. sub-minute pieces total in ms and convert once: '
        'two 30-second pieces sum to 1 minute, not 0', () {
      final out = summarizeSleepSessions([
        _session(
            '2026-10-28',
            DateTime(2026, 10, 28, 1, 0, 0),
            DateTime(2026, 10, 28, 1, 0, 30)),
        _session(
            '2026-10-28',
            DateTime(2026, 10, 28, 3, 0, 0),
            DateTime(2026, 10, 28, 3, 0, 30)),
      ]);
      // Each piece alone is 0 whole minutes; totalled in ms
      // (30000 + 30000) and converted once they are 1 minute.
      expect(out, [(date: '2026-10-28', mins: 1, deep: 0)]);
    });

    test('j. exact-touch intervals merge into one continuous '
        'interval (start == previous end)', () {
      final out = summarizeSleepSessions([
        _session('2026-10-28', _dt(10, 27, 23), _dt(10, 28, 1)),
        _session('2026-10-28', _dt(10, 28, 1), _dt(10, 28, 6)),
      ]);
      // 23:00-01:00 (120) touching 01:00-06:00 (300) at exactly
      // 01:00: one continuous 420-minute interval — no gap and
      // no double count at the touch point.
      expect(out, [(date: '2026-10-28', mins: 420, deep: 0)]);
    });
  });

  group('readSleepHistory channel parse', () {
    HealthConnectService serviceWith(
        Future<dynamic> Function(MethodCall call) handler) {
      final channel = MethodChannel(HealthConnectService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      return HealthConnectService(channel: channel, store: _MemStore());
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(HealthConnectService.channelName), null);
    });

    test('g. bare list of sessions -> unioned totals; '
        'malformed entries skipped', () async {
      final svc = serviceWith((call) async {
        expect(call.method, 'readSleepHistory');
        return <Object>[
          _sessionMap('2026-10-28', _dt(10, 27, 23), _dt(10, 28, 1),
              deep: [(_dt(10, 28, 0), _dt(10, 28, 0, 30))]),
          _sessionMap('2026-10-28', _dt(10, 28, 3), _dt(10, 28, 7),
              deep: [(_dt(10, 28, 4), _dt(10, 28, 4, 30))]),
          // Malformed entries: skipped, never thrown.
          <String, Object>{'date': '2026-10-28'},
          <String, Object>{'startMs': 1, 'endMs': 2},
          'not a map',
        ];
      });
      final out = await svc.readSleepHistory(7);
      expect(out, [(date: '2026-10-28', mins: 360, deep: 60)]);
    });

    test('g. {items, partialError} shape -> totals + '
        'lastPartialErrorCode SLEEP_HISTORY_PARTIAL', () async {
      final svc = serviceWith((call) async {
        return <String, Object>{
          'items': <Object>[
            _sessionMap('2026-10-28', _dt(10, 27, 22), _dt(10, 28, 6),
                awake: [(_dt(10, 28, 1), _dt(10, 28, 2))]),
          ],
          'partialError': 'a chunk failed',
        };
      });
      final out = await svc.readSleepHistory(7);
      // 480 - 60 awake = 420.
      expect(out, [(date: '2026-10-28', mins: 420, deep: 0)]);
      expect(svc.lastPartialErrorCode, 'SLEEP_HISTORY_PARTIAL');
    });
  });

  group('Sleep Need materiality', () {
    test('h. summed bouts vs legacy main-bout-only over 28 nights', () {
      String ds(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

      // 28 nights: 2026-09-29 .. 2026-10-26.
      final start = DateTime(2026, 9, 29);
      final dates = [
        for (var i = 0; i < 28; i++) ds(start.add(Duration(days: i))),
      ];
      expect(dates.first, '2026-09-29');
      expect(dates.last, '2026-10-26');

      // Legacy (main-bout-only): every night 420 minutes.
      final legacy = <String, int>{for (final d in dates) d: 420};

      // Summed: the same nights, with 8 of them split — the extra
      // bout adds 40-100 minutes to each split night.
      final summed = Map<String, int>.from(legacy);
      const splitIdx = [2, 5, 9, 13, 17, 21, 24, 27];
      const extras = [40, 50, 60, 70, 80, 90, 100, 60];
      for (var i = 0; i < splitIdx.length; i++) {
        summed[dates[splitIdx[i]]] =
            summed[dates[splitIdx[i]]]! + extras[i];
      }

      final legacyEst = estimateSleepNeed(legacy)!;
      final summedEst = estimateSleepNeed(summed)!;
      final delta =
          summedEst.baseNeedMinutes - legacyEst.baseNeedMinutes;
      // Evidence for the coordinator's report — exact numbers:
      // legacy baseNeed = 420, summed baseNeed = 460, delta = 40.
      // (75th percentile, nearest-rank over 28 nights: rank 21.
      // Legacy's sorted nights are all 420; summed has 20 nights at
      // 420 and the 21st is the smallest split night, 420 + 40.)
      expect(legacyEst.baseNeedMinutes, 420);
      expect(summedEst.baseNeedMinutes, 460);
      expect(summedEst.baseNeedMinutes,
          greaterThanOrEqualTo(legacyEst.baseNeedMinutes));
      expect(delta, 40);
    });
  });
}
