import 'dart:async';

import 'package:flutter/widgets.dart';

import 'progress_report.dart';
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
/// The service knows nothing about report CONTENT: pipelines are
/// built by the page and injected as a [ReportGenerationRun].
class ReportGenerationService extends ChangeNotifier {
  ReportGenerationService({this.notifier});

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

  // ── Public state (the page is a view of this) ─────────────────

  ReportStage? get stage => _stage;
  bool get isGenerating => _stage != null;
  bool get isCancelled => _cancelRequested;
  ReportReady? get pendingShare => _pendingShare;
  ReportFailed? get pendingFailure => _pendingFailure;
  bool get shareDialogVisible => _shareDialogVisible;
  bool get shareRevealPending => _shareRevealPending;
  int get lastExportMs => _lastExportMs;

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
  Future<void> start(ReportGenerationRun run) async {
    if (_stage != null) return;
    _cancelRequested = false;
    _pendingFailure = null;
    _failureRevealPending = false;
    _stage = ReportStage.collecting;
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
    await start(
      ({required onStage, required isCancelled}) => resume(
        retryAi: retryAi,
        onStage: onStage,
        isCancelled: isCancelled,
      ),
    );
  }

  void _setStage(ReportStage stage) {
    if (_stage == null) return; // finished; a late callback is inert
    _stage = stage;
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
      // was saved, stays saved. No notification, no dialog.
      notifyListeners();
      return;
    }
    switch (outcome) {
      case ReportReady ready:
        _pendingShare = ready;
        notifyListeners();
        if (userIsPresent) {
          _presentShare();
        } else {
          _shareRevealPending = true;
          unawaited(_notifyReportReady());
        }
      case ReportFailed failed:
        if (failed.message == 'Cancelled') {
          notifyListeners();
          return;
        }
        _pendingFailure = failed;
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
    _pendingShare = null;
    _shareRevealPending = false;
    if (exportMs != null) _lastExportMs = exportMs;
    notifyListeners();
  }

  /// A failure surfaced somewhere other than the page (root
  /// snackbar) has been seen: it is no longer held.
  void markFailureSeen() {
    if (_pendingFailure == null) return;
    _pendingFailure = null;
    _failureRevealPending = false;
    notifyListeners();
  }

  /// App returned to the foreground (any presenter's lifecycle
  /// observer may call this; it is idempotent): reveal what a
  /// backgrounded completion held.
  void handleResumed() {
    if (!userIsPresent) return;
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
  void handleNotificationTap() {
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

  /// Test hygiene: back to a pristine idle state.
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
  }
}
