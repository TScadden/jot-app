import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 19 — the History view (clock-arrow icon on Quick Log, and the
/// destination of the "Today so far" icon). A faithful Flutter port of
/// native `HistoryScreen.kt` + `HistoryViewModel.kt`, plus the founder
/// addendum: the circular-arrow button moved here from the Quick Log
/// input row.
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

  /// When true (opened from the "Today so far" icon), the list starts
  /// filtered to today's entries — the same history destination, pre-
  /// filtered. The filter can be cleared from the UI.
  final bool initialTodayOnly;

  const HistoryScreen(
      {super.key, this.backend, this.initialTodayOnly = false});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  bool _loading = true;
  String? _loadError;
  List<QuickLogEntry> _entries = const [];
  List<QuickLogCategory> _categories = const [];
  List<QuickLogInsight> _insights = const [];
  DateTime? _lastSyncAt;

  String _searchQuery = '';
  int? _categoryFilter;
  late bool _todayOnly;
  int _tab = 0; // 0 = logs, 1 = AI insights
  bool _syncing = false;

  static const _chipInk = Color(0xFF0A0A0E); // native LegacyDarkChipInk

  @override
  void initState() {
    super.initState();
    _todayOnly = widget.initialTodayOnly;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final pull = await _backend.fetchSyncPull();
      if (pull == null) {
        setState(() {
          _loading = false;
          _loadError = "Couldn't reach the Tabs server. "
              'Check your connection and retry.';
        });
        return;
      }
      setState(() {
        _entries = _sorted(pull);
        _lastSyncAt = DateTime.now();
        _loading = false;
      });
      // Categories + insights ride the same cached pull (no extra fetch).
      final cats = await _backend.fetchLogCategories();
      final insights = await _backend.fetchLogInsights();
      if (mounted) {
        setState(() {
          _categories = cats;
          _insights = insights;
        });
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _loadError = 'Something went wrong loading history: $e';
      });
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

  Future<void> _refresh() async {
    setState(() => _syncing = true);
    _backend.invalidateSyncPull();
    await _load();
    setState(() => _syncing = false);
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
    final ok = await _backend.postLogEntries([dupe]);
    if (!mounted) return;
    if (ok) {
      await _refresh();
      if (!mounted) return;
      final today = todayEntryCount(_entries);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Last entry repeated · $today today')),
      );
    } else {
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
    final ok = await _backend.deleteLogEntry(entry.id);
    if (!mounted) return;
    if (ok) {
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Entry removed')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Couldn't delete that entry — try again.")),
      );
    }
  }

  void _showEntryDetail(QuickLogEntry entry) {
    final cat = _categories
        .where((c) => c.id == entry.categoryId)
        .firstOrNull;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          cat?.name ?? 'Entry',
          style: const TextStyle(
              color: NotelColors.textPrimary,
              fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(entry.body,
                  style: const TextStyle(
                      color: NotelColors.textPrimary, fontSize: 15)),
              const SizedBox(height: 12),
              Text(_formatDateTime(entry.timestamp),
                  style: const TextStyle(
                      color: NotelColors.textSecondary, fontSize: 12)),
              if (entry.chips.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Chips: ${entry.chips}',
                    style: const TextStyle(
                        color: NotelColors.textSecondary, fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
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
          IconButton(
            onPressed: _repeatLastEntry,
            icon: const Icon(Icons.replay),
            tooltip: 'Repeat last entry',
            color: NotelColors.primary,
          ),
          IconButton(
            onPressed: _syncing ? null : _refresh,
            icon: _syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: NotelColors.primary),
                  )
                : const Icon(Icons.sync),
            tooltip: 'Sync Now / Retry',
            color: NotelColors.textSecondary,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child:
                  CircularProgressIndicator(color: NotelColors.primary))
          : _loadError != null
              ? _buildLoadError()
              : Column(
                  children: [
                    _buildSearchBar(),
                    _buildCategoryFilterRow(),
                    _buildTabRow(),
                    Expanded(
                      child: _tab == 0
                          ? _buildLogsTab()
                          : _buildInsightsTab(),
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
              onPressed: _refresh,
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
            // "Today" filter chip (from the Today-so-far icon).
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

  Widget _buildTabRow() {
    final filtered = _filtered;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(child: _tabButton(0, 'LOGS (${filtered.length})')),
          Expanded(
              child:
                  _tabButton(1, 'AI INSIGHTS (${_insights.length})')),
        ],
      ),
    );
  }

  Widget _tabButton(int index, String label) {
    final selected = _tab == index;
    return GestureDetector(
      onTap: () => setState(() => _tab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected
                  ? NotelColors.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? NotelColors.primary
                : NotelColors.textSecondary,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
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
                        child: cat != null
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    borderRadius:
                                        BorderRadius.circular(8),
                                    color: accent.withValues(
                                        alpha: 0.15),
                                    border: Border.all(
                                        color: accent.withValues(
                                            alpha: 0.45)),
                                  ),
                                  child: Text(
                                    cat.name,
                                    style: TextStyle(
                                      color: accent,
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

  Widget _buildInsightsTab() {
    if (_insights.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome,
                size: 64, color: NotelColors.surfaceHigh),
            SizedBox(height: 12),
            Text('No AI insights history',
                style:
                    TextStyle(color: NotelColors.textSecondary)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemCount: _insights.length,
      itemBuilder: (context, index) {
        final insight = _insights[index];
        final entryId = int.tryParse(insight.entryId ?? '');
        final entry = entryId == null
            ? null
            : _entries
                .where((e) => e.id == entryId)
                .firstOrNull;
        final cat = entry == null
            ? null
            : _categories
                .where((c) => c.id == entry.categoryId)
                .firstOrNull;
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: NotelColors.surface,
            border: Border.all(
                color:
                    NotelColors.primary.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _titleCase(insight.type),
                      style: const TextStyle(
                        color: NotelColors.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Text(
                    cat?.name ?? 'Uncategorized',
                    style: const TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                insight.text,
                style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                entry != null
                    ? 'Original Entry: "${_truncate(entry.body, 60)}..."'
                    : 'Original entry unavailable',
                style: TextStyle(
                  color: entry != null
                      ? NotelColors.textSecondary
                      : NotelColors.error,
                  fontSize: 11,
                  fontStyle: entry != null
                      ? FontStyle.normal
                      : FontStyle.italic,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _formatDateTime(insight.timestamp),
                style: TextStyle(
                  color:
                      NotelColors.primary.withValues(alpha: 0.5),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _titleCase(String s) {
    final t = s.toLowerCase();
    return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : s.substring(0, n);
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
