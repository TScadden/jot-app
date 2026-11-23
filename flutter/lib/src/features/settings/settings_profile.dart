import 'dart:convert';

import 'package:tabs_lab/src/data/correlation_engine.dart'
    show deriveFeelingByDay;
import 'package:tabs_lab/src/data/focus_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
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

  /// Founder ruling (Nov 18, 2026) — the Developer Terminal / dev
  /// area is TYSON-ONLY: it renders iff the signed-in account's
  /// pulled `dev_access` flag is true. This is NOT the admin flag
  /// (other admins must not see the dev area) and NOT a build
  /// flavor gate. The server sets it true only on Tyson's profile;
  /// it arrives in /api/sync/pull's profile map (alongside
  /// `purchased_freezes`); the top level is also accepted so either
  /// serialization parses. Absent/false → no dev area, ever.
  final bool devAccess;
  final String nickname;
  final String tag;

  /// The user's picked profile picture (Nov 23, 2026): one of
  /// `avatar_01`..`avatar_15` from the pull profile map's
  /// `avatarId` key, or '' when no picture is picked — surfaces
  /// then render their initials fallback, exactly as before.
  final String avatarId;
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

  /// The profile's `focusState` blob, raw — the Project Focus
  /// tests behind the Project Focus reminder gate. Carried in the
  /// same style as [eventCountersRaw]; decoded through the ONE
  /// shared parse path ([focusTests]) so Settings and the
  /// first-run resync can never drift on how a test is read.
  final String focusStateRaw;

  /// The Tabs-day labels (`yyyy-MM-dd`, `energyDayLabel`
  /// attribution) that already carry a feeling check-in — the
  /// check-in reminder gate's input (VC 100138). Derived in
  /// [SettingsProfileData.fromPull] from the pull's top-level
  /// `entries` + `categories` through the ONE shared derivation
  /// ([deriveFeelingByDay], the correlation engine's Daily
  /// Ranking derivation), so Settings and the first-run resync
  /// can never drift on what "checked in" means. Empty when the
  /// pull carried no check-in entries (or no entries at all).
  final Set<String> checkedInDayLabels;

  /// The settled streak state parsed from the pull profile's
  /// `streakState` blob — the streak-countdown reminder gate's
  /// input (Community Added Scope #2). Parsed through the ONE
  /// shared decode ([StreakState.fromJson], the same shape
  /// `TabsBackend.fetchStreakRecord` hands the streak store),
  /// so Settings and the first-run resync can never drift on
  /// what the settled record says. Null when the pull carried
  /// no decodable blob — the countdown is then never armed on
  /// a guess (Home's live settled state, passed from the
  /// streak store, is the fresher source when it exists).
  final StreakState? streakState;
  final List<QuickLogInsight> insights;

  /// Round 65 — knowledge documents from the pull's top-level
  /// `documents` field (metadata only; file bytes move through
  /// GET /api/sync/documents/{id}), newest first — native's
  /// `knowledgeDocuments` flow (Room ORDER BY createdAt DESC).
  final List<KnowledgeDocumentMeta> documents;

  const SettingsProfileData({
    this.isUnlimited = false,
    this.isAdmin = false,
    this.devAccess = false,
    this.nickname = '',
    this.tag = '',
    this.avatarId = '',
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
    this.focusStateRaw = '',
    this.checkedInDayLabels = const {},
    this.streakState,
    this.insights = const [],
    this.documents = const [],
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

  /// The decoded Project Focus tests — THE shared parse path for
  /// the pull's `focusState` blob (decode via
  /// [TabsBackend.decodeProfileList], collect via
  /// [collectFocusTests]). Both production reminder callers feed
  /// the reminder projection from this getter.
  List<FocusTest> get focusTests =>
      collectFocusTests(TabsBackend.decodeProfileList(focusStateRaw));

  SettingsProfileData copyWith({
    String? nickname,
    String? tag,
    String? avatarId,
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
    String? focusStateRaw,
    Set<String>? checkedInDayLabels,
    StreakState? streakState,
    List<KnowledgeDocumentMeta>? documents,
  }) {
    return SettingsProfileData(
      isUnlimited: isUnlimited,
      isAdmin: isAdmin,
      devAccess: devAccess,
      nickname: nickname ?? this.nickname,
      tag: tag ?? this.tag,
      avatarId: avatarId ?? this.avatarId,
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
      focusStateRaw: focusStateRaw ?? this.focusStateRaw,
      checkedInDayLabels: checkedInDayLabels ?? this.checkedInDayLabels,
      streakState: streakState ?? this.streakState,
      documents: documents ?? this.documents,
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
    // VC 100138 — the check-in reminder gate's checked-in labels,
    // from the pull's top-level `entries` + `categories` (the
    // same rows Home's check-in state reads). Malformed rows are
    // skipped, mirroring TabsBackend.fetchLogEntryDtos /
    // fetchLogCategories; a pull with no usable rows yields an
    // empty set, never a throw.
    final checkedInDayLabels = _checkedInDayLabelsFromPull(body);
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
      devAccess: body['dev_access'] == true || p['dev_access'] == true,
      isUnlimited: body['isUnlimited'] == true || isAdmin,
      nickname: _asString(body['nickname']),
      tag: _asString(body['tag']),
      avatarId: p['avatarId'] is String ? p['avatarId'] as String : '',
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
      focusStateRaw: _asRaw(p['focusState']),
      checkedInDayLabels: checkedInDayLabels,
      streakState: _streakStateFromProfile(p),
      documents: KnowledgeDocumentMeta.listFromPull(body),
      insights: insights,
    );
  }

  /// Parses the profile's `streakState` blob (a JSON string, or
  /// an already-decoded map) through [StreakState.fromJson].
  /// Any failure yields null — never a fabricated state.
  static StreakState? _streakStateFromProfile(
      Map<String, dynamic> profile) {
    final raw = profile['streakState'];
    try {
      if (raw is Map<String, dynamic>) return StreakState.fromJson(raw);
      if (raw is String && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return StreakState.fromJson(decoded);
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Parses the pull's `entries` / `categories` and derives the
  /// checked-in Tabs-day label set via [deriveFeelingByDay] (its
  /// keys are exactly the `energyDayLabel` labels of the days
  /// carrying a Daily Ranking check-in).
  static Set<String> _checkedInDayLabelsFromPull(
      Map<String, dynamic> body) {
    final entriesRaw = body['entries'];
    final categoriesRaw = body['categories'];
    if (entriesRaw is! List || entriesRaw.isEmpty) return const {};
    final entries = <QuickLogEntry>[];
    for (final e in entriesRaw) {
      if (e is Map<String, dynamic>) {
        try {
          entries.add(QuickLogEntry.fromJson(e));
        } catch (_) {
          // Skip malformed rows — never fail the whole list.
        }
      }
    }
    if (entries.isEmpty) return const {};
    final categories = <QuickLogCategory>[];
    if (categoriesRaw is List) {
      for (final c in categoriesRaw) {
        if (c is Map<String, dynamic>) {
          try {
            categories.add(QuickLogCategory.fromJson(c));
          } catch (_) {
            // Skip malformed rows — never fail the whole list.
          }
        }
      }
    }
    return deriveFeelingByDay(entries, categories).keys.toSet();
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

  /// When this counter was deleted (epoch ms), or null when it was
  /// not deleted through the Delete action. Delete/restore model
  /// (founder direction, Oct 27, 2026): deleting a counter sets
  /// [isArchived] AND stamps [deletedAt]; restoring clears both.
  /// Rows archived before this model existed carry no stamp —
  /// readers must treat a null stamp as "no known delete date",
  /// never invent one.
  final int? deletedAt;

  const EventCounterItem({
    required this.id,
    required this.name,
    required this.targetDate,
    this.isUp = false,
    this.autoUp = false,
    this.isFavorite = false,
    this.isArchived = false,
    this.deletedAt,
  });

  /// THE unified active predicate (founder direction, Oct 28,
  /// 2026): "deleted is the same as archived" — a counter is
  /// ACTIVE iff it carries NEITHER non-active mark
  /// ([isArchived] false AND [deletedAt] null), and non-active
  /// (it lives in the unified PAST COUNTERS box) iff it carries
  /// EITHER mark. Every consumer — the Settings page split, the
  /// Home rotator (via [activeEventCounters]), the reminder
  /// projection, and the Health Coach context — uses this one
  /// predicate; no site may filter on [isArchived] alone, or a
  /// stamp-only row (deletedAt set, isArchived false) would leak
  /// back into the active list, Home, reminders, and the coach.
  bool get isActive => !isArchived && deletedAt == null;

  /// The complement of [isActive]: this counter belongs in the
  /// unified PAST COUNTERS box.
  bool get isNonActive => !isActive;

  /// The same unified predicate over a RAW profile-blob map, for
  /// the sites that parse maps before (or instead of) building an
  /// [EventCounterItem]. Delegates to [fromMap] so the tolerant
  /// parsing (num | String) and the predicate can never drift.
  static bool counterMapIsActive(Map<String, dynamic> m) =>
      EventCounterItem.fromMap(m).isActive;

  factory EventCounterItem.fromMap(Map<String, dynamic> m) {
    int asInt(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);
    int? asIntOrNull(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    bool asBool(dynamic v) => v == true || v == 'true';
    return EventCounterItem(
      id: '${m['id'] ?? ''}',
      name: '${m['name'] ?? ''}',
      targetDate: asInt(m['targetDate']),
      isUp: asBool(m['isUp']),
      autoUp: asBool(m['autoUp']),
      isFavorite: asBool(m['isFavorite']),
      isArchived: asBool(m['isArchived']),
      deletedAt: asIntOrNull(m['deletedAt']),
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
        // Emitted ONLY when set: the profile blob is stored
        // verbatim server-side (whole-blob replace), so omitting
        // the key on a restore CLEARS the stamp server-side.
        if (deletedAt != null) 'deletedAt': deletedAt,
      };

  /// Sentinel for [copyWith]'s [deletedAt]: an omitted argument
  /// keeps the current stamp; an explicit `deletedAt: null` clears
  /// it (a restore).
  static const Object _deletedAtUnset = Object();

  EventCounterItem copyWith({
    String? name,
    int? targetDate,
    bool? isUp,
    bool? autoUp,
    bool? isArchived,
    Object? deletedAt = _deletedAtUnset,
  }) =>
      EventCounterItem(
        id: id,
        name: name ?? this.name,
        targetDate: targetDate ?? this.targetDate,
        isUp: isUp ?? this.isUp,
        autoUp: autoUp ?? this.autoUp,
        isFavorite: isFavorite,
        isArchived: isArchived ?? this.isArchived,
        deletedAt: identical(deletedAt, _deletedAtUnset)
            ? this.deletedAt
            : deletedAt as int?,
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
      other.isArchived == isArchived &&
      other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hash(
      id, name, targetDate, isUp, autoUp, isFavorite, isArchived, deletedAt);

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
  ///
  /// Round 37: singular/plural — exactly one day reads "1 day",
  /// every other count reads "N days". This is THE shared day-label
  /// formatter: the Settings Event Counters rows render it directly
  /// and Home's rotator shows the same [calendarDayDiff] /
  /// [todayDisplay] numbers, so the grammar lives only here.
  String daysLabel({DateTime? now}) {
    final days = calendarDayDiff(now: now).abs();
    final up = countsUp(now: now);
    final unit = days == 1 ? 'day' : 'days';
    return '$days $unit ${up ? 'since' : 'until'}';
  }
}

/// The counters Home shows (Round 34): every ACTIVE counter, in
/// profile (Settings list) order — native `TodayScreen.kt` filters
/// `quickLogState.eventCounters` with `!it.isArchived` and keeps
/// the stored order, and the Settings list renders active counters
/// in that same order, so Home and Settings always agree.
/// "Active" is the unified predicate ([EventCounterItem.isActive],
/// Oct 28, 2026): neither archived NOR delete-stamped — a
/// stamp-only row must not reach Home. Ended-and-saved counters
/// are REMOVED from the profile list by Settings (they live in
/// counter history), so they can never reach this filter.
List<EventCounterItem> activeEventCounters(
        Iterable<EventCounterItem> counters) =>
    counters.where((c) => c.isActive).toList();

// ── Counter delete tombstones (Oct 2026, native parity) ──────────
//
// Native solved this exact resurrection class in SyncManager.kt:
// its pull merge is `(localList + tombstoneFilteredServer)` with
// `deletedEventCounterIds` persisted locally and self-cleaned once
// the server stops carrying the id. The Flutter port dropped that
// protection; these helpers are its Flutter form, shared by the
// Settings load and Home's counter load. The tombstone set itself
// is persisted account-bound in SettingsStore
// (`getDeletedCounterIds` / `setDeletedCounterIds`) and holds ONLY
// the user's own counter ids — it never leaves the device.
//
// Filtering is BY ID ONLY: a pulled row that is missing the
// `isArchived` key (native-era encoding) passes through untouched
// apart from the id check.

/// Drops every counter whose id is tombstoned. Order preserved.
List<EventCounterItem> filterDeletedCounters(
        Iterable<EventCounterItem> counters, Set<String> tombstones) =>
    tombstones.isEmpty
        ? counters.toList()
        : counters.where((c) => !tombstones.contains(c.id)).toList();

/// The tombstones that are still needed after seeing a pulled
/// server list: exactly those whose id the server list STILL
/// carries. A tombstone whose id is absent from the pulled list
/// has done its job (the delete has fully propagated) and is
/// pruned — the native self-cleaning rule.
Set<String> pruneCounterTombstones(
        Set<String> tombstones, Iterable<String> serverCounterIds) =>
    tombstones.intersection(serverCounterIds.toSet());
