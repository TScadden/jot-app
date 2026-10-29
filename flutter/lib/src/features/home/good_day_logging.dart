import 'dart:convert';

import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart'
    show feelingDayStart;
import 'package:tabs_lab/src/features/home/flare_day_logging.dart'
    show parseFlareChips;

/// Merged check-in flow — the good-day record (Juno ruling Oct 28,
/// 2026, Items 5/6/11).
///
/// Data decision (recorded in the build amendment): a good-day
/// record is a normal [QuickLogEntry] in the existing
/// `Mood & Energy` category — the same category the Daily Ranking
/// check-in files under, resolved by the same resolver
/// (`resolveFeelingCategoryId`, name-first with the native fallback
/// id 6) — identified by the reserved chip tag [goodDayTag]. It
/// deliberately does NOT carry the `Daily Ranking` tag: that tag is
/// History's locked-check-in identity, and a good-day entry must
/// stay an ordinary editable entry. Identity, derivation, and
/// amend-in-place mirror the flare record's pattern exactly
/// (tag-based find over the current energy day, outbox staging,
/// same id on amend).
///
/// All user-visible strings are Juno's verbatim set. Do not
/// paraphrase them.

/// Reserved tag on every good-day record (Juno Item 6: recorded as
/// a data tag, NOT display copy — it never renders anywhere).
const String goodDayTag = 'Good Day';

/// Good options, in sheet order (Juno Item 5). This order is also
/// the record order everywhere: chips, body, summary, announcement.
const List<String> goodOptions = [
  'Energy',
  'Good sleep',
  'Low pain',
  'Clear head',
  'Got things done',
  'Good mood',
];

/// The selected options in sheet order (never tap order), so the
/// same selection set always writes the same record.
List<String> goodOptionsInSheetOrder(Iterable<String> selected) => [
      for (final option in goodOptions)
        if (selected.contains(option)) option,
    ];

/// The entry body / Item 11 announcement for a good-day commit
/// (Juno Item 6): `Good day · {options}` with options joined `, `
/// in sheet order. A zero-option body does not exist — no options
/// means no record.
String goodBody(List<String> options) =>
    'Good day · ${goodOptionsInSheetOrder(options).join(', ')}';

/// The chips string for a good-day commit, in the check-in's
/// JSON-list form: `["Good Day", ...options in sheet order]`.
String goodChips(List<String> options) => jsonEncode(
      [goodDayTag, ...goodOptionsInSheetOrder(options)],
    );

/// True when [chips] (raw string) parses to a list containing the
/// reserved [goodDayTag]. Defensive parsing is shared with the
/// flare identity (`parseFlareChips`).
bool chipsContainGoodDayTag(String chips) =>
    parseFlareChips(chips).contains(goodDayTag);

/// The good options carried by a good-day record's chips, in sheet
/// order (pinned vocabulary only).
List<String> goodOptionsOf(QuickLogEntry entry) => goodOptionsInSheetOrder(
      parseFlareChips(entry.chips).where(goodOptions.contains),
    );

/// The current energy day's good-day record, or null: an entry is
/// the day's good record iff its categoryId equals the resolved
/// Mood & Energy id, its parsed chip list contains [goodDayTag],
/// and its timestamp falls inside the current energy day (04:00
/// local start). Newest wins when several match (should not
/// happen — one per energy day).
QuickLogEntry? findGoodRecord(
  List<QuickLogEntry> entries, {
  required int moodCategoryId,
  DateTime? now,
}) {
  final start = feelingDayStart(now ?? DateTime.now());
  final startMs = start.millisecondsSinceEpoch;
  final endMs = start.add(const Duration(days: 1)).millisecondsSinceEpoch;
  QuickLogEntry? found;
  for (final e in entries) {
    if (e.categoryId != moodCategoryId) continue;
    if (e.timestamp < startMs || e.timestamp >= endMs) continue;
    if (!chipsContainGoodDayTag(e.chips)) continue;
    if (found == null || e.timestamp > found.timestamp) found = e;
  }
  return found;
}

/// Builds the exact entry a good-day commit writes. [id] comes from
/// the outbox's post-load allocation. Timestamp is the commit time.
QuickLogEntry buildGoodEntry({
  required int id,
  required int categoryId,
  required List<String> options,
  DateTime? now,
}) {
  final ordered = goodOptionsInSheetOrder(options);
  return QuickLogEntry(
    id: id,
    categoryId: categoryId,
    body: goodBody(ordered),
    chips: goodChips(ordered),
    manualText: '',
    timestamp: (now ?? DateTime.now()).millisecondsSinceEpoch,
  );
}

/// Amends an existing good-day record in place: same id, same
/// timestamp, same category — new options in body and chips.
QuickLogEntry amendGoodEntry(
  QuickLogEntry existing, {
  required List<String> options,
}) {
  final ordered = goodOptionsInSheetOrder(options);
  return existing.copyWith(
    body: goodBody(ordered),
    chips: goodChips(ordered),
    manualText: '',
  );
}
