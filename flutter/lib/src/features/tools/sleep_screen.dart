import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 (Team B) — Sleep tool, READ-ONLY port of the native
/// `SleepScreen.kt` analysis layout.
///
/// Data sources:
/// - Health Connect `readSleepMinutes(dateStr)` for the 7-day window
///   (behind the `isConnected()` gate; "--"/empty when not connected).
/// - `profile['todaySleepMins']` and `profile['todaySleepDebt']` from the
///   sync pull for the hero card.
///
/// Founder's biometric rule: a 0 is a failed read — never charted,
/// averaged, or displayed as real sleep. Missing → "--".
///
/// Rendered (layout per native):
/// - Hero card: bed icon, "Time Asleep Today", big sleep time, Deficit
///   row, REM row ("--", stage data isn't exposed by the current reads),
///   Efficiency chip ("--", same reason). Tapping shows the Sleep Science
///   dialog (read-only, like native).
/// - "Sleep Stages" grid: Deep / Light ("--" — stage reads unavailable).
/// - "Recent Nights": the 7-day window with per-night totals or "--",
///   plus a 7-day average over non-zero nights.
///
/// DEFERRED: compare-days/weeks, date picker, manual sync — all
/// interactive extras from native.

String _formatMins(int mins) {
  final h = mins ~/ 60;
  final m = mins % 60;
  if (h > 0 && m > 0) return '${h}h ${m}m';
  if (h > 0) return '${h}h';
  return '${m}m';
}

class SleepScreen extends StatefulWidget {
  /// Injectable for tests.
  final TabsBackend? backend;

  /// Injectable for tests (a fake can override isConnected/readSleepMinutes).
  final HealthConnectService? healthConnect;

  const SleepScreen({super.key, this.backend, this.healthConnect});

  @override
  State<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends State<SleepScreen> {
  late final TabsBackend _backend;
  late final HealthConnectService _hc;

  bool _loading = true;
  bool _connected = false;
  int? _todayMins;
  int? _debtMins;
  List<({String dateStr, String dayLabel, int? mins})> _nights = const [];

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _hc = widget.healthConnect ?? HealthConnectService();
    _load();
  }

  Future<void> _load() async {
    try {
      final connected = await _hc.isConnected();
      int? todayMins;
      int? debtMins;
      final nights = <({String dateStr, String dayLabel, int? mins})>[];

      if (connected) {
        final window = sevenDayWindow();
        final reads = await Future.wait(
          window.map((d) => _hc.readSleepMinutes(d.dateStr)),
        );
        for (var i = 0; i < window.length; i++) {
          final raw = reads[i];
          // Founder rule: 0 = failed read → missing, never displayed.
          nights.add((
            dateStr: window[i].dateStr,
            dayLabel: window[i].dayLabel,
            mins: (raw != null && raw > 0) ? raw : null,
          ));
        }

        final profile = await _backend.fetchProfile();
        todayMins = _asPositiveInt(profile?['todaySleepMins']);
        debtMins = _asInt(profile?['todaySleepDebt']);
        todayMins ??= nights.isNotEmpty ? nights.last.mins : null;
      }

      if (!mounted) return;
      setState(() {
        _connected = connected;
        _todayMins = todayMins;
        _debtMins = debtMins;
        _nights = nights;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Honest empty on any failure.
      setState(() {
        _connected = false;
        _loading = false;
      });
    }
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static int? _asPositiveInt(dynamic v) {
    final i = _asInt(v);
    return (i != null && i > 0) ? i : null;
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
          'Sleep Profile',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: NotelColors.primary),
                  SizedBox(height: 16),
                  Text(
                    'Loading Sleep Data...',
                    style: TextStyle(
                      fontSize: 14,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            )
          : !_connected
              ? _notConnectedState()
              : _analysisView(),
    );
  }

  Widget _notConnectedState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                  const Icon(
                    Icons.hotel,
                    size: 64,
                    color: NotelColors.primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Sleep Analysis',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Connect your health data to track sleep cycles and calculate your sleep debt automatically.',
              style: TextStyle(
                fontSize: 14,
                height: 1.57,
                color: NotelColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              "Today's sleep: --",
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _analysisView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heroCard(),
          const SizedBox(height: 24),
          const Text(
            'Sleep Stages',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _stageCard('Deep', null)),
              const SizedBox(width: 12),
              Expanded(child: _stageCard('Light', null)),
            ],
          ),
          const SizedBox(height: 24),
          _recentNights(),
        ],
      ),
    );
  }

  Widget _heroCard() {
    final mins = _todayMins;
    final debt = _debtMins;

    return GestureDetector(
      onTap: _showSleepInfo,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: NotelColors.cardBorder),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.hotel,
              size: 64,
              color: NotelColors.primary,
            ),
            const SizedBox(height: 16),
            const Text(
              'Time Asleep Today',
              style: TextStyle(
                fontSize: 14,
                color: NotelColors.textSecondary,
              ),
            ),
            Text(
              mins != null ? _formatMins(mins) : '--',
              style: const TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.w900,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.history,
                  size: 16,
                  color: NotelColors.error,
                ),
                const SizedBox(width: 8),
                Text(
                  debt != null
                      ? 'Deficit: -${debt.abs() ~/ 60}h ${debt.abs() % 60}m'
                      : 'Deficit: --',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.error,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.auto_graph,
                  size: 16,
                  color: NotelColors.info,
                ),
                SizedBox(width: 8),
                Text(
                  'REM: --',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: NotelColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: NotelColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: const Text(
                'Efficiency: --',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: NotelColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stageCard(String label, int? mins) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: NotelColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            mins != null ? _formatMins(mins) : '--',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentNights() {
    final valid = _nights.where((n) => n.mins != null).toList();
    final avgText = valid.isNotEmpty
        ? '7-Day Average: ${_formatMins((valid.map((n) => n.mins!).reduce((a, b) => a + b) / valid.length).round())}'
        : 'Not enough sleep data yet';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent Nights',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          avgText,
          style: const TextStyle(
            fontSize: 13,
            color: NotelColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: NotelColors.cardBorder),
          ),
          child: Column(
            children: [
              for (var i = 0; i < _nights.length; i++) ...[
                _nightRow(_nights[i]),
                if (i < _nights.length - 1)
                  Divider(
                    height: 1,
                    color: NotelColors.textSecondary.withValues(alpha: 0.2),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _nightRow(({String dateStr, String dayLabel, int? mins}) night) {
    final parts = night.dateStr.split('-');
    final dateLabel = parts.length == 3
        ? '${_monthName(int.tryParse(parts[1]) ?? 0)} ${int.tryParse(parts[2]) ?? 0}'
        : night.dateStr;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(
            Icons.bedtime,
            size: 20,
            color: NotelColors.primary,
          ),
          const SizedBox(width: 12),
          Text(
            night.dayLabel,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            dateLabel,
            style: const TextStyle(
              fontSize: 13,
              color: NotelColors.textSecondary,
            ),
          ),
          const Spacer(),
          Text(
            night.mins != null ? _formatMins(night.mins!) : '--',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: night.mins != null
                  ? NotelColors.textPrimary
                  : NotelColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String _monthName(int m) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return (m >= 1 && m <= 12) ? months[m] : '';
  }

  void _showSleepInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: const Text(
          'Sleep Science',
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
              'Tabs uses a 10-day rolling window to calculate your sleep debt. Surplus sleep (over 8h) is capped at 1.5h of recovery credit per night.',
              style: TextStyle(
                fontSize: 14,
                color: NotelColors.textSecondary,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'REM sleep is crucial for cognitive function and emotional regulation. Most adults need 1.5h to 2h of REM per night.',
              style: TextStyle(
                fontSize: 14,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Got it',
              style: TextStyle(color: NotelColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}
