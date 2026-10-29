import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart'
    show feelingDayStart;

/// Phase 1, item 1 — flare-day fast logging (spec
/// `phase1-item1-flare-logging-spec.md`, Oct 28, 2026).
///
/// The user DECLARES a flare day; Tabs never detects, predicts, or
/// infers one. Three taps from Home: open the sheet, pick a severity
/// word, pick a type word (or commit severity-only) — done. The
/// record is an ordinary [QuickLogEntry] in the existing Symptoms
/// category, identified by the reserved chip tag [flareTag], written
/// through the shipped VC 100107 optimistic outbox (durable local
/// stage first, background push, per-entry sync badge in History /
/// Quick Log). No new store, no new endpoint, no category writes.
///
/// All user-visible strings are Juno's reviewed verbatim set (spec
/// §3). Do not paraphrase them.

// ── Pinned vocabularies (spec §3 items 4/6, §4.2; founder Q1/Q3) ────

/// Reserved tag on every flare record (spec §4.2).
const String flareTag = 'Flare Day';

/// The existing category the record files under (founder Q4).
const String flareCategoryName = 'Symptoms';

/// Fallback id for [resolveFlareCategoryId]: used ONLY when a pulled
/// category actually carries id 1 (resolveSummaryCategoryId
/// semantics — NOT the migraine chain's unconditional `?? 1`).
const int flareCategoryFallbackId = 1;

/// Severity words in the READ vocabulary: every word a flare
/// record may legitimately carry. `Bad` stays here forever — it is
/// valid on pre-existing records and displays exactly as recorded
/// (Juno merged-flow Item 10(a)) — but it is never offered or
/// written by the merged flow (see [flareLateSeverities] and
/// [severityForRanking]).
const List<String> flareSeverities = ['Rough', 'Bad', 'Really bad'];

/// The merged flow's WRITING vocabulary for a late-added flare
/// (Juno Item 8): only the two severities a number can declare, in
/// this order. `Bad` is NOT in this list.
const List<String> flareLateSeverities = ['Rough', 'Really bad'];

/// The number-derived severity for a 1–2 ranking (Juno Item 10(a)):
/// 1 → `Really bad`, 2 → `Rough`. Null for 3–5 (no flare derives
/// from those numbers).
String? severityForRanking(int ranking) {
  switch (ranking) {
    case 1:
      return 'Really bad';
    case 2:
      return 'Rough';
    default:
      return null;
  }
}

/// Type words, in sheet order (spec §3 item 6).
const List<String> flareTypes = ['Dizzy', 'Pain', 'Fog', 'Crash'];

/// Icon per type word (spec §2 step 3: icon+label options).
const Map<String, IconData> flareTypeIcons = {
  'Dizzy': Icons.blur_circular,
  'Pain': Icons.healing,
  'Fog': Icons.cloud,
  'Crash': Icons.battery_alert,
};

/// Accessibility label for a late-add severity option (Juno
/// Item 8): `Rough, severity 1 of 2` / `Really bad, severity 2 of 2`.
String flareLateSeveritySemantics(String severity) {
  final index = flareLateSeverities.indexOf(severity);
  return '$severity, severity ${index + 1} of 2';
}

/// The logged-state label (spec §3 item 9):
/// `Flare logged · {severity}` — middle-dot separator, verbatim.
String flareLoggedLabel(String severity) => 'Flare logged · $severity';

/// The Item 11 commit announcement for a flare record:
/// `Flare logged · {severity}` or, with a kind,
/// `Flare logged · {severity} · {kind}`.
String flareLoggedAnnouncement(String severity, {String? type}) =>
    type == null ? flareLoggedLabel(severity) : 'Flare logged · $severity · $type';

// ── Category resolution (spec §4.2, founder Q4) ──────────────────────

/// Resolves the Symptoms category id from the pulled category set:
/// exact name first, then fallback id 1 ONLY when a pulled category
/// actually carries it. Null on a double miss — the caller does not
/// render the button (the check-in's hide-rather-than-misfile
/// honesty pattern).
int? resolveFlareCategoryId(List<QuickLogCategory> categories) =>
    resolveSummaryCategoryId(
      categories,
      name: flareCategoryName,
      fallbackId: flareCategoryFallbackId,
    );

// ── Chip parsing (spec §4.2; defensive, §1.3) ────────────────────────

/// Parses an entry's raw chips string into a chip list. The flare
/// writer uses the check-in's JSON-list form; other writers in the
/// tree use a `', '`-joined string, and pulls can carry a bare-list
/// rendering. All three shapes parse to the same list so identity
/// checks never misclassify: an ordinary Symptoms entry whose joined
/// chips are `Headache, Pain` yields `[Headache, Pain]` — no
/// reserved tag, never a flare record. Never throws.
List<String> parseFlareChips(String chips) {
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

/// True when [chips] (raw string) parses to a list containing the
/// reserved [flareTag].
bool chipsContainFlareTag(String chips) =>
    parseFlareChips(chips).contains(flareTag);

/// The severity word carried by a flare record's chips, or null when
/// the parsed list holds no word from the pinned severity vocabulary.
String? flareSeverityOf(QuickLogEntry entry) {
  for (final chip in parseFlareChips(entry.chips)) {
    if (flareSeverities.contains(chip)) return chip;
  }
  return null;
}

/// The type words carried by a flare record's chips (pinned
/// vocabulary only), in chip order.
List<String> flareTypesOf(QuickLogEntry entry) => [
      for (final chip in parseFlareChips(entry.chips))
        if (flareTypes.contains(chip)) chip,
    ];

// ── Identity (spec §4.2; mirrors hasFeelingCheckIn) ──────────────────

/// The current energy day's flare record, or null: an entry is the
/// day's flare record iff its categoryId equals the resolved
/// Symptoms id, its parsed chip list contains [flareTag], and its
/// timestamp falls inside the current energy day (04:00 local start,
/// the feelingDayStart precedent). When several match (should not
/// happen — one record per day, founder Q2), the newest wins.
QuickLogEntry? findFlareRecord(
  List<QuickLogEntry> entries, {
  required int symptomsCategoryId,
  DateTime? now,
}) {
  final start = feelingDayStart(now ?? DateTime.now());
  final startMs = start.millisecondsSinceEpoch;
  final endMs = start.add(const Duration(days: 1)).millisecondsSinceEpoch;
  QuickLogEntry? found;
  for (final e in entries) {
    if (e.categoryId != symptomsCategoryId) continue;
    if (e.timestamp < startMs || e.timestamp >= endMs) continue;
    if (!chipsContainFlareTag(e.chips)) continue;
    if (found == null || e.timestamp > found.timestamp) found = e;
  }
  return found;
}

/// Whether a flare record exists for the current energy day.
bool hasFlareToday(
  List<QuickLogEntry> entries, {
  required int symptomsCategoryId,
  DateTime? now,
}) =>
    findFlareRecord(entries,
        symptomsCategoryId: symptomsCategoryId, now: now) !=
    null;

// ── Record building (spec §4.2, §3 item 11) ──────────────────────────

/// The entry body for a flare commit (spec §3 item 11): typed —
/// `Flare day · {severity} · {type}`; severity-only —
/// `Flare day · {severity}`. Middle-dot separators, verbatim.
String flareBody({required String severity, String? type}) =>
    type == null ? 'Flare day · $severity' : 'Flare day · $severity · $type';

/// The chips string for a flare commit: the check-in's JSON-list
/// form — `["Flare Day", severity]` or
/// `["Flare Day", severity, type]` (NOT the `', '`-joined form).
String flareChips({required String severity, String? type}) => jsonEncode(
      [flareTag, severity, ?type],
    );

/// Builds the exact entry a flare commit writes. [id] comes from the
/// outbox's post-load allocation (VC 100107 mechanism — never a
/// synchronous max+1 here). Timestamp is the commit time.
QuickLogEntry buildFlareEntry({
  required int id,
  required int categoryId,
  required String severity,
  String? type,
  DateTime? now,
}) {
  return QuickLogEntry(
    id: id,
    categoryId: categoryId,
    body: flareBody(severity: severity, type: type),
    chips: flareChips(severity: severity, type: type),
    manualText: '',
    timestamp: (now ?? DateTime.now()).millisecondsSinceEpoch,
  );
}

/// Amends an existing flare record in place (founder Q2): same id,
/// same timestamp, same category — new severity/type in body and
/// chips. `updatedAt` is stamped fresh by `toSyncJson()` at push
/// time, and the server upsert on `(user_id, local_id)` makes this a
/// single-record update, never a duplicate.
QuickLogEntry amendFlareEntry(
  QuickLogEntry existing, {
  required String severity,
  String? type,
}) {
  return existing.copyWith(
    body: flareBody(severity: severity, type: type),
    chips: flareChips(severity: severity, type: type),
    manualText: '',
  );
}

/// The generic save-failure copy Quick Log already uses for a failed
/// local stage (quick_log_screen.dart) — reused verbatim for every
/// failed local stage in the merged flow, per Juno Item 11 / ruling
/// 3.3b: no new failure strings.
const String flareStageFailureCopy =
    "Couldn't save that entry on this device. Try again.";
