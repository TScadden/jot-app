import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Phase 1, item 2a — medication change-event CAPTURE (spec
/// §2.6, phase1-item2-med-effectiveness-spec.md).
///
/// Every medication start, stop, restore, dose change,
/// frequency change, date edit, and delete becomes ONE
/// append-only change event, diffed from the FRESH pre-push
/// medication list against the list that was actually pushed —
/// never from a rendered snapshot (diffing the rendered snapshot
/// would record wrong "old" values — the exact Oct 22, 2026
/// failure the fresh-pull-before-splice discipline exists to
/// prevent).
///
/// Events are emitted ONLY after the profile push succeeds
/// (spec §2.6): a failed or refused push emits no event.
/// Emission is best-effort — see [emitMedicationChangeEvents].
///
/// This file has NO user-visible strings and no UI; the
/// timeline view (item 2b) is a separate package.

/// The five medication fields a change event snapshots, in the
/// exact shape of the server contract's `old` / `new` objects.
class MedicationFieldSnapshot {
  final String dose;
  final String frequency;
  final String startDate;

  /// The STORED end date: the stamped/declared date for an
  /// archived med, `''` when an archived row carries none, and
  /// the `"Present"` sentinel for an active med — exactly what
  /// [MedicationEntry.toBlobRow] emits.
  final String endDate;
  final bool isPresent;

  const MedicationFieldSnapshot({
    required this.dose,
    required this.frequency,
    required this.startDate,
    required this.endDate,
    required this.isPresent,
  });

  factory MedicationFieldSnapshot.fromEntry(MedicationEntry entry) {
    return MedicationFieldSnapshot(
      dose: entry.dose,
      frequency: entry.rawFrequency,
      startDate: entry.startDate,
      endDate: '${entry.toBlobRow()['endDate'] ?? ''}',
      isPresent: !entry.isArchived,
    );
  }

  factory MedicationFieldSnapshot.fromJson(Map<String, dynamic> json) {
    return MedicationFieldSnapshot(
      dose: '${json['dose'] ?? ''}',
      frequency: '${json['frequency'] ?? ''}',
      startDate: '${json['startDate'] ?? ''}',
      endDate: '${json['endDate'] ?? ''}',
      isPresent: json['isPresent'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'dose': dose,
    'frequency': frequency,
    'startDate': startDate,
    'endDate': endDate,
    'isPresent': isPresent,
  };

  @override
  bool operator ==(Object other) =>
      other is MedicationFieldSnapshot &&
      other.dose == dose &&
      other.frequency == frequency &&
      other.startDate == startDate &&
      other.endDate == endDate &&
      other.isPresent == isPresent;

  @override
  int get hashCode =>
      Object.hash(dose, frequency, startDate, endDate, isPresent);
}

/// One append-only medication change event, in the exact JSON
/// shape of the server contract for
/// `POST /api/sync/medication-events` (insert-only server-side;
/// the client-supplied [id] makes replays harmless).
class MedicationChangeEvent {
  final String id;

  /// The medication row's id at capture time; may be `''` for
  /// id-less rows (such rows exist in real blobs).
  final String medId;

  /// Name snapshot — names get edited and rows get deleted, so
  /// the event carries the name it was recorded under.
  final String medName;

  /// One of `start | dose_change | frequency_change | stop |
  /// restore | delete | dates_edit`.
  final String type;

  final MedicationFieldSnapshot? oldSnapshot;
  final MedicationFieldSnapshot? newSnapshot;

  /// The declared start/end string the change is effective
  /// from, kept distinct from [recordedAt] (spec §2.6: starts
  /// are routinely backdated or month-precision, and archive
  /// stamps are action dates, so both are stored, always).
  /// Null for dose/frequency changes and for deleting a med
  /// that was still active.
  final String? effectiveDate;

  /// Epoch ms capture time — the same value for every event in
  /// one diff batch.
  final int recordedAt;

  /// One of `tools | settings | coach` — the writer surface the
  /// mutation flowed through.
  final String source;

  const MedicationChangeEvent({
    required this.id,
    required this.medId,
    required this.medName,
    required this.type,
    required this.oldSnapshot,
    required this.newSnapshot,
    required this.effectiveDate,
    required this.recordedAt,
    required this.source,
  });

  /// Parses one event in the GET `/api/sync/medication-events`
  /// response shape (the server's re-shaped client contract:
  /// `old` / `new` snapshot objects or null, `recordedAt` already
  /// coerced to a number server-side).
  factory MedicationChangeEvent.fromJson(Map<String, dynamic> json) {
    MedicationFieldSnapshot? snap(Object? raw) =>
        raw is Map<String, dynamic>
            ? MedicationFieldSnapshot.fromJson(raw)
            : null;
    return MedicationChangeEvent(
      id: '${json['id'] ?? ''}',
      medId: '${json['medId'] ?? ''}',
      medName: '${json['medName'] ?? ''}',
      type: '${json['type'] ?? ''}',
      oldSnapshot: snap(json['old']),
      newSnapshot: snap(json['new']),
      effectiveDate:
          json['effectiveDate'] is String ? json['effectiveDate'] as String : null,
      recordedAt: (json['recordedAt'] as num?)?.toInt() ?? 0,
      source: '${json['source'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'medId': medId,
    'medName': medName,
    'type': type,
    'old': oldSnapshot?.toJson(),
    'new': newSnapshot?.toJson(),
    'effectiveDate': effectiveDate,
    'recordedAt': recordedAt,
    'source': source,
  };
}

/// Diffs the FRESH [before] medication list against the pushed
/// [after] list and classifies each changed row into exactly
/// ONE change event.
///
/// Pairing, in order:
/// 1. rows whose non-empty id occurs exactly once in each list
///    pair by that id;
/// 2. among unpaired rows, a before/after pair with equal name
///    AND equal snapshot pairs greedily (unchanged rows) — this
///    makes insert/delete alignment fall out naturally;
/// 3. remaining unpaired rows on both sides pair IN ORDER (the
///    mutation ops preserve list order); leftover before-only
///    rows are deletes and leftover after-only rows are starts.
///
/// Classification per pair — exactly one event, this
/// precedence: `isPresent` true→false is `stop`, false→true is
/// `restore`, a dose difference is `dose_change`, a frequency
/// difference is `frequency_change`, a start/end date
/// difference is `dates_edit`, and equal snapshots emit NO
/// event. The name is NOT compared: a rename alone emits
/// nothing (spec Q5 assumption — renames only change the
/// `medName` snapshot on future events). `updatedAt` and
/// `isDeleted` are NOT compared, so a no-change edit (which
/// still bumps `updatedAt`) emits nothing.
List<MedicationChangeEvent> diffMedicationLists({
  required List<MedicationEntry> before,
  required List<MedicationEntry> after,
  required String source,
  required DateTime now,
  required String Function() idGen,
}) {
  final recordedAt = now.millisecondsSinceEpoch;
  final beforeSnaps = [
    for (final e in before) MedicationFieldSnapshot.fromEntry(e),
  ];
  final afterSnaps = [
    for (final e in after) MedicationFieldSnapshot.fromEntry(e),
  ];

  final pairedBefore = List<bool>.filled(before.length, false);
  final pairedAfter = List<bool>.filled(after.length, false);
  final pairs = <(int, int)>[]; // (beforeIndex, afterIndex)

  // (1) Unique non-empty id pairing.
  final beforeIdCounts = <String, int>{};
  for (final e in before) {
    if (e.id.isNotEmpty) beforeIdCounts[e.id] = (beforeIdCounts[e.id] ?? 0) + 1;
  }
  final afterIdCounts = <String, int>{};
  for (final e in after) {
    if (e.id.isNotEmpty) afterIdCounts[e.id] = (afterIdCounts[e.id] ?? 0) + 1;
  }
  for (var i = 0; i < before.length; i++) {
    final id = before[i].id;
    if (id.isEmpty) continue;
    if (beforeIdCounts[id] != 1 || afterIdCounts[id] != 1) continue;
    for (var j = 0; j < after.length; j++) {
      if (!pairedAfter[j] && after[j].id == id) {
        pairs.add((i, j));
        pairedBefore[i] = true;
        pairedAfter[j] = true;
        break;
      }
    }
  }

  // (2) Unchanged-row pairing: equal name AND equal snapshot.
  for (var i = 0; i < before.length; i++) {
    if (pairedBefore[i]) continue;
    for (var j = 0; j < after.length; j++) {
      if (pairedAfter[j]) continue;
      if (after[j].name == before[i].name && afterSnaps[j] == beforeSnaps[i]) {
        pairs.add((i, j));
        pairedBefore[i] = true;
        pairedAfter[j] = true;
        break;
      }
    }
  }

  // (3) Remaining rows pair in order.
  final remainingBefore = [
    for (var i = 0; i < before.length; i++)
      if (!pairedBefore[i]) i,
  ];
  final remainingAfter = [
    for (var j = 0; j < after.length; j++)
      if (!pairedAfter[j]) j,
  ];
  final inOrderPairs = remainingBefore.length < remainingAfter.length
      ? remainingBefore.length
      : remainingAfter.length;
  for (var k = 0; k < inOrderPairs; k++) {
    final i = remainingBefore[k];
    final j = remainingAfter[k];
    pairs.add((i, j));
    pairedBefore[i] = true;
    pairedAfter[j] = true;
  }

  final events = <MedicationChangeEvent>[];

  // Changed pairs, in before-list order.
  final sortedPairs = [...pairs]..sort((a, b) => a.$1.compareTo(b.$1));
  for (final (i, j) in sortedPairs) {
    final oldSnap = beforeSnaps[i];
    final newSnap = afterSnaps[j];
    if (oldSnap == newSnap) continue;
    final String type;
    final String? effectiveDate;
    if (oldSnap.isPresent && !newSnap.isPresent) {
      type = 'stop';
      effectiveDate = newSnap.endDate;
    } else if (!oldSnap.isPresent && newSnap.isPresent) {
      type = 'restore';
      // The end date in effect until the restore — the value
      // the unarchive op erases from the row, preserved only
      // here (spec §2.6).
      effectiveDate = oldSnap.endDate;
    } else if (oldSnap.dose != newSnap.dose) {
      type = 'dose_change';
      effectiveDate = null;
    } else if (oldSnap.frequency != newSnap.frequency) {
      type = 'frequency_change';
      effectiveDate = null;
    } else if (oldSnap.startDate != newSnap.startDate ||
        oldSnap.endDate != newSnap.endDate) {
      type = 'dates_edit';
      effectiveDate = oldSnap.startDate != newSnap.startDate
          ? newSnap.startDate
          : newSnap.endDate;
    } else {
      // Snapshots differ only in a field no classification
      // covers — unreachable for the five snapshot fields, and
      // never a reason to invent an event.
      continue;
    }
    events.add(
      MedicationChangeEvent(
        id: idGen(),
        medId: after[j].id.isNotEmpty ? after[j].id : before[i].id,
        medName: after[j].name,
        type: type,
        oldSnapshot: oldSnap,
        newSnapshot: newSnap,
        effectiveDate: effectiveDate,
        recordedAt: recordedAt,
        source: source,
      ),
    );
  }

  // Leftover before-only rows are deletes.
  for (var i = 0; i < before.length; i++) {
    if (pairedBefore[i]) continue;
    final oldSnap = beforeSnaps[i];
    events.add(
      MedicationChangeEvent(
        id: idGen(),
        medId: before[i].id,
        medName: before[i].name,
        type: 'delete',
        oldSnapshot: oldSnap,
        newSnapshot: null,
        effectiveDate: oldSnap.isPresent ? null : oldSnap.endDate,
        recordedAt: recordedAt,
        source: source,
      ),
    );
  }

  // Leftover after-only rows are starts.
  for (var j = 0; j < after.length; j++) {
    if (pairedAfter[j]) continue;
    final newSnap = afterSnaps[j];
    events.add(
      MedicationChangeEvent(
        id: idGen(),
        medId: after[j].id,
        medName: after[j].name,
        type: 'start',
        oldSnapshot: null,
        newSnapshot: newSnap,
        effectiveDate: newSnap.startDate,
        recordedAt: recordedAt,
        source: source,
      ),
    );
  }

  return events;
}

/// Best-effort emission of [events] through [backend].
///
/// Per spec §2.6, call sites invoke this ONLY after the profile
/// push has succeeded — a failed or refused push emits no
/// event. An empty list makes no call at all. ALL failures are
/// swallowed: a capture failure must never surface to the user
/// or un-save a completed save (the medication list push has
/// already landed by the time this runs).
Future<void> emitMedicationChangeEvents(
  TabsBackend backend,
  List<MedicationChangeEvent> events,
) async {
  if (events.isEmpty) return;
  try {
    await backend.postMedicationChangeEvents(events);
  } catch (_) {
    // Best-effort capture (spec §2.6): never surface, never
    // un-save a completed save.
  }
}
