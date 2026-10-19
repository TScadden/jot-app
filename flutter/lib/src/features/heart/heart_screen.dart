import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/connections/health_connect_disclosure.dart';
import 'package:tabs_lab/src/features/heart/heart_spike_review_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Dark ink on a primary fill (native LegacyDarkChipInk) — the in-app
/// passing precedent for text on Tabs purple: 5.21:1 vs white's 3.80:1
/// (R49 audit S1/HE5).
const _chipInk = Color(0xFF0A0A0E);

/// Round 25 — the Heart tab, port of native `FitbitScreen.kt`
/// (legacy filename; it IS the native Heart screen).
///
/// Layout, traced from the Kotlin source (dp/sp/colors are native
/// values, dark palette — the Flutter Lab is dark-only):
/// - TopAppBar: "Heart" (28sp, FontWeight Black), and when connected a
///   date pill (surfaceHigh, radius 20, "Today"/"MMM d" 13sp SemiBold
///   + 16dp chevron-down) and a refresh icon button.
/// - The date pill opens a date picker (native: Material3
///   DatePickerDialog, selectable range = today minus 180 days
///   through today). Picking a date reloads that date's series.
/// - Refresh = native `viewModel.sync(force = true)`: bypasses the
///   native 5-minute sync throttle; here it simply re-reads Health
///   Connect for the selected date (the Dart bridge has no throttle).
/// - While a load runs AND data is already on screen, native's inline
///   "Updating sync data..." strip shows (14dp spinner + 12sp text)
///   — values are never wiped for a spinner (stale-while-revalidate
///   via [HeartDataCache]: cached values render on the first frame,
///   the refresh swaps in quietly).
/// - Not connected: native's full-screen "Connect Vital Signs" state.
///   Its Link button launches the HC permission flow directly in
///   native; here the house compliance rule (Juno MF-3, round 12)
///   puts the prominent disclosure BEFORE the system dialog, exactly
///   like the Connections screen. Flagged in the round report.
///
/// Data definitions live in heart_data.dart with file/line traces.
/// Awake window unified in Round 26 (founder decision Oct 12, 2026):
/// hours 7..22 everywhere — the Heart VM and the snapshot code agree.
class HeartScreen extends StatefulWidget {
  final String? email;

  /// Injectable for tests; defaults to a real HealthConnectService.
  final HealthConnectService? healthConnectService;

  /// Injectable for tests; defaults to the shared [HeartDataCache].
  final HeartDataCache? cache;

  const HeartScreen({super.key, this.email, this.healthConnectService, this.cache});

  @override
  State<HeartScreen> createState() => _HeartScreenState();
}

class _HeartScreenState extends State<HeartScreen> {
  late final HealthConnectService _service;
  late final HeartDataCache _cache;

  bool? _connected; // null = first check not landed yet
  bool _loading = false;
  bool _requesting = false;
  String? _error;
  DateTime _selectedDate = DateTime.now();
  HeartDayData? _data;
  DateTime? _lastSyncAt;

  String get _dateStr => _fmtDate(_selectedDate);
  String get _todayStr => _fmtDate(DateTime.now());

  static String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _service = widget.healthConnectService ?? HealthConnectService();
    _cache = widget.cache ?? HeartDataCache.instance;
    // Instant first paint from cache (memory, then disk warm).
    final cached = _cache.snapshot(_dateStr);
    if (cached != null) {
      _data = cached;
      _lastSyncAt = _cache.lastSyncAt;
    }
    unawaited(_init());
  }

  Future<void> _init() async {
    await _cache.clearIfOwnerMismatch(widget.email);
    if (_data == null) {
      await _cache.warmFromDisk(currentEmail: widget.email);
      if (!mounted) return;
      final cached = _cache.snapshot(_dateStr);
      if (cached != null && _data == null) {
        setState(() {
          _data = cached;
          _lastSyncAt = _cache.lastSyncAt;
        });
      }
    }
    await _checkConnectionAndLoad();
  }

  Future<void> _checkConnectionAndLoad() async {
    var connected = false;
    try {
      connected = await _service.isConnected();
    } catch (_) {
      // Fall back to persisted state, like the connections screen.
      // The fallback only PAINTS the connected layout: the load
      // below is the real proof, and its error surfaces even over
      // cached data (see _load) — persisted state can no longer
      // silently mask dead reads (hardening #6, Vera F8: the
      // behavior lives in _load's error path, no separate flag).
      try {
        connected = await _service.hasPersistedConnection();
      } catch (_) {
        connected = false;
      }
    }
    if (!mounted) return;
    setState(() => _connected = connected);
    if (connected) await _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // The service keeps the last read error code without clearing it
      // on success; reset it so only THIS call's failure can surface.
      _service.lastReadErrorCode = null;
      _service.lastPartialErrorCode = null;
      _service.lastReadErrorDetails = null;
      // Bounded wait (hardening #2): the bridge read itself had NO
      // timeout, so a never-returning channel call wedged this
      // screen's "Updating sync data..." spinner forever (defect
      // #3). On expiry the read fails closed as READ_TIMEOUT with
      // the error recorded on the service, and the failed-load path
      // below surfaces it — never a permanent spinner.
      final raw = await _service
          .readHeartRateSamples(_dateStr)
          .timeout(HealthConnectService.readTimeout, onTimeout: () {
        _service.lastReadErrorCode = 'READ_TIMEOUT';
        _service.lastReadErrorDetails =
            'Health Connect did not respond in time. Please try again.';
        return const <HrSample>[];
      });
      if (!mounted) return;
      // readHeartRateSamples fails closed to an empty list with the
      // error code + native exception class kept on the service; a
      // partial read records its own code (some chunks failed, real
      // data still arrived).
      final errCode = _service.lastReadErrorCode;
      final partialCode = _service.lastPartialErrorCode;
      final errDetails = _service.lastReadErrorDetails;
      // A hard failure must NOT stamp the cache's lastSyncAt —
      // "Synced just now" over a failed load is founder defect #3 —
      // and must not be persisted as a fresh blob. A partial read
      // delivered real data and counts as a sync.
      final failed = errCode != null;
      final data = _cache.apply(_dateStr, raw,
          ownerEmail: widget.email, succeeded: !failed);
      if (!failed) unawaited(_cache.persist());
      setState(() {
        _data = data;
        _lastSyncAt = _cache.lastSyncAt;
        _loading = false;
        if (failed) {
          // Bracketed code + the exception class only (never health
          // values) so a screenshot diagnoses the failure. This
          // surfaces even when cached data is on screen — including
          // when _connected came from the persisted fallback above.
          _error = errDetails != null
              ? '[$errCode] Could not read heart rate data. ($errDetails)'
              : '[$errCode] Could not read heart rate data.';
        } else if (partialCode != null) {
          // Juno J4: partial copy must not claim total failure.
          _error = errDetails != null
              ? '[$partialCode] Some heart rate data could not be read and may be missing. ($errDetails)'
              : '[$partialCode] Some heart rate data could not be read and may be missing.';
        } else {
          _error = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read heart rate data.';
      });
    }
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final firstDate = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 180));
    final lastDate = DateTime(today.year, today.month, today.day);
    final initialDate = _selectedDate.isBefore(firstDate)
        ? firstDate
        : (_selectedDate.isAfter(lastDate) ? lastDate : _selectedDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null || !mounted) return;
    final pickedDay = DateTime(picked.year, picked.month, picked.day);
    final currentDay =
        DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    if (pickedDay == currentDay) return;
    setState(() {
      _selectedDate = pickedDay;
      // Cached series for the new date renders instantly when present.
      _data = _cache.snapshot(_dateStr);
    });
    await _load();
  }

  Future<void> _onLinkTap() async {
    if (_requesting) return;
    // Juno MF-3: prominent disclosure BEFORE the system permission UI.
    final proceed = await showHealthConnectDisclosure(context);
    if (!proceed || !mounted) return;
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      final granted = await _service.requestPermissions();
      if (!mounted) return;
      final connected =
          granted.containsAll(HealthConnectService.requiredPermissions);
      setState(() {
        _requesting = false;
        _connected = connected;
        if (!connected && granted.isEmpty) {
          _error = 'No permissions were granted.';
        }
      });
      if (connected) await _load();
    } on HealthConnectException catch (e) {
      if (mounted) {
        setState(() {
          _requesting = false;
          _error = '[${e.code}] ${e.message}';
        });
      }
    }
  }

  void _showHrInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Heart Rate Insights',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Tabs tracks your 'Awake Average' to better understand your physiological load throughout the day.",
              style: TextStyle(fontSize: 14, color: NotelColors.textSecondary),
            ),
            SizedBox(height: 12),
            Text(
              'Clinical Benchmarks:\n'
              '• Resting (RHR): 60 - 80 bpm\n'
              '• Tachycardia: >100 bpm at rest\n'
              '• Bradycardia: <60 bpm at rest',
              style: TextStyle(fontSize: 14, color: NotelColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it', style: TextStyle(color: NotelColors.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _openSpikeReview() async {
    final data = _data;
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => HeartSpikeReviewScreen(
            samples: data?.samples ?? const [], dateStr: _dateStr),
      ),
    );
  }

  Future<void> _openConnections() async {
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => ConnectionsScreen(healthConnectService: _service),
      ),
    );
    if (!mounted) return;
    // Native returns to the same shared state; re-check + refresh.
    await _checkConnectionAndLoad();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connected;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        title: const Text(
          'Heart',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 22,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          if (connected == true) ...[
            // Date selector pill (native: Surface radius 20,
            // surfaceHigh fill, textSecondary @20% border).
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Material(
                  color: NotelColors.surfaceHigh,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                      color: NotelColors.textSecondary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _pickDate,
                    // R49 HE2: hit area ≥48dp tall (was ≈30dp);
                    // glyphs and pill padding unchanged.
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              heartDateLabel(_dateStr, _todayStr),
                              style: const TextStyle(
                                color: NotelColors.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.keyboard_arrow_down,
                              color: NotelColors.textSecondary,
                              size: 16,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: _loading ? null : () => unawaited(_load()),
              icon: const Icon(Icons.refresh,
                  size: 24, color: NotelColors.textSecondary),
              tooltip: 'Refresh',
            ),
          ],
        ],
      ),
      body: connected == false
          ? _notConnectedBody()
          : _connectedBody(),
    );
  }

  // Native not-connected state (FitbitScreen.kt): centered column,
  // 120dp circle (primary @10%) with a 64dp heart, title, copy, and
  // the Link Health Connect button at 90% width.
  Widget _notConnectedBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 48),
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: 0.1,
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: NotelColors.primary,
                    ),
                  ),
                ),
                const Icon(Icons.favorite,
                    size: 64, color: NotelColors.primary),
              ],
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Connect Vital Signs',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Link Health Connect to automatically sync your heart rate and sleep data.',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 14,
              height: 22 / 14,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 40),
          FractionallySizedBox(
            widthFactor: 0.9,
            child: _GlassyButton(
              color: NotelColors.primary,
              onTap: _requesting ? null : _onLinkTap,
              child: _requesting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _chipInk,
                      ),
                    )
                  : const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'Link Health Connect',
                        style: TextStyle(
                          color: _chipInk,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: NotelColors.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _connectedBody() {
    final data = _data ?? HeartDayData.empty;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) ...[
            Container(
              decoration: BoxDecoration(
                color: NotelColors.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              padding:
                  const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: NotelColors.primary,
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Updating sync data...',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          _summaryCard(data),
          const SizedBox(height: 16),
          _patternCard(data),
          const SizedBox(height: 16),
          _spikesCard(data),
          const SizedBox(height: 16),
          _healthConnectRow(),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: NotelColors.error, fontSize: 12),
            ),
          ],
          // Native: 72dp tail spacer above the floating nav bar; the
          // shell's dock floats too, so keep the same clearance.
          const SizedBox(height: 72),
        ],
      ),
    );
  }

  // ── 1. Summary card ─────────────────────────────────────────────────
  Widget _summaryCard(HeartDayData data) {
    return _GlassyCard(
      onTap: _showHrInfo,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.favorite,
                  color: NotelColors.primary, size: 48),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Awake average',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: data.awakeAvg != null
                              ? '${data.awakeAvg}'
                              : '--',
                          style: const TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 40,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const TextSpan(
                          text: ' bpm',
                          style: TextStyle(
                            color: NotelColors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 5, // native weight 1.0 vs 1.2
                child: _pill(
                  color: NotelColors.legacyDarkAsleepPill,
                  borderColor: NotelColors.legacyDarkAsleepPillBorder,
                  icon: Icons.nights_stay,
                  iconColor: NotelColors.legacyDarkAsleepInk,
                  text: data.asleepAvg != null
                      ? 'Asleep ${data.asleepAvg} bpm'
                      : 'Asleep -- bpm',
                  textColor: NotelColors.legacyDarkAsleepInk,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 6, // native weight 1.2 vs 1.0
                child: _pill(
                  color: NotelColors.legacyDarkLastPill,
                  borderColor: NotelColors.legacyDarkLastPillBorder,
                  icon: Icons.bar_chart,
                  iconColor: NotelColors.info,
                  text: data.latest != null
                      ? 'Last ${data.latest!.bpm} bpm · ${formatHrTime(data.latest!.timeMs)}'
                      : 'Last -- bpm',
                  textColor: NotelColors.info,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required Color color,
    required Color borderColor,
    required IconData icon,
    required Color iconColor,
    required String text,
    required Color textColor,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── 2. Today's pattern card ─────────────────────────────────────────
  Widget _patternCard(HeartDayData data) {
    return _GlassyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Today’s pattern',
                style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 6),
              // R49 HE3: 48dp hit area around the 16dp glyph
              // (was a bare 16dp target).
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showHrInfo,
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(Icons.info,
                        size: 16, color: NotelColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
          const Text(
            'Heart rate from 12 AM to 11:59 PM',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 210,
            child: CustomPaint(
              size: Size.infinite,
              painter: _HeartPatternPainter(
                samples: data.samples,
                date: _selectedDate,
                use24Hour: MediaQuery.of(context).alwaysUse24HourFormat,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Legend (native FlowRow, SpaceBetween).
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 16,
                    height: 3,
                    decoration: BoxDecoration(
                      color: NotelColors.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('Heart rate',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 11)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 10,
                    decoration: BoxDecoration(
                      color: NotelColors.restingSwatch,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('Resting range (45 to 70 bpm)',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 11)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: NotelColors.error,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    data.peakBpm != null
                        ? 'Peak ${data.peakBpm} bpm'
                        : 'Peak --',
                    style: const TextStyle(
                        color: NotelColors.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 3. Spikes card ──────────────────────────────────────────────────
  Widget _spikesCard(HeartDayData data) {
    final card = data.spikesCard;
    final loadLevel = card.loadLevel;
    final high = loadLevel == 'High load';
    return Container(
      decoration: BoxDecoration(
        color: high ? NotelColors.errorTint : NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: high
              ? NotelColors.primary.withValues(alpha: 0.18)
              : NotelColors.cardBorder,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: NotelColors.errorTintStrong,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.whatshot,
                    color: NotelColors.error, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${card.spikeCount} significant spikes',
                      style: const TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      loadLevel,
                      style: const TextStyle(
                        color: NotelColors.error,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: NotelColors.errorTintStrong,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text(
                  loadLevel,
                  style: const TextStyle(
                    color: NotelColors.error,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _spikeMetric('Peak',
                  card.maxBpm > 0 ? '${card.maxBpm}' : '--', 'bpm',
                  color: NotelColors.error),
              _spikeMetric(
                  'Largest jump',
                  card.maxDelta > 0 ? '+${card.maxDelta}' : '--',
                  'bpm'),
              _spikeMetric('Total', '${card.spikeCount}', 'events'),
            ],
          ),
          const SizedBox(height: 16),
          _GlassyButton(
            color: NotelColors.legacyDarkReviewButton,
            onTap: _openSpikeReview,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Review spikes',
                  style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(Icons.arrow_forward,
                    size: 18, color: NotelColors.textSecondary),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _spikeMetric(String label, String value, String unit,
      {Color color = NotelColors.textPrimary}) {
    return Column(
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          unit,
          style: const TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  // ── 4. Health Connect row ───────────────────────────────────────────
  Widget _healthConnectRow() {
    return _GlassyCard(
      onTap: _openConnections,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: NotelColors.legacyDarkConnectCircle,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Image.asset(
              'assets/images/ic_health_connect.png',
              width: 24,
              height: 24,
              errorBuilder: (_, _, _) => const Icon(Icons.favorite,
                  color: NotelColors.primary, size: 20),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Health Connect',
                  style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                Text(
                  formatSyncedAgo(_lastSyncAt, DateTime.now()),
                  style: const TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward,
              color: NotelColors.textSecondary, size: 18),
        ],
      ),
    );
  }
}

/// Native GlassyCard (LiquidGlass.kt): solid fill, radius 16, 1dp
/// primary @18% border, 16dp padding.
class _GlassyCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const _GlassyCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      padding: padding,
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: card,
      ),
    );
  }
}

/// Native GlassyButton (LiquidGlass.kt): padding h24 v12,
/// 1dp border of the container color @60%.
/// R49 HE4/HE6: radius aligned to the screen's 16dp card family
/// (was 14) and a 48dp minimum height (the Review-spikes instance
/// measured ≈44dp).
class _GlassyButton extends StatelessWidget {
  final Widget child;
  final Color color;
  final VoidCallback? onTap;

  const _GlassyButton({required this.child, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Port of native `HeartPatternGraph` (FitbitScreen.kt):
/// - plot paddings: left 36, right 16, top 24, bottom 28 (dp);
/// - y range 20–180, ticks 180/140/100/60/20, dashed grid #222F4C,
///   10sp labels;
/// - resting band 45–70 bpm: fill #1B2847 @60% (hardcoded in native —
///   NOT computed from data and NOT read from stored settings);
/// - x across the selected date 00:00 → 23:59:59, ticks at
///   0/6/12/18/24h, dashed verticals #1D2A47, labels per the device
///   12h/24h setting;
/// - the HR polyline (primary, 2.5dp, round caps/joins) drawn only
///   with ≥ 2 samples;
/// - peak marker: 5dp error circle, 2dp white center, bold 12sp error
///   value label above it.
class _HeartPatternPainter extends CustomPainter {
  final List<HrSample> samples;
  final DateTime date;
  final bool use24Hour;

  const _HeartPatternPainter({
    required this.samples,
    required this.date,
    required this.use24Hour,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 36.0;
    const rightPad = 16.0;
    const topPad = 24.0;
    const bottomPad = 28.0;
    final graphW = size.width - leftPad - rightPad;
    final graphH = size.height - topPad - bottomPad;
    const minY = 20.0;
    const maxY = 180.0;

    final dayStart = DateTime(date.year, date.month, date.day);
    final startMs = dayStart.millisecondsSinceEpoch;
    final endMs =
        dayStart.add(const Duration(hours: 23, minutes: 59, seconds: 59))
            .millisecondsSinceEpoch;

    double yToPx(double bpm) {
      final clamped = bpm.clamp(minY, maxY);
      final ratio = (clamped - minY) / (maxY - minY);
      return topPad + graphH * (1 - ratio);
    }

    double xToPx(int tMs) {
      final duration = math.max(1, endMs - startMs);
      final ratio = ((tMs - startMs) / duration).clamp(0.0, 1.0);
      return leftPad + graphW * ratio;
    }

    void drawLabel(String text, Offset topLeft,
        {double fontSize = 10,
        FontWeight weight = FontWeight.normal,
        Color color = NotelColors.textSecondary}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
              color: color, fontSize: fontSize, fontWeight: weight),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, topLeft);
    }

    Size measureLabel(String text,
        {double fontSize = 10, FontWeight weight = FontWeight.normal}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: fontSize, fontWeight: weight),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return painter.size;
    }

    void dashedHLine(double y, Color color, double dash, double gap) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1;
      var x = leftPad;
      final endX = size.width - rightPad;
      while (x < endX) {
        final segEnd = math.min(x + dash, endX);
        canvas.drawLine(Offset(x, y), Offset(segEnd, y), paint);
        x += dash + gap;
      }
    }

    void dashedVLine(double x, Color color, double dash, double gap) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1;
      var y = topPad;
      final endY = topPad + graphH;
      while (y < endY) {
        final segEnd = math.min(y + dash, endY);
        canvas.drawLine(Offset(x, y), Offset(x, segEnd), paint);
        y += dash + gap;
      }
    }

    // 1. Y grid + labels.
    for (final tick in [180, 140, 100, 60, 20]) {
      final y = yToPx(tick.toDouble());
      dashedHLine(y, NotelColors.heartChartGridY, 6, 6);
      final labelSize = measureLabel('$tick');
      drawLabel('$tick',
          Offset(leftPad - labelSize.width - 8, y - labelSize.height / 2));
    }

    // 2. Resting band 45–70.
    final bandTop = yToPx(70);
    final bandBottom = yToPx(45);
    canvas.drawRect(
      Rect.fromLTWH(leftPad, bandTop, graphW, bandBottom - bandTop),
      Paint()..color = NotelColors.restingBand.withValues(alpha: 0.6),
    );

    // 3. X grid + labels at 0/6/12/18/24h.
    for (final hr in [0, 6, 12, 18, 24]) {
      final tickMs = dayStart.add(Duration(hours: hr)).millisecondsSinceEpoch;
      final x = xToPx(tickMs);
      dashedVLine(x, NotelColors.heartChartGridX, 4, 4);
      final String label;
      if (use24Hour) {
        label = hr == 24
            ? '00:00'
            : '${hr.toString().padLeft(2, '0')}:00';
      } else {
        label = switch (hr) {
          0 || 24 => '12 AM',
          12 => '12 PM',
          > 12 => '${hr - 12} PM',
          _ => '$hr AM',
        };
      }
      final labelSize = measureLabel(label, weight: FontWeight.w500);
      final clampedX = (x - labelSize.width / 2)
          .clamp(leftPad, size.width - rightPad - labelSize.width);
      drawLabel(label, Offset(clampedX, size.height - bottomPad + 6),
          weight: FontWeight.w500);
    }

    // 4. HR polyline (≥ 2 samples, native rule). Samples are already
    // valid-filtered (bpm > 0) by HeartDayData.
    if (samples.length >= 2) {
      final path = Path();
      for (var i = 0; i < samples.length; i++) {
        final x = xToPx(samples[i].timeMs);
        final y = yToPx(samples[i].bpm.toDouble());
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = NotelColors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // 5. Peak marker + value.
    HrSample? peak;
    for (final s in samples) {
      if (peak == null || s.bpm > peak.bpm) peak = s;
    }
    if (peak != null && peak.bpm > 0) {
      final px = xToPx(peak.timeMs);
      final py = yToPx(peak.bpm.toDouble());
      canvas.drawCircle(Offset(px, py), 5, Paint()..color = NotelColors.error);
      canvas.drawCircle(Offset(px, py), 2, Paint()..color = Colors.white);
      final label = '${peak.bpm}';
      final labelSize =
          measureLabel(label, fontSize: 12, weight: FontWeight.bold);
      final clampedX = (px - labelSize.width / 2)
          .clamp(leftPad, size.width - rightPad - labelSize.width);
      drawLabel(label, Offset(clampedX, py - labelSize.height - 6),
          fontSize: 12, weight: FontWeight.bold, color: NotelColors.error);
    }
  }

  @override
  bool shouldRepaint(covariant _HeartPatternPainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.date != date ||
      oldDelegate.use24Hour != use24Hour;
}
