import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

/// Round 18 (Team C) — Trends, Flutter port of the native `TrendsScreen.kt`
/// patterns-over-time layout.
///
/// Data: sync-pull `entries` (timestamps → hourly density chart + log
/// volume + symptom chips) and `categories` (category focus rows).
/// Honest empty states per section: "No logs yet" when there are no
/// entries, "No symptoms logged yet."
///
/// Round 20c: the "Heart rate over time" section is gone.
///
/// Round 20b: the Patterns (insights) section is gone. The Log volume
/// card is now a view toggle: with no filter active, tapping it switches
/// the hourly chart between the selected day and an all-time view
/// (every entry bucketed by hour of day across all days); with an hour
/// or symptom filter active, the first tap only clears the filter.
///
/// Founder's data rules: biometric zeros are failed reads (never
/// charted); missing → empty/"--", never invented.
class TrendsScreen extends StatefulWidget {
  final TabsBackend? backend;
  final void Function(int entryId)? onNavigateToEntry;

  const TrendsScreen({super.key, this.backend, this.onNavigateToEntry});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class TrendsEntry {
  final int id;
  final String body;
  final int timestamp;
  final int categoryId;
  final String chips;

  const TrendsEntry({
    required this.id,
    required this.body,
    required this.timestamp,
    required this.categoryId,
    required this.chips,
  });

  factory TrendsEntry.fromJson(Map<String, dynamic> json) {
    return TrendsEntry(
      id: parseLooseInt(json['id']),
      body: '${json['body'] ?? ''}',
      timestamp: parseEpochMs(json['timestamp']),
      categoryId: parseLooseInt(json['categoryId']),
      chips: '${json['chips'] ?? ''}',
    );
  }
}

class _TrendsScreenState extends State<TrendsScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  bool _loading = true;
  String? _error;
  List<TrendsEntry> _entries = const [];
  List<TrendsCategory> _categories = const [];
  Map<int, String> _categoryNames = const {};
  Map<int, Color> _categoryColors = const {};

  /// 0 = today; negative = days in the past.
  int _dayOffset = 0;

  /// Hourly chart mode: false = selected day only, true = all-time
  /// (every entry bucketed by hour of day, day selector hidden).
  bool _allTime = false;
  int? _selectedHour;
  String? _selectedSymptom;
  bool _showSymptomsDialog = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pull = await _backend.fetchSyncPull();
      if (!mounted) return;
      if (pull == null) {
        setState(() {
          _loading = false;
          _error =
              'Could not load your data. Check your connection and try again.';
        });
        return;
      }
      setState(() {
        _loading = false;
        _entries = parseTrendsEntries(pull['entries']);
        final cats = parseTrendsCategories(pull['categories']);
        _categories = cats;
        _categoryNames = {
          for (final c in cats) c.id: c.name,
        };
        _categoryColors = {
          for (final c in cats) c.id: c.color,
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Could not load your data. Check your connection and try again.';
      });
    }
  }

  DateTime get _selectedDate {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return today.add(Duration(days: _dayOffset));
  }

  bool _isOnSelectedDay(DateTime dt) {
    final sel = _selectedDate;
    return dt.year == sel.year && dt.month == sel.month && dt.day == sel.day;
  }

  Map<int, int> get _frequencyByHour {
    final out = <int, int>{};
    for (final e in _entries) {
      if (e.timestamp <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(e.timestamp);
      // All-time mode buckets every entry by hour of day, any day.
      if (_allTime || _isOnSelectedDay(dt)) {
        out[dt.hour] = (out[dt.hour] ?? 0) + 1;
      }
    }
    return out;
  }

  List<TrendsEntry> get _filteredLogs {
    if (_selectedHour == null) return const [];
    final out = [
      for (final e in _entries)
        if (e.timestamp > 0)
          () {
            final dt = DateTime.fromMillisecondsSinceEpoch(e.timestamp);
            // All-time mode: the hour matches on any day.
            return ((_allTime || _isOnSelectedDay(dt)) &&
                    dt.hour == _selectedHour)
                ? e
                : null;
          }()
    ].whereType<TrendsEntry>().toList();
    // Native selectHour lists newest first.
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  List<TrendsEntry> get _logsForSymptom {
    if (_selectedSymptom == null) return const [];
    final needle = _selectedSymptom!.toLowerCase();
    // Mirrors native TrendsViewModel.selectSymptom: a log matches when
    // one of its chips equals the symptom OR its body mentions it,
    // listed newest first.
    final out = [
      for (final e in _entries)
        if (splitChips(e.chips).any((c) => c.toLowerCase() == needle) ||
            e.body.toLowerCase().contains(needle))
          e,
    ];
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  List<({String chip, int count})> get _topChips {
    final counts = <String, int>{};
    final firstSeen = <String, String>{};
    for (final e in _entries) {
      for (final chip in splitChips(e.chips)) {
        final key = chip.toLowerCase();
        firstSeen.putIfAbsent(key, () => chip);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final out = [
      for (final k in counts.keys) (chip: firstSeen[k]!, count: counts[k]!),
    ];
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  /// Category counts for the CURRENT view, using the same scope as
  /// the hourly chart: the selected day in day mode, every entry in
  /// all-time mode. (Native counts the selected day's entries; the
  /// Round 20b all-time view extends that scope to all days, so the
  /// Category Focus rows always agree with the chart above them.)
  Map<int, int> get _frequencyByCategory {
    final out = <int, int>{};
    for (final e in _entries) {
      if (e.timestamp <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(e.timestamp);
      if (_allTime || _isOnSelectedDay(dt)) {
        out[e.categoryId] = (out[e.categoryId] ?? 0) + 1;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textSecondary, semanticLabel: 'Back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Visual Trends',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.list,
                color: NotelColors.textSecondary,
                semanticLabel: 'Most Used Symptoms'),
            onPressed: () =>
                setState(() => _showSymptomsDialog = true),
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(),
          if (_showSymptomsDialog) _SymptomsDialog(
            chips: _topChips,
            selected: _selectedSymptom,
            onSelect: (chip) => setState(() {
              _selectedSymptom = chip;
              // Native selectSymptom clears the hour filter.
              _selectedHour = null;
              _showSymptomsDialog = false;
            }),
            onClose: () =>
                setState(() => _showSymptomsDialog = false),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return _buildLoadingSkeleton();
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 56, color: NotelColors.textSecondary),
              const SizedBox(height: 16),
              Text(_error!,
                  style: const TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: NotelColors.textSecondary),
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _load();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final totalLogs = _entries.length;
    final filtered = _filteredLogs;
    final symptomLogs = _logsForSymptom;
    // Lazy slivers: long entry lists build on demand instead of the
    // whole column at once (founder scroll-lag report).
    return CustomScrollView(
      slivers: [
        // Log volume card — also the day/all-time view toggle.
        // Interaction rule (Round 20b): if an hour or symptom filter
        // is active, a tap clears the filter only (no mode change);
        // with no filter active, a tap toggles day ↔ all-time mode.
        _section(
          top: 16,
          child: InkWell(
            onTap: () => setState(() {
              if (_selectedHour != null || _selectedSymptom != null) {
                _selectedHour = null;
                _selectedSymptom = null;
              } else {
                _allTime = !_allTime;
                if (!_allTime) {
                  // The all-time hint promises "return to today": the
                  // day view restarts at today, cross-day hour
                  // selection cleared.
                  _dayOffset = 0;
                  _selectedHour = null;
                }
              }
            }),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _allTime
                    ? NotelColors.primary.withValues(alpha: 0.12)
                    : NotelColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: _allTime
                        ? NotelColors.primary
                        : NotelColors.primary.withValues(alpha: 0.18),
                    width: _allTime ? 1.5 : 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.trending_up,
                      size: 32, color: NotelColors.primary),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Log volume',
                            style: TextStyle(
                                fontSize: 13, color: NotelColors.primary)),
                        Text('$totalLogs Total Entries',
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: NotelColors.textPrimary)),
                        Text(
                            _selectedHour != null || _selectedSymptom != null
                                ? 'Tap to reset filter'
                                : _allTime
                                    ? 'Showing all time · tap to return to today'
                                    : 'Tap to view all time',
                            style: TextStyle(
                                fontSize: 11,
                                color: NotelColors.primaryText)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        if (totalLogs == 0)
          _section(
            child: _emptyState(
              icon: Icons.trending_up,
              title: 'No logs yet',
              body:
                  'Log your first entry from Quick Log, then come back here to see your patterns.',
            ),
          )
        else ...[
          // The day selector has no meaning in all-time mode.
          if (!_allTime) _section(child: _daySelector()),
          _section(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel(_selectedHour != null
                    ? 'Logs at ${_formatHour(_selectedHour!)}'
                    : _allTime
                        ? 'Log activity by hour · All time'
                        : 'Log activity by hour'),
                const SizedBox(height: 8),
                _HourlyChart(
                  data: _frequencyByHour,
                  selectedHour: _selectedHour,
                  onHourSelected: (h) => setState(() => _selectedHour =
                      _selectedHour == h ? null : h),
                ),
              ],
            ),
          ),
          if (_selectedHour == null)
            _section(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Category Focus',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: NotelColors.textPrimary)),
                  const SizedBox(height: 12),
                  ..._categoryRows(),
                ],
              ),
            ),
          if (filtered.isNotEmpty) ...[
            _section(
                bottom: 8, child: _sectionLabel('Entries for this hour')),
            _lazyList(filtered.length, (i) => _entryCard(filtered[i])),
          ],
          if (symptomLogs.isNotEmpty) ...[
            _section(
                bottom: 8,
                child: _sectionLabel("Logs for '${_selectedSymptom!}'")),
            _lazyList(symptomLogs.length, (i) => _entryCard(symptomLogs[i])),
          ],
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 110)),
      ],
    );
  }

  /// Round 36 — initial-load skeleton shaped like the real screen
  /// (volume card, day selector, hourly chart, category rows). The
  /// founder's Round 19c rule: anything that genuinely must load uses
  /// a skeleton shaped like the real content — never a blocking
  /// spinner. Shown only until the first pull lands.
  Widget _buildLoadingSkeleton() {
    return SkeletonGroup(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Log volume card: icon block + label/total/hint lines.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: NotelColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: NotelColors.primary.withValues(alpha: 0.18),
                ),
              ),
              child: const Row(
                children: [
                  SkeletonBox(width: 32, height: 32, radius: 8),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 72, height: 13),
                        SizedBox(height: 6),
                        SkeletonBox(width: 160, height: 20),
                        SizedBox(height: 6),
                        SkeletonBox(width: 120, height: 11),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Day selector line.
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SkeletonBox(width: 24, height: 24, radius: 12),
                SkeletonBox(width: 80, height: 16),
                SkeletonBox(width: 24, height: 24, radius: 12),
              ],
            ),
            const SizedBox(height: 24),
            // Hourly chart card.
            const SkeletonBox(width: 150, height: 12),
            const SizedBox(height: 8),
            const SkeletonBox(height: 220, radius: 16),
            const SizedBox(height: 24),
            // Category Focus rows.
            const SkeletonBox(width: 120, height: 16),
            const SizedBox(height: 12),
            for (var i = 0; i < 3; i++) ...[
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SkeletonBox(width: 110, height: 14),
                  SkeletonBox(width: 20, height: 14),
                ],
              ),
              const SizedBox(height: 6),
              const SkeletonBox(height: 8, radius: 4),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  /// One eagerly-built block in the trends scroll view, with the
  /// screen's standard horizontal padding and spacing below it.
  Widget _section({required Widget child, double top = 0, double bottom = 24}) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, top, 16, bottom),
      sliver: SliverToBoxAdapter(child: child),
    );
  }

  /// A lazily-built list section: rows are only built as they scroll
  /// into view, each in its own repaint boundary.
  Widget _lazyList(int count, Widget Function(int index) builder,
      {double bottom = 24}) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
      sliver: SliverList.builder(
        itemCount: count,
        itemBuilder: (context, i) => RepaintBoundary(child: builder(i)),
      ),
    );
  }

  Widget _daySelector() {
    final canGoNext = _dayOffset < 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left,
              color: NotelColors.textPrimary),
          onPressed: () => setState(() {
            _dayOffset -= 1;
            _selectedHour = null;
          }),
          tooltip: 'Previous Day',
        ),
        InkWell(
          onTap: () => setState(() {
            _dayOffset = 0;
            _selectedHour = null;
          }),
          child: SizedBox(
            height: 48,
            child: Center(
              child: Text(_dateLabel(_selectedDate),
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.chevron_right,
              color: canGoNext
                  ? NotelColors.textPrimary
                  : NotelColors.textSecondary.withValues(alpha: 0.5)),
          onPressed: canGoNext
              ? () => setState(() {
                    _dayOffset += 1;
                    _selectedHour = null;
                  })
              : null,
          tooltip: 'Next Day',
        ),
      ],
    );
  }

  List<Widget> _categoryRows() {
    final freq = _frequencyByCategory;
    // Percentages are shares of the scoped entries (the same set the
    // counts come from), so the bars agree with the chart's scope.
    final total = freq.values.fold(0, (a, b) => a + b);
    final rows = <Widget>[];
    // Native iterates the category list (server order) and shows the
    // ones with entries; entries pointing at an unknown category id
    // still get a fallback row after the known ones.
    final knownIds = <int>{};
    for (final cat in _categories) {
      knownIds.add(cat.id);
      final count = freq[cat.id] ?? 0;
      if (count <= 0) continue;
      rows.add(_CategoryProgressRow(
        name: cat.name,
        count: count,
        total: total,
        color: cat.color,
      ));
      rows.add(const SizedBox(height: 12));
    }
    for (final entry in freq.entries) {
      if (entry.value <= 0 || knownIds.contains(entry.key)) continue;
      rows.add(_CategoryProgressRow(
        name: resolveTrendsCategoryName(entry.key, _categoryNames),
        count: entry.value,
        total: total,
        color: _categoryColors[entry.key] ?? NotelColors.primary,
      ));
      rows.add(const SizedBox(height: 12));
    }
    if (rows.isEmpty) {
      return [
        _emptyState(
          icon: Icons.category_outlined,
          title: 'No categories yet',
          body: 'Categories with logged entries will show here.',
          compact: true,
        ),
      ];
    }
    return rows;
  }

  Widget _entryCard(TrendsEntry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: widget.onNavigateToEntry == null
            ? null
            : () => widget.onNavigateToEntry!(entry.id),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: NotelColors.primary.withValues(alpha: 0.18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.timestamp > 0)
                Text(formatEntryDate(entry.timestamp),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: NotelColors.primaryText)),
              if (entry.timestamp > 0) const SizedBox(height: 4),
              Text(entry.body,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.45,
                      color: NotelColors.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String body,
    bool compact = false,
  }) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 20 : 32),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.legacyDarkHairlineFaint),
      ),
      child: Column(
        children: [
          Icon(icon,
              size: compact ? 36 : 56,
              color: NotelColors.textSecondary.withValues(alpha: 0.5)),
          SizedBox(height: compact ? 12 : 16),
          Text(title,
              style: TextStyle(
                  fontSize: compact ? 15 : 18,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(body,
              style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: NotelColors.textSecondary),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(text.toUpperCase(),
        style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
            color: NotelColors.primary));
  }
}

// ── Hourly density chart ────────────────────────────────────────────────────

class _HourlyChart extends StatelessWidget {
  final Map<int, int> data;
  final int? selectedHour;
  final void Function(int hour) onHourSelected;

  const _HourlyChart({
    required this.data,
    required this.selectedHour,
    required this.onHourSelected,
  });

  @override
  Widget build(BuildContext context) {
    final maxVal = math.max(1, data.values.fold(0, math.max));
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: NotelColors.primary.withValues(alpha: 0.18)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        itemCount: 24,
        itemBuilder: (context, hour) {
          final count = data[hour] ?? 0;
          final isSelected = selectedHour == hour;
          final barH = (count / maxVal) * 120;
          return InkWell(
            onTap: () => onHourSelected(hour),
            child: SizedBox(
              width: 48,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (count > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('$count',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isSelected
                                  ? NotelColors.primaryText
                                  : NotelColors.textSecondary)),
                    ),
                  Container(
                    width: 12,
                    height: math.max(2, barH),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? NotelColors.primary
                          : NotelColors.primary.withValues(
                              alpha: count > 0 ? 0.55 : 0.12),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_hourLabel(hour),
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w500,
                          color: isSelected
                              ? NotelColors.primaryText
                              : NotelColors.textSecondary),
                      maxLines: 1),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

String _hourLabel(int hour) {
  if (hour == 0) return '12am';
  if (hour < 12) return '${hour}am';
  if (hour == 12) return '12pm';
  return '${hour - 12}pm';
}

String _formatHour(int hour) {
  if (hour == 0) return '12 AM';
  if (hour < 12) return '$hour AM';
  if (hour == 12) return '12 PM';
  return '${hour - 12} PM';
}

// ── Category progress row ───────────────────────────────────────────────────

class _CategoryProgressRow extends StatelessWidget {
  final String name;
  final int count;
  final int total;
  final Color color;

  const _CategoryProgressRow({
    required this.name,
    required this.count,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? count / total : 0.0;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(name,
                  style: const TextStyle(
                      fontSize: 14, color: NotelColors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            Text('$count',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color)),
          ],
        ),
        const SizedBox(height: 6),
        Stack(
          children: [
            Container(
              height: 8,
              decoration: BoxDecoration(
                color: NotelColors.surfaceHigh,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            FractionallySizedBox(
              widthFactor: pct.clamp(0.0, 1.0),
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Symptoms dialog ─────────────────────────────────────────────────────────

class _SymptomsDialog extends StatelessWidget {
  final List<({String chip, int count})> chips;
  final String? selected;
  final void Function(String chip) onSelect;
  final VoidCallback onClose;

  const _SymptomsDialog({
    required this.chips,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(32),
          padding: const EdgeInsets.all(24),
          // Round 20b: cap the dialog at ~80% of screen height and
          // scroll ONLY the chip area — with ~20 chips the old fixed
          // layout cut the bottom chips off with no way to reach them.
          // Header and Close stay pinned outside the scroll view.
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: NotelColors.primary.withValues(alpha: 0.25)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('MOST USED SYMPTOMS',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: NotelColors.primary)),
              const SizedBox(height: 16),
              if (chips.isEmpty)
                const Text('No symptoms logged yet.',
                    style: TextStyle(
                        fontSize: 14, color: NotelColors.textSecondary))
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in chips)
                          InkWell(
                            onTap: () => onSelect(c.chip),
                            borderRadius: BorderRadius.circular(10),
                            // R53 T3: 48dp hit area; visual chip (h12/v6,
                            // r10) centered inside, unchanged.
                            child: SizedBox(
                              height: 48,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: selected == c.chip
                                    ? NotelColors.primary
                                    : NotelColors.surfaceHigh,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: NotelColors.primary.withValues(
                                        alpha:
                                            selected == c.chip ? 1.0 : 0.25)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(c.chip,
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: selected == c.chip
                                              ? NotelColors.onPrimary
                                              : NotelColors.textPrimary)),
                                  const SizedBox(width: 6),
                                  Text('${c.count}',
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: selected == c.chip
                                              ? NotelColors.onPrimary
                                              : NotelColors.primary)),
                                ],
                              ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onClose,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NotelColors.surfaceHigh,
                    foregroundColor: NotelColors.textPrimary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pure parsing helpers (unit-tested) ──────────────────────────────────────

/// Tolerant int parse for sync-pull fields. The server serializes
/// Postgres bigint columns as JSON strings (node-pg int8 default), so
/// ids arrive as `"639"`, not `639`. Accepts num or numeric string;
/// anything else → 0. Never throws.
int parseLooseInt(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

/// Tolerant epoch-millis parse (see [parseLooseInt] for why strings
/// arrive). Also accepts an ISO-8601 string defensively. Never throws.
int parseEpochMs(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) {
    final s = v.trim();
    final n = int.tryParse(s);
    if (n != null) return n;
    final dt = DateTime.tryParse(s);
    if (dt != null) return dt.millisecondsSinceEpoch;
  }
  return 0;
}

/// Sync-pull entries → view rows. Skips malformed rows; never throws.
List<TrendsEntry> parseTrendsEntries(dynamic raw) {
  if (raw is! List) return const [];
  final out = <TrendsEntry>[];
  for (final e in raw) {
    if (e is Map<String, dynamic>) out.add(TrendsEntry.fromJson(e));
  }
  return out;
}

class TrendsCategory {
  final int id;
  final String name;
  final Color color;

  const TrendsCategory(
      {required this.id, required this.name, required this.color});
}

/// Sync-pull categories → id/name/color rows. Never throws.
List<TrendsCategory> parseTrendsCategories(dynamic raw) {
  if (raw is! List) return const [];
  final out = <TrendsCategory>[];
  for (final c in raw) {
    if (c is Map<String, dynamic>) {
      final id = c['id'];
      Color color = NotelColors.primary;
      final hex = '${c['colorHex'] ?? c['color'] ?? ''}';
      if (hex.isNotEmpty) {
        try {
          final v = int.parse(hex.replaceFirst('#', ''), radix: 16);
          color = Color(v | 0xFF000000);
        } catch (_) {}
      }
      out.add(TrendsCategory(
        // Category ids are int8 too — the server sends them as JSON
        // strings ("1"), and a num-only parse zeroed every one of
        // them, collapsing all categories onto id 0 (Round 36 fix:
        // rows rendered "Category N" with the fallback color).
        id: parseLooseInt(id),
        name: '${c['name'] ?? 'Category'}',
        color: color,
      ));
    }
  }
  return out;
}

/// Canonical names of the app's built-in default categories (native
/// `DefaultCategories`; the ids are stable across app generations).
/// Trends uses these ONLY as a display fallback when the sync pull
/// carries no row for an entry's category id: this client never
/// originates the defaults as server rows, and a full-list categories
/// replace can drop rows that older entries still reference — without
/// the fallback those entries render as a raw "Category N" (fresh-
/// account audit, Oct 28, 2026). A pulled row — including a user
/// rename — always wins over this table.
const Map<int, String> trendsDefaultCategoryNames = {
  1: 'Symptoms',
  2: 'Food & Eating',
  3: 'Weight & Vitals',
  4: 'Goals & Habits',
  5: 'Sleep',
  6: 'Mood & Energy',
  7: 'General',
  8: 'Medication',
};

/// Display name for a Trends category row: pulled name first, then
/// the built-in default name, then the raw-id fallback.
String resolveTrendsCategoryName(int id, Map<int, String> pulledNames) =>
    pulledNames[id] ?? trendsDefaultCategoryNames[id] ?? 'Category $id';

/// Splits an entry's chips field into plain symptom/chip names.
///
/// The field is a JSON-array string (`'["Heart Palpitations"]'`,
/// `'[]'` for none) — native decodes it with
/// `Json.decodeFromString<List<String>>`. Parsing it as plain text
/// leaked raw array syntax onto the screen (`["Medication Tab"]`,
/// and `[]` itself as a bogus top "symptom"). JSON arrays are decoded
/// properly; a legacy plain string falls back to comma/semicolon
/// splitting. Empty arrays and blank names yield nothing. Never throws.
List<String> splitChips(String chips) {
  final trimmed = chips.trim();
  if (trimmed.isEmpty) return const [];
  if (trimmed.startsWith('[')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        return [
          for (final e in decoded)
            if ('$e'.trim().isNotEmpty) '$e'.trim(),
        ];
      }
    } catch (_) {
      // Malformed array syntax is machine-format text — never a chip.
      return const [];
    }
    return const [];
  }
  return trimmed
      .split(RegExp(r'[,;]'))
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty)
      .toList();
}

const _trendMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// "Today" / "Yesterday" / "Oct 9, 2026" for the day selector.
String _dateLabel(DateTime dt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(dt.year, dt.month, dt.day);
  if (d == today) return 'Today';
  if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return '${_trendMonths[dt.month - 1]} ${dt.day}, ${dt.year}';
}

/// "6:16 PM, Oct 11" like the native entry rows.
String formatEntryDate(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final amPm = dt.hour < 12 ? 'AM' : 'PM';
  final minute = dt.minute.toString().padLeft(2, '0');
  return '$hour12:$minute $amPm, ${_trendMonths[dt.month - 1]} ${dt.day}';
}
