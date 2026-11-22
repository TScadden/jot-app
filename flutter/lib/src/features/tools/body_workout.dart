import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/workout_table.dart';

/// Workout layer for the Body Info & Impact Map (founder direction
/// Nov 20, 2026). A workout is a normal log entry carrying the
/// `Workout` chip; everything visual is RE-DERIVED on-device from
/// the entry text via the shipped [WorkoutTable] — no server state,
/// no AI. Only `Workout`-chip entries are parsed, so symptom logs
/// ("leg pain") never light workout zones.

/// Chip marking a log entry as a Body-screen workout.
const String kWorkoutChip = 'Workout';

bool isWorkoutEntry(QuickLogEntry entry) => entry.chips
    .split(',')
    .map((c) => c.trim().toLowerCase())
    .contains(kWorkoutChip.toLowerCase());

/// Display names for the canonical zone ids.
const Map<String, String> bodyZoneLabels = {
  'head': 'Head',
  'chest': 'Chest',
  'shoulder_l': 'Left Shoulder',
  'shoulder_r': 'Right Shoulder',
  'bicep_l': 'Left Bicep',
  'bicep_r': 'Right Bicep',
  'tricep_l': 'Left Tricep',
  'tricep_r': 'Right Tricep',
  'forearm_l': 'Left Forearm',
  'forearm_r': 'Right Forearm',
  'core': 'Core',
  'traps': 'Traps',
  'back': 'Back',
  'glutes': 'Glutes',
  'quad_l': 'Left Quad',
  'quad_r': 'Right Quad',
  'hamstring_l': 'Left Hamstring',
  'hamstring_r': 'Right Hamstring',
  'calf_l': 'Left Calf',
  'calf_r': 'Right Calf',
  'shin_l': 'Left Shin',
  'shin_r': 'Right Shin',
};

/// Every canonical zone id (figure render order is by asset, this
/// is for SYSTEMIC expansion and tests).
const List<String> allBodyZones = [
  'head',
  'chest',
  'shoulder_l',
  'shoulder_r',
  'bicep_l',
  'bicep_r',
  'tricep_l',
  'tricep_r',
  'forearm_l',
  'forearm_r',
  'core',
  'traps',
  'back',
  'glutes',
  'quad_l',
  'quad_r',
  'hamstring_l',
  'hamstring_r',
  'calf_l',
  'calf_r',
  'shin_l',
  'shin_r',
];

/// Zones with a mask on the FRONT figure. The rest are back-only:
/// a hamstring workout shows its quads in front and its hamstrings
/// when the figure flips — anatomically where they live.
const Set<String> frontBodyZones = {
  'head',
  'chest',
  'shoulder_l',
  'shoulder_r',
  'bicep_l',
  'bicep_r',
  'forearm_l',
  'forearm_r',
  'core',
  'quad_l',
  'quad_r',
  'shin_l',
  'shin_r',
};

/// Zones with a mask on the BACK figure.
const Set<String> backBodyZones = {
  'head',
  'traps',
  'back',
  'shoulder_l',
  'shoulder_r',
  'tricep_l',
  'tricep_r',
  'forearm_l',
  'forearm_r',
  'glutes',
  'hamstring_l',
  'hamstring_r',
  'calf_l',
  'calf_r',
};

/// Impact-engine region ids → figure zones. LEFT_ARM impacts are
/// lab draws (engine rule 2), which sit in the forearm/vein zone.
const Map<String, List<String>> impactZonesForRegion = {
  'HEAD': ['head'],
  'EYES': ['head'],
  'LEFT_ARM': ['forearm_l'],
  'RIGHT_ARM': ['forearm_r'],
  'ABDOMEN': ['core'],
  'BACK': ['back'],
  'CHEST': ['chest'],
  'THIGHS': ['quad_l', 'quad_r', 'hamstring_l', 'hamstring_r'],
  'PEPTIDE': ['core'],
  'LEFT_SIDE': ['core'],
  'RIGHT_SIDE': ['core'],
};

/// One zone's workout light: figure [alpha] (0–0.85), whether any
/// contributing entry hit it as a primary zone, and the newest
/// contributing entry's timestamp.
class BodyWorkoutZone {
  final String zoneId;
  final double alpha;
  final bool primary;
  final int latestTimestampMs;

  const BodyWorkoutZone({
    required this.zoneId,
    required this.alpha,
    required this.primary,
    required this.latestTimestampMs,
  });
}

/// A workout entry still inside its fade window, for the zone rows.
class BodyWorkoutEntry {
  final QuickLogEntry entry;
  final ParsedWorkout parsed;

  const BodyWorkoutEntry({required this.entry, required this.parsed});

  /// Fade window for this entry: 48h × intensity, clamped 24–96h.
  double get windowHours => (48 * parsed.intensity).clamp(24.0, 96.0);
}

/// Derived workout state for the figure + rows.
class BodyWorkoutState {
  final Map<String, BodyWorkoutZone> zones;
  final List<BodyWorkoutEntry> recentEntries;

  const BodyWorkoutState({required this.zones, required this.recentEntries});

  static const empty = BodyWorkoutState(zones: {}, recentEntries: []);
}

/// Derives workout zones from log [entries] at [nowMs]. Entries
/// whose text matches nothing contribute nothing (they stay plain
/// notes). Newest entries first in [BodyWorkoutState.recentEntries].
BodyWorkoutState evaluateBodyWorkouts(
  List<QuickLogEntry> entries,
  WorkoutTable table,
  int nowMs,
) {
  final zones = <String, BodyWorkoutZone>{};
  final recent = <BodyWorkoutEntry>[];
  final workouts = entries.where(isWorkoutEntry).toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  for (final entry in workouts) {
    final parsed = table.parse(entry.body);
    if (!parsed.matched) continue;
    final windowH = (48 * parsed.intensity).clamp(24.0, 96.0);
    final ageH = (nowMs - entry.timestamp) / (60 * 60 * 1000.0);
    if (ageH >= windowH) continue;
    final remaining = 1 - (ageH < 0 ? 0 : ageH) / windowH;
    recent.add(BodyWorkoutEntry(entry: entry, parsed: parsed));
    final brightness = (parsed.intensity / 1.3).clamp(0.35, 1.0).toDouble();
    void apply(Set<String> zoneIds, double base, bool primary) {
      for (final zoneId in zoneIds) {
        final alpha = base * brightness * remaining;
        final current = zones[zoneId];
        if (current == null || alpha > current.alpha) {
          zones[zoneId] = BodyWorkoutZone(
            zoneId: zoneId,
            alpha: alpha,
            primary: primary || (current?.primary ?? false),
            latestTimestampMs: entry.timestamp,
          );
        } else if (primary && !current.primary) {
          zones[zoneId] = BodyWorkoutZone(
            zoneId: zoneId,
            alpha: current.alpha,
            primary: true,
            latestTimestampMs: current.latestTimestampMs,
          );
        }
      }
    }

    apply(parsed.primaryZones, 0.85, true);
    apply(parsed.secondaryZones, 0.45, false);
  }
  return BodyWorkoutState(zones: zones, recentEntries: recent);
}
