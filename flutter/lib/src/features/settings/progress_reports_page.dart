import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/clinician_report_pdf.dart';
import 'package:tabs_lab/src/data/downloads_saver.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart';
import 'package:tabs_lab/src/data/report_generation_journal.dart';
import 'package:tabs_lab/src/data/report_generation_service.dart';
import 'package:tabs_lab/src/data/report_ready_notification.dart';
import 'package:tabs_lab/src/data/weekly_automation.dart';
import 'package:tabs_lab/src/data/weekly_generation_claim.dart';
import 'package:tabs_lab/src/data/weekly_notification.dart';
import 'package:tabs_lab/src/data/weekly_production.dart';
import 'package:tabs_lab/src/data/weekly_report.dart';
import 'package:tabs_lab/src/features/settings/report_share_flow.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 66 — Progress Reports page (Settings → AI & Clinical
/// Advocate → Progress Reports), the Flutter port of native
/// `ProgressReportsScreen.kt`. Renders inside the Settings scroll
/// column; the Settings top bar shows "Progress Reports" and its
/// back button returns to AI & Clinical Advocate (unchanged).
///
/// Layout mirrors native's cards: Overview (type picker, custom
/// category checkboxes, time range, stats, honest coverage,
/// medical disclaimer) → Preview (summary line, hourly chart,
/// generation state, Export button, last-exported, "What's in
/// this report" disclosure) → Details (per-category share rows) →
/// Appointment card. PDF generation + share confirmation follow
/// native's pipeline (see progress_report.dart / _pdf.dart).
class ProgressReportsPage extends StatefulWidget {
  final SettingsProfileData profileData;
  final TabsBackend backend;
  final SettingsStore store;
  final HealthConnectService? healthConnectService;
  final ReminderNotificationService? notificationService;

  /// Round 65's extracted-text store (Settings passes its shared
  /// instance; defaults to the same singleton).
  final KnowledgeExtractionStore? knowledgeStore;

  /// Test seams: production uses Printing.sharePdf + a save into
  /// the app documents directory.
  final Future<void> Function(List<int> bytes, String fileName)? sharePdf;
  final Future<String> Function(List<int> bytes, String fileName)? savePdf;

  /// Test seam for the automatic Downloads copy (Juno Ruling 2):
  /// production uses [ReportDownloadsSaver] over the Health Connect
  /// bridge channel (MediaStore). Returns whether the copy landed;
  /// a throw is treated the same as a false return — a failed
  /// Downloads copy never blocks generation or sharing.
  final Future<bool> Function(List<int> bytes, String fileName)?
      saveToDownloads;
  final ReportGenerationPipeline? pipeline;

  /// Test seam for the Phase 1 item 3 one-page clinician report
  /// (defaults to a pipeline wired to the page's backend + the
  /// stored-score history).
  final ClinicianReportPipeline? clinicianPipeline;

  /// Phase 1 item 3, Q7 premium gate (applied at the VC 100109
  /// combine — the item-3 spec's crew assumption: the one-page
  /// clinician report is PREMIUM; the existing multi-page report
  /// is the free basic export and is untouched). Test seam for
  /// the entitlement check; production defaults to the server
  /// membership check ([TabsBackend.fetchMembership] — the same
  /// source the Health Coach / timeline gates use), fail-closed.
  final Future<bool> Function()? clinicianPremiumCheck;

  /// Test seam for the report-ready notification (founder
  /// request, Nov 9, 2026): posted when a generation completes
  /// while the user is not watching this page. Production builds
  /// a [LocalReportReadyNotifier] whose tap returns the user to
  /// the held share confirmation.
  final ReportReadyNotifier? reportReadyNotifier;

  /// The app-level generation owner (founder bug, Nov 9, 2026):
  /// Settings passes [ReportGenerationService.instance] so the
  /// run survives this page's disposal and completions can be
  /// presented on whatever screen is current. Null (tests that
  /// pump the page standalone) gives the page its own service —
  /// the pre-service isolation those tests were written against.
  final ReportGenerationService? generationService;

  // ── Weekly Report Package 1 seams ─────────────────────────────

  /// Test seam for the weekly entitlement check (production
  /// defaults to the SAME source as the clinician gate —
  /// [TabsBackend.fetchMembership]'s `isUnlimited` — fail-closed,
  /// with the lapsed state derived from a non-empty archive).
  final Future<WeeklyEntitlement> Function()? weeklyEntitlementCheck;

  /// Test seam for the weekly archive store.
  final WeeklyReportStore? weeklyStore;

  /// Test seam for the weekly generation service. Production
  /// builds a dedicated service whose ONLY notifier is a
  /// [WeeklySilentNotifier] — PR #55's report-ready notifier is
  /// never used on the weekly path (zero notifications).
  final ReportGenerationService? weeklyGenerationService;

  /// The silent notifier for the production weekly service
  /// (test seam so the recording sink can be asserted).
  final WeeklySilentNotifier? weeklyNotifier;

  /// Weekly Report Package 2: the AUTOMATIC weekly notification
  /// seam. Production builds a [LocalWeeklyNotifier] (the new
  /// `Weekly reports` channel — never the report-ready channel).
  /// This is separate from the weekly service's silent notifier:
  /// the service's hold-until-seen machinery never posts for a
  /// weekly run; the automation coordinator posts through THIS
  /// notifier, and only when the completeness bar passes.
  final WeeklyNotifier? weeklyAutoNotifier;

  /// Background Generation package: the cross-process claim seam
  /// for the automation coordinator. Production (Settings) passes
  /// the file-backed claim; null keeps the coordinator's
  /// permissive default (the shape every pre-existing page test
  /// was written against).
  final WeeklyGenerationClaim? weeklyClaim;

  /// Background Generation package (Juno BG-3): the
  /// background-access probe for the background-access ask.
  /// Returns true when the grant is verified present, false when
  /// verified absent, and null when unknown (probe failure —
  /// renders nothing). Production defaults to
  /// [HealthConnectService.hasBackgroundAccess] with a throw
  /// mapped to null.
  final Future<bool?> Function()? weeklyBackgroundAccessCheck;

  /// Clock seam for the weekly closed-week computation.
  final DateTime Function()? weeklyClock;

  const ProgressReportsPage({
    super.key,
    required this.profileData,
    required this.backend,
    required this.store,
    this.healthConnectService,
    this.notificationService,
    this.knowledgeStore,
    this.sharePdf,
    this.savePdf,
    this.saveToDownloads,
    this.pipeline,
    this.clinicianPipeline,
    this.clinicianPremiumCheck,
    this.reportReadyNotifier,
    this.generationService,
    this.weeklyEntitlementCheck,
    this.weeklyStore,
    this.weeklyGenerationService,
    this.weeklyNotifier,
    this.weeklyAutoNotifier,
    this.weeklyClaim,
    this.weeklyBackgroundAccessCheck,
    this.weeklyClock,
  });

  @override
  State<ProgressReportsPage> createState() => _ProgressReportsPageState();
}

/// Native appointment-reminder notification id (NotificationHelper
/// 770002). Note: 770002 sits INSIDE the event-counter hash range
/// (700000–799998) — the same accepted exposure as check-in 770001,
/// not its own disjoint block. Kept as native's id regardless.
const appointmentReminderId = 770002;

class _ProgressReportsPageState extends State<ProgressReportsPage>
    with WidgetsBindingObserver {
  ReportFocus _focus = ReportFocus.health;
  bool _last30Days = true;
  Set<String> _customIds = {};
  bool _customSeeded = false;

  List<QuickLogCategory> _categories = const [];
  List<QuickLogEntry> _entries = const [];
  bool _loaded = false;

  int? _selectedHour;
  bool _showSources = false;
  bool _showAttemptDetails = false;

  /// The generation's owner (see [ReportGenerationService]):
  /// stage, cancellation, and the held outcome are SERVICE state
  /// now — this page is a view of it, so leaving and returning
  /// shows the live run instead of a blank page. The two getters
  /// below keep the build code reading the same names.
  late final ReportGenerationService _service;
  late final ReportCompletionPresenter _pagePresenter;

  ReportStage? get _stage => _service.stage;
  String? get _failureMessage => _service.pendingFailure?.message;
  bool get _failureAllowRaw =>
      _service.pendingFailure?.allowRawFallback ?? false;

  int _lastExportMs = 0;
  String? _appointmentDateIso;
  String _appointmentTypeKey = 'health';
  String? _pickedDateIso;
  ReportFocus _appointmentFocus = ReportFocus.health;

  TabsBackend get _backend => widget.backend;

  // ── Weekly Report Package 1 state ─────────────────────────────

  /// The weekly generation's dedicated service: same run-closure
  /// / hold-until-seen / share pop-up behavior as the standard
  /// flow, but a SEPARATE instance with a silent notifier and an
  /// in-memory journal (the durable weekly record is the archive
  /// store; the standard service's journal key stays singleton-
  /// owned and is never written by weekly runs).
  late final ReportGenerationService _weeklyService;
  late final ReportCompletionPresenter _weeklyPresenter;
  late final WeeklyReportStore _weeklyStore;

  /// Weekly Report Package 2: the first-open automation
  /// coordinator (trigger / idempotency / fail-closed entitlement
  /// / evaluate / archive / conditional notify). Built in
  /// initState after the weekly service; nullable only so the
  /// service listener can read it before construction settles.
  WeeklyAutomationCoordinator? _weeklyAutomation;

  /// Null while the entitlement check is running (fail-closed:
  /// no weekly surface offers generation until it resolves).
  WeeklyEntitlement? _weeklyEntitlement;
  List<WeeklyArchiveRecord> _weeklyRecords = const [];

  /// The saved path of the weekly ready outcome already archived
  /// (the service listener fires repeatedly; archiving is once
  /// per outcome).
  String? _weeklyArchivedPath;

  /// Juno §a permission-needed state: the blocked generation's
  /// evaluation + record, shown in-app until dismissed with
  /// "Not now" (the archive entry stays, labeled Blocked).
  WeeklyEvaluation? _permissionEval;
  bool _permissionDismissed = false;

  /// Background Generation package: the extracted generation
  /// executor (weekly_production.dart) — the page's manual and
  /// automatic weekly runs both drive the weekly service through
  /// it, and the background runner drives the same executor
  /// page-free.
  late final WeeklyGenerationExecutor _weeklyExecutor;

  /// Juno background-access ask state (DISTINCT from the §a
  /// state above; Flag BG-1): null = unknown / not yet probed
  /// (renders nothing, BG-3); true = grant verified present
  /// (silent, BG-5); false = verified absent (the ask may render
  /// for a Premium user outside the dismissal window).
  bool? _bgAccess;
  int? _bgDismissedAtMs;

  /// Item 3 Q7 premium gate state: null = check still running;
  /// true = the one-page clinician report is unlocked. Fail-closed:
  /// an unknown or failed check reads as locked, so the premium
  /// artifact is never generated on an unverified entitlement.
  bool? _clinicianUnlocked;

  @override
  void initState() {
    super.initState();
    _service = widget.generationService ??
        ReportGenerationService(notifier: widget.reportReadyNotifier);
    if (widget.generationService != null &&
        widget.reportReadyNotifier != null) {
      _service.useNotifier(widget.reportReadyNotifier!);
    }
    // VC 100131: bind the page's backend for the service's
    // cancel-invalidation DELETE (fire-and-forget).
    _service.useBackend(widget.backend);
    _pagePresenter = () {
      // Synchronous presentation from the completion, as the
      // page always did (a post-frame deferral can starve when
      // no frame is scheduled). The service only invokes this
      // while the page is registered — i.e. mounted — so the
      // context is live; the mounted check is belt-and-braces.
      if (!mounted) {
        _service.presentPendingShare();
        return;
      }
      presentReportShareConfirmation(
        context: context,
        service: _service,
        store: widget.store,
        sharePdf: widget.sharePdf,
      );
    };
    _service.addListener(_onServiceChanged);
    _service.registerPagePresenter(_pagePresenter);
    // Weekly Report Package 1: the dedicated weekly service.
    _weeklyStore = widget.weeklyStore ?? WeeklyReportStore();
    _weeklyService = widget.weeklyGenerationService ??
        ReportGenerationService(
          notifier: widget.weeklyNotifier ?? WeeklySilentNotifier(),
          journal: ReportGenerationJournal.inMemory({}),
        );
    _weeklyPresenter = () {
      if (!mounted) {
        _weeklyService.presentPendingShare();
        return;
      }
      presentReportShareConfirmation(
        context: context,
        service: _weeklyService,
        store: widget.store,
        sharePdf: widget.sharePdf,
      );
    };
    _weeklyService.addListener(_onWeeklyServiceChanged);
    _weeklyService.registerPagePresenter(_weeklyPresenter);
    // Background Generation package: the extracted executor —
    // its pipeline builder is THIS page's standard pipeline
    // (providers wired to the page's standard service, exactly
    // as the pre-extraction _startWeeklyGeneration used it).
    _weeklyExecutor = WeeklyGenerationExecutor(
      weeklyService: _weeklyService,
      pipelineBuilder: _standardPipeline,
      categoriesLoader: () async => _categories,
      profileLoader: () async => _profileInput,
      recordsLoader: () async => _weeklyRecords,
      savePdf: widget.savePdf ?? _defaultSave,
      saveToDownloads: widget.saveToDownloads ?? _defaultSaveToDownloads,
      otherServiceGenerating: () => _service.isGenerating,
      fallbackCategories: (_) => _selected,
    );
    // Weekly Report Package 2: the automation coordinator. Its
    // generation seam drives THIS page's weekly service (through
    // the executor), and it — not the service listener — archives
    // automatic runs and owns the bar-gated weekly notification.
    _weeklyAutomation = WeeklyAutomationCoordinator(
      checkEntitlement: _resolveWeeklyEntitlement,
      store: _weeklyStore,
      generate: _runAutoGeneration,
      notifier: widget.weeklyAutoNotifier ?? LocalWeeklyNotifier(),
      claim: widget.weeklyClaim,
    );
    WidgetsBinding.instance.addObserver(this);
    _load();
    _resolveClinicianGate();
    _loadWeekly();
  }

  @override
  void dispose() {
    _service.unregisterPagePresenter(_pagePresenter);
    _service.removeListener(_onServiceChanged);
    _weeklyService.unregisterPagePresenter(_weeklyPresenter);
    _weeklyService.removeListener(_onWeeklyServiceChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The page is a view of the service: any service change
  /// (stage, held outcome, a share stamped elsewhere) rebuilds
  /// it, and a share completed through the root presenter still
  /// lands its "Last exported" stamp here.
  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {
      if (_service.lastExportMs > _lastExportMs) {
        _lastExportMs = _service.lastExportMs;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _service.handleResumed();
      // Weekly Report Package 1: the weekly service holds its
      // own completions the same way — an away completion's
      // share confirmation presents on return, exactly as the
      // standard flow's does.
      _weeklyService.handleResumed();
      // Weekly Report Package 2: returning to the app with this
      // surface mounted is an app open — re-run the automation
      // check (a pure read unless a week is due and ungenerated).
      unawaited(_maybeAutoWeekly());
      // Background Generation package: a return is also the
      // re-verify point for the background-access ask (BG-4 —
      // returning from Health Connect settings with the grant
      // now present removes the ask in the same render).
      unawaited(_refreshBgAskState());
    }
  }

  Future<void> _resolveClinicianGate() async {
    try {
      final check = widget.clinicianPremiumCheck ??
          () async => (await _backend.fetchMembership()).isUnlimited;
      final unlocked = await check();
      if (!mounted) return;
      setState(() => _clinicianUnlocked = unlocked);
    } catch (_) {
      if (!mounted) return;
      setState(() => _clinicianUnlocked = false);
    }
  }

  Future<void> _load() async {
    final results = await Future.wait<dynamic>([
      _backend.fetchLogCategories(),
      _backend.fetchLogEntryDtos(),
      widget.store.getReportLastType(),
      widget.store.getReportLastRange30d(),
      widget.store.getReportLastExportMs(),
      widget.store.getReportAppointmentDate(),
      widget.store.getReportAppointmentType(),
    ]);
    if (!mounted) return;
    setState(() {
      _categories = results[0] as List<QuickLogCategory>;
      _entries = results[1] as List<QuickLogEntry>;
      _focus = ReportFocus.fromKey(results[2] as String);
      _last30Days = results[3] as bool;
      _lastExportMs = results[4] as int;
      _appointmentDateIso = results[5] as String?;
      _appointmentTypeKey = results[6] as String;
      _appointmentFocus = ReportFocus.fromKey(_appointmentTypeKey);
      _loaded = true;
      _seedCustomIfNeeded();
    });
    // VC 100129 (R5-9): a generation interrupted by process
    // death auto-starts ONCE from its persisted request
    // identity, framed "Starting your report again". If the
    // auto-start cannot proceed, the interrupted surface below
    // (R5-1–R5-3) is what renders instead.
    final interrupted = _service.interruptedEntry;
    if (interrupted != null && !_service.autoRestoreAttempted) {
      unawaited(
          _service.autoRestoreInterrupted(_buildRun(interrupted.request)));
    }
    // Weekly Report Package 2: the automation check needs the
    // loaded categories (its generation run is built from them);
    // _loadWeekly fires the same check, and whichever lands
    // second finds the coordinator's guards already settled.
    unawaited(_maybeAutoWeekly());
  }

  /// Builds the service run for a persisted request identity
  /// (restore / retry paths): selections resolve from the
  /// identity against the page's loaded categories.
  ReportGenerationRun _buildRun(ReportRequestIdentity identity) {
    final focus = ReportFocus.fromKey(identity.focusKey);
    final selected = resolveReportCategories(
        _categories, focus, identity.categoryIds.toSet());
    if (identity.kind == 'clinician') {
      final pipeline = _clinicianPipeline();
      return ({required onStage, required isCancelled}) => pipeline.generate(
            selectedCategories: selected,
            last30Days: identity.last30Days,
            profile: _profileInput,
            onStage: onStage,
            isCancelled: isCancelled,
            renderPdf: (data) async => buildClinicianPdfBytes(data,
                fonts: await loadClinicianPdfFonts()),
            savePdf: widget.savePdf ?? _defaultSave,
            saveToDownloads:
                widget.saveToDownloads ?? _defaultSaveToDownloads,
          );
    }
    final pipeline = _standardPipeline();
    return ({required onStage, required isCancelled}) => pipeline.generate(
          selectedCategories: selected,
          last30Days: identity.last30Days,
          profile: _profileInput,
          forceRawFallback: identity.forceRaw,
          onStage: onStage,
          isCancelled: isCancelled,
          renderPdf: (snapshot, aiSummary,
                  {required bool isRawFallback, RawReportBanner? rawBanner}) =>
              buildReportPdfBytes(snapshot,
                  aiSummary: aiSummary,
                  isRawFallback: isRawFallback,
                  rawBanner: rawBanner ?? RawReportBanner.noChoiceFailure),
          savePdf: widget.savePdf ?? _defaultSave,
          saveToDownloads: widget.saveToDownloads ?? _defaultSaveToDownloads,
        );
  }

  ReportRequestIdentity _identityFor(
          {required String kind, bool forceRaw = false}) =>
      ReportRequestIdentity(
        kind: kind,
        focusKey: _focus.key,
        last30Days: _last30Days,
        categoryIds: _selected.map((c) => c.id).toList(),
        forceRaw: forceRaw,
      );

  ReportGenerationPipeline _standardPipeline() =>
      widget.pipeline ??
      ReportGenerationPipeline(
        collector: ReportDataCollector(
          backend: _backend,
          hc: widget.healthConnectService ?? HealthConnectService(),
          documentsLoader: () async {
            final pull = await _backend.fetchSyncPull();
            final docs = KnowledgeDocumentMeta.listFromPull(pull);
            if (docs.isEmpty) return const [];
            final store =
                widget.knowledgeStore ?? KnowledgeExtractionStore.instance;
            await store.load(await _backend.readEmail());
            return [
              for (final d in docs)
                if (store.textFor(d.id) case final t?
                    when t.trim().isNotEmpty)
                  t,
            ];
          },
        ),
        backend: _backend,
        // T1-2 save hook: the journal records the exact artifact
        // path the moment the save lands inside the pipeline.
        onArtifactSaved: _service.noteArtifactSaved,
        // VC 100131: the pipeline reads the generation's wire
        // identity + pickup controls from the service, which
        // owns the mint/reuse rule and rotates them per start()
        // (the clinician pipeline makes no /report call — its
        // generations carry the identity through the journal
        // record the shared service writes for both kinds).
        reportGenerationIdProvider: () =>
            _service.currentReportGenerationId,
        checkPickupFirstProvider: () => _service.currentCheckPickupFirst,
        pickupCheckIdProvider: () => _service.currentPickupCheckId,
        generationInvalidatedProvider: () =>
            _service.currentGenerationInvalidated,
        // Pickup reconciliation: a narrative the service's
        // one-shot probe already collected for a held/restored
        // decision (consuming the server's held row) is handed
        // to the leg through this seam instead of re-fetched.
        prefetchedNarrativeProvider: _service.takePrefetchedNarrative,
      );

  ClinicianReportPipeline _clinicianPipeline() =>
      widget.clinicianPipeline ??
      ClinicianReportPipeline(
        collector: ReportDataCollector(
          backend: _backend,
          hc: widget.healthConnectService ?? HealthConnectService(),
        ),
        clinicianCollector: ClinicianReportCollector(
          scoreLoader: () async {
            final days = await HealthHistoryStore.instance.readAll();
            return {
              for (final e in days.entries)
                if (e.value.dailyScore != null) e.key: e.value.dailyScore!,
            };
          },
          eventsLoader: () => _backend.fetchMedicationChangeEvents(),
          categoriesLoader: () => _backend.fetchLogCategories(),
        ),
        onArtifactSaved: _service.noteArtifactSaved,
      );

  void _seedCustomIfNeeded() {
    // Native: preselect ALL categories the first time Custom opens
    // (only while the custom set is still empty).
    if (_focus == ReportFocus.custom &&
        !_customSeeded &&
        _customIds.isEmpty &&
        _categories.isNotEmpty) {
      _customIds = _categories.map((c) => c.id).toSet();
      _customSeeded = true;
    }
  }

  Future<void> _pickFocus(ReportFocus f) async {
    setState(() {
      _focus = f;
      _seedCustomIfNeeded();
    });
    await widget.store.setReportLastType(f.key);
  }

  Future<void> _pickRange(bool isMonth) async {
    setState(() => _last30Days = isMonth);
    await widget.store.setReportLastRange30d(isMonth);
  }

  List<QuickLogCategory> get _selected =>
      resolveReportCategories(_categories, _focus, _customIds);

  ReportProfileInput get _profileInput =>
      reportProfileInputFromSettings(widget.profileData);

  Future<String> _defaultSave(List<int> bytes, String fileName) async {
    // The saved copy lands in the app documents directory; the
    // share sheet shares the same bytes. The automatic Downloads
    // copy is a SEPARATE step over the same bytes (Juno Ruling 2 —
    // see [_defaultSaveToDownloads]); this app-private save is
    // unchanged.
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// The automatic Downloads copy (Juno Ruling 2): the bridge
  /// plugin's MediaStore writer (the CSV bridge's channel, extended
  /// with a byte hand-off — see downloads_saver.dart). Never throws:
  /// the saver reports failure as false.
  Future<bool> _defaultSaveToDownloads(
          List<int> bytes, String fileName) =>
      ReportDownloadsSaver.instance.savePdf(bytes: bytes, fileName: fileName);

  Future<void> _generate({bool forceRaw = false}) async {
    if (_service.isGenerating) return;
    final pipeline = _standardPipeline();
    // The service owns the run from here: it survives this
    // page's disposal, holds the outcome, and routes its
    // presentation (see ReportGenerationService).
    await _service.start(
      ({required onStage, required isCancelled}) => pipeline.generate(
        selectedCategories: _selected,
        last30Days: _last30Days,
        profile: _profileInput,
        forceRawFallback: forceRaw,
        // A forced-raw ship reached from a held failure carries
        // THAT failure's recorded banner state (Phase 3): a fatal
        // AI class's fallback is a no-choice failure ship; any
        // other held failure leaves the tap itself as the user's
        // explicit choice.
        forceRawBanner: _service.pendingFailure?.rawFallbackBanner ??
            RawReportBanner.explicitChoice,
        onStage: onStage,
        isCancelled: isCancelled,
        renderPdf: (snapshot, aiSummary,
                {required bool isRawFallback, RawReportBanner? rawBanner}) =>
            buildReportPdfBytes(snapshot,
                aiSummary: aiSummary,
                isRawFallback: isRawFallback,
                rawBanner: rawBanner ?? RawReportBanner.noChoiceFailure),
        savePdf: widget.savePdf ?? _defaultSave,
        saveToDownloads: widget.saveToDownloads ?? _defaultSaveToDownloads,
      ),
      request: _identityFor(kind: 'standard', forceRaw: forceRaw),
    );
  }

  /// Phase 1, item 3 — the one-page clinician report: a separate
  /// generate action on this page (founder Q8 crew assumption),
  /// reusing the same save/Downloads/share machinery. No AI call;
  /// the existing report's flow is not modified.
  Future<void> _generateClinician() async {
    // Q7 premium gate (defense in depth — the button is also
    // disabled while locked): the v2 pipeline never runs for a
    // non-premium or unverified entitlement.
    if (_clinicianUnlocked != true) return;
    if (_service.isGenerating) return;
    final pipeline = _clinicianPipeline();
    await _service.start(
      ({required onStage, required isCancelled}) => pipeline.generate(
        selectedCategories: _selected,
        last30Days: _last30Days,
        profile: _profileInput,
        onStage: onStage,
        isCancelled: isCancelled,
        renderPdf: (data) async => buildClinicianPdfBytes(data,
            fonts: await loadClinicianPdfFonts()),
        savePdf: widget.savePdf ?? _defaultSave,
        saveToDownloads: widget.saveToDownloads ?? _defaultSaveToDownloads,
      ),
      request: _identityFor(kind: 'clinician'),
    );
  }

  // ── Weekly Report Package 1 ───────────────────────────────────

  Future<void> _loadWeekly() async {
    final records = await _weeklyStore.readAll();
    if (!mounted) return;
    setState(() => _weeklyRecords = records);
    final entitlement = await _resolveWeeklyEntitlement();
    if (!mounted) return;
    setState(() => _weeklyEntitlement = entitlement);
    // Background Generation package: probe the background grant
    // for the Juno ask (Premium surfaces only need the answer,
    // but the probe is read-only and fail-closed either way).
    unawaited(_refreshBgAskState());
    // Weekly Report Package 2: opening this surface is the
    // first-open automation check point.
    unawaited(_maybeAutoWeekly());
  }

  /// The weekly entitlement resolution — the extracted resolver
  /// in weekly_production.dart (the background runner resolves
  /// through the same function). Fail-closed; lapsed derives
  /// from this page's loaded archive records.
  Future<WeeklyEntitlement> _resolveWeeklyEntitlement() =>
      resolveWeeklyEntitlement(
        overrideCheck: widget.weeklyEntitlementCheck,
        isUnlimitedCheck: () async =>
            (await _backend.fetchMembership()).isUnlimited,
        hasArchiveRecords: () async => _weeklyRecords.isNotEmpty,
      );

  /// Background Generation package — the background-access ask's
  /// probe (Juno BG-3): only a VERIFIED absent result may render
  /// the ask; a probe failure / unknown renders nothing. Also
  /// loads the persisted dismissal stamp (BG-4).
  Future<void> _refreshBgAskState() async {
    final dismissedAt = await widget.store.getWeeklyBgAskDismissedAtMs();
    bool? access;
    try {
      final check = widget.weeklyBackgroundAccessCheck;
      if (check != null) {
        access = await check();
      } else {
        access = await (widget.healthConnectService ??
                HealthConnectService())
            .hasBackgroundAccess();
      }
    } catch (_) {
      access = null; // unknown — never claimed absent (BG-3)
    }
    if (!mounted) return;
    setState(() {
      _bgDismissedAtMs = dismissedAt;
      _bgAccess = access;
    });
  }

  /// Whether the background-access ask renders right now (Juno
  /// §a notes 2–5): Premium only, verified-absent grant, outside
  /// the 28-day dismissal window. Granted is silent (BG-5).
  bool get _bgAskVisible {
    if (_weeklyEntitlement != WeeklyEntitlement.premium) return false;
    if (_bgAccess != false) return false;
    final dismissedAt = _bgDismissedAtMs;
    if (dismissedAt != null) {
      final now = widget.weeklyClock?.call() ?? DateTime.now();
      final dismissed =
          DateTime.fromMillisecondsSinceEpoch(dismissedAt);
      if (now.difference(dismissed) < weeklyBgDismissalWindow) {
        return false;
      }
    }
    return true;
  }

  Future<void> _dismissBgAsk() async {
    final now = widget.weeklyClock?.call() ?? DateTime.now();
    await widget.store
        .setWeeklyBgAskDismissedAtMs(now.millisecondsSinceEpoch);
    if (!mounted) return;
    setState(() => _bgDismissedAtMs = now.millisecondsSinceEpoch);
  }

  /// The ask's primary action: the existing Health Connect
  /// settings route, foreground only (BG-6); on return the grant
  /// is re-checked and a granted ask is removed in the same
  /// render (BG-4). Returning without granting is NOT a
  /// dismissal and starts no window.
  Future<void> _openBgHealthConnectSettings() async {
    await _openHealthConnectSettings();
    await _refreshBgAskState();
  }

  void _onWeeklyServiceChanged() {
    if (!mounted) return;
    // Weekly Report Package 2: while an AUTOMATIC run is in
    // flight, the coordinator is the archiver for its completion
    // (it evaluates with the automation's Flag 1 bound and owns
    // the notification gate) — this listener must not archive
    // the same outcome a second time under the manual rules.
    if (_weeklyAutomation?.inFlight ?? false) {
      setState(() {});
      return;
    }
    final ready = _weeklyService.pendingShare;
    if (ready != null && _weeklyArchivedPath != ready.savedPath) {
      _weeklyArchivedPath = ready.savedPath;
      unawaited(_archiveWeekly(ready));
    }
    setState(() {});
  }

  /// Archives a finished weekly generation: evaluates the
  /// completeness bar over its snapshot and persists the PDF's
  /// record (the PDF itself was saved by the pipeline's save
  /// step). A blocked outcome raises the Juno §a
  /// permission-needed state.
  Future<void> _archiveWeekly(ReportReady ready) async {
    final snapshot = ready.snapshot;
    if (snapshot.weekStart == null || snapshot.weekEnd == null) return;
    final window = WeeklyWeekWindow(snapshot.weekStart!, snapshot.weekEnd!);
    final previous = WeeklyReportStore.previousOf(_weeklyRecords, window);
    final evaluation = evaluateWeeklyCompleteness(
      snapshot: snapshot,
      week: window,
      generationCompleted: true,
      previousWeek: previous,
    );
    final record = WeeklyArchiveRecord(
      weekStartKey: window.startKey,
      weekEndKey: window.endKey,
      generatedAtMs: snapshot.generationTimestampMs,
      fileName: ready.fileName,
      savedPath: ready.savedPath,
      label: evaluation.label,
      blockedSections: evaluation.blockedSections,
      dailyScoreDays: evaluation.dailyScoreDays,
      sleepNights: evaluation.sleepNights,
      loggedDays: evaluation.loggedDays,
      completeDays: evaluation.completeDays,
      avgScoreCompleteDays: evaluation.avgScoreCompleteDays,
    );
    final records = await _weeklyStore.upsert(record);
    if (!mounted) return;
    setState(() {
      _weeklyRecords = records;
      // Juno §d Flag 3: the permission-needed state fires ONLY
      // on a verified permissionDenied outcome — never on an
      // availability contradiction, whose denial claim the
      // week's own data refutes (its archive entry still
      // labels Blocked; the state and its "permission wasn't
      // granted" body stay unfired).
      if (evaluation.blockedSections.isNotEmpty &&
          !evaluation.contradiction) {
        _permissionEval = evaluation;
        _permissionDismissed = false;
      }
    });
  }

  /// Manual weekly generation. The entitlement gate is
  /// PRE-GENERATION (founder clarification): verified again here,
  /// before any generation work begins — no-entitlement and
  /// expired alike produce no PDF, no archive entry, nothing.
  /// The run drives the dedicated weekly [ReportGenerationService]
  /// with forceRawFallback (data pipeline only — NO AI narrative,
  /// zero Gemini cost) over the most recent CLOSED Mon–Sun week.
  Future<void> _generateWeekly() async {
    if (_weeklyService.isGenerating || _service.isGenerating) return;
    final entitlement = await _resolveWeeklyEntitlement();
    if (!mounted) return;
    setState(() => _weeklyEntitlement = entitlement);
    if (entitlement != WeeklyEntitlement.premium) return;
    final now = widget.weeklyClock?.call() ?? DateTime.now();
    final window = WeeklyWeekWindow.mostRecentClosed(now);
    await _startWeeklyGeneration(window, now);
  }

  /// Weekly Report Package 2 — the automation check, fired when
  /// this surface opens and again on lifecycle resume. The
  /// coordinator owns the decision (due week, archive
  /// idempotency, fail-closed entitlement, evaluation, archive,
  /// bar-gated notification); this method only reflects a
  /// generated outcome into the page: the refreshed archive and,
  /// for a verified-denial block, the Juno §a permission-needed
  /// state (Flag 3 — never on a contradiction).
  Future<void> _maybeAutoWeekly() async {
    final automation = _weeklyAutomation;
    if (automation == null || !_loaded) return;
    final now = widget.weeklyClock?.call() ?? DateTime.now();
    final outcome = await automation.maybeGenerate(now: now);
    if (!mounted || outcome.record == null) return;
    // The coordinator archived this outcome; keep the service
    // listener's once-guard in step so a later service change
    // cannot archive the same completion a second time.
    _weeklyArchivedPath = outcome.record!.savedPath;
    final records = await _weeklyStore.readAll();
    if (!mounted) return;
    setState(() {
      _weeklyRecords = records;
      final evaluation = outcome.evaluation;
      if (evaluation != null &&
          evaluation.blockedSections.isNotEmpty &&
          !evaluation.contradiction) {
        _permissionEval = evaluation;
        _permissionDismissed = false;
      }
    });
  }

  /// The coordinator's generation seam — the extracted
  /// executor's seam (weekly_production.dart), which the
  /// background runner also drives page-free.
  Future<WeeklyGenerationResult?> _runAutoGeneration(
          WeeklyWeekWindow week, DateTime now) =>
      _weeklyExecutor.runAutoGeneration(week, now);

  /// One weekly generation run through the dedicated weekly
  /// service, shared by the manual action (Package 1) and the
  /// automation (Package 2) — the extracted executor's run
  /// (weekly_production.dart).
  Future<void> _startWeeklyGeneration(
    WeeklyWeekWindow window,
    DateTime now, {
    DateTime? closedBefore,
  }) =>
      _weeklyExecutor.startWeeklyGeneration(window, now,
          closedBefore: closedBefore);

  /// Tapping an archive entry opens/shares the stored PDF (the
  /// existing share flow's share function; production defaults
  /// to Printing.sharePdf, exactly as the share confirmation).
  Future<void> _openWeeklyRecord(WeeklyArchiveRecord record) async {
    try {
      final bytes = await File(record.savedPath).readAsBytes();
      final shareFn = widget.sharePdf ??
          (b, name) =>
              Printing.sharePdf(bytes: Uint8List.fromList(b), filename: name);
      await shareFn(bytes, record.fileName);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not open this weekly report.')));
      }
    }
  }

  Future<void> _openHealthConnectSettings() async {
    try {
      await (widget.healthConnectService ?? HealthConnectService())
          .openHealthConnectSettings();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not open Health Connect settings')));
      }
    }
  }

  // Completion handling lives in ReportGenerationService (the
  // run's owner) and report_share_flow.dart (the share
  // confirmation, presented by whichever presenter the service
  // routes to — this page, or the app-root presenter when the
  // user is elsewhere in the app). PR #55's semantics carry over
  // unchanged: watched completion presents directly; a
  // backgrounded completion posts the report-ready notification
  // and holds the confirmation for resume / notification tap;
  // cancelled and failed outcomes notify nothing, and a failure
  // renders inline below from the service's held outcome.

  // ── Appointment ─────────────────────────────────────────────────

  Future<void> _saveAppointment() async {
    final date = _pickedDateIso;
    if (date == null) return;
    await widget.store.setReportAppointmentDate(date);
    await widget.store.setReportAppointmentType(_appointmentFocus.key);
    if (mounted) {
      setState(() {
        _appointmentDateIso = date;
        _appointmentTypeKey = _appointmentFocus.key;
        _pickedDateIso = null;
      });
    }
    await _syncAppointmentReminder();
  }

  Future<void> _clearAppointment() async {
    await widget.store.setReportAppointmentDate(null);
    if (mounted) setState(() => _appointmentDateIso = null);
    final notifs = widget.notificationService;
    if (notifs != null) {
      try {
        await notifs.cancel(appointmentReminderId);
      } catch (_) {
        // Visible failure rule: the clear itself already landed;
        // a stale one-shot reminder is the worst case.
      }
    }
  }

  /// Day-before 9:00 AM local reminder through the existing
  /// notification machinery (native AppointmentReminderScheduler),
  /// id 770002 — native's id (inside the event-counter hash range;
  /// see the note on [appointmentReminderId]).
  Future<void> _syncAppointmentReminder() async {
    final notifs = widget.notificationService;
    final iso = _appointmentDateIso;
    if (notifs == null || iso == null) return;
    final date = DateTime.tryParse(iso);
    if (date == null) return;
    final fire = DateTime(date.year, date.month, date.day - 1, 9);
    try {
      if (fire.isAfter(DateTime.now())) {
        final typeLabel =
            ReportFocus.fromKey(_appointmentTypeKey).label;
        final dateLabel =
            '${_monthNames[date.month - 1]} ${date.day}';
        await notifs.scheduleOnce(
          id: appointmentReminderId,
          title: 'Appointment tomorrow',
          body:
              'Your visit is on $dateLabel. Export your $typeLabel report so it is ready.',
          channelId: 'appointment_reminder',
          channelName: 'Appointment reminders',
          when: fire,
          highImportance: true,
        );
      } else {
        await notifs.cancel(appointmentReminderId);
      }
    } on NotificationServiceException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not schedule the appointment reminder')));
      }
    }
  }

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final selectedIds = selected.map((c) => c.id).toSet();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final inRange = _loaded
        ? logsInRange(_entries, selectedIds,
            last30Days: _last30Days, nowMs: nowMs)
        : const <QuickLogEntry>[];
    final hasAnyLogs = _entries.isNotEmpty;
    final generating = _stage != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _overviewCard(selected, inRange),
        const SizedBox(height: 16),
        _previewCard(inRange, selected, hasAnyLogs, generating),
        const SizedBox(height: 16),
        _weeklyCard(),
        if (selected.isNotEmpty) ...[
          const SizedBox(height: 16),
          _detailsCard(selected, inRange),
        ],
        const SizedBox(height: 16),
        _appointmentCard(),
      ],
    );
  }

  Widget _card(List<Widget> children, {BoxBorder? border}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: border,
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _sectionLabel(String text) => Text(text,
      style: const TextStyle(
          color: NotelColors.primary,
          fontSize: 12,
          fontWeight: FontWeight.w600));

  Widget _pickerButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: selected
                ? NotelColors.primary.withValues(alpha: 0.18)
                : NotelColors.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              maxLines: 1,
              style: TextStyle(
                  color: selected
                      ? NotelColors.primary
                      : NotelColors.textSecondary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
        ),
      ),
    );
  }

  Widget _overviewCard(
      List<QuickLogCategory> selected, List<QuickLogEntry> inRange) {
    final denom = coverageDenominator(_entries,
        last30Days: _last30Days, nowMs: DateTime.now().millisecondsSinceEpoch);
    return _card([
      _sectionLabel('Report type'),
      const SizedBox(height: 8),
      Row(children: [
        for (var i = 0; i < ReportFocus.values.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          _pickerButton(
            label: ReportFocus.values[i].label,
            selected: _focus == ReportFocus.values[i],
            onTap: () => _pickFocus(ReportFocus.values[i]),
          ),
        ],
      ]),
      const SizedBox(height: 6),
      Text(_focus.description,
          style: TextStyle(
              color: NotelColors.textSecondary.withValues(alpha: 0.75),
              fontSize: 11)),
      if (_focus == ReportFocus.custom) ...[
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Include these categories',
                style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
            Row(children: [
              TextButton(
                onPressed: () => setState(() =>
                    _customIds = _categories.map((c) => c.id).toSet()),
                child: const Text('Select all',
                    style: TextStyle(color: NotelColors.primary, fontSize: 12)),
              ),
              TextButton(
                onPressed: () => setState(() => _customIds = {}),
                child: const Text('Clear',
                    style: TextStyle(
                        color: NotelColors.textSecondary, fontSize: 12)),
              ),
            ]),
          ],
        ),
        const SizedBox(height: 4),
        for (final c in _categories)
          InkWell(
            onTap: () => setState(() {
              _customIds = _customIds.contains(c.id)
                  ? (_customIds.toSet()..remove(c.id))
                  : (_customIds.toSet()..add(c.id));
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Checkbox(
                  value: _customIds.contains(c.id),
                  onChanged: null,
                  activeColor: NotelColors.primary,
                ),
                const SizedBox(width: 8),
                Text(c.name,
                    style: const TextStyle(
                        color: NotelColors.textPrimary, fontSize: 14)),
              ]),
            ),
          ),
      ],
      const SizedBox(height: 12),
      _sectionLabel('Time range'),
      const SizedBox(height: 8),
      Row(children: [
        _pickerButton(
            label: 'This Month',
            selected: _last30Days,
            onTap: () => _pickRange(true)),
        const SizedBox(width: 8),
        _pickerButton(
            label: 'All Time',
            selected: !_last30Days,
            onTap: () => _pickRange(false)),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        _stat('${inRange.length}', 'Entries'),
        _stat('${selected.length}', 'Categories'),
        _stat(_last30Days ? '30' : 'All', 'Days covered'),
      ]),
      const SizedBox(height: 8),
      Center(
        child: Text(
            'Logged ${distinctDaysLogged(inRange)} of $denom days',
            style: TextStyle(
                color: NotelColors.textSecondary.withValues(alpha: 0.75),
                fontSize: 11)),
      ),
      const SizedBox(height: 12),
      // Native MedicalDisclaimerBanner (verbatim wording).
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: NotelColors.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition. AI insights are informational only. Consult a healthcare professional.',
          textAlign: TextAlign.center,
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 11),
        ),
      ),
    ]);
  }

  /// Weekly Report Package 1 card (Juno §c rows 1.1–1.17):
  /// header, the manual generate action (Premium only), the
  /// archive list, the free user's ONE locked row, the lapsed
  /// line, and the permission-needed state. No new screen.
  Widget _weeklyCard() {
    final entitlement = _weeklyEntitlement;
    final generating = _weeklyService.isGenerating;
    return _card([
      _sectionLabel(weeklyArchiveHeader),
      const SizedBox(height: 8),
      if (entitlement == WeeklyEntitlement.free) ...[
        // Exactly ONE locked row; no generate action (row 1.9/1.10).
        Row(children: [
          const Icon(Icons.lock_outline, size: 18, color: NotelColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(weeklyLockedTitle,
                    style: TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
                const Text(weeklyLockedBody,
                    style: TextStyle(
                        color: NotelColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ]),
      ] else if (entitlement == WeeklyEntitlement.lapsed) ...[
        const Text(weeklyLapsedLine,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        if (_weeklyRecords.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final r in _weeklyRecords) _weeklyEntryRow(r),
        ],
      ] else if (entitlement == WeeklyEntitlement.premium) ...[
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton(
            onPressed: generating ? null : () => _generateWeekly(),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: NotelColors.primary),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: generating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: NotelColors.primary))
                : const Text(weeklyGenerateLabel,
                    style: TextStyle(
                        color: NotelColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
          ),
        ),
        if (_weeklyService.pendingFailure != null && !generating) ...[
          const SizedBox(height: 8),
          Text(_weeklyService.pendingFailure!.message,
              style: const TextStyle(color: NotelColors.error, fontSize: 12)),
        ],
        if (_bgAskVisible) ...[
          const SizedBox(height: 12),
          _backgroundGenerationAsk(),
        ],
        const SizedBox(height: 8),
        if (_weeklyRecords.isEmpty)
          const Text(weeklyArchiveEmpty,
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 12))
        else
          for (final r in _weeklyRecords) _weeklyEntryRow(r),
        if (_permissionEval != null && !_permissionDismissed) ...[
          const SizedBox(height: 12),
          _permissionNeededState(_permissionEval!),
        ],
      ],
    ]);
  }

  /// Juno Background Generation ruling §a — the
  /// background-access ask: a DISTINCT, section-level state on
  /// the weekly surface (never the §a permission-needed state;
  /// Flag BG-1). It renders only for a Premium user with a
  /// verified-absent background grant outside the dismissal
  /// window (see [_bgAskVisible]); the granted state is silent
  /// and ships no element at all (BG-5).
  Widget _backgroundGenerationAsk() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(weeklyBgTitle,
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(weeklyBgBody,
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          const Text(weeklyBgGuidance,
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          Row(children: [
            TextButton(
              onPressed: () => _openBgHealthConnectSettings(),
              child: const Text(weeklyBgPrimaryAction,
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () => _dismissBgAsk(),
              child: const Text(weeklyBgSecondaryAction,
                  style: TextStyle(
                      color: NotelColors.textSecondary, fontSize: 12)),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _weeklyEntryRow(WeeklyArchiveRecord r) {
    return InkWell(
      onTap: () => _openWeeklyRecord(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          const Icon(Icons.picture_as_pdf,
              size: 18, color: NotelColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(weeklyWeekLabel(r.window),
                    style: const TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                Text(weeklyGeneratedLine(r.generatedAtMs),
                    style: const TextStyle(
                        color: NotelColors.textSecondary, fontSize: 11)),
              ],
            ),
          ),
          Text(r.label.label,
              style: const TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  /// Juno §a — the permission-needed state: in-app, attached to
  /// the blocked week's outcome; not a modal, not a banner, not
  /// a notification. Fires ONLY on a verified permissionDenied
  /// outcome (the evaluator's blocked label derives from the
  /// unified probe's per-section statuses).
  Widget _permissionNeededState(WeeklyEvaluation evaluation) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(weeklyPermissionTitle,
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(weeklyPermissionBody,
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          const Text(weeklyPermissionSectionsLabel,
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
          for (final section in evaluation.blockedSections)
            Text(section,
                style: const TextStyle(
                    color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          const Text(weeklyPermissionGuidance,
              style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          Row(children: [
            TextButton(
              // The SAME Health Connect settings destination the
              // Settings surface's button of this name opens; no
              // auto-regenerate on return (Juno §a.3).
              onPressed: () => _openHealthConnectSettings(),
              child: const Text(weeklyPermissionPrimaryAction,
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () => setState(() => _permissionDismissed = true),
              child: const Text(weeklyPermissionSecondaryAction,
                  style: TextStyle(
                      color: NotelColors.textSecondary, fontSize: 12)),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(children: [
          Text(value,
              style: const TextStyle(
                  color: NotelColors.primary,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 11)),
        ]),
      );

  Widget _previewCard(List<QuickLogEntry> inRange,
      List<QuickLogCategory> selected, bool hasAnyLogs, bool generating) {
    return _card([
      _sectionLabel('Preview'),
      const SizedBox(height: 4),
      Text(
        '${_focus.label} report, ${_last30Days ? 'this month' : 'all time'}. '
        '${inRange.length} entries across ${selected.length} categories.',
        style:
            const TextStyle(color: NotelColors.textSecondary, fontSize: 13),
      ),
      if (inRange.isNotEmpty) ...[
        const SizedBox(height: 8),
        const Text('Log activity by hour',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        SizedBox(height: 210, child: _hourlyChart(inRange)),
        if (_selectedHour != null)
          Text(
            '${formatHourLabel(_selectedHour!)}: ${hourlyCounts(inRange)[_selectedHour!] ?? 0} entries',
            style: const TextStyle(
                color: NotelColors.textSecondary, fontSize: 12),
          ),
      ] else ...[
        const SizedBox(height: 12),
        Center(
          child: Column(children: [
            Icon(Icons.bar_chart,
                size: 40,
                color: NotelColors.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            Text(
              selected.isEmpty
                  ? 'No categories selected'
                  : 'Nothing to preview yet',
              style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              selected.isEmpty
                  ? 'Pick at least one category above to see a preview.'
                  : 'Log symptoms, meds, or sleep and your activity will show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: NotelColors.textSecondary.withValues(alpha: 0.7),
                  fontSize: 12),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      if (generating) ...[
        // R5-9: the auto re-run framing line, above the standard
        // stage label, only while an auto re-run is in flight.
        if (_service.autoRunInFlight) ...[
          const Center(
            child: Text(autoRerunFraming,
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 6),
        ],
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: NotelColors.primary),
          ),
          const SizedBox(width: 10),
          Text(reportStageLabels[_stage] ?? 'Generating report...',
              style: const TextStyle(
                  color: NotelColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: () => _service.requestCancel(),
            child: const Text('Cancel Report Generation',
                style: TextStyle(color: NotelColors.error, fontSize: 11)),
          ),
        ),
      ],
      if (!generating && _service.expiredEntry != null) ...[
        // VC 100131, Juno R8-1 — the EXPIRED terminal state: the
        // report finished server-side but its held copy passed
        // the 24 h ceiling and was deleted. It REPLACES the
        // decision surface (restored or in-session alike — same
        // copy, no variant), and its ONE action starts a NEW
        // logical generation (new identity, full collect +
        // generate). Copy is Juno's signed R8-1 set, defined in
        // report_generation_journal.dart.
        const Text(expiredHoldTitle,
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text(expiredHoldBody,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () {
            final entry = _service.expiredEntry!;
            _service.clearExpired();
            unawaited(_service.start(_buildRun(entry.request),
                request: entry.request));
          },
          child: const Text(expiredHoldActionLabel,
              style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
      ] else if (!generating && _service.restoredDecisionEntry != null) ...[
        // VC 100129, R5-5 Case 2 — a decision restored after
        // relaunch: framing line + unchanged title, Case 2 body,
        // ONE action (no snapshot survives death, so the
        // same-session body/buttons would be false here).
        if (_service.restoredDecisionFraming != null) ...[
          Text(_service.restoredDecisionFraming!,
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
        ],
        const Text(aiDecisionTitle,
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text(restoredDecisionBodyCase2,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () {
            final entry = _service.restoredDecisionEntry!;
            _service.clearRestoredDecision();
            // VC 100131: this starts a NEW logical generation
            // (fresh identity minted in start()), PAIRED with the
            // restored generation for pickup: the leg checks
            // pickup for the RESTORED identity before its first
            // dispatch — a held narrative is collected instead of
            // re-burned, and a 410 replaces this decision surface
            // with the expired state (Juno R8-1).
            unawaited(_service.start(_buildRun(entry.request),
                request: entry.request,
                pickupCheckGenerationId: entry.reportGenerationId));
          },
          child: const Text(restoredDecisionAction,
              style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ),
        _attemptDetails(),
        const SizedBox(height: 8),
      ] else if (!generating && _service.interruptedEntry != null) ...[
        // VC 100129, R5-1–R5-3 — the interrupted surface (shown
        // when the auto re-run could not proceed).
        const Text(interruptedTitle,
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text(interruptedBody,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () {
            final entry = _service.interruptedEntry!;
            unawaited(_service.retryInterrupted(_buildRun(entry.request)));
          },
          child: const Text(interruptedRetryLabel,
              style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
      ] else if (_service.pendingFailure is ReportAiDecision) ...[
        // Phase 3 — the held AI-failure decision (Juno's ruled
        // surface, byte-exact): the AI leg exhausted a retryable
        // class, no PDF shipped, and the generation holds until
        // the user retries the analysis on the collected data or
        // explicitly chooses the data-only report.
        // VC 100129 F5: a decision rendered later than it was
        // produced carries the earlier-attempt framing line.
        if (_service.heldFramingLine != null) ...[
          Text(_service.heldFramingLine!,
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
        ],
        const Text(aiDecisionTitle,
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text(aiDecisionBody,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 4),
        Row(children: [
          TextButton(
            onPressed: () => _service.resumeAiDecision(retryAi: true),
            child: const Text(aiDecisionRetryLabel,
                style: TextStyle(
                    color: NotelColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () => _service.resumeAiDecision(retryAi: false),
            child: const Text(aiDecisionRawLabel,
                style: TextStyle(
                    color: NotelColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
        ]),
        _attemptDetails(),
        const SizedBox(height: 8),
      ] else if (_failureMessage != null) ...[
        // VC 100129 R5-4: a restored failure carries the
        // earlier-attempt framing line above the unchanged
        // failure message.
        if (_service.heldFramingLine != null) ...[
          Text(_service.heldFramingLine!,
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
        ],
        Text(_failureMessage!,
            style: const TextStyle(color: NotelColors.error, fontSize: 12)),
        if (_failureAllowRaw)
          TextButton(
            onPressed: () => _generate(forceRaw: true),
            child: const Text('Generate Raw Data Report (Without AI)',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
        _attemptDetails(),
        const SizedBox(height: 8),
      ],
      SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton(
          onPressed: (!generating && hasAnyLogs && selected.isNotEmpty)
              ? () => _generate()
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: NotelColors.primary,
            disabledBackgroundColor:
                NotelColors.primary.withValues(alpha: 0.4),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: generating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.picture_as_pdf,
                        size: 18, color: NotelColors.textPrimary),
                    SizedBox(width: 8),
                    Text('Export PDF Report',
                        style: TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton(
          onPressed: (!generating && _clinicianUnlocked == true)
              ? () => _generateClinician()
              : null,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: NotelColors.primary),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Q7 gate: a lock icon while the entitlement check
              // resolves non-premium (Juno's item-3 set has no
              // locked-state copy — no invented text, the item-2
              // locked-view precedent).
              Icon(
                  _clinicianUnlocked == false
                      ? Icons.lock_outline
                      : Icons.description_outlined,
                  size: 18,
                  color: NotelColors.primary),
              const SizedBox(width: 8),
              const Text('Export Clinician Report (1 page)',
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
      if (!hasAnyLogs) ...[
        const SizedBox(height: 6),
        Text('Add some notes first to generate a report.',
            style: TextStyle(
                color: NotelColors.textSecondary.withValues(alpha: 0.5),
                fontSize: 11)),
      ],
      if (_lastExportMs > 0) ...[
        const SizedBox(height: 8),
        Center(
          child: Text('Last exported ${formatExportTimestamp(_lastExportMs)}',
              style: TextStyle(
                  color: NotelColors.textSecondary.withValues(alpha: 0.6),
                  fontSize: 11)),
        ),
      ],
      const SizedBox(height: 8),
      InkWell(
        onTap: () => setState(() => _showSources = !_showSources),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("What's in this report",
                  style: TextStyle(
                      color: NotelColors.textSecondary, fontSize: 12)),
              Icon(_showSources ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: NotelColors.textSecondary),
            ],
          ),
        ),
      ),
      if (_showSources) ...[
        const SizedBox(height: 4),
        _sourceRow('Your logged entries',
            'Symptoms, meds, sleep, and notes you recorded'),
        const SizedBox(height: 10),
        _sourceRow('Health Connect biometrics',
            'Heart rate, sleep, and activity from your device'),
        const SizedBox(height: 10),
        _sourceRow('AI generated summary',
            'Written by AI from your data. Informational only, not medical advice.'),
      ],
    ]);
  }

  /// R-1 F1 (R5-6/R5-7): the recorded attempt history behind a
  /// "Details" expansion, read from the generation journal.
  /// Only Juno's mapped plain labels and actually-received HTTP
  /// statuses render — never raw class names, reasons, exception
  /// text, URLs, or health content.
  Widget _attemptDetails() {
    // VC 100130 (Juno R6-1): the ONE non-AI failure line renders
    // in this same expansion, AFTER any AI attempt lines — it is
    // the outcome that ended the generation, so it closes the
    // record. Same style as the attempt lines.
    final lines = [
      ..._service.displayAttemptLines,
      ..._service.displayFailureLines,
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () =>
              setState(() => _showAttemptDetails = !_showAttemptDetails),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(attemptDetailsLabel,
                    style: TextStyle(
                        color: NotelColors.textSecondary, fontSize: 12)),
                Icon(
                    _showAttemptDetails
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: NotelColors.textSecondary),
              ],
            ),
          ),
        ),
        if (_showAttemptDetails)
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(line,
                  style: const TextStyle(
                      color: NotelColors.textSecondary, fontSize: 11)),
            ),
      ],
    );
  }

  Widget _sourceRow(String title, String detail) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle,
              size: 16, color: NotelColors.primary.withValues(alpha: 0.7)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                Text(detail,
                    style: const TextStyle(
                        color: NotelColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ],
      );

  Widget _hourlyChart(List<QuickLogEntry> inRange) {
    final data = hourlyCounts(inRange);
    final maxVal = data.values.fold<int>(1, (a, b) => a > b ? a : b);
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 24,
      itemBuilder: (_, hour) {
        final count = data[hour] ?? 0;
        final isSel = _selectedHour == hour;
        return GestureDetector(
          onTap: () => setState(
              () => _selectedHour = isSel ? null : hour),
          child: Container(
            width: 40,
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (count > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('$count',
                        style: TextStyle(
                            color: isSel
                                ? NotelColors.primary
                                : NotelColors.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                Container(
                  width: 12,
                  height: count == 0 ? 0 : (count / maxVal) * 120,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isSel
                          ? [NotelColors.primary, NotelColors.primary]
                          : [
                              NotelColors.primary.withValues(alpha: 0.6),
                              NotelColors.primary.withValues(alpha: 0.2),
                            ],
                    ),
                    borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(hourBarLabel(hour),
                    maxLines: 1,
                    style: TextStyle(
                        color: isSel
                            ? NotelColors.primary
                            : NotelColors.textSecondary,
                        fontSize: 9,
                        fontWeight:
                            isSel ? FontWeight.bold : FontWeight.w500)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailsCard(
      List<QuickLogCategory> selected, List<QuickLogEntry> inRange) {
    final total = inRange.isEmpty ? 1 : inRange.length;
    return _card([
      _sectionLabel('Details'),
      const SizedBox(height: 12),
      for (var i = 0; i < selected.length; i++) ...[
        if (i > 0) const SizedBox(height: 14),
        _categoryRow(selected[i],
            inRange.where((e) => e.categoryId == selected[i].id).length, total),
      ],
    ]);
  }

  Widget _categoryRow(QuickLogCategory c, int count, int total) {
    final pct = count / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(c.name,
                style: const TextStyle(
                    color: NotelColors.textPrimary, fontSize: 14)),
            Text('$count',
                style: TextStyle(
                    color: c.color, fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 8,
          decoration: BoxDecoration(
            color: NotelColors.surfaceHigh,
            borderRadius: BorderRadius.circular(4),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: pct.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: c.color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _appointmentCard() {
    final saved = _appointmentDateIso;
    return _card(
      [
        const Row(children: [
          Icon(Icons.event_note, size: 22, color: NotelColors.primary),
          SizedBox(width: 8),
          Text('Prepare for an appointment',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Save the date and the report type you want ready for your visit. We will remind you the day before to export it.',
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (saved != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: NotelColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Appointment: ${formatIsoDate(saved)}${appointmentCountdown(saved) != null ? ' (${appointmentCountdown(saved)})' : ''}',
                      style: const TextStyle(
                          color: NotelColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                    Text(
                        '${ReportFocus.fromKey(_appointmentTypeKey).label} report saved',
                        style: const TextStyle(
                            color: NotelColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              Column(children: [
                TextButton(
                  onPressed: () =>
                      _pickFocus(ReportFocus.fromKey(_appointmentTypeKey)),
                  child: const Text('Use this type',
                      style:
                          TextStyle(color: NotelColors.primary, fontSize: 12)),
                ),
                TextButton(
                  onPressed: _clearAppointment,
                  child: const Text('Clear',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 12)),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: now,
                firstDate: DateTime(now.year - 1),
                lastDate: DateTime(now.year + 5),
              );
              if (picked != null && mounted) {
                setState(() => _pickedDateIso = dateStrOf(picked));
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.surfaceHigh,
              foregroundColor: NotelColors.textPrimary,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.calendar_month,
                size: 18, color: NotelColors.primary),
            label: Text(
                _pickedDateIso != null
                    ? 'Visit on ${formatIsoDate(_pickedDateIso!)}'
                    : 'Pick a date',
                style: const TextStyle(fontSize: 13)),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          for (var i = 0; i < ReportFocus.values.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _pickerButton(
              label: ReportFocus.values[i].label,
              selected: _appointmentFocus == ReportFocus.values[i],
              onTap: () =>
                  setState(() => _appointmentFocus = ReportFocus.values[i]),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _pickedDateIso != null ? _saveAppointment : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
              disabledBackgroundColor:
                  NotelColors.primary.withValues(alpha: 0.4),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Save appointment',
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold)),
          ),
        ),
      ],
      border: Border.all(
          color: NotelColors.primary.withValues(alpha: 0.25), width: 1),
    );
  }
}
