import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

// ── Round 42 — entry editing (pure helpers, ports of native
// `EntryDetailViewModel` in EntryDetailScreen.kt) ────────────────────

/// Parses an entry's chips JSON-array string into labels. Tolerant,
/// never throws: malformed payloads render as NO chips (native decodes
/// `List<String>` and falls back to `emptyList()` on error). Raw JSON
/// is never rendered to a screen.
List<String> parseEntryChips(String chipsJson) {
  final raw = chipsJson.trim();
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.map((c) => '$c').where((c) => c.isNotEmpty).toList();
    }
  } catch (_) {
    // Fall through: malformed chips are no chips.
  }
  return const [];
}

/// Native detail body display + edit-field initial value:
/// `body + "\n\n" + manualText` when manualText is non-blank, else body.
String entryCombinedText(QuickLogEntry entry) =>
    entry.manualText.isNotBlank
        ? '${entry.body}\n\n${entry.manualText}'
        : entry.body;

/// Native `updateText(body, "")`: the edited combined text becomes the
/// body and manualText is cleared. Same id/timestamp/chips/category.
QuickLogEntry editedEntryText(QuickLogEntry entry, String newText) =>
    entry.copyWith(body: newText, manualText: '');

/// Native `updateCategory(categoryId)`: sets the category AND replaces
/// the chips with a JSON array holding exactly the new category name
/// (`JSONArray(listOf(catName))`), or `[]` when the name is blank.
/// Same id/timestamp/body/manualText.
QuickLogEntry editedEntryCategory(
  QuickLogEntry entry,
  QuickLogCategory category,
) {
  final chips =
      category.name.trim().isEmpty ? '[]' : jsonEncode([category.name]);
  return entry.copyWith(categoryId: category.id, chips: chips);
}

/// Native picker order: `CategoryDao.getAllCategories()` is
/// `ORDER BY sortOrder ASC`. Input is the account's REAL categories
/// from the sync pull — never hardcoded.
List<QuickLogCategory> sortedCategoriesForPicker(
  List<QuickLogCategory> categories,
) {
  final sorted = categories.toList();
  sorted.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return sorted;
}

/// Locked check-in detection (Round 21 identity — the sync DTO has no
/// `source` field): the entry sits in the resolved Mood & Energy
/// category AND carries the reserved "Daily Ranking" chip. Native
/// locks by `source == "Energy check-in"` regardless of date, so this
/// identity check carries no date window either — the [04:00, +1d)
/// energy-day window in [hasFeelingCheckIn] only decides whether
/// TODAY already has a check-in, not whether an entry IS one.
bool isLockedCheckInEntry(
  QuickLogEntry entry,
  List<QuickLogCategory> categories,
) {
  final moodId = resolveFeelingCategoryId(categories);
  if (moodId == null || entry.categoryId != moodId) return false;
  return chipsContainFeelingTag(entry.chips);
}

/// Native category-change guard for medication entries:
/// `source == "Medications Tab" || chips.contains("Medication Tab")`.
/// The sync DTO carries no source, so the chips half is what Flutter
/// can check. Text editing stays allowed for these entries (native
/// `updateText` has no medication guard).
bool isMedicationTabEntry(QuickLogEntry entry) =>
    entry.chips.contains('Medication Tab');

extension _StringNotBlank on String {
  bool get isNotBlank => trim().isNotEmpty;
}

/// Round 19 — the History view (clock-arrow icon on Quick Log). A
/// faithful Flutter port of native `HistoryScreen.kt` +
/// `HistoryViewModel.kt`, plus the founder addendum: the circular-arrow
/// button moved here from the Quick Log input row.
///
/// Round 19b (founder, Oct 12 2026): the AI Insights tab was removed —
/// the backend "insights" payload turned out to be raw biometric JSON
/// blobs rendered as garbage (epoch-0 dates, "Original entry
/// unavailable"). History is LOGS only now, full width, no tab bar.
///
/// What the moved button does (traced from native source):
/// `QuickLogScreen`'s replay icon calls
/// `QuickLogViewModel.repeatLastEntry()` — it takes the single most
/// recent log entry and inserts a DUPLICATE of it (same category, body,
/// chips, new timestamp, source "Repeat Last Entry"). It is NOT an
/// undo/delete. That exact behavior is preserved here.
///
/// Data: the user's REAL history — sync-pull `entries[]` (the same
/// source native syncs into its local DB; his ~580 entries). Native
/// loads the whole list via a Room Flow with NO pagination (LazyColumn
/// renders lazily); this port mirrors that — one pull, full list.
/// Honest empty/error states; never fake entries.
class HistoryScreen extends StatefulWidget {
  final TabsBackend? backend;

  const HistoryScreen({super.key, this.backend});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  bool _loading = true;
  String? _loadError;
  List<QuickLogEntry> _entries = const [];
  List<QuickLogCategory> _categories = const [];
  DateTime? _lastSyncAt;

  String _searchQuery = '';
  int? _categoryFilter;
  bool _todayOnly = false;

  static const _chipInk = Color(0xFF0A0A0E); // native LegacyDarkChipInk

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Initial load (and retry from the error state).
  ///
  /// Round 19c: the initial open no longer shows a full-screen
  /// spinner either — the body renders a skeleton shaped like the
  /// real history (search field, filter chips, entry cards) while
  /// this runs (see `_buildInitialSkeleton`). `_loading` still means
  /// ONLY "initial load / error retry" — round 19b's mutation paths
  /// (optimistic delete/repeat + quiet `_revalidate()`) never touch
  /// it and are unchanged.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    await _fetchIntoState();
  }

  /// Stale-while-revalidate (founder addendum #3, Oct 12 2026).
  ///
  /// ROOT CAUSE of the old "every action reloads the whole screen" bug:
  /// mutations (delete, repeat) and the old manual sync button all
  /// funnelled into `_refresh()`, which called `_load()` — and `_load()`
  /// unconditionally set `_loading = true`, swapping the whole body for
  /// a spinner and refetching everything. Mutations now update
  /// `_entries` locally (optimistically) and this quiet revalidation
  /// merges fresh server state in the background WITHOUT ever touching
  /// `_loading`/`_loadError` — what's on screen stays on screen.
  Future<void> _revalidate() async {
    _backend.invalidateSyncPull();
    await _fetchIntoState(quiet: true);
  }

  Future<void> _fetchIntoState({bool quiet = false}) async {
    try {
      final pull = await _backend.fetchSyncPull();
      if (!mounted) return;
      if (pull == null) {
        // Quiet failure keeps the displayed data; only the bare
        // initial load surfaces the error screen.
        if (!quiet) {
          setState(() {
            _loading = false;
            _loadError = "Couldn't reach the Tabs server. "
                'Check your connection and retry.';
          });
        }
        return;
      }
      setState(() {
        _entries = _sorted(pull);
        _lastSyncAt = DateTime.now();
        _loading = false;
        _loadError = null;
      });
      // Categories ride the same cached pull (no extra fetch).
      final cats = await _backend.fetchLogCategories();
      if (mounted) {
        setState(() {
          _categories = cats;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (!quiet) {
        setState(() {
          _loading = false;
          _loadError = 'Something went wrong loading history: $e';
        });
      }
      // Quiet failure: keep what's on screen; the next action retries.
    }
  }

  List<QuickLogEntry> _sorted(Map<String, dynamic> pull) {
    final raw = pull['entries'];
    final out = <QuickLogEntry>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          try {
            out.add(QuickLogEntry.fromJson(e));
          } catch (_) {}
        }
      }
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  List<QuickLogEntry> get _filtered {
    var list = _entries;
    if (_todayOnly) {
      final now = DateTime.now();
      final midnight =
          DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
      list = list.where((e) => e.timestamp >= midnight).toList();
    }
    if (_categoryFilter != null) {
      list = list.where((e) => e.categoryId == _categoryFilter).toList();
    }
    final q = _searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((e) => e.body.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  int _nextEntryId() {
    var maxId = 0;
    for (final e in _entries) {
      if (e.id > maxId) maxId = e.id;
    }
    return maxId + 1;
  }

  /// The moved circular-arrow button: native `repeatLastEntry()`
  /// behavior, preserved exactly — duplicate the most recent entry.
  Future<void> _repeatLastEntry() async {
    if (_entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No entries yet to repeat.')),
      );
      return;
    }
    final last = _entries.first; // server orders timestamp DESC
    final dupe = QuickLogEntry(
      id: _nextEntryId(),
      categoryId: last.categoryId,
      body: last.body,
      chips: last.chips,
      manualText: last.manualText,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    // Optimistic: the duplicate appears at the top immediately (its
    // timestamp is now, and the list is timestamp-DESC). Rolled back
    // if the server post fails.
    setState(() => _entries = [dupe, ..._entries]);
    final ok = await _backend.postLogEntries([dupe]);
    if (!mounted) return;
    if (ok) {
      final today = todayEntryCount(_entries);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Last entry repeated · $today today')),
      );
      // Quiet background reconcile — never blanks the screen.
      unawaited(_revalidate());
    } else {
      setState(() =>
          _entries = _entries.where((e) => e.id != dupe.id).toList());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Couldn't repeat that entry — try again.")),
      );
    }
  }

  Future<void> _deleteEntry(QuickLogEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete entry?',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: const Text(
          'This cannot be undone.',
          style: TextStyle(color: NotelColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(color: NotelColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Optimistic delete: the entry disappears immediately — no reload,
    // no loading flash. Restored at its original position if the
    // server DELETE fails.
    final index = _entries.indexWhere((e) => e.id == entry.id);
    if (index < 0) return;
    setState(() => _entries = [..._entries]..removeAt(index));
    final ok = await _backend.deleteLogEntry(entry.id);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Entry removed')));
      // Quiet background reconcile — never blanks the screen.
      unawaited(_revalidate());
    } else {
      setState(() {
        final restored = [..._entries];
        restored.insert(
            index > restored.length ? restored.length : index, entry);
        _entries = restored;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Couldn't delete that entry — try again.")),
      );
    }
  }

  /// Round 42 — save path for entry edits (native `LogRepository
  /// .updateEntry` + sync push): POST the edited entry through the
  /// existing entries upsert, REUSING its existing id, so the server
  /// updates the row in place — never a new id, never a duplicate.
  ///
  /// On success the History row is replaced in place in `_entries`
  /// (no `_loading`, no full refresh — the Round 19b pattern) and a
  /// quiet revalidation reconciles with the server. On failure the
  /// list is NOT touched: the entry keeps its old values everywhere
  /// and the caller surfaces the honest error.
  Future<bool> _saveEntryEdit(QuickLogEntry updated) async {
    final original =
        _entries.where((e) => e.id == updated.id).firstOrNull;
    if (original == null) return false;
    // Belt-and-suspenders lock guards, mirroring the native view
    // model early-returns: check-in entries never save at all, and
    // medication-tab entries never change category.
    if (isLockedCheckInEntry(original, _categories)) return false;
    if (isMedicationTabEntry(original) &&
        updated.categoryId != original.categoryId) {
      return false;
    }
    final ok = await _backend.postLogEntries([updated]);
    if (!mounted) return ok;
    if (ok) {
      setState(() {
        _entries = _entries
            .map((e) => e.id == updated.id ? updated : e)
            .toList();
      });
      // Quiet background reconcile — never blanks the screen.
      unawaited(_revalidate());
    }
    return ok;
  }

  void _showEntryDetail(QuickLogEntry entry) {
    showDialog(
      context: context,
      builder: (context) => _EntryDetailDialog(
        entry: entry,
        categories: _categories,
        formatDateTime: _formatDateTime,
        onSave: _saveEntryEdit,
      ),
    );
  }

  String _formatDateTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final amPm = d.hour < 12 ? 'AM' : 'PM';
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year} · $h12:$min $amPm';
  }

  String _formatSyncTime(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final amPm = d.hour < 12 ? 'AM' : 'PM';
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day} · $h12:$min $amPm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
          color: NotelColors.textSecondary,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'History',
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
            Text(
              _lastSyncAt != null
                  ? 'Last synced: ${_formatSyncTime(_lastSyncAt!)}'
                  : 'Saved locally',
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 11),
            ),
          ],
        ),
        actions: [
          // Founder addendum: the circular-arrow button moved here from
          // the Quick Log input row. Behavior preserved exactly —
          // duplicates the most recent entry (native repeatLastEntry).
          // (Founder addendum #4, Oct 12 2026: the manual sync button
          // that sat next to this was removed — sync runs automatically
          // in the background; only the button/wiring went away.)
          IconButton(
            onPressed: _repeatLastEntry,
            icon: const Icon(Icons.replay),
            tooltip: 'Repeat last entry',
            color: NotelColors.primary,
          ),
        ],
      ),
      body: _loading
          ? _buildInitialSkeleton()
          : _loadError != null
              ? _buildLoadError()
              : Column(
                  children: [
                    _buildSearchBar(),
                    _buildCategoryFilterRow(),
                    Expanded(child: _buildLogsTab()),
                  ],
                ),
    );
  }

  /// Round 19c — initial-load skeleton, shaped like the real history:
  /// a search-field block, a filter-chip row, and entry cards (chip
  /// line, two body lines, timestamp line) in the real list's padding.
  /// Shown only for the initial load / error retry — never for 19b's
  /// quiet revalidations.
  Widget _buildInitialSkeleton() {
    return SkeletonGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SkeletonBox(height: 48, radius: 14),
          ),
          const SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SkeletonBox(width: 64, height: 36, radius: 12),
                SizedBox(width: 8),
                SkeletonBox(width: 52, height: 36, radius: 12),
                SizedBox(width: 8),
                SkeletonBox(width: 96, height: 36, radius: 12),
                SizedBox(width: 8),
                SkeletonBox(width: 84, height: 36, radius: 12),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemCount: 4,
              itemBuilder: (_, _) => Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: NotelColors.surface,
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 72, height: 18, radius: 8),
                    SizedBox(height: 10),
                    SkeletonBox(height: 15, radius: 4),
                    SizedBox(height: 6),
                    SkeletonBox(width: 180, height: 15, radius: 4),
                    SizedBox(height: 10),
                    SkeletonBox(width: 110, height: 11, radius: 4),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NotelColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _load,
              child: const Text('Retry',
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        onChanged: (v) => setState(() => _searchQuery = v),
        style:
            const TextStyle(color: NotelColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search entries…',
          hintStyle:
              const TextStyle(color: NotelColors.textSecondary),
          prefixIcon: const Icon(Icons.search,
              color: NotelColors.textSecondary),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  onPressed: () => setState(() => _searchQuery = ''),
                  icon: const Icon(Icons.clear,
                      color: NotelColors.textSecondary),
                )
              : null,
          filled: true,
          fillColor: NotelColors.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
                color: NotelColors.primary.withValues(alpha: 0.25)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide:
                const BorderSide(color: NotelColors.primary),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryFilterRow() {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemCount: _categories.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            // "Today" filter chip.
            final on = _todayOnly;
            return GestureDetector(
              onTap: () => setState(() => _todayOnly = !on),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: on
                      ? NotelColors.primary
                      : NotelColors.surface,
                  border: Border.all(
                    color: on
                        ? NotelColors.primary
                        : NotelColors.primary
                            .withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  'TODAY',
                  style: TextStyle(
                    color: on ? _chipInk : NotelColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            );
          }
          if (index == 1) {
            final allSelected = _categoryFilter == null;
            return GestureDetector(
              onTap: () => setState(() => _categoryFilter = null),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: allSelected
                      ? NotelColors.primary
                      : NotelColors.surface,
                  border: Border.all(
                    color: allSelected
                        ? NotelColors.primary
                        : NotelColors.primary
                            .withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  'ALL',
                  style: TextStyle(
                    color: allSelected
                        ? _chipInk
                        : NotelColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            );
          }
          final cat = _categories[index - 2];
          final selected = _categoryFilter == cat.id;
          final catColor = cat.color;
          return GestureDetector(
            onTap: () => setState(() =>
                _categoryFilter = selected ? null : cat.id),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: selected ? catColor : NotelColors.surface,
                border: Border.all(
                  color: selected
                      ? catColor
                      : catColor.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                cat.name,
                style: TextStyle(
                  color:
                      selected ? _chipInk : NotelColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLogsTab() {
    final filtered = _filtered;
    if (filtered.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.note_alt,
                size: 64, color: NotelColors.surfaceHigh),
            SizedBox(height: 12),
            Text('No entries yet',
                style:
                    TextStyle(color: NotelColors.textSecondary)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemCount: filtered.length,
      itemBuilder: (context, index) =>
          _buildEntryCard(filtered[index]),
    );
  }

  /// Native `EntryCard`: 16dp card, accent-color border, left accent
  /// strip, category chip, body (max 4 lines), timestamp + sync badge,
  /// delete with confirmation.
  Widget _buildEntryCard(QuickLogEntry entry) {
    final cat = _categories
        .where((c) => c.id == entry.categoryId)
        .firstOrNull;
    final accent = cat?.color ?? NotelColors.primary;
    // Native HistoryScreen EntryCard: check-in entries show their
    // locked "Daily Ranking" tag on the card instead of the category
    // chip. All other entries keep the category chip.
    final lockedCheckIn = isLockedCheckInEntry(entry, _categories);
    final chipLabel = lockedCheckIn ? feelingCheckInTag : cat?.name;
    final chipColor = lockedCheckIn ? NotelColors.primary : accent;
    return GestureDetector(
      onTap: () => _showEntryDetail(entry),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: NotelColors.surface,
          border: Border.all(
              color: accent.withValues(alpha: 0.20)),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: chipLabel != null
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    borderRadius:
                                        BorderRadius.circular(8),
                                    color: chipColor.withValues(
                                        alpha: 0.15),
                                    border: Border.all(
                                        color: chipColor.withValues(
                                            alpha: 0.45)),
                                  ),
                                  child: Text(
                                    chipLabel,
                                    style: TextStyle(
                                      color: chipColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          onPressed: () => _deleteEntry(entry),
                          icon: const Icon(Icons.delete, size: 16),
                          color: NotelColors.textSecondary
                              .withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    entry.body,
                    style: const TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.45,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDateTime(entry.timestamp),
                        style: TextStyle(
                          color: NotelColors.primary
                              .withValues(alpha: 0.55),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.3,
                        ),
                      ),
                      // Entries here came from the server pull itself,
                      // so SYNCED is the honest status.
                      Row(
                        children: [
                          Icon(Icons.cloud_done,
                              size: 12,
                              color: NotelColors.primary
                                  .withValues(alpha: 0.6)),
                          const SizedBox(width: 4),
                          Text(
                            'Synced',
                            style: TextStyle(
                              color: NotelColors.primary
                                  .withValues(alpha: 0.6),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Round 42 — entry detail dialog. Port of native `EntryDetailScreen`:
/// - NORMAL entries: a "CHANGE CATEGORY" row (account categories in
///   native sortOrder order; a tap saves IMMEDIATELY, exactly like
///   native — there is no category save button) and an Edit affordance
///   opening the text editor. Chips render as parsed tiles, never raw
///   JSON; the only chips mutation native allows is the category
///   change replacing them with `[newCategoryName]`.
/// - Check-in entries (Round 21 identity): NO edit affordance and NO
///   category row — the native lock note stands in their place, and
///   the "Daily Ranking" tile carries its lock icon + note.
/// - Medication-tab entries: the native banner replaces the category
///   row (category locked); text editing stays available.
/// Saves go through [onSave]; the dialog only adopts new values when
/// it reports success, so a failed save leaves the OLD values on
/// screen with an honest inline error.
class _EntryDetailDialog extends StatefulWidget {
  final QuickLogEntry entry;
  final List<QuickLogCategory> categories;
  final String Function(int timestamp) formatDateTime;
  final Future<bool> Function(QuickLogEntry updated) onSave;

  const _EntryDetailDialog({
    required this.entry,
    required this.categories,
    required this.formatDateTime,
    required this.onSave,
  });

  @override
  State<_EntryDetailDialog> createState() => _EntryDetailDialogState();
}

class _EntryDetailDialogState extends State<_EntryDetailDialog> {
  late QuickLogEntry _entry;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
  }

  bool get _isCheckIn =>
      isLockedCheckInEntry(_entry, widget.categories);
  bool get _isMedTab => isMedicationTabEntry(_entry);

  QuickLogCategory? get _category => widget.categories
      .where((c) => c.id == _entry.categoryId)
      .firstOrNull;

  Future<void> _changeCategory(QuickLogCategory cat) async {
    if (_saving || cat.id == _entry.categoryId) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final updated = editedEntryCategory(_entry, cat);
    final ok = await widget.onSave(updated);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _entry = updated;
      } else {
        _error = "Couldn't save that change — try again.";
      }
    });
  }

  Future<void> _editText() async {
    final updated = await showDialog<QuickLogEntry>(
      context: context,
      builder: (context) =>
          _EditEntryTextDialog(entry: _entry, onSave: widget.onSave),
    );
    if (updated != null && mounted) {
      setState(() => _entry = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chips = parseEntryChips(_entry.chips);
    final pickerCats = sortedCategoriesForPicker(widget.categories);
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        _category?.name ?? 'Entry',
        style: const TextStyle(
            color: NotelColors.textPrimary, fontWeight: FontWeight.bold),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isCheckIn)
              // Native locked note in place of every edit affordance.
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock,
                      size: 12, color: NotelColors.textSecondary),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'This entry was logged automatically and cannot '
                      'be edited.',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 12),
                    ),
                  ),
                ],
              )
            else if (_isMedTab)
              const Text(
                'LOGGED VIA MEDICATIONS TAB',
                style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              )
            else ...[
              const Text(
                'CHANGE CATEGORY',
                style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              // Native LazyRow. A SingleChildScrollView+Row is used
              // instead of a horizontal ListView: a viewport inside an
              // AlertDialog breaks the dialog's intrinsic sizing.
              SizedBox(
                height: 40,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < pickerCats.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Builder(builder: (context) {
                          final cat = pickerCats[i];
                          final selected = cat.id == _entry.categoryId;
                          final color = cat.color;
                          return GestureDetector(
                            onTap: _saving
                                ? null
                                : () => _changeCategory(cat),
                            child: Container(
                              height: 40,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: selected
                                    ? color
                                    : NotelColors.surfaceHigh,
                                border: Border.all(
                                  color: selected
                                      ? color
                                      : color.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Text(
                                cat.name.toUpperCase(),
                                style: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : NotelColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              entryCombinedText(_entry),
              style: const TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 17,
                height: 24 / 17,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Logged on ${widget.formatDateTime(_entry.timestamp)}',
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 12),
            ),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'ASSOCIATED TILES',
                style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final chip in chips)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: NotelColors.surfaceHigh,
                        border: Border.all(
                            color:
                                NotelColors.primary.withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isCheckIn && chip == feelingCheckInTag) ...[
                            const Icon(Icons.lock,
                                size: 12,
                                color: NotelColors.textSecondary),
                            const SizedBox(width: 4),
                          ],
                          Text(chip,
                              style: const TextStyle(
                                  color: NotelColors.textPrimary,
                                  fontSize: 13)),
                        ],
                      ),
                    ),
                ],
              ),
              if (_isCheckIn) ...[
                const SizedBox(height: 8),
                const Text(
                  'This tag was added automatically and cannot be '
                  'changed.',
                  style: TextStyle(
                      color: NotelColors.textSecondary, fontSize: 12),
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                    color: NotelColors.error, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_isCheckIn)
          TextButton(
            onPressed: _saving ? null : _editText,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit, size: 16, color: NotelColors.primary),
                SizedBox(width: 6),
                Text('Edit',
                    style: TextStyle(
                        color: NotelColors.primary,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close',
              style: TextStyle(
                  color: NotelColors.primary,
                  fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

/// Native "Edit Entry Text" dialog: one field labelled "Note Content"
/// holding the combined text (no character limit, no empty-text
/// validation — native has neither), Save / Cancel. Save calls
/// [onSave] with `updateText(edited, "")` semantics; on failure the
/// dialog stays open with the error shown and nothing is adopted.
class _EditEntryTextDialog extends StatefulWidget {
  final QuickLogEntry entry;
  final Future<bool> Function(QuickLogEntry updated) onSave;

  const _EditEntryTextDialog({required this.entry, required this.onSave});

  @override
  State<_EditEntryTextDialog> createState() => _EditEntryTextDialogState();
}

class _EditEntryTextDialogState extends State<_EditEntryTextDialog> {
  late final TextEditingController _controller;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: entryCombinedText(widget.entry));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final updated = editedEntryText(widget.entry, _controller.text);
    final ok = await widget.onSave(updated);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, updated);
    } else {
      setState(() {
        _saving = false;
        _error = "Couldn't save that edit — try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Edit Entry Text',
          style: TextStyle(
              color: NotelColors.textPrimary,
              fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 250,
              child: TextField(
                key: const ValueKey('entry_text_editor'),
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Note Content',
                  labelStyle:
                      const TextStyle(color: NotelColors.textSecondary),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                        color: NotelColors.primary.withValues(alpha: 0.5)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: NotelColors.primary),
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_error!,
                    style: const TextStyle(
                        color: NotelColors.error, fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel',
              style: TextStyle(color: NotelColors.textSecondary)),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save',
              style: TextStyle(
                  color: NotelColors.primary,
                  fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
