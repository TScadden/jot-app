/// Workout sync from Health Connect (Nov 27, 2026) — turns HC
/// exercise sessions into ordinary Tabs log entries (DESIGN
/// §1.3/§3/§4, DECISIONS decisions 1–10).
///
/// Pipeline per run: badges-mirrored tri-state permission gate →
/// 400-day rich read → per session, oldest first: skip when any
/// link exists → link (don't create) on a manual-overlap match →
/// otherwise create the entry through the SAME outbox
/// allocate/stage/flush path as a manual save, then record the
/// link. Sync is CREATE-ONLY: it never modifies a linked entry,
/// and a deleted synced entry stays deleted (the store's
/// tombstone is consulted before every creation — there is no
/// server tombstone, DESIGN §1.2).
///
/// Fail-closed throughout: any gate failure, read failure, or
/// pull failure means zero creations and zero stamps — the run
/// simply didn't happen and the next capture retries. INSIDE the
/// per-session loop the unit of failure is the SESSION (ROUND 3,
/// FM-1/FM-2): one poison session is skipped and counted, never
/// allowed to abort the run — it holds no link, so the next run
/// retries it. Every exit path (except the owner-unverified
/// early return, which must not write) records a
/// [WorkoutSyncRunRecord] — stage reached, gate verdict, counts,
/// abort code — so a silent abort is diagnosable on-device.
/// Triggered fire-and-forget from the capture tail
/// ([HealthHistorySync] beside DailyBiometricsSync); single-
/// flight like [DailyBiometricsSync.syncAfterCapture].
///
/// STREAK BOUNDARY (JUNO-GATE §3, SIGNED): a synced workout does
/// NOT complete a day and does NOT move the streak — Daily
/// Summary completion governs, and log-entry counts are not an
/// input to it (DESIGN §6). No copy in this feature may imply
/// otherwise.
library;

import 'dart:async';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/workout_sync_store.dart';
import 'package:tabs_lab/src/features/tools/body_workout.dart';

/// The optional, badges-scoped exercise permission (Juno
/// B-ruling, Nov 20, 2026): declared in the manifest, granted by
/// the user in Health Connect settings, NEVER in
/// [HealthConnectService.requiredPermissions] and never requested
/// by this feature — the gate below only READS the live granted
/// set, exactly like `loadBadgeInputs` in badge_store.dart.
const String kReadExercisePermission =
    'android.permission.health.READ_EXERCISE';

/// The plain chips form every synced entry writes (DESIGN §2.2 /
/// §1.5 R1): the existing Workout chip plus the synced marker.
const String kSyncedWorkoutChips = '$kWorkoutChip, $kSyncedWorkoutChip';

/// Grace on both sides of the manual-overlap window (DESIGN §4):
/// a manual Workout entry whose timestamp lies inside
/// `[startMs − 10min, endMs + 10min]` is the same workout.
const int kWorkoutOverlapGraceMs = 10 * 60 * 1000;

/// The metrics line a synced entry carries in `manualText`
/// (DECISIONS decision 6, JUNO-STRINGS.md §1.3 — formats ruled):
/// parts joined by ' · ' in the fixed order TITLE, CALORIES,
/// HEART RATE; absent parts omitted entirely; '' when nothing is
/// present. Calories: active wins as a bare `{n} kcal`; a
/// total-only figure is labelled `Total {n} kcal (incl. rest)` —
/// never a bare "burned" claim on a total (NATIVE.md §3). A 0
/// from any aggregate is missing data (the parse in
/// [WorkoutSession.tryParse] already nulled it; the guards here
/// keep directly-constructed sessions honest too).
String workoutMetricsLine(WorkoutSession session) {
  final parts = <String>[];
  final title = session.title?.trim() ?? '';
  if (title.isNotEmpty) parts.add(title);
  final kcalActive = session.kcalActive;
  final kcalTotal = session.kcalTotal;
  if (kcalActive != null && kcalActive > 0) {
    parts.add('$kcalActive kcal');
  } else if (kcalTotal != null && kcalTotal > 0) {
    parts.add('Total $kcalTotal kcal (incl. rest)');
  }
  final hrAvg = session.hrAvg;
  final hrMax = session.hrMax;
  if (hrAvg != null && hrAvg > 0) parts.add('avg HR $hrAvg');
  if (hrMax != null && hrMax > 0) parts.add('max HR $hrMax');
  return parts.join(' · ');
}

/// Builds the log entry for one session (DESIGN §2.2 as amended
/// by DECISIONS decision 6): body is the type label + WALL-CLOCK
/// duration (decision 5 — never labelled "active"), timestamp is
/// the session start, metrics ride in `manualText` (History cards
/// never render it; the detail dialog shows it as a second
/// paragraph — exactly where HR/calories belong).
QuickLogEntry buildSyncedWorkoutEntry({
  required WorkoutSession session,
  required int id,
  required int categoryId,
}) {
  return QuickLogEntry(
    id: id,
    categoryId: categoryId,
    body: '${session.typeLabel} · ${session.durationMinutes} min',
    chips: kSyncedWorkoutChips,
    manualText: workoutMetricsLine(session),
    timestamp: session.startMs,
  );
}

class WorkoutSyncService {
  static final WorkoutSyncService instance = WorkoutSyncService._production();

  factory WorkoutSyncService._production() {
    final hc = HealthConnectService();
    final backend = TabsBackend();
    final outbox = LogEntryOutbox.instance;
    return WorkoutSyncService.withDeps(
      store: WorkoutSyncStore.instance,
      outbox: outbox,
      probe: hc.probeAvailability,
      grantedPermissions: hc.getGrantedPermissions,
      readRich: hc.readExerciseSessionsRich,
      fetchEntries: backend.fetchLogEntryDtos,
      fetchCategories: backend.fetchLogCategoriesOrNull,
      allocateId: (serverMaxId) => outbox.allocateEntryIdForBackend(
          backend: backend, serverMaxId: serverMaxId),
      stageEntry: (entry) => outbox.stageForBackend(entry,
          backend: backend, serverKnown: false),
      flushOutbox: () async {
        await outbox.flush(backend);
      },
    );
  }

  /// Injectable for tests (the [DailyBiometricsSync.withDeps]
  /// pattern): every outside touch is a function; [store] and
  /// [outbox] are the real objects over whatever disk their own
  /// `debugSetStore` seams were given.
  WorkoutSyncService.withDeps({
    required this.store,
    required this.outbox,
    required this._probe,
    required this._grantedPermissions,
    required this._readRich,
    required this._fetchEntries,
    required this._fetchCategories,
    required this._allocateId,
    required this._stageEntry,
    required this._flushOutbox,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final WorkoutSyncStore store;
  final LogEntryOutbox outbox;
  final Future<HcAvailability> Function() _probe;
  final Future<Set<String>> Function() _grantedPermissions;
  final Future<HcReadOutcome<List<WorkoutSession>>> Function(int days)
      _readRich;
  final Future<List<QuickLogEntry>> Function() _fetchEntries;
  final Future<List<QuickLogCategory>?> Function() _fetchCategories;
  final Future<int> Function(int serverMaxId) _allocateId;
  final Future<bool> Function(QuickLogEntry entry) _stageEntry;
  final Future<void> Function() _flushOutbox;
  final int Function() _nowMs;

  /// The read window: always the native cap, the exact depth
  /// badges already use (DESIGN §3.4). Sessions are sparse and
  /// dedup is by session key, so a max window makes backfill,
  /// gap recovery, and re-installs the same code path.
  static const int readWindowDays = 400;

  Future<bool>? _inFlight;

  /// One sync run. Concurrent calls join the in-flight run.
  /// Returns true when the run completed (gate passed, read
  /// succeeded, loop reached its end — including zero sessions
  /// and runs where individual sessions were skipped); false
  /// when it aborted fail-closed before the loop. Never throws.
  Future<bool> syncAfterCapture() {
    final existing = _inFlight;
    if (existing != null) return existing;
    late final Future<bool> future;
    future = _run().whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  Future<bool> _run() async {
    // ── Run-record state (ROUND 3) ─────────────────────────────
    // Tracked as the run advances; EVERY exit path below records
    // it via [finish] — except the owner-unverified early return,
    // which records nothing (a persist there would re-stamp an
    // unowned blob). Counts and codes only.
    final startedAtMs = _nowMs();
    var stage = 'warm';
    var grantVerdict = 'notChecked';
    int? sessionsRead;
    var entriesCreated = 0;
    var entriesAdopted = 0;
    var sessionsSkipped = 0;
    var readPartial = false;
    String? abortCode;

    Future<bool> finish(bool result) async {
      // Recording must never throw into the run (the store's
      // persist already never throws; this is belt and braces).
      try {
        await store.recordRun(WorkoutSyncRunRecord(
          startedAtMs: startedAtMs,
          finishedAtMs: _nowMs(),
          stage: stage,
          grantVerdict: grantVerdict,
          sessionsRead: sessionsRead,
          entriesCreated: entriesCreated,
          entriesAdopted: entriesAdopted,
          sessionsSkipped: sessionsSkipped,
          readPartial: readPartial,
          abortCode: abortCode,
        ));
      } catch (_) {}
      return result;
    }

    try {
      // The store must be loaded before any decision reads it;
      // the warm is owner-bound wherever main.dart / the
      // background runner already performed it — this unbound
      // warm only loads the blob as-is.
      await store.warmFromDisk();
      // Owner-unverified state is read-only (H1-04): never write
      // links derived from data we cannot prove is this
      // account's — and never write the run record either.
      if (store.warmLoadedUnownedData) return false;

      // ── Probe ────────────────────────────────────────────────
      stage = 'probe';
      final probe = await _probe();
      if (!probe.serviceAvailable) return await finish(false);
      if (!probe.grantKnown) {
        grantVerdict = 'unknown';
        return await finish(false);
      }

      // ── Gate (badges pattern verbatim, DESIGN §3.2) ──────────
      stage = 'gate';
      bool? exerciseGranted;
      try {
        exerciseGranted =
            (await _grantedPermissions()).contains(kReadExercisePermission);
      } catch (_) {
        exerciseGranted = null;
      }
      // true → read. false → VERIFIED denial: create nothing.
      // null → unknown: no read, no "blocked" claim, retry next
      // capture (§9 rule 1 — unknown is not denied).
      if (exerciseGranted == null) {
        grantVerdict = 'unknown';
        return await finish(false);
      }
      if (exerciseGranted != true) {
        grantVerdict = 'denied';
        return await finish(false);
      }
      grantVerdict = 'granted';

      // ── Rich read ────────────────────────────────────────────
      stage = 'read';
      final HcReadOutcome<List<WorkoutSession>> outcome;
      try {
        outcome = await _readRich(readWindowDays);
      } catch (e) {
        // The read contract is total after ROUND 3 Build 3, but
        // any throw that still escapes becomes a failed read
        // here — never a silent whole-run abort.
        abortCode = e.runtimeType.toString();
        return await finish(false);
      }
      if (outcome.failed) {
        // Abort; stamp nothing (FM-5: fail-closed by design —
        // the record names the stage + the bridge errorCode).
        abortCode = outcome.errorCode ?? 'READ_FAILED';
        return await finish(false);
      }
      final sessions = outcome.value.toList()
        ..sort((a, b) => a.startMs.compareTo(b.startMs));
      sessionsRead = sessions.length;
      readPartial = outcome.partial;

      // ── Pull + categories ────────────────────────────────────
      // A failed pull aborts before creation (DESIGN §5): no
      // categories = no honest filing, and the merge candidates
      // would be fiction. Next capture retries.
      stage = 'pull';
      final categories = await _fetchCategories();
      if (categories == null) {
        abortCode = 'CATEGORIES_UNAVAILABLE';
        return await finish(false);
      }
      final pulled = await _fetchEntries();
      final merged = outbox.merge(pulled);
      final categoryId = workoutCategoryId(categories);
      var serverMaxId = 0;
      for (final e in pulled) {
        if (e.id > serverMaxId) serverMaxId = e.id;
      }

      // ── Per session, oldest first (DESIGN §4) ────────────────
      // PER-SESSION ISOLATION (ROUND 3, FM-1/FM-2): each
      // session's processing runs in its own try/catch. A throw
      // (e.g. the outbox's by-design StateError from
      // allocateEntryId before its disk load settles) skips ONLY
      // that session — counted, first skip's code kept — and the
      // run continues. No link is written for a skipped session,
      // so the next run retries it.
      stage = 'loop';
      var createdAny = false;
      for (final session in sessions) {
        final key = session.dedupKey;
        try {
          // 1. Any link state → skip. This alone makes re-syncs,
          //    400-day windows, and re-installs idempotent, and
          //    makes deletes permanent. NOT a failure skip — the
          //    normal idempotent path; never counted as skipped.
          if (store.linkForKey(key) != null) continue;

          // 2. Manual-overlap match → link, don't create.
          final match = _overlapMatch(session, merged);
          if (match != null) {
            await store.recordLink(
              key: key,
              entryId: match.id,
              state: WorkoutLinkState.adopted,
              origin: isSyncedWorkoutEntry(match)
                  ? WorkoutLinkOrigin.synced
                  : WorkoutLinkOrigin.manual,
              hcId: session.hcId.isEmpty ? null : session.hcId,
            );
            entriesAdopted++;
            continue;
          }

          // 3. Create through the manual path (DESIGN §1.3):
          //    allocate → stage durably → link → one flush per
          //    run. Stage-then-link is deliberate: if the link
          //    write fails, the next run's overlap rule adopts
          //    the unlinked entry instead of duplicating it.
          final id = await _allocateId(serverMaxId);
          if (id > serverMaxId) serverMaxId = id;
          final entry = buildSyncedWorkoutEntry(
            session: session,
            id: id,
            categoryId: categoryId,
          );
          final staged = await _stageEntry(entry);
          if (!staged) {
            // FM-6: a quiet false is retry-correct (no link
            // written) but is now a counted skip with a reason.
            sessionsSkipped++;
            abortCode ??= 'STAGE_FAILED';
            continue;
          }
          await store.recordLink(
            key: key,
            entryId: id,
            state: WorkoutLinkState.linked,
            origin: WorkoutLinkOrigin.synced,
            hcId: session.hcId.isEmpty ? null : session.hcId,
          );
          entriesCreated++;
          createdAny = true;
        } catch (e) {
          sessionsSkipped++;
          abortCode ??= e.runtimeType.toString();
          continue;
        }
      }
      if (createdAny) {
        // Exactly like a manual save (Quick Log's
        // _applyLocalEntry): fire-and-forget; failures stay
        // queued as failed and retry on the next trigger.
        unawaited(_flushOutbox());
      }
      // The loop reaching its end = the run completed: stamp the
      // sync (DESIGN §3.3 — lastSyncMs is informational only) and
      // report success EVEN when some sessions were skipped; the
      // record carries the counts + the first skip's code, and
      // skipped sessions retry next capture (they hold no link).
      // A successful read — even a genuinely empty one — stamps;
      // a partial enrichment stamps too: the read happened; its
      // missing fields stay missing.
      stage = 'done';
      await store.markSynced(_nowMs());
      return await finish(true);
    } catch (e) {
      // Sync must never break a capture. Fail-closed: whatever
      // was staged/linked before the failure is durable and
      // consistent (stage-then-link), and the next run resumes.
      // The record names the stage reached + the exception type.
      abortCode ??= e.runtimeType.toString();
      return await finish(false);
    }
  }

  /// The §4 overlap candidate for [session] among [merged]
  /// entries, or null: an entry that (a) is a workout (the
  /// Workout chip, or the synced marker for the self-healing
  /// sub-case), (b) is not already linked to another session,
  /// and (c) whose point timestamp lies inside the session
  /// window expanded by the grace on both sides. Synced-marked
  /// unlinked candidates (a prior run staged one, then died
  /// before the link write) win over manual ones; within a class
  /// the nearest timestamp to the session start wins.
  QuickLogEntry? _overlapMatch(
    WorkoutSession session,
    List<QuickLogEntry> merged,
  ) {
    final windowStart = session.startMs - kWorkoutOverlapGraceMs;
    final windowEnd = session.endMs + kWorkoutOverlapGraceMs;
    QuickLogEntry? bestManual;
    QuickLogEntry? bestSynced;
    var bestManualDist = 1 << 62;
    var bestSyncedDist = 1 << 62;
    for (final entry in merged) {
      if (entry.timestamp < windowStart || entry.timestamp > windowEnd) {
        continue;
      }
      if (store.linkForEntry(entry.id) != null) continue;
      final dist = (entry.timestamp - session.startMs).abs();
      if (isSyncedWorkoutEntry(entry)) {
        if (dist < bestSyncedDist) {
          bestSynced = entry;
          bestSyncedDist = dist;
        }
      } else if (isWorkoutEntry(entry)) {
        if (dist < bestManualDist) {
          bestManual = entry;
          bestManualDist = dist;
        }
      }
    }
    return bestSynced ?? bestManual;
  }
}
