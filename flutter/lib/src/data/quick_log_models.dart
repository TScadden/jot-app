import 'package:flutter/material.dart';

/// Round 19 — Quick Log data models + pure logic.
///
/// DTO shapes mirror the native app exactly:
/// - `LogEntryDtoModel` (native `JotApi.kt`): id, categoryId, body, chips,
///   manualText, timestamp, updatedAt.
/// - `CategoryDtoModel` (native `JotApi.kt`): id, name, icon, colorHex,
///   isDefault, sortOrder.
/// - Sync-pull membership (server `src/routes/sync.js`):
///   `isUnlimited = isAdmin || user.is_unlimited`,
///   `isAdmin = ADMIN_EMAILS.contains(email) || user.is_admin`.
///   Native `SyncManager.pullAllData()` reads these same two fields.
///
/// Pure functions ([todayEntryCount], [recentSuggestions], [cleanChips],
/// [rankCategories]) are ports of native `QuickLogViewModel` /
/// `TemplateAndDefaultsRepository` logic and are unit-tested.

/// GAP-18 (Nov 27, 2026) — sync identity for entries and
/// categories is a STRING that holds one of two schemes:
///
/// - a legacy numeric id (`'42'`), assigned by the server-era
///   per-device maxId+1 allocation. Existing entries and
///   built-in categories keep these ids forever and keep
///   syncing exactly as before.
/// - a client-generated random v4 UUID (see uuid_v4.dart),
///   assigned to every NEW entry and NEW custom category.
///   Two devices logging offline after the same pull can no
///   longer allocate the same id, so neither device's entry
///   can silently overwrite the other's on sync.
///
/// [syncIdWireValue] is the wire form: numeric ids ride as
/// JSON ints (byte-identical to the pre-GAP-18 payloads, so a
/// legacy entry's push is unchanged), UUIDs ride as strings.
/// Pulls may carry either form; [idStringFromJson] accepts both.
String idStringFromJson(dynamic v) =>
    v is num ? '${v.toInt()}' : '${v ?? ''}';

Object syncIdWireValue(String id) => int.tryParse(id) ?? id;

bool isNumericSyncId(String id) => int.tryParse(id) != null;

/// One log entry from `/api/sync/pull` `entries`.
class QuickLogEntry {
  final String id;
  final String categoryId;
  final String body;
  final String chips;
  final String manualText;
  final int timestamp;

  const QuickLogEntry({
    required this.id,
    required this.categoryId,
    required this.body,
    required this.chips,
    required this.manualText,
    required this.timestamp,
  });

  /// Round 42 — copy with edited fields. Edits ALWAYS keep [id]
  /// (the sync endpoint upserts on `(user_id, local_id)`; a new id
  /// would duplicate the entry, a colliding id would overwrite a
  /// different one) and [timestamp] (an edit is not a re-log).
  QuickLogEntry copyWith({
    String? categoryId,
    String? body,
    String? chips,
    String? manualText,
  }) {
    return QuickLogEntry(
      id: id,
      categoryId: categoryId ?? this.categoryId,
      body: body ?? this.body,
      chips: chips ?? this.chips,
      manualText: manualText ?? this.manualText,
      timestamp: timestamp,
    );
  }

  factory QuickLogEntry.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v) =>
        v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return QuickLogEntry(
      id: idStringFromJson(json['id']),
      categoryId: idStringFromJson(json['categoryId']),
      body: '${json['body'] ?? ''}',
      chips: '${json['chips'] ?? ''}',
      manualText: '${json['manualText'] ?? ''}',
      timestamp: asInt(json['timestamp']),
    );
  }

  /// Request body for `POST /api/sync/entries` (native
  /// `SyncEntriesRequest` → server upserts on `(user_id, local_id)`).
  Map<String, dynamic> toSyncJson() => {
        'id': syncIdWireValue(id),
        'categoryId': syncIdWireValue(categoryId),
        'body': body,
        'chips': chips,
        'manualText': manualText,
        'timestamp': timestamp,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };
}

/// One category from `/api/sync/pull` `categories` — the account's REAL
/// category set (server is authoritative; native `SyncManager` inserts the
/// pull's categories into the local DB on every pull). Never hardcoded.
class QuickLogCategory {
  final String id;
  final String name;
  final String icon;
  final String colorHex;
  final bool isDefault;
  final int sortOrder;

  /// GAP-18 — the client's last-known `updated_at` for this row
  /// (ms since epoch; 0 = never stamped). Category pushes carry
  /// it so the server's conflict guard can compare timestamps
  /// instead of clobbering by push order: rows this client
  /// created or edited carry the moment of that change; rows
  /// that merely rode along from a pull echo the pulled value,
  /// so an untouched row never looks newer than it is.
  final int updatedAt;

  const QuickLogCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.colorHex,
    required this.isDefault,
    required this.sortOrder,
    this.updatedAt = 0,
  });

  QuickLogCategory copyWith({
    String? name,
    String? icon,
    String? colorHex,
    bool? isDefault,
    int? sortOrder,
    int? updatedAt,
  }) {
    return QuickLogCategory(
      id: id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      colorHex: colorHex ?? this.colorHex,
      isDefault: isDefault ?? this.isDefault,
      sortOrder: sortOrder ?? this.sortOrder,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory QuickLogCategory.fromJson(Map<String, dynamic> json) {
    final sortOrder = json['sortOrder'];
    final updatedAt = json['updatedAt'] ?? json['updated_at'];
    return QuickLogCategory(
      // GAP-18 server contract: the categories pull returns
      // `id` = the legacy local_id (NULL for UUID categories)
      // plus `clientId` carrying the UUID. The UUID wins when
      // present; a pull from a pre-GAP-18 server has no
      // `clientId` key at all and reads exactly as before.
      id: json['clientId'] != null
          ? idStringFromJson(json['clientId'])
          : idStringFromJson(json['id']),
      name: '${json['name'] ?? 'Untitled'}',
      icon: '${json['icon'] ?? 'circle'}',
      colorHex: '${json['colorHex'] ?? '#CCCCCC'}',
      isDefault: json['isDefault'] == true,
      sortOrder: sortOrder is num ? sortOrder.toInt() : 0,
      updatedAt: updatedAt is num
          ? updatedAt.toInt()
          : int.tryParse('$updatedAt') ?? 0,
    );
  }

  /// Request row for `POST /api/sync/categories` (native
  /// `SyncCategoriesRequest` — full-list replace). GAP-18: the
  /// row now carries a real `updatedAt` for the server's
  /// timestamp conflict guard.
  Map<String, dynamic> toSyncJson() => {
        'id': syncIdWireValue(id),
        'name': name,
        'icon': icon,
        'colorHex': colorHex,
        'isDefault': isDefault,
        'sortOrder': sortOrder,
        'updatedAt': updatedAt,
      };

  /// Parses `#RRGGBB`/`#AARRGGBB`, falling back to Tabs purple —
  /// same fallback rule as native `CategoryChip`.
  Color get color {
    try {
      var hex = colorHex.trim();
      if (hex.startsWith('#')) hex = hex.substring(1);
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return const Color(0xFF7C6EFF);
    }
  }
}

/// One AI insight from `/api/sync/pull` `insights` (server sends
/// `entryId`, so the original entry can be linked honestly).
class QuickLogInsight {
  final String id;
  final String? entryId;
  final String text;
  final String type;
  final int timestamp;

  const QuickLogInsight({
    required this.id,
    required this.entryId,
    required this.text,
    required this.type,
    required this.timestamp,
  });

  factory QuickLogInsight.fromJson(Map<String, dynamic> json) {
    final ts = json['timestamp'];
    return QuickLogInsight(
      id: '${json['id'] ?? ''}',
      entryId: json['entryId']?.toString(),
      text: '${json['text'] ?? ''}',
      type: '${json['type'] ?? ''}',
      timestamp: ts is num ? ts.toInt() : 0,
    );
  }
}

/// Native `LogRepository.getTodayJotCount()`: entries with
/// `timestamp >= local midnight`. A count, not biometrics — the
/// zero rule does not apply (0 today = "No entries yet today").
int todayEntryCount(List<QuickLogEntry> entries, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final midnight = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
  var count = 0;
  for (final e in entries) {
    if (e.timestamp >= midnight) count++;
  }
  return count;
}

/// Port of native
/// `TemplateAndDefaultsRepository.getDeduplicatedRecentSuggestions(10)`:
/// newest-first, deduped on `categoryId + lowercase body`, medication
/// entries kept only when the body names an active (non-archived)
/// medication. `entries` must be newest-first (the sync pull already
/// orders `timestamp DESC`).
List<QuickLogEntry> recentSuggestions(
  List<QuickLogEntry> entries, {
  required Set<String> activeMedicationNames,
  required String? medicationCategoryId,
  int limit = 10,
}) {
  final seen = <String>{};
  final out = <QuickLogEntry>[];
  for (final entry in entries) {
    final key = '${entry.categoryId}_${entry.body.trim().toLowerCase()}';
    if (!seen.add(key)) continue;
    if (medicationCategoryId != null &&
        entry.categoryId == medicationCategoryId) {
      final bodyLower = entry.body.toLowerCase();
      if (!activeMedicationNames.any(bodyLower.contains)) continue;
    }
    out.add(entry);
    if (out.length >= limit) break;
  }
  return out;
}

/// Port of native `QuickLogViewModel.processRawChips`: strip parenthetical
/// groups and `?`, collapse whitespace, cap at 3 words / 20 chars, drop
/// blanks, apply the medication prohibited-terms filter, dedupe
/// case-insensitively.
List<String> cleanChips(List<String> raw, String categoryName) {
  final isMedicationCategory =
      categoryName.trim().toLowerCase() == 'medication' ||
          categoryName.trim().toLowerCase() == 'medications';
  final prohibited = RegExp(
    r'\b(water|gallon|hydration|liquid\s*iv|water\s*boy|compression|garment|worn|wear|handicap|pass|appointment|exercise|rest|sleep|symptom|pain)\b',
    caseSensitive: false,
  );
  final out = <String>[];
  final seenLower = <String>{};
  for (final chip in raw) {
    var cleaned = chip
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll('?', '')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    final words = cleaned.split(' ');
    if (words.length > 3) cleaned = words.take(3).join(' ');
    if (cleaned.length > 20) cleaned = cleaned.substring(0, 20).trim();
    if (cleaned.isEmpty) continue;
    if (isMedicationCategory && prohibited.hasMatch(cleaned)) continue;
    if (!seenLower.add(cleaned.toLowerCase())) continue;
    out.add(cleaned);
  }
  return out;
}

/// Port of native `QuickLogViewModel.rankCategories`: most-logged
/// categories first (ties → most recently used), then `sortOrder`.
/// (Native's session-only time-of-day AI keys have no Flutter-side
/// equivalent and are intentionally omitted.)
List<QuickLogCategory> rankCategories(
  List<QuickLogCategory> categories,
  List<QuickLogEntry> recentEntries,
) {
  final frequency = <String, int>{};
  final lastUsed = <String, int>{};
  for (final entry in recentEntries) {
    frequency[entry.categoryId] = (frequency[entry.categoryId] ?? 0) + 1;
    final prev = lastUsed[entry.categoryId] ?? 0;
    if (entry.timestamp > prev) lastUsed[entry.categoryId] = entry.timestamp;
  }
  final sorted = categories.toList();
  sorted.sort((a, b) {
    final fa = frequency[a.id] ?? 0;
    final fb = frequency[b.id] ?? 0;
    if (fa != fb) return fb.compareTo(fa);
    if (fa > 0) {
      final ra = lastUsed[a.id] ?? 0;
      final rb = lastUsed[b.id] ?? 0;
      if (ra != rb) return rb.compareTo(ra);
    }
    return a.sortOrder.compareTo(b.sortOrder);
  });
  return sorted;
}
