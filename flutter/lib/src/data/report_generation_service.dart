import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'progress_report.dart';
import 'report_generation_journal.dart';
import 'report_ready_notification.dart';

/// One generation run, handed to [ReportGenerationService.start]:
/// the caller (the Progress Reports page) builds its pipeline and
/// passes a closure that invokes it with the SERVICE's stage and
/// cancellation channels, so the run's control surface outlives
/// the caller's widget.
typedef ReportGenerationRun = Future<ReportOutcome> Function({
  required void Function(ReportStage stage) onStage,
  required bool Function() isCancelled,
});

/// A completion presenter: a mounted widget (the Progress Reports
/// page, or the app-root presenter) that can put the share
/// confirmation on screen RIGHT NOW via its own context. The
/// service invokes at most one per presentation request; the
/// share-flow claim guard is the second lock.
typedef ReportCompletionPresenter = void Function();

/// App-level owner of a Progress Reports generation (founder bug,
/// Nov 9, 2026).
///
/// Before this service, the run lived in the Progress Reports
/// page's State: `_stage`, `_cancelRequested` and `_pendingShare`
/// were page fields, and leaving the page in-app disposed that
/// State — the Settings body swap removes the page from the tree
/// and the shell drops the outgoing tab — so a returning user
/// found no spinner, no stage, and no outcome; a completion that
/// landed while the page was disposed was dropped in silence (a
/// ready outcome posted a system notification even while the user
/// was inside the app on another screen, and failures vanished
/// entirely). This service owns the run instead:
///
/// - [start] runs the pipeline to completion independent of any
///   widget's lifecycle; [stage] / [isCancelled] are service
///   state, so a re-mounted page renders the LIVE run and its
///   Cancel button drives the same flag the pipeline reads
///   (PR #55's stage-boundary cancellation, unchanged).
/// - A completed outcome is HELD here ([pendingShare] /
///   [pendingFailure]) until it has been seen — never dropped.
/// - Presentation is routed to whoever can show it: the page
///   presenter when the page is mounted (the watched case,
///   behaving exactly as before), otherwise the app-root
///   presenter, which shows the share confirmation on whatever
///   in-app screen is current. A completion while the app is
///   backgrounded keeps PR #55's behavior: the report-ready
///   notification posts (id 7304, Juno's ruled strings) and the
///   share confirmation is held for resume / notification tap.
///
/// VC 100129 (R-2 Tier 1 + R-1): the service also owns the
/// generation JOURNAL ([ReportGenerationJournal]) — one record,
/// written at start, at every stage change, when the PDF save
/// lands, and at finish — and restores it on construction, so a
/// generation survives process death truthfully: a finished
/// report is re-offered from its exact saved artifact, a failure
/// or decision is re-presented with its recorded facts, and a
/// generation that died mid-run restores as an interrupted state
/// the page auto-retries once (see [interruptedEntry]).
///
/// The service knows nothing about report CONTENT beyond the
/// journal's outcome metadata: pipelines are built by the page
/// and injected as a [ReportGenerationRun].
class ReportGenerationService extends ChangeNotifier {
  ReportGenerationService({
    this.notifier,
    ReportGenerationJournal? journal,
    DateTime Function()? clock,
    Future<bool> Function(String path)? artifactExists,
    Future<List<int>> Function(String path)? artifactReader,
  })  : _journal = journal ?? ReportGenerationJournal(),
        _clock = clock ?? DateTime.now,
        _artifactExists =
            artifactExists ?? ((p) => File(p).exists()),
        _artifactReader =
            artifactReader ?? ((p) => File(p).readAsBytes()) {
    _restoreFuture = _restore();
  }

  /// The app-lifetime instance: provided to the Progress Reports
  /// page by Settings and to the root presenter by the app root,
  /// so both see the same run.
  static final ReportGenerationService instance =
      ReportGenerationService();

  /// The report-ready notifier (test seam): production leaves
  /// this null and the service lazily builds its
  /// [LocalReportReadyNotifier] with the service's own tap
  /// handler.
  ReportReadyNotifier? notifier;

  final ReportGenerationJournal _journal;
  final DateTime Function() _clock;
  final Future<bool> Function(String path) _artifactExists;
  final Future<List<int>> Function(String path) _artifactReader;

  ReportStage? _stage;
  bool _cancelRequested = false;
  ReportReady? _pendingShare;
  ReportFailed? _pendingFailure;
  bool _shareDialogVisible = false;

  /// A ready outcome completed while the app was backgrounded:
  /// its confirmation is held for the moment the user returns
  /// (resume or notification tap). PR #55 semantics, lifted.
  bool _shareRevealPending = false;

  /// A failure completed while the app was backgrounded (or with
  /// nobody able to surface it): held for the next foreground
  /// opportunity instead of dropped. Failures never notify
  /// (PR #55 rule).
  bool _failureRevealPending = false;

  int _lastExportMs = 0;

  ReportCompletionPresenter? _pagePresenter;
  ReportCompletionPresenter? _rootPresenter;
  ReportCompletionPresenter? _rootFailurePresenter;

  // ── VC 100129 journal / restore state ────────────────────────

  /// The in-memory mirror of the journaled record for the
  /// current (or most recent) generation.
  ReportJournalEntry? _currentEntry;

  Future<void>? _restoreFuture;

  /// Bumped by every [start]: a restore that read the journal
  /// before a newer generation began must not apply over it.
  int _stateEpoch = 0;
  int _generationSeq = 0;

  /// True when the held outcome was restored from the journal
  /// after a relaunch (its framing line applies — R5-4).
  bool _outcomeRestored = false;

  /// A journal entry whose generation died mid-run (a
  /// non-terminal stage at relaunch), or whose ready artifact
  /// was missing at restore (R5-11 fallback). The page renders
  /// the interrupted surface / auto-retries from this entry's
  /// persisted request identity.
  ReportJournalEntry? _interruptedEntry;

  /// A decision restored after relaunch. Case 2 governs
  /// (rulings-5 R5-5): no snapshot survives death, so this is
  /// journal facts only — never a [ReportAiDecision] with a
  /// resume closure.
  ReportJournalEntry? _restoredDecisionEntry;

  /// True while an auto re-run of an interrupted generation
  /// (started by the page on restore) is in flight — the page
  /// shows Juno's "Starting your report again" framing above
  /// the stage labels only in this state (R5-9).
  bool _autoRunInFlight = false;
  bool _autoRestoreAttempted = false;

  /// When the currently held decision was recorded (same-session
  /// F5 freshness), and whether it has since been re-encountered
  /// (resume / page re-registration) — i.e. it is being rendered
  /// LATER than the moment it was produced.
  DateTime? _heldDecisionAt;
  bool _heldDecisionIsEarlier = false;

  // ── Public state (the page is a view of this) ─────────────────

  ReportStage? get stage => _stage;
  bool get isGenerating => _stage != null;
  bool get isCancelled => _cancelRequested;
  ReportReady? get pendingShare => _pendingShare;
  ReportFailed? get pendingFailure => _pendingFailure;
  bool get shareDialogVisible => _shareDialogVisible;
  bool get shareRevealPending => _shareRevealPending;
  int get lastExportMs => _lastExportMs;

  /// The journal record for the current/most recent generation
  /// (the F1 details surface reads attempt history from here).
  ReportJournalEntry? get journalEntry => _currentEntry;

  ReportJournalEntry? get interruptedEntry => _interruptedEntry;
  ReportJournalEntry? get restoredDecisionEntry => _restoredDecisionEntry;
  bool get outcomeRestored => _outcomeRestored;
  bool get autoRunInFlight => _autoRunInFlight;

  /// Completes when the construction-time journal restore has
  /// settled (applied or found nothing). Tests await this to
  /// simulate a relaunch deterministically.
  Future<void> get restoreSettled => _restoreFuture ?? Future.value();

  /// The R5-4/R5-8 framing line for the currently held failure
  /// or decision, or null when no framing applies: a restored
  /// outcome always carries it (journal finish time); a
  /// same-session held decision carries it once it is being
  /// rendered later than it was produced (F5). A fresh outcome
  /// from the generation the user just ran carries none.
  String? get heldFramingLine {
    final entry = _currentEntry;
    if (_outcomeRestored && entry?.finishedAt != null) {
      return earlierAttemptFraming(entry!.finishedAt!, now: _clock());
    }
    if (_pendingFailure is ReportAiDecision &&
        _heldDecisionIsEarlier &&
        _heldDecisionAt != null) {
      return earlierAttemptFraming(_heldDecisionAt!, now: _clock());
    }
    return null;
  }

  /// Framing line for the restored-decision (Case 2) surface.
  String? get restoredDecisionFraming {
    final e = _restoredDecisionEntry;
    if (e?.finishedAt == null) return null;
    return earlierAttemptFraming(e!.finishedAt!, now: _clock());
  }

  /// The F1 details lines (R5-7 format) for the held outcome,
  /// read FROM THE JOURNAL when a journal record exists.
  List<String> get displayAttemptLines {
    final attempts = _currentEntry?.attempts ??
        _pendingFailure?.aiAttempts ??
        _pendingShare?.aiAttempts ??
        const <AiAttemptRecord>[];
    return [
      for (final a in attempts)
        if (attemptDetailLine(a) != null) attemptDetailLine(a)!,
    ];
  }

  /// The user is looking at the app right now (foreground). The
  /// PR #55 page rule, lifted verbatim: a null lifecycle state
  /// counts as present.
  bool get userIsPresent {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == null || s == AppLifecycleState.resumed;
    } catch (_) {
      return true;
    }
  }

  /// Test-seam binding (the page forwards its injected
  /// `reportReadyNotifier` here when a caller supplies both a
  /// service and a notifier).
  void useNotifier(ReportReadyNotifier n) {
    notifier = n;
  }

  ReportReadyNotifier get _effectiveNotifier =>
      notifier ??=
          LocalReportReadyNotifier(onTap: handleNotificationTap);

  // ── Journal writes ────────────────────────────────────────────

  void _journalWrite(ReportJournalEntry entry) {
    _currentEntry = entry;
    unawaited(_journal.write(entry));
  }

  /// The pipelines' save-step hook (T1-2): the exact artifact
  /// reference, recorded the moment the PDF save lands — before
  /// the outcome exists — so a death in the post-save window
  /// restores the finished report instead of orphaning it.
  void noteArtifactSaved(String fileName, String savedPath) {
    final entry = _currentEntry;
    if (entry == null || entry.isTerminal) return;
    _journalWrite(entry.copyWith(
      updatedAtMs: _clock().millisecondsSinceEpoch,
      fileName: fileName,
      savedPath: savedPath,
    ));
  }

  // ── Restore on relaunch ───────────────────────────────────────

  Future<void> _restore() async {
    final epoch = _stateEpoch;
    final entry = await _journal.read();
    if (entry == null) return;
    // A newer generation (or any held outcome) supersedes the
    // journal record this restore read.
    if (epoch != _stateEpoch ||
        _stage != null ||
        _pendingShare != null ||
        _pendingFailure != null ||
        _currentEntry != null) {
      return;
    }
    _currentEntry = entry;
    switch (entry.outcomeKind) {
      case JournalOutcomeKind.ready:
        await _restoreReady(entry, epoch);
      case JournalOutcomeKind.failed:
        _pendingFailure = ReportFailed(
          entry.message ?? reportExportFailureMessage,
          allowRawFallback: entry.allowRawFallback ?? false,
          aiAttempts: entry.attempts,
          aiFailureReason: entry.aiFailureReason,
        );
        _outcomeRestored = true;
        notifyListeners();
      case JournalOutcomeKind.decision:
        // Case 2 (R5-5): journal facts only — no snapshot, no
        // resume closure. The page renders the Case 2 surface.
        _restoredDecisionEntry = entry;
        notifyListeners();
      case JournalOutcomeKind.running:
        if (entry.savedPath != null && entry.savedPath!.isNotEmpty) {
          // Orphan adoption: the generation died in the
          // post-save window — the render and save completed
          // (the artifact is on disk and journaled) and only
          // the outcome construction remained. The finished
          // report is restored from the artifact; a missing
          // artifact degrades to interrupted inside
          // _restoreReady (R5-11).
          await _restoreReady(entry, epoch);
        } else {
          // A non-terminal stage at relaunch IS the interrupted
          // state — derived, never guessed (T1-3).
          _interruptedEntry = entry;
          notifyListeners();
        }
    }
  }

  Future<void> _restoreReady(ReportJournalEntry entry, int epoch) async {
    final path = entry.savedPath;
    var restored = false;
    if (path != null && path.isNotEmpty) {
      try {
        if (await _artifactExists(path)) {
          final bytes = await _artifactReader(path);
          if (epoch == _stateEpoch && _pendingShare == null) {
            _pendingShare = ReportReady(
              snapshot: ReportSnapshot(
                last30Days: entry.request.last30Days,
                generationTimestampMs: entry.startedAtMs,
                logEntries: const [],
                categoriesMap: {
                  for (final id in entry.request.categoryIds) id: '',
                },
              ),
              pdfBytes: bytes,
              fileName: entry.fileName ?? '',
              savedPath: path,
              isRawFallback: entry.isRawFallback ?? false,
              aiAttempts: entry.attempts,
              downloadsSaved: entry.downloadsSaved,
            );
            _outcomeRestored = true;
            // Re-present through the existing reveal machinery:
            // the next presenter registration / resume offers
            // the share confirmation for the restored artifact.
            _shareRevealPending = true;
            restored = true;
            notifyListeners();
          }
        }
      } catch (_) {
        restored = false;
      }
    }
    if (!restored) {
      // R5-11 binding condition: never present "ready" for a
      // missing artifact — the truth is the interrupted state.
      _pendingShare = null;
      _outcomeRestored = false;
      _interruptedEntry = entry;
      notifyListeners();
    }
  }

  /// Auto re-run of an interrupted generation (R5-9): a FRESH
  /// generation from the persisted request identity, framed as
  /// "Starting your report again" while in flight. Returns false
  /// (and leaves the interrupted entry in place for the R5-1–R5-3
  /// surface) when the auto-start cannot proceed — a run is
  /// already in flight, or there is nothing interrupted.
  /// [run] must be the page-built run for [entry]'s identity.
  Future<bool> autoRestoreInterrupted(ReportGenerationRun run) async {
    final entry = _interruptedEntry;
    if (entry == null || _stage != null || _autoRestoreAttempted) {
      return false;
    }
    _autoRestoreAttempted = true;
    _autoRunInFlight = true;
    _interruptedEntry = null;
    notifyListeners();
    try {
      await start(run, request: entry.request);
    } finally {
      _autoRunInFlight = false;
      notifyListeners();
    }
    return true;
  }

  /// Marks that an auto-restore was already attempted in a prior
  /// page mount of this process, so re-mounting the page does
  /// not loop the auto re-run (R5-9 truth conditions).
  bool get autoRestoreAttempted => _autoRestoreAttempted;

  /// A manual retry from the interrupted surface ("Try again",
  /// R5-3): a fresh generation from the persisted identity,
  /// WITHOUT the auto re-run framing (the user tapped it).
  Future<void> retryInterrupted(ReportGenerationRun run) async {
    final entry = _interruptedEntry;
    if (entry == null) return;
    _interruptedEntry = null;
    await start(run, request: entry.request);
  }

  /// Dismisses a restored decision (Case 2) once the user has
  /// acted on it (its "Start a new report" action starts a fresh
  /// generation through the page, which supersedes the journal;
  /// this clears the restored surface state).
  void clearRestoredDecision() {
    if (_restoredDecisionEntry == null) return;
    _restoredDecisionEntry = null;
    notifyListeners();
  }

  // ── Presenter registration ────────────────────────────────────

  /// The Progress Reports page registers while mounted: it is the
  /// preferred presenter (the watched case presents exactly as
  /// before, from the page's own context).
  void registerPagePresenter(ReportCompletionPresenter presenter) {
    _pagePresenter = presenter;
    // Returning to the page with a held share is a reveal
    // opportunity (PR #55's resume semantics, generalized): if a
    // backgrounded completion is waiting, present it now.
    if (_shareRevealPending && _pendingShare != null && userIsPresent) {
      _shareRevealPending = false;
      presenter();
    }
    // F5: a decision already held when a page (re)registers is
    // being rendered later than it was produced.
    if (_pendingFailure is ReportAiDecision) _heldDecisionIsEarlier = true;
  }

  void unregisterPagePresenter(ReportCompletionPresenter presenter) {
    if (_pagePresenter == presenter) _pagePresenter = null;
  }

  /// The app-root presenter registers for the app's lifetime: it
  /// presents completions on whatever in-app screen is current
  /// when the page is not mounted, and surfaces held failures by
  /// snackbar when the page is not there to show them inline.
  void registerRootPresenter(
    ReportCompletionPresenter sharePresenter, {
    ReportCompletionPresenter? failurePresenter,
  }) {
    _rootPresenter = sharePresenter;
    _rootFailurePresenter = failurePresenter;
    // A presenter arriving after a completion (e.g. cold start
    // under a held outcome) is itself a reveal opportunity.
    handleResumed();
  }

  void unregisterRootPresenter(ReportCompletionPresenter presenter) {
    if (_rootPresenter == presenter) _rootPresenter = null;
    if (_rootFailurePresenter == presenter) {
      _rootFailurePresenter = null;
    }
  }

  // ── Run control ───────────────────────────────────────────────

  /// Starts a run. A second start while one is in flight is a
  /// no-op (the page's old `_stage != null` guard, lifted).
  /// [request] is the generation's identity for the journal;
  /// callers that do not supply one journal under a default
  /// standard identity (the journal still records stage and
  /// outcome truthfully).
  Future<void> start(
    ReportGenerationRun run, {
    ReportRequestIdentity? request,
  }) async {
    if (_stage != null) return;
    _stateEpoch++;
    _cancelRequested = false;
    _pendingFailure = null;
    _failureRevealPending = false;
    _outcomeRestored = false;
    _restoredDecisionEntry = null;
    _heldDecisionAt = null;
    _heldDecisionIsEarlier = false;
    _stage = ReportStage.collecting;
    final now = _clock();
    _journalWrite(ReportJournalEntry(
      generationId: '${now.millisecondsSinceEpoch}-${++_generationSeq}',
      startedAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
      request: request ??
          const ReportRequestIdentity(
            kind: 'standard',
            focusKey: 'health',
            last30Days: true,
            categoryIds: [],
          ),
      stage: ReportStage.collecting.name,
      outcomeKind: JournalOutcomeKind.running,
    ));
    notifyListeners();
    ReportOutcome outcome;
    try {
      outcome = await run(
        onStage: _setStage,
        isCancelled: () => _cancelRequested,
      );
    } catch (_) {
      // Both pipelines map their own failures to ReportFailed;
      // an escape from the injected run itself is surfaced with
      // the pipeline's existing export-failure copy rather than
      // dropped (no new strings).
      outcome = const ReportFailed(reportExportFailureMessage,
          allowRawFallback: true);
    }
    _finish(outcome);
  }

  /// Drives a held AI-failure decision (Phase 3): the pending
  /// failure is a [ReportAiDecision] whose pipeline-built
  /// continuation either retries ONLY the AI analysis on the
  /// already-collected data ([retryAi] true) or makes the
  /// data-only report as the user's explicit choice. The resumed
  /// run goes through [start], so it keeps every lifecycle
  /// guarantee (single run at a time, stage/cancel state, outcome
  /// held until seen, failures never notify). A no-op when no
  /// decision is held or a run is already in flight.
  Future<void> resumeAiDecision({required bool retryAi}) async {
    final failure = _pendingFailure;
    if (failure is! ReportAiDecision) return;
    final resume = failure.resume;
    // The resumed run continues the SAME generation's journal
    // record (its attempt history extends; start() superseding
    // with a fresh record would lose the earlier attempts the
    // F1 details surface must show). Carry the identity over.
    final prior = _currentEntry;
    await start(
      ({required onStage, required isCancelled}) => resume(
        retryAi: retryAi,
        onStage: onStage,
        isCancelled: isCancelled,
      ),
      request: prior?.request,
    );
    // Re-attach the prior generation's attempts are NOT merged
    // here: the resumed pipeline outcome already carries the
    // full continuous attempt history (Phase 3), and _finish
    // journals exactly that list.
  }

  void _setStage(ReportStage stage) {
    if (_stage == null) return; // finished; a late callback is inert
    _stage = stage;
    final entry = _currentEntry;
    if (entry != null && !entry.isTerminal) {
      _journalWrite(entry.copyWith(
        updatedAtMs: _clock().millisecondsSinceEpoch,
        stage: stage.name,
      ));
    }
    notifyListeners();
  }

  /// The working Cancel: flips the flag the pipeline's
  /// stage-boundary checks read (PR #55). The run ends as a
  /// Cancelled failure, which [_finish] drops silently — exactly
  /// the pre-service page behavior.
  void requestCancel() {
    if (_stage == null || _cancelRequested) return;
    _cancelRequested = true;
    notifyListeners();
  }

  void _finish(ReportOutcome outcome) {
    _stage = null;
    final wasCancelled = _cancelRequested;
    _cancelRequested = false;
    if (wasCancelled) {
      // Cancelled outcome (or a success that slipped past the
      // last stage-boundary check after the user cancelled):
      // dropped, as the page dropped it before — the PDF, if one
      // was saved, stays saved. No notification, no dialog. The
      // journal record is cleared with it: a cancelled generation
      // has no outcome to restore.
      _currentEntry = null;
      unawaited(_journal.clear());
      notifyListeners();
      return;
    }
    switch (outcome) {
      case ReportReady ready:
        _pendingShare = ready;
        _journalFinishReady(ready);
        notifyListeners();
        if (userIsPresent) {
          _presentShare();
        } else {
          _shareRevealPending = true;
          unawaited(_notifyReportReady());
        }
      case ReportFailed failed:
        if (failed.message == 'Cancelled') {
          _currentEntry = null;
          unawaited(_journal.clear());
          notifyListeners();
          return;
        }
        _pendingFailure = failed;
        if (failed is ReportAiDecision) {
          _heldDecisionAt = _clock();
          _journalFinishDecision(failed);
        } else {
          _journalFinishFailed(failed);
        }
        notifyListeners();
        if (!userIsPresent) {
          _failureRevealPending = true;
        } else if (_pagePresenter == null) {
          // Nobody's page is showing it inline: surface it where
          // the user is, now.
          _surfaceFailure();
        }
        // Page mounted: the page renders the failure inline from
        // [pendingFailure] (the existing page convention).
    }
  }

  void _journalFinishReady(ReportReady ready) {
    final entry = _currentEntry;
    if (entry == null) return;
    final now = _clock();
    _journalWrite(entry.copyWith(
      updatedAtMs: now.millisecondsSinceEpoch,
      finishedAtMs: now.millisecondsSinceEpoch,
      clearStage: true,
      outcomeKind: JournalOutcomeKind.ready,
      fileName: ready.fileName,
      savedPath: ready.savedPath,
      downloadsSaved: ready.downloadsSaved,
      isRawFallback: ready.isRawFallback,
      attempts: ready.aiAttempts,
    ));
  }

  void _journalFinishFailed(ReportFailed failed) {
    final entry = _currentEntry;
    if (entry == null) return;
    final now = _clock();
    _journalWrite(entry.copyWith(
      updatedAtMs: now.millisecondsSinceEpoch,
      finishedAtMs: now.millisecondsSinceEpoch,
      clearStage: true,
      outcomeKind: JournalOutcomeKind.failed,
      message: failed.message,
      aiFailureReason: failed.aiFailureReason,
      failureClassName: failed.aiAttempts.isNotEmpty
          ? failed.aiAttempts.last.failureClass?.name
          : null,
      allowRawFallback: failed.allowRawFallback,
      attempts: failed.aiAttempts,
    ));
  }

  void _journalFinishDecision(ReportAiDecision decision) {
    final entry = _currentEntry;
    if (entry == null) return;
    final now = _clock();
    _journalWrite(entry.copyWith(
      updatedAtMs: now.millisecondsSinceEpoch,
      finishedAtMs: now.millisecondsSinceEpoch,
      clearStage: true,
      outcomeKind: JournalOutcomeKind.decision,
      message: decision.message,
      aiFailureReason: decision.aiFailureReason,
      failureClassName: decision.failureClass.name,
      allowRawFallback: false,
      attempts: decision.aiAttempts,
    ));
  }

  // ── Presentation routing ──────────────────────────────────────

  /// Re-run presentation routing for a held share (a presenter
  /// that was asked to present but lost its context before the
  /// frame hands the outcome back through here).
  void presentPendingShare() => _presentShare();

  void _presentShare() {
    if (_pendingShare == null || _shareDialogVisible) return;
    final presenter = _pagePresenter ?? _rootPresenter;
    presenter?.call();
  }

  void _surfaceFailure() {
    if (_pendingFailure == null) return;
    _rootFailurePresenter?.call();
  }

  /// The share flow's anti-stacking claim (PR #55's page guard,
  /// lifted to app level): exactly one share confirmation may be
  /// on screen, whichever presenter asked first.
  bool tryClaimShareDialog() {
    if (_shareDialogVisible || _pendingShare == null) return false;
    _shareDialogVisible = true;
    return true;
  }

  void releaseShareDialog() {
    _shareDialogVisible = false;
  }

  /// The share confirmation has been shown and dismissed: the
  /// held outcome is consumed. [exportMs] is set when the user
  /// actually shared (the flow stamps the store the same way the
  /// page always did); the page reads it back for its
  /// "Last exported" line.
  void consumePendingShare({int? exportMs}) {
    final wasRestored = _outcomeRestored;
    _pendingShare = null;
    _shareRevealPending = false;
    _outcomeRestored = false;
    if (exportMs != null) _lastExportMs = exportMs;
    // Consume-once (T1-4): a consumed ready outcome leaves no
    // journal record to re-restore on the next launch.
    if (wasRestored || _currentEntry?.outcomeKind == JournalOutcomeKind.ready) {
      _currentEntry = null;
      unawaited(_journal.clear());
    }
    notifyListeners();
  }

  /// A failure surfaced somewhere other than the page (root
  /// snackbar) has been seen: it is no longer held.
  void markFailureSeen() {
    if (_pendingFailure == null) return;
    _pendingFailure = null;
    _failureRevealPending = false;
    _heldDecisionAt = null;
    _heldDecisionIsEarlier = false;
    if (_outcomeRestored) {
      _outcomeRestored = false;
      _currentEntry = null;
      unawaited(_journal.clear());
    }
    notifyListeners();
  }

  /// App returned to the foreground (any presenter's lifecycle
  /// observer may call this; it is idempotent): reveal what a
  /// backgrounded completion held.
  void handleResumed() {
    if (!userIsPresent) return;
    // F5: a held decision encountered again on resume is being
    // rendered later than it was produced.
    if (_pendingFailure is ReportAiDecision) _heldDecisionIsEarlier = true;
    if (_shareRevealPending && _pendingShare != null) {
      _shareRevealPending = false;
      _presentShare();
    }
    if (_failureRevealPending && _pendingFailure != null) {
      _failureRevealPending = false;
      if (_pagePresenter == null) _surfaceFailure();
      // With the page mounted, its inline rendering of
      // [pendingFailure] IS the surface.
    }
  }

  /// The report-ready notification was tapped: the platform has
  /// foregrounded the app; present the held share confirmation
  /// through the best available presenter. The claim guard and
  /// the resume path cannot stack a second dialog.
  ///
  /// VC 100129: on a FRESH process the singleton starts empty —
  /// the tap first waits for the journal restore, then presents
  /// the restored ready outcome (opening the exact journaled
  /// artifact through the normal share flow). Previously this
  /// no-oped on the fresh singleton and the tap was a dead end.
  void handleNotificationTap() {
    final restore = _restoreFuture;
    if (restore != null) {
      unawaited(restore.then((_) {
        _shareRevealPending = false;
        if (userIsPresent) _presentShare();
      }));
      return;
    }
    _shareRevealPending = false;
    if (userIsPresent) _presentShare();
  }

  Future<void> _notifyReportReady() async {
    try {
      await _effectiveNotifier.showReportReady();
    } catch (_) {
      // Best-effort by contract (PR #55): a failed post stays off
      // the completion path; the held share still reveals on
      // return.
    }
  }

  /// Test hygiene: back to a pristine idle state. The journal
  /// STORE is left untouched (a relaunch test seeds it on
  /// purpose); in-memory restore state is reset and a fresh
  /// restore is armed for the next construction-equivalent use.
  @visibleForTesting
  void debugReset() {
    _stage = null;
    _cancelRequested = false;
    _pendingShare = null;
    _pendingFailure = null;
    _shareDialogVisible = false;
    _shareRevealPending = false;
    _failureRevealPending = false;
    _lastExportMs = 0;
    _pagePresenter = null;
    _rootPresenter = null;
    _rootFailurePresenter = null;
    _currentEntry = null;
    _outcomeRestored = false;
    _interruptedEntry = null;
    _restoredDecisionEntry = null;
    _autoRunInFlight = false;
    _autoRestoreAttempted = false;
    _heldDecisionAt = null;
    _heldDecisionIsEarlier = false;
  }
}
