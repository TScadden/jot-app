/// Phase 1, item 5 — correlation engine core (spec
/// `phase1-item5-correlation-spec.md`; copy per Juno's final
/// rulings, 2026-10-28).
///
/// The engine answers one question shape only: on days of kind A,
/// what did the user's recorded outcomes average — and on days of
/// kind B, what did they average? It computes grouped averages
/// over the user's own recorded days for the FIXED registry of
/// five families below. It never computes a correlation
/// coefficient, a delta, a percentage, a p-value, or any searched
/// parameter: thresholds, lags, and windows are the constants of
/// spec §3.3/§4, and no API in this file accepts one from a
/// caller.
///
/// Day-key rule (spec §2.2, binding): biometric/score series keep
/// their calendar date keys (`DailyBiometrics.date`); entry-derived
/// series (feeling, flare, migraine, intake) assign each entry to
/// its ENERGY day (04:00 local start) labeled by the calendar date
/// of its 04:00 start. Every family joins on that label only.
///
/// Zero rule: a stored biometric 0 (sleep/hrv/hr) is an absent
/// day — never grouped, never averaged. A null score is an absent
/// outcome; a day with no score is not a 0.
library;

import 'dart:convert';

import 'correlation_copy.dart';
import 'health_history_store.dart';
import 'quick_log_models.dart';
import 'sleep_need.dart';

// ── Constants (spec §3.3/§3.4/§4 — golden-tested, §8 A5) ──────────

/// Minimum outcome days per group for numbers to render.
const int correlationMinPerGroup = 5;

/// Minimum total outcome days across both groups.
const int correlationMinTotal = 14;

/// Trailing window for F1–F4, in days.
const int correlationWindowDays = 90;

/// F1a split point: under 6 hours of sleep.
const int correlationF1aThresholdMinutes = 360;

/// F5 / item-2 window length, days either side of a change.
const int correlationF5WindowDays = 14;

/// The windowKey for the trailing-90-day families.
const String correlationWindowKeyLast90 = 'last90d';

// ── Record model (pinned — the Patterns UI builds against it) ──────

enum InsightState { numbers, progress, unavailable }

class InsightGroup {
  final String label;

  /// Outcome-day count. In the progress state this is the real
  /// current count; [mean]/[median] are then null.
  final int n;
  final double? mean;
  final double? median;

  const InsightGroup({
    required this.label,
    required this.n,
    this.mean,
    this.median,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'n': n,
        if (mean != null) 'mean': mean,
        if (median != null) 'median': median,
      };

  static InsightGroup? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    double? asDouble(dynamic v) => v is num ? v.toDouble() : null;
    return InsightGroup(
      label: '${raw['label'] ?? ''}',
      n: (raw['n'] as num?)?.toInt() ?? 0,
      mean: asDouble(raw['mean']),
      median: asDouble(raw['median']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InsightGroup &&
      other.label == label &&
      other.n == n &&
      other.mean == mean &&
      other.median == median;

  @override
  int get hashCode => Object.hash(label, n, mean, median);
}

/// F2 incidence outcome: a flare (resp. migraine) was logged on
/// [x] of the [n] assessable days after group A days, and on [y]
/// of the [m] assessable days after group B days. Counts with
/// denominators only — never a percentage (Juno R4).
class IncidenceResult {
  final int x;
  final int n;
  final int y;
  final int m;

  const IncidenceResult({
    required this.x,
    required this.n,
    required this.y,
    required this.m,
  });

  Map<String, dynamic> toJson() => {'x': x, 'n': n, 'y': y, 'm': m};

  static IncidenceResult? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;
    return IncidenceResult(
      x: asInt(raw['x']),
      n: asInt(raw['n']),
      y: asInt(raw['y']),
      m: asInt(raw['m']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IncidenceResult &&
      other.x == x &&
      other.n == n &&
      other.y == y &&
      other.m == m;

  @override
  int get hashCode => Object.hash(x, n, y, m);
}

/// A computed co-occurrence (Juno S5): rendered only when the
/// engine computed it from the same days as the comparison it
/// rides on. Sleep values are mean minutes.
class CoOccurrence {
  final String confounderLabel;
  final String groupADays;
  final String groupBDays;
  final double valueA;
  final double valueB;

  const CoOccurrence({
    required this.confounderLabel,
    required this.groupADays,
    required this.groupBDays,
    required this.valueA,
    required this.valueB,
  });

  Map<String, dynamic> toJson() => {
        'confounderLabel': confounderLabel,
        'groupADays': groupADays,
        'groupBDays': groupBDays,
        'valueA': valueA,
        'valueB': valueB,
      };

  static CoOccurrence? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    double asDouble(dynamic v) => v is num ? v.toDouble() : 0.0;
    return CoOccurrence(
      confounderLabel: '${raw['confounderLabel'] ?? ''}',
      groupADays: '${raw['groupADays'] ?? ''}',
      groupBDays: '${raw['groupBDays'] ?? ''}',
      valueA: asDouble(raw['valueA']),
      valueB: asDouble(raw['valueB']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CoOccurrence &&
      other.confounderLabel == confounderLabel &&
      other.groupADays == groupADays &&
      other.groupBDays == groupBDays &&
      other.valueA == valueA &&
      other.valueB == valueB;

  @override
  int get hashCode =>
      Object.hash(confounderLabel, groupADays, groupBDays, valueA, valueB);
}

/// One secondary outcome on an F1 record (a score component over
/// the primary outcome's groups), with its OWN floor evaluation:
/// a below-floor component is [InsightState.progress] in its own
/// entry even when the primary outcome renders numbers.
class InsightComponentOutcome {
  /// 'scoreSleep' | 'scoreHrv' | 'scoreRestingHr'.
  final String outcomeId;
  final InsightState state;
  final List<InsightGroup> groups;

  const InsightComponentOutcome({
    required this.outcomeId,
    required this.state,
    required this.groups,
  });

  Map<String, dynamic> toJson() => {
        'outcomeId': outcomeId,
        'state': state.name,
        'groups': [for (final g in groups) g.toJson()],
      };

  static InsightComponentOutcome? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final groups = <InsightGroup>[];
    final rawGroups = raw['groups'];
    if (rawGroups is List) {
      for (final g in rawGroups) {
        final parsed = InsightGroup.fromJson(g);
        if (parsed != null) groups.add(parsed);
      }
    }
    return InsightComponentOutcome(
      outcomeId: '${raw['outcomeId'] ?? ''}',
      state: _stateFromName('${raw['state'] ?? ''}'),
      groups: groups,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InsightComponentOutcome &&
      other.outcomeId == outcomeId &&
      other.state == state &&
      _listEquals(other.groups, groups);

  @override
  int get hashCode => Object.hash(outcomeId, state, Object.hashAll(groups));
}

InsightState _stateFromName(String name) => switch (name) {
      'numbers' => InsightState.numbers,
      'unavailable' => InsightState.unavailable,
      _ => InsightState.progress,
    };

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One cached insight: a single family split over a single
/// window, in one of the three honest states. There is NO delta
/// field, by design (Juno R2) — the two group averages stand side
/// by side and nothing else is computed from them.
class InsightRecord {
  /// 'F1'..'F5'.
  final String familyId;

  /// The split within the family: 'F1a'/'F1b' for F1; the F2 split
  /// ids ('fluid-score', 'sodium-score', 'fluid-flare',
  /// 'sodium-flare', 'fluid-migraine', 'sodium-migraine'); 'F3';
  /// 'F4'; for F5, the medication change event's id.
  final String splitId;

  /// 'last90d' or 'event:{eventId}'.
  final String windowKey;

  final InsightState state;

  /// Groups A then B, always in the family's fixed order.
  final List<InsightGroup> groups;

  /// F2 incidence splits only.
  final IncidenceResult? incidence;

  /// F3 only, and only in the numbers state.
  final CoOccurrence? coOccurrence;

  /// F5 only: the item-2 Draft 6 change label. Null for delete
  /// records (Draft 6 has no delete label) and non-F5 records.
  final String? headerLabel;

  /// F5 only: the recorded medication name (the card's heading
  /// when [headerLabel] is null, and carried on every F5 record).
  final String? subjectName;

  /// F1 only: secondary component outcomes over the same groups.
  final List<InsightComponentOutcome> componentOutcomes;

  final int computedAtMs;

  /// The latest day key that contributed data to this record.
  final String throughDate;

  /// Newest input day key + per-series day counts over this
  /// family's inputs (spec §6). A record is stale when a fresh
  /// fingerprint differs.
  final String inputFingerprint;

  const InsightRecord({
    required this.familyId,
    required this.splitId,
    required this.windowKey,
    required this.state,
    required this.groups,
    this.incidence,
    this.coOccurrence,
    this.headerLabel,
    this.subjectName,
    this.componentOutcomes = const [],
    required this.computedAtMs,
    required this.throughDate,
    required this.inputFingerprint,
  });

  /// The insight store's key for this record.
  String get storeKey => correlationRecordKey(familyId, splitId);

  Map<String, dynamic> toJson() => {
        'familyId': familyId,
        'splitId': splitId,
        'windowKey': windowKey,
        'state': state.name,
        'groups': [for (final g in groups) g.toJson()],
        if (incidence != null) 'incidence': incidence!.toJson(),
        if (coOccurrence != null) 'coOccurrence': coOccurrence!.toJson(),
        if (headerLabel != null) 'headerLabel': headerLabel,
        if (subjectName != null) 'subjectName': subjectName,
        if (componentOutcomes.isNotEmpty)
          'componentOutcomes': [
            for (final c in componentOutcomes) c.toJson(),
          ],
        'computedAtMs': computedAtMs,
        'throughDate': throughDate,
        'inputFingerprint': inputFingerprint,
      };

  static InsightRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final groups = <InsightGroup>[];
    final rawGroups = raw['groups'];
    if (rawGroups is List) {
      for (final g in rawGroups) {
        final parsed = InsightGroup.fromJson(g);
        if (parsed != null) groups.add(parsed);
      }
    }
    final components = <InsightComponentOutcome>[];
    final rawComponents = raw['componentOutcomes'];
    if (rawComponents is List) {
      for (final c in rawComponents) {
        final parsed = InsightComponentOutcome.fromJson(c);
        if (parsed != null) components.add(parsed);
      }
    }
    return InsightRecord(
      familyId: '${raw['familyId'] ?? ''}',
      splitId: '${raw['splitId'] ?? ''}',
      windowKey: '${raw['windowKey'] ?? ''}',
      state: _stateFromName('${raw['state'] ?? ''}'),
      groups: groups,
      incidence: IncidenceResult.fromJson(raw['incidence']),
      coOccurrence: CoOccurrence.fromJson(raw['coOccurrence']),
      headerLabel:
          raw['headerLabel'] is String ? raw['headerLabel'] as String : null,
      subjectName:
          raw['subjectName'] is String ? raw['subjectName'] as String : null,
      componentOutcomes: components,
      computedAtMs: (raw['computedAtMs'] as num?)?.toInt() ?? 0,
      throughDate: '${raw['throughDate'] ?? ''}',
      inputFingerprint: '${raw['inputFingerprint'] ?? ''}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InsightRecord &&
      other.familyId == familyId &&
      other.splitId == splitId &&
      other.windowKey == windowKey &&
      other.state == state &&
      _listEquals(other.groups, groups) &&
      other.incidence == incidence &&
      other.coOccurrence == coOccurrence &&
      other.headerLabel == headerLabel &&
      other.subjectName == subjectName &&
      _listEquals(other.componentOutcomes, componentOutcomes) &&
      other.computedAtMs == computedAtMs &&
      other.throughDate == throughDate &&
      other.inputFingerprint == inputFingerprint;

  @override
  int get hashCode => Object.hash(
        familyId,
        splitId,
        windowKey,
        state,
        Object.hashAll(groups),
        incidence,
        coOccurrence,
        headerLabel,
        subjectName,
        Object.hashAll(componentOutcomes),
        computedAtMs,
        throughDate,
        inputFingerprint,
      );
}

/// The insight store's record key: familyId + splitId.
String correlationRecordKey(String familyId, String splitId) =>
    '$familyId/$splitId';

// ── Family registry (spec §3.3 — exactly F1–F5, nothing else) ──────

/// One registry entry. The audit tests (§8 A4/A5) read this table:
/// no family's grouping variable may be a score component or a
/// transform of its outcome, and every threshold/lag/window must
/// equal the spec constants exactly.
class CorrelationFamilyDefinition {
  final String familyId;
  final String splitId;

  /// The series the split groups days BY (a stored biometric, a
  /// derived per-night estimate, or an entry-derived series).
  final String groupingVariable;

  /// The series averaged (or counted, for incidence splits).
  final String outcomeVariable;

  /// 0 = same-day, 1 = next-day. Never scanned, never caller-set.
  final int lagDays;

  /// The trailing window the split reads (F5: item 2's window).
  final int windowDays;

  /// The grouping split point where the family has one (F1a's
  /// 360 sleep minutes); null where the split is categorical or
  /// per-night (F1b).
  final int? threshold;

  const CorrelationFamilyDefinition({
    required this.familyId,
    required this.splitId,
    required this.groupingVariable,
    required this.outcomeVariable,
    required this.lagDays,
    required this.windowDays,
    this.threshold,
  });
}

const List<CorrelationFamilyDefinition> correlationFamilyRegistry = [
  CorrelationFamilyDefinition(
    familyId: 'F1',
    splitId: 'F1a',
    groupingVariable: 'sleepMinutes',
    outcomeVariable: 'dailyScore',
    lagDays: 1,
    windowDays: correlationWindowDays,
    threshold: correlationF1aThresholdMinutes,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F1',
    splitId: 'F1b',
    groupingVariable: 'sleepNeedPerNight',
    outcomeVariable: 'dailyScore',
    lagDays: 1,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F2',
    splitId: 'fluid-score',
    groupingVariable: 'fluidIntakeTargetHit',
    outcomeVariable: 'dailyScore',
    lagDays: 1,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F2',
    splitId: 'sodium-score',
    groupingVariable: 'sodiumIntakeTargetHit',
    outcomeVariable: 'dailyScore',
    lagDays: 1,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F2',
    splitId: 'fluid-flare',
    groupingVariable: 'fluidIntakeTargetHit',
    outcomeVariable: 'flareIncidence',
    lagDays: 1,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F2',
    splitId: 'sodium-flare',
    groupingVariable: 'sodiumIntakeTargetHit',
    outcomeVariable: 'flareIncidence',
    lagDays: 1,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F2',
    splitId: 'fluid-migraine',
    groupingVariable: 'fluidIntakeTargetHit',
    outcomeVariable: 'migraineIncidence',
    lagDays: 1,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F2',
    splitId: 'sodium-migraine',
    groupingVariable: 'sodiumIntakeTargetHit',
    outcomeVariable: 'migraineIncidence',
    lagDays: 1,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F3',
    splitId: 'F3',
    groupingVariable: 'flareDay',
    outcomeVariable: 'dailyScore',
    lagDays: 0,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F4',
    splitId: 'F4',
    groupingVariable: 'dailyRanking',
    outcomeVariable: 'dailyScore',
    lagDays: 0,
    windowDays: correlationWindowDays,
  ),
  CorrelationFamilyDefinition(
    familyId: 'F5',
    splitId: 'F5',
    groupingVariable: 'medicationChange',
    outcomeVariable: 'dailyScore',
    lagDays: 0,
    windowDays: correlationF5WindowDays,
  ),
];

// ── Inputs ─────────────────────────────────────────────────────────

/// One versioned intake target (item 4 spec §4.6 contract):
/// derivations judge each day against the target in force that
/// day — the latest entry whose [effectiveFromDay] is on or
/// before the day. A null quantity means no target for it.
class IntakeTargetHistoryEntry {
  final int? fluidTargetMl;
  final int? sodiumTargetMg;

  /// Day key 'YYYY-MM-DD' the target takes effect from.
  final String effectiveFromDay;

  const IntakeTargetHistoryEntry({
    this.fluidTargetMl,
    this.sodiumTargetMg,
    required this.effectiveFromDay,
  });
}

/// Provider seam for the intake target history (item 4 §4.6).
/// Production defaults return empty until item 4's store lands —
/// see correlation_refresh.dart.
abstract class IntakeTargetHistoryProvider {
  Future<List<IntakeTargetHistoryEntry>> loadTargetHistory();
}

/// One medication field snapshot, in the item 2a event contract's
/// `old` / `new` shape.
class MedFieldSnapshot {
  final String dose;
  final String frequency;
  final String startDate;
  final String endDate;
  final bool isPresent;

  const MedFieldSnapshot({
    required this.dose,
    required this.frequency,
    required this.startDate,
    required this.endDate,
    required this.isPresent,
  });

  static MedFieldSnapshot? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    return MedFieldSnapshot(
      dose: '${raw['dose'] ?? ''}',
      frequency: '${raw['frequency'] ?? ''}',
      startDate: '${raw['startDate'] ?? ''}',
      endDate: '${raw['endDate'] ?? ''}',
      isPresent: raw['isPresent'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'dose': dose,
        'frequency': frequency,
        'startDate': startDate,
        'endDate': endDate,
        'isPresent': isPresent,
      };
}

/// One medication change event, parsed from the item 2a contract
/// JSON — its `toJson` shape: {id, medId, medName, type:
/// start|dose_change|frequency_change|stop|restore|delete|
/// dates_edit, old/new: {dose, frequency, startDate, endDate,
/// isPresent}|null, effectiveDate (String?), recordedAt (epoch
/// ms), source}.
class MedChangeEventInput {
  final String id;
  final String medId;
  final String medName;
  final String type;
  final MedFieldSnapshot? oldSnapshot;
  final MedFieldSnapshot? newSnapshot;
  final String? effectiveDate;
  final int recordedAt;
  final String source;

  const MedChangeEventInput({
    required this.id,
    required this.medId,
    required this.medName,
    required this.type,
    this.oldSnapshot,
    this.newSnapshot,
    this.effectiveDate,
    required this.recordedAt,
    this.source = '',
  });

  factory MedChangeEventInput.fromJson(Map<String, dynamic> json) {
    return MedChangeEventInput(
      id: '${json['id'] ?? ''}',
      medId: '${json['medId'] ?? ''}',
      medName: '${json['medName'] ?? ''}',
      type: '${json['type'] ?? ''}',
      oldSnapshot: MedFieldSnapshot.fromJson(json['old']),
      newSnapshot: MedFieldSnapshot.fromJson(json['new']),
      effectiveDate:
          json['effectiveDate'] is String ? json['effectiveDate'] as String : null,
      recordedAt: (json['recordedAt'] as num?)?.toInt() ?? 0,
      source: '${json['source'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'medId': medId,
        'medName': medName,
        'type': type,
        'old': oldSnapshot?.toJson(),
        'new': newSnapshot?.toJson(),
        'effectiveDate': effectiveDate,
        'recordedAt': recordedAt,
        'source': source,
      };
}

/// Provider seam for medication change events (item 2a contract).
/// Production defaults return empty until a med-event read path
/// lands — see correlation_refresh.dart.
abstract class MedChangeEventProvider {
  Future<List<MedChangeEventInput>> loadMedChangeEvents();
}

/// Everything the pure compute consumes. Assembled by
/// correlation_refresh.dart in production; built by hand in tests.
class CorrelationInputs {
  final Map<String, DailyBiometrics> biometrics;
  final List<QuickLogEntry> entries;
  final List<QuickLogCategory> categories;
  final List<IntakeTargetHistoryEntry> targetHistory;
  final List<MedChangeEventInput> medEvents;

  /// Fallback 'through' day key when no input series has any day.
  final String nowDayKey;

  const CorrelationInputs({
    required this.biometrics,
    required this.entries,
    required this.categories,
    required this.targetHistory,
    required this.medEvents,
    required this.nowDayKey,
  });
}

// ── Day-key helpers ────────────────────────────────────────────────

String _fmtDay(int y, int m, int d) =>
    '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

/// Parses a strict full 'YYYY-MM-DD' day key, or null. (A
/// month-precision 'YYYY-MM' string does NOT parse — F5's anchor
/// rule depends on that distinction.)
DateTime? parseDayKey(String s) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return null;
  final parsed = DateTime.tryParse(s);
  if (parsed == null) return null;
  // Round-trip guard: reject overflow dates like 2026-02-31.
  if (_fmtDay(parsed.year, parsed.month, parsed.day) != s) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

String formatDayKey(DateTime d) => _fmtDay(d.year, d.month, d.day);

/// Day-key arithmetic on labels only (spec §4): [dayKey] ± [days].
String addDaysToDayKey(String dayKey, int days) {
  final parsed = parseDayKey(dayKey);
  if (parsed == null) return dayKey;
  return formatDayKey(parsed.add(Duration(days: days)));
}

/// The energy-day label for an entry timestamp: the calendar date
/// of the energy day's 04:00 local start (the feelingDayStart
/// rule — an entry at 03:59 belongs to the prior labeled day, one
/// at 04:00 to the new one).
String energyDayLabel(int timestampMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final startDate = dt.hour < 4
      ? DateTime(dt.year, dt.month, dt.day - 1)
      : DateTime(dt.year, dt.month, dt.day);
  return _fmtDay(startDate.year, startDate.month, startDate.day);
}

/// Category resolution with resolveSummaryCategoryId's semantics
/// (today_summary.dart): exact name first (case-insensitive),
/// then the fallback id ONLY when a pulled category carries it.
int? resolveCorrelationCategoryId(
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

/// Parses an entry's raw chips string into a chip list, with the
/// flare branch's parsing semantics (parseFlareChips): the JSON
/// list form, the ', '-joined form, and the bare-list rendering
/// all parse to the same list. Never throws.
List<String> parseCorrelationChips(String chips) {
  final raw = chips.trim();
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [
        for (final c in decoded)
          if ('$c'.trim().isNotEmpty) '$c'.trim(),
      ];
    }
  } catch (_) {
    // Fall through to the joined / bare-list shapes.
  }
  var body = raw;
  if (body.startsWith('[') && body.endsWith(']')) {
    body = body.substring(1, body.length - 1);
  }
  return [
    for (final part in body.split(','))
      if (part.trim().replaceAll('"', '').trim().isNotEmpty)
        part.trim().replaceAll('"', '').trim(),
  ];
}

// ── Series derivations ─────────────────────────────────────────────

/// The sleep map for F1: date -> sleepMinutes, including ONLY
/// non-null, > 0 values (the zero rule).
Map<String, int> buildSleepMap(Map<String, DailyBiometrics> biometrics) {
  final out = <String, int>{};
  for (final e in biometrics.entries) {
    final v = e.value.sleepMinutes;
    if (v != null && v > 0) out[e.key] = v;
  }
  return out;
}

/// Feeling derivation: energy day -> Daily Ranking (1–5). An
/// entry counts iff its parsed chips contain 'Daily Ranking', its
/// body matches 'Feeling: N/5' (N in 1..5), and — when the
/// 'Mood & Energy' category resolves (name-first, fallback 6) —
/// its categoryId matches. One value per energy day (the newest
/// entry wins, mirroring the one-check-in-per-day design).
Map<String, int> deriveFeelingByDay(
  List<QuickLogEntry> entries,
  List<QuickLogCategory> categories,
) {
  final moodId = resolveCorrelationCategoryId(
    categories,
    name: 'Mood & Energy',
    fallbackId: 6,
  );
  final pattern = RegExp(r'^Feeling: ([1-5])/5\b');
  final byDay = <String, int>{};
  final newestAt = <String, int>{};
  for (final e in entries) {
    if (moodId != null && e.categoryId != moodId) continue;
    if (!parseCorrelationChips(e.chips).contains('Daily Ranking')) continue;
    final match = pattern.firstMatch(e.body.trim());
    if (match == null) continue;
    final day = energyDayLabel(e.timestamp);
    if (newestAt[day] == null || e.timestamp >= newestAt[day]!) {
      newestAt[day] = e.timestamp;
      byDay[day] = int.parse(match.group(1)!);
    }
  }
  return byDay;
}

/// Flare derivation: the set of energy days carrying a flare
/// record — an entry in the name-resolved Symptoms category
/// (name 'Symptoms', fallback 1) whose parsed chips contain
/// 'Flare Day'. When the category does not resolve, no day is a
/// flare day (hide-rather-than-misfile, the flare pattern).
Set<String> deriveFlareDays(
  List<QuickLogEntry> entries,
  List<QuickLogCategory> categories,
) {
  final symptomsId = resolveCorrelationCategoryId(
    categories,
    name: 'Symptoms',
    fallbackId: 1,
  );
  if (symptomsId == null) return const {};
  final days = <String>{};
  for (final e in entries) {
    if (e.categoryId != symptomsId) continue;
    if (!parseCorrelationChips(e.chips).contains('Flare Day')) continue;
    days.add(energyDayLabel(e.timestamp));
  }
  return days;
}

/// Migraine derivation: the set of energy days carrying a synced
/// migraine record — an entry whose parsed chips contain
/// 'Migraine attack' (the synced entry form, migraine_trends).
Set<String> deriveMigraineDays(List<QuickLogEntry> entries) {
  final days = <String>{};
  for (final e in entries) {
    if (!parseCorrelationChips(e.chips).contains('Migraine attack')) {
      continue;
    }
    days.add(energyDayLabel(e.timestamp));
  }
  return days;
}

/// One energy day's intake totals (item 4 §4.4 derivation).
class IntakeDayTotals {
  final int fluidMl;
  final int sodiumMg;
  final int eventCount;

  const IntakeDayTotals({
    required this.fluidMl,
    required this.sodiumMg,
    required this.eventCount,
  });
}

/// The intake derivation result: per-energy-day totals plus the
/// count of tagged-but-unparseable entries, which are EXCLUDED
/// from the totals and counted (item 4 §4.1 — silent exclusion is
/// how data loss hides).
class IntakeDerivation {
  final Map<String, IntakeDayTotals> byDay;
  final int unparseableCount;

  const IntakeDerivation({required this.byDay, required this.unparseableCount});
}

const Set<String> _intakeKinds = {'Water', 'Electrolyte drink', 'Salt'};

/// Intake derivation (item 4 contract, verbatim): an entry is an
/// intake entry iff its parsed chips contain 'Intake'; its
/// manualText must parse as JSON {v:1, kind, fluidMl?, sodiumMg?}
/// with kind in {Water, Electrolyte drink, Salt}; amounts are
/// integers. Day totals are sums per energy day.
IntakeDerivation deriveIntake(List<QuickLogEntry> entries) {
  final fluid = <String, int>{};
  final sodium = <String, int>{};
  final counts = <String, int>{};
  var unparseable = 0;
  for (final e in entries) {
    if (!parseCorrelationChips(e.chips).contains('Intake')) continue;
    int? fluidMl;
    int? sodiumMg;
    var ok = false;
    try {
      final decoded = jsonDecode(e.manualText);
      if (decoded is Map && decoded['v'] == 1) {
        final kind = decoded['kind'];
        if (kind is String && _intakeKinds.contains(kind)) {
          // Item 4 §4.1: amounts are integers — no floats anywhere
          // in the payload. A present amount that is not a whole
          // number (a fractional num, or a non-num value) returns
          // null here, which the badType check below turns into
          // unparseable: excluded from totals AND counted, like the
          // bad-JSON/string cases. A whole-valued double is treated
          // as the integer it is (JSON "473" decodes to int in Dart,
          // but "473.0" decodes to double 473.0, and JSON encoders
          // vary); only a fractional value is the defect case.
          int? amount(dynamic v) {
            if (v == null) return null;
            if (v is int) return v;
            if (v is double && v.isFinite && v == v.truncateToDouble()) {
              return v.toInt();
            }
            return null;
          }
          final f = amount(decoded['fluidMl']);
          final s = amount(decoded['sodiumMg']);
          final badType = (decoded['fluidMl'] != null && f == null) ||
              (decoded['sodiumMg'] != null && s == null);
          if (!badType) {
            fluidMl = f;
            sodiumMg = s;
            ok = true;
          }
        }
      }
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      unparseable++;
      continue;
    }
    final day = energyDayLabel(e.timestamp);
    fluid[day] = (fluid[day] ?? 0) + (fluidMl ?? 0);
    sodium[day] = (sodium[day] ?? 0) + (sodiumMg ?? 0);
    counts[day] = (counts[day] ?? 0) + 1;
  }
  final byDay = <String, IntakeDayTotals>{
    for (final day in counts.keys)
      day: IntakeDayTotals(
        fluidMl: fluid[day] ?? 0,
        sodiumMg: sodium[day] ?? 0,
        eventCount: counts[day]!,
      ),
  };
  return IntakeDerivation(byDay: byDay, unparseableCount: unparseable);
}

/// The target in force on [day]: the latest history entry whose
/// effectiveFromDay is on or before [day], or null when none is.
IntakeTargetHistoryEntry? intakeTargetForDay(
  List<IntakeTargetHistoryEntry> history,
  String day,
) {
  IntakeTargetHistoryEntry? best;
  for (final h in history) {
    if (h.effectiveFromDay.compareTo(day) <= 0 &&
        (best == null ||
            h.effectiveFromDay.compareTo(best.effectiveFromDay) > 0)) {
      best = h;
    }
  }
  return best;
}

/// Target-hit for one quantity on one day. Null when the day is
/// unclassifiable for the quantity: no intake events that day (a
/// no-data day — item 4's binding rule), or no target in force.
/// Otherwise true when the day's total reached the target.
bool? _quantityHit({
  required IntakeDayTotals? totals,
  required int? target,
  required int total,
}) {
  if (totals == null || totals.eventCount == 0) return null;
  if (target == null) return null;
  return total >= target;
}

// ── Statistics ─────────────────────────────────────────────────────

/// Mean + median of [values] (non-empty). The only statistics the
/// engine computes.
({double mean, double median}) groupStats(List<double> values) {
  final sorted = [...values]..sort();
  final mean = values.reduce((a, b) => a + b) / values.length;
  final mid = sorted.length ~/ 2;
  final median = sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
  return (mean: mean, median: median);
}

/// The shared floor (spec §3.4; D1 for F5): numbers only when
/// EACH group has at least [correlationMinPerGroup] outcome days
/// AND the total is at least [correlationMinTotal].
bool meetsCorrelationFloor(int nA, int nB) =>
    nA >= correlationMinPerGroup &&
    nB >= correlationMinPerGroup &&
    (nA + nB) >= correlationMinTotal;

/// Builds the two groups for a score outcome: numbers state with
/// means/medians at the floor, progress state (real counts, no
/// averages anywhere) below it.
({InsightState state, List<InsightGroup> groups}) _scoreGroups({
  required String labelA,
  required String labelB,
  required List<double> valuesA,
  required List<double> valuesB,
}) {
  if (meetsCorrelationFloor(valuesA.length, valuesB.length)) {
    final a = groupStats(valuesA);
    final b = groupStats(valuesB);
    return (
      state: InsightState.numbers,
      groups: [
        InsightGroup(
            label: labelA, n: valuesA.length, mean: a.mean, median: a.median),
        InsightGroup(
            label: labelB, n: valuesB.length, mean: b.mean, median: b.median),
      ],
    );
  }
  return (
    state: InsightState.progress,
    groups: [
      InsightGroup(label: labelA, n: valuesA.length),
      InsightGroup(label: labelB, n: valuesB.length),
    ],
  );
}

// ── F1b per-night grouping ─────────────────────────────────────────

/// Whether night [date] falls below its OWN Sleep Need: grouped
/// by that night's own `needMinutes` from [evaluateSleepNight]
/// over the FULL sleep map. Null when the night has no usable
/// sleep value or its need cannot be estimated (too few prior
/// nights) — such a night belongs to neither F1b group.
bool? sleepNightBelowNeed(Map<String, int> sleepByDate, String date) {
  final evaluation = evaluateSleepNight(sleepByDate, date);
  if (evaluation == null || evaluation.needMinutes == null) return null;
  return evaluation.asleepMinutes < evaluation.needMinutes!;
}

// ── F5 — the shared medication-window computation ──────────────────
//
// This is THE computation (item 2 spec §3): item 2b's
// before/after panel consumes [computeMedChangeWindows] exactly
// as the engine's F5 family does. There is no private engine
// variant, and the panel must not grow one either.

/// The anchor day for a change event: its effectiveDate when it
/// parses as a full YYYY-MM-DD date; otherwise (null,
/// month-precision YYYY-MM, unparseable) the device-local
/// calendar day of recordedAt.
String medChangeAnchorDay(MedChangeEventInput event) {
  final effective = event.effectiveDate;
  if (effective != null && parseDayKey(effective) != null) return effective;
  final dt = DateTime.fromMillisecondsSinceEpoch(event.recordedAt);
  return _fmtDay(dt.year, dt.month, dt.day);
}

bool _sameMed(MedChangeEventInput a, MedChangeEventInput b) {
  if (a.medId.isNotEmpty && b.medId.isNotEmpty) return a.medId == b.medId;
  return a.medName == b.medName;
}

/// Types whose change day counts in the AFTER window (item 2 §3 /
/// Juno Draft 5): starts and dose changes — with frequency
/// changes and restores in the same class. Stops and deletes
/// count their change day in the BEFORE window.
bool _changeDayInAfter(String type) =>
    type == 'start' ||
    type == 'dose_change' ||
    type == 'frequency_change' ||
    type == 'restore';

/// One window of a medication change comparison.
class MedWindowStats {
  /// Scored days in the window (days with a Daily Score).
  final int n;
  final double? mean;

  /// Whether a neighboring same-med change truncated the window.
  final bool truncated;

  const MedWindowStats({required this.n, this.mean, required this.truncated});
}

/// The before/after windows for one change event.
class MedChangeWindows {
  final String anchorDay;
  final MedWindowStats before;
  final MedWindowStats after;

  const MedChangeWindows({
    required this.anchorDay,
    required this.before,
    required this.after,
  });
}

MedWindowStats _windowStats(
  String startDay,
  String endDay,
  Map<String, DailyBiometrics> biometrics, {
  required bool truncated,
}) {
  final values = <double>[];
  var day = startDay;
  while (day.compareTo(endDay) <= 0) {
    final score = biometrics[day]?.dailyScore;
    if (score != null) values.add(score.toDouble());
    day = addDaysToDayKey(day, 1);
  }
  return MedWindowStats(
    n: values.length,
    mean: values.isEmpty ? null : groupStats(values).mean,
    truncated: truncated,
  );
}

/// Computes the 14-day before/after Daily Score windows for
/// [event] over [biometrics], truncated at neighboring same-med
/// changes from [allEvents] (dates_edit events included — they
/// change the record of a change and so bound their neighbors'
/// windows, per the engine brief).
///
/// Change-day rule: the anchor day is in the AFTER window for
/// start/dose_change/frequency_change/restore, and in the BEFORE
/// window for stop/delete. Truncation: the after window ends the
/// day before the next same-med change's anchor; the before
/// window starts the day after the previous same-med change's
/// anchor.
MedChangeWindows computeMedChangeWindows({
  required MedChangeEventInput event,
  required List<MedChangeEventInput> allEvents,
  required Map<String, DailyBiometrics> biometrics,
}) {
  final anchor = medChangeAnchorDay(event);
  final inAfter = _changeDayInAfter(event.type);

  var beforeStart =
      addDaysToDayKey(anchor, inAfter ? -correlationF5WindowDays : -(correlationF5WindowDays - 1));
  var beforeEnd = addDaysToDayKey(anchor, inAfter ? -1 : 0);
  var afterStart = addDaysToDayKey(anchor, inAfter ? 0 : 1);
  var afterEnd =
      addDaysToDayKey(anchor, inAfter ? correlationF5WindowDays - 1 : correlationF5WindowDays);

  String? prevAnchor;
  String? nextAnchor;
  for (final other in allEvents) {
    if (other.id == event.id && other.recordedAt == event.recordedAt) continue;
    if (!_sameMed(event, other)) continue;
    final otherAnchor = medChangeAnchorDay(other);
    if (otherAnchor.compareTo(anchor) < 0 &&
        (prevAnchor == null || otherAnchor.compareTo(prevAnchor) > 0)) {
      prevAnchor = otherAnchor;
    }
    if (otherAnchor.compareTo(anchor) > 0 &&
        (nextAnchor == null || otherAnchor.compareTo(nextAnchor) < 0)) {
      nextAnchor = otherAnchor;
    }
  }

  var beforeTruncated = false;
  if (prevAnchor != null) {
    final bound = addDaysToDayKey(prevAnchor, 1);
    if (bound.compareTo(beforeStart) > 0) {
      beforeStart = bound;
      beforeTruncated = true;
    }
  }
  var afterTruncated = false;
  if (nextAnchor != null) {
    final bound = addDaysToDayKey(nextAnchor, -1);
    if (bound.compareTo(afterEnd) < 0) {
      afterEnd = bound;
      afterTruncated = true;
    }
  }

  return MedChangeWindows(
    anchorDay: anchor,
    before: _windowStats(beforeStart, beforeEnd, biometrics,
        truncated: beforeTruncated),
    after: _windowStats(afterStart, afterEnd, biometrics,
        truncated: afterTruncated),
  );
}

/// The item-2 Draft 6 header label for an F5 event. Null for
/// delete records — Draft 6 has no delete label; the UI heads
/// those cards with the record's plain subjectName instead.
String? medChangeHeaderLabel(MedChangeEventInput event) {
  final name = event.medName;
  return switch (event.type) {
    'start' =>
      medChangeStartedLabel(name, event.newSnapshot?.dose ?? ''),
    'stop' => medChangeStoppedLabel(name),
    'dose_change' => medChangeDoseLabel(
        name, event.oldSnapshot?.dose ?? '', event.newSnapshot?.dose ?? ''),
    'frequency_change' => medChangeScheduleLabel(name,
        event.oldSnapshot?.frequency ?? '', event.newSnapshot?.frequency ?? ''),
    'restore' =>
      medChangeRestartedLabel(name, event.newSnapshot?.dose ?? ''),
    _ => null,
  };
}

// ── Derived series + fingerprints + the compute entry point ────────

class _Derived {
  final Map<String, int> sleepByDate;
  final Map<String, int> feelingByDay;
  final Set<String> flareDays;
  final Set<String> migraineDays;
  final IntakeDerivation intake;

  /// The latest day key across all input series (the window end
  /// and every record's throughDate, except F5's own rule below).
  final String through;

  /// First day of the trailing-90-day window.
  final String windowStart;

  _Derived._(this.sleepByDate, this.feelingByDay, this.flareDays,
      this.migraineDays, this.intake, this.through, this.windowStart);

  factory _Derived.from(CorrelationInputs inputs) {
    final sleep = buildSleepMap(inputs.biometrics);
    final feeling = deriveFeelingByDay(inputs.entries, inputs.categories);
    final flare = deriveFlareDays(inputs.entries, inputs.categories);
    final migraine = deriveMigraineDays(inputs.entries);
    final intake = deriveIntake(inputs.entries);

    String? latest;
    void consider(String day) {
      if (latest == null || day.compareTo(latest!) > 0) latest = day;
    }

    for (final d in inputs.biometrics.keys) {
      consider(d);
    }
    for (final d in feeling.keys) {
      consider(d);
    }
    for (final d in flare) {
      consider(d);
    }
    for (final d in migraine) {
      consider(d);
    }
    for (final d in intake.byDay.keys) {
      consider(d);
    }
    for (final e in inputs.medEvents) {
      consider(medChangeAnchorDay(e));
    }
    final through = latest ?? inputs.nowDayKey;
    return _Derived._(
      sleep,
      feeling,
      flare,
      migraine,
      intake,
      through,
      addDaysToDayKey(through, -(correlationWindowDays - 1)),
    );
  }

  bool inWindow(String day) =>
      day.compareTo(windowStart) >= 0 && day.compareTo(through) <= 0;

  int countInWindow(Iterable<String> days) => days.where(inWindow).length;
}

String _fingerprint(String familyId, String through, Map<String, int> counts) {
  final keys = counts.keys.toList()..sort();
  return 'v1|$familyId|through:$through|${[
    for (final k in keys) '$k:${counts[k]}',
  ].join('|')}';
}

class _Job {
  final String familyId;
  final String splitId;
  final String fingerprint;
  final InsightRecord Function() build;

  _Job(this.familyId, this.splitId, this.fingerprint, this.build);

  String get key => correlationRecordKey(familyId, splitId);
}

List<_Job> _buildJobs(CorrelationInputs inputs, _Derived d, int computedAtMs) {
  final jobs = <_Job>[];
  final bioInWindow = d.countInWindow(inputs.biometrics.keys);
  final sleepInWindow = d.countInWindow(d.sleepByDate.keys);

  InsightRecord record({
    required String familyId,
    required String splitId,
    required String windowKey,
    required InsightState state,
    required List<InsightGroup> groups,
    required String fingerprint,
    IncidenceResult? incidence,
    CoOccurrence? coOccurrence,
    String? headerLabel,
    String? subjectName,
    List<InsightComponentOutcome> componentOutcomes = const [],
    String? throughDate,
  }) =>
      InsightRecord(
        familyId: familyId,
        splitId: splitId,
        windowKey: windowKey,
        state: state,
        groups: groups,
        incidence: incidence,
        coOccurrence: coOccurrence,
        headerLabel: headerLabel,
        subjectName: subjectName,
        componentOutcomes: componentOutcomes,
        computedAtMs: computedAtMs,
        throughDate: throughDate ?? d.through,
        inputFingerprint: fingerprint,
      );

  // ── F1 — sleep duration → next-day Daily Score ──────────────────
  for (final splitId in const ['F1a', 'F1b']) {
    final fp = _fingerprint('F1', d.through, {
      'bio': bioInWindow,
      'sleep': sleepInWindow,
    });
    jobs.add(_Job('F1', splitId, fp, () {
      final labelA = splitId == 'F1a' ? f1aGroupALabel : f1bGroupALabel;
      final labelB = splitId == 'F1a' ? f1aGroupBLabel : f1bGroupBLabel;
      // Group membership per night (the grouping variable), then
      // each outcome collects over the nights in its groups.
      final nightsA = <String>[];
      final nightsB = <String>[];
      final nights = d.sleepByDate.keys.where(d.inWindow).toList()..sort();
      for (final night in nights) {
        final bool? isA = splitId == 'F1a'
            ? d.sleepByDate[night]! < correlationF1aThresholdMinutes
            : sleepNightBelowNeed(d.sleepByDate, night);
        if (isA == null) continue;
        (isA ? nightsA : nightsB).add(night);
      }
      List<double> outcome(
          List<String> groupNights, int? Function(DailyBiometrics) pick) {
        final values = <double>[];
        for (final night in groupNights) {
          final row = inputs.biometrics[addDaysToDayKey(night, 1)];
          if (row == null) continue;
          final v = pick(row);
          if (v != null) values.add(v.toDouble());
        }
        return values;
      }

      final primary = _scoreGroups(
        labelA: labelA,
        labelB: labelB,
        valuesA: outcome(nightsA, (r) => r.dailyScore),
        valuesB: outcome(nightsB, (r) => r.dailyScore),
      );
      InsightComponentOutcome component(
          String outcomeId, int? Function(DailyBiometrics) pick) {
        final g = _scoreGroups(
          labelA: labelA,
          labelB: labelB,
          valuesA: outcome(nightsA, pick),
          valuesB: outcome(nightsB, pick),
        );
        return InsightComponentOutcome(
          outcomeId: outcomeId,
          state: g.state,
          groups: g.groups,
        );
      }

      final components = <InsightComponentOutcome>[
        component('scoreSleep', (r) => r.scoreSleep),
        component('scoreHrv', (r) => r.scoreHrv),
        component('scoreRestingHr', (r) => r.scoreRestingHr),
      ];
      return record(
        familyId: 'F1',
        splitId: splitId,
        windowKey: correlationWindowKeyLast90,
        state: primary.state,
        groups: primary.groups,
        fingerprint: fp,
        componentOutcomes: components,
      );
    }));
  }

  // ── F2 — intake target-hit → next-day outcomes ──────────────────
  final intakeInWindow = d.countInWindow(d.intake.byDay.keys);
  final flareInWindow = d.countInWindow(d.flareDays);
  final migraineInWindow = d.countInWindow(d.migraineDays);
  // Classification per intake day in the window, per quantity.
  // A null hit is unclassifiable (no-data or no target in force)
  // and lands in NEITHER group (item 4's no-data-day rule).
  final fluidHitByDay = <String, bool>{};
  final sodiumHitByDay = <String, bool>{};
  for (final e in d.intake.byDay.entries) {
    if (!d.inWindow(e.key)) continue;
    final target = intakeTargetForDay(inputs.targetHistory, e.key);
    final fluidHit = _quantityHit(
        totals: e.value, target: target?.fluidTargetMl, total: e.value.fluidMl);
    if (fluidHit != null) fluidHitByDay[e.key] = fluidHit;
    final sodiumHit = _quantityHit(
        totals: e.value,
        target: target?.sodiumTargetMg,
        total: e.value.sodiumMg);
    if (sodiumHit != null) sodiumHitByDay[e.key] = sodiumHit;
  }

  for (final splitId in const [
    'fluid-score',
    'sodium-score',
    'fluid-flare',
    'sodium-flare',
    'fluid-migraine',
    'sodium-migraine',
  ]) {
    final isFluid = splitId.startsWith('fluid');
    final kind = splitId.substring(splitId.indexOf('-') + 1); // score|flare|migraine
    final fp = _fingerprint('F2', d.through, {
      'bio': bioInWindow,
      'intake': intakeInWindow,
      'targets': inputs.targetHistory.length,
      if (kind == 'flare') 'flare': flareInWindow,
      if (kind == 'migraine') 'migraine': migraineInWindow,
    });
    jobs.add(_Job('F2', splitId, fp, () {
      if (d.intake.byDay.isEmpty) {
        // The input feature itself is absent: S7's unavailable
        // state (not a progress state — there is nothing to
        // accumulate counts against).
        return record(
          familyId: 'F2',
          splitId: splitId,
          windowKey: correlationWindowKeyLast90,
          state: InsightState.unavailable,
          groups: const [
            InsightGroup(label: f2GroupALabel, n: 0),
            InsightGroup(label: f2GroupBLabel, n: 0),
          ],
          fingerprint: fp,
        );
      }
      final hitByDay = isFluid ? fluidHitByDay : sodiumHitByDay;
      final daysA = [for (final e in hitByDay.entries) if (e.value) e.key];
      final daysB = [for (final e in hitByDay.entries) if (!e.value) e.key];
      if (kind == 'score') {
        List<double> outcomes(List<String> days) {
          final values = <double>[];
          for (final day in days) {
            final score =
                inputs.biometrics[addDaysToDayKey(day, 1)]?.dailyScore;
            if (score != null) values.add(score.toDouble());
          }
          return values;
        }

        final g = _scoreGroups(
          labelA: f2GroupALabel,
          labelB: f2GroupBLabel,
          valuesA: outcomes(daysA),
          valuesB: outcomes(daysB),
        );
        return record(
          familyId: 'F2',
          splitId: splitId,
          windowKey: correlationWindowKeyLast90,
          state: g.state,
          groups: g.groups,
          fingerprint: fp,
        );
      }
      // Incidence: numerator = group days whose NEXT labeled day
      // carries the outcome record; denominator = group days
      // whose next day is assessable (next day <= latest input
      // day). Floors apply to the denominators.
      final outcomeDays = kind == 'flare' ? d.flareDays : d.migraineDays;
      (int, int) incidenceFor(List<String> days) {
        var x = 0;
        var n = 0;
        for (final day in days) {
          final next = addDaysToDayKey(day, 1);
          if (next.compareTo(d.through) > 0) continue;
          n++;
          if (outcomeDays.contains(next)) x++;
        }
        return (x, n);
      }

      final (x, n) = incidenceFor(daysA);
      final (y, m) = incidenceFor(daysB);
      final state = meetsCorrelationFloor(n, m)
          ? InsightState.numbers
          : InsightState.progress;
      return record(
        familyId: 'F2',
        splitId: splitId,
        windowKey: correlationWindowKeyLast90,
        state: state,
        groups: [
          InsightGroup(label: f2GroupALabel, n: n),
          InsightGroup(label: f2GroupBLabel, n: m),
        ],
        fingerprint: fp,
        incidence: IncidenceResult(x: x, n: n, y: y, m: m),
      );
    }));
  }

  // ── F3 — flare days → same-day Daily Score ──────────────────────
  {
    final fp = _fingerprint('F3', d.through, {
      'bio': bioInWindow,
      'flare': flareInWindow,
      'sleep': sleepInWindow,
    });
    jobs.add(_Job('F3', 'F3', fp, () {
      final daysA = <String>[];
      final daysB = <String>[];
      final valuesA = <double>[];
      final valuesB = <double>[];
      final days = inputs.biometrics.keys.where(d.inWindow).toList()..sort();
      for (final day in days) {
        final score = inputs.biometrics[day]?.dailyScore;
        if (score == null) continue;
        if (d.flareDays.contains(day)) {
          daysA.add(day);
          valuesA.add(score.toDouble());
        } else {
          daysB.add(day);
          valuesB.add(score.toDouble());
        }
      }
      final g = _scoreGroups(
        labelA: f3GroupALabel,
        labelB: f3GroupBLabel,
        valuesA: valuesA,
        valuesB: valuesB,
      );
      CoOccurrence? coOccurrence;
      if (g.state == InsightState.numbers) {
        // S5, computed from the SAME days as the comparison:
        // mean sleep over the flare group days vs the non-flare
        // group days, over days with a usable sleep value.
        List<double> sleeps(List<String> groupDays) => [
              for (final day in groupDays)
                if (d.sleepByDate[day] != null) d.sleepByDate[day]!.toDouble(),
            ];
        final a = sleeps(daysA);
        final b = sleeps(daysB);
        if (a.isNotEmpty && b.isNotEmpty) {
          coOccurrence = CoOccurrence(
            confounderLabel: 'sleep',
            groupADays: 'flare',
            groupBDays: 'non-flare',
            valueA: groupStats(a).mean,
            valueB: groupStats(b).mean,
          );
        }
      }
      return record(
        familyId: 'F3',
        splitId: 'F3',
        windowKey: correlationWindowKeyLast90,
        state: g.state,
        groups: g.groups,
        fingerprint: fp,
        coOccurrence: coOccurrence,
      );
    }));
  }

  // ── F4 — feeling → same-day Daily Score ─────────────────────────
  {
    final fp = _fingerprint('F4', d.through, {
      'bio': bioInWindow,
      'feeling': d.countInWindow(d.feelingByDay.keys),
    });
    jobs.add(_Job('F4', 'F4', fp, () {
      final valuesA = <double>[];
      final valuesB = <double>[];
      final days = d.feelingByDay.keys.where(d.inWindow).toList()..sort();
      for (final day in days) {
        final value = d.feelingByDay[day]!;
        // A 3 is evidence for neither pole; a day with no
        // check-in is absent. Both are excluded structurally.
        if (value != 1 && value != 2 && value != 4 && value != 5) continue;
        final score = inputs.biometrics[day]?.dailyScore;
        if (score == null) continue;
        (value <= 2 ? valuesA : valuesB).add(score.toDouble());
      }
      final g = _scoreGroups(
        labelA: f4GroupALabel,
        labelB: f4GroupBLabel,
        valuesA: valuesA,
        valuesB: valuesB,
      );
      return record(
        familyId: 'F4',
        splitId: 'F4',
        windowKey: correlationWindowKeyLast90,
        state: g.state,
        groups: g.groups,
        fingerprint: fp,
      );
    }));
  }

  // ── F5 — medication change before/after windows ─────────────────
  if (inputs.medEvents.isEmpty) {
    final fp = _fingerprint('F5', d.through, {
      'bio': inputs.biometrics.length,
      'events': 0,
    });
    jobs.add(_Job('F5', 'F5', fp, () {
      return record(
        familyId: 'F5',
        splitId: 'F5',
        windowKey: correlationWindowKeyLast90,
        state: InsightState.unavailable,
        groups: const [
          InsightGroup(label: f5GroupALabel, n: 0),
          InsightGroup(label: f5GroupBLabel, n: 0),
        ],
        fingerprint: fp,
      );
    }));
  } else {
    final eligible = inputs.medEvents.where((e) {
      if (e.type == 'dates_edit') return false; // no F5 record
      final anchor = medChangeAnchorDay(e);
      return d.inWindow(anchor);
    }).toList()
      ..sort((a, b) {
        final byAnchor =
            medChangeAnchorDay(a).compareTo(medChangeAnchorDay(b));
        return byAnchor != 0 ? byAnchor : a.recordedAt.compareTo(b.recordedAt);
      });
    for (final event in eligible) {
      final fp = _fingerprint('F5', d.through, {
        'bio': inputs.biometrics.length,
        'events': inputs.medEvents.length,
        'event': event.recordedAt,
        'eventId': event.id.hashCode,
        'eventType': event.type.hashCode,
        'eventDose': (event.newSnapshot?.dose ?? '').hashCode,
      });
      jobs.add(_Job('F5', event.id, fp, () {
        final windows = computeMedChangeWindows(
          event: event,
          allEvents: inputs.medEvents,
          biometrics: inputs.biometrics,
        );
        final numbers =
            meetsCorrelationFloor(windows.before.n, windows.after.n);
        return record(
          familyId: 'F5',
          splitId: event.id,
          windowKey: 'event:${event.id}',
          state: numbers ? InsightState.numbers : InsightState.progress,
          groups: [
            InsightGroup(
              label: f5GroupALabel,
              n: windows.before.n,
              mean: numbers ? windows.before.mean : null,
            ),
            InsightGroup(
              label: f5GroupBLabel,
              n: windows.after.n,
              mean: numbers ? windows.after.mean : null,
            ),
          ],
          fingerprint: fp,
          headerLabel: medChangeHeaderLabel(event),
          subjectName: event.medName,
        );
      }));
    }
  }

  return jobs;
}

/// The fingerprint of every record the current inputs would
/// produce, keyed by store key (spec §6). Cheap by construction:
/// it derives the series and counts them; it does not compute
/// group statistics. A stored record is stale exactly when its
/// fingerprint differs from the fresh one for its key.
Map<String, String> computeCorrelationFingerprints(CorrelationInputs inputs) {
  final d = _Derived.from(inputs);
  final jobs = _buildJobs(inputs, d, 0);
  return {for (final j in jobs) j.key: j.fingerprint};
}

/// The pure compute entry point: every insight record for
/// [inputs], in fixed registry order (F1→F5; Juno R1 — order is
/// never data-dependent). When [onlySplitKeys] is given, only
/// those records are built (the refresh path's stale-only
/// recompute); fingerprints are unaffected.
List<InsightRecord> computeCorrelationInsights(
  CorrelationInputs inputs, {
  int? computedAtMs,
  Set<String>? onlySplitKeys,
}) {
  final at = computedAtMs ?? DateTime.now().millisecondsSinceEpoch;
  final d = _Derived.from(inputs);
  final jobs = _buildJobs(inputs, d, at);
  return [
    for (final job in jobs)
      if (onlySplitKeys == null || onlySplitKeys.contains(job.key)) job.build(),
  ];
}
