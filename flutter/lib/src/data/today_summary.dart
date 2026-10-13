import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';

/// Round 35 — the Home "Today Summary" data layer: a content-for-content
/// port of the native implementation.
///
/// Native spec (traced, not assumed):
/// - Subtitle + plan: `TodayViewModel.uiState` combine block
///   (`TodayViewModel.kt`) over medications / reminders / habits /
///   today's dose occurrences / today's completed-reminder set.
/// - Trends: `HealthComparisonRepository.getWhatChangedComparisons`
///   (Sleep Duration, Resting Heart Rate, Symptom Logs — in that
///   order), rendered by `TodayScreen.kt` item 3.
///
/// Where each native source lives in the Flutter/server world:
/// - Medications: the sync pull's `profile.medications` blob — rows of
///   native's view-model `Medication` shape `{id (uuid), name, dose,
///   frequency, startDate, endDate, isPresent, isDeleted, updatedAt}`.
///   The blob carries NO `timesPerDay` (native restores it as 1 on a
///   fresh install), so every med yields the single "Daily" slot —
///   exactly what native shows for the same server data.
/// - Dose status: native occurrences are device-local and never sync
///   (`syncState = "SAVED_LOCALLY"`, no API route). The one synced
///   trace of a dose action is the log entry native writes on TAKEN
///   (`ScheduledDoseRepository.recordDoseAction`: category Medication,
///   body "Took {name} {dose}", and a skip after a take rewrites that
///   body to "[Corrected to Skipped] …"). Flutter mirrors both
///   channels: today's explicit action lives in [TodayPlanStore]
///   (device-local, like the occurrence row) and wins; otherwise a
///   med counts as taken when today's pulled entries carry its
///   "Took …" entry. SKIPPED/SNOOZED recorded only in the native app
///   have no synced trace and read as PENDING here.
/// - Reminders: the pull's `profile.reminders` blob (native `Reminder`
///   entity rows, ids included); completion is the device-local
///   per-day set in [TodayPlanStore], like native's DataStore set.
/// - Habits: `GET /api/habits` (`HabitDto`), completed when `logs`
///   contains today's device-local date string.
/// - Trends biometrics: Health Connect via [HealthConnectService]
///   (per-day sleep minutes + resting-HR history). Symptom counts
///   come from the pulled entries + categories.
///
/// Data-shape rules enforced here (team history):
/// - Server int8 fields arrive as JSON strings (node-pg): every id /
///   timestamp / hour parse tolerates numeric strings, nums, and
///   garbage (→ skipped row, never a crash, never raw JSON on screen).
/// - Biometric 0 = failed read: sleep/RHR values ≤ 0 are excluded
///   before any averaging, exactly as native filters `> 0`.
/// - Nothing here ever throws: every source degrades to its honest
///   empty outcome, and a failed sync pull falls back to the
///   account-bound, date-bound [TodaySummaryCache].

// ── Shared tolerant parses (Rounds 19–20 pattern) ────────────────────

/// Loose int: num → int, numeric string → int, anything else → null.
int? parseLooseIntOrNull(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

String dateStrOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ── Dose status (native `ActionStatus`) ──────────────────────────────

enum DoseStatus { pending, taken, skipped, snoozed }

String doseStatusName(DoseStatus s) => switch (s) {
      DoseStatus.pending => 'PENDING',
      DoseStatus.taken => 'TAKEN',
      DoseStatus.skipped => 'SKIPPED',
      DoseStatus.snoozed => 'SNOOZED',
    };

DoseStatus? doseStatusFromName(String name) => switch (name) {
      'TAKEN' => DoseStatus.taken,
      'SKIPPED' => DoseStatus.skipped,
      'SNOOZED' => DoseStatus.snoozed,
      'PENDING' => DoseStatus.pending,
      _ => null,
    };

// ── Plan items (native `TodayPlanItem`) ──────────────────────────────

enum PlanItemKind { medication, reminder, habit }

class TodayPlanItem {
  final PlanItemKind kind;

  /// Native-style stable id: `med_<key>_<slot>`, `rem_<id>`,
  /// `habit_<id>`.
  final String id;
  final String title;
  final String timeDisplay;
  final bool isCompleted;

  /// Medications only; [DoseStatus.pending] for other kinds.
  final DoseStatus status;

  /// Medications only: the dose line value (may be '').
  final String dose;

  /// Medications only: blob identifier (uuid when present, else name)
  /// + slot label, for plan-store action keys.
  final String medKey;
  final String slot;

  /// Reminders only: native reminder id (blob `id`).
  final int reminderId;
  final int reminderHour;
  final int reminderMinute;

  /// Habits only.
  final String habitId;
  final String habitTargetTime;

  const TodayPlanItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.timeDisplay,
    required this.isCompleted,
    this.status = DoseStatus.pending,
    this.dose = '',
    this.medKey = '',
    this.slot = '',
    this.reminderId = 0,
    this.reminderHour = 0,
    this.reminderMinute = 0,
    this.habitId = '',
    this.habitTargetTime = 'Anytime',
  });

  /// Port of native `TodayPlanItem.isOverdue()` (the per-row badge
  /// rule — distinct from the summary overdue count below).
  bool isOverdue(DateTime now) {
    if (isCompleted) return false;
    // A skipped dose is an intentional action, not a missed one.
    if (kind == PlanItemKind.medication && status == DoseStatus.skipped) {
      return false;
    }
    switch (kind) {
      case PlanItemKind.medication:
        return switch (slot) {
          'Morning' => now.hour >= 12,
          'Evening' => now.hour >= 20,
          'Daily' => now.hour >= 18,
          _ => false,
        };
      case PlanItemKind.reminder:
        return now.hour > reminderHour ||
            (now.hour == reminderHour && now.minute > reminderMinute);
      case PlanItemKind.habit:
        final target = habitTargetTime;
        if (target == 'Anytime') return false;
        final parts = target.split(':');
        if (parts.length != 2) return false;
        final hour = int.tryParse(parts[0]);
        final min = int.tryParse(parts[1]);
        if (hour == null || min == null) return false;
        return now.hour > hour || (now.hour == hour && now.minute > min);
    }
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'id': id,
        'title': title,
        'timeDisplay': timeDisplay,
        'isCompleted': isCompleted,
        'status': doseStatusName(status),
        'dose': dose,
        'medKey': medKey,
        'slot': slot,
        'reminderId': reminderId,
        'reminderHour': reminderHour,
        'reminderMinute': reminderMinute,
        'habitId': habitId,
        'habitTargetTime': habitTargetTime,
      };

  static TodayPlanItem? fromJson(Map<String, dynamic> j) {
    try {
      final kind = PlanItemKind.values
          .where((k) => k.name == j['kind'])
          .firstOrNull;
      if (kind == null) return null;
      return TodayPlanItem(
        kind: kind,
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        timeDisplay: '${j['timeDisplay'] ?? ''}',
        isCompleted: j['isCompleted'] == true,
        status: doseStatusFromName('${j['status'] ?? ''}') ??
            DoseStatus.pending,
        dose: '${j['dose'] ?? ''}',
        medKey: '${j['medKey'] ?? ''}',
        slot: '${j['slot'] ?? ''}',
        reminderId: parseLooseIntOrNull(j['reminderId']) ?? 0,
        reminderHour: parseLooseIntOrNull(j['reminderHour']) ?? 0,
        reminderMinute: parseLooseIntOrNull(j['reminderMinute']) ?? 0,
        habitId: '${j['habitId'] ?? ''}',
        habitTargetTime: '${j['habitTargetTime'] ?? 'Anytime'}',
      );
    } catch (_) {
      return null;
    }
  }
}

// ── Blob row parses ──────────────────────────────────────────────────

/// One medication from the `profile.medications` blob (native
/// view-model `Medication` shape). Null when the row is deleted,
/// not present (archived), or nameless — native's plan only includes
/// `!isArchived && !isDeleted` meds.
class SummaryMedication {
  final String key; // uuid when present, else the name
  final String name;
  final String dose;

  const SummaryMedication(
      {required this.key, required this.name, required this.dose});

  static SummaryMedication? fromBlobRow(Map<String, dynamic> row) {
    try {
      if (row['isDeleted'] == true) return null;
      if (row['isPresent'] == false) return null;
      final name = '${row['name'] ?? ''}'.trim();
      if (name.isEmpty) return null;
      final uuid = '${row['id'] ?? ''}'.trim();
      return SummaryMedication(
        key: uuid.isNotEmpty ? uuid : name,
        name: name,
        dose: '${row['dose'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
}

/// One reminder from the `profile.reminders` blob (native `Reminder`
/// entity shape). Defaults mirror the entity (12:00, enabled).
class SummaryReminder {
  final int id;
  final String title;
  final int fixedHour;
  final int fixedMinute;
  final bool isEnabled;

  const SummaryReminder({
    required this.id,
    required this.title,
    required this.fixedHour,
    required this.fixedMinute,
    required this.isEnabled,
  });

  /// [fallbackId] keys rows whose blob id is missing/unparseable so
  /// completion state still tracks per row (native rows always carry
  /// an id; this only guards malformed data).
  static SummaryReminder? fromBlobRow(Map<String, dynamic> row,
      {required int fallbackId}) {
    try {
      return SummaryReminder(
        id: parseLooseIntOrNull(row['id']) ?? fallbackId,
        title: '${row['title'] ?? ''}',
        fixedHour: parseLooseIntOrNull(row['fixedHour']) ?? 12,
        fixedMinute: parseLooseIntOrNull(row['fixedMinute']) ?? 0,
        isEnabled: row['isEnabled'] != false,
      );
    } catch (_) {
      return null;
    }
  }
}

// ── Category resolution ──────────────────────────────────────────────
//
// The sync category DTO carries no slug (native `CategoryDtoModel`),
// so — like the round-21 feeling check-in — categories resolve by
// exact name first, then by the native seeded id when a category
// carries it (`DefaultCategories`: Symptoms id 1, Medication id 8).

int? resolveSummaryCategoryId(
  List<QuickLogCategory> categories, {
  required String name,
  required int fallbackId,
}) {
  for (final c in categories) {
    if (c.name.trim().toLowerCase() == name.toLowerCase()) return c.id;
  }
  for (final c in categories) {
    if (c.id == fallbackId) return c.id;
  }
  return null;
}

// ── Plan computation (port of the TodayViewModel combine block) ─────

class TodayPlanData {
  final List<TodayPlanItem> items;
  final int remainingCount;
  final int overdueCount;
  final String summaryText;

  const TodayPlanData({
    required this.items,
    required this.remainingCount,
    required this.overdueCount,
    required this.summaryText,
  });

  static const empty = TodayPlanData(
    items: [],
    remainingCount: 0,
    overdueCount: 0,
    summaryText: 'No plans recorded today',
  );

  Map<String, dynamic> toJson() => {
        'items': items.map((i) => i.toJson()).toList(),
        'remainingCount': remainingCount,
        'overdueCount': overdueCount,
        'summaryText': summaryText,
      };

  static TodayPlanData? fromJson(Map<String, dynamic> j) {
    try {
      final rawItems = j['items'];
      if (rawItems is! List) return null;
      final items = <TodayPlanItem>[];
      for (final r in rawItems) {
        if (r is Map<String, dynamic>) {
          final item = TodayPlanItem.fromJson(r);
          if (item != null) items.add(item);
        }
      }
      return TodayPlanData(
        items: items,
        remainingCount: parseLooseIntOrNull(j['remainingCount']) ?? 0,
        overdueCount: parseLooseIntOrNull(j['overdueCount']) ?? 0,
        summaryText: '${j['summaryText'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Whether today's pulled entries prove [medName] was taken: native
/// writes body "Took {name}" / "Took {name} {dose}" into the
/// Medication category on TAKEN, and a later skip rewrites the body
/// with a "[Corrected to Skipped] " prefix — such rows never count.
bool medTakenFromEntries({
  required String medName,
  required List<QuickLogEntry> todayEntries,
  required int? medicationCategoryId,
}) {
  if (medicationCategoryId == null) return false;
  for (final e in todayEntries) {
    if (e.categoryId != medicationCategoryId) continue;
    final body = e.body.trim();
    if (body.startsWith('[Corrected to Skipped]')) continue;
    if (body == 'Took $medName' || body.startsWith('Took $medName ')) {
      return true;
    }
  }
  return false;
}

/// Builds the plan exactly as native's combine block does:
/// meds (Daily slot) → enabled reminders → habits; sorted incomplete
/// first, then by `timeDisplay` string; remaining/overdue counts and
/// the subtitle string follow the native formulas verbatim.
TodayPlanData buildTodayPlan({
  required List<SummaryMedication> medications,
  required List<SummaryReminder> reminders,
  required List<HabitDto> habits,
  required TodayPlanLocalState localState,
  required List<QuickLogEntry> entries,
  required int? medicationCategoryId,
  required DateTime now,
}) {
  final todayStr = dateStrOf(now);
  final todayEntries = entries
      .where((e) =>
          dateStrOf(DateTime.fromMillisecondsSinceEpoch(e.timestamp)) ==
          todayStr)
      .toList();

  final plan = <TodayPlanItem>[];

  for (final med in medications) {
    // The profile blob carries no timesPerDay; native restores it as
    // 1, so the slot list is exactly ["Daily"] (native uses
    // ["Morning", "Evening"] only when timesPerDay > 1 locally).
    const slot = 'Daily';
    final explicit =
        localState.medActions[TodayPlanStore.medActionKey(med.key, slot)];
    final status = explicit ??
        (medTakenFromEntries(
          medName: med.name,
          todayEntries: todayEntries,
          medicationCategoryId: medicationCategoryId,
        )
            ? DoseStatus.taken
            : DoseStatus.pending);
    plan.add(TodayPlanItem(
      kind: PlanItemKind.medication,
      id: 'med_${med.key}_$slot',
      title: med.name,
      timeDisplay: slot,
      isCompleted: status == DoseStatus.taken,
      status: status,
      dose: med.dose,
      medKey: med.key,
      slot: slot,
    ));
  }

  for (final rem in reminders) {
    if (!rem.isEnabled) continue;
    plan.add(TodayPlanItem(
      kind: PlanItemKind.reminder,
      id: 'rem_${rem.id}',
      title: rem.title,
      timeDisplay:
          '${rem.fixedHour.toString().padLeft(2, '0')}:${rem.fixedMinute.toString().padLeft(2, '0')}',
      isCompleted: localState.completedReminderIds.contains(rem.id),
      reminderId: rem.id,
      reminderHour: rem.fixedHour,
      reminderMinute: rem.fixedMinute,
    ));
  }

  for (final habit in habits) {
    plan.add(TodayPlanItem(
      kind: PlanItemKind.habit,
      id: 'habit_${habit.id}',
      title: habit.title,
      timeDisplay: habit.targetTime,
      isCompleted: habit.logs.contains(todayStr),
      habitId: habit.id,
      habitTargetTime: habit.targetTime,
    ));
  }

  plan.sort((a, b) {
    if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
    return a.timeDisplay.compareTo(b.timeDisplay);
  });

  final remainingCount = plan.where((i) => !i.isCompleted).length;

  // Native's summary overdue count (NOT the per-row badge rule):
  // meds count only a missed Morning slot at/after noon, reminders
  // when their hour has passed, habits never; skipped meds exempt.
  final overdueCount = plan.where((item) {
    if (item.isCompleted) return false;
    if (item.kind == PlanItemKind.medication &&
        item.status == DoseStatus.skipped) {
      return false;
    }
    return switch (item.kind) {
      PlanItemKind.medication =>
        item.slot == 'Morning' && now.hour >= 12,
      PlanItemKind.reminder => item.reminderHour < now.hour,
      PlanItemKind.habit => false,
    };
  }).length;

  final summaryText = remainingCount > 0
      ? '$remainingCount item${remainingCount > 1 ? 's' : ''} remaining'
          '${overdueCount > 0 ? ' · $overdueCount overdue' : ''}'
      : (plan.isNotEmpty
          ? 'Everything planned for today is complete'
          : 'No plans recorded today');

  return TodayPlanData(
    items: plan,
    remainingCount: remainingCount,
    overdueCount: overdueCount,
    summaryText: summaryText,
  );
}

// ── Trends (port of HealthComparisonRepository) ─────────────────────

class TrendComparison {
  final String metricName;
  final String currentPeriod;
  final String comparisonPeriod;
  final String differenceText;
  final String dataSource;
  final String lastUpdatedTime;

  const TrendComparison({
    required this.metricName,
    required this.currentPeriod,
    required this.comparisonPeriod,
    required this.differenceText,
    required this.dataSource,
    required this.lastUpdatedTime,
  });

  Map<String, dynamic> toJson() => {
        'metricName': metricName,
        'currentPeriod': currentPeriod,
        'comparisonPeriod': comparisonPeriod,
        'differenceText': differenceText,
        'dataSource': dataSource,
        'lastUpdatedTime': lastUpdatedTime,
      };

  static TrendComparison? fromJson(Map<String, dynamic> j) {
    try {
      return TrendComparison(
        metricName: '${j['metricName'] ?? ''}',
        currentPeriod: '${j['currentPeriod'] ?? ''}',
        comparisonPeriod: '${j['comparisonPeriod'] ?? ''}',
        differenceText: '${j['differenceText'] ?? ''}',
        dataSource: '${j['dataSource'] ?? ''}',
        lastUpdatedTime: '${j['lastUpdatedTime'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Port of native's symptom-log counting: entries in
/// [today − 7d at local midnight, now], matched by the Symptoms
/// category id, or — native's legacy fallback — categoryId 0 entries
/// whose body names headache/nausea/fatigue.
int countSymptomLogs({
  required List<QuickLogEntry> entries,
  required int? symptomsCategoryId,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final startMs =
      today.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
  final nowMs = now.millisecondsSinceEpoch;
  var count = 0;
  for (final e in entries) {
    if (e.timestamp < startMs || e.timestamp > nowMs) continue;
    final matchesCategory =
        symptomsCategoryId != null && e.categoryId == symptomsCategoryId;
    final body = e.body.toLowerCase();
    final matchesLegacy = e.categoryId == 0 &&
        (body.contains('headache') ||
            body.contains('nausea') ||
            body.contains('fatigue'));
    if (matchesCategory || matchesLegacy) count++;
  }
  return count;
}

/// Builds the comparison list in native's order (Sleep, Resting
/// Heart Rate, Symptom Logs), each section fail-safe and independent.
/// Biometric maps carry only usable values — callers drop ≤ 0 first
/// (the loader does); the ≥ 3 previous days rule is native's.
List<TrendComparison> buildTrendComparisons({
  required Map<String, int> sleepMinutesByDate,
  required Map<String, int> restingHrByDate,
  required int symptomLogCount,
  required String todayStr,
}) {
  final out = <TrendComparison>[];

  // 1. Sleep Duration.
  final todaySleep = sleepMinutesByDate[todayStr];
  final prevSleep = sleepMinutesByDate.entries
      .where((e) => e.key != todayStr && e.value > 0)
      .map((e) => e.value)
      .toList();
  if (todaySleep != null && todaySleep > 0 && prevSleep.length >= 3) {
    final avgSleep = prevSleep.reduce((a, b) => a + b) / prevSleep.length;
    final diffMins = (todaySleep - avgSleep).toInt();
    final diffText = diffMins < -15
        ? '${diffMins.abs()} minutes shorter than your seven-day average.'
        : diffMins > 15
            ? '$diffMins minutes longer than your seven-day average.'
            : 'Close to your seven-day average.';
    out.add(TrendComparison(
      metricName: 'Sleep Duration',
      currentPeriod: '${todaySleep ~/ 60}h ${todaySleep % 60}m today',
      comparisonPeriod:
          '7-day avg (${(avgSleep / 60).toInt()}h ${(avgSleep % 60).toInt()}m)',
      differenceText: 'Sleep was $diffText',
      dataSource: 'Health Connect',
      lastUpdatedTime: 'Today',
    ));
  }

  // 2. Resting Heart Rate.
  final todayRhr = restingHrByDate[todayStr];
  final prevRhr = restingHrByDate.entries
      .where((e) => e.key != todayStr && e.value > 0)
      .map((e) => e.value)
      .toList();
  if (todayRhr != null && todayRhr > 0 && prevRhr.length >= 3) {
    final avgRhr =
        (prevRhr.reduce((a, b) => a + b) / prevRhr.length).toInt();
    final diffBpm = todayRhr - avgRhr;
    final diffText = diffBpm > 5
        ? '$diffBpm bpm higher than your seven-day average.'
        : diffBpm < -5
            ? '${diffBpm.abs()} bpm lower than your seven-day average.'
            : 'close to your recent average.';
    out.add(TrendComparison(
      metricName: 'Resting Heart Rate',
      currentPeriod: '$todayRhr bpm today',
      comparisonPeriod: '7-day avg ($avgRhr bpm)',
      differenceText: 'Resting heart rate is $diffText',
      dataSource: 'Health Connect',
      lastUpdatedTime: 'Today',
    ));
  }

  // 3. Symptom Logs.
  if (symptomLogCount > 0) {
    out.add(TrendComparison(
      metricName: 'Symptom Logs',
      currentPeriod: '$symptomLogCount logged in past 7 days',
      comparisonPeriod: 'Previous week',
      differenceText:
          'Symptoms were logged $symptomLogCount time${symptomLogCount > 1 ? 's' : ''} this week.',
      dataSource: 'Personal Log Entries',
      lastUpdatedTime: 'Today',
    ));
  }

  return out;
}

// ── Last-known cache (account-bound, date-bound) ─────────────────────

/// The completed summary (plan + trends) from the last successful
/// load, persisted like [HomeDataCache]: memory + one secure-storage
/// JSON blob stamped with the owner email and the device-local date.
/// A different account, a different day, or an unowned blob drops it —
/// a summary is one account's health picture for one day, and neither
/// half may leak across. Used only when a fresh load fails (offline /
/// sync pull down), so Home never shows an error or a blank section
/// for data it showed minutes ago.
class TodaySummaryCache {
  static const String storageKey = 'today_summary_cache_v1';

  static final TodaySummaryCache instance = TodaySummaryCache._internal();
  TodaySummaryCache._internal();

  factory TodaySummaryCache.testInstance() = TodaySummaryCache._internal;

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  @visibleForTesting
  void debugSetStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) {
    _read = read;
    _write = write;
    if (delete != null) _delete = delete;
  }

  String? _ownerEmail;
  String? _date;
  TodayPlanData? _plan;
  List<TrendComparison>? _trends;

  @visibleForTesting
  void debugReset() {
    _ownerEmail = null;
    _date = null;
    _plan = null;
    _trends = null;
  }

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  /// Synchronous snapshot for the card's first frame. Null unless the
  /// in-memory copy belongs to [email] and [todayStr].
  ({TodayPlanData plan, List<TrendComparison> trends})? snapshot({
    required String? email,
    required String todayStr,
  }) {
    if (_plan == null || _trends == null) return null;
    if (_date != todayStr) return null;
    final expected = _normalizeEmail(email);
    if (expected != null && _ownerEmail != expected) return null;
    if (expected == null && _ownerEmail != null) return null;
    return (plan: _plan!, trends: _trends!);
  }

  /// Stores a completed load in memory and persists it. Never throws.
  Future<void> save({
    required String? email,
    required String todayStr,
    required TodayPlanData plan,
    required List<TrendComparison> trends,
  }) async {
    _ownerEmail = _normalizeEmail(email);
    _date = todayStr;
    _plan = plan;
    _trends = trends;
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': _ownerEmail,
          'date': todayStr,
          'plan': plan.toJson(),
          'trends': trends.map((t) => t.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Memory copy stays; disk simply misses this refresh.
    }
  }

  /// Loads the persisted copy for [email]/[todayStr]; warms memory on
  /// success. Null on missing/corrupt/foreign/stale — foreign and
  /// unowned blobs are wiped so they cannot resurface.
  Future<({TodayPlanData plan, List<TrendComparison> trends})?> load({
    required String? email,
    required String todayStr,
  }) async {
    final mem = snapshot(email: email, todayStr: todayStr);
    if (mem != null) return mem;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final blobOwner = decoded['ownerEmail'] is String
          ? _normalizeEmail(decoded['ownerEmail'] as String)
          : null;
      final expected = _normalizeEmail(email);
      if (expected != null && blobOwner != expected) {
        await _wipeDisk();
        return null;
      }
      if (decoded['date'] != todayStr) return null;
      final planRaw = decoded['plan'];
      if (planRaw is! Map<String, dynamic>) return null;
      final plan = TodayPlanData.fromJson(planRaw);
      if (plan == null) return null;
      final trends = <TrendComparison>[];
      final rawTrends = decoded['trends'];
      if (rawTrends is List) {
        for (final r in rawTrends) {
          if (r is Map<String, dynamic>) {
            final t = TrendComparison.fromJson(r);
            if (t != null) trends.add(t);
          }
        }
      }
      _ownerEmail = blobOwner;
      _date = todayStr;
      _plan = plan;
      _trends = trends;
      return (plan: plan, trends: trends);
    } catch (_) {
      return null;
    }
  }

  Future<void> _wipeDisk() async {
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Wipes memory + disk (logout hook). Never throws.
  Future<void> clear() async {
    debugReset();
    await _wipeDisk();
  }
}

// ── Loader / actions ─────────────────────────────────────────────────

class TodaySummaryData {
  final TodayPlanData plan;
  final List<TrendComparison> trends;

  /// True when this came from [TodaySummaryCache] because the fresh
  /// load failed — the values are last-known, not live.
  final bool fromCache;

  /// True when the sync pull succeeded (plan sources are live).
  final bool pullSucceeded;

  const TodaySummaryData({
    required this.plan,
    required this.trends,
    this.fromCache = false,
    this.pullSucceeded = false,
  });
}

/// Orchestrates one summary load + the plan-row actions. Every method
/// is fail-safe (never throws): the card renders honest empty states
/// on failure, and last-known values whenever the cache has them.
class TodaySummaryLoader {
  final TabsBackend backend;
  final HealthConnectService hc;
  final TodayPlanStore planStore;
  final TodaySummaryCache cache;
  final SessionStore sessionStore;

  TodaySummaryLoader({
    TabsBackend? backend,
    HealthConnectService? hc,
    TodayPlanStore? planStore,
    TodaySummaryCache? cache,
    SessionStore? sessionStore,
  })  : backend = backend ?? TabsBackend(),
        hc = hc ?? HealthConnectService(),
        planStore = planStore ?? TodayPlanStore.instance,
        cache = cache ?? TodaySummaryCache.instance,
        sessionStore = sessionStore ?? SessionStore();

  Future<String?> _email() async {
    try {
      return await sessionStore.readEmail();
    } catch (_) {
      return null;
    }
  }

  /// Full load: plan from the sync pull (+ local plan state), trends
  /// from Health Connect + entries. On pull failure, falls back to
  /// the cache (plan) while still attempting live HC trends.
  Future<TodaySummaryData> load({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final todayStr = dateStrOf(at);
    final email = await _email();
    try {
      final profile = await backend.fetchProfile();
      if (profile != null) {
        final entries = await backend.fetchLogEntryDtos();
        final categories = await backend.fetchLogCategories();
        final habits = await backend.fetchHabits();
        final localState =
            await planStore.load(email: email, todayStr: todayStr);
        final medCategoryId = resolveSummaryCategoryId(categories,
            name: 'Medication', fallbackId: 8);
        final plan = buildTodayPlan(
          medications: _parseMeds(profile),
          reminders: _parseReminders(profile),
          habits: habits,
          localState: localState,
          entries: entries,
          medicationCategoryId: medCategoryId,
          now: at,
        );
        final trends = await loadTrends(
          entries: entries,
          categories: categories,
          now: at,
        );
        unawaited(cache.save(
            email: email, todayStr: todayStr, plan: plan, trends: trends));
        return TodaySummaryData(
            plan: plan, trends: trends, pullSucceeded: true);
      }
    } catch (_) {
      // Fall through to the cache path — a summary load failure must
      // never surface as an error or a blank section.
    }
    // Pull failed (offline / no session): last-known plan from cache,
    // live HC trends where possible (native reads HC locally too).
    final cached = await cache.load(email: email, todayStr: todayStr);
    final trends = await loadTrends(entries: null, categories: null, now: at);
    if (cached != null) {
      return TodaySummaryData(
        plan: cached.plan,
        trends: trends.isNotEmpty ? trends : cached.trends,
        fromCache: true,
      );
    }
    return TodaySummaryData(plan: TodayPlanData.empty, trends: trends);
  }

  List<SummaryMedication> _parseMeds(Map<String, dynamic> profile) {
    final out = <SummaryMedication>[];
    for (final row in TabsBackend.decodeProfileList(profile['medications'])) {
      final med = SummaryMedication.fromBlobRow(row);
      if (med != null) out.add(med);
    }
    return out;
  }

  List<SummaryReminder> _parseReminders(Map<String, dynamic> profile) {
    final rows = TabsBackend.decodeProfileList(profile['reminders']);
    final out = <SummaryReminder>[];
    for (var i = 0; i < rows.length; i++) {
      final rem =
          SummaryReminder.fromBlobRow(rows[i], fallbackId: -(i + 1));
      if (rem != null) out.add(rem);
    }
    return out;
  }

  /// Trends only (the card's refresh button — native
  /// `loadHealthComparisons`). [entries]/[categories] null → the
  /// symptom section is skipped (no pulled data to count from).
  Future<List<TrendComparison>> loadTrends({
    required List<QuickLogEntry>? entries,
    required List<QuickLogCategory>? categories,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final todayStr = dateStrOf(at);
    final sleepByDate = <String, int>{};
    final rhrByDate = <String, int>{};
    try {
      // Native reads 8 days of sleep history anchored on today
      // (sessions attributed to their end date, as the bridge does).
      // Calendar-day arithmetic — a 24h Duration subtraction can
      // drift a date across a DST boundary.
      for (var i = 0; i <= 8; i++) {
        final d = dateStrOf(DateTime(at.year, at.month, at.day - i));
        final mins = await hc.readSleepMinutes(d);
        // Biometric 0 = failed read — excluded, never averaged.
        if (mins != null && mins > 0) sleepByDate[d] = mins;
      }
    } catch (_) {
      // Section fails safe — other comparisons still build.
    }
    try {
      final history = await hc.readRestingHrHistory(8);
      for (final h in history) {
        if (h.bpm > 0) rhrByDate[h.date] = h.bpm;
      }
    } catch (_) {
      // Section fails safe.
    }
    var symptomCount = 0;
    if (entries != null && categories != null) {
      final symptomsId = resolveSummaryCategoryId(categories,
          name: 'Symptoms', fallbackId: 1);
      symptomCount = countSymptomLogs(
          entries: entries, symptomsCategoryId: symptomsId, now: at);
    }
    return buildTrendComparisons(
      sleepMinutesByDate: sleepByDate,
      restingHrByDate: rhrByDate,
      symptomLogCount: symptomCount,
      todayStr: todayStr,
    );
  }

  /// Re-runs trends against a FRESH pull (refresh button): native
  /// re-reads its local stores; Flutter's equivalent is dropping the
  /// in-memory pull cache and re-reading entries/categories.
  Future<List<TrendComparison>> refreshTrends({DateTime? now}) async {
    try {
      backend.invalidateSyncPull();
      final pull = await backend.fetchSyncPull();
      if (pull == null) return loadTrends(entries: null, categories: null, now: now);
      final entries = await backend.fetchLogEntryDtos();
      final categories = await backend.fetchLogCategories();
      return loadTrends(entries: entries, categories: categories, now: now);
    } catch (_) {
      return loadTrends(entries: null, categories: null, now: now);
    }
  }

  // ── Plan-row actions (native TodayViewModel handlers) ─────────────

  /// Reminder checkbox — native `completeReminder` writes the
  /// device-local per-day set; the plan store is that set.
  Future<void> setReminderCompleted(TodayPlanItem item, bool completed,
      {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final email = await _email();
    await planStore.setReminderCompleted(
      email: email,
      todayStr: dateStrOf(at),
      reminderId: item.reminderId,
      completed: completed,
    );
  }

  /// Habit checkbox — native `toggleHabit` → `POST /api/habits/log`.
  /// False when the write failed (the row keeps its current state,
  /// exactly as native's flow only re-emits on success).
  Future<bool> setHabitCompleted(TodayPlanItem item, bool completed,
      {DateTime? now}) async {
    final at = now ?? DateTime.now();
    try {
      return await backend.logHabit(
        habitId: item.habitId,
        date: dateStrOf(at),
        completed: completed,
      );
    } catch (_) {
      return false;
    }
  }

  /// Medication Take / Skip / Undo — native `markMedicationAction` →
  /// `ScheduledDoseRepository.recordDoseAction`:
  /// - the action itself is recorded device-locally (plan store);
  /// - TAKEN also posts the synced "Took {name} {dose}" log entry in
  ///   the Medication category (fresh id = max + 1, round-19 rule);
  /// - SKIPPED after a take rewrites that entry's body with the
  ///   "[Corrected to Skipped] " prefix;
  /// - undo (→ PENDING) leaves the entry, as native does.
  /// The local record happens even if the entry post fails — native's
  /// occurrence write is local-first the same way.
  Future<void> setMedicationAction(TodayPlanItem item, DoseStatus status,
      {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final todayStr = dateStrOf(at);
    final email = await _email();
    await planStore.setMedAction(
      email: email,
      todayStr: todayStr,
      medKey: item.medKey,
      slot: item.slot,
      status: status,
    );
    try {
      if (status == DoseStatus.taken || status == DoseStatus.skipped) {
        backend.invalidateSyncPull();
        final entries = await backend.fetchLogEntryDtos();
        final categories = await backend.fetchLogCategories();
        final medCategoryId = resolveSummaryCategoryId(categories,
            name: 'Medication', fallbackId: 8);
        if (medCategoryId != null) {
          final took = _findTookEntry(item.title, entries, medCategoryId, at);
          if (status == DoseStatus.taken && took == null) {
            var maxId = 0;
            for (final e in entries) {
              if (e.id > maxId) maxId = e.id;
            }
            final dose = item.dose.trim();
            await backend.postLogEntries([
              QuickLogEntry(
                id: maxId + 1,
                categoryId: medCategoryId,
                body: 'Took ${item.title}${dose.isNotEmpty ? ' $dose' : ''}',
                chips: '[]',
                manualText: '',
                timestamp: at.millisecondsSinceEpoch,
              ),
            ]);
          } else if (status == DoseStatus.skipped && took != null) {
            await backend.postLogEntries([
              QuickLogEntry(
                id: took.id,
                categoryId: took.categoryId,
                body: '[Corrected to Skipped] ${took.body}',
                chips: took.chips,
                manualText: took.manualText,
                timestamp: took.timestamp,
              ),
            ]);
          }
        }
        backend.invalidateSyncPull();
      }
    } catch (_) {
      // Entry sync is best-effort; the local action already landed.
    }
  }

  QuickLogEntry? _findTookEntry(String medName, List<QuickLogEntry> entries,
      int medCategoryId, DateTime now) {
    final todayStr = dateStrOf(now);
    for (final e in entries) {
      if (e.categoryId != medCategoryId) continue;
      if (dateStrOf(DateTime.fromMillisecondsSinceEpoch(e.timestamp)) !=
          todayStr) {
        continue;
      }
      final body = e.body.trim();
      if (body.startsWith('[Corrected to Skipped]')) continue;
      if (body == 'Took $medName' || body.startsWith('Took $medName ')) {
        return e;
      }
    }
    return null;
  }
}
