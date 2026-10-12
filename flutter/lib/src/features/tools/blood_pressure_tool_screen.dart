import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Where a blood pressure reading came from.
enum BpSource { manual, healthConnect }

/// One merged reading tagged with its source.
class BpUiRecord {
  final BpRecord record;
  final BpSource source;

  const BpUiRecord({required this.record, required this.source});
}

/// Merge manual + Health Connect readings for the Blood Pressure tool.
///
/// Ports round 13's snapshot merge spirit, minus the 7-day bucketing:
/// - A 0 or negative systolic/diastolic is a failed read (founder rule) and
///   is dropped, never charted or listed.
/// - Duplicates by [BpRecord.timeEpochMs] are collapsed; the Health Connect
///   copy wins because device data is the source of truth.
/// - Newest first.
/// - Never throws; empty in → empty out.
List<BpUiRecord> mergeBpRecords({
  required List<BpRecord> manual,
  required List<BpRecord> healthConnect,
}) {
  final byTime = <int, BpUiRecord>{};
  for (final r in healthConnect) {
    if (r.systolic <= 0 || r.diastolic <= 0 || r.timeEpochMs <= 0) continue;
    byTime[r.timeEpochMs] = BpUiRecord(record: r, source: BpSource.healthConnect);
  }
  for (final r in manual) {
    if (r.systolic <= 0 || r.diastolic <= 0 || r.timeEpochMs <= 0) continue;
    byTime.putIfAbsent(
        r.timeEpochMs, () => BpUiRecord(record: r, source: BpSource.manual));
  }
  final out = byTime.values.toList()
    ..sort((a, b) => b.record.timeEpochMs.compareTo(a.record.timeEpochMs));
  return out;
}

/// "Oct 11, 2026 · 6:16 PM" — small local formatter (no intl dep allowed).
String formatBpDateTime(int timeEpochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(timeEpochMs);
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final minute = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${months[d.month - 1]} ${d.day}, ${d.year} · $hour12:$minute $ampm';
}

/// Round 18, Team D — Blood Pressure tool screen (read-only).
///
/// Ports the native `BloodPressureScreen.kt` display path: the latest reading
/// is spotlighted and the merged history list follows. Data comes from
/// [TabsBackend.fetchManualBpLogs] plus Health Connect's last 30 days when
/// connected; the write flows (manual add, CSV import, delete) need POST
/// endpoints that do not exist in the shared data layer yet, so this screen
/// is display-only for this round.
class BloodPressureToolScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final TabsBackend? backend;
  final HealthConnectService? healthConnect;

  const BloodPressureToolScreen({
    super.key,
    this.onBack,
    this.backend,
    this.healthConnect,
  });

  @override
  State<BloodPressureToolScreen> createState() =>
      _BloodPressureToolScreenState();
}

class _BloodPressureToolScreenState extends State<BloodPressureToolScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  HealthConnectService get _hc =>
      widget.healthConnect ?? HealthConnectService();

  bool _loading = true;
  bool _refreshing = false;
  List<BpUiRecord> _records = const [];
  String? _hcNotice;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool isRefresh = false}) async {
    if (mounted) {
      setState(() {
        if (isRefresh) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _error = null;
      });
    }
    try {
      final manual = await _backend.fetchManualBpLogs();
      List<BpRecord> hcRecords = const [];
      String? notice;
      bool connected = false;
      try {
        connected = await _hc.isConnected();
        if (connected) {
          hcRecords = await _hc.readBloodPressure(30);
        } else {
          notice = 'Health Connect is not connected. Showing manual readings only.';
        }
      } catch (e) {
        // Channel failures surface as a visible notice; manual data still shows.
        notice = 'Health Connect query issue. Showing manual readings.';
      }
      if (!mounted) return;
      setState(() {
        _records = mergeBpRecords(manual: manual, healthConnect: hcRecords);
        _hcNotice = notice;
        _loading = false;
        _refreshing = false;
      });
    } catch (e) {
      // A backend read throwing outright is rare (it normally returns null),
      // but an honest error is better than a stuck spinner.
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your data. We could not pull your latest '
            'readings. Check your connection and try again.';
        _loading = false;
        _refreshing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final latest = _records.isEmpty ? null : _records.first;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textSecondary, semanticLabel: 'Back'),
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Blood Pressure',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh,
                color: NotelColors.textSecondary, semanticLabel: 'Refresh'),
            onPressed: _refreshing ? null : () => _load(isRefresh: true),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: NotelColors.primary))
          : RefreshIndicator(
              color: NotelColors.primary,
              onRefresh: () => _load(isRefresh: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (_hcNotice != null) _noticeBanner(_hcNotice!),
                  _latestCard(latest),
                  const SizedBox(height: 24),
                  const Text(
                    'History',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary),
                  ),
                  const SizedBox(height: 12),
                  if (_error != null)
                    _errorBanner(_error!)
                  else if (_records.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        'No blood pressure records found.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 14, color: NotelColors.textSecondary),
                      ),
                    )
                  else
                    ..._records.map(_historyRow),
                ],
              ),
            ),
    );
  }

  Widget _noticeBanner(String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber,
              size: 18, color: NotelColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12, color: NotelColors.textSecondary)),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NotelColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.error.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style:
              const TextStyle(fontSize: 13, color: NotelColors.textPrimary)),
    );
  }

  Widget _latestCard(BpUiRecord? latest) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite, size: 20, color: NotelColors.primary),
              SizedBox(width: 8),
              Text('Latest Reading',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: NotelColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 12),
          if (latest == null) ...[
            const Text('-- / --',
                style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textSecondary)),
            const SizedBox(height: 4),
            const Text('No readings logged yet',
                style: TextStyle(
                    fontSize: 13, color: NotelColors.textSecondary)),
          ] else ...[
            Text(
                '${latest.record.systolic} / ${latest.record.diastolic}',
                style: const TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                    color: NotelColors.textPrimary)),
            const Text('mmHg',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: NotelColors.textSecondary)),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatBpDateTime(latest.record.timeEpochMs),
                    style: TextStyle(
                        fontSize: 12,
                        color:
                            NotelColors.textSecondary.withValues(alpha: 0.8))),
                const SizedBox(width: 6),
                _sourceChip(latest.source),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _historyRow(BpUiRecord item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${item.record.systolic} / ${item.record.diastolic} mmHg',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                formatBpDateTime(item.record.timeEpochMs),
                style: const TextStyle(
                    fontSize: 12, color: NotelColors.textSecondary),
              ),
            ],
          ),
          _sourceChip(item.source),
        ],
      ),
    );
  }

  Widget _sourceChip(BpSource source) {
    final isHc = source == BpSource.healthConnect;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isHc
            ? const Color(0xFF1E3A8A)
            : const Color(0xFF064E3B), // native chip fills, verbatim
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        isHc ? 'Health Connect' : 'Manual',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isHc
              ? const Color(0xFF93C5FD)
              : const Color(0xFF6EE7B7), // native chip text, verbatim
        ),
      ),
    );
  }
}
