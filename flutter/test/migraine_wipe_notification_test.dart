import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';

/// Vera 4e follow-up (Oct 27, 2026) — wiping MigraineAttackStore
/// mid-attack must also cancel the migraine attack's persistent
/// tap-to-end notification (id 7303), or the orphan notification's
/// tap loads a wiped store.
///
/// Honest scope note: `_onSessionExpired` in main.dart is a private
/// State method and cannot be invoked from a test; its session-
/// expiry leg is exercised here via its shared cancel entry point
/// ([LocalMigraineNotifier.cancelPostedAttack] — the exact call
/// `_onSessionExpired` makes), mirroring how audit 4e tested the
/// expiry leg via `MigraineAttackStore.clear()`.

class FakeMigraineNotifier implements MigraineNotifier {
  int cancelCount = 0;
  bool throwOnCancel = false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> showAttack(int elapsedMin) async => true;

  @override
  Future<void> cancel() async {
    cancelCount++;
    if (throwOnCancel) {
      throw StateError('cancel failed');
    }
  }

  @override
  Future<bool> areNotificationsEnabled() async => true;

  @override
  Future<bool> launchMigrainePayload() async => false;
}

MigraineAttack attack({
  required int start,
  int? end,
  String meds = 'sumatriptan',
}) =>
    MigraineAttack(
      id: start,
      startTimestamp: start,
      endTimestamp: end,
      auraPhase: 'VISUAL',
      medsTaken: meds,
      painPeak: 8,
      reliefRating: 3,
      updatedAt: end ?? start,
    );

void main() {
  final disk = <String, String>{};
  final store = MigraineAttackStore.instance;

  void wireMigraine() {
    store.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
  }

  /// The AccountActions funnel clears every account-bound
  /// singleton; wire them all to in-memory IO (the
  /// migraine_store_wipe_test.dart pattern) so the real funnel
  /// completes against fakes.
  void wireFunnelCaches() {
    final cacheDisk = <String, String>{};
    void wire(dynamic cache) => cache.debugSetStore(
          read: (k) async => cacheDisk[k],
          write: (k, v) async => cacheDisk[k] = v,
          delete: (k) async => cacheDisk.remove(k),
        );
    wire(HomeDataCache.instance);
    wire(QuickLogCache.instance);
    wire(HeartDataCache.instance);
    wire(TodaySummaryCache.instance);
    wire(TodayPlanStore.instance);
    wire(CoachMemoryStore.instance);
    wire(KnowledgeExtractionStore.instance);
    wire(HealthHistoryStore.instance);
  }

  setUp(() async {
    disk.clear();
    wireMigraine();
    await store.clear(); // unbinds any owner a prior test bound
    disk.clear();
  });

  tearDown(() async {
    LocalMigraineNotifier.debugSetWipeNotifier(null);
    await store.clear();
  });

  group('migraine notification cancel on wipe paths (Vera 4e '
      'follow-up)', () {
    test('funnel: AccountActions wipe cancels the posted attack '
        'notification and wipes the active attack', () async {
      wireFunnelCaches();
      wireMigraine(); // funnel wiring must not disturb this store
      expect(await store.clearIfOwnerMismatch('a@example.com'),
          isFalse);
      await store.save(attack(start: 1760010000000)); // active
      expect(disk.containsKey(MigraineAttackStore.storageKey), isTrue);
      expect(await store.loadActive(), isNotNull);

      final fake = FakeMigraineNotifier();
      LocalMigraineNotifier.debugSetWipeNotifier(fake);

      await AccountActions.clearDefaultCaches();

      expect(disk.containsKey(MigraineAttackStore.storageKey), isFalse);
      expect(await store.loadActive(), isNull);
      expect(fake.cancelCount, 1);
    });

    test('fault isolation: a throwing cancel does not break the '
        'AccountActions wipe', () async {
      wireFunnelCaches();
      wireMigraine();
      expect(await store.clearIfOwnerMismatch('a@example.com'),
          isFalse);
      await store.save(attack(start: 1760010000000)); // active

      final fake = FakeMigraineNotifier()..throwOnCancel = true;
      LocalMigraineNotifier.debugSetWipeNotifier(fake);

      await AccountActions.clearDefaultCaches();

      expect(fake.cancelCount, 1);
      expect(disk.containsKey(MigraineAttackStore.storageKey), isFalse);
      expect(await store.loadActive(), isNull);
    });

    test('session-expiry leg: cancelPostedAttack cancels once, '
        'and a throwing notifier never propagates', () async {
      expect(await store.clearIfOwnerMismatch('a@example.com'),
          isFalse);
      await store.save(attack(start: 1760010000000)); // active

      final fake = FakeMigraineNotifier();
      LocalMigraineNotifier.debugSetWipeNotifier(fake);

      // The exact call _onSessionExpired makes in main.dart.
      await LocalMigraineNotifier.cancelPostedAttack();
      expect(fake.cancelCount, 1);

      final throwing = FakeMigraineNotifier()..throwOnCancel = true;
      LocalMigraineNotifier.debugSetWipeNotifier(throwing);
      await LocalMigraineNotifier.cancelPostedAttack();
      expect(throwing.cancelCount, 1);
    });
  });
}
