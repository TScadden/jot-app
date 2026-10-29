import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'coach_memory_store.dart';
import 'health_data.dart' show HrSample;
import 'lean_test_strings.dart';
import 'migraine_time_format.dart' show formatAttackTimestamp;
import 'quick_log_models.dart';
import 'today_summary.dart' show resolveSummaryCategoryId;

/// Phase 1, item 6 — Guided Lean Test: session model, local
/// owner-bound session store, payload build/parse, and every
/// derivation (phase, baseline, outcome, result rendering, past
/// tests). Derivations read the payload only, never the entry body
/// (spec §4). All phase/elapsed values derive from persisted
/// timestamps — never accumulated ticks (migraine precedent).
///
/// A biometric 0 is a failed read, never data: capture fields store
/// null for empty/0 input, the payload omits null values, and the
/// U2 label renders in their place.

// ── Constants ──────────────────────────────────────────────────────

/// The existing category the result files under (spec §4).
const String leanCategoryName = 'Symptoms';

/// Fallback id used ONLY when a pulled category actually carries
/// id 1 (item-1 §4.2 / flare pattern — NOT an unconditional `?? 1`).
const int leanCategoryFallbackId = 1;

/// Rest phase length.
const int leanRestMinutes = 10;

/// Standing phase: captures at minutes 0..10.
const int leanStandingMinutes = 10;

/// Standing capture slots: the minute-10 capture is due at elapsed
/// minute 10 and stays open for that whole minute; the phase is
/// expired once elapsed reaches minute 11 with the minute-10
/// capture unsubmitted.
const int leanStandingExpiryMinute = 11;

/// Resting baseline captures fall at rest minutes 9 and 10.
const List<int> leanBaselineMinutes = [9, 10];

/// Resolves the Symptoms category id (name first, then fallback id
/// 1 only when a pulled category carries it). Null on a double
/// miss — the Tools tile hides and nothing is written.
int? resolveLeanCategoryId(List<QuickLogCategory> categories) =>
    resolveSummaryCategoryId(
      categories,
      name: leanCategoryName,
      fallbackId: leanCategoryFallbackId,
    );

// ── Capture ────────────────────────────────────────────────────────

/// One capture slot's stored values. A field is null when the user
/// entered nothing or 0 (not recorded). [source] is `manual` or
/// `health_connect`; [sampleTMs] is the Health Connect sample's own
/// timestamp, present only for a confirmed assist value.
class LeanCapture {
  /// Rest minute (9/10) for a resting capture, standing minute
  /// (0..10) for a checkpoint.
  final int minute;
  final int tMs;
  final int? hr;
  final int? sys;
  final int? dia;
  final String source;
  final int? sampleTMs;
  final String? symptomNote;

  const LeanCapture({
    required this.minute,
    required this.tMs,
    this.hr,
    this.sys,
    this.dia,
    this.source = 'manual',
    this.sampleTMs,
    this.symptomNote,
  });

  /// §9 Q2: a recorded value is at least one HR/BP value actually
  /// entered or confirmed. An empty/0 capture is not a value.
  bool get hasRecordedValue => hr != null || sys != null || dia != null;

  Map<String, dynamic> toJson() => {
        'minute': minute,
        'tMs': tMs,
        if (hr != null) 'hr': hr,
        if (sys != null) 'sys': sys,
        if (dia != null) 'dia': dia,
        'source': source,
        if (sampleTMs != null) 'sampleTMs': sampleTMs,
        if (symptomNote != null && symptomNote!.isNotEmpty)
          'symptomNote': symptomNote,
      };

  /// Payload form (spec §4): the checkpoint form carries `minute`;
  /// the baseline-reading form omits it (readings are ordered).
  Map<String, dynamic> toPayloadJson({required bool withMinute}) => {
        if (withMinute) 'minute': minute,
        'tMs': tMs,
        if (hr != null) 'hr': hr,
        if (sys != null) 'sys': sys,
        if (dia != null) 'dia': dia,
        'source': source,
        if (sampleTMs != null) 'sampleTMs': sampleTMs,
        if (symptomNote != null && symptomNote!.isNotEmpty)
          'symptomNote': symptomNote,
      };

  static LeanCapture? fromJson(Map<String, dynamic> j,
      {int fallbackMinute = 0}) {
    try {
      int asInt(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
      int? asPos(dynamic v) {
        final n = v is num ? v.toInt() : int.tryParse('$v');
        // The zero rule, on read as on write: 0 is never a value.
        return (n == null || n <= 0) ? null : n;
      }

      final tMs = asInt(j['tMs']);
      if (tMs == 0) return null;
      final note = j['symptomNote']?.toString();
      return LeanCapture(
        minute: j['minute'] == null ? fallbackMinute : asInt(j['minute']),
        tMs: tMs,
        hr: asPos(j['hr']),
        sys: asPos(j['sys']),
        dia: asPos(j['dia']),
        source: '${j['source'] ?? 'manual'}',
        sampleTMs: j['sampleTMs'] == null ? null : asInt(j['sampleTMs']),
        symptomNote: (note == null || note.isEmpty) ? null : note,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Manual-entry normalization (spec §3.4): empty or 0 = not
/// recorded; any other entered value is stored as entered, with no
/// range blocking.
int? leanEnteredValue(String raw) {
  final n = int.tryParse(raw.trim());
  if (n == null || n <= 0) return null;
  return n;
}

// ── Session ────────────────────────────────────────────────────────

enum LeanOutcome { completed, stoppedEarly, interrupted }

enum LeanPhase { rest, transition, standing }

/// Relaunch disposition for a persisted session (spec §3.3, §3.5,
/// override §9).
enum LeanRelaunch {
  /// Resume at the derived phase.
  resume,

  /// Rest expired while dead; standing never began — present the
  /// stand transition. Nothing was interrupted.
  transition,

  /// Standing expired while dead and values exist — present the
  /// interrupted screen (N3).
  interrupted,

  /// Standing expired while dead with ZERO recorded values —
  /// discard silently, no interrupted screen (coordinator judgment
  /// call applying §9 Q2's principle; flagged for Vera/Juno).
  discardSilently,
}

class LeanTestSession {
  final int startedAtMs;
  final int restStartedAtMs;
  final int? standingStartedAtMs;

  /// Submitted resting captures (slots 9 and 10), in slot order. A
  /// submitted-but-empty capture is present with no values.
  final List<LeanCapture> baselineCaptures;

  /// Submitted standing checkpoints, in submission order.
  final List<LeanCapture> checkpoints;

  /// The outbox entry id allocated for this session's result,
  /// persisted before the first stage attempt (exactly-once,
  /// migraine pattern). Null until the session first closes.
  final int? allocatedEntryId;

  /// The fully built result entry awaiting a successful stage, as a
  /// plain entry map. Non-null only while a stage is pending retry.
  final Map<String, dynamic>? pendingEntryJson;

  /// The outcome the pending entry was built with.
  final String? pendingOutcome;

  const LeanTestSession({
    required this.startedAtMs,
    required this.restStartedAtMs,
    this.standingStartedAtMs,
    this.baselineCaptures = const [],
    this.checkpoints = const [],
    this.allocatedEntryId,
    this.pendingEntryJson,
    this.pendingOutcome,
  });

  bool get hasAnyRecordedValue =>
      baselineCaptures.any((c) => c.hasRecordedValue) ||
      checkpoints.any((c) => c.hasRecordedValue);

  /// Resting captures that carry at least one recorded value — the
  /// payload's baseline readings.
  List<LeanCapture> get baselineReadings =>
      baselineCaptures.where((c) => c.hasRecordedValue).toList();

  int restElapsedMinutes(int nowMs) {
    final m = (nowMs - restStartedAtMs) ~/ 60000;
    return m < 0 ? 0 : m;
  }

  /// Null until the user taps S7 — the standing clock starts from
  /// that tap's timestamp only, never automatically.
  int? standingElapsedMinutes(int nowMs) {
    final start = standingStartedAtMs;
    if (start == null) return null;
    final m = (nowMs - start) ~/ 60000;
    return m < 0 ? 0 : m;
  }

  /// The current standing minute, capped at 10.
  int currentStandingMinute(int nowMs) {
    final e = standingElapsedMinutes(nowMs) ?? 0;
    return e > leanStandingMinutes ? leanStandingMinutes : e;
  }

  bool get minute10Submitted =>
      checkpoints.any((c) => c.minute == leanStandingMinutes);

  /// True when the standing phase fully expired (spec §3.3): the
  /// minute-10 capture window closed without a minute-10 capture.
  bool standingExpired(int nowMs) {
    final e = standingElapsedMinutes(nowMs);
    if (e == null) return false;
    return e >= leanStandingExpiryMinute && !minute10Submitted;
  }

  /// The derived phase at [nowMs]. Timing derives from timestamps
  /// only; nothing here counts ticks.
  LeanPhase phaseAt(int nowMs) {
    if (standingStartedAtMs != null) return LeanPhase.standing;
    if (restElapsedMinutes(nowMs) >= leanRestMinutes &&
        baselineCaptures.length >= leanBaselineMinutes.length) {
      return LeanPhase.transition;
    }
    return LeanPhase.rest;
  }

  /// The next resting capture slot due at [nowMs], or null: slot 9
  /// from rest minute 9, slot 10 from rest minute 10, in order.
  int? dueBaselineMinute(int nowMs) {
    final elapsed = restElapsedMinutes(nowMs);
    for (final slot in leanBaselineMinutes) {
      if (baselineCaptures.any((c) => c.minute == slot)) continue;
      return elapsed >= slot ? slot : null;
    }
    return null;
  }

  /// What a relaunch presents for this session (never an automatic
  /// resume or extension of the standing phase).
  LeanRelaunch relaunchAt(int nowMs) {
    if (standingStartedAtMs != null) {
      if (standingExpired(nowMs)) {
        return hasAnyRecordedValue
            ? LeanRelaunch.interrupted
            : LeanRelaunch.discardSilently;
      }
      return LeanRelaunch.resume;
    }
    if (phaseAt(nowMs) == LeanPhase.transition) {
      return LeanRelaunch.transition;
    }
    return LeanRelaunch.resume;
  }

  LeanTestSession copyWith({
    int? standingStartedAtMs,
    List<LeanCapture>? baselineCaptures,
    List<LeanCapture>? checkpoints,
    int? allocatedEntryId,
    Map<String, dynamic>? pendingEntryJson,
    String? pendingOutcome,
  }) {
    return LeanTestSession(
      startedAtMs: startedAtMs,
      restStartedAtMs: restStartedAtMs,
      standingStartedAtMs: standingStartedAtMs ?? this.standingStartedAtMs,
      baselineCaptures: baselineCaptures ?? this.baselineCaptures,
      checkpoints: checkpoints ?? this.checkpoints,
      allocatedEntryId: allocatedEntryId ?? this.allocatedEntryId,
      pendingEntryJson: pendingEntryJson ?? this.pendingEntryJson,
      pendingOutcome: pendingOutcome ?? this.pendingOutcome,
    );
  }

  Map<String, dynamic> toJson() => {
        'startedAtMs': startedAtMs,
        'restStartedAtMs': restStartedAtMs,
        'standingStartedAtMs': standingStartedAtMs,
        'baselineCaptures':
            baselineCaptures.map((c) => c.toJson()).toList(),
        'checkpoints': checkpoints.map((c) => c.toJson()).toList(),
        'allocatedEntryId': allocatedEntryId,
        'pendingEntryJson': pendingEntryJson,
        'pendingOutcome': pendingOutcome,
      };

  static LeanTestSession? fromJson(Map<String, dynamic> j) {
    try {
      int asInt(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
      int? asIntOrNull(dynamic v) =>
          v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
      final started = asInt(j['startedAtMs']);
      final rest = asInt(j['restStartedAtMs']);
      if (started == 0 || rest == 0) return null;
      List<LeanCapture> captures(dynamic raw, List<int> fallbackMinutes) {
        final out = <LeanCapture>[];
        if (raw is List) {
          for (var i = 0; i < raw.length; i++) {
            final row = raw[i];
            if (row is Map<String, dynamic>) {
              final c = LeanCapture.fromJson(row,
                  fallbackMinute:
                      i < fallbackMinutes.length ? fallbackMinutes[i] : 0);
              if (c != null) out.add(c);
            }
          }
        }
        return out;
      }

      final pendingRaw = j['pendingEntryJson'];
      return LeanTestSession(
        startedAtMs: started,
        restStartedAtMs: rest,
        standingStartedAtMs: asIntOrNull(j['standingStartedAtMs']),
        baselineCaptures:
            captures(j['baselineCaptures'], leanBaselineMinutes),
        checkpoints: captures(j['checkpoints'], const []),
        allocatedEntryId: asIntOrNull(j['allocatedEntryId']),
        pendingEntryJson: pendingRaw is Map
            ? pendingRaw.map((k, v) => MapEntry('$k', v))
            : null,
        pendingOutcome: j['pendingOutcome']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

// ── Baseline ───────────────────────────────────────────────────────

/// The record's baseline: the mean of the two resting readings when
/// both exist, the single reading when only one does, absent when
/// none do (spec §3.2, R2). Both raw readings always render beside
/// it. This average is the ONLY averaged figure in the feature.
class LeanBaseline {
  /// `mean_of_two` | `single`.
  final String form;
  final List<LeanCapture> readings;
  final double? hrMean;
  final double? sysMean;
  final double? diaMean;

  const LeanBaseline({
    required this.form,
    required this.readings,
    this.hrMean,
    this.sysMean,
    this.diaMean,
  });

  bool get isMean => form == 'mean_of_two';
}

double? _meanOf(List<LeanCapture> readings, int? Function(LeanCapture) pick) {
  final values = <int>[for (final r in readings) if (pick(r) != null) pick(r)!];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

/// Derives the baseline from value-bearing resting readings, or
/// null when there are none (no baseline renders, nothing is
/// fabricated).
LeanBaseline? leanBaselineOf(List<LeanCapture> readings) {
  if (readings.isEmpty) return null;
  return LeanBaseline(
    form: readings.length >= 2 ? 'mean_of_two' : 'single',
    readings: readings,
    hrMean: _meanOf(readings, (r) => r.hr),
    sysMean: _meanOf(readings, (r) => r.sys),
    diaMean: _meanOf(readings, (r) => r.dia),
  );
}

/// Measurement rendering (data display, app conventions): whole
/// numbers bare, a mean's half step at one decimal.
String leanFormatMeasure(double value) =>
    value == value.roundToDouble()
        ? '${value.toInt()}'
        : value.toStringAsFixed(1);

/// The baseline's headline value for the R2 label: heart rate when
/// any reading carries one, otherwise the blood-pressure pair.
String? leanBaselineValueText(LeanBaseline baseline) {
  if (baseline.hrMean != null) {
    return '${leanFormatMeasure(baseline.hrMean!)} bpm';
  }
  if (baseline.sysMean != null && baseline.diaMean != null) {
    return '${leanFormatMeasure(baseline.sysMean!)}/${leanFormatMeasure(baseline.diaMean!)} mmHg';
  }
  // A lone systolic or diastolic is a recorded value too: it must
  // render (named, so it cannot be mistaken for the other number),
  // never vanish from the baseline line.
  if (baseline.sysMean != null) {
    return 'Systolic: ${leanFormatMeasure(baseline.sysMean!)} mmHg';
  }
  if (baseline.diaMean != null) {
    return 'Diastolic: ${leanFormatMeasure(baseline.diaMean!)} mmHg';
  }
  return null;
}

/// The R2 baseline label line, or null when no baseline exists.
String? leanBaselineLabel(LeanBaseline? baseline) {
  if (baseline == null) return null;
  final value = leanBaselineValueText(baseline);
  if (value == null) return null;
  return baseline.isMean
      ? leanBaselineMeanLabel(value)
      : leanBaselineSingleLabel(value);
}

// ── Result payload + rendering (payload-only derivations) ─────────

/// A closed test's parsed payload — the single source every result
/// surface derives from (result screen, History body is built from
/// it at close, the tool's past-tests list, item 3's Z7 hand-off).
class LeanTestResult {
  final int startedAtMs;
  final String outcome; // completed | stopped_early | interrupted
  final String? stoppedPhase; // rest | standing
  final int? stoppedAtMinute;
  final List<LeanCapture> baselineReadings;
  final List<LeanCapture> checkpoints;
  final int disclaimerVersion;

  const LeanTestResult({
    required this.startedAtMs,
    required this.outcome,
    this.stoppedPhase,
    this.stoppedAtMinute,
    this.baselineReadings = const [],
    this.checkpoints = const [],
    this.disclaimerVersion = leanTestDisclaimerVersion,
  });

  LeanBaseline? get baseline => leanBaselineOf(baselineReadings);

  /// The S12 outcome form for this result — identical on every
  /// surface it renders (spec §8 test 12, override §9.1).
  String get outcomeLabel {
    switch (outcome) {
      case 'completed':
        return leanOutcomeCompleted;
      case 'interrupted':
        return leanOutcomeInterrupted;
      case 'stopped_early':
        if (stoppedPhase == 'rest') {
          return leanOutcomeStoppedRest(stoppedAtMinute ?? 0);
        }
        return leanOutcomeStoppedStanding(stoppedAtMinute ?? 0);
      default:
        return leanOutcomeInterrupted;
    }
  }

  /// The S12 completion line.
  String get completionLine => leanS12Line(
        outcomeLabel,
        formatAttackTimestamp(startedAtMs),
      );

  Map<String, dynamic> toPayload() => {
        'v': 1,
        'kind': leanTestPayloadKind,
        'startedAtMs': startedAtMs,
        'outcome': outcome,
        if (stoppedPhase != null) 'stoppedPhase': stoppedPhase,
        if (stoppedAtMinute != null) 'stoppedAtMinute': stoppedAtMinute,
        if (baselineReadings.isNotEmpty)
          'baseline': {
            'form': baseline!.form,
            'readings': baselineReadings
                .map((c) => c.toPayloadJson(withMinute: false))
                .toList(),
          },
        'checkpoints':
            checkpoints.map((c) => c.toPayloadJson(withMinute: true)).toList(),
        'disclaimerVersion': disclaimerVersion,
      };

  /// Parses a payload from an entry's `manualText`. Null when the
  /// text is not a lean-test payload. Never throws.
  static LeanTestResult? fromPayloadText(String manualText) {
    try {
      final decoded = jsonDecode(manualText);
      if (decoded is! Map<String, dynamic>) return null;
      return fromPayload(decoded);
    } catch (_) {
      return null;
    }
  }

  static LeanTestResult? fromPayload(Map<String, dynamic> p) {
    try {
      if (p['kind'] != leanTestPayloadKind) return null;
      int asInt(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
      final started = asInt(p['startedAtMs']);
      if (started == 0) return null;
      final readings = <LeanCapture>[];
      final baselineRaw = p['baseline'];
      if (baselineRaw is Map<String, dynamic>) {
        final list = baselineRaw['readings'];
        if (list is List) {
          for (var i = 0; i < list.length; i++) {
            final row = list[i];
            if (row is Map<String, dynamic>) {
              final c = LeanCapture.fromJson(row,
                  fallbackMinute:
                      i < leanBaselineMinutes.length
                          ? leanBaselineMinutes[i]
                          : 9);
              if (c != null) readings.add(c);
            }
          }
        }
      }
      final checkpoints = <LeanCapture>[];
      final rawCheckpoints = p['checkpoints'];
      if (rawCheckpoints is List) {
        for (final row in rawCheckpoints) {
          if (row is Map<String, dynamic>) {
            final c = LeanCapture.fromJson(row);
            if (c != null) checkpoints.add(c);
          }
        }
      }
      checkpoints.sort((a, b) => a.minute.compareTo(b.minute));
      return LeanTestResult(
        startedAtMs: started,
        outcome: '${p['outcome'] ?? 'interrupted'}',
        stoppedPhase: p['stoppedPhase']?.toString(),
        stoppedAtMinute:
            p['stoppedAtMinute'] == null ? null : asInt(p['stoppedAtMinute']),
        baselineReadings: readings,
        checkpoints: checkpoints,
        disclaimerVersion: asInt(p['disclaimerVersion']),
      );
    } catch (_) {
      return null;
    }
  }

  /// The recorded-values lines (data display): baseline readings,
  /// the R2 baseline line, then each standing minute in range —
  /// submitted values as recorded, unsubmitted or valueless minutes
  /// as U2. No derived figure of any kind appears here (R3).
  List<String> valueLines() {
    final lines = <String>[];
    for (var i = 0; i < baselineReadings.length; i++) {
      lines.add(
          'Resting reading ${i + 1}: ${leanCaptureValuesText(baselineReadings[i])}');
    }
    final label = leanBaselineLabel(baseline);
    if (label != null) lines.add(label);
    final byMinute = {for (final c in checkpoints) c.minute: c};
    final lastMinute = outcome == 'completed'
        ? leanStandingMinutes
        : (stoppedPhase == 'standing'
            ? (stoppedAtMinute ?? 0)
            : (checkpoints.isEmpty
                ? -1
                : checkpoints.map((c) => c.minute).reduce((a, b) => a > b ? a : b)));
    for (var m = 0; m <= lastMinute; m++) {
      final c = byMinute[m];
      lines.add('Minute $m: ${c == null ? leanU2 : leanCaptureValuesText(c)}');
      final note = c?.symptomNote;
      if (note != null && note.isNotEmpty) lines.add(note);
    }
    return lines;
  }

  /// The entry body: the human-readable summary — S12 completion
  /// line, the R2 baseline line (inside [valueLines]), and the
  /// recorded values per checkpoint. Derivations never read this.
  String bodyText() => [completionLine, ...valueLines()].join('\n');
}

/// One capture's values as recorded (data display): present fields
/// with their units; a capture with no values is U2.
String leanCaptureValuesText(LeanCapture c) {
  if (!c.hasRecordedValue) return leanU2;
  final parts = <String>[];
  parts.add(c.hr != null ? '${c.hr} bpm' : 'Heart rate: $leanU2');
  if (c.sys != null && c.dia != null) {
    parts.add('${c.sys}/${c.dia} mmHg');
  } else if (c.sys != null) {
    // A lone recorded number renders as itself, named — never as
    // U2, which would falsely say nothing was recorded.
    parts.add('Systolic: ${c.sys} mmHg');
  } else if (c.dia != null) {
    parts.add('Diastolic: ${c.dia} mmHg');
  }
  return parts.join(' · ');
}

/// Builds the ONE log entry a closed session stages (spec §4).
QuickLogEntry buildLeanTestEntry({
  required int id,
  required int categoryId,
  required LeanTestResult result,
}) {
  return QuickLogEntry(
    id: id,
    categoryId: categoryId,
    body: result.bodyText(),
    chips: jsonEncode([leanTestChip]),
    manualText: jsonEncode(result.toPayload()),
    timestamp: result.startedAtMs,
  );
}

/// True when an entry's chips carry the reserved lean-test chip
/// (JSON-list form, with the flare parser's tolerance for the other
/// shapes found in pulled data).
bool leanEntryHasChip(QuickLogEntry entry) {
  final raw = entry.chips.trim();
  if (raw.isEmpty) return false;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.any((c) => '$c'.trim() == leanTestChip);
    }
  } catch (_) {}
  var body = raw;
  if (body.startsWith('[') && body.endsWith(']')) {
    body = body.substring(1, body.length - 1);
  }
  return body
      .split(',')
      .map((p) => p.trim().replaceAll('"', '').trim())
      .contains(leanTestChip);
}

/// The past-tests list (N4): lean-test results derived from entries
/// carrying the chip, payload only — date, S12 outcome label, and
/// recorded values. No comparison, trend, or delta (spec §4).
List<LeanTestResult> leanPastResults(List<QuickLogEntry> entries) {
  final out = <LeanTestResult>[];
  for (final e in entries) {
    if (!leanEntryHasChip(e)) continue;
    final r = LeanTestResult.fromPayloadText(e.manualText);
    if (r != null) out.add(r);
  }
  out.sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
  return out;
}

// ── Health Connect assist ──────────────────────────────────────────

/// The assist offer for a checkpoint: the freshest stored sample of
/// the day at or before [nowMs], with its U1 display line. A sample
/// older than the checkpoint's minute carries the age form.
class LeanAssistOffer {
  final HrSample sample;
  final String displayLine;

  const LeanAssistOffer({required this.sample, required this.displayLine});
}

/// Builds the offer from the day's samples (spec §3.4, U1). Null
/// when no sample exists at or before [nowMs] — nothing is offered,
/// and nothing is ever written without user confirmation.
LeanAssistOffer? leanAssistOffer(
  List<HrSample> samples, {
  required int nowMs,
  required int checkpointTMs,
}) {
  HrSample? freshest;
  for (final s in samples) {
    if (s.timeMs > nowMs) continue;
    if (freshest == null || s.timeMs > freshest.timeMs) freshest = s;
  }
  if (freshest == null || freshest.bpm <= 0) return null;
  final time = formatAttackTimestamp(freshest.timeMs);
  final ageMinutes = (checkpointTMs - freshest.timeMs) ~/ 60000;
  return LeanAssistOffer(
    sample: freshest,
    displayLine: ageMinutes > 0
        ? leanU1Older(time, ageMinutes)
        : leanU1At(time),
  );
}

// ── Session store (owner-bound, MigraineAttackStore pattern) ──────

/// Local owner-bound store for the ONE active lean-test session.
/// FlutterSecureStorage blob `{ownerEmail, session}` — local-only,
/// never synced; the finished artifact is the staged log entry.
class LeanTestSessionStore {
  static const String storageKey = 'lean_test_session_v1';

  static final LeanTestSessionStore instance = LeanTestSessionStore._internal();

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  String? _boundOwner;

  factory LeanTestSessionStore() => instance;

  LeanTestSessionStore._internal();

  LeanTestSessionStore._(this._read, this._write, this._delete);

  static String? _normalizeEmail(String? email) =>
      CoachMemoryStore.normalizeEmail(email);

  @visibleForTesting
  factory LeanTestSessionStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) =>
      LeanTestSessionStore._(
        read,
        write,
        delete ??
            (key) async {
              await write(key, '');
            },
      );

  @visibleForTesting
  void debugSetStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) {
    _read = read;
    _write = write;
    if (delete != null) _delete = delete;
  }

  /// The persisted session, or null. A blob stamped for a different
  /// bound owner is wiped instead of served (migraine audit-4e
  /// pattern). Never throws.
  Future<LeanTestSession?> load() async {
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final stamp = _normalizeEmail(decoded['ownerEmail']?.toString());
      if (stamp != null && _boundOwner != null && stamp != _boundOwner) {
        try {
          await _delete(storageKey);
        } catch (_) {}
        return null;
      }
      final sessionRaw = decoded['session'];
      if (sessionRaw is! Map<String, dynamic>) return null;
      return LeanTestSession.fromJson(sessionRaw);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(LeanTestSession session) async {
    var stamp = _boundOwner;
    if (stamp == null) {
      try {
        final raw = await _read(storageKey);
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            stamp = _normalizeEmail(decoded['ownerEmail']?.toString());
          }
        }
      } catch (_) {}
    }
    await _write(
      storageKey,
      jsonEncode({'ownerEmail': stamp, 'session': session.toJson()}),
    );
  }

  /// Discards the session. Called only after the result entry has
  /// staged, on a no-entry close (§9 Q2), on discard-and-restart,
  /// and on the silent interrupted discard. Never throws.
  Future<void> clear() async {
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Logout / account-deletion wipe: drops the blob and unbinds.
  Future<void> clearAndUnbind() async {
    _boundOwner = null;
    await clear();
  }

  /// Login/register ownership enforcement, mirroring
  /// [MigraineAttackStore.clearIfOwnerMismatch]. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) {
        _boundOwner = expected;
        return false;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await clearAndUnbind();
        _boundOwner = expected;
        return true;
      }
      final owner = _normalizeEmail(decoded['ownerEmail']?.toString());
      if (owner == expected) {
        _boundOwner = expected;
        return false;
      }
      await clearAndUnbind();
      _boundOwner = expected;
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// The backend surface the lean-test flow needs. Abstract so tests
/// drive the whole flow without a backend; production is
/// `BackendLeanTestGateway` in the feature screen file.
abstract class LeanTestGateway {
  /// The name-resolved Symptoms category id, or null on a double
  /// miss (the tile hides; nothing is written to a guessed id).
  Future<int?> resolveCategoryId();

  /// Allocates a fresh entry id through the outbox's post-load
  /// allocator (VC 100107 mechanism).
  Future<int> allocateEntryId();

  /// Durably stages [entry] locally through the optimistic outbox.
  /// True only when the local stage succeeded.
  Future<bool> stageEntry(QuickLogEntry entry);

  /// All entries (pulled, merged with the outbox) for past results.
  Future<List<QuickLogEntry>> loadEntries();

  /// The day's stored Health Connect heart-rate samples.
  Future<List<HrSample>> readHrSamples(String dateStr);
}

/// The outcome of closing a session.
class LeanCloseResult {
  /// The staged (or pending) result; null in the §9 Q2 no-entry
  /// case (rest stop before any recorded value).
  final LeanTestResult? result;

  /// The entry built for the result, when one exists.
  final QuickLogEntry? entry;

  /// True when the entry staged durably and the local session was
  /// discarded. False with a non-null [entry] means the entry is
  /// persisted on the session as pending and retries on app start.
  final bool staged;

  const LeanCloseResult({this.result, this.entry, this.staged = false});

  bool get hasEntry => entry != null;
}

/// Closes sessions into log entries (spec §3.5, §4; override §9):
/// builds the result, persists the allocated id on the session
/// BEFORE staging, stages through the gateway, and discards the
/// local session only after the entry stages.
class LeanTestCloser {
  final LeanTestSessionStore store;
  final LeanTestGateway gateway;

  const LeanTestCloser({required this.store, required this.gateway});

  /// Standing stop: outcome stopped_early, phase standing, minute =
  /// the current standing minute.
  Future<LeanCloseResult> closeStandingStop(
      LeanTestSession session, int nowMs) {
    return _close(
      session,
      result: LeanTestResult(
        startedAtMs: session.startedAtMs,
        outcome: 'stopped_early',
        stoppedPhase: 'standing',
        stoppedAtMinute: session.currentStandingMinute(nowMs),
        baselineReadings: session.baselineReadings,
        checkpoints: _sorted(session.checkpoints),
        disclaimerVersion: leanTestDisclaimerVersion,
      ),
    );
  }

  /// Rest/transition stop (§9): with zero recorded values NO entry
  /// is staged and the session is discarded after the caller
  /// renders N5; with at least one recorded value the entry stages
  /// under the `Stopped early during rest at minute {n}` form,
  /// where {n} is the elapsed rest minute (10 on the transition
  /// screen).
  Future<LeanCloseResult> closeRestStop(
      LeanTestSession session, int nowMs) async {
    if (!session.hasAnyRecordedValue) {
      await store.clear();
      return const LeanCloseResult();
    }
    final restMinute = session.restElapsedMinutes(nowMs);
    return _close(
      session,
      result: LeanTestResult(
        startedAtMs: session.startedAtMs,
        outcome: 'stopped_early',
        stoppedPhase: 'rest',
        stoppedAtMinute:
            restMinute > leanRestMinutes ? leanRestMinutes : restMinute,
        baselineReadings: session.baselineReadings,
        checkpoints: _sorted(session.checkpoints),
        disclaimerVersion: leanTestDisclaimerVersion,
      ),
    );
  }

  /// Completion: all standing minutes ran and the minute-10
  /// capture was submitted.
  Future<LeanCloseResult> closeCompleted(LeanTestSession session) {
    return _close(
      session,
      result: LeanTestResult(
        startedAtMs: session.startedAtMs,
        outcome: 'completed',
        baselineReadings: session.baselineReadings,
        checkpoints: _sorted(session.checkpoints),
        disclaimerVersion: leanTestDisclaimerVersion,
      ),
    );
  }

  /// Close-as-interrupted from the N3 screen.
  Future<LeanCloseResult> closeInterrupted(LeanTestSession session) {
    return _close(
      session,
      result: LeanTestResult(
        startedAtMs: session.startedAtMs,
        outcome: 'interrupted',
        baselineReadings: session.baselineReadings,
        checkpoints: _sorted(session.checkpoints),
        disclaimerVersion: leanTestDisclaimerVersion,
      ),
    );
  }

  List<LeanCapture> _sorted(List<LeanCapture> captures) =>
      captures.toList()..sort((a, b) => a.minute.compareTo(b.minute));

  Future<LeanCloseResult> _close(
    LeanTestSession session, {
    required LeanTestResult result,
  }) async {
    final categoryId = await gateway.resolveCategoryId();
    if (categoryId == null) {
      // Double miss at close: never write to a guessed id. The
      // session stays local and unstaged.
      return LeanCloseResult(result: result, staged: false);
    }
    var working = session;
    var entryId = working.allocatedEntryId;
    if (entryId == null) {
      entryId = await gateway.allocateEntryId();
      working = working.copyWith(allocatedEntryId: entryId);
      // Persist the allocated id BEFORE staging (migraine pattern):
      // a kill between allocation and stage can never hand the id
      // to a different entry or lose this one.
      await store.save(working);
    }
    final entry =
        buildLeanTestEntry(id: entryId, categoryId: categoryId, result: result);
    working = working.copyWith(
      pendingEntryJson: {
        'id': entry.id,
        'categoryId': entry.categoryId,
        'body': entry.body,
        'chips': entry.chips,
        'manualText': entry.manualText,
        'timestamp': entry.timestamp,
      },
      pendingOutcome: result.outcome,
    );
    await store.save(working);
    final staged = await gateway.stageEntry(entry);
    if (staged) {
      // The local session is discarded ONLY after the entry stages.
      await store.clear();
    }
    return LeanCloseResult(result: result, entry: entry, staged: staged);
  }
}

/// App-start pending retry (migraine pattern): if the persisted
/// session carries a built-but-unstaged result entry, stage it
/// through [stage] with its persisted allocated id; the session is
/// discarded only after the stage succeeds, so the entry lands
/// exactly once. Returns true when a pending entry landed.
Future<bool> retryPendingLeanTestEntry({
  required LeanTestSessionStore store,
  required Future<bool> Function(QuickLogEntry entry) stage,
}) async {
  try {
    final session = await store.load();
    final pending = session?.pendingEntryJson;
    if (session == null || pending == null) return false;
    final entry = QuickLogEntry.fromJson(pending);
    if (entry.id == 0) return false;
    final ok = await stage(entry);
    if (ok) await store.clear();
    return ok;
  } catch (_) {
    return false;
  }
}
