import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/reminder_alarm_sync.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';

/// TAKEOVER Phase 4 — first-run reminder continuity (Ivy P0 §3.2).
///
/// Scheduled notifications live in the OLD package's plugin prefs +
/// AlarmManager registrations; none survive the package change, and
/// the production package starts with ZERO scheduled reminders. The
/// resync code already exists — `ReminderSync.syncAll` for the
/// Settings toggles + event counters, `reconcileReminderAlarms` for
/// user reminders — but today it only runs when the user opens
/// Settings / Reminders. This file runs it ONCE, automatically,
/// on the first run after install/update (and again right after a
/// migration import — see the Settings import action), so reminders
/// survive the switch without the user opening anything.
///
/// Failure rule: the done-flag is stamped ONLY after a fully
/// successful resync. A failed run (offline first launch, a failed
/// pull) leaves the flag unset and the next launch retries — the
/// resync itself is idempotent (schedules replace by plugin id,
/// cancels are repeat-safe), so retrying can never duplicate an
/// alarm.
class FirstRunSyncException implements Exception {
  final String code;
  const FirstRunSyncException(this.code);
  @override
  String toString() => 'FirstRunSyncException($code)';
}

/// The exactly-once gate around one resync callback.
class FirstRunReminderResync {
  /// Secure-storage flag key. Deliberately NOT a migration-bundle
  /// member: it records THIS install's resync, not user data, and
  /// must never travel between packages.
  static const String doneKey = 'first_run_reminder_resync_v1';
  static const String doneValue = 'done';

  final SecureStore _store;
  final Future<void> Function() _resync;

  FirstRunReminderResync({
    SecureStore? store,
    required this._resync,
  }) : _store = store ?? const FlutterSecureStore();

  /// Runs the resync when this install has not completed one yet.
  /// Returns true when the resync ran (and the flag was stamped).
  /// A resync failure propagates and stamps nothing, so the next
  /// call retries. A flag READ failure is treated as "not done" —
  /// re-running an idempotent resync is harmless, skipping it is
  /// not.
  Future<bool> runOnce() async {
    String? flag;
    try {
      flag = await _store.read(doneKey);
    } catch (_) {
      flag = null;
    }
    if (flag == doneValue) return false;
    await _resync();
    try {
      await _store.write(doneKey, doneValue);
    } catch (_) {
      // The resync DID happen; a lost stamp only costs one
      // idempotent re-run on the next launch.
    }
    return true;
  }
}

/// The production resync: one fresh pull drives both halves.
///
/// - `ReminderSync.syncAll` inputs: the profile's habit / project /
///   event toggles + event counters (server-synced) and the LOCAL
///   check-in toggle from [SettingsStore] — after a migration
///   import that toggle is the imported value, which is why the
///   import action runs this too.
/// - `reconcileReminderAlarms` inputs: the profile's `reminders`
///   blob, parsed with the Reminders screen's own parser.
///
/// Throws [FirstRunSyncException] (`PULL_FAILED` /
/// `PROFILE_FAILED`) when either read fails. Crucially, a failed
/// reminders read NEVER reconciles against an empty list — that
/// would cancel every user-reminder alarm on a guess.
Future<void> performReminderResync({
  required TabsBackend backend,
  required SettingsStore settingsStore,
  required ReminderNotificationService notifications,
}) async {
  final pull = await backend.fetchSyncPull();
  if (pull == null) {
    throw const FirstRunSyncException('PULL_FAILED');
  }
  final data = SettingsProfileData.fromPull(pull);
  final checkInEnabled = await settingsStore.getCheckInReminderEnabled();
  await ReminderSync(notifications).syncAll(
    habitEnabled: data.habitReminderEnabled,
    projectEnabled: data.projectReminderEnabled,
    checkInEnabled: checkInEnabled,
    eventEnabled: data.eventReminderEnabled,
    events: data.eventCounters
        .map(EventCounterItem.fromMap)
        .map((c) => EventReminderRequest(
              counterId: c.id,
              name: c.name,
              targetDateMs: c.targetDate,
              isArchived: c.isArchived,
              isUp: c.isUp,
              deletedAt: c.deletedAt,
            ))
        .toList(),
  );
  final profile = await backend.fetchProfile();
  if (profile == null) {
    throw const FirstRunSyncException('PROFILE_FAILED');
  }
  final rows = TabsBackend.decodeProfileList(profile['reminders']);
  await reconcileReminderAlarms(notifications, parseReminderModels(rows));
}
