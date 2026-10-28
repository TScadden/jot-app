import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart' show dateStrOf;
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart'
    show feelingDayStart;
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Phase 1, item 4 — salt & fluid tracking with timestamps (spec
/// `phase1-item4-salt-fluid-spec.md`, Oct 28, 2026; copy per Juno's
/// final ruling set, `2026-10-28-phase1-juno-rulings.md`, Item 4).
///
/// Every intake event is an ordinary [QuickLogEntry] in the
/// name-resolved `Hydration` category (name only — NO fallback id,
/// NO category creation; unresolvable → the whole quick-add surface
/// hides, spec §4.1/Q4), identified by the reserved chip tag
/// [intakeTag] (Juno R3, locked), carrying its structured amounts in
/// `manualText` as a `v:1` JSON payload. Derivation reads the
/// payload ONLY, never the body or any free-text prose (§5.4).
/// Writes ride the shipped VC 100107 optimistic outbox: durable
/// local stage first, screen applies instantly, background flush,
/// and a failed push never un-logs. No new store for entries, no
/// new endpoint, no category writes, no profile-blob writes.
///
/// Honesty rules that shape this file (§5): totals are sums of what
/// the user declared and are labeled *logged*; a day with ZERO
/// intake events is a NO-DATA day — never a miss, never a zero
/// (§5.2, the single most important derivation rule); targets are
/// the user's own, versioned by effective energy day, with NO
/// shipped defaults; no hit/miss language ever renders on the
/// totals line (Juno R2).
///
/// All user-visible strings are Juno's final verbatim set for
/// item 4. Do not paraphrase them.

// ── Pinned vocabulary (Juno R3 — LOCKED) ────────────────────────────

/// Reserved tag on every intake record.
const String intakeTag = 'Intake';

/// The existing category intake entries file under, resolved by
/// NAME ONLY (spec §4.1/Q4). No fallback id exists for this
/// feature: a name miss hides the surface rather than misfiling.
const String intakeCategoryName = 'Hydration';

/// Kind vocabulary (Juno R3 — LOCKED), in card/sheet order.
const List<String> intakeKinds = ['Water', 'Electrolyte drink', 'Salt'];

const String intakeKindWater = 'Water';
const String intakeKindElectrolyte = 'Electrolyte drink';
const String intakeKindSalt = 'Salt';

// ── Juno's final verbatim strings (Item 4) ──────────────────────────

/// S1 — Home card title.
const String intakeCardTitle = 'Salt & water';

/// S6 — target provenance line (renders when targets are displayed
/// and inside the targets editor).
const String intakeTargetsProvenance =
    'Targets you set. Tabs does not recommend intake amounts.';

/// S7 — the ONLY label for a day with no intake events.
const String intakeNoDataLabel = 'No intake logged';

/// R4 — first-use seed label.
const String intakeSeedLabel =
    'Preset amounts are examples. Change them to your own.';

/// R5 — helper under the editor's Time field, verbatim, wherever a
/// past time can be entered.
const String intakeTimeHelper =
    'Enter the time as you remember it. Tabs records the time you enter.';

/// The generic save-failure copy the app already uses for a failed
/// local stage (Quick Log / flare sheet) — reused verbatim; there
/// is no intake-specific failure string.
const String intakeStageFailureCopy =
    "Couldn't save that entry on this device. Try again.";

// ── Units (spec §3) ─────────────────────────────────────────────────

/// 1 US gallon = 3,785 mL; 1 fl oz = 29.5735 mL.
const double mlPerFlOz = 29.5735;

/// Salt → sodium at the fixed constant: 1,000 mg salt = 393 mg
/// sodium, applied ONCE at write time into the payload's sodiumMg.
const int sodiumMgPer1000SaltMg = 393;

int flOzToMl(double flOz) => (flOz * mlPerFlOz).round();

int saltMgToSodiumMg(int saltMg) =>
    (saltMg * sodiumMgPer1000SaltMg / 1000).round();

/// Display form for a fluid amount: fl oz (imperial only), one
/// decimal, trailing `.0` stripped (473 mL → `16`, 250 mL → `8.5`).
String formatFlOz(int ml) {
  final oz = ml / mlPerFlOz;
  final rounded = (oz * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) return '${rounded.toInt()}';
  return rounded.toStringAsFixed(1);
}

/// Display form for a salt amount: grams, up to two decimals,
/// trailing zeros stripped (1,000 mg → `1`, 250 mg → `0.25`).
String formatSaltGrams(int saltMg) {
  final g = saltMg / 1000;
  var s = g.toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

/// Display form for a sodium amount: integer mg with thousands
/// separators (1500 → `1,500`).
String formatMg(int mg) {
  final digits = mg.abs().toString();
  final buf = StringBuffer(mg < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}

// ── Category resolution (spec §4.1/Q4 — name only) ──────────────────

/// Resolves the Hydration category id from the pulled category set
/// by exact name (case-insensitive). There is deliberately NO
/// fallback id and NO creation: null means the intake surface
/// hides.
int? resolveIntakeCategoryId(List<QuickLogCategory> categories) {
  for (final c in categories) {
    if (c.name.trim().toLowerCase() == intakeCategoryName.toLowerCase()) {
      return c.id;
    }
  }
  return null;
}

// ── Chip parsing (defensive — flare's parseFlareChips shape) ────────

/// Parses an entry's raw chips string into a chip list. The intake
/// writer uses the JSON-list form; other writers in the tree use a
/// `', '`-joined string, and pulls can carry a bare-list rendering.
/// All shapes parse to the same list so the tag check never
/// misclassifies. Never throws.
List<String> parseIntakeChips(String chips) {
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

/// True when [entry]'s parsed chips contain the reserved
/// [intakeTag]. This — plus a parseable payload — is the intake
/// identity; the body text is never consulted (§5.4).
bool isIntakeEntry(QuickLogEntry entry) =>
    parseIntakeChips(entry.chips).contains(intakeTag);

/// The chips string for an intake commit: JSON-list form,
/// `["Intake", kind]`.
String intakeChips(String kind) => jsonEncode([intakeTag, kind]);

// ── Payload (spec §4.1) ─────────────────────────────────────────────

/// The structured payload carried in an intake entry's
/// `manualText`: `{v:1, kind, fluidMl?, sodiumMg?}` with integer
/// amounts (mL, mg) — no floats, so totals are exact sums.
///
/// [saltMg] is a declared-input extension field for salt events:
/// the grams the user entered, kept so the editor can re-display
/// them instead of a back-computed rounding. Derivation NEVER reads
/// [saltMg] — a salt event's sodium contribution is the [sodiumMg]
/// computed once at write time by [saltMgToSodiumMg] (or entered
/// directly).
class IntakePayload {
  final String kind;
  final int? fluidMl;
  final int? sodiumMg;
  final int? saltMg;

  const IntakePayload({
    required this.kind,
    this.fluidMl,
    this.sodiumMg,
    this.saltMg,
  });

  Map<String, dynamic> toJson() => {
        'v': 1,
        'kind': kind,
        if (fluidMl != null) 'fluidMl': fluidMl,
        if (sodiumMg != null) 'sodiumMg': sodiumMg,
        if (saltMg != null) 'saltMg': saltMg,
      };

  String encode() => jsonEncode(toJson());

  /// Parses a payload, or null when absent/corrupt/wrong-version/
  /// unknown-kind — the caller counts that as an excluded record
  /// (visible, never silently dropped, §4.1).
  static IntakePayload? tryParse(String manualText) {
    final raw = manualText.trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != 1) return null;
      final kind = decoded['kind'];
      if (kind is! String || !intakeKinds.contains(kind)) return null;
      // §4.1 amounts are integers: a float, a numeric string, or a
      // negative amount is NOT a valid amount — the payload is
      // invalid (excluded + counted), never coerced.
      int? amount(String key) {
        final v = decoded[key];
        if (v is int && v >= 0) return v;
        return null;
      }

      // A present-but-unparseable amount corrupts the payload.
      for (final key in const ['fluidMl', 'sodiumMg', 'saltMg']) {
        if (decoded.containsKey(key) && amount(key) == null) return null;
      }
      return IntakePayload(
        kind: kind,
        fluidMl: amount('fluidMl'),
        sodiumMg: amount('sodiumMg'),
        saltMg: amount('saltMg'),
      );
    } catch (_) {
      return null;
    }
  }
}

/// An editor save's declared values, before they become an entry.
class IntakeDraft {
  final String kind;
  final int? fluidMl;
  final int? sodiumMg;

  /// Salt events only: the salt grams the user entered (mg), when
  /// they entered salt rather than sodium directly.
  final int? saltMg;

  /// The declared intake time (defaults to now; a backfilled past
  /// time is stored exactly as declared, §5.5).
  final DateTime time;

  const IntakeDraft({
    required this.kind,
    this.fluidMl,
    this.sodiumMg,
    this.saltMg,
    required this.time,
  });

  IntakePayload get payload => IntakePayload(
        kind: kind,
        fluidMl: fluidMl,
        sodiumMg: sodiumMg,
        saltMg: saltMg,
      );
}

/// The entry body for an intake event — Juno U1's final patterns,
/// amounts rendered from the payload's logged values. The salt
/// body prints NO computed sodium conversion (Juno's replacement
/// exists for exactly that reason). Display only; never parsed.
String intakeBodyFor(IntakePayload payload) => switch (payload.kind) {
      intakeKindWater => payload.fluidMl == null
          ? intakeKindWater
          : 'Water · ${formatFlOz(payload.fluidMl!)} fl oz',
      intakeKindElectrolyte => payload.sodiumMg == null
          ? intakeKindElectrolyte
          : 'Electrolyte drink · ${formatMg(payload.sodiumMg!)} mg sodium',
      // Salt entered as grams renders Juno's `Salt · {amount} g`.
      // A salt event entered by sodium directly has no Juno-ruled
      // pattern; it renders the value the user actually logged in
      // the electrolyte pattern's shape — never a back-computed
      // gram figure (the mirror of Juno's U1 objection).
      intakeKindSalt => payload.saltMg != null
          ? 'Salt · ${formatSaltGrams(payload.saltMg!)} g'
          : (payload.sodiumMg != null
              ? 'Salt · ${formatMg(payload.sodiumMg!)} mg sodium'
              : intakeKindSalt),
      _ => payload.kind,
    };

/// Builds the exact entry an intake commit writes. [id] comes from
/// the outbox's post-load allocation — never a synchronous max+1.
QuickLogEntry buildIntakeEntry({
  required int id,
  required int categoryId,
  required IntakeDraft draft,
}) {
  final payload = draft.payload;
  return QuickLogEntry(
    id: id,
    categoryId: categoryId,
    body: intakeBodyFor(payload),
    chips: intakeChips(draft.kind),
    manualText: payload.encode(),
    timestamp: draft.time.millisecondsSinceEpoch,
  );
}

/// Rewrites an existing intake entry from an editor save: body +
/// payload together (never one without the other), preserving the
/// entry id and category. The timestamp changes only when the
/// draft's time differs from the entry's — the editor passes the
/// entry's own time back untouched unless the user edited Time.
QuickLogEntry editIntakeEntry(
  QuickLogEntry existing, {
  required IntakeDraft draft,
}) {
  final payload = draft.payload;
  return QuickLogEntry(
    id: existing.id,
    categoryId: existing.categoryId,
    body: intakeBodyFor(payload),
    chips: intakeChips(draft.kind),
    manualText: payload.encode(),
    timestamp: draft.time.millisecondsSinceEpoch,
  );
}

// ── Derivation (pure functions; spec §4.4/§5) ───────────────────────

/// One energy day's intake derivation. [hasData] is the §5.2 line:
/// a day with zero intake EVENTS is no-data — excluded from
/// hit/miss, never a miss, never a zero total. [excludedCount] is
/// the tagged-but-unparseable count for the day (§4.1: exclusion is
/// visible, never silent).
class IntakeDayTotals {
  /// The energy day's start (04:00 local).
  final DateTime dayStart;
  final int fluidMl;
  final int sodiumMg;
  final int eventCount;
  final int excludedCount;

  const IntakeDayTotals({
    required this.dayStart,
    required this.fluidMl,
    required this.sodiumMg,
    required this.eventCount,
    required this.excludedCount,
  });

  bool get hasData => eventCount > 0;
}

/// Aggregates intake totals for the energy day starting at
/// [dayStart] (see [feelingDayStart]). Counts ONLY entries whose
/// chips carry the reserved tag AND whose payload parses; tagged
/// entries with a corrupt/absent payload are excluded and counted.
/// Untagged free-text entries mentioning water or salt contribute
/// nothing (§5.4).
IntakeDayTotals intakeTotalsForDayStart(
  List<QuickLogEntry> entries, {
  required DateTime dayStart,
}) {
  final startMs = dayStart.millisecondsSinceEpoch;
  final endMs = dayStart.add(const Duration(days: 1)).millisecondsSinceEpoch;
  var fluid = 0;
  var sodium = 0;
  var events = 0;
  var excluded = 0;
  for (final e in entries) {
    if (e.timestamp < startMs || e.timestamp >= endMs) continue;
    if (!isIntakeEntry(e)) continue;
    final payload = IntakePayload.tryParse(e.manualText);
    if (payload == null) {
      excluded++;
      continue;
    }
    events++;
    fluid += payload.fluidMl ?? 0;
    sodium += payload.sodiumMg ?? 0;
  }
  return IntakeDayTotals(
    dayStart: dayStart,
    fluidMl: fluid,
    sodiumMg: sodium,
    eventCount: events,
    excludedCount: excluded,
  );
}

/// Totals for the energy day containing [now] (default: now).
IntakeDayTotals intakeTotalsForDay(
  List<QuickLogEntry> entries, {
  DateTime? now,
}) =>
    intakeTotalsForDayStart(entries,
        dayStart: feelingDayStart(now ?? DateTime.now()));

/// The day's parseable intake entries (the card's compact rows),
/// oldest first. Tagged-but-unparseable entries are NOT rows —
/// they carry no honest body-derived amounts — but they are counted
/// by [intakeTotalsForDay]'s excluded count.
List<QuickLogEntry> intakeEntriesForDay(
  List<QuickLogEntry> entries, {
  DateTime? now,
}) {
  final start = feelingDayStart(now ?? DateTime.now());
  final startMs = start.millisecondsSinceEpoch;
  final endMs = start.add(const Duration(days: 1)).millisecondsSinceEpoch;
  final out = <QuickLogEntry>[];
  for (final e in entries) {
    if (e.timestamp < startMs || e.timestamp >= endMs) continue;
    if (!isIntakeEntry(e)) continue;
    if (IntakePayload.tryParse(e.manualText) == null) continue;
    out.add(e);
  }
  out.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return out;
}

// ── Targets (spec §4.6 — user-set, versioned, no defaults) ──────────

/// One target version, in force from [effectiveFromDayMs] (an
/// energy-day start) until the next version. Either component may
/// be unset. There are NO shipped defaults anywhere in this file.
class IntakeTargetVersion {
  final int? fluidTargetMl;
  final int? sodiumTargetMg;
  final int effectiveFromDayMs;

  const IntakeTargetVersion({
    this.fluidTargetMl,
    this.sodiumTargetMg,
    required this.effectiveFromDayMs,
  });

  Map<String, dynamic> toJson() => {
        if (fluidTargetMl != null) 'fluidTargetMl': fluidTargetMl,
        if (sodiumTargetMg != null) 'sodiumTargetMg': sodiumTargetMg,
        'effectiveFromDay': effectiveFromDayMs,
      };

  static IntakeTargetVersion? fromJson(Map<String, dynamic> json) {
    final eff = json['effectiveFromDay'];
    final effMs = eff is num ? eff.toInt() : int.tryParse('$eff');
    if (effMs == null) return null;
    int? amount(String key) {
      final v = json[key];
      if (v is num) return v.toInt();
      return int.tryParse('${json[key]}');
    }

    return IntakeTargetVersion(
      fluidTargetMl: amount('fluidTargetMl'),
      sodiumTargetMg: amount('sodiumTargetMg'),
      effectiveFromDayMs: effMs,
    );
  }
}

/// The targets in force on the energy day starting at [dayStart]:
/// the latest version effective on or before that day, or null when
/// no version covers it (a fresh account has no targets at all).
IntakeTargetVersion? intakeTargetsInForce(
  List<IntakeTargetVersion> versions, {
  required DateTime dayStart,
}) {
  final dayMs = dayStart.millisecondsSinceEpoch;
  IntakeTargetVersion? found;
  for (final v in versions) {
    if (v.effectiveFromDayMs > dayMs) continue;
    if (found == null || v.effectiveFromDayMs >= found.effectiveFromDayMs) {
      found = v;
    }
  }
  return found;
}

/// S4/S5 totals line (Juno's final patterns). With targets:
/// `Logged today: {fluid} of {fluidTarget} water · {sodium} of
/// {sodiumTarget} sodium.` — a component with no target in force
/// renders without its `of {target}` clause. Without any target:
/// the S5 form. This line carries NO hit/miss/goal-met language or
/// state (Juno R2). Callers render [intakeNoDataLabel] instead when
/// the day has no intake events (§5.2).
String intakeTotalsLine({
  required IntakeDayTotals totals,
  required IntakeTargetVersion? targets,
}) {
  final fluid = '${formatFlOz(totals.fluidMl)} fl oz';
  final sodium = '${formatMg(totals.sodiumMg)} mg';
  final fluidTarget = targets?.fluidTargetMl;
  final sodiumTarget = targets?.sodiumTargetMg;
  final fluidPart = fluidTarget == null
      ? '$fluid water'
      : '$fluid of ${formatFlOz(fluidTarget)} fl oz water';
  final sodiumPart = sodiumTarget == null
      ? '$sodium sodium'
      : '$sodium of ${formatMg(sodiumTarget)} mg sodium';
  return 'Logged today: $fluidPart · $sodiumPart.';
}

// ── Z6 adherence summary (spec §4.4 — item 3's contract) ────────────

/// One day of the Z6 summary. Hit flags are null when no target for
/// that component was in force that day.
class IntakeDaySummary {
  /// Energy-day key: the date the energy day starts (`yyyy-MM-dd`).
  final String day;
  final int fluidMl;
  final int sodiumMg;
  final bool? fluidHit;
  final bool? sodiumHit;

  const IntakeDaySummary({
    required this.day,
    required this.fluidMl,
    required this.sodiumMg,
    required this.fluidHit,
    required this.sodiumHit,
  });

  Map<String, dynamic> toJson() => {
        'day': day,
        'fluidMl': fluidMl,
        'sodiumMg': sodiumMg,
        'fluidHit': fluidHit,
        'sodiumHit': sodiumHit,
      };
}

/// The §4.4 summary shape item 3's Z6 consumes:
/// `{daysWithData, fluidHitDays, sodiumHitDays, perDay: [...]}`.
/// No-data days are ABSENT from [perDay] and from every count —
/// they are in neither the hit group nor the miss group (§5.2).
class IntakeAdherenceSummary {
  final int daysWithData;
  final int fluidHitDays;
  final int sodiumHitDays;
  final List<IntakeDaySummary> perDay;

  const IntakeAdherenceSummary({
    required this.daysWithData,
    required this.fluidHitDays,
    required this.sodiumHitDays,
    required this.perDay,
  });

  Map<String, dynamic> toJson() => {
        'daysWithData': daysWithData,
        'fluidHitDays': fluidHitDays,
        'sodiumHitDays': sodiumHitDays,
        'perDay': perDay.map((d) => d.toJson()).toList(),
      };
}

/// Builds the Z6 summary over the inclusive energy-day range
/// [startDay]..[endDay] — each an instant WITHIN its intended
/// energy day, normalized through [feelingDayStart] (note a
/// midnight instant belongs to the energy day that opened at the
/// previous date's 04:00). A day is a hit for a component when its
/// total is >= the target in force THAT day (§4.4/§4.6).
IntakeAdherenceSummary summarizeIntake({
  required List<QuickLogEntry> entries,
  required DateTime startDay,
  required DateTime endDay,
  required List<IntakeTargetVersion> targets,
}) {
  var day = feelingDayStart(startDay);
  final last = feelingDayStart(endDay);
  final perDay = <IntakeDaySummary>[];
  var fluidHits = 0;
  var sodiumHits = 0;
  while (!day.isAfter(last)) {
    final totals = intakeTotalsForDayStart(entries, dayStart: day);
    if (totals.hasData) {
      final inForce = intakeTargetsInForce(targets, dayStart: day);
      final fluidHit = inForce?.fluidTargetMl == null
          ? null
          : totals.fluidMl >= inForce!.fluidTargetMl!;
      final sodiumHit = inForce?.sodiumTargetMg == null
          ? null
          : totals.sodiumMg >= inForce!.sodiumTargetMg!;
      if (fluidHit == true) fluidHits++;
      if (sodiumHit == true) sodiumHits++;
      perDay.add(IntakeDaySummary(
        day: dateStrOf(day),
        fluidMl: totals.fluidMl,
        sodiumMg: totals.sodiumMg,
        fluidHit: fluidHit,
        sodiumHit: sodiumHit,
      ));
    }
    day = day.add(const Duration(days: 1));
  }
  return IntakeAdherenceSummary(
    daysWithData: perDay.length,
    fluidHitDays: fluidHits,
    sodiumHitDays: sodiumHits,
    perDay: perDay,
  );
}

// ── Presets (remembered amounts; spec §4.2, Juno R4) ────────────────

/// The remembered amounts for one kind — the last editor-saved
/// amounts, used by the card's one-tap quick-add. Unconfigured
/// kinds have no preset: their button opens the editor instead of
/// logging an invented amount.
class IntakePreset {
  final String kind;
  final int? fluidMl;
  final int? sodiumMg;
  final int? saltMg;

  const IntakePreset({
    required this.kind,
    this.fluidMl,
    this.sodiumMg,
    this.saltMg,
  });

  bool get isConfigured => switch (kind) {
        intakeKindWater => fluidMl != null,
        intakeKindElectrolyte => sodiumMg != null,
        intakeKindSalt => sodiumMg != null || saltMg != null,
        _ => false,
      };

  Map<String, dynamic> toJson() => {
        if (fluidMl != null) 'fluidMl': fluidMl,
        if (sodiumMg != null) 'sodiumMg': sodiumMg,
        if (saltMg != null) 'saltMg': saltMg,
      };

  static IntakePreset? fromJson(String kind, Map<String, dynamic> json) {
    int? amount(String key) {
      final v = json[key];
      if (v is num) return v.toInt();
      return int.tryParse('${json[key]}');
    }

    return IntakePreset(
      kind: kind,
      fluidMl: amount('fluidMl'),
      sodiumMg: amount('sodiumMg'),
      saltMg: amount('saltMg'),
    );
  }
}

/// All remembered presets plus the R4 seed state. On a fresh
/// install the ONLY seed is a Water preset of 16 fl oz — an
/// unambiguous container size (Juno R4) — with [seedLabelPending]
/// set so the R4 label renders at its first presentation.
/// Electrolyte drink and Salt start unconfigured.
class IntakePresets {
  final Map<String, IntakePreset> byKind;
  final bool seedLabelPending;

  const IntakePresets({required this.byKind, required this.seedLabelPending});

  IntakePreset? operator [](String kind) => byKind[kind];

  /// The first-use seed (Juno R4): Water 16 fl oz only.
  factory IntakePresets.seed() => IntakePresets(
        byKind: {
          intakeKindWater: IntakePreset(
            kind: intakeKindWater,
            fluidMl: flOzToMl(16),
          ),
        },
        seedLabelPending: true,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'seedLabelPending': seedLabelPending,
        'presets': {
          for (final e in byKind.entries) e.key: e.value.toJson(),
        },
      };

  static IntakePresets? fromJson(Map<String, dynamic> json) {
    final raw = json['presets'];
    if (raw is! Map<String, dynamic>) return null;
    final byKind = <String, IntakePreset>{};
    for (final e in raw.entries) {
      if (!intakeKinds.contains(e.key)) continue;
      final v = e.value;
      if (v is Map<String, dynamic>) {
        final preset = IntakePreset.fromJson(e.key, v);
        if (preset != null) byKind[e.key] = preset;
      }
    }
    return IntakePresets(
      byKind: byKind,
      seedLabelPending: json['seedLabelPending'] == true,
    );
  }

  IntakePresets withPreset(IntakePreset preset, {bool? seedLabelPending}) =>
      IntakePresets(
        byKind: {...byKind, preset.kind: preset},
        seedLabelPending: seedLabelPending ?? this.seedLabelPending,
      );

  /// The same presets with [kind]'s remembered amounts removed —
  /// that kind returns to the unconfigured state. [seedLabelPending]
  /// is preserved exactly: deleting a preset (including the R4
  /// seed) is NOT a re-seed and must never re-trigger the R4 label.
  IntakePresets withoutKind(String kind) => IntakePresets(
        byKind: {...byKind}..remove(kind),
        seedLabelPending: seedLabelPending,
      );
}

// ── On-device settings (spec §4.6) ──────────────────────────────────
//
// Targets and remembered preset amounts are device-local settings
// in the app's existing SettingsStore (secure storage) — the
// entries themselves are the durable record. Keys:
//   SettingsStore.intakeTargetsKey  ('intake_targets_v1')
//   SettingsStore.intakePresetsKey  ('intake_presets_v1')

/// Loads/saves intake targets + presets through a [SettingsStore].
/// Every method is fail-safe: a read failure degrades to the honest
/// empty state (no targets; seeded presets only when NOTHING was
/// ever stored), never a throw, never an invented value.
class IntakeSettings {
  final SettingsStore store;

  const IntakeSettings(this.store);

  Future<List<IntakeTargetVersion>> loadTargets() async {
    try {
      final raw = await store.getIntakeTargetsJson();
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <IntakeTargetVersion>[];
      for (final row in decoded) {
        if (row is Map<String, dynamic>) {
          final v = IntakeTargetVersion.fromJson(row);
          if (v != null) out.add(v);
        }
      }
      out.sort((a, b) => a.effectiveFromDayMs.compareTo(b.effectiveFromDayMs));
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveTargets(List<IntakeTargetVersion> versions) async {
    try {
      await store.setIntakeTargetsJson(
        jsonEncode(versions.map((v) => v.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// Appends a target version effective the CURRENT energy day —
  /// past versions are never rewritten (§4.6), so yesterday's
  /// verdict keeps yesterday's target.
  ///
  /// Juno Ratification 2B: an ALL-EMPTY save is a NO-OP — it
  /// appends no version, changes no target in force, and does not
  /// clear targets already in force. (A save setting exactly one
  /// component IS a real version.)
  Future<List<IntakeTargetVersion>> appendTarget({
    int? fluidTargetMl,
    int? sodiumTargetMg,
    DateTime? now,
  }) async {
    if (fluidTargetMl == null && sodiumTargetMg == null) {
      return loadTargets();
    }
    final versions = [...await loadTargets()];
    versions.add(IntakeTargetVersion(
      fluidTargetMl: fluidTargetMl,
      sodiumTargetMg: sodiumTargetMg,
      effectiveFromDayMs:
          feelingDayStart(now ?? DateTime.now()).millisecondsSinceEpoch,
    ));
    await saveTargets(versions);
    return versions;
  }

  /// Loads the remembered presets. Nothing stored → the R4 seed.
  /// Something stored → exactly what was stored (no re-seeding).
  Future<IntakePresets> loadPresets() async {
    try {
      final raw = await store.getIntakePresetsJson();
      if (raw == null || raw.isEmpty) return IntakePresets.seed();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return IntakePresets.fromJson(decoded) ?? IntakePresets.seed();
      }
    } catch (_) {}
    return IntakePresets.seed();
  }

  Future<void> savePresets(IntakePresets presets) async {
    try {
      await store.setIntakePresetsJson(jsonEncode(presets.toJson()));
    } catch (_) {}
  }

  /// Records [draft]'s amounts as the remembered preset for its
  /// kind (the editor's save does this for create AND edit saves).
  Future<IntakePresets> rememberDraft(IntakeDraft draft) async {
    final presets = await loadPresets();
    final updated = presets.withPreset(IntakePreset(
      kind: draft.kind,
      fluidMl: draft.fluidMl,
      sodiumMg: draft.sodiumMg,
      saltMg: draft.saltMg,
    ));
    await savePresets(updated);
    return updated;
  }

  /// Deletes [kind]'s remembered preset amounts (Vera C2 / R4:
  /// every seed is user-editable AND deletable). The kind returns
  /// to the unconfigured state — its quick-add button opens the
  /// editor instead of logging. The removal is persisted (a stored
  /// presets blob with that kind absent), so [loadPresets] returns
  /// exactly what was stored and NEVER re-seeds a deliberately
  /// deleted seed; [IntakePresets.seedLabelPending] is preserved,
  /// so the R4 label is not re-triggered.
  Future<IntakePresets> forgetPreset(String kind) async {
    final presets = await loadPresets();
    if (!presets.byKind.containsKey(kind)) return presets;
    final updated = presets.withoutKind(kind);
    await savePresets(updated);
    return updated;
  }

  /// Marks the R4 seed label as presented (it renders once, at the
  /// seed's first presentation).
  Future<IntakePresets> markSeedLabelShown() async {
    final presets = await loadPresets();
    if (!presets.seedLabelPending) return presets;
    final flipped = IntakePresets(
      byKind: presets.byKind,
      seedLabelPending: false,
    );
    await savePresets(flipped);
    return flipped;
  }
}

// ── Quick-add button labels (S2) ────────────────────────────────────

/// The S2 button label for [kind]: `+ Water {amount}` with the
/// amount from the remembered preset; `+ Electrolyte drink` /
/// `+ Salt` carry no amount in Juno's final pattern. An
/// unconfigured Water preset renders `+ Water` with no amount —
/// tapping it opens the editor rather than logging an invented
/// amount.
String intakeQuickAddLabel(String kind, IntakePreset? preset) =>
    switch (kind) {
      intakeKindWater => preset?.fluidMl == null
          ? '+ Water'
          : '+ Water ${formatFlOz(preset!.fluidMl!)} fl oz',
      intakeKindElectrolyte => '+ Electrolyte drink',
      intakeKindSalt => '+ Salt',
      _ => '+ $kind',
    };

// ── Home card (S1) ──────────────────────────────────────────────────

/// The Home intake card: title S1, one quick-add button per kind
/// (S2, remembered amounts), the totals line (S4 with targets /
/// S5 + `Set targets` without / S7 on a no-data day), the S6
/// provenance line whenever targets are displayed (tap it to edit
/// the targets), an Undo (S8) for the most recent card-logged
/// event, and today's intake entries as compact rows (body + time;
/// tap a row to edit it). All state is derived by the host screen;
/// this widget renders and reports taps only.
class IntakeCard extends StatelessWidget {
  final List<QuickLogEntry> todayEntries;
  final IntakeDayTotals totals;
  final IntakeTargetVersion? targets;
  final IntakePresets presets;
  final bool showSeedLabel;

  /// The most recent card-logged event's id, or null — Undo (S8)
  /// renders only while one stands.
  final int? lastLoggedEntryId;

  final void Function(String kind) onQuickAdd;
  final VoidCallback onOpenEditor;
  final void Function(QuickLogEntry entry) onEditEntry;
  final VoidCallback onUndo;
  final VoidCallback onOpenTargets;

  const IntakeCard({
    super.key,
    required this.todayEntries,
    required this.totals,
    required this.targets,
    required this.presets,
    required this.showSeedLabel,
    required this.lastLoggedEntryId,
    required this.onQuickAdd,
    required this.onOpenEditor,
    required this.onEditEntry,
    required this.onUndo,
    required this.onOpenTargets,
  });

  String _timeLabel(int timestamp) {
    final d = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final amPm = d.hour < 12 ? 'AM' : 'PM';
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final min = d.minute.toString().padLeft(2, '0');
    return '$h12:$min $amPm';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: NotelColors.primary.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: NotelColors.primary.withValues(alpha: 0.22),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    intakeCardTitle,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onOpenEditor,
                  child: const Text(
                    'Log intake',
                    style: TextStyle(
                      color: NotelColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (lastLoggedEntryId != null)
                  TextButton(
                    onPressed: onUndo,
                    child: const Text(
                      'Undo',
                      style: TextStyle(
                        color: NotelColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Quick-add row: one button per kind (S2).
            for (final kind in intakeKinds) ...[
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: () => onQuickAdd(kind),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NotelColors.textPrimary,
                    side: BorderSide(
                      color: NotelColors.primary.withValues(alpha: 0.35),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    intakeQuickAddLabel(kind, presets[kind]),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (showSeedLabel) ...[
              const Text(
                intakeSeedLabel,
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
            ],
            // Totals: S7 on a no-data day (never a manufactured 0);
            // S4 with targets in force, S5 without (§5.2, Juno R2).
            if (!totals.hasData)
              const Text(
                intakeNoDataLabel,
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 13,
                ),
              )
            else ...[
              Text(
                intakeTotalsLine(totals: totals, targets: targets),
                style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (targets != null)
                InkWell(
                  onTap: onOpenTargets,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      intakeTargetsProvenance,
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: onOpenTargets,
                    child: const Text(
                      'Set targets',
                      style: TextStyle(
                        color: NotelColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
            // Today's intake rows: body + time, tap to edit.
            for (final entry in todayEntries) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => onEditEntry(entry),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.body,
                          style: const TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Text(
                        _timeLabel(entry.timestamp),
                        style: const TextStyle(
                          color: NotelColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Editor sheet (S3) ───────────────────────────────────────────────

/// Save callback for the editor sheet: persists [draft] (create
/// when [existing] is null, edit otherwise) and returns true only
/// when the LOCAL stage succeeded — on false the sheet stays open
/// with the app's existing generic save-error copy.
typedef IntakeSave = Future<bool> Function(
  IntakeDraft draft,
  QuickLogEntry? existing,
);

/// Opens the intake editor sheet (`Log intake`, S3).
Future<void> showIntakeEditorSheet({
  required BuildContext context,
  required IntakeSave onSave,
  QuickLogEntry? existing,
  String? initialKind,
  IntakePresets? presets,
  Future<void> Function()? onDelete,
  Future<void> Function(String kind)? onDeletePreset,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => IntakeEditorSheet(
      onSave: onSave,
      existing: existing,
      initialKind: initialKind,
      presets: presets,
      onDelete: onDelete,
      onDeletePreset: onDeletePreset,
    ),
  );
}

/// The one form in the feature: kind selector, the kind's amount
/// fields, and a Time field (default now, editable to a declared
/// past time, R5 helper verbatim beneath it). Salt's Salt (g) and
/// Sodium (mg) are EITHER/OR: entering salt grams computes sodium
/// at the §3 constant; entering sodium directly uses it as entered;
/// one event never counts both.
class IntakeEditorSheet extends StatefulWidget {
  final IntakeSave onSave;
  final QuickLogEntry? existing;
  final String? initialKind;
  final IntakePresets? presets;

  /// Edit mode only: deletes the entry (host mirrors History's
  /// delete semantics). Null hides the action.
  final Future<void> Function()? onDelete;

  /// Create mode only: deletes the remembered preset amounts for
  /// the selected kind (Vera C2 — the preset delete/reset path,
  /// reusing the approved `Delete` string). Null hides the action;
  /// the host (Home) owns the presets store.
  final Future<void> Function(String kind)? onDeletePreset;

  const IntakeEditorSheet({
    super.key,
    required this.onSave,
    this.existing,
    this.initialKind,
    this.presets,
    this.onDelete,
    this.onDeletePreset,
  });

  @override
  State<IntakeEditorSheet> createState() => _IntakeEditorSheetState();
}

class _IntakeEditorSheetState extends State<IntakeEditorSheet> {
  late String _kind;
  late DateTime _time;
  final _water = TextEditingController();
  final _sodium = TextEditingController();
  final _salt = TextEditingController();
  bool _saving = false;
  bool _saveFailed = false;

  IntakePayload? get _existingPayload => widget.existing == null
      ? null
      : IntakePayload.tryParse(widget.existing!.manualText);

  @override
  void initState() {
    super.initState();
    final payload = _existingPayload;
    _kind = payload?.kind ?? widget.initialKind ?? intakeKindWater;
    if (widget.existing != null) {
      _time = DateTime.fromMillisecondsSinceEpoch(widget.existing!.timestamp);
      if (payload != null) {
        if (payload.fluidMl != null) {
          _water.text = formatFlOz(payload.fluidMl!);
        }
        if (payload.sodiumMg != null) _sodium.text = '${payload.sodiumMg}';
        if (payload.saltMg != null) {
          _salt.text = formatSaltGrams(payload.saltMg!);
        }
      }
    } else {
      _time = DateTime.now();
      _prefillFromPreset(_kind, overwrite: true);
    }
    _salt.addListener(_onSaltChanged);
  }

  @override
  void dispose() {
    _water.dispose();
    _sodium.dispose();
    _salt.dispose();
    super.dispose();
  }

  void _prefillFromPreset(String kind, {bool overwrite = false}) {
    final preset = widget.presets?[kind];
    if (preset == null) return;
    void fill(TextEditingController c, String value) {
      if (overwrite || c.text.trim().isEmpty) c.text = value;
    }

    if (preset.fluidMl != null) fill(_water, formatFlOz(preset.fluidMl!));
    if (preset.sodiumMg != null) fill(_sodium, '${preset.sodiumMg}');
    if (preset.saltMg != null) fill(_salt, formatSaltGrams(preset.saltMg!));
  }

  /// Salt grams typed → sodium shows the §3 conversion. (Direct
  /// sodium edits simply leave a value that no longer equals the
  /// conversion, and [_buildDraft] then takes it as entered.)
  void _onSaltChanged() {
    final saltMg = _parseSaltMg();
    if (saltMg == null) return;
    final computed = '${saltMgToSodiumMg(saltMg)}';
    if (_sodium.text != computed) {
      _sodium.text = computed;
    }
  }

  int? _parseWaterMl() {
    final v = double.tryParse(_water.text.trim());
    if (v == null || v < 0) return null;
    return flOzToMl(v);
  }

  int? _parseSodiumMg() {
    final v = int.tryParse(_sodium.text.trim()) ??
        double.tryParse(_sodium.text.trim())?.round();
    if (v == null || v < 0) return null;
    return v;
  }

  int? _parseSaltMg() {
    final v = double.tryParse(_salt.text.trim());
    if (v == null || v < 0) return null;
    return (v * 1000).round();
  }

  bool get _canSave => switch (_kind) {
        intakeKindWater => _parseWaterMl() != null,
        intakeKindElectrolyte => _parseSodiumMg() != null,
        intakeKindSalt => _parseSaltMg() != null || _parseSodiumMg() != null,
        _ => false,
      };

  IntakeDraft _buildDraft() {
    switch (_kind) {
      case intakeKindWater:
        return IntakeDraft(
          kind: _kind,
          fluidMl: _parseWaterMl(),
          time: _time,
        );
      case intakeKindElectrolyte:
        return IntakeDraft(
          kind: _kind,
          fluidMl: _water.text.trim().isEmpty ? null : _parseWaterMl(),
          sodiumMg: _parseSodiumMg(),
          time: _time,
        );
      case intakeKindSalt:
        final saltMg = _parseSaltMg();
        final sodiumMg = _parseSodiumMg();
        // EITHER/OR: the salt path holds when salt was entered and
        // the sodium field still shows exactly its conversion (or
        // nothing); a sodium value the user typed over the
        // conversion is taken as entered, and the salt grams are
        // dropped — never both counted.
        if (saltMg != null &&
            (sodiumMg == null || sodiumMg == saltMgToSodiumMg(saltMg))) {
          return IntakeDraft(
            kind: _kind,
            sodiumMg: saltMgToSodiumMg(saltMg),
            saltMg: saltMg,
            time: _time,
          );
        }
        return IntakeDraft(
          kind: _kind,
          sodiumMg: sodiumMg,
          time: _time,
        );
      default:
        return IntakeDraft(kind: _kind, time: _time);
    }
  }

  Future<void> _save() async {
    if (_saving || !_canSave) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    bool ok;
    try {
      ok = await widget.onSave(_buildDraft(), widget.existing);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _saveFailed = true;
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _time,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _time = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _time.hour,
        _time.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_time),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _time = DateTime(
        _time.year,
        _time.month,
        _time.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  String get _dateLabel => dateStrOf(_time);

  String get _timeOfDayLabel {
    final amPm = _time.hour < 12 ? 'AM' : 'PM';
    final h12 = _time.hour % 12 == 0 ? 12 : _time.hour % 12;
    final min = _time.minute.toString().padLeft(2, '0');
    return '$h12:$min $amPm';
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required ValueKey<String> fieldKey,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: fieldKey,
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(color: NotelColors.textPrimary),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: NotelColors.textSecondary),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: NotelColors.primary.withValues(alpha: 0.5),
            ),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: NotelColors.primary),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Log intake',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: NotelColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'Kind',
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final kind in intakeKinds)
                    ChoiceChip(
                      label: Text(kind),
                      selected: _kind == kind,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() {
                                _kind = kind;
                                if (widget.existing == null) {
                                  _prefillFromPreset(kind);
                                }
                              }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (_kind == intakeKindWater)
                _field(
                  label: 'Water (fl oz)',
                  controller: _water,
                  fieldKey: const ValueKey('intake_water_field'),
                ),
              if (_kind == intakeKindElectrolyte) ...[
                _field(
                  label: 'Water (fl oz)',
                  controller: _water,
                  fieldKey: const ValueKey('intake_water_field'),
                ),
                _field(
                  label: 'Sodium (mg)',
                  controller: _sodium,
                  fieldKey: const ValueKey('intake_sodium_field'),
                ),
              ],
              if (_kind == intakeKindSalt) ...[
                _field(
                  label: 'Salt (g)',
                  controller: _salt,
                  fieldKey: const ValueKey('intake_salt_field'),
                ),
                _field(
                  label: 'Sodium (mg)',
                  controller: _sodium,
                  fieldKey: const ValueKey('intake_sodium_field'),
                ),
              ],
              const Text(
                'Time',
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : _pickDate,
                      child: Text(_dateLabel),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : _pickTime,
                      child: Text(_timeOfDayLabel),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // R5 — verbatim, wherever a past time can be entered.
              const Text(
                intakeTimeHelper,
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (widget.existing != null && widget.onDelete != null)
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () async {
                              final cb = widget.onDelete!;
                              Navigator.of(context).pop();
                              await cb();
                            },
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: NotelColors.error),
                      ),
                    ),
                  // Vera C2 — preset delete/reset (create mode): the
                  // selected kind's remembered amounts are deleted,
                  // returning it to the unconfigured state. Reuses
                  // the approved `Delete` string verbatim.
                  if (widget.existing == null &&
                      widget.onDeletePreset != null &&
                      (widget.presets?[_kind]?.isConfigured ?? false))
                    TextButton(
                      key: const ValueKey('intake_delete_preset'),
                      onPressed: _saving
                          ? null
                          : () async {
                              final cb = widget.onDeletePreset!;
                              final kind = _kind;
                              Navigator.of(context).pop();
                              await cb(kind);
                            },
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: NotelColors.error),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: NotelColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _saving || !_canSave ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Save'),
                  ),
                ],
              ),
              if (_saveFailed) ...[
                const SizedBox(height: 12),
                const Text(
                  intakeStageFailureCopy,
                  style: TextStyle(color: NotelColors.error, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Targets editor ──────────────────────────────────────────────────

/// Save callback for the targets editor: appends a target version
/// effective the current energy day (past versions never rewrite).
typedef IntakeTargetsSave = Future<void> Function({
  int? fluidTargetMl,
  int? sodiumTargetMg,
});

/// Opens the targets editor. Fields are the user's own entered
/// terms — fluid target in fl oz, sodium target in mg (Q2) — with
/// NO defaults pre-filled for a fresh account. S6 renders in it
/// verbatim.
Future<void> showIntakeTargetsSheet({
  required BuildContext context,
  required IntakeTargetsSave onSave,
  IntakeTargetVersion? current,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => IntakeTargetsSheet(onSave: onSave, current: current),
  );
}

class IntakeTargetsSheet extends StatefulWidget {
  final IntakeTargetsSave onSave;
  final IntakeTargetVersion? current;

  const IntakeTargetsSheet({super.key, required this.onSave, this.current});

  @override
  State<IntakeTargetsSheet> createState() => _IntakeTargetsSheetState();
}

class _IntakeTargetsSheetState extends State<IntakeTargetsSheet> {
  final _fluid = TextEditingController();
  final _sodium = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    if (current?.fluidTargetMl != null) {
      _fluid.text = formatFlOz(current!.fluidTargetMl!);
    }
    if (current?.sodiumTargetMg != null) {
      _sodium.text = '${current!.sodiumTargetMg}';
    }
  }

  @override
  void dispose() {
    _fluid.dispose();
    _sodium.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final fluidOz = double.tryParse(_fluid.text.trim());
    final sodiumMg = int.tryParse(_sodium.text.trim()) ??
        double.tryParse(_sodium.text.trim())?.round();
    setState(() => _saving = true);
    await widget.onSave(
      fluidTargetMl:
          (fluidOz == null || fluidOz < 0) ? null : flOzToMl(fluidOz),
      sodiumTargetMg: (sodiumMg == null || sodiumMg < 0) ? null : sodiumMg,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Set targets',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: NotelColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('intake_fluid_target_field'),
                controller: _fluid,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Water (fl oz)',
                  labelStyle:
                      const TextStyle(color: NotelColors.textSecondary),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: NotelColors.primary.withValues(alpha: 0.5),
                    ),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: NotelColors.primary),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('intake_sodium_target_field'),
                controller: _sodium,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Sodium (mg)',
                  labelStyle:
                      const TextStyle(color: NotelColors.textSecondary),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: NotelColors.primary.withValues(alpha: 0.5),
                    ),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: NotelColors.primary),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // S6 — verbatim, in the targets editor.
              const Text(
                intakeTargetsProvenance,
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: NotelColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
