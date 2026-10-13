import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';

/// Round 52 — Dart-side audit scaffolding for the Round 50 home-screen
/// widget defect (widget renders as an empty black bar / launcher
/// "Fix" state on the founder's Pixel).
///
/// The Round 50 suite (`widget_sync_r50_test.dart`) already covers the
/// buildPayload mapping cell-by-cell and ONE signed-in push + ONE
/// clear at the WidgetSync level. This file adds only the gaps:
///
/// (a) Trigger accounting: every push/clear PATH that production code
///     can take must request exactly one widget update per call —
///     including the caller-level paths through [HomeDataCache]
///     (persist / clear / owner-mismatch), which no test covered
///     before, and the persist() no-load gate, which is the pinned
///     reason a placed widget can sit orphaned (see below).
/// (b) The provider face-selection contract as a PAYLOAD matrix,
///     exercised through the fake bridge (what actually lands in the
///     widget store), not just the pure mapper:
///       no prefs at all      → native default (flag absent reads
///                              false) ≡ the signed-out payload below
///       signed-out           → flag false + every cell "--"
///       signed in, missing   → "--" per missing biometric cell
///       signed in, values    → the values
///     ONE deliberate exception, pinned here so it is a decision and
///     not a surprise: the logs cell is a real count, so a signed-in
///     snapshot with no vitals section yet saves logs "0", not "--"
///     (strip parity: `v?.logCountToday ?? 0`).
///
/// Characterization tests (marked as such) pin CURRENT failure
/// semantics of the silent side-channel so a future observability /
/// atomicity fix flips them deliberately, not accidentally.
class _FakeBridge {
  final Map<String, Object?> saved = {};
  final List<String> saveAttempts = [];
  var updateAttempts = 0;

  /// When set, saving this key throws (simulates a channel failure
  /// mid-sequence).
  String? failOnSaveKey;

  /// When true, the update request itself throws (simulates the
  /// plugin's PlatformException, e.g. code "-3" provider not found).
  var failUpdate = false;

  Future<void> save(String key, Object? value) async {
    saveAttempts.add(key);
    if (key == failOnSaveKey) throw StateError('bridge down at $key');
    saved[key] = value;
  }

  Future<void> update() async {
    updateAttempts++;
    if (failUpdate) throw StateError('update failed');
  }

  void install() =>
      WidgetSync.debugSetBridge(save: save, update: update);

  void reset() {
    saved.clear();
    saveAttempts.clear();
    updateAttempts = 0;
    failOnSaveKey = null;
    failUpdate = false;
  }
}

HomeCacheSnapshot _snap({
  TodayVitals? vitals,
  bool vitalsLoaded = true,
  int? currentStreak,
  bool streakLoaded = true,
}) {
  return HomeCacheSnapshot(
    vitals: vitals,
    vitalsLoaded: vitalsLoaded,
    currentStreak: currentStreak,
    bestStreak: null,
    streakLoaded: streakLoaded,
  );
}

const _signedOutMap = <String, Object?>{
  WidgetSync.keySignedIn: false,
  WidgetSync.keyHeartRate: '--',
  WidgetSync.keyStreak: '--',
  WidgetSync.keyLogs: '--',
  WidgetSync.keySleep: '--',
};

void main() {
  final bridge = _FakeBridge();

  setUp(() {
    bridge.reset();
    bridge.install();
  });

  tearDown(WidgetSync.debugResetBridge);

  group('R52 (b) face-selection payload matrix via the bridge', () {
    test('signed-out push (even with a full snapshot) writes the '
        'signed-out payload and exactly one update', () async {
      await WidgetSync.pushSnapshot(
        _snap(
          vitals: const TodayVitals(
            heartRate: 72,
            sleepMinutes: 482,
            logCountToday: 3,
          ),
          currentStreak: 12,
        ),
        signedIn: false,
      );
      expect(bridge.saved, _signedOutMap);
      expect(bridge.updateAttempts, 1);
    });

    test('signed in, no vitals section and no streak → "--" per '
        'biometric cell, logs "0" (real count, strip parity)',
        () async {
      await WidgetSync.pushSnapshot(
        _snap(vitals: null, vitalsLoaded: false, currentStreak: null),
        signedIn: true,
      );
      expect(bridge.saved, const <String, Object?>{
        WidgetSync.keySignedIn: true,
        WidgetSync.keyHeartRate: '--',
        WidgetSync.keyStreak: '--',
        WidgetSync.keyLogs: '0',
        WidgetSync.keySleep: '--',
      });
      expect(bridge.updateAttempts, 1);
    });

    test('signed in, vitals present but every field missing → same '
        '"--" payload as no vitals section', () async {
      await WidgetSync.pushSnapshot(
        _snap(vitals: const TodayVitals(), currentStreak: null),
        signedIn: true,
      );
      expect(bridge.saved[WidgetSync.keySignedIn], isTrue);
      expect(bridge.saved[WidgetSync.keyHeartRate], '--');
      expect(bridge.saved[WidgetSync.keyStreak], '--');
      expect(bridge.saved[WidgetSync.keySleep], '--');
      expect(bridge.updateAttempts, 1);
    });

    test('signed in, partial values → present cells carry values, '
        'missing cells stay "--"', () async {
      await WidgetSync.pushSnapshot(
        _snap(
          vitals: const TodayVitals(heartRate: 65, logCountToday: 2),
          currentStreak: null,
        ),
        signedIn: true,
      );
      expect(bridge.saved[WidgetSync.keyHeartRate], '65');
      expect(bridge.saved[WidgetSync.keySleep], '--');
      expect(bridge.saved[WidgetSync.keyStreak], '--');
      expect(bridge.saved[WidgetSync.keyLogs], '2');
      expect(bridge.updateAttempts, 1);
    });

    test('buildPayload matrix: the full face-selection table, '
        'including failed-read zeros', () {
      final cases = <(String, HomeCacheSnapshot, bool, WidgetPayload)>[
        (
          'no data at all, signed out → signed-out payload',
          _snap(vitals: null, vitalsLoaded: false, currentStreak: null),
          false,
          const WidgetPayload.signedOut(),
        ),
        (
          'full data, signed out → signed-out payload (no leak)',
          _snap(
            vitals: const TodayVitals(
              heartRate: 72,
              sleepMinutes: 482,
              logCountToday: 3,
            ),
            currentStreak: 12,
          ),
          false,
          const WidgetPayload.signedOut(),
        ),
        (
          'signed in, empty snapshot → "--" cells, logs "0"',
          _snap(vitals: null, vitalsLoaded: false, currentStreak: null),
          true,
          const WidgetPayload(
            signedIn: true,
            heartRate: '--',
            streak: '--',
            logs: '0',
            sleep: '--',
          ),
        ),
        (
          'signed in, failed reads (HR 0 / sleep 0) → "--"; honest '
              'zeros (streak 0 / logs 0) stay "0"',
          _snap(
            vitals: const TodayVitals(
              heartRate: 0,
              sleepMinutes: 0,
              logCountToday: 0,
            ),
            currentStreak: 0,
          ),
          true,
          const WidgetPayload(
            signedIn: true,
            heartRate: '--',
            streak: '0',
            logs: '0',
            sleep: '--',
          ),
        ),
        (
          'signed in, sleep only → sleep formatted, rest "--"',
          _snap(vitals: const TodayVitals(sleepMinutes: 426)),
          true,
          const WidgetPayload(
            signedIn: true,
            heartRate: '--',
            streak: '--',
            logs: '0',
            sleep: '7h6m',
          ),
        ),
      ];
      for (final (name, snap, signedIn, expected) in cases) {
        final payload = WidgetSync.buildPayload(snap, signedIn: signedIn);
        expect(payload, expected, reason: name);
        expect(payload.toMap(), expected.toMap(), reason: name);
      }
    });
  });

  group('R52 (a) trigger accounting at the WidgetSync level', () {
    test('every push saves exactly the 5 native keys, in order, '
        'flag as bool and cells as String, then one update',
        () async {
      await WidgetSync.pushSnapshot(
        _snap(
          vitals: const TodayVitals(heartRate: 70, logCountToday: 1),
          currentStreak: 4,
        ),
        signedIn: true,
      );
      expect(bridge.saveAttempts, const [
        WidgetSync.keySignedIn,
        WidgetSync.keyHeartRate,
        WidgetSync.keyStreak,
        WidgetSync.keyLogs,
        WidgetSync.keySleep,
      ]);
      // The native provider reads the flag with getBoolean and the
      // cells with getString — the type split is part of the
      // contract (a String "true" would read back as a type error /
      // default on the Kotlin side).
      expect(bridge.saved[WidgetSync.keySignedIn], isA<bool>());
      for (final key in [
        WidgetSync.keyHeartRate,
        WidgetSync.keyStreak,
        WidgetSync.keyLogs,
        WidgetSync.keySleep,
      ]) {
        expect(bridge.saved[key], isA<String>(), reason: key);
      }
      expect(bridge.updateAttempts, 1);
    });

    test('clear on its own (no preceding push) writes the '
        'signed-out payload and requests exactly one update',
        () async {
      await WidgetSync.clear();
      expect(bridge.saved, _signedOutMap);
      expect(bridge.saveAttempts, hasLength(5));
      expect(bridge.updateAttempts, 1);
    });

    test('no coalescing: push + clear + push requests 3 updates',
        () async {
      final snap = _snap(
        vitals: const TodayVitals(heartRate: 70),
        currentStreak: 1,
      );
      await WidgetSync.pushSnapshot(snap, signedIn: true);
      await WidgetSync.clear();
      await WidgetSync.pushSnapshot(snap, signedIn: true);
      expect(bridge.updateAttempts, 3);
      expect(bridge.saveAttempts, hasLength(15));
    });
  });

  group('R52 failure semantics (characterization)', () {
    test('update request throws AFTER all saves land: saves stay, '
        'exactly one update was attempted, nothing escapes',
        () async {
      bridge.failUpdate = true;
      await expectLater(
        WidgetSync.pushSnapshot(
          _snap(
            vitals: const TodayVitals(heartRate: 70, logCountToday: 1),
            currentStreak: 4,
          ),
          signedIn: true,
        ),
        completes,
      );
      expect(bridge.saved[WidgetSync.keyHeartRate], '70');
      expect(bridge.updateAttempts, 1);
      await expectLater(WidgetSync.clear(), completes);
      expect(bridge.updateAttempts, 2);
    });

    test('a save failing mid-sequence skips the remaining saves '
        'AND the update request (partial payload, no refresh)',
        () async {
      bridge.failOnSaveKey = WidgetSync.keyStreak;
      await expectLater(
        WidgetSync.pushSnapshot(
          _snap(
            vitals: const TodayVitals(heartRate: 70, logCountToday: 1),
            currentStreak: 4,
          ),
          signedIn: true,
        ),
        completes,
      );
      expect(bridge.saveAttempts, const [
        WidgetSync.keySignedIn,
        WidgetSync.keyHeartRate,
        WidgetSync.keyStreak,
      ]);
      expect(bridge.saved.containsKey(WidgetSync.keyLogs), isFalse);
      expect(bridge.saved.containsKey(WidgetSync.keySleep), isFalse);
      // The widget is never told to redraw with the partial payload.
      expect(bridge.updateAttempts, 0);
    });
  });

  group('R52 (a) caller-level paths through HomeDataCache', () {
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

    tearDown(() {
      HomeDataCache.instance.debugReset();
    });

    test('persist() after a completed load pushes the snapshot '
        'with exactly one update', () async {
      final cache = HomeDataCache.instance;
      cache.applyVitals(const TodayVitals(
        heartRate: 70,
        sleepMinutes: 400,
        logCountToday: 1,
      ));
      cache.applyStreak(3, 9);
      await cache.persist();
      await pumpEventQueue();
      expect(bridge.saved, const <String, Object?>{
        WidgetSync.keySignedIn: true,
        WidgetSync.keyHeartRate: '70',
        WidgetSync.keyStreak: '3',
        WidgetSync.keyLogs: '1',
        WidgetSync.keySleep: '6h40m',
      });
      expect(bridge.updateAttempts, 1);
    });

    test('persist() with nothing ever loaded is a no-op: NO push, '
        'NO update (the orphan-widget gate)', () async {
      await HomeDataCache.instance.persist();
      await pumpEventQueue();
      expect(bridge.saveAttempts, isEmpty);
      expect(bridge.updateAttempts, 0);
    });

    test('HomeDataCache.clear() (logout / delete / session-expiry '
        'funnel) clears the widget with exactly one update',
        () async {
      final cache = HomeDataCache.instance;
      cache.applyVitals(const TodayVitals(heartRate: 70));
      await cache.clear();
      await pumpEventQueue();
      expect(bridge.saved, _signedOutMap);
      expect(bridge.updateAttempts, 1);
    });

    test('clearIfOwnerMismatch on a foreign-owned cache clears '
        'the widget exactly once; a matching owner does not',
        () async {
      final cache = HomeDataCache.instance;
      cache.applyVitals(
        const TodayVitals(heartRate: 70),
        ownerEmail: 'first@example.com',
      );
      // Same owner: no wipe, no widget update.
      expect(await cache.clearIfOwnerMismatch('first@example.com'),
          isFalse);
      await pumpEventQueue();
      expect(bridge.updateAttempts, 0);
      // Foreign owner: wipe → widget drops to signed-out, one update.
      expect(await cache.clearIfOwnerMismatch('second@example.com'),
          isTrue);
      await pumpEventQueue();
      expect(bridge.saved, _signedOutMap);
      expect(bridge.updateAttempts, 1);
    });
  });
}
