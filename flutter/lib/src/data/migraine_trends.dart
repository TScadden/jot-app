import 'migraine_attack_store.dart';
import 'migraine_time_format.dart';
import 'quick_log_models.dart';

/// Trends entry construction for a migraine attack — Juno ruling
/// 2026-10-26 §E, verbatim. Exactly ONE entry per attack: written
/// when the attack ends, updated (same id, never duplicated) when
/// the post-tap details form is saved.
///
/// Template:
/// `Migraine attack — {duration}. {Aura: {aura}. }Peak pain {p}/10. Meds: {meds}. Relief {r}/5. Started {started-ts}.`
///
/// Substitutions (all mandatory):
/// - duration uses the Lab UI elapsed format (`45 min`, `2h 15m`).
/// - the Aura segment appears only when aura ≠ None, lowercased.
/// - unset peak pain (0) → `Peak pain not logged.`
/// - empty meds → `no meds logged`.
/// - unset relief (0) → `Relief not rated.`
String buildMigraineTrendsBody(MigraineAttack attack) {
  final endMs = attack.endTimestamp ?? attack.startTimestamp;
  var durationMin = (endMs - attack.startTimestamp) ~/ 60000;
  if (durationMin < 0) durationMin = 0;
  final durationText = formatElapsedDuration(durationMin);
  final auraText = attack.auraPhase.toUpperCase() != 'NONE'
      ? 'Aura: ${attack.auraPhase.toLowerCase()}. '
      : '';
  final painText = attack.painPeak > 0
      ? 'Peak pain ${attack.painPeak}/10. '
      : 'Peak pain not logged. ';
  final medsText =
      attack.medsTaken.isEmpty ? 'no meds logged' : attack.medsTaken;
  final reliefText = attack.reliefRating > 0
      ? 'Relief ${attack.reliefRating}/5. '
      : 'Relief not rated. ';
  return 'Migraine attack — $durationText. $auraText$painText'
      'Meds: $medsText. $reliefText'
      'Started ${formatAttackTimestamp(attack.startTimestamp)}.';
}

/// The Quick Log entry for [attack] under [entryId] (persisted on
/// the attack record at first end; reused for the form-save update)
/// in category [categoryId] (the founder's "Migraine Symptoms &
/// Triggers" when it exists, else Symptoms, fallback 1 — migraine
/// log trio fix 3; see the controller's gateway).
///
/// - timestamp = attack start.
/// - manualText = `Ended {ts}` in the Lab timestamp format.
/// - chips = `["Migraine attack"]`.
QuickLogEntry buildMigraineTrendsEntry(
  MigraineAttack attack, {
  required int entryId,
  required int categoryId,
}) {
  final endMs = attack.endTimestamp ?? attack.startTimestamp;
  return QuickLogEntry(
    id: entryId,
    categoryId: categoryId,
    body: buildMigraineTrendsBody(attack),
    chips: '["Migraine attack"]',
    manualText: 'Ended ${formatAttackTimestamp(endMs)}',
    timestamp: attack.startTimestamp,
  );
}
