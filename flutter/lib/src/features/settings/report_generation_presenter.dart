import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/report_generation_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'report_share_flow.dart';

/// The navigator the root presenter presents through: wired as
/// `MaterialApp.navigatorKey` by the app root, so the presenter's
/// dialogs land on the root navigator, above whatever route is
/// current. (The presenter's own build context sits ABOVE the
/// Navigator — `MaterialApp.builder` wraps it — and cannot push
/// routes itself.)
final GlobalKey<NavigatorState> reportPresentationNavigatorKey =
    GlobalKey<NavigatorState>();

/// App-root presenter for report generations (founder bug,
/// Nov 9, 2026): mounted once above the app's Navigator by the
/// app root, it is the presenter of last resort for
/// [ReportGenerationService] completions.
///
/// - A generation that completes while the user is in-app on any
///   screen other than Progress Reports presents the share
///   confirmation HERE, over the current screen (the dialog goes
///   on the root navigator from this context), exactly once —
///   the service's app-level claim arbitrates against the page
///   presenter and the resume/notification-tap paths.
/// - A failure that completes with no Progress Reports page
///   mounted surfaces as a snackbar carrying the pipeline's
///   EXISTING failure message (no new copy), and the service
///   marks it seen; with the page mounted, the page's inline
///   failure rendering is the surface and this presenter stays
///   out of the way. Phase 3 exception: a held AI-failure
///   DECISION ([ReportAiDecision]) surfaces as Juno's decision
///   dialog and is never marked seen — the hold survives until
///   the user decides.
/// - A backgrounded completion keeps PR #55's behavior: the
///   report-ready notification posts from the service, and this
///   presenter's lifecycle observer reveals the held share
///   confirmation on resume.
class ReportGenerationPresenter extends StatefulWidget {
  final ReportGenerationService service;
  final Widget child;

  /// The navigator key wired into the app's MaterialApp
  /// (defaults to the shared [reportPresentationNavigatorKey];
  /// tests pass their own).
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Test seams: production uses a plain [SettingsStore] (the
  /// same storage every Settings surface reads) and the flow's
  /// default Printing share.
  final SettingsStore? store;
  final Future<void> Function(List<int> bytes, String fileName)? sharePdf;

  const ReportGenerationPresenter({
    super.key,
    required this.service,
    required this.child,
    this.navigatorKey,
    this.store,
    this.sharePdf,
  });

  @override
  State<ReportGenerationPresenter> createState() =>
      _ReportGenerationPresenterState();
}

class _ReportGenerationPresenterState
    extends State<ReportGenerationPresenter> with WidgetsBindingObserver {
  late final SettingsStore _store;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? SettingsStore();
    WidgetsBinding.instance.addObserver(this);
    widget.service.registerRootPresenter(_presentShare,
        failurePresenter: _presentFailure);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.service.unregisterRootPresenter(_presentShare);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.service.handleResumed();
    }
  }

  /// A context UNDER the root navigator (this widget's own
  /// context is above it — see [reportPresentationNavigatorKey]).
  BuildContext? get _navContext =>
      (widget.navigatorKey ?? reportPresentationNavigatorKey)
          .currentContext;

  void _presentShare() {
    // Presented SYNCHRONOUSLY from the completion, exactly as
    // the page presented it before the service existed: a
    // post-frame deferral can starve on a static screen (no
    // frame is ever scheduled, so the callback never runs).
    if (!mounted) return;
    final navContext = _navContext;
    if (navContext == null) return;
    presentReportShareConfirmation(
      context: navContext,
      service: widget.service,
      store: _store,
      sharePdf: widget.sharePdf,
    );
  }

  void _presentFailure() {
    final failed = widget.service.pendingFailure;
    if (failed == null) return;
    if (!mounted) return;
    final navContext = _navContext;
    if (navContext == null) return;
    if (failed is ReportAiDecision) {
      // Phase 3: a held AI-failure decision is NOT a snackbar —
      // it is Juno's decision surface, and it is never marked
      // seen here: the hold survives until the user actually
      // decides (here, or inline on the Progress Reports page).
      showDialog<void>(
        context: navContext,
        builder: (ctx) => AlertDialog(
          backgroundColor: NotelColors.surface,
          title: const Text(aiDecisionTitle,
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.w600)),
          content: const Text(aiDecisionBody,
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 13)),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.service.resumeAiDecision(retryAi: false);
              },
              child: const Text(aiDecisionRawLabel,
                  style: TextStyle(color: NotelColors.textSecondary)),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.service.resumeAiDecision(retryAi: true);
              },
              child: const Text(aiDecisionRetryLabel,
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      return;
    }
    // The pipeline's own failure message — the exact string the
    // Progress Reports page renders inline — surfaced on the
    // user's current screen, then marked seen so the held
    // outcome is not re-surfaced.
    ScaffoldMessenger.of(navContext).showSnackBar(
      SnackBar(content: Text(failed.message)),
    );
    widget.service.markFailureSeen();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
