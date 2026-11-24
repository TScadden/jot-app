import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/widgets/user_avatar.dart';

/// Perf-lag fixes (Nov 23, 2026) — three fixes, one package:
///
/// F1. App-open capture min-interval: `captureOnAppOpen` keeps
///     bypassing the 6h throttle, but a last-successful stamp
///     younger than `HealthHistorySync.appOpenMinInterval`
///     (30 min) now skips the run.
/// F2. Spike counts: the Dart service parses the native
///     per-chunk partial envelope (`{items, partialError}` →
///     `SPIKE_COUNTS_PARTIAL`), and the spike backfill flag
///     sets on a clean OR partial full-180-day walk — only an
///     error blocks it. (The native chunk isolation itself is
///     Kotlin; the plugin has no Kotlin test harness — see the
///     package report.)
/// F3. Avatar decode sizing: `UserAvatar` (and the Settings
///     picker, covered in avatar_picker_test patterns via the
///     shared `avatarDecodeExtent`) decodes at
///     `ceil(size * 3)`, not the full 480×480.

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

HealthHistoryStore _fakeStore() {
  final fake = _FakeStore();
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

final _now = DateTime(2026, 11, 23, 17, 30);

/// Seeds a non-empty store stamped [age] ago against [_now];
/// a null [age] leaves the store unstamped (no capture yet).
Future<HealthHistoryStore> _seededStore({Duration? age}) async {
  final store = _fakeStore();
  await store.mergeRefresh([
    const DailyBiometrics(
      date: '2026-11-22',
      sleepMinutes: 480,
      restingHrBpm: 60,
    ),
  ]);
  if (age != null) {
    await store.markCaptured(_now.millisecondsSinceEpoch - age.inMilliseconds);
  }
  return store;
}

/// Instant HC fake; resting-HR reads are counted — one capture
/// run performs exactly one, so the count is the run count.
/// The spike leg's outcome is staged directly through its
/// outcome variant (the report-collect fakes' pattern).
class _CountingHc extends HealthConnectService {
  int restingHrCalls = 0;
  final List<int> spikeWindows = [];
  String? spikeErrorCode;
  String? spikePartialCode;
  List<({String date, int count})> spikeRows = const [];

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async {
    restingHrCalls++;
    return const [];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
    int days,
  ) async => const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(int days) async =>
      const [];

  @override
  Future<HcReadOutcome<List<({String date, int count})>>>
  readSpikeCountsWithOutcome(int days) async {
    spikeWindows.add(days);
    return HcReadOutcome(
      value: spikeRows,
      errorCode: spikeErrorCode,
      partialCode: spikePartialCode,
    );
  }
}

class _MemorySecureStore implements SecureStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HealthHistorySync.debugResetFlight();
  });
  tearDown(() {
    HealthHistorySync.debugResetFlight();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(HealthConnectService.channelName),
          null,
        );
  });

  group('F1 — app-open min-interval gate (pure decision)', () {
    final nowMs = _now.millisecondsSinceEpoch;
    int stampAgo(Duration age) => nowMs - age.inMilliseconds;

    test('(a) app-open within the floor → skip', () {
      expect(HealthHistorySync.appOpenMinInterval, const Duration(minutes: 30));
      expect(
        HealthHistorySync.shouldSkipAppOpenCapture(
          nowMs: nowMs,
          lastCaptureMs: stampAgo(const Duration(minutes: 10)),
          isFirst: false,
        ),
        isTrue,
      );
      expect(
        HealthHistorySync.shouldSkipAppOpenCapture(
          nowMs: nowMs,
          lastCaptureMs: stampAgo(Duration.zero),
          isFirst: false,
        ),
        isTrue,
      );
    });

    test('(b) app-open after the floor → run', () {
      expect(
        HealthHistorySync.shouldSkipAppOpenCapture(
          nowMs: nowMs,
          lastCaptureMs: stampAgo(const Duration(minutes: 30)),
          isFirst: false,
        ),
        isFalse,
        reason: 'exactly at the floor is no longer younger than it',
      );
      expect(
        HealthHistorySync.shouldSkipAppOpenCapture(
          nowMs: nowMs,
          lastCaptureMs: stampAgo(const Duration(hours: 2)),
          isFirst: false,
        ),
        isFalse,
      );
    });

    test('(c) first capture (no stamp / empty store) → run', () {
      expect(
        HealthHistorySync.shouldSkipAppOpenCapture(
          nowMs: nowMs,
          lastCaptureMs: null,
          isFirst: false,
        ),
        isFalse,
      );
      expect(
        HealthHistorySync.shouldSkipAppOpenCapture(
          nowMs: nowMs,
          lastCaptureMs: stampAgo(const Duration(minutes: 5)),
          isFirst: true,
        ),
        isFalse,
      );
    });
  });

  group('F1 — app-open min-interval gate (capture integration)', () {
    HealthHistorySync syncFor(_CountingHc hc, HealthHistoryStore store) =>
        HealthHistorySync.withDeps(hc: hc, store: store, now: () => _now);

    test('(a) app-open within floor → no capture', () async {
      final store = await _seededStore(age: const Duration(minutes: 10));
      final hc = _CountingHc();
      expect(await syncFor(hc, store).captureOnAppOpen(), isFalse);
      expect(hc.restingHrCalls, 0);
    });

    test('(b) app-open after floor → capture (still inside 6h)', () async {
      final store = await _seededStore(age: const Duration(hours: 1));
      final hc = _CountingHc();
      expect(await syncFor(hc, store).captureOnAppOpen(), isTrue);
      expect(hc.restingHrCalls, 1);
    });

    test('(c) first capture (no stamp) → capture', () async {
      final store = await _seededStore(age: null);
      final hc = _CountingHc();
      expect(await syncFor(hc, store).captureOnAppOpen(), isTrue);
      expect(hc.restingHrCalls, 1);
    });

    test('(d) plain capture still 6h-throttled after the floor', () async {
      final store = await _seededStore(age: const Duration(hours: 1));
      final hc = _CountingHc();
      final sync = syncFor(hc, store);
      // 1h is past the app-open floor but inside the plain 6h
      // throttle: the plain path must still skip.
      expect(await sync.capture(), isFalse);
      expect(hc.restingHrCalls, 0);
      // And past 6h the plain path runs again.
      final oldStore = await _seededStore(age: const Duration(hours: 7));
      expect(await syncFor(hc, oldStore).capture(), isTrue);
      expect(hc.restingHrCalls, 1);
    });

    test('(e) force still bypasses both gates with a fresh stamp', () async {
      final store = await _seededStore(age: Duration.zero);
      final hc = _CountingHc();
      final sync = syncFor(hc, store);
      expect(await sync.capture(force: true), isTrue);
      expect(hc.restingHrCalls, 1);
      // A direct forced captureFromHealthConnect also runs.
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.restingHrCalls, 2);
    });
  });

  group('F2 — spike backfill flag decision (pure)', () {
    test('clean → set', () {
      expect(
        HealthHistorySync.spikeBackfillShouldComplete(
          errorCode: null,
          partialCode: null,
          windowDays: 180,
        ),
        isTrue,
      );
    });

    test('partial → set', () {
      expect(
        HealthHistorySync.spikeBackfillShouldComplete(
          errorCode: null,
          partialCode: 'SPIKE_COUNTS_PARTIAL',
          windowDays: 180,
        ),
        isTrue,
      );
    });

    test('error → not set', () {
      expect(
        HealthHistorySync.spikeBackfillShouldComplete(
          errorCode: 'SPIKE_COUNTS_READ_FAILED',
          partialCode: null,
          windowDays: 180,
        ),
        isFalse,
      );
      expect(
        HealthHistorySync.spikeBackfillShouldComplete(
          errorCode: 'READ_TIMEOUT',
          partialCode: null,
          windowDays: 180,
        ),
        isFalse,
      );
    });

    test('a routine 31-day walk never sets it', () {
      expect(
        HealthHistorySync.spikeBackfillShouldComplete(
          errorCode: null,
          partialCode: null,
          windowDays: 31,
        ),
        isFalse,
      );
    });
  });

  group('F2 — spike backfill flag (capture integration)', () {
    Future<({_CountingHc hc, HealthHistoryStore store})> capture(
      _CountingHc hc,
    ) async {
      final store = _fakeStore();
      final sync = HealthHistorySync.withDeps(
        hc: hc,
        store: store,
        now: () => _now,
      );
      await sync.captureFromHealthConnect(force: true);
      return (hc: hc, store: store);
    }

    test('clean full-window walk sets the flag; next window is 31', () async {
      final hc = _CountingHc();
      final r = await capture(hc);
      expect(r.hc.spikeWindows, [180]);
      expect(r.store.spikeBackfillComplete, isTrue);
      final sync = HealthHistorySync.withDeps(
        hc: hc,
        store: r.store,
        now: () => _now,
      );
      await sync.captureFromHealthConnect(force: true);
      expect(hc.spikeWindows, [180, 31]);
    });

    test('partial full-window walk sets the flag and keeps the '
        'counts that did read', () async {
      final hc = _CountingHc()
        ..spikePartialCode = 'SPIKE_COUNTS_PARTIAL'
        ..spikeRows = const [(date: '2026-11-20', count: 2)];
      final r = await capture(hc);
      expect(r.hc.spikeWindows, [180]);
      expect(
        r.store.spikeBackfillComplete,
        isTrue,
        reason: 'a partial walk no longer blocks the flag',
      );
      final days = await r.store.readAll();
      expect(days['2026-11-20']?.spikeCount, 2);
    });

    test('errored walk does NOT set the flag; next capture '
        're-walks 180', () async {
      final hc = _CountingHc()..spikeErrorCode = 'SPIKE_COUNTS_READ_FAILED';
      final r = await capture(hc);
      expect(r.store.spikeBackfillComplete, isFalse);
      hc.spikeErrorCode = null;
      final sync = HealthHistorySync.withDeps(
        hc: hc,
        store: r.store,
        now: () => _now,
      );
      await sync.captureFromHealthConnect(force: true);
      expect(hc.spikeWindows, [180, 180]);
      expect(r.store.spikeBackfillComplete, isTrue);
    });
  });

  group('F2 — spike counts partial-envelope parsing (Dart service)', () {
    HealthConnectService serviceReturning(dynamic response, {Object? error}) {
      const channel = MethodChannel(HealthConnectService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'readSpikeCounts') return null;
            if (error != null) throw error;
            return response;
          });
      return HealthConnectService(
        channel: channel,
        store: _MemorySecureStore(),
      );
    }

    test('clean bare list parses identically (0 kept, no partial)', () async {
      final service = serviceReturning([
        {'date': '2026-11-20', 'count': 3},
        {'date': '2026-11-21', 'count': 0},
      ]);
      final outcome = await service.readSpikeCountsWithOutcome(2);
      expect(outcome.errorCode, isNull);
      expect(outcome.partialCode, isNull);
      expect(outcome.value, hasLength(2));
      expect(outcome.value.last.count, 0);
    });

    test('{items, partialError} → values kept, partial code set, '
        'no error', () async {
      final service = serviceReturning({
        'items': [
          {'date': '2026-11-20', 'count': 3},
        ],
        'partialError': 'java.lang.SecurityException: chunk',
      });
      final outcome = await service.readSpikeCountsWithOutcome(180);
      expect(outcome.errorCode, isNull);
      expect(outcome.partialCode, 'SPIKE_COUNTS_PARTIAL');
      expect(outcome.value, hasLength(1));
      expect(outcome.value.single.count, 3);
      expect(service.lastPartialErrorCode, 'SPIKE_COUNTS_PARTIAL');
      // The legacy value-only method returns the same counts.
      expect(await service.readSpikeCounts(180), hasLength(1));
    });

    test('a platform error still errors the read (total failure)', () async {
      final service = serviceReturning(
        null,
        error: PlatformException(
          code: 'SPIKE_COUNTS_READ_FAILED',
          message: 'Could not read heart rate spikes.',
        ),
      );
      final outcome = await service.readSpikeCountsWithOutcome(180);
      expect(outcome.errorCode, 'SPIKE_COUNTS_READ_FAILED');
      expect(outcome.partialCode, isNull);
      expect(outcome.value, isEmpty);
    });
  });

  group('F3 — avatar decode sizing', () {
    test('avatarDecodeExtent is ceil(size * 3), clamped to '
        '[1, 480] (the source size)', () {
      expect(avatarDecodeExtent(40), 120);
      expect(avatarDecodeExtent(72), 216);
      expect(avatarDecodeExtent(40.5), 122); // ceil(121.5)
      expect(avatarDecodeExtent(0), 1);
      expect(avatarDecodeExtent(1000), 480);
    });

    testWidgets('UserAvatar image provider is a ResizeImage bound '
        'at ceil(size * 3) over the catalog asset', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UserAvatar(
              avatarId: 'avatar_07',
              size: 40,
              fallback: Text('FALLBACK'),
            ),
          ),
        ),
      );
      await tester.pump();
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<ResizeImage>());
      final resize = image.image as ResizeImage;
      expect(resize.width, 120);
      expect(resize.height, 120);
      expect(
        (resize.imageProvider as AssetImage).assetName,
        'assets/images/avatar_07.png',
      );
      // Display geometry is unchanged.
      expect(image.width, 40);
      expect(image.height, 40);
      expect(image.fit, BoxFit.cover);
    });

    testWidgets('a larger UserAvatar scales the bound with size', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UserAvatar(
              avatarId: 'avatar_01',
              size: 72,
              fallback: Text('FALLBACK'),
            ),
          ),
        ),
      );
      await tester.pump();
      final resize =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect(resize.width, 216);
      expect(resize.height, 216);
    });
  });
}
