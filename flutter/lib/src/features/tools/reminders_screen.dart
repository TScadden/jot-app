import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 — Reminders tool screen, DISPLAY-ONLY. Faithful port of native
/// `ui/screen/RemindersScreen.kt` minus the write path:
///
/// - Data: `TabsBackend.decodeProfileList(profile['reminders'])` — the
///   reminders JSON blob synced from the native app. Per-row shape mirrors
///   native `data/local/entity/Reminder.kt`:
///   `{title, type: FIXED|INTERVAL, fixedHour, fixedMinute, intervalHours,
///   intervalMinutes, startHour, startMinute, endHour, endMinute,
///   isEnabled, daysOfWeekConfig}`.
/// - Renders each reminder with its title, the native schedule summary
///   (fixed time, per-day times, or "Every Nh • start to end"), and a
///   read-only enabled pill (the native Switch toggles a write).
/// - DEFERRED (later round): creating reminders, toggling enabled,
///   deleting, and the Android notification/alarms permission flow. The
///   native ✕ delete button and add FAB are omitted; rows are read-only.
///
/// `ReminderModel` / [reminderScheduleSummary] / [formatTime12h] are pure
/// and unit-tested.

/// One entry of the `reminders` profile blob. Defaults mirror native
/// `Reminder.kt` (fixedHour 12, interval 2h, window 8:00–21:00, enabled).
class ReminderModel {
  final String title;
  final String type; // "FIXED" | "INTERVAL"
  final int fixedHour;
  final int fixedMinute;
  final int intervalHours;
  final int intervalMinutes;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final bool isEnabled;
  final List<DayTimeConfig> dayConfigs;

  const ReminderModel({
    required this.title,
    required this.type,
    required this.fixedHour,
    required this.fixedMinute,
    required this.intervalHours,
    required this.intervalMinutes,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.isEnabled,
    required this.dayConfigs,
  });

  factory ReminderModel.fromJson(Map<String, dynamic> json) {
    final dayConfigs = <DayTimeConfig>[];
    final rawDays = json['daysOfWeekConfig'];
    if (rawDays is String && rawDays.trim().isNotEmpty) {
      try {
        // Tolerates a JSON list (what native writes) or a single object.
        final decoded = TabsBackend.decodeProfileList(rawDays);
        for (final d in decoded) {
          dayConfigs.add(DayTimeConfig.fromJson(d));
        }
      } catch (_) {
        // Malformed day config → fall back to the fixed time.
      }
    } else if (rawDays is List) {
      for (final d in rawDays) {
        if (d is Map<String, dynamic>) {
          dayConfigs.add(DayTimeConfig.fromJson(d));
        }
      }
    }
    final type = '${json['type'] ?? 'FIXED'}'.toUpperCase();
    return ReminderModel(
      title: '${json['title'] ?? ''}',
      type: type == 'INTERVAL' ? 'INTERVAL' : 'FIXED',
      fixedHour: _asInt(json['fixedHour'], 12),
      fixedMinute: _asInt(json['fixedMinute'], 0),
      intervalHours: _asInt(json['intervalHours'], 2),
      intervalMinutes: _asInt(json['intervalMinutes'], 0),
      startHour: _asInt(json['startHour'], 8),
      startMinute: _asInt(json['startMinute'], 0),
      endHour: _asInt(json['endHour'], 21),
      endMinute: _asInt(json['endMinute'], 0),
      isEnabled: json['isEnabled'] != false,
      dayConfigs: dayConfigs,
    );
  }
}

/// Parses reminder rows fail-soft: a row that throws is skipped instead
/// of killing the whole list. Never throws.
List<ReminderModel> parseReminderModels(
    List<Map<String, dynamic>> rows) {
  final out = <ReminderModel>[];
  for (final row in rows) {
    try {
      out.add(ReminderModel.fromJson(row));
    } catch (_) {
      // Skip the bad row; keep the rest.
    }
  }
  return out;
}

/// One row of native `DayTimeConfig` (Mon 9:00 AM, …).
class DayTimeConfig {
  final String dayName;
  final bool isEnabled;
  final int hour;
  final int minute;

  const DayTimeConfig({
    required this.dayName,
    required this.isEnabled,
    required this.hour,
    required this.minute,
  });

  factory DayTimeConfig.fromJson(Map<String, dynamic> json) {
    return DayTimeConfig(
      dayName: '${json['dayName'] ?? ''}',
      isEnabled: json['isEnabled'] == true,
      hour: _asInt(json['hour'], 8),
      minute: _asInt(json['minute'], 0),
    );
  }
}

int _asInt(dynamic v, int fallback) {  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

/// 12-hour clock label, matching native `formatTime` ("9:00 AM").
String formatTime12h(int hour, int minute) {
  final amPm = hour < 12 ? 'AM' : 'PM';
  final h12 = hour % 12 == 0 ? 12 : hour % 12;
  return '$h12:${minute.toString().padLeft(2, '0')} $amPm';
}

/// The schedule summary line, mirroring native `ReminderCard`'s
/// `timeLabel` logic verbatim.
String reminderScheduleSummary(ReminderModel r) {
  if (r.type == 'FIXED') {
    final enabled =
        r.dayConfigs.where((d) => d.isEnabled).toList();
    if (enabled.isNotEmpty) {
      return enabled
          .map((d) => '${d.dayName} ${formatTime12h(d.hour, d.minute)}')
          .join(', ');
    }
    return formatTime12h(r.fixedHour, r.fixedMinute);
  }
  final intervalStr = r.intervalHours > 0
      ? 'Every ${r.intervalHours}h'
      : 'Every ${r.intervalMinutes}m';
  return '$intervalStr  •  ${formatTime12h(r.startHour, r.startMinute)} to ${formatTime12h(r.endHour, r.endMinute)}';
}

/// Round 18 — display-only Reminders screen.
///
/// [backend] is injectable so widget tests can drive the screen with a
/// mock client; production defaults to a real [TabsBackend].
class RemindersScreen extends StatefulWidget {
  final TabsBackend? backend;

  const RemindersScreen({super.key, this.backend});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  late final TabsBackend _backend;
  bool _loading = true;
  bool _failed = false;
  bool _loadFailed = false; // profile itself was null (auth/network)
  List<ReminderModel> _reminders = const [];

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
      _loadFailed = false;
    });
    try {
      final profile = await _backend.fetchProfile();
      if (!mounted) return;
      if (profile == null) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        return;
      }
      final rows =
          TabsBackend.decodeProfileList(profile['reminders']);
      setState(() {
        // Round 18b: fail soft per item — one bad reminder row must not
        // kill the whole screen.
        _reminders = parseReminderModels(rows);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
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
          'Reminders',
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
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: NotelColors.primary),
      );
    }
    if (_failed || _loadFailed) {
      return _failureState();
    }
    if (_reminders.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('🔔', style: TextStyle(fontSize: 48)),
            SizedBox(height: 16),
            Text(
              'No reminders yet',
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Your scheduled reminders will appear here.',
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding:
          const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: _reminders.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) =>
          _reminderCard(_reminders[i]),
    );
  }

  Widget _failureState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔔', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            const Text(
              'Couldn\'t load reminders',
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Check your connection and try again.',
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _load,
              style: FilledButton.styleFrom(
                  backgroundColor: NotelColors.primary),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reminderCard(ReminderModel r) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: r.isEnabled
            ? NotelColors.surfaceHigh.withValues(alpha: 0.12)
            : NotelColors.surfaceHigh.withValues(alpha: 0.05),
        border: Border.all(
          color: r.isEnabled
              ? NotelColors.primary.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
        ),
      ),
      child: Row(
        children: [
          Icon(
            r.type == 'FIXED' ? Icons.alarm : Icons.repeat,
            color: r.isEnabled
                ? NotelColors.primary
                : NotelColors.textSecondary,
            size: 24,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // No fallback: an empty title renders as-is. Nothing
                  // is invented to fill a missing value.
                  r.title,
                  style: TextStyle(
                    color: r.isEnabled
                        ? NotelColors.textPrimary
                        : NotelColors.textSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  reminderScheduleSummary(r),
                  style: TextStyle(
                    color: NotelColors.textSecondary
                        .withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Read-only enabled pill (native Switch is a write — deferred).
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: r.isEnabled
                  ? NotelColors.primary.withValues(alpha: 0.15)
                  : NotelColors.surfaceHigh
                      .withValues(alpha: 0.2),
            ),
            child: Text(
              r.isEnabled ? 'ON' : 'OFF',
              style: TextStyle(
                color: r.isEnabled
                    ? NotelColors.primary
                    : NotelColors.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
