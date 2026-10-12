import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 (Team C) — Trends, Flutter port of the native `TrendsScreen.kt`
/// patterns-over-time layout.
///
/// Data: sync-pull `entries` (timestamps → hourly density chart + log
/// volume + symptom chips), `categories` (category focus rows), `insights`
/// (patterns section), and `profile['heartRateHistory']` (a JSON string
/// decoded leniently → recent HR strip). Honest empty states per section:
/// "No logs yet" when there are no entries, "No symptoms logged yet.",
/// "No patterns yet.", "No heart rate history yet."
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
  Map<int, String> _categoryNames = const {};
  Map<int, Color> _categoryColors = const {};
  List<Map<String, dynamic>> _insights = const [];
  List<({String label, double value})> _hrHistory = const [];

  /// 0 = today; negative = days in the past.
  int _dayOffset = 0;
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
        _categoryNames = {
          for (final c in cats) c.id: c.name,
        };
        _categoryColors = {
          for (final c in cats) c.id: c.color,
        };
        _insights = parseTrendsInsights(pull['insights']);
        final profile = pull['profile'];
        _hrHistory = profile is Map<String, dynamic>
            ? parseHeartRateHistory(profile['heartRateHistory'])
            : const [];
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

  Map<int, int> get _frequencyByHour {
    final sel = _selectedDate;
    final out = <int, int>{};
    for (final e in _entries) {
      if (e.timestamp <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(e.timestamp);
      if (dt.year == sel.year && dt.month == sel.month && dt.day == sel.day) {
        out[dt.hour] = (out[dt.hour] ?? 0) + 1;
      }
    }
    return out;
  }

  List<TrendsEntry> get _filteredLogs {
    if (_selectedHour == null) return const [];
    final sel = _selectedDate;
    return [
      for (final e in _entries)
        if (e.timestamp > 0)
          () {
            final dt = DateTime.fromMillisecondsSinceEpoch(e.timestamp);
            return (dt.year == sel.year &&
                    dt.month == sel.month &&
                    dt.day == sel.day &&
                    dt.hour == _selectedHour)
                ? e
                : null;
          }()
    ].whereType<TrendsEntry>().toList();
  }

  List<TrendsEntry> get _logsForSymptom {
    if (_selectedSymptom == null) return const [];
    final needle = _selectedSymptom!.toLowerCase();
    // Mirrors native TrendsViewModel.selectSymptom: a log matches when
    // one of its chips equals the symptom OR its body mentions it.
    return [
      for (final e in _entries)
        if (splitChips(e.chips).any((c) => c.toLowerCase() == needle) ||
            e.body.toLowerCase().contains(needle))
          e,
    ];
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

  Map<int, int> get _frequencyByCategory {
    final out = <int, int>{};
    for (final e in _entries) {
      out[e.categoryId] = (out[e.categoryId] ?? 0) + 1;
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
      return const Center(
          child: CircularProgressIndicator(color: NotelColors.primary));
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
    // Lazy slivers: long lists (entries, patterns) build on demand
    // instead of the whole column at once (founder scroll-lag report).
    return CustomScrollView(
      slivers: [
        // Log volume card
        _section(
          top: 16,
          child: InkWell(
            onTap: () => setState(() {
              _selectedHour = null;
              _selectedSymptom = null;
            }),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: NotelColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: NotelColors.primary.withValues(alpha: 0.18)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.trending_up,
                      size: 32, color: NotelColors.primary),
                  const SizedBox(width: 16),
                  Column(
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
                      if (_selectedHour != null || _selectedSymptom != null)
                        Text('Tap to reset filter',
                            style: TextStyle(
                                fontSize: 11,
                                color: NotelColors.primary
                                    .withValues(alpha: 0.7))),
                    ],
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
          _section(child: _daySelector()),
          _section(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel(_selectedHour != null
                    ? 'Logs at ${_formatHour(_selectedHour!)}'
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

        // Patterns (insights) — always shown when present
        _section(bottom: 8, child: _sectionLabel('Patterns')),
        if (_insights.isEmpty)
          _section(
            child: _emptyState(
              icon: Icons.auto_awesome,
              title: 'No patterns yet',
              body:
                  'Insights appear here once Tabs has enough data to spot trends.',
              compact: true,
            ),
          )
        else
          _lazyList(
            _insights.length,
            (i) => _insightCard(_insights[i]) ?? const SizedBox.shrink(),
          ),

        // Heart rate history strip
        _section(bottom: 8, child: _sectionLabel('Heart rate over time')),
        if (_hrHistory.isEmpty)
          _section(
            bottom: 0,
            child: _emptyState(
              icon: Icons.favorite_border,
              title: 'No heart rate history yet',
              body:
                  'Heart rate history from your profile will appear here once it syncs.',
              compact: true,
            ),
          )
        else
          _section(bottom: 0, child: _HrHistoryStrip(data: _hrHistory)),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
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
          child: Text(_dateLabel(_selectedDate),
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary)),
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
    final total = _entries.length;
    final rows = <Widget>[];
    for (final entry in freq.entries) {
      if (entry.value <= 0) continue;
      rows.add(_CategoryProgressRow(
        name: _categoryNames[entry.key] ?? 'Category ${entry.key}',
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
                        color: NotelColors.primary
                            .withValues(alpha: 0.6))),
              if (entry.timestamp > 0) const SizedBox(height: 4),
              Text(entry.body,
                  style: const TextStyle(
                      fontSize: 14, color: NotelColors.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _insightCard(Map<String, dynamic> insight) {
    // Round 18b: never render raw JSON — unparseable patterns are skipped.
    final text = renderInsightText('${insight['text'] ?? ''}');
    if (text == null || text.isEmpty) return null;
    final type = '${insight['type'] ?? ''}';
    final range = '${insight['dateRangeText'] ?? ''}';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: NotelColors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (type.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: NotelColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(type.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.primary)),
            ),
          Text(text,
              style: const TextStyle(
                  fontSize: 14, height: 1.5, color: NotelColors.textPrimary)),
          if (range.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(range,
                style: const TextStyle(
                    fontSize: 12, color: NotelColors.textSecondary)),
          ],
        ],
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
              width: 40,
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
                                  ? NotelColors.primary
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
                          fontSize: 9,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w500,
                          color: isSelected
                              ? NotelColors.primary
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
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in chips)
                      InkWell(
                        onTap: () => onSelect(c.chip),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
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
                                          ? Colors.white
                                          : NotelColors.textPrimary)),
                              const SizedBox(width: 6),
                              Text('${c.count}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: selected == c.chip
                                          ? Colors.white
                                          : NotelColors.primary)),
                            ],
                          ),
                        ),
                      ),
                  ],
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

// ── Heart-rate history strip ────────────────────────────────────────────────

class _HrHistoryStrip extends StatelessWidget {
  final List<({String label, double value})> data;

  const _HrHistoryStrip({required this.data});

  @override
  Widget build(BuildContext context) {
    final shown = data.length > 14 ? data.sublist(data.length - 14) : data;
    final maxVal = shown.map((e) => e.value).fold(0.0, math.max);
    return Container(
      height: 170,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.legacyDarkHairlineFaint),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final point = shown[i];
          final barH =
              maxVal > 0 ? (point.value / maxVal) * 90 : 0.0;
          return SizedBox(
            width: 44,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(point.value.toStringAsFixed(0),
                    style: const TextStyle(
                        fontSize: 9, color: NotelColors.textSecondary)),
                const SizedBox(height: 4),
                Container(
                  width: 14,
                  height: math.max(2, barH),
                  decoration: BoxDecoration(
                    color: NotelColors.heartRateRed
                        .withValues(alpha: 0.75),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(point.label,
                    style: const TextStyle(
                        fontSize: 8, color: NotelColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          );
        },
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
        id: id is num ? id.toInt() : 0,
        name: '${c['name'] ?? 'Category'}',
        color: color,
      ));
    }
  }
  return out;
}

/// Round 18b — renders an insight's `text` for display.
///
/// Some server insights carry a raw biometric JSON blob as their text
/// (e.g. `{"sleepMins":433,"deepSleepMins":76,"avgHr":58,
/// "hrv":73.29897959183671,"calories":2271}`) which must never be shown
/// raw (founder bug report). Known biometric fields are parsed into a
/// human-readable summary with rounded numbers (`HRV 73.3`, never 17
/// decimals) and the app's sleep format.
///
/// - Prose (not JSON) → returned unchanged.
/// - JSON with renderable biometric fields → summary string.
/// - JSON-looking but unparseable, or JSON with no renderable fields →
///   null → the caller skips the card (never show raw JSON).
/// Never throws.
String? renderInsightText(String text) {
  final trimmed = text.trim();
  // Server reports (Graph Analysis Report) carry full HTML. Raw markup
  // must never reach the screen — convert to clean readable text.
  if (_looksLikeHtml(trimmed)) {
    final clean = htmlToPlainText(trimmed);
    return clean.isEmpty ? null : clean;
  }
  if (!trimmed.startsWith('{')) return text; // prose → as-is
  Map<String, dynamic>? obj;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) obj = decoded;
  } catch (_) {}
  if (obj == null) return null; // JSON-looking but unparseable → skip
  int? asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  double? asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  String fmtSleep(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    return '${m}m';
  }

  // Founder rule: biometric zeros are failed reads — skip them.
  // (Spike counts of 0 are real, but a 0-spike pattern card says
  // nothing, so it is skipped like the rest.)
  final parts = <String>[];
  final sleepMins = asInt(obj['sleepMins']);
  if (sleepMins != null && sleepMins > 0) {
    parts.add('Sleep ${fmtSleep(sleepMins)}');
  }
  final deep = asInt(obj['deepSleepMins']);
  if (deep != null && deep > 0) parts.add('Deep ${fmtSleep(deep)}');
  final avgHr = asInt(obj['avgHr']);
  if (avgHr != null && avgHr > 0) parts.add('Avg HR $avgHr');
  final hrv = asDouble(obj['hrv']);
  if (hrv != null && hrv > 0) parts.add('HRV ${hrv.toStringAsFixed(1)}');
  final calories = asInt(obj['calories']);
  if (calories != null && calories > 0) parts.add('$calories cal');
  final spikes = asInt(obj['spikes']);
  if (spikes != null && spikes > 0) {
    parts.add('$spikes spike${spikes == 1 ? '' : 's'}');
  }
  if (parts.isEmpty) return null; // no renderable fields → skip
  return parts.join(' · ');
}

/// Sync-pull insights, curated the way native curates them for display
/// (SettingsScreen's AI Insights History): "Biometrics" and "BodyLoad"
/// rows are machine data series (per-day JSON blobs), never display
/// cards — native excludes both types outright. Of the rest: dedupe
/// identical texts, non-dismissed first, newest first, capped at 15
/// like native. Never throws.
List<Map<String, dynamic>> parseTrendsInsights(dynamic raw) {
  if (raw is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final i in raw) {
    if (i is Map<String, dynamic> && '${i['text'] ?? ''}'.isNotEmpty) {
      final type = '${i['type'] ?? ''}';
      if (type == 'Biometrics' || type == 'BodyLoad') continue;
      out.add(i);
    }
  }
  out.sort((a, b) {
    final da = a['isDismissed'] == true ? 1 : 0;
    final db = b['isDismissed'] == true ? 1 : 0;
    if (da != db) return da.compareTo(db);
    return parseEpochMs(b['timestamp']).compareTo(parseEpochMs(a['timestamp']));
  });
  final seen = <String>{};
  out.removeWhere((i) => !seen.add('${i['text']}'.trim()));
  return out.length > 15 ? out.sublist(0, 15) : out;
}

/// Lenient decode of `profile['heartRateHistory']` (a JSON string).
/// Accepts a list of {date, value-ish} maps or a {date: value} map.
/// Zeros are dropped (failed reads); unparseable → empty. Never throws.
List<({String label, double value})> parseHeartRateHistory(dynamic raw) {
  if (raw is! String || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    final out = <({String label, double value})>[];
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final label = '${item['date'] ?? item['day'] ?? item['label'] ?? ''}';
          final value = _firstPositiveNum(item);
          if (label.isNotEmpty && value != null) {
            out.add((label: label, value: value));
          }
        }
      }
    } else if (decoded is Map<String, dynamic>) {
      for (final e in decoded.entries) {
        final v = e.value;
        if (v is num && v > 0) out.add((label: e.key, value: v.toDouble()));
      }
      out.sort((a, b) => a.label.compareTo(b.label));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

double? _firstPositiveNum(Map<String, dynamic> map) {
  for (final key in ['avg', 'value', 'bpm', 'restingHr', 'heartRate']) {
    final v = map[key];
    if (v is num && v > 0) return v.toDouble();
  }
  for (final v in map.values) {
    if (v is num && v > 0) return v.toDouble();
  }
  return null;
}

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

/// True when [s] contains HTML markup (tags), as the server's Graph
/// Analysis Report text does.
bool _looksLikeHtml(String s) =>
    s.contains(RegExp(r'<[a-zA-Z][^>]*>'));

/// Converts an HTML fragment (server report text) to clean readable
/// plain text: script/style blocks dropped, block boundaries become
/// line breaks, list items get bullets, all tags and inline styles
/// removed, entities decoded, blank lines collapsed. The report's
/// actual content (headings, paragraphs) is preserved. Never throws.
String htmlToPlainText(String html) {
  var s = html;
  s = s.replaceAll(
      RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>',
          caseSensitive: false),
      '');
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n• ');
  s = s.replaceAll(
      RegExp(r'</(p|div|h[1-6]|li|tr|section|article|header|footer)\s*>',
          caseSensitive: false),
      '\n');
  s = s.replaceAll(RegExp(r'<[^>]*>'), '');
  s = _decodeHtmlEntities(s);
  final lines = s
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .toList();
  return lines.join('\n');
}

String _decodeHtmlEntities(String s) {
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'");
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    // Range-check: fromCharCode throws on values above U+10FFFF, and
    // server-supplied text is untrusted — leave bad entities literal.
    return (code == null || code < 0 || code > 0x10FFFF)
        ? m.group(0)!
        : String.fromCharCode(code);
  });
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return (code == null || code < 0 || code > 0x10FFFF)
        ? m.group(0)!
        : String.fromCharCode(code);
  });
  // &amp; last, so "&amp;lt;" decodes to the literal "&lt;", not "<".
  return out.replaceAll('&amp;', '&');
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
