import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// On-device workout parsing for the Body screen (founder direction
/// Nov 20, 2026): one-line workout text resolves to body zones using
/// ONLY the shipped table asset (`assets/body/workout_table.json`) —
/// no network, no AI. Unmatched text parses to zero zones and the
/// caller logs it as a plain note; zones are never guessed.
///
/// The table is data, not code, so coverage grows by editing the
/// JSON: named exercises (primary zones light strong, secondary
/// light mild), region words (the one-tap chips), gym shorthand
/// (push / pull / upper / lower), and single-muscle words.

/// One phrase → zones rule from the table asset.
class WorkoutRule {
  final String label;
  final List<String> phrases;
  final Set<String> primary;
  final Set<String> secondary;

  const WorkoutRule({
    required this.label,
    required this.phrases,
    required this.primary,
    required this.secondary,
  });

  factory WorkoutRule.fromJson(Map<String, dynamic> json) {
    Set<String> zones(String key) => {
      for (final z in (json[key] as List? ?? const [])) '$z',
    };
    return WorkoutRule(
      label: '${json['label'] ?? json['name'] ?? ''}',
      phrases: [
        for (final p in (json['phrases'] as List? ?? const []))
          '$p'.toLowerCase(),
      ],
      primary: zones('primary'),
      secondary: zones('secondary'),
    );
  }
}

/// The result of parsing one workout line.
class ParsedWorkout {
  final Set<String> primaryZones;
  final Set<String> secondaryZones;

  /// Effort scale 0.5–1.5 (1.0 = a default session). Drives figure
  /// brightness and the fade window (48h × intensity, clamped).
  final double intensity;
  final int? sets;
  final int? minutes;

  /// Display label of the best-matching rule ("Legs", "Bench
  /// Press"), null when nothing matched.
  final String? label;

  const ParsedWorkout({
    required this.primaryZones,
    required this.secondaryZones,
    required this.intensity,
    this.sets,
    this.minutes,
    this.label,
  });

  bool get matched => primaryZones.isNotEmpty || secondaryZones.isNotEmpty;

  /// "3 sets" / "45 min" for zone rows; null when neither was given.
  String? get detailLabel {
    if (sets != null) return sets == 1 ? '1 set' : '$sets sets';
    if (minutes != null) return '$minutes min';
    return null;
  }
}

class _PhraseMatch {
  final WorkoutRule rule;
  final int groupRank; // regions 0, shorthand 1, exercises 2, zone words 3
  final int start;
  final int end;
  const _PhraseMatch(this.rule, this.groupRank, this.start, this.end);
  int get length => end - start;
}

/// The parsed workout table. Load once via [WorkoutTable.load];
/// construct directly from JSON in tests.
class WorkoutTable {
  final List<WorkoutRule> regions;
  final List<WorkoutRule> shorthand;
  final List<WorkoutRule> exercises;
  final List<WorkoutRule> zoneWords;

  const WorkoutTable({
    required this.regions,
    required this.shorthand,
    required this.exercises,
    required this.zoneWords,
  });

  factory WorkoutTable.fromJson(Map<String, dynamic> json) {
    List<WorkoutRule> rules(String key) => [
      for (final r in (json[key] as List? ?? const []))
        if (r is Map<String, dynamic>) WorkoutRule.fromJson(r),
    ];
    return WorkoutTable(
      regions: rules('regions'),
      shorthand: rules('shorthand'),
      exercises: rules('exercises'),
      zoneWords: rules('zoneWords'),
    );
  }

  static WorkoutTable? _cached;

  /// Loads the shipped asset. Throws on a missing/corrupt asset —
  /// callers catch and degrade to chip-only logging (entries still
  /// save; they just don't light zones until the table loads).
  static Future<WorkoutTable> load() async {
    final cached = _cached;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/body/workout_table.json');
    return _cached = WorkoutTable.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  static final _setsRe = RegExp(r'(\d+)\s*sets?\b');
  static final _setsXRe = RegExp(r'(\d+)\s*x\s*\d+');
  static final _minutesRe = RegExp(r'(\d+)\s*(?:minutes|minute|mins|min)\b');
  static final _hoursRe = RegExp(
    r'(\d+(?:\.\d+)?)\s*(?:hours|hour|hrs|hr|h)\b',
  );
  static final _lightRe = RegExp(r'\b(?:light|easy|gentle)\b');
  static final _hardRe = RegExp(r'\b(?:hard|heavy|intense|brutal)\b');

  /// Parses one workout line. Pure and synchronous.
  ParsedWorkout parse(String rawText) {
    final text = rawText
        .toLowerCase()
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Intensity extraction: sets first ("3 sets", "3x10"), then
    // duration ("45 min", "1.5 h"), then effort words.
    int? sets;
    final setsMatch = _setsRe.firstMatch(text);
    if (setsMatch != null) {
      sets = int.tryParse(setsMatch.group(1)!);
    } else {
      final xMatch = _setsXRe.firstMatch(text);
      if (xMatch != null) sets = int.tryParse(xMatch.group(1)!);
    }
    int? minutes;
    final minMatch = _minutesRe.firstMatch(text);
    if (minMatch != null) {
      minutes = int.tryParse(minMatch.group(1)!);
    } else {
      final hrMatch = _hoursRe.firstMatch(text);
      if (hrMatch != null) {
        minutes = ((double.tryParse(hrMatch.group(1)!) ?? 0) * 60).round();
      }
    }

    double intensity;
    if (sets != null) {
      intensity = sets <= 1
          ? 0.7
          : sets == 2
          ? 0.85
          : sets == 3
          ? 1.0
          : sets == 4
          ? 1.15
          : 1.3;
    } else if (minutes != null) {
      intensity = (0.7 + minutes / 120).clamp(0.7, 1.3).toDouble();
    } else {
      intensity = 1.0;
    }
    if (_lightRe.hasMatch(text)) intensity *= 0.65;
    if (_hardRe.hasMatch(text)) intensity *= 1.35;
    intensity = intensity.clamp(0.5, 1.5).toDouble();

    // Phrase matching with span containment: a longer phrase that
    // contains a shorter one wins its span ("leg raises" is an ab
    // exercise, not a leg workout; "push ups" beats "push").
    final groups = <(int, List<WorkoutRule>)>[
      (0, regions),
      (1, shorthand),
      (2, exercises),
      (3, zoneWords),
    ];
    final found = <_PhraseMatch>[];
    for (final (rank, rules) in groups) {
      for (final rule in rules) {
        for (final phrase in rule.phrases) {
          if (phrase.isEmpty) continue;
          final re = RegExp('\\b${RegExp.escape(phrase)}\\b');
          for (final m in re.allMatches(text)) {
            found.add(_PhraseMatch(rule, rank, m.start, m.end));
          }
        }
      }
    }
    found.sort((a, b) => b.length.compareTo(a.length));
    final accepted = <_PhraseMatch>[];
    for (final m in found) {
      final contained = accepted.any(
        (a) =>
            m.start >= a.start &&
            m.end <= a.end &&
            (m.start > a.start || m.end < a.end),
      );
      if (!contained) accepted.add(m);
    }

    final primary = <String>{};
    final secondary = <String>{};
    for (final m in accepted) {
      primary.addAll(m.rule.primary);
      secondary.addAll(m.rule.secondary);
    }
    secondary.removeAll(primary);

    String? label;
    if (accepted.isNotEmpty) {
      final byLabelPriority = [...accepted]
        ..sort((a, b) {
          final r = a.groupRank.compareTo(b.groupRank);
          if (r != 0) return r;
          final l = b.length.compareTo(a.length);
          if (l != 0) return l;
          return a.start.compareTo(b.start);
        });
      label = byLabelPriority.first.rule.label;
    }

    return ParsedWorkout(
      primaryZones: primary,
      secondaryZones: secondary,
      intensity: intensity,
      sets: sets,
      minutes: minutes,
      label: label,
    );
  }
}
