import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';

/// Sleep-totals rule upgrade (Oct 28, 2026 sleep-bouts change).
///
/// Stored per-night sleep totals were computed by the OLD rule
/// (single best bout). The bridge/app change unions all bouts,
/// but routine captures only re-read a gap-aware window
/// (min 31 days, sleep cap 90), so stale single-bout totals
/// inside Health Connect's window would persist indefinitely.
///
/// The upgrade path pinned here:
/// - [HealthHistoryStore] persists a sleep-totals rule version;
///   version 1 is implicit for blobs written before the key
///   existed, [HealthHistoryStore.currentSleepTotalsRuleVersion]
///   (2) is the unioned-bouts rule;
/// - while the stored version is stale, a capture re-reads the
///   FULL 90-day sleep window (other windows stay gap-aware);
/// - the version stamps to current only when that sleep read
///   completes cleanly — a failed OR partial sleep read leaves
///   it stale so the next capture retries the full window.

HealthHistoryStore _storeFor(Map<String, String> disk) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  return store;
}

/// Recording fake HC: notes the requested window per metric and
/// returns empty lists. The sleep leg can be made to fail or
/// return partial exactly as the real service reports it — the
/// fake sets `lastReadErrorCode` / `lastPartialErrorCode` on
/// ITSELF during the sleep read, and the sync reads those fields
/// off the instance after the read.
class _RecordingHc extends HealthConnectService {
  final Map<String, int> windows = {};

  String? sleepErrorCode;
  String? sleepPartialCode;

  /// Sleep rows the fake re-read returns (empty by default, as
  /// before). Set to pin what a forced capture does with ACTUAL
  /// returned totals.
  List<({String date, int mins, int deep})> sleepRows = const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async {
    windows['restingHr'] = days;
    return const [];
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    windows['sleep'] = days;
    if (sleepErrorCode != null) lastReadErrorCode = sleepErrorCode;
    if (sleepPartialCode != null) {
      lastPartialErrorCode = sleepPartialCode;
    }
    return sleepRows;
  }

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(int days) async {
    windows['hrv'] = days;
    return const [];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async {
    windows['calories'] = days;
    return const [];
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async {
    windows['spikes'] = days;
    return const [];
  }
}

final _now = DateTime.utc(2026, 10, 21, 12);
const _dayMs = 86400000;

/// Seeds a routine-capture store: one stored day and a
/// last-capture stamp 2 days before [_now], so a routine
/// (gap-aware) capture would read the 31-day floor
/// (ceil(2) + 2 = 4, clamped up to 31). When [stampCurrent] is
/// set the store is pre-stamped to the current sleep-totals
/// rule version.
Future<HealthHistoryStore> _seededStore(
  Map<String, String> disk, {
  bool stampCurrent = false,
}) async {
  final store = _storeFor(disk);
  await store.mergeRefresh(const [
    DailyBiometrics(
      date: '2026-10-10',
      restingHrBpm: 58,
      sleepMinutes: 432,
      deepSleepMinutes: 88,
      caloriesKcal: 2100,
    ),
  ]);
  await store.markCaptured(_now.millisecondsSinceEpoch - 2 * _dayMs);
  if (stampCurrent) {
    await store.markSleepTotalsRuleVersion(
        HealthHistoryStore.currentSleepTotalsRuleVersion);
  }
  return store;
}

Future<bool> _runCapture(HealthHistoryStore store, _RecordingHc hc) {
  final sync = HealthHistorySync.withDeps(
    hc: hc,
    store: store,
    now: () => _now,
  );
  return sync.captureFromHealthConnect(force: true);
}

void main() {
  setUp(() {
    HealthHistorySync.debugResetFlight();
  });
  tearDown(() {
    HealthHistorySync.debugResetFlight();
  });

  group('store — sleep-totals rule version persistence', () {
    test('blob WITHOUT the key warms to version 1 (implicit legacy)',
        () async {
      final disk = <String, String>{
        HealthHistoryStore.storageKey: jsonEncode({
          'ownerEmail': null,
          'lastCaptureMs': null,
          'days': {
            '2026-10-10': {
              'date': '2026-10-10',
              'sleepMinutes': 432,
            },
          },
        }),
      };
      final store = _storeFor(disk);
      await store.warmFromDisk();
      expect(store.sleepTotalsRuleVersion, 1);
      expect(
          HealthHistoryStore.currentSleepTotalsRuleVersion, 2);
    });

    test('markSleepTotalsRuleVersion(2) persists across a re-warm',
        () async {
      final disk = <String, String>{};
      final store = _storeFor(disk);
      await store.warmFromDisk();
      expect(store.sleepTotalsRuleVersion, 1);

      await store.markSleepTotalsRuleVersion(2);
      expect(store.sleepTotalsRuleVersion, 2);

      // A second instance over the same disk sees the stamp.
      final rewarm = _storeFor(disk);
      await rewarm.warmFromDisk();
      expect(rewarm.sleepTotalsRuleVersion, 2);
    });

    test('markSleepTotalsRuleVersion never moves backward', () async {
      final disk = <String, String>{};
      final store = _storeFor(disk);
      await store.markSleepTotalsRuleVersion(2);
      expect(store.sleepTotalsRuleVersion, 2);

      await store.markSleepTotalsRuleVersion(1);
      expect(store.sleepTotalsRuleVersion, 2);
      await store.markSleepTotalsRuleVersion(2);
      expect(store.sleepTotalsRuleVersion, 2);

      final rewarm = _storeFor(disk);
      await rewarm.warmFromDisk();
      expect(rewarm.sleepTotalsRuleVersion, 2);
    });
  });

  group('sync — sleep-totals upgrade capture', () {
    test('stale version: sleep window is the full 90 while other '
        'windows stay gap-aware, and a clean read stamps version 2',
        () async {
      final disk = <String, String>{};
      final store = await _seededStore(disk);
      expect(store.sleepTotalsRuleVersion, 1);
      final hc = _RecordingHc();

      expect(await _runCapture(store, hc), isTrue);

      // Routine gap is 2 days → gap-aware floor is 31; sleep
      // alone is forced to the full 90 by the pending upgrade.
      expect(hc.windows['sleep'], 90);
      expect(hc.windows['restingHr'], 31);
      expect(hc.windows['calories'], 31);
      expect(store.sleepTotalsRuleVersion, 2);

      // The stamp persisted, not just in memory.
      final rewarm = _storeFor(disk);
      await rewarm.warmFromDisk();
      expect(rewarm.sleepTotalsRuleVersion, 2);
    });

    test('failed sleep read: version stays 1; the next clean '
        'capture retries the full window and stamps', () async {
      final disk = <String, String>{};
      final store = await _seededStore(disk);
      final hc = _RecordingHc()
        ..sleepErrorCode = 'SLEEP_HISTORY_READ_FAILED';

      expect(await _runCapture(store, hc), isTrue);
      expect(hc.windows['sleep'], 90);
      expect(store.sleepTotalsRuleVersion, 1);

      // The fake now reads cleanly: the retry still uses the
      // full window (the version is still stale) and stamps.
      hc.sleepErrorCode = null;
      hc.windows.clear();
      expect(await _runCapture(store, hc), isTrue);
      expect(hc.windows['sleep'], 90);
      expect(store.sleepTotalsRuleVersion, 2);
    });

    test('partial sleep read: version stays 1 (no stamp)', () async {
      final disk = <String, String>{};
      final store = await _seededStore(disk);
      final hc = _RecordingHc()
        ..sleepPartialCode = 'SLEEP_HISTORY_PARTIAL';

      expect(await _runCapture(store, hc), isTrue);
      expect(hc.windows['sleep'], 90);
      expect(hc.windows['restingHr'], 31);
      expect(store.sleepTotalsRuleVersion, 1);
    });

    test('forced re-read returning a CHANGED union total for an '
        'already-stored in-window date REPLACES the stored totals '
        'and stamps version 2 (C-1b)', () async {
      final disk = <String, String>{};
      // Seeded legacy night: 2026-10-10 at sleep 432 / deep 88,
      // store on rule version 1.
      final store = await _seededStore(disk);
      expect(store.sleepTotalsRuleVersion, 1);
      final before = (await store.readAll())['2026-10-10']!;
      expect(before.sleepMinutes, 432);
      expect(before.deepSleepMinutes, 88);

      // The forced full-window re-read returns a DIFFERENT union
      // total for that same date.
      final hc = _RecordingHc()
        ..sleepRows = const [
          (date: '2026-10-10', mins: 512, deep: 101),
        ];

      expect(await _runCapture(store, hc), isTrue);
      expect(hc.windows['sleep'], 90);

      // mergeRefresh replacement, not gap-fill: the stored row
      // now holds the new union totals, and unrelated fields on
      // the row are untouched.
      final after = (await store.readAll())['2026-10-10']!;
      expect(after.sleepMinutes, 512);
      expect(after.deepSleepMinutes, 101);
      expect(after.restingHrBpm, 58);
      expect(after.caloriesKcal, 2100);
      expect(store.sleepTotalsRuleVersion, 2);
    });

    test('forced re-read returning NO row for a stored in-window '
        'date keeps its legacy total and still stamps version 2 '
        '(C-1a disclosed case: sessions deleted at the source)',
        () async {
      final disk = <String, String>{};
      final store = await _seededStore(disk);
      expect(store.sleepTotalsRuleVersion, 1);
      // Default fake returns zero sleep rows: the stored night
      // is absent from the re-read (e.g. deleted in Health
      // Connect), so the merge never touches it.
      final hc = _RecordingHc();

      expect(await _runCapture(store, hc), isTrue);
      expect(hc.windows['sleep'], 90);

      final after = (await store.readAll())['2026-10-10']!;
      expect(after.sleepMinutes, 432);
      expect(after.deepSleepMinutes, 88);
      expect(store.sleepTotalsRuleVersion, 2);
    });

    test('current version: routine capture keeps the gap-aware '
        'sleep window (31)', () async {
      final disk = <String, String>{};
      final store = await _seededStore(disk, stampCurrent: true);
      expect(store.sleepTotalsRuleVersion,
          HealthHistoryStore.currentSleepTotalsRuleVersion);
      final hc = _RecordingHc();

      expect(await _runCapture(store, hc), isTrue);

      expect(hc.windows['sleep'], 31);
      expect(hc.windows['restingHr'], 31);
      expect(store.sleepTotalsRuleVersion, 2);
    });
  });
}
