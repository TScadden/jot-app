import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 8 — Weekly Snapshot card.
///
/// Pixel-port of the native `ui/component/WeeklySnapshotCard.kt`:
/// bar-chart icon + "Weekly Snapshot" title, refresh icon, metric
/// dropdown, "7-Day Avg" label, 7-day chart (Mon–Sun) with tap-to-select
/// tooltip.
///
/// DATA STATUS THIS ROUND: no data sources wired yet (see
/// `lib/src/data/weekly_snapshot.dart` for the future hookups). Every
/// metric shows its native empty state; Logs shows its real zero count.
/// Nothing is invented.
///
/// The metric switcher is fully live: all 7 metrics, dropdown styled
/// like the native `DropdownMenu`, selection resets the tapped point.
///
/// Round 13 — real data via [loadData]: loaded on init, on metric switch
/// (resetting the tapped point), and on refresh-button tap. When [loadData]
/// is null the card keeps the round-8 empty states (used by tests).
class WeeklySnapshotCard extends StatefulWidget {
  final Future<WeeklySnapshotMetricData> Function(SnapshotMetric)? loadData;

  const WeeklySnapshotCard({super.key, this.loadData});

  @override
  State<WeeklySnapshotCard> createState() => _WeeklySnapshotCardState();
}

class _WeeklySnapshotCardState extends State<WeeklySnapshotCard> {
  // Native default: SLEEP_HOURS (WeeklySnapshotMetric.DEFAULT).
  SnapshotMetric _selected = SnapshotMetric.sleepHours;
  int? _selectedPoint;

  /// Latest loaded data per metric; null until the first load completes.
  WeeklySnapshotMetricData? _loaded;

  /// Guards against stale loads when the user switches metrics quickly.
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final loader = widget.loadData;
    if (loader == null) return;
    final generation = ++_loadGeneration;
    WeeklySnapshotMetricData data;
    try {
      data = await loader(_selected);
    } catch (_) {
      // A throwing loader is a bug — fall back to the native empty state
      // rather than leaving stale data on screen.
      data = emptyMetricData(_selected);
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loaded = data;
    });
  }

  void _selectMetric(SnapshotMetric m) {
    setState(() {
      _selected = m;
      _selectedPoint = null; // native resets the tapped point on switch
      _loaded = null; // drop stale data for the old metric
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    // Fast first paint + honest fallback: the native empty state until the
    // loader delivers (or when no loader is wired).
    final data = _loaded ?? emptyMetricData(_selected);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.legacyDarkDivider, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const SizedBox(height: 8),
            _MetricSelector(
              selected: _selected,
              onSelect: _selectMetric,
            ),
            const SizedBox(height: 12),
            if (data.isEmpty)
              _emptyState(data)
            else ...[
              _avgRow(data),
              const SizedBox(height: 8),
              _tooltip(data),
              // Round 14 — keyed by metric + load generation so the
              // draw-in animation restarts on every metric switch and
              // refresh, not just first paint.
              _SnapshotChart(
                key: ValueKey('${_selected.name}_$_loadGeneration'),
                data: data,
                selectedIndex: _selectedPoint,
                onSelectIndex: (i) => setState(() => _selectedPoint = i),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Row(
          children: [
            Icon(Icons.bar_chart, size: 20, color: NotelColors.primary),
            SizedBox(width: 8),
            Text(
              'Weekly Snapshot',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: NotelColors.textPrimary,
              ),
            ),
          ],
        ),
        // Refresh: reloads the current metric's data via [loadData].
        // No loader → no-op (round-8 behavior).
        IconButton(
          onPressed: () => _reload(),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(
            minWidth: 48,
            minHeight: 48,
          ),
          tooltip: 'Refresh weekly snapshot',
          icon: const Icon(
            Icons.refresh,
            size: 16,
            color: NotelColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _emptyState(WeeklySnapshotMetricData data) {
    return SizedBox(
      height: 140,
      child: Center(
        child: Text(
          data.emptyMessage ?? 'No data available past 7 days',
          style: const TextStyle(
            fontSize: 13,
            color: NotelColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _avgRow(WeeklySnapshotMetricData data) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          data.averageOrTotalText,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: NotelColors.textSecondary,
          ),
        ),
        // Blood Pressure Sys/Dia legend (native shows it when available).
        if (data.metric.isBloodPressure && data.isAvailable)
          const Row(
            children: [
              _LegendDot(color: NotelColors.error),
              SizedBox(width: 4),
              Text('Sys',
                  style: TextStyle(
                      fontSize: 10, color: NotelColors.textSecondary)),
              SizedBox(width: 8),
              _LegendDot(color: NotelColors.info),
              SizedBox(width: 4),
              Text('Dia',
                  style: TextStyle(
                      fontSize: 10, color: NotelColors.textSecondary)),
            ],
          ),
      ],
    );
  }

  Widget _tooltip(WeeklySnapshotMetricData data) {
    final i = _selectedPoint;
    if (i == null || i < 0 || i >= data.points.length) {
      return const SizedBox.shrink();
    }
    final pt = data.points[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 8.0),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: NotelColors.legacyDarkDivider, width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              '${pt.dateStr} (${pt.dayLabel}): ${_formatValue(data, pt)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                // Round 49 (audit H8): primary on this surfaceHigh fill
                // measures 4.21:1 — below the 4.5 floor. textPrimary on
                // surfaceHigh is 14.00:1; bold keeps the emphasis.
                color: NotelColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _selectedPoint = null),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 48,
              minHeight: 48,
            ),
            tooltip: 'Dismiss Tooltip',
            icon: const Icon(
              Icons.close,
              size: 14,
              color: NotelColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// Tooltip value formatting, verbatim from native `SnapshotDataContent`.
  String _formatValue(WeeklySnapshotMetricData data, DailySnapshotPoint pt) {
    if (pt.secondaryValue != null) {
      return '${pt.value?.toInt() ?? '--'}/${pt.secondaryValue!.toInt()} ${data.metric.unit}';
    }
    if (pt.value != null) {
      if (data.metric.unit == 'h') {
        final h = pt.value!.toInt();
        final m = ((pt.value! - h) * 60).toInt();
        return '${h}h ${m}m';
      } else if (data.metric.unit == '%') {
        return '${pt.value!.toInt()}%';
      }
      return '${pt.value!.toInt()} ${data.metric.unit}'.trim();
    }
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);
    if (pt.dateStr == todayStr &&
        const {'Resting Heart Rate', 'Sleep Hours', 'Active Calories'}
            .contains(data.metric.displayName)) {
      final noun = switch (data.metric) {
        SnapshotMetric.restingHeartRate => 'resting heart rate',
        SnapshotMetric.sleepHours => 'sleep data',
        _ => 'calorie data',
      };
      return "Today's $noun isn't ready yet. Check back tomorrow.";
    }
    return 'No data';
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  const _LegendDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The metric selector box (Round 49: 48dp tall target) + floating
/// dropdown, styled like the native `DropdownMenu` (NotelSurfaceHigh,
/// current metric Bold).
class _MetricSelector extends StatefulWidget {
  final SnapshotMetric selected;
  final ValueChanged<SnapshotMetric> onSelect;

  const _MetricSelector({required this.selected, required this.onSelect});

  @override
  State<_MetricSelector> createState() => _MetricSelectorState();
}

class _MetricSelectorState extends State<_MetricSelector> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _targetKey = GlobalKey();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _removeEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _toggle() {
    if (_entry != null) {
      _removeEntry();
      return;
    }
    final renderBox =
        _targetKey.currentContext?.findRenderObject() as RenderBox?;
    final width = renderBox?.size.width ?? 300.0;
    _entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _removeEntry,
              behavior: HitTestBehavior.opaque,
              child: Container(color: Colors.transparent),
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 4),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: width,
                decoration: BoxDecoration(
                  color: NotelColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: NotelColors.legacyDarkDivider, width: 1),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: SnapshotMetric.values.map((m) {
                    final isCurrent = m == widget.selected;
                    return InkWell(
                      onTap: () {
                        _removeEntry();
                        widget.onSelect(m);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12.0, vertical: 12.0),
                        child: Text(
                          m.displayName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isCurrent
                                ? FontWeight.bold
                                : FontWeight.normal,
                            // Round 49 (audit H8): the current item's
                            // primary on this surfaceHigh menu measured
                            // 4.21:1; bold textPrimary (14.00:1) still
                            // marks the current metric.
                            color: NotelColors.textPrimary,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        key: _targetKey,
        onTap: _toggle,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: NotelColors.surfaceHigh,
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: NotelColors.legacyDarkDivider, width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.selected.displayName,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  // Round 49 (audit H8): primary on surfaceHigh measured
                  // 4.21:1; textPrimary is 14.00:1. The arrow icon below
                  // keeps the purple accent (icons need 3:1; primary on
                  // surfaceHigh clears that at 4.21).
                  color: NotelColors.textPrimary,
                ),
              ),
              const Icon(
                Icons.arrow_drop_down,
                color: NotelColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 7-day chart canvas — port of native
/// `WeeklySnapshotInteractiveCanvas`: 3 gridlines, line chart with gaps
/// (Sleep / Resting HR), bars (HR Spikes / Calories / Logs / Habit
/// Completion), dual Sys/Dia lines (Blood Pressure), day labels, and
/// tap-to-select.
///
/// Round 14 — the series draws itself in on appearance (a left-to-right
/// reveal driven by [progress]); day labels are never clipped. Under
/// reduced motion the chart renders complete instantly.
class _SnapshotChart extends StatefulWidget {
  final WeeklySnapshotMetricData data;
  final int? selectedIndex;
  final ValueChanged<int?> onSelectIndex;

  const _SnapshotChart({
    super.key,
    required this.data,
    required this.selectedIndex,
    required this.onSelectIndex,
  });

  @override
  State<_SnapshotChart> createState() => _SnapshotChartState();
}

class _SnapshotChartState extends State<_SnapshotChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion: no controller animation — the painter draws the
    // full chart (progress 1) with no repaint subscription.
    final progress =
        animationsDisabled(context) ? null : _controller;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(details.globalPosition);
        // The painter reserves 20dp for labels; taps map over the chart area.
        final chartWidth = box.size.width;
        final stepX = chartWidth / widget.data.points.length;
        final idx =
            (local.dx / stepX).floor().clamp(0, widget.data.points.length - 1);
        widget.onSelectIndex(idx == widget.selectedIndex ? null : idx);
      },
      child: SizedBox(
        height: 160,
        child: CustomPaint(
          painter: _SnapshotChartPainter(
            data: widget.data,
            selectedIndex: widget.selectedIndex,
            progress: progress,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _SnapshotChartPainter extends CustomPainter {
  final WeeklySnapshotMetricData data;
  final int? selectedIndex;

  /// Draw-in progress, 0..1. Null = draw everything (reduced motion /
  /// tests). Subscribed as the repaint notifier when non-null.
  final Animation<double>? progress;

  _SnapshotChartPainter({
    required this.data,
    required this.selectedIndex,
    this.progress,
  }) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    const bottomPadding = 24.0; // native bottomPadding = 24.dp
    final chartH = size.height - bottomPadding;
    final points = data.points;
    final stepX = size.width / points.length;
    final lineColor = data.metric.chartColor;

    double cx(int i) => (i + 0.5) * stepX;

    // Draw-in reveal: the series (and gridlines) sweep in left to right.
    // Day labels stay unclipped below.
    final p = progress == null
        ? 1.0
        : Curves.easeOutCubic.transform(progress!.value);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, size.width * p, size.height));

    // Horizontal grid lines (3).
    final gridPaint = Paint()
      ..color = NotelColors.chartGrid
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = chartH * (i / 2);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (data.metric.isBarChart) {
      _paintBars(canvas, chartH, stepX, lineColor);
    } else if (data.metric.isBloodPressure) {
      _paintBloodPressure(canvas, chartH, stepX);
    } else {
      _paintLine(canvas, chartH, stepX, lineColor);
    }
    canvas.restore();

    // X-axis weekday labels.
    for (var i = 0; i < points.length; i++) {
      final isSel = selectedIndex == i;
      final tp = TextPainter(
        text: TextSpan(
          text: points[i].dayLabel,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
            color: isSel ? NotelColors.primary : NotelColors.textSecondary,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(cx(i) - tp.width / 2, size.height - 20 + (20 - tp.height) / 2),
      );
    }
  }

  void _paintLine(Canvas canvas, double chartH, double stepX, Color lineColor) {
    final points = data.points;
    final valid = points.map((p) => p.value).whereType<double>().toList();
    if (valid.isEmpty) return;
    final minV = valid.reduce((a, b) => a < b ? a : b);
    final maxV = valid.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV) == 0 ? 1.0 : (maxV - minV);

    double cx(int i) => (i + 0.5) * stepX;
    final stroke = Paint()
      ..color = lineColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    Path? segment;
    void flush() {
      if (segment != null) {
        canvas.drawPath(segment!, stroke);
        segment = null;
      }
    }

    for (var i = 0; i < points.length; i++) {
      final v = points[i].value;
      if (v != null) {
        final cy = chartH - 12 - (((v - minV) / range) * (chartH - 24));
        final pt = Offset(cx(i), cy);
        if (segment == null) {
          segment = Path()..moveTo(pt.dx, pt.dy);
        } else {
          segment!.lineTo(pt.dx, pt.dy);
        }
        final isSel = selectedIndex == i;
        canvas.drawCircle(pt, 3.5, Paint()..color = const Color(0xFFFFFFFF));
        canvas.drawCircle(
          pt,
          isSel ? 5 : 2,
          Paint()..color = isSel ? NotelColors.primary : lineColor,
        );
      } else {
        flush();
        // Native "no data" marker: ring + tick on the baseline.
        final y = chartH - 12;
        canvas.drawCircle(
          Offset(cx(i), y),
          3,
          Paint()
            ..color = NotelColors.noDataRing
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        canvas.drawLine(
          Offset(cx(i) - 2, y),
          Offset(cx(i) + 2, y),
          Paint()
            ..color = NotelColors.noDataTick
            ..strokeWidth = 1,
        );
      }
    }
    flush();
  }

  void _paintBars(Canvas canvas, double chartH, double stepX, Color lineColor) {
    final points = data.points;
    final valid = points.map((p) => p.value).whereType<double>().toList();
    final maxVal = valid.isEmpty
        ? 100.0
        : valid.reduce((a, b) => a > b ? a : b).clamp(1.0, double.infinity);
    final barWidth = (stepX * 0.45).clamp(0.0, 28.0);

    double cx(int i) => (i + 0.5) * stepX;
    for (var i = 0; i < points.length; i++) {
      final v = points[i].value;
      final isSel = selectedIndex == i;
      if (v != null && v > 0) {
        final barH = (v / maxVal) * (chartH * 0.85);
        final topY = chartH - barH;
        canvas.drawRRect(
          RRect.fromLTRBR(
            cx(i) - barWidth / 2,
            topY,
            cx(i) + barWidth / 2,
            chartH,
            const Radius.circular(4),
          ),
          Paint()
            ..color = isSel
                ? lineColor
                : lineColor.withValues(alpha: 0.75),
        );
      } else if (v == 0) {
        // Native: zero draws a small baseline dot, not a bar.
        canvas.drawCircle(
          Offset(cx(i), chartH - 3),
          3,
          Paint()..color = lineColor.withValues(alpha: 0.4),
        );
      }
    }
  }

  void _paintBloodPressure(Canvas canvas, double chartH, double stepX) {
    final points = data.points;
    final sysVals = points.map((p) => p.value).whereType<double>().toList();
    final diaVals =
        points.map((p) => p.secondaryValue).whereType<double>().toList();
    if (sysVals.isEmpty && diaVals.isEmpty) return;
    final maxVal =
        (sysVals.isEmpty ? 140.0 : sysVals.reduce((a, b) => a > b ? a : b).clamp(140.0, double.infinity)) + 10;
    final minVal =
        (diaVals.isEmpty ? 60.0 : diaVals.reduce((a, b) => a < b ? a : b).clamp(0.0, 60.0)) - 10;
    final valRange = (maxVal - minVal).clamp(1.0, double.infinity);

    double cx(int i) => (i + 0.5) * stepX;
    final sysStroke = Paint()
      ..color = NotelColors.error
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final diaStroke = Paint()
      ..color = NotelColors.info
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Path? sysPath, diaPath;

    for (var i = 0; i < points.length; i++) {
      final isSel = selectedIndex == i;
      final v = points[i].value;
      if (v != null) {
        final y = chartH - ((v - minVal) / valRange) * chartH;
        final pt = Offset(cx(i), y);
        if (sysPath == null) {
          sysPath = Path()..moveTo(pt.dx, pt.dy);
        } else {
          sysPath.lineTo(pt.dx, pt.dy);
        }
        canvas.drawCircle(pt, isSel ? 5 : 3, Paint()..color = NotelColors.error);
      } else if (sysPath != null) {
        // Native: break the segment at null days — never interpolate
        // across missing values.
        canvas.drawPath(sysPath, sysStroke);
        sysPath = null;
      }
      final sv = points[i].secondaryValue;
      if (sv != null) {
        final y = chartH - ((sv - minVal) / valRange) * chartH;
        final pt = Offset(cx(i), y);
        if (diaPath == null) {
          diaPath = Path()..moveTo(pt.dx, pt.dy);
        } else {
          diaPath.lineTo(pt.dx, pt.dy);
        }
        canvas.drawCircle(pt, isSel ? 5 : 3, Paint()..color = NotelColors.info);
      } else if (diaPath != null) {
        canvas.drawPath(diaPath, diaStroke);
        diaPath = null;
      }
    }
    if (sysPath != null) canvas.drawPath(sysPath, sysStroke);
    if (diaPath != null) canvas.drawPath(diaPath, diaStroke);
  }

  @override
  bool shouldRepaint(covariant _SnapshotChartPainter old) =>
      old.data != data ||
      old.selectedIndex != selectedIndex ||
      old.progress != progress;
}
