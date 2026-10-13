import 'dart:convert';

import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Round 29 — the Settings view of the sync pull.
///
/// Native source: `SyncManager.pullAllData()` (SyncManager.kt:507+)
/// writes the pull body into DataStore; `SettingsViewModel` exposes
/// those flows to `SettingsScreen`. Membership comes from the pull
/// body's top-level `isUnlimited`/`isAdmin` (SyncManager.kt:524-525 —
/// server computes `isUnlimited = isAdmin || users.is_unlimited`);
/// nickname/tag are top-level too (:592-593); everything else lives in
/// the body's `profile` object.
///
/// Server int fields can arrive as JSON strings — every parser below
/// is tolerant (num | String | bool | null), mirroring the existing
/// helpers in `tabs_backend.dart`.
class SettingsProfileData {
  final bool isUnlimited;
  final bool isAdmin;
  final String nickname;
  final String tag;
  final String userContext;
  final String knowledgeBase;
  final String professionalUpdates;
  final int? age;
  final double? heightCm;
  final double? weightKg;
  final String gender;
  final bool autoAiSuggestions;
  final bool shareDataWithFriends;
  final bool hrSpikeAlertsEnabled;
  final int spikeThreshold;
  final bool hrDeltaEnabled;
  final int spikeDeltaThreshold;
  final bool habitReminderEnabled;
  final bool projectReminderEnabled;
  final bool eventReminderEnabled;
  final String eventCountersRaw;
  final String counterHistoryRaw;
  final String medicationsRaw;
  final String conditionsRaw;
  final List<QuickLogInsight> insights;

  const SettingsProfileData({
    this.isUnlimited = false,
    this.isAdmin = false,
    this.nickname = '',
    this.tag = '',
    this.userContext = '',
    this.knowledgeBase = '',
    this.professionalUpdates = '',
    this.age,
    this.heightCm,
    this.weightKg,
    this.gender = '',
    this.autoAiSuggestions = false,
    this.shareDataWithFriends = true,
    this.hrSpikeAlertsEnabled = false,
    this.spikeThreshold = 120,
    this.hrDeltaEnabled = false,
    this.spikeDeltaThreshold = 30,
    this.habitReminderEnabled = false,
    this.projectReminderEnabled = true,
    this.eventReminderEnabled = true,
    this.eventCountersRaw = '',
    this.counterHistoryRaw = '',
    this.medicationsRaw = '',
    this.conditionsRaw = '',
    this.insights = const [],
  });

  /// Native membership copy derivation (SettingsScreen.kt:634-651).
  String get membershipTitle =>
      isAdmin ? 'Admin Account' : (isUnlimited ? 'Tabs Premium' : 'No Active Membership');
  String get membershipSubtitle => isAdmin
      ? 'Developer Access · All Features Unlocked'
      : (isUnlimited
          ? 'Premium Access · All Features Unlocked'
          : 'Subscribe to unlock all AI features');
  String get membershipBadge =>
      isAdmin ? 'ADMIN' : (isUnlimited ? 'ACTIVE' : 'INACTIVE');
  String get membershipLevel => isUnlimited ? 'Unlimited' : 'Standard';

  List<Map<String, dynamic>> get eventCounters =>
      TabsBackend.decodeProfileList(eventCountersRaw);
  List<Map<String, dynamic>> get counterHistory =>
      TabsBackend.decodeProfileList(counterHistoryRaw);
  List<Map<String, dynamic>> get medications =>
      TabsBackend.decodeProfileList(medicationsRaw);
  List<Map<String, dynamic>> get conditions =>
      TabsBackend.decodeProfileList(conditionsRaw);

  SettingsProfileData copyWith({
    String? nickname,
    String? tag,
    String? userContext,
    String? knowledgeBase,
    String? professionalUpdates,
    int? age,
    double? heightCm,
    double? weightKg,
    String? gender,
    bool? autoAiSuggestions,
    bool? shareDataWithFriends,
    bool? hrSpikeAlertsEnabled,
    int? spikeThreshold,
    bool? hrDeltaEnabled,
    int? spikeDeltaThreshold,
    bool? habitReminderEnabled,
    bool? projectReminderEnabled,
    bool? eventReminderEnabled,
    String? eventCountersRaw,
    String? counterHistoryRaw,
    String? medicationsRaw,
    String? conditionsRaw,
  }) {
    return SettingsProfileData(
      isUnlimited: isUnlimited,
      isAdmin: isAdmin,
      nickname: nickname ?? this.nickname,
      tag: tag ?? this.tag,
      userContext: userContext ?? this.userContext,
      knowledgeBase: knowledgeBase ?? this.knowledgeBase,
      professionalUpdates: professionalUpdates ?? this.professionalUpdates,
      age: age ?? this.age,
      heightCm: heightCm ?? this.heightCm,
      weightKg: weightKg ?? this.weightKg,
      gender: gender ?? this.gender,
      autoAiSuggestions: autoAiSuggestions ?? this.autoAiSuggestions,
      shareDataWithFriends: shareDataWithFriends ?? this.shareDataWithFriends,
      hrSpikeAlertsEnabled: hrSpikeAlertsEnabled ?? this.hrSpikeAlertsEnabled,
      spikeThreshold: spikeThreshold ?? this.spikeThreshold,
      hrDeltaEnabled: hrDeltaEnabled ?? this.hrDeltaEnabled,
      spikeDeltaThreshold: spikeDeltaThreshold ?? this.spikeDeltaThreshold,
      habitReminderEnabled: habitReminderEnabled ?? this.habitReminderEnabled,
      projectReminderEnabled:
          projectReminderEnabled ?? this.projectReminderEnabled,
      eventReminderEnabled: eventReminderEnabled ?? this.eventReminderEnabled,
      eventCountersRaw: eventCountersRaw ?? this.eventCountersRaw,
      counterHistoryRaw: counterHistoryRaw ?? this.counterHistoryRaw,
      medicationsRaw: medicationsRaw ?? this.medicationsRaw,
      conditionsRaw: conditionsRaw ?? this.conditionsRaw,
      insights: insights,
    );
  }

  /// Parses a full sync-pull body. Null body → honest defaults
  /// (free/standard membership, native DataStore defaults for toggles).
  factory SettingsProfileData.fromPull(Map<String, dynamic>? body) {
    if (body == null) return const SettingsProfileData();
    final profile = body['profile'];
    final p = profile is Map<String, dynamic> ? profile : const <String, dynamic>{};
    final isAdmin = body['isAdmin'] == true;
    final insightsRaw = body['insights'];
    final insights = <QuickLogInsight>[];
    if (insightsRaw is List) {
      for (final i in insightsRaw) {
        if (i is Map<String, dynamic>) {
          try {
            insights.add(QuickLogInsight.fromJson(i));
          } catch (_) {}
        }
      }
    }
    return SettingsProfileData(
      isAdmin: isAdmin,
      isUnlimited: body['isUnlimited'] == true || isAdmin,
      nickname: _asString(body['nickname']),
      tag: _asString(body['tag']),
      userContext: _asString(p['userContext']),
      knowledgeBase: _asString(p['knowledgeBase']),
      professionalUpdates: _asString(p['professionalUpdates']),
      age: _asInt(p['age']),
      heightCm: _asDouble(p['heightCm']),
      weightKg: _asDouble(p['weightKg']),
      gender: _asString(p['gender']),
      autoAiSuggestions: _asBool(p['autoAiSuggestions'], false),
      shareDataWithFriends: _asBool(p['shareDataWithFriends'], true),
      hrSpikeAlertsEnabled: _asBool(p['hrSpikeAlertsEnabled'], false),
      spikeThreshold: _asInt(p['spikeThreshold']) ?? 120,
      hrDeltaEnabled: _asBool(p['hrDeltaEnabled'], false),
      spikeDeltaThreshold: _asInt(p['spikeDeltaThreshold']) ?? 30,
      habitReminderEnabled: _asBool(p['habitReminderEnabled'], false),
      projectReminderEnabled: _asBool(p['projectReminderEnabled'], true),
      eventReminderEnabled: _asBool(p['eventReminderEnabled'], true),
      eventCountersRaw: _asRaw(p['eventCounters']),
      counterHistoryRaw: _asRaw(p['counterHistory']),
      medicationsRaw: _asRaw(p['medications']),
      conditionsRaw: _asRaw(p['conditions']),
      insights: insights,
    );
  }

  static String _asString(dynamic v) => v == null ? '' : '$v';
  static String _asRaw(dynamic v) {
    if (v == null) return '';
    if (v is String) return v;
    // Already-decoded list/map: re-encode so decodeProfileList sees
    // the same JSON-string shape native stores.
    try {
      return jsonEncode(v);
    } catch (_) {
      return '';
    }
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static bool _asBool(dynamic v, bool fallback) {
    if (v is bool) return v;
    if (v is String) {
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    if (v is num) return v != 0;
    return fallback;
  }
}

/// One event counter (native `EventCounterDto`, SettingsViewModel.kt:1659).
class EventCounterItem {
  final String id;
  final String name;
  final int targetDate;
  final bool isUp;
  final bool autoUp;
  final bool isFavorite;
  final bool isArchived;

  const EventCounterItem({
    required this.id,
    required this.name,
    required this.targetDate,
    this.isUp = false,
    this.autoUp = false,
    this.isFavorite = false,
    this.isArchived = false,
  });

  factory EventCounterItem.fromMap(Map<String, dynamic> m) {
    int asInt(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);
    bool asBool(dynamic v) => v == true || v == 'true';
    return EventCounterItem(
      id: '${m['id'] ?? ''}',
      name: '${m['name'] ?? ''}',
      targetDate: asInt(m['targetDate']),
      isUp: asBool(m['isUp']),
      autoUp: asBool(m['autoUp']),
      isFavorite: asBool(m['isFavorite']),
      isArchived: asBool(m['isArchived']),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'targetDate': targetDate,
        'isUp': isUp,
        'autoUp': autoUp,
        'isFavorite': isFavorite,
        'isArchived': isArchived,
      };

  EventCounterItem copyWith({String? name, int? targetDate, bool? isUp, bool? autoUp, bool? isArchived}) =>
      EventCounterItem(
        id: id,
        name: name ?? this.name,
        targetDate: targetDate ?? this.targetDate,
        isUp: isUp ?? this.isUp,
        autoUp: autoUp ?? this.autoUp,
        isFavorite: isFavorite,
        isArchived: isArchived ?? this.isArchived,
      );

  @override
  bool operator ==(Object other) =>
      other is EventCounterItem &&
      other.id == id &&
      other.name == name &&
      other.targetDate == targetDate &&
      other.isUp == isUp &&
      other.autoUp == autoUp &&
      other.isFavorite == isFavorite &&
      other.isArchived == isArchived;

  @override
  int get hashCode =>
      Object.hash(id, name, targetDate, isUp, autoUp, isFavorite, isArchived);

  /// Signed whole calendar days from the target's local calendar day
  /// to today's local calendar day (positive when the target day is
  /// in the past). Computed on UTC-normalized dates built from the
  /// local year/month/day components, so DST transitions (23/25-hour
  /// local days) never shift the count — device-local day boundaries,
  /// matching native `TodayScreen.kt`'s
  /// `ChronoUnit.DAYS.between(targetLocalDate, LocalDate.now())` and
  /// the Settings label's local-midnight semantics. (The previous
  /// millisecond implementation divided a raw ms span by 86400000,
  /// which undercounts by a day whenever the target's time-of-day is
  /// after local midnight — e.g. yesterday 01:00 read as 0 days.)
  int calendarDayDiff({DateTime? now}) {
    final n = now ?? DateTime.now();
    final t = DateTime.fromMillisecondsSinceEpoch(targetDate);
    final todayUtc = DateTime.utc(n.year, n.month, n.day);
    final targetUtc = DateTime.utc(t.year, t.month, t.day);
    return todayUtc.difference(targetUtc).inDays;
  }

  /// Whether this counter counts UP at [now]: explicitly ([isUp]),
  /// or via [autoUp] once the target day has passed (native
  /// `TodayScreen.kt`: `diffDays > 0`; native `SettingsScreen.kt`:
  /// `todayStart > targetDate` — the same boundary in calendar days).
  bool countsUp({DateTime? now}) {
    final diff = calendarDayDiff(now: now);
    return isUp || (autoUp && diff > 0);
  }

  /// Native Today display (TodayScreen.kt rotating counter pager):
  /// the directed day count — up counters show days since the
  /// target, down counters show days until it — clamped at 0, so a
  /// past target without autoUp reads "0 Days / Until", never a
  /// negative number and never the Settings label's absolute value.
  ({int days, bool up}) todayDisplay({DateTime? now}) {
    final diff = calendarDayDiff(now: now);
    final up = isUp || (autoUp && diff > 0);
    final directed = up ? diff : -diff;
    return (days: directed < 0 ? 0 : directed, up: up);
  }

  /// Native label (SettingsScreen.kt:1355-1357): whole days between
  /// local midnight today and the target, "since" when counting up
  /// (explicitly or via autoUp once the day has arrived).
  String daysLabel({DateTime? now}) {
    final days = calendarDayDiff(now: now).abs();
    final up = countsUp(now: now);
    return '$days days ${up ? 'since' : 'until'}';
  }
}

/// The counters Home shows (Round 34): every counter that is not
/// archived, in profile (Settings list) order — native
/// `TodayScreen.kt` filters `quickLogState.eventCounters` with
/// `!it.isArchived` and keeps the stored order, and the Settings
/// list renders active counters in that same order, so Home and
/// Settings always agree. Ended-and-saved counters are REMOVED from
/// the profile list by Settings (they live in counter history), so
/// they can never reach this filter.
List<EventCounterItem> activeEventCounters(
        Iterable<EventCounterItem> counters) =>
    counters.where((c) => !c.isArchived).toList();
