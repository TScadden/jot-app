import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/medication_timeline.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_summary.dart' show dateStrOf;
import 'package:tabs_lab/src/features/tools/medication_timeline_strings.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';
import 'package:tabs_lab/src/theme/animations.dart';

/// Phase 1, item 2b — the medication timeline VIEW (spec §3:
/// Option B primary — change markers overlaid on the Daily Score
/// chart — with Option A per-medication lanes as the drill-down).
///
/// All claim/label copy comes from [MedicationTimelineStrings]
/// (Juno's final verbatim set for item 2) — this file adds NO
/// copy of its own; everything else rendered is data-derived
/// (names, doses, recorded date strings, counts) or a bare
/// number (the 7/14/30 window selector).
///
/// Premium (founder Q2 crew assumption): the timeline screen and
/// its before/after panel are premium; the 2a capture stays free
/// for everyone and is untouched. The gate follows the app's
/// existing pattern: the app-owned [BillingService] threaded
/// through Tools → Medications when one exists, else the
/// server-membership check ([TabsBackend.fetchMembership] — the
/// Health Coach / Tips gate). No new gating mechanism, no Lab
/// bypass.
///
/// Score integrity: this screen READS [HealthHistoryStore] only
/// (coverage + readRange). It never writes the store and never
/// triggers score computation.

/// The marker label for [marker], built ONLY from Juno's Draft 6
/// patterns with the recorded snapshot values.
String medicationMarkerLabel(TimelineMarker marker) => switch (marker.kind) {
      TimelineMarkerKind.start => MedicationTimelineStrings.startedLabel(
          marker.medName, marker.doseAtEvent),
      TimelineMarkerKind.stop =>
        MedicationTimelineStrings.stoppedLabel(marker.medName),
      TimelineMarkerKind.doseChange =>
        MedicationTimelineStrings.doseChangedLabel(
            marker.medName, marker.oldValue, marker.newValue),
      TimelineMarkerKind.frequencyChange =>
        MedicationTimelineStrings.scheduleChangedLabel(
            marker.medName, marker.oldValue, marker.newValue),
      TimelineMarkerKind.restore => MedicationTimelineStrings.restartedLabel(
          marker.medName, marker.doseAtEvent),
    };

/// Persists the "non-causation disclaimer has been shown on this
/// screen" flag (first open only). Injectable IO so tests never
/// touch platform channels (ToolOrderStore pattern).
class MedicationTimelineSeenStore {
  static const String storageKey = 'medication_timeline_seen_v1';

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) => const FlutterSecureStorage().write(key: key, value: value);

  /// Test seam.
  void debugSetIO({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  }) {
    if (read != null) _read = read;
    if (write != null) _write = write;
  }

  Future<bool> hasSeen() async {
    try {
      final raw = await _read(storageKey).timeout(const Duration(seconds: 3));
      return raw == '1';
    } catch (_) {
      // A wedged storage channel must not block the screen; the
      // disclaimer also always renders on the panel.
      return true;
    }
  }

  Future<void> markSeen() async {
    try {
      await _write(storageKey, '1').timeout(const Duration(seconds: 3));
    } catch (_) {
      // Best-effort only.
    }
  }
}

class MedicationTimelineScreen extends StatefulWidget {
  /// Injectable for tests.
  final TabsBackend? backend;
  final HealthHistoryStore? historyStore;
  final MedicationTimelineSeenStore? seenStore;

  /// The app-owned billing service, threaded Tools → Medications
  /// → here (the app's existing pattern). Null in contexts where
  /// no service exists (the Lab) — the gate then falls back to
  /// the server-membership check, exactly like the Health Coach.
  final BillingService? billingService;

  const MedicationTimelineScreen({
    super.key,
    this.backend,
    this.historyStore,
    this.seenStore,
    this.billingService,
  });

  @override
  State<MedicationTimelineScreen> createState() =>
      _MedicationTimelineScreenState();
}

class _MedicationTimelineScreenState extends State<MedicationTimelineScreen> {
  late final TabsBackend _backend;
  late final HealthHistoryStore _historyStore;
  late final MedicationTimelineSeenStore _seenStore;

  /// null = gate check still running; true = unlocked.
  bool? _unlocked;
  bool _loading = true;
  bool _showFirstOpenDisclaimer = false;
  MedicationTimelineData? _data;
  StreamSubscription<BillingState>? _billingSub;

  // Series toggles (Draft 9 labels; Q4 crew assumption defaults:
  // Daily Score on, Flare days on, Migraine days on, Symptom
  // logs off).
  bool _showScore = true;
  bool _showFlare = true;
  bool _showMigraine = true;
  bool _showSymptoms = false;

  final ScrollController _chartScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _historyStore = widget.historyStore ?? HealthHistoryStore.instance;
    _seenStore = widget.seenStore ?? MedicationTimelineSeenStore();
    _checkGate();
  }

  @override
  void dispose() {
    _billingSub?.cancel();
    _chartScroll.dispose();
    super.dispose();
  }

  Future<void> _checkGate() async {
    final service = widget.billingService;
    if (service != null) {
      setState(() => _unlocked = service.state.isUnlimited == true);
      _billingSub = service.states.listen((state) {
        if (!mounted) return;
        final unlocked = state.isUnlimited == true;
        if (unlocked == _unlocked) return;
        setState(() => _unlocked = unlocked);
        if (unlocked && _data == null) unawaited(_load());
      });
      if (_unlocked == true) await _load();
      return;
    }
    try {
      final membership = await _backend.fetchMembership();
      if (!mounted) return;
      setState(() => _unlocked = membership.isUnlimited);
    } catch (_) {
      if (!mounted) return;
      setState(() => _unlocked = false);
    }
    if (_unlocked == true) await _load();
  }

  Future<void> _load() async {
    try {
      final profile = await _backend.fetchProfile();
      final medRows = parseMedicationBlob(
          TabsBackend.decodeProfileList(profile?['medications']));
      // VC 100109 combine: the unified read path is nullable
      // (item 3's degradation semantics); this screen's signed
      // behavior is the empty list on any failure.
      final events =
          await _backend.fetchMedicationChangeEvents() ?? const [];
      final entries = await _backend.fetchLogEntryDtos();
      final categories = await _backend.fetchLogCategories();

      // Score read bounds: the store's own coverage, widened to
      // cover every marker anchor and entry day, so readRange
      // returns the full series the derivation joins against.
      final coverage = await _historyStore.coverage();
      var start = coverage.earliest;
      var end = coverage.latest;
      void widen(DateTime day) {
        final s = dateStrOf(day);
        if (start == null || s.compareTo(start!) < 0) start = s;
        if (end == null || s.compareTo(end!) > 0) end = s;
      }

      for (final e in events) {
        widen(DateTime.fromMillisecondsSinceEpoch(e.recordedAt));
        final eff = e.effectiveDate;
        if (eff != null) {
          final parsed = parseMedicationDate(eff);
          if (parsed != null) widen(parsed);
        }
      }
      for (final row in medRows) {
        final s = parseMedicationDate(row.startDate);
        if (s != null) widen(s);
        final en = row.endedDate == null
            ? null
            : parseMedicationDate(row.endedDate!);
        if (en != null) widen(en);
      }
      for (final entry in entries) {
        widen(DateTime.fromMillisecondsSinceEpoch(entry.timestamp));
      }
      widen(DateTime.now());

      final rows = (start != null && end != null)
          ? await _historyStore.readRange(start!, end!)
          : const <String, DailyBiometrics>{};
      final data = buildMedicationTimeline(
        events: events,
        medications: medRows,
        scoresByDate: scoreMapFromHistoryRows(rows),
        entries: entries,
        categories: categories,
        today: DateTime.now(),
      );
      final seen = await _seenStore.hasSeen();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        _showFirstOpenDisclaimer = !seen;
      });
      if (!seen) unawaited(_seenStore.markSeen());
      _scrollChartToEnd();
    } catch (_) {
      if (!mounted) return;
      // Honest empty on any failure: the timeline is built over
      // fully empty inputs, so the screen renders its ruled
      // empty states and nothing is invented. (VC 100109
      // combine — Vera C3 comment correction: the earlier text
      // overstated this fallback as rendering seeds + scores;
      // on a load failure neither is available.)
      setState(() {
        _data = buildMedicationTimeline(
          events: const [],
          medications: const [],
          scoresByDate: const {},
          entries: const [],
          categories: const [],
          today: DateTime.now(),
        );
        _loading = false;
      });
    }
  }

  void _scrollChartToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chartScroll.hasClients) {
        _chartScroll.jumpTo(_chartScroll.position.maxScrollExtent);
      }
    });
  }

  void _openPanel(TimelineMarker marker) {
    final data = _data;
    if (data == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NotelColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => MedicationChangePanel(marker: marker, data: data),
    );
  }

  void _onChartTap(TapUpDetails details) {
    final data = _data;
    if (data == null || data.days.isEmpty) return;
    final index =
        (details.localPosition.dx / MedicationTimelineChart.pxPerDay).floor();
    if (index < 0 || index >= data.days.length) return;
    final dayMarkers = data.days[index].markers;
    if (dayMarkers.isEmpty) return;
    if (dayMarkers.length == 1) {
      _openPanel(dayMarkers.single);
      return;
    }
    // Several changes share this day: each opens its OWN panel
    // (test 14) — offer the day's marker labels, nothing else.
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NotelColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final marker in dayMarkers)
              ListTile(
                title: Text(
                  medicationMarkerLabel(marker),
                  style: const TextStyle(color: NotelColors.textPrimary),
                ),
                subtitle: Text(
                  marker.dateDisplay,
                  style: const TextStyle(color: NotelColors.textSecondary),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openPanel(marker);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openLane(TimelineMedLane lane) {
    final data = _data;
    if (data == null) return;
    Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => MedicationLaneScreen(lane: lane, data: data),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          MedicationTimelineStrings.title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_unlocked == null || (_unlocked == true && _loading)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_unlocked != true) return _lockedView();
    final data = _data;
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
      children: [
        const Text(
          MedicationTimelineStrings.intro,
          style: TextStyle(fontSize: 14, color: NotelColors.textSecondary),
        ),
        if (_showFirstOpenDisclaimer) ...[
          const SizedBox(height: 16),
          _disclaimerCard(MedicationTimelineStrings.nonCausationDisclaimer),
        ],
        const SizedBox(height: 16),
        _toggles(),
        const SizedBox(height: 12),
        _chartCard(data),
        const SizedBox(height: 20),
        if (data.markers.isEmpty)
          const Text(
            MedicationTimelineStrings.noChangesInRange,
            style: TextStyle(fontSize: 14, color: NotelColors.textSecondary),
          )
        else
          for (final marker in data.markers) _changeRow(marker),
        if (data.lanes.isNotEmpty) ...[
          const SizedBox(height: 20),
          for (final lane in data.lanes) _medRow(lane),
        ],
      ],
    );
  }

  /// The locked state. NOTE (flagged in the build report): Juno's
  /// item 2 string set contains NO locked-state copy, so this
  /// view renders only the ruled title + intro beside the lock
  /// icon — no invented explanatory text.
  Widget _lockedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: NotelColors.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: NotelColors.cardBorder),
              ),
              child: const Icon(Icons.lock_outline,
                  size: 44, color: NotelColors.textSecondary),
            ),
            const SizedBox(height: 24),
            const Text(
              MedicationTimelineStrings.title,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              MedicationTimelineStrings.intro,
              style: TextStyle(
                  fontSize: 14, height: 1.5, color: NotelColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _disclaimerCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Text(
        text,
        style: const TextStyle(
            fontSize: 13, height: 1.45, color: NotelColors.textPrimary),
      ),
    );
  }

  Widget _toggles() {
    Widget chip(String label, bool selected, ValueChanged<bool> onChanged,
        Color dot) {
      return FilterChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
        selected: selected,
        onSelected: onChanged,
        backgroundColor: NotelColors.surface,
        selectedColor: NotelColors.primary.withValues(alpha: 0.25),
        checkmarkColor: NotelColors.primaryText,
        labelStyle: TextStyle(
          fontSize: 12,
          color: selected
              ? NotelColors.textPrimary
              : NotelColors.textSecondary,
        ),
        side: const BorderSide(color: NotelColors.cardBorder),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(MedicationTimelineStrings.toggleDailyScore, _showScore,
            (v) => setState(() => _showScore = v), NotelColors.primary),
        chip(MedicationTimelineStrings.toggleFlareDays, _showFlare,
            (v) => setState(() => _showFlare = v), NotelColors.warning),
        chip(MedicationTimelineStrings.toggleMigraineDays, _showMigraine,
            (v) => setState(() => _showMigraine = v), NotelColors.chipPink),
        chip(MedicationTimelineStrings.toggleSymptomLogs, _showSymptoms,
            (v) => setState(() => _showSymptoms = v), NotelColors.info),
      ],
    );
  }

  Widget _chartCard(MedicationTimelineData data) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: SingleChildScrollView(
        controller: _chartScroll,
        scrollDirection: Axis.horizontal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onChartTap,
          child: CustomPaint(
            size: Size(
              data.days.length * MedicationTimelineChart.pxPerDay,
              MedicationTimelineChart.height,
            ),
            painter: MedicationTimelineChartPainter(
              days: data.days,
              showScore: _showScore,
              showFlare: _showFlare,
              showMigraine: _showMigraine,
              showSymptoms: _showSymptoms,
            ),
          ),
        ),
      ),
    );
  }

  Widget _changeRow(TimelineMarker marker) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openPanel(marker),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: NotelColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  medicationMarkerLabel(marker),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  marker.dateDisplay,
                  style: const TextStyle(
                      fontSize: 12, color: NotelColors.textSecondary),
                ),
                if (marker.seeded) ...[
                  const SizedBox(height: 3),
                  const Text(
                    MedicationTimelineStrings.seededProvenance,
                    style: TextStyle(
                        fontSize: 12, color: NotelColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _medRow(TimelineMedLane lane) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openLane(lane),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: NotelColors.cardBorder),
            ),
            child: Row(
              children: [
                const Icon(Icons.medication,
                    size: 20, color: NotelColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    lane.medName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right,
                    size: 20, color: NotelColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Chart geometry constants for the timeline painter.
abstract final class MedicationTimelineChart {
  /// Fixed horizontal scale: every calendar day occupies exactly
  /// this many logical pixels, scored or not.
  static const double pxPerDay = 26;
  static const double height = 196;
}

/// The timeline chart painter (spec §3, Option B): a NEW painter
/// on a calendar-continuous date axis. Every day in range
/// occupies a slot; scored days draw the Daily Score, unscored
/// days are EMPTY GAPS — never zero-filled, never omitted (the
/// existing 14-day bar chart's omission behavior is exactly what
/// this feature may not inherit).
class MedicationTimelineChartPainter extends CustomPainter {
  final List<TimelineDay> days;
  final bool showScore;
  final bool showFlare;
  final bool showMigraine;
  final bool showSymptoms;

  const MedicationTimelineChartPainter({
    required this.days,
    required this.showScore,
    required this.showFlare,
    required this.showMigraine,
    required this.showSymptoms,
  });

  static const double _baselineY = 158;
  static const double _plotTop = 44;
  static const double _flareRowY = 14;
  static const double _migraineRowY = 28;

  @override
  void paint(Canvas canvas, Size size) {
    final px = MedicationTimelineChart.pxPerDay;
    final baselinePaint = Paint()
      ..color = NotelColors.legacyDarkDivider
      ..strokeWidth = 1;
    canvas.drawLine(
        const Offset(0, _baselineY), Offset(size.width, _baselineY),
        baselinePaint);

    const monthNames = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];

    for (var i = 0; i < days.length; i++) {
      final day = days[i];
      final cx = i * px + px / 2;

      // Marker: a gold vertical rule + diamond on the axis.
      if (day.markers.isNotEmpty) {
        final linePaint = Paint()
          ..color = NotelColors.streakGold.withValues(alpha: 0.55)
          ..strokeWidth = 1.5;
        canvas.drawLine(Offset(cx, _plotTop - 6), Offset(cx, _baselineY),
            linePaint);
        final diamond = Path()
          ..moveTo(cx, _plotTop - 14)
          ..lineTo(cx + 5, _plotTop - 8)
          ..lineTo(cx, _plotTop - 2)
          ..lineTo(cx - 5, _plotTop - 8)
          ..close();
        canvas.drawPath(
            diamond, Paint()..color = NotelColors.streakGold);
      }

      // Daily Score spine: a bar ONLY on scored days. An unscored
      // day draws nothing — the gap is the honest render.
      if (showScore && day.score != null) {
        final h = (day.score! / 100) * (_baselineY - _plotTop);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 5, _baselineY - h, 10, h),
          const Radius.circular(3),
        );
        canvas.drawRRect(rect, Paint()..color = NotelColors.primary);
      }

      if (showFlare && day.isFlareDay) {
        canvas.drawCircle(Offset(cx, _flareRowY), 4,
            Paint()..color = NotelColors.warning);
      }
      if (showMigraine && day.isMigraineDay) {
        canvas.drawCircle(Offset(cx, _migraineRowY), 4,
            Paint()..color = NotelColors.chipPink);
      }

      // Symptom logs: a small tick below the baseline, height ∝
      // the day's count (capped for legibility).
      if (showSymptoms && day.symptomLogCount > 0) {
        final h = math.min(day.symptomLogCount, 8) * 2.0;
        canvas.drawRect(
          Rect.fromLTWH(cx - 3, _baselineY + 4, 6, h),
          Paint()..color = NotelColors.info,
        );
      }

      // Sparse date labels (data-derived) — the 1st of a month,
      // plus the first day of the axis.
      if (day.date.day == 1 || i == 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${monthNames[day.date.month]} ${day.date.day}',
            style: const TextStyle(
                fontSize: 9, color: NotelColors.textSecondary),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(cx - tp.width / 2, _baselineY + 22));
      }
    }
  }

  @override
  bool shouldRepaint(MedicationTimelineChartPainter old) =>
      old.days != days ||
      old.showScore != showScore ||
      old.showFlare != showFlare ||
      old.showMigraine != showMigraine ||
      old.showSymptoms != showSymptoms;
}

/// The before/after panel for ONE marker (spec §3; Juno R2/R4/R5
/// + D1). Contents, in order: marker label; date (verbatim);
/// provenance when seeded; the non-causation disclaimer; the
/// 7/14/30 window selector; EITHER the two window averages +
/// rule note (D1 floor met) OR the below-floor string (floor
/// unmet, no partial averages); the R5 disclaimer, once.
///
/// R2: the two averages render in IDENTICAL neutral styling,
/// before-window first, always — no difference, percent, arrow,
/// or color/ordering contrast exists in this widget.
class MedicationChangePanel extends StatefulWidget {
  final TimelineMarker marker;
  final MedicationTimelineData data;

  const MedicationChangePanel({
    super.key,
    required this.marker,
    required this.data,
  });

  @override
  State<MedicationChangePanel> createState() => _MedicationChangePanelState();
}

class _MedicationChangePanelState extends State<MedicationChangePanel> {
  int _windowDays = 14;

  @override
  Widget build(BuildContext context) {
    final marker = widget.marker;
    final result = widget.data.windowsFor(marker, _windowDays);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              medicationMarkerLabel(marker),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              marker.dateDisplay,
              style: const TextStyle(
                  fontSize: 13, color: NotelColors.textSecondary),
            ),
            if (marker.seeded) ...[
              const SizedBox(height: 4),
              const Text(
                MedicationTimelineStrings.seededProvenance,
                style:
                    TextStyle(fontSize: 13, color: NotelColors.textSecondary),
              ),
            ],
            const SizedBox(height: 14),
            const Text(
              MedicationTimelineStrings.nonCausationDisclaimer,
              style: TextStyle(
                  fontSize: 13, height: 1.45, color: NotelColors.textPrimary),
            ),
            const SizedBox(height: 16),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment<int>(value: 7, label: Text('7')),
                ButtonSegment<int>(value: 14, label: Text('14')),
                ButtonSegment<int>(value: 30, label: Text('30')),
              ],
              selected: {_windowDays},
              onSelectionChanged: (selection) =>
                  setState(() => _windowDays = selection.single),
              style: ButtonStyle(
                foregroundColor:
                    WidgetStateProperty.all(NotelColors.textPrimary),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? NotelColors.primary.withValues(alpha: 0.25)
                      : NotelColors.surfaceHigh,
                ),
                side: WidgetStateProperty.all(
                    const BorderSide(color: NotelColors.cardBorder)),
              ),
            ),
            const SizedBox(height: 16),
            if (result.floorMet) ...[
              _averageRow(
                MedicationTimelineStrings.windowLabelBefore(
                    result.beforeSpanDays),
                MedicationTimelineStrings.windowValue(
                    result.beforeAverage!, result.beforeScoredDays),
              ),
              const SizedBox(height: 10),
              _averageRow(
                MedicationTimelineStrings.windowLabelAfter(
                    result.afterSpanDays),
                MedicationTimelineStrings.windowValue(
                    result.afterAverage!, result.afterScoredDays),
              ),
              const SizedBox(height: 14),
              const Text(
                MedicationTimelineStrings.ruleNote,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: NotelColors.textSecondary),
              ),
            ] else
              Text(
                MedicationTimelineStrings.belowFloorMessage(
                    result.beforeScoredDays, result.afterScoredDays),
                style: const TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: NotelColors.textPrimary),
              ),
            const SizedBox(height: 16),
            const Text(
              MedicationTimelineStrings.screenDisclaimer,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: NotelColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  /// One window average row. Both rows use this exact builder —
  /// identical styling for before and after is structural, not
  /// a convention (R2).
  Widget _averageRow(String label, String value) {
    const labelStyle = TextStyle(
      fontSize: 13,
      color: NotelColors.textSecondary,
    );
    const valueStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: NotelColors.textPrimary,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(label, style: labelStyle)),
        Text(value, style: valueStyle),
      ],
    );
  }
}

/// The per-medication lane drill-down (spec §3, Option A as
/// drill-down): the med's events chronologically on the same
/// calendar axis — dose/frequency segments between events from
/// the governing snapshot, seeded boundaries carrying the
/// provenance label; tapping an event row opens the same panel.
class MedicationLaneScreen extends StatelessWidget {
  final TimelineMedLane lane;
  final MedicationTimelineData data;

  const MedicationLaneScreen({super.key, required this.lane, required this.data});

  void _openPanel(BuildContext context, TimelineMarker marker) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NotelColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => MedicationChangePanel(marker: marker, data: data),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          lane.medName,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
        children: [
          _segmentStrip(context),
          const SizedBox(height: 20),
          for (final marker in lane.markers)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: NotelColors.surface,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _openPanel(context, marker),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: NotelColors.cardBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          medicationMarkerLabel(marker),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: NotelColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          marker.dateDisplay,
                          style: const TextStyle(
                              fontSize: 12,
                              color: NotelColors.textSecondary),
                        ),
                        if (marker.seeded) ...[
                          const SizedBox(height: 3),
                          const Text(
                            MedicationTimelineStrings.seededProvenance,
                            style: TextStyle(
                                fontSize: 12,
                                color: NotelColors.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The lane's dose/frequency segments on the shared calendar
  /// scale (same px/day as the main chart): each block's width
  /// is its span in days, labeled with the governing snapshot's
  /// dose · frequency (data-derived values only).
  Widget _segmentStrip(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final segment in lane.segments)
              Container(
                width: math.max(
                  segment.endDate.difference(segment.startDate).inDays *
                      MedicationTimelineChart.pxPerDay,
                  72,
                ),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: segment.isPresent
                      ? NotelColors.primary.withValues(alpha: 0.18)
                      : NotelColors.surfaceHigh.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: NotelColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatMedArchiveDate(segment.startDate),
                      style: const TextStyle(
                          fontSize: 11, color: NotelColors.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (segment.dose.isNotEmpty) segment.dose,
                        if (segment.frequency.isNotEmpty) segment.frequency,
                      ].join(' · '),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: NotelColors.textPrimary,
                      ),
                    ),
                    if (segment.startsSeeded) ...[
                      const SizedBox(height: 4),
                      const Text(
                        MedicationTimelineStrings.seededProvenance,
                        style: TextStyle(
                            fontSize: 11, color: NotelColors.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
