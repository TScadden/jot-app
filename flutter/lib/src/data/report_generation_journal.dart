import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'progress_report.dart';

/// VC 100129 — the report generation journal (R-2 Tier 1, T1-1;
/// subsumes R-1 F1's persistence: there is exactly ONE record).
///
/// One live generation at a time: the journal holds a single
/// record, written when a generation starts, updated at every
/// stage change and when the PDF save lands, and finalized at
/// finish. The next [ReportGenerationService.start] supersedes
/// it. The record is bounded: request identity, stage, outcome
/// kind, and — for ready — the exact artifact reference; for
/// failed/decision — class, reason, and the full attempt
/// records. It carries NO health content beyond what the outcome
/// itself already carries (messages and attempt metadata only —
/// never entries, series, or snapshot data).
///
/// Store: the app's established SettingsStore /
/// flutter_secure_storage pattern (JSON blob under one key).
/// The app has no SharedPreferences and no sqflite/Drift, and
/// this package adds neither.

// ── Juno R5 verbatim strings (rulings-5, VC 100129) ─────────────

/// R5-1 — interrupted title.
const interruptedTitle = "Your report didn't finish";

/// R5-2 — interrupted body.
const interruptedBody =
    'Tabs stopped before this report finished. Your logged data is safe, and you can try the report again.';

/// R5-3 — interrupted retry action (a fresh generation).
const interruptedRetryLabel = 'Try again';

/// R5-9 — auto re-run framing line (above the unchanged stage
/// labels, only while an auto re-run is actually in flight).
const autoRerunFraming = 'Starting your report again';

/// R5-5 Case 2 — restored-decision body (no snapshot survives
/// death, so the original body/buttons are same-session only).
const restoredDecisionBodyCase2 =
    'Your data is safe. The AI analysis could not be completed on your earlier attempt. To try again, start a new report.';

/// R5-5 Case 2 — restored-decision single action.
const restoredDecisionAction = 'Start a new report';

/// R5-6 — F1 details expansion label.
const attemptDetailsLabel = 'Details';

// ── VC 100131 (Round 3) — expired-hold copy ─────────────────────
//
// FINAL — Juno's SIGNED R8-1 copy
// (~/workspace/mega-100127/round3-juno-stage2-rulings.md, R8-1:
// "FINAL expired-hold copy — SIGNED (not a draft; build exactly
// this)"). An expired hold is a NEW terminal state (the report
// DID finish server-side, but its held narrative passed the 24 h
// ceiling and was deleted), so it may NOT reuse the
// failed/decision copy. This is the ONLY place the expired copy
// lives. Ruled presentation (R8-1): a 410 pickup answer at
// decision-restore REPLACES the decision surface with this
// presentation; an in-session 410 shows the SAME state and ends
// the generation; the only exit is the action below, which mints
// a NEW identity for a new logical generation.

/// R8-1 FINAL — expired-hold title.
const expiredHoldTitle = 'Your earlier report is no longer saved';

/// R8-1 FINAL — expired-hold body.
const expiredHoldBody =
    'Tabs finished that report and held it for 24 hours. That time has passed and the held copy has been deleted. You can make a new report from your data.';

/// R8-1 FINAL — expired-hold action (starts a NEW logical
/// generation: new identity, full collect + generate).
const expiredHoldActionLabel = 'Make a new report';

// ── VC 100131 (Round 3) — the wire generation identity ──────────

/// Mints the stable logical-generation identity sent to the
/// server as `reportGenerationId` (POST /api/ai/report body field
/// and the pickup path parameter): 128 bits from
/// [Random.secure], lowercase hex (32 chars). Minted ONCE per
/// user-initiated logical generation by
/// ReportGenerationService.start and persisted on the journal
/// entry; decision resumes, the interrupted auto-rerun, and
/// interrupted retries REUSE the persisted value (see the service
/// for the minting rule). Deliberately NOT the journal
/// `generationId` (a per-start() bookkeeping id that rotates on
/// every resume/restore and carries a process-local counter).
///
/// Vera Stage 2 adjudication, Item D1 condition: NO weak
/// fallback. If secure randomness throws or is unavailable this
/// returns null and the generation proceeds with NO
/// reportGenerationId (legacy behaviour) — a missing ID beats a
/// guessable one; never downgrade to a non-secure source.
String? mintReportGenerationId() {
  try {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  } catch (_) {
    return null;
  }
}

// ── Juno R6 verbatim strings (round2-juno-rulings, VC 100130) ──
//
// The closed set of base lines for NON-AI failures, ruled
// verbatim in R6-2. These are the ONLY rendered form of the
// journal's internal failure kind/stage names (R6-4 condition 1:
// the names themselves are never rendered, in any form). The
// stage is never user-visible (R6-3): the collection lines do
// not split by stage, because the collection deadline is
// cumulative across stages and a stage-specific line could
// misattribute the cause.

/// R6-2 — collectionTimeout base line (any collection stage).
const failureLineCollectionTimeout =
    'Collecting your report data took too long, so the report stopped';

/// R6-2 — collectionFailure base line (any collection stage).
const failureLineCollectionFailure =
    'Something went wrong while collecting your report data';

/// R6-2 — renderFailure base line.
const failureLineRenderFailure =
    'Something went wrong while creating the PDF file';

/// R6-2 — saveFailure base line.
const failureLineSaveFailure =
    'Something went wrong while saving the PDF file';

/// R6-1: the rendered non-AI failure line for a journaled
/// failure kind: `{base line} · {time}`, where the time is the
/// journal's recorded finish time in the governing format
/// ([journalTimeText]). No recorded finish time → the base line
/// alone (no separator, no placeholder). An unknown or absent
/// kind (including a buildingSummary escape, which records no
/// kind) → null: no line. Exactly one such line exists per
/// failed generation; the service renders it AFTER any AI
/// attempt lines.
String? reportFailureDetailLine(String? failureKindName,
    {DateTime? finishedAt}) {
  final base = switch (failureKindName) {
    'collectionTimeout' => failureLineCollectionTimeout,
    'collectionFailure' => failureLineCollectionFailure,
    'renderFailure' => failureLineRenderFailure,
    'saveFailure' => failureLineSaveFailure,
    _ => null,
  };
  if (base == null) return null;
  if (finishedAt == null) return base;
  return '$base · ${journalTimeText(finishedAt)}';
}

const _monthsShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The governing time format (rulings-5 head): local device
/// time, 12-hour clock, hour with no leading zero, two-digit
/// minutes, then AM/PM — e.g. `1:37 AM`. Always the time
/// recorded in the journal, never display time.
String journalTimeText(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// R5-4 / R5-8 framing template (one wording for every
/// "earlier attempt" surface): same calendar day as display →
/// `From your earlier attempt at {time}.`; earlier day →
/// `From your earlier attempt on {Mon d} at {time}.`
String earlierAttemptFraming(DateTime recordedAt, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final sameDay = recordedAt.year == n.year &&
      recordedAt.month == n.month &&
      recordedAt.day == n.day;
  if (sameDay) {
    return 'From your earlier attempt at ${journalTimeText(recordedAt)}.';
  }
  return 'From your earlier attempt on ${_monthsShort[recordedAt.month - 1]} '
      '${recordedAt.day} at ${journalTimeText(recordedAt)}.';
}

/// R5-7 closed plain-language mapping (class → the only label
/// that may be shown). Raw class names and raw plainReason
/// strings are never rendered.
String attemptPlainLabel(AiFailureClass cls) => switch (cls) {
      AiFailureClass.connection => 'No connection',
      AiFailureClass.timeout => 'Timed out waiting for a response',
      AiFailureClass.server => 'Server error',
      AiFailureClass.rateLimited => 'Server was busy',
      AiFailureClass.session => 'Not signed in',
      AiFailureClass.fatalRequest => 'Request could not be completed',
      AiFailureClass.unknown => 'Unknown error',
      AiFailureClass.preDispatch => 'Could not start the request in the app',
    };

/// R5-7 per-attempt line: `Attempt {n} · {time} · {plain label}`,
/// plus ` · HTTP {status}` ONLY when a status was actually
/// received. Succeeded attempts carry no failure label and are
/// not rendered as detail lines (returns null).
String? attemptDetailLine(AiAttemptRecord a) {
  final cls = a.failureClass;
  if (a.succeeded || cls == null) return null;
  final base =
      'Attempt ${a.attempt} · ${journalTimeText(a.at)} · ${attemptPlainLabel(cls)}';
  return a.httpStatus != null ? '$base · HTTP ${a.httpStatus}' : base;
}

// ── Request identity ─────────────────────────────────────────────

/// What was being generated — persisted NOWHERE before this
/// package (kind and category ids included). Enough to start a
/// fresh generation from the same identity after process death,
/// and nothing more.
class ReportRequestIdentity {
  /// 'standard' or 'clinician'.
  final String kind;
  final String focusKey;
  final bool last30Days;
  final List<int> categoryIds;
  final bool forceRaw;

  const ReportRequestIdentity({
    required this.kind,
    required this.focusKey,
    required this.last30Days,
    required this.categoryIds,
    this.forceRaw = false,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'focusKey': focusKey,
        'last30Days': last30Days,
        'categoryIds': categoryIds,
        'forceRaw': forceRaw,
      };

  static ReportRequestIdentity? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    try {
      final ids = raw['categoryIds'];
      return ReportRequestIdentity(
        kind: '${raw['kind'] ?? 'standard'}',
        focusKey: '${raw['focusKey'] ?? 'health'}',
        last30Days: raw['last30Days'] == true,
        categoryIds: [
          if (ids is List)
            for (final e in ids)
              if (e is num) e.toInt(),
        ],
        forceRaw: raw['forceRaw'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

// ── Journal entry ────────────────────────────────────────────────

enum JournalOutcomeKind {
  running,
  ready,
  failed,
  decision,

  /// VC 100131 (Round 3): the generation FINISHED server-side
  /// but its held narrative expired before pickup (the pickup
  /// endpoint answered 410). A terminal presentation state of
  /// its own — distinct from [failed] (the generation did not
  /// fail) and from [decision] (there is nothing to resume: the
  /// narrative is gone and Juno R7-7 forbids regeneration at
  /// pickup or after expiry; the only action is a NEW logical
  /// generation). Tolerant read: builds that predate this value
  /// parse an unknown outcomeKind as [running] (the existing
  /// orElse in fromJsonString), which degrades an expired record
  /// to the interrupted handling — never to a false ready/failed.
  expired,
}

class ReportJournalEntry {
  final String generationId;
  final int startedAtMs;
  final int updatedAtMs;
  final int? finishedAtMs;
  final ReportRequestIdentity request;

  /// Current stage name (ReportStage.name) while running; null
  /// once finished.
  final String? stage;
  final JournalOutcomeKind outcomeKind;

  // Ready outcome: the exact artifact reference.
  final String? fileName;
  final String? savedPath;
  final bool? downloadsSaved;
  final bool? isRawFallback;

  // Failed/decision outcome.
  final String? message;
  final String? aiFailureReason;
  final String? failureClassName;
  final bool? allowRawFallback;
  final List<AiAttemptRecord> attempts;

  // VC 100130 diagnostic record (additive): the failed
  // generation's ReportFailureKind / ReportStage names, recorded
  // whenever the producer supplied them — independent of the AI
  // attempt history (a collection timeout has zero attempts and
  // still records both). [stage] above is the LIVE stage and
  // clears at finish; [failureStageName] is the permanent record
  // of where the failure happened.
  final String? failureKindName;
  final String? failureStageName;

  // VC 100131 (Round 3) wire identity (additive): the stable
  // logical-generation id sent to the server as
  // `reportGenerationId` — 128-bit secure-random lowercase hex,
  // minted once per user-initiated logical generation (see
  // [mintReportGenerationId] and the service's minting rule) and
  // REUSED across decision resumes, the interrupted auto-rerun,
  // and interrupted retries of the same logical generation.
  // Null on records written by builds that predate Round 3.
  final String? reportGenerationId;

  // VC 100131 (Round 3) cancel tombstone (additive, default
  // false): set + persisted by requestCancel on the Cancel tap
  // itself (Juno R8-2). While set, NO pickup is ever attempted
  // for [reportGenerationId] at any call site and the identity
  // is never re-POSTed: a cancelled generation is invalidated
  // client-side independently of whether the server DELETE
  // landed.
  final bool generationInvalidated;

  // VC 100131 (Round 3) held-completion record (additive,
  // Vera Stage 2 Item 4 condition): the server's `completedAt`
  // for a narrative collected by PICKUP, recorded on the
  // terminal journal record. Recorded, NOT displayed anywhere
  // (Juno's silent-pickup ruling stands — no provenance surface
  // reads this). Null for POST-delivered completions (the POST
  // success body carries no completedAt) and for every
  // non-ready outcome.
  final int? heldCompletedAtMs;

  const ReportJournalEntry({
    required this.generationId,
    required this.startedAtMs,
    required this.updatedAtMs,
    this.finishedAtMs,
    required this.request,
    this.stage,
    required this.outcomeKind,
    this.fileName,
    this.savedPath,
    this.downloadsSaved,
    this.isRawFallback,
    this.message,
    this.aiFailureReason,
    this.failureClassName,
    this.allowRawFallback,
    this.attempts = const [],
    this.failureKindName,
    this.failureStageName,
    this.reportGenerationId,
    this.generationInvalidated = false,
    this.heldCompletedAtMs,
  });

  bool get isTerminal => outcomeKind != JournalOutcomeKind.running;

  DateTime get startedAt =>
      DateTime.fromMillisecondsSinceEpoch(startedAtMs);
  DateTime? get finishedAt => finishedAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(finishedAtMs!);

  AiFailureClass? get failureClass {
    for (final c in AiFailureClass.values) {
      if (c.name == failureClassName) return c;
    }
    return null;
  }

  ReportJournalEntry copyWith({
    int? updatedAtMs,
    int? finishedAtMs,
    String? stage,
    bool clearStage = false,
    JournalOutcomeKind? outcomeKind,
    String? fileName,
    String? savedPath,
    bool? downloadsSaved,
    bool? isRawFallback,
    String? message,
    String? aiFailureReason,
    String? failureClassName,
    bool? allowRawFallback,
    List<AiAttemptRecord>? attempts,
    String? failureKindName,
    String? failureStageName,
    String? reportGenerationId,
    bool? generationInvalidated,
    int? heldCompletedAtMs,
  }) =>
      ReportJournalEntry(
        generationId: generationId,
        startedAtMs: startedAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        finishedAtMs: finishedAtMs ?? this.finishedAtMs,
        request: request,
        stage: clearStage ? null : (stage ?? this.stage),
        outcomeKind: outcomeKind ?? this.outcomeKind,
        fileName: fileName ?? this.fileName,
        savedPath: savedPath ?? this.savedPath,
        downloadsSaved: downloadsSaved ?? this.downloadsSaved,
        isRawFallback: isRawFallback ?? this.isRawFallback,
        message: message ?? this.message,
        aiFailureReason: aiFailureReason ?? this.aiFailureReason,
        failureClassName: failureClassName ?? this.failureClassName,
        allowRawFallback: allowRawFallback ?? this.allowRawFallback,
        attempts: attempts ?? this.attempts,
        failureKindName: failureKindName ?? this.failureKindName,
        failureStageName: failureStageName ?? this.failureStageName,
        reportGenerationId: reportGenerationId ?? this.reportGenerationId,
        generationInvalidated:
            generationInvalidated ?? this.generationInvalidated,
        heldCompletedAtMs: heldCompletedAtMs ?? this.heldCompletedAtMs,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'generationId': generationId,
        'startedAtMs': startedAtMs,
        'updatedAtMs': updatedAtMs,
        'finishedAtMs': finishedAtMs,
        'request': request.toJson(),
        'stage': stage,
        'outcomeKind': outcomeKind.name,
        'fileName': fileName,
        'savedPath': savedPath,
        'downloadsSaved': downloadsSaved,
        'isRawFallback': isRawFallback,
        'message': message,
        'aiFailureReason': aiFailureReason,
        'failureClassName': failureClassName,
        'failureKindName': failureKindName,
        'failureStageName': failureStageName,
        'reportGenerationId': reportGenerationId,
        'generationInvalidated': generationInvalidated,
        'heldCompletedAtMs': heldCompletedAtMs,
        'allowRawFallback': allowRawFallback,
        'attempts': [
          for (final a in attempts)
            {
              'attempt': a.attempt,
              'failureClass': a.failureClass?.name,
              'httpStatus': a.httpStatus,
              'succeeded': a.succeeded,
              'atMs': a.at.millisecondsSinceEpoch,
            },
        ],
      };

  static ReportJournalEntry? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final request = ReportRequestIdentity.fromJson(decoded['request']);
      if (request == null) return null;
      final kindName = '${decoded['outcomeKind']}';
      final kind = JournalOutcomeKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => JournalOutcomeKind.running,
      );
      final attempts = <AiAttemptRecord>[];
      final rawAttempts = decoded['attempts'];
      if (rawAttempts is List) {
        for (final r in rawAttempts) {
          if (r is! Map) continue;
          AiFailureClass? cls;
          final cn = r['failureClass'];
          if (cn is String) {
            for (final c in AiFailureClass.values) {
              if (c.name == cn) cls = c;
            }
          }
          attempts.add(AiAttemptRecord(
            attempt: (r['attempt'] as num?)?.toInt() ?? attempts.length + 1,
            failureClass: cls,
            httpStatus: (r['httpStatus'] as num?)?.toInt(),
            succeeded: r['succeeded'] == true,
            at: DateTime.fromMillisecondsSinceEpoch(
                (r['atMs'] as num?)?.toInt() ?? 0),
          ));
        }
      }
      return ReportJournalEntry(
        generationId: '${decoded['generationId'] ?? ''}',
        startedAtMs: (decoded['startedAtMs'] as num?)?.toInt() ?? 0,
        updatedAtMs: (decoded['updatedAtMs'] as num?)?.toInt() ?? 0,
        finishedAtMs: (decoded['finishedAtMs'] as num?)?.toInt(),
        request: request,
        stage: decoded['stage'] as String?,
        outcomeKind: kind,
        fileName: decoded['fileName'] as String?,
        savedPath: decoded['savedPath'] as String?,
        downloadsSaved: decoded['downloadsSaved'] as bool?,
        isRawFallback: decoded['isRawFallback'] as bool?,
        message: decoded['message'] as String?,
        aiFailureReason: decoded['aiFailureReason'] as String?,
        failureClassName: decoded['failureClassName'] as String?,
        failureKindName: decoded['failureKindName'] as String?,
        failureStageName: decoded['failureStageName'] as String?,
        // VC 100131 additive fields, tolerant exactly like the
        // VC 100130 pair: absent/wrong-typed reads degrade to
        // null / false (a pre-Round-3 record simply has no wire
        // identity and no tombstone).
        reportGenerationId: decoded['reportGenerationId'] is String &&
                (decoded['reportGenerationId'] as String).isNotEmpty
            ? decoded['reportGenerationId'] as String
            : null,
        generationInvalidated: decoded['generationInvalidated'] == true,
        heldCompletedAtMs: (decoded['heldCompletedAtMs'] as num?)?.toInt(),
        allowRawFallback: decoded['allowRawFallback'] as bool?,
        attempts: attempts,
      );
    } catch (_) {
      return null;
    }
  }
}

// ── Store ────────────────────────────────────────────────────────

class ReportGenerationJournal {
  static const journalKey = 'report_generation_journal_v1';

  /// Hygiene bound: attempt records are capped so the blob
  /// stays a few KB even across decision retries (a decision
  /// retry extends the same history; the cap keeps the most
  /// recent records, preserving order).
  static const maxJournaledAttempts = 32;

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Future<void> Function(String key) _delete;

  ReportGenerationJournal()
      : _read = ((key) => const FlutterSecureStorage().read(key: key)),
        _write = ((key, value) =>
            const FlutterSecureStorage().write(key: key, value: value)),
        _delete = ((key) => const FlutterSecureStorage().delete(key: key));

  ReportGenerationJournal.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) delete,
  }) : this._(read, write, delete);

  ReportGenerationJournal._(this._read, this._write, this._delete);

  /// In-memory-store factory for tests (one shared map = one
  /// "device"; a fresh service over the same map simulates a
  /// relaunch).
  factory ReportGenerationJournal.inMemory(Map<String, String> mem) =>
      ReportGenerationJournal.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );

  Future<void> write(ReportJournalEntry entry) async {
    final bounded = entry.attempts.length <= maxJournaledAttempts
        ? entry
        : entry.copyWith(attempts: entry.attempts
            .sublist(entry.attempts.length - maxJournaledAttempts));
    try {
      await _write(journalKey, jsonEncode(bounded.toJson()));
    } catch (_) {
      // Journaling is best-effort: a storage failure must never
      // break the generation itself (the in-memory outcome is
      // still held and presented exactly as before).
    }
  }

  Future<ReportJournalEntry?> read() async {
    try {
      return ReportJournalEntry.fromJsonString(await _read(journalKey));
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      await _delete(journalKey);
    } catch (_) {}
  }

  @visibleForTesting
  static String encode(ReportJournalEntry e) => jsonEncode(e.toJson());
}
