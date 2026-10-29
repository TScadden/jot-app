import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tabs_lab/src/data/billing_models.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/calendar_service.dart';
import 'package:tabs_lab/src/data/common_conditions.dart';
import 'package:tabs_lab/src/data/csv_file_picker.dart';
import 'package:tabs_lab/src/data/first_run_sync.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/metrics_csv_import.dart';
import 'package:tabs_lab/src/data/migration_bundle.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/google_sign_in_service.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/billing/billing_plans_panel.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';
import 'package:tabs_lab/src/features/settings/crash_test_hook.dart';
import 'package:tabs_lab/src/features/settings/progress_reports_page.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Dark ink on a primary fill (native LegacyDarkChipInk) — the in-app
/// passing precedent for text on Tabs purple: 5.21:1 vs white's 3.80:1
/// (R49 audit S1).
const _chipInk = Color(0xFF0A0A0E);

/// Round 29 — the Flutter Settings tab: a port of native
/// `SettingsScreen.kt` (5933 lines, SettingsMenu MAIN / MEMBERSHIP /
/// USER_PROFILE / CUSTOMIZE / CONNECTED_APPS / AI_AND_KNOWLEDGE /
/// EVENT_COUNTERS / NOTIFICATIONS / SYNC_SETTINGS / JOT_LIVE / DEBUG /
/// PROGRESS_REPORTS).
///
/// What is wired for real (native backend evidence in
/// `tabs_backend.dart` Round 29 notes + `settings_store.dart`):
/// - Personal Context + every profile-backed toggle/field: sync pull
///   for reads, `POST /api/sync/profile` for writes — the same fields
///   native's SyncManager pushes.
/// - Nickname: `POST /api/auth/update-nickname` with native validation.
/// - Membership: REAL state from the pull's isUnlimited/isAdmin.
///   Purchase is Google Play Billing native-side; the Lab has no Play
///   Billing client, so the CTA explains that honestly (flagged).
/// - Device-only settings (nav labels, theme mode, context hidden,
///   check-in reminder, last sync time): SettingsStore, mirroring
///   native DataStore-only keys.
/// - Logout / delete account: AccountActions (server revoke/delete
///   first, then session + Home/QuickLog/Heart caches cleared).
///
/// Round 30 — the Lab-era "not available yet" states are now wired
/// for real: reminder notifications actually schedule on-device
/// (`notification_service.dart`, native schedulers mirrored), Google
/// Account link/disconnect + Google Calendar connect/disconnect run
/// the native flows, Medications / Conditions / Physician Protocols /
/// knowledge-base entries have working profile-synced editors, and
/// Profile Auto-Fill reads weight/height from Health Connect exactly
/// like native `syncHealthProfile`. HR spike/delta alerts stay
/// preference-only (native runs them from a persistent foreground
/// monitor service — flagged as its own item), and the light theme
/// stays a flagged design task (native has a full light palette; the
/// Lab ships only the dark palette and does not improvise one).
///
/// Round 51 — Connected Apps state fix: the Health Connect row
/// binds the live bridge status (it was a static not-connected
/// card), the Google rows' stored flags load on an isolated path
/// and re-load every time the page opens, and Google sign-in
/// seeds the account flag (login_screen.dart) exactly like native
/// — see [_loadConnectionState]. All Round 30 write flows
/// (link/disconnect/connect) are unchanged.
///
/// Workstream 3 (Oct 16, 2026) — Personal Context surfacing: the
/// editor's caption now discloses, in plain language, that the
/// text is quoted word for word as background in clinical
/// reports and sent to the Health Coach with every message, and
/// that the medication list is authoritative for reports. Under
/// the editor, a dismissible hint names any medication ENTRY
/// (active ∪ archived, from the profile list this screen already
/// holds) the text mentions — known names only, via
/// `medicationNamesMentionedInContext` in medications.dart. The
/// hint is UI-only: it never edits the text or the data, and it
/// never renders while the context is privacy-hidden (it would
/// leak the very names the hide toggle conceals). The editor's
/// save behavior (debounced push via tabs_backend) is unchanged.
///
/// Honest unavailable states (native presentation kept, flagged in
/// the round report): Play purchase flow, Tabs Live BLE, and
/// Developer Terminal test notifications. (Progress Reports shipped
/// in Round 66 — progress_reports_page.dart; file/text-note knowledge
/// ingestion shipped in Round 65 — knowledge_documents.dart.)
/// Native Settings does not link to Research (that is a Tools-screen
/// destination, already built as ResearchToolScreen), so neither does
/// this port.
class SettingsScreen extends StatefulWidget {
  final String? email;
  final VoidCallback? onLogout;
  final TabsBackend? backend;
  final SettingsStore? settingsStore;
  final AccountActions? accountActions;
  final HealthConnectService? healthConnectService;

  /// Injectable for tests (Round 30 reminder scheduling).
  final ReminderNotificationService? notificationService;

  /// Injectable for tests (Round 30 Google linking flows).
  final GoogleSignInService? googleSignInService;

  /// Injectable calendar bridge (Round 54) for the connect-time
  /// usability check on the Google Calendar row. Null in
  /// production.
  final CalendarService? calendarService;

  /// Injectable document picker (Round 65) for Digital Knowledge
  /// Extraction. Null in production (the SAF bridge picker).
  final KnowledgeDocumentPicker? knowledgePicker;

  /// Injectable extracted-text store (Round 65). Null in production.
  final KnowledgeExtractionStore? knowledgeStore;

  /// Injectable CSV picker (R70 WS3) for the health-history import.
  /// Null in production (the SAF bridge picker).
  final CsvFilePicker? csvFilePicker;

  /// Injectable history store (R70 WS3). Null in production (the
  /// shared [HealthHistoryStore.instance]).
  final HealthHistoryStore? historyStore;

  /// Injectable for tests (native opens these in the system browser).
  final Future<bool> Function(Uri uri)? urlLauncher;

  /// Takeover Phase 2 — the app-owned billing service for the
  /// Membership page (single instance, owned by the app flow via
  /// BillingAppSync; threaded through MainShell). This screen
  /// CONSUMES it only: it never constructs its own service and
  /// never disposes this one. Null in the Lab (and in tests that
  /// do not inject one): the Membership page then keeps its
  /// honest cannot-purchase state.
  final BillingService? billingService;

  /// TAKEOVER Phase 4 — injectable migration bridge (Lab export /
  /// production import). Null in production (real secure storage +
  /// the SAF picker / share-sheet bridges).
  final MigrationBundleService? migrationService;
  final MigrationFilePicker? migrationPicker;
  final MigrationShareService? migrationShare;

  /// Round 34 — open directly on the Event Counters page instead of
  /// the main menu (the Home counter slot pushes Settings this way).
  /// Back from that page pops the route (it was pushed as a
  /// destination, not reached from the Settings menu).
  final bool openEventCounters;

  const SettingsScreen({
    super.key,
    this.email,
    this.onLogout,
    this.backend,
    this.settingsStore,
    this.accountActions,
    this.healthConnectService,
    this.notificationService,
    this.googleSignInService,
    this.calendarService,
    this.knowledgePicker,
    this.knowledgeStore,
    this.csvFilePicker,
    this.historyStore,
    this.urlLauncher,
    this.billingService,
    this.migrationService,
    this.migrationPicker,
    this.migrationShare,
    this.openEventCounters = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _Page {
  main,
  membership,
  userProfile,
  customize,
  connectedApps,
  aiKnowledge,
  eventCounters,
  notifications,
  syncSettings,
  jotLive,
  debug,
  progressReports,
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TabsBackend _backend;
  late final KnowledgeExtractionStore _kStore;
  late final KnowledgeDocumentService _kService;
  late final KnowledgeDocumentPicker _kPicker;
  late final SettingsStore _store;
  late final AccountActions _actions;
  late final ReminderNotificationService _notifs;
  late final GoogleSignInService _google;
  late final HealthConnectService _hc;
  late final MigrationBundleService _migration;
  late final MigrationFilePicker _migrationPicker;
  late final MigrationShareService _migrationShare;

  late _Page _page;
  SettingsProfileData _data = const SettingsProfileData();
  bool _loaded = false;

  /// Counter-mutation durability (Oct 2026): true once a real sync
  /// pull (or a counter save built on one) has populated [_data].
  /// A later load whose pull FAILS (null body) must keep the
  /// last-known [_data] instead of resetting the whole screen to
  /// factory defaults — the founder's "all counters disappeared
  /// ~1s after a tap" flicker was exactly that reset landing when
  /// the post-push reload pull failed.
  bool _hasRealData = false;

  /// Correction round (Vera F1): true while a counter save is in
  /// flight. The counter action buttons disable on it — a second
  /// tap during a save must never fire a second save (with the old
  /// fresh-row toggle, a double-tap archived then un-archived,
  /// reproducing the founder's "archive did not stick" symptom).
  bool _counterSaveInFlight = false;

  /// Correction round (Juno C1): whether this screen session's
  /// last load/save outcome CONFIRMS the on-screen data matches
  /// the server. The counters page "Synced" chip renders only
  /// while this is true; a failed load (kept-data or first-ever)
  /// or an aborted/failed save drops it to the not-synced state
  /// until the next successful pull/push. Session-only view
  /// state: a fresh screen starts unconfirmed until its first
  /// load lands.
  bool _syncConfirmed = false;

  // Device-only settings (SettingsStore).
  bool _showNavLabels = true;
  // Juno ruling (Oct 2026): no _themeMode view state anymore — the
  // Appearance picker is disabled and Dark is always the shown
  // selection, so this screen never reads the stored theme mode.
  // The stored key/value is left exactly as it was in the store.
  bool _contextHidden = true;
  bool _checkInEnabled = true;
  int _lastSyncMs = 0;

  // Round 30 — notification scheduling state. _notifError carries the
  // visible error code when a schedule call fails; the denied flags
  // drive native's under-row explanations after a permission denial.
  String? _notifError;
  bool _notifDenied = false;
  bool _checkInDenied = false;

  // Round 30 — Connected Apps device state (native keeps all four
  // values in DataStore only; mirrored in SettingsStore).
  bool _gCalConnected = false;
  String _gCalEmail = '';
  bool _gAccountConnected = false;
  String _gAccountEmail = '';

  // Round 51 — Health Connect status for the Connected Apps row,
  // read from the SAME HealthConnectService.getStatus() Home's
  // Round 23 status logic uses. Null until the first check lands;
  // the last-known value stays on screen while a re-check runs
  // (no stale flash, no empty flash). A bridge failure falls back
  // to notConnected with the exception code kept for display,
  // exactly like Home (_hcStatusErrorCode there).
  HealthConnectStatus? _hcStatus;
  String? _hcErrorCode;

  // HRV grant visibility — when Health Connect is only partially
  // granted, the plain-language names of the data types that are
  // NOT shared (e.g. "Heart rate variability"), read live alongside
  // _hcStatus so the Connected Apps card can name them instead of
  // a generic "some permissions are missing". Empty when fully
  // granted or when the missing-set read failed (the card then
  // keeps its generic partial copy).
  List<String> _hcMissingLabels = const [];

  // Defect 1b — the last capture's HRV outcome from the history
  // store's persisted diagnostics (code + sample/day counts),
  // rendered as the Connected Apps diagnostics line so a capture
  // problem is diagnosable from one screenshot. Null until a
  // capture has recorded an HRV outcome.
  CaptureDiagnostic? _hrvDiag;

  // Daily Score background scoring (founder amendment #2) — the
  // Health Connect BACKGROUND read grant's live state for the
  // Connected Apps card below. Null until the first check lands;
  // read on the same isolated path as the other Connected Apps
  // state so one failing read never resets the page.
  bool? _bgScoreAccess;

  // Round 65 — Digital Knowledge Extraction state. _kProcessing is
  // native's isProcessingFile (the add buttons swap for the
  // "Gemini is reading your files..." row); _kError is native's
  // processError line; per-document extraction states live in the
  // KnowledgeExtractionStore (ready / pending / failed).
  bool _kProcessing = false;
  String? _kError;
  bool _factsExpanded = false;
  bool _docsExpanded = false;
  final Set<int> _expandedFacts = {};
  final Set<String> _kBusyDocs = {};

  String _selectedPlan = 'monthly';

  // Takeover Phase 2 — the app-owned billing service for the
  // Membership page, consumed via the widget parameter. Non-null
  // ONLY in the production build (or when a test injects one);
  // the Lab keeps it null and the page renders its honest
  // cannot-purchase state. Read through the widget on every use
  // so the instance the app flow finishes creating asynchronously
  // is picked up when it arrives.
  BillingService? get _billing => widget.billingService;

  bool _syncing = false;
  bool _recovering = false;

  // TAKEOVER Phase 4 — migration export/import state. _migrationStatus
  // is the plain-language outcome line under the two buttons (success
  // and refusal alike — a refusal is an explanation, not a silent no).
  bool _migrationBusy = false;
  String? _migrationStatus;
  bool _showInsights = false;
  bool _privacyExpanded = false;

  // Round 64 — Past Professional Updates starts COLLAPSED on every
  // open of the AI & Clinical Advocate page (founder directive),
  // mirroring Today Summary's collapsed-by-default rule
  // (today_summary_card.dart: `bool _expanded = false`). View state
  // only: never persisted, and reset whenever the page is entered,
  // so it never survives a fresh open of the screen.
  bool _pastUpdatesExpanded = false;
  String? _deleteError;

  final _contextController = TextEditingController();
  bool _contextSeeded = false;
  Timer? _contextDebounce;

  // Workstream 3 — the dismissed state of the Personal Context
  // medication-name hint, held as the signature (lowercased
  // mentioned names, joined) of the mention set it was dismissed
  // for. Dismissing hides the hint for THAT set only: if the
  // text changes so a different set of entry names is mentioned,
  // the hint returns. View state only — never persisted, never
  // written to the profile.
  String _contextMedHintDismissedKey = '';

  @override
  void initState() {
    super.initState();
    _page = widget.openEventCounters ? _Page.eventCounters : _Page.main;
    _backend = widget.backend ?? TabsBackend();
    _store = widget.settingsStore ?? SettingsStore();
    _actions = widget.accountActions ??
        AccountActions(backend: _backend, settingsStore: _store);
    _notifs = widget.notificationService ?? LocalReminderNotificationService();
    _google = widget.googleSignInService ?? GoogleSignInService();
    _hc = widget.healthConnectService ?? HealthConnectService();
    _kStore = widget.knowledgeStore ?? KnowledgeExtractionStore.instance;
    _kPicker = widget.knowledgePicker ?? KnowledgeDocumentPicker();
    _kService = KnowledgeDocumentService(backend: _backend, store: _kStore);
    _migration = widget.migrationService ?? MigrationBundleService();
    _migrationPicker = widget.migrationPicker ?? MigrationFilePicker();
    _migrationShare = widget.migrationShare ?? MigrationShareService();
    _load();
  }

  // Takeover Phase 2 (single-instance fix): this screen does NOT
  // construct, initialize-own, or dispose a billing service. The
  // app-owned instance arrives via widget.billingService (see the
  // _billing getter); the BillingPlansPanel initializes it if it
  // is still idle, and disposal belongs to the app flow that owns
  // it — never to this screen's dispose().

  /// "Refresh Subscription Status" — native's button calls exactly
  /// the billing sync (`checkSubscriptionStatus`). Production: run
  /// the billing sync-subscriptions reconcile, then reload the
  /// pull. Lab: the pull reload is all there honestly is.
  Future<void> _refreshMembership() async {
    final billing = _billing;
    if (billing != null) {
      await billing.syncSubscriptionStatus();
    }
    await _reloadFromServer();
  }

  @override
  void dispose() {
    // Deliberately does NOT dispose widget.billingService: it is
    // the app-owned single instance (see _billing).
    _contextDebounce?.cancel();
    _contextController.dispose();
    super.dispose();
  }

  /// Counter-mutation durability (Oct 2026): [reportLoadFailure]
  /// is false only for the reload [_pushProfile] runs right after
  /// it has already shown its own save-error snack — the user gets
  /// exactly one honest error, never two queued ones.
  Future<void> _load({bool reportLoadFailure = true}) async {
    final results = await Future.wait<dynamic>([
      _backend.fetchSyncPull(),
      _store.getShowNavLabels(),
      // No getThemeMode(): per Juno's Oct 2026 ruling the disabled
      // Appearance picker never displays the stored value (see the
      // field note above), so nothing here consumes it.
      _store.getUserContextHidden(),
      _store.getCheckInReminderEnabled(),
      _store.getLastSyncTimeMs(),
    ]);
    if (!mounted) return;
    final body = results[0] as Map<String, dynamic>?;
    final SettingsProfileData data;
    if (body == null) {
      // Defect B fix: a failed pull NEVER blanks the screen. Once
      // real data has loaded, keep it whole (every Settings field,
      // counters included) AND surface the failure with a snack —
      // the list the user sees is their last-known data, never a
      // silent factory-default empty list. A first-ever load with
      // no data yet sits on defaults with no snack, exactly like
      // every other screen's honest empty state (a snack here would
      // also queue ahead of — and hide — the action errors this
      // screen shows for the failure the user actually caused).
      data = _hasRealData ? _data : const SettingsProfileData();
      if (reportLoadFailure && _hasRealData) {
        _snack('Could not load your settings. '
            'Check your connection and try again.');
      }
    } else {
      data = SettingsProfileData.fromPull(body);
      _hasRealData = true;
    }
    // Juno C1: the Synced chip follows the load outcome — a kept-
    // data or first-ever failed load is NOT a synced state.
    _syncConfirmed = body != null;
    setState(() {
      _data = data;
      _showNavLabels = results[1] as bool;
      _contextHidden = results[2] as bool;
      _checkInEnabled = results[3] as bool;
      _lastSyncMs = results[4] as int;
      _loaded = true;
      if (!_contextSeeded) {
        _contextController.text = data.userContext;
        _contextSeeded = true;
      }
    });
    if (body != null) {
      // Defect D — the delete-tombstone filter runs on its OWN
      // isolated path AFTER the data lands (the Round 51 pattern):
      // tombstoned ids are filtered out of the rendered list and
      // tombstones the server no longer carries are pruned, without
      // ever blocking or blanking the load above.
      unawaited(_filterTombstonedCountersInPlace());
    }
    // Round 65 — load the account-bound extracted-text cache, then
    // backfill any document that has no cached text (native
    // SettingsViewModel.init → backfillDocumentExtractions). The
    // account email comes from the session (widget email first,
    // then the backend's stored email); any failure here leaves an
    // empty cache — documents still list from the pull, and their
    // extraction state reads pending instead of crashing the page.
    try {
      var email = widget.email;
      if (email == null || email.isEmpty) {
        try {
          email = await _backend.readEmail();
        } catch (_) {}
      }
      await _kStore.load(email);
      if (mounted) setState(() {});
      unawaited(_backfillKnowledgeDocs());
    } catch (_) {}
    // Round 51 — Connected Apps state loads on its OWN path, never
    // inside the Future.wait above: that wait fails atomically, so
    // one throwing read (the real backend's pull starts with an
    // unguarded secure-storage token read) silently discarded the
    // stored Google flags and the rows fell back to their
    // not-connected defaults even when the stored state was set.
    await _loadConnectionState();
    // Native re-arms its reminder schedules at app start (NotelApp
    // onCreate + BootReceiver); the Settings load is the Flutter
    // equivalent checkpoint. Failures land in _notifError and render
    // on the Notifications page — never silent.
    await _syncReminders();
  }

  /// Round 51 — (re)reads every Connected Apps row's state from the
  /// SAME real sources the working surfaces use:
  /// - Health Connect: [HealthConnectService.getStatus] — the live
  ///   bridge check Home's Round 23 status logic and the Data
  ///   Connections screen both use (native parity:
  ///   SettingsViewModel.checkHealthConnectStatus →
  ///   hasAllPermissions, re-run when the screen/permission flow
  ///   returns). Bridge failures fall back to notConnected WITH
  ///   the visible [CODE], exactly like Home — never silent
  ///   (LESSONS.md: every channel call gets try/catch + a code).
  /// - Google Calendar / Google Account: the SettingsStore flags —
  ///   native's DataStore-only state (NotelPreferences.kt:155-158),
  ///   written by the Round 30 connect/link/disconnect flows and,
  ///   for the account, seeded by Google sign-in itself (native
  ///   LoginScreen.kt:220-221; Flutter parity in login_screen.dart
  ///   Round 51). There is deliberately NO parallel store and NO
  ///   sync-pull field: the server pull carries no Google state
  ///   (verified against jot-server src/routes/sync.js — its user
  ///   query selects nickname/tag/is_unlimited/is_admin only).
  ///
  /// Called from [_load], again every time the Connected Apps page
  /// is opened, and again when the Data Connections screen pushed
  /// from this page returns — so a connection made elsewhere shows
  /// reality without restarting the screen. Each source is read in
  /// isolation: one failing read keeps the last-known values for
  /// the others instead of resetting the whole page to defaults.
  Future<void> _loadConnectionState() async {
    try {
      final cal = await _store.getGoogleCalendarConnected();
      final calEmail = await _store.getGoogleCalendarEmail();
      final acc = await _store.getGoogleAccountConnected();
      final accEmail = await _store.getGoogleAccountEmail();
      if (!mounted) return;
      setState(() {
        _gCalConnected = cal;
        _gCalEmail = calEmail;
        _gAccountConnected = acc;
        _gAccountEmail = accEmail;
      });
    } catch (_) {
      // Keep the last-known flag values — never reset to defaults
      // on a storage surprise.
    }
    try {
      final status = await _hc.getStatus();
      // Defect 1b — the last capture's HRV outcome. Read from
      // memory ONLY (no warm, no channel call on this path): the
      // shared store is warmed at startup and by every capture,
      // so its diagnostics are already in memory whenever a
      // capture has run; an unwarmed store simply has no line yet.
      final hs = widget.historyStore ?? HealthHistoryStore.instance;
      final hrvDiag = hs.lastCaptureDiagnostics['hrv'];
      if (!mounted) return;
      // The status lands FIRST, in its own setState: a slow or
      // failing missing-set read below must never delay or block
      // the status the founder sees.
      setState(() {
        _hcStatus = status;
        _hcErrorCode = null;
        _hcMissingLabels = const [];
        _hrvDiag = hrvDiag;
      });
      // Partial grant: also read WHICH types are missing, on its
      // own guard — a failure here must not flip the row to
      // not-connected; it just leaves the labels empty and the
      // card keeps its generic partial copy.
      if (status == HealthConnectStatus.partiallyConnected) {
        try {
          final missingLabels = await _hc.getMissingPermissionLabels();
          if (!mounted) return;
          setState(() => _hcMissingLabels = missingLabels);
        } catch (_) {}
      }
      // Background read grant — its own guard, like the missing-set
      // read above: a failure leaves the last-known state and never
      // touches the connection status.
      try {
        final bg = await _hc.hasBackgroundAccess();
        if (!mounted) return;
        setState(() => _bgScoreAccess = bg);
      } catch (_) {}
    } on HealthConnectException catch (e) {
      if (!mounted) return;
      setState(() {
        _hcStatus = HealthConnectStatus.notConnected;
        _hcErrorCode = e.code;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hcStatus = HealthConnectStatus.notConnected;
        _hcErrorCode = 'UNKNOWN';
      });
    }
  }

  /// Round 51 — opens the shared Data Connections screen (the one
  /// destination Home's watch icon and HC banner use too) and
  /// re-reads connection state when it returns, so a connect /
  /// disconnect / permission change made there is reflected on
  /// this page immediately.
  Future<void> _openConnections() async {
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) =>
            ConnectionsScreen(healthConnectService: _hc),
      ),
    );
    if (!mounted) return;
    await _loadConnectionState();
  }

  /// Hands off to Health Connect settings — the only place the
  /// background read grant can be given (founder amendment #2).
  /// Failures surface with their code; the grant state re-reads
  /// the next time this page's state loads.
  Future<void> _openHcSettingsForBackground() async {
    try {
      await _hc.openHealthConnectSettings();
    } on HealthConnectException catch (e) {
      _snack('Could not open Health Connect settings [${e.code}]');
    } catch (_) {
      _snack('Could not open Health Connect settings [UNKNOWN]');
    }
  }

  /// Defect 1b — the Connected Apps diagnostics line for one HRV
  /// capture outcome. Exact wordings (Juno review):
  /// - failed:  "Last HRV sync check: the read failed
  ///   [HRV_SAMPLES_READ_FAILED]. 0 samples read, 0 days."
  /// - partial: "Last HRV sync check: some data could not be read
  ///   [HRV_SAMPLES_PARTIAL]. 132 samples read, 29 days."
  /// - success: "Last HRV sync check: 132 samples read, 29 days."
  String _hrvDiagnosticsLine(CaptureDiagnostic d) {
    final samples = d.sampleCount ?? 0;
    final days = d.dayCount ?? 0;
    final counts = '$samples ${samples == 1 ? 'sample' : 'samples'} read, '
        '$days ${days == 1 ? 'day' : 'days'}.';
    if (d.errorCode != null) {
      return 'Last HRV sync check: the read failed '
          '[${d.errorCode}]. $counts';
    }
    if (d.partialCode != null) {
      return 'Last HRV sync check: some data could not be read '
          '[${d.partialCode}]. $counts';
    }
    return 'Last HRV sync check: $counts';
  }

  /// Reconciles the on-device notification schedules with the
  /// persisted preferences (ReminderSync). User-triggered calls pass
  /// [report] so failures also surface as a snackbar with the code.
  Future<void> _syncReminders({bool report = false}) async {
    try {
      await ReminderSync(_notifs).syncAll(
        habitEnabled: _data.habitReminderEnabled,
        projectEnabled: _data.projectReminderEnabled,
        checkInEnabled: _checkInEnabled,
        eventEnabled: _data.eventReminderEnabled,
        events: _counters
            .map((c) => EventReminderRequest(
                  counterId: c.id,
                  name: c.name,
                  targetDateMs: c.targetDate,
                  isArchived: c.isArchived,
                  isUp: c.isUp,
                  deletedAt: c.deletedAt,
                ))
            .toList(),
      );
      if (_notifError != null && mounted) {
        setState(() => _notifError = null);
      }
    } on NotificationServiceException catch (e) {
      if (!mounted) return;
      setState(() => _notifError = e.code);
      if (report) {
        _snack('Could not update notification schedules [${e.code}]');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _notifError = 'SCHEDULE_FAILED');
      if (report) {
        _snack('Could not update notification schedules [SCHEDULE_FAILED]');
      }
    }
  }

  /// Native's permission gate for enabling a notification toggle
  /// (SettingsScreen.kt `checkAndToggle` :213-227 and
  /// `handleCheckInReminderToggle` :435-455, with the founder's
  /// rationale-before-system-prompt rule): when POST_NOTIFICATIONS is
  /// not granted, an in-app dialog explains FIRST; the system prompt
  /// appears only after "Allow". Returns true only when notifications
  /// are enabled at the end of the flow — on denial the toggle stays
  /// off, exactly like native. Never called from a background path.
  Future<bool> _ensureNotificationPermission({bool checkIn = false}) async {
    bool enabled;
    try {
      enabled = await _notifs.areNotificationsEnabled();
    } on NotificationServiceException catch (e) {
      _snack('Notifications are unavailable on this device [${e.code}]');
      return false;
    }
    if (enabled) return true;
    if (!mounted) return false;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Allow notifications?',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Text(
          checkIn
              ? 'Tabs needs permission to send notifications before it can remind you. The reminder fires at 4:00 AM, only on mornings you have not checked in yet.'
              : 'Tabs needs permission to send notifications before it can remind you. Each reminder fires at the time shown for its toggle, only while that toggle is on.',
          style: const TextStyle(color: NotelColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: const ValueKey('notif_allow_button'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Allow',
                style: TextStyle(color: NotelColors.primary)),
          ),
        ],
      ),
    );
    if (proceed != true) return false;
    try {
      enabled = await _notifs.requestNotificationsPermission();
    } on NotificationServiceException catch (e) {
      _snack('Could not request notification permission [${e.code}]');
      return false;
    }
    if (!enabled) {
      if (mounted) {
        setState(() {
          _notifDenied = true;
          if (checkIn) _checkInDenied = true;
        });
      }
      return false;
    }
    // Exact timing needs the separate exact-alarm grant (Android 12+).
    // Ask from this same user-initiated flow; if the user declines,
    // schedules fall back to inexact timing rather than not firing.
    try {
      if (!await _notifs.canScheduleExact()) {
        await _notifs.requestExactAlarmsPermission();
      }
    } on NotificationServiceException catch (e) {
      _snack('Exact alarm check failed [${e.code}]');
    }
    return true;
  }

  Future<void> _reloadFromServer({bool reportLoadFailure = true}) async {
    _backend.invalidateSyncPull();
    await _load(reportLoadFailure: reportLoadFailure);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── R70 WS3 — health-history CSV import flow ───────────────────
  // SAF pick → parse → fill-gaps merge into the history store →
  // result dialog (BP importer style). Nothing imports silently:
  // failures show their message, success shows the full report.
  Future<void> _startHistoryImport() async {
    String? text;
    try {
      text = await (widget.csvFilePicker ?? CsvFilePicker()).pickCsvText();
    } on CsvPickException catch (e) {
      _showHistoryImportError(
          e.message ?? "Couldn't read this file. Please try a different CSV.");
      return;
    } catch (_) {
      _showHistoryImportError(
          "Couldn't read this file. Please try a different CSV.");
      return;
    }
    if (text == null || !mounted) return; // user cancelled the picker
    final outcome = await importMetricsCsv(
        csvText: text,
        store: widget.historyStore ?? HealthHistoryStore.instance);
    if (!mounted) return;
    switch (outcome) {
      case MetricsImportError(:final message):
        _showHistoryImportError(message);
      case MetricsImportOk(:final report):
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: NotelColors.surface,
            title: const Text('Health History Imported',
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.bold)),
            content: Text(report.summary,
                style: const TextStyle(
                    color: NotelColors.textSecondary, fontSize: 14)),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                style: FilledButton.styleFrom(
                    backgroundColor: NotelColors.primary),
                child: const Text('OK'),
              ),
            ],
          ),
        );
    }
  }

  void _showHistoryImportError(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text("Couldn't Import CSV",
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Text(message,
            style: const TextStyle(
                color: NotelColors.textSecondary, fontSize: 14)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: FilledButton.styleFrom(
                backgroundColor: NotelColors.primary),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Push profile fields; on failure show the honest error and reload
  /// so the UI never claims a value the server did not take.
  ///
  /// Vera R39 fix pass, Finding 3: this is the single choke point
  /// for ALL Settings profile pushes, and a successful push makes
  /// the cached sync pull stale by definition — invalidate it on
  /// success (the Tools Medications tab already does), so the next
  /// read re-fetches instead of serving pre-push state.
  Future<bool> _pushProfile(Map<String, dynamic> fields) async {
    final ok = await _backend.postSyncProfile(fields);
    if (ok) {
      _backend.invalidateSyncPull();
      // Juno C1: a landed push confirms sync; a failed one drops
      // the chip until the next successful pull/push (the reload
      // below re-confirms only if its own pull lands).
      //
      // Delta re-review (Juno C1 residual): postSyncProfile is
      // FIELD-PARTIAL — a landed push confirms only the fields it
      // sent, never eventCounters. So a push may confirm the chip
      // only when this session already holds real pulled data
      // ([_hasRealData]): the on-screen counters then came from
      // an actual pull (or a counter save built on one) and this
      // push did not touch them. When the first-ever load failed
      // (_hasRealData false, counters still never-loaded
      // defaults), a landed NON-counter push (medications,
      // conditions, a toggle, the debounced Personal Context
      // push) must NOT flip the chip to Synced over a counter
      // list that was never pulled.
      _syncConfirmed = _hasRealData;
    } else {
      _syncConfirmed = false;
      _snack('Could not save. Check your connection and try again.');
      // The save error above IS the honest surface for this
      // failure; the reload's own load-failure snack is suppressed
      // so the user never gets two queued errors for one failure.
      await _reloadFromServer(reportLoadFailure: false);
    }
    return ok;
  }

  /// F-11 (legal-exposure register Q82) — open-source license
  /// notices. Flutter populates the LicenseRegistry with every
  /// bundled package's license, but the shipped app wired no
  /// surface to it, so the MIT/BSD/Apache notice duties that
  /// travel with the binary were unreachable in-app.
  /// showLicensePage renders that registry (app name/version
  /// plus the full license list) in the app's theme.
  void _openLicenses() {
    showLicensePage(
      context: context,
      applicationName: 'Tabs',
      applicationVersion: '1.0',
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    final launch = widget.urlLauncher ??
        (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);
    try {
      await launch(uri);
    } catch (_) {}
  }

  String get _title => switch (_page) {
        _Page.main => 'Settings',
        _Page.membership => 'Membership',
        _Page.userProfile => 'User Profile',
        _Page.customize => 'Customize',
        _Page.connectedApps => 'Connected Apps',
        _Page.aiKnowledge => 'AI & Clinical Advocate',
        _Page.eventCounters => 'Event Counters',
        _Page.notifications => 'Notifications',
        _Page.syncSettings => 'Sync Settings',
        _Page.jotLive => 'Tabs Live Beta',
        _Page.debug => 'Developer Terminal',
        _Page.progressReports => 'Progress Reports',
      };

  void _back() {
    // Round 34 — a Settings screen pushed directly at Event Counters
    // (from the Home counter slot) backs OUT to the caller instead of
    // landing on the Settings menu it never showed.
    if (widget.openEventCounters &&
        _page == _Page.eventCounters &&
        Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _page = _page == _Page.progressReports ? _Page.aiKnowledge : _Page.main;
      // Round 64 — entering the AI page fresh always starts with
      // Past Professional Updates minimized.
      if (_page == _Page.aiKnowledge) _pastUpdatesExpanded = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // System-back parity with the app-bar arrow (founder report,
    // Oct 27, 2026): the sub-pages are body swaps inside this one
    // route, so without interception the Navigator has nothing to
    // pop on Android back and the gesture exits the app from any
    // sub-page — while the arrow correctly returns to the menu.
    // Intercept whenever a sub-page is showing and run the SAME
    // [_back] logic the arrow runs, exceptions included: Progress
    // Reports backs to the AI page it was opened from, and a
    // Settings pushed straight at Event Counters (Home counter
    // slot) backs OUT to its caller — that one is a real route
    // pop, so that state stays poppable instead of intercepting.
    // On the menu page itself nothing changes: the route pops (or
    // the app exits from the shell tab) exactly as before.
    final bool interceptBack = _page != _Page.main &&
        !(widget.openEventCounters && _page == _Page.eventCounters);
    return PopScope(
      canPop: !interceptBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _back();
      },
      child: Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: _page == _Page.main
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back,
                    color: NotelColors.textSecondary),
                onPressed: _back,
              ),
        title: Text(_title,
            style: const TextStyle(
                color: NotelColors.textPrimary,
                // R49 SE7/S3: explicit root-title size (was inherited
                // from the M3 default text theme).
                fontSize: 22,
                fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
        children: [
          if (_page == _Page.main || _page == _Page.membership)
            _segmentedHeader(),
          if (_page == _Page.membership) _membershipPage(),
          if (_page == _Page.main) ..._mainPage(),
          if (_page == _Page.userProfile) ..._userProfilePage(),
          if (_page == _Page.customize) ..._customizePage(),
          if (_page == _Page.connectedApps) ..._connectedAppsPage(),
          if (_page == _Page.aiKnowledge) ..._aiPage(),
          if (_page == _Page.eventCounters) ..._countersPage(),
          if (_page == _Page.notifications) ..._notificationsPage(),
          if (_page == _Page.syncSettings) ..._syncPage(),
          if (_page == _Page.jotLive) ..._unavailablePage(
              'Tabs Live Beta streams live heart data from a connected band over Bluetooth. Bluetooth streaming is not available in the Flutter Lab yet.'),
          if (_page == _Page.debug) ..._unavailablePage(
              'The Developer Terminal fires test notifications from the native app. Test notifications are not available in the Flutter Lab yet.'),
          if (_page == _Page.progressReports)
            ProgressReportsPage(
              // Round 66 — the real Progress Reports page (native
              // ProgressReportsScreen.kt port): type/range pickers,
              // preview, PDF generation via the pure-Dart pdf
              // package, share confirmation, appointment card.
              profileData: _data,
              backend: _backend,
              store: _store,
              healthConnectService: _hc,
              notificationService: _notifs,
              knowledgeStore: _kStore,
            ),
        ],
      ),
      ),
    );
  }

  // ── Shared pieces ────────────────────────────────────────────────

  Widget _segmentedHeader() {
    Widget seg(String label, IconData icon, _Page page) {
      final selected = _page == page;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _page = page),
          child: Container(
            // R49 SE3: segment hit height ≥48dp (was ≈38dp).
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? NotelColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 18,
                    color: selected
                        ? NotelColors.textPrimary
                        : NotelColors.textSecondary),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                        color: selected
                            ? NotelColors.textPrimary
                            : NotelColors.textSecondary,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.w500,
                        fontSize: 14)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        seg('Settings', Icons.subtitles, _Page.main),
        seg('Membership', Icons.wallet, _Page.membership),
      ]),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      );

  Widget _card(List<Widget> children, {EdgeInsets? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _toggleRow(String title, String subtitle, bool value,
      ValueChanged<bool> onChanged,
      {Key? key}) {
    return Row(
      key: key,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: NotelColors.textPrimary,
                      // R49 SE7: explicit row-title size, unified at
                      // 16 with the profile card titles (was inherited).
                      fontSize: 16,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(
                      color: NotelColors.textSecondary, fontSize: 11)),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: NotelColors.primary,
        ),
      ],
    );
  }

  List<Widget> _unavailablePage(String message) {
    return [
      _card([
        Text(message,
            style: const TextStyle(
                color: NotelColors.textSecondary, fontSize: 13)),
      ]),
    ];
  }

  // ── MAIN ─────────────────────────────────────────────────────────

  /// Workstream 3 — the Personal Context medication-name hint.
  ///
  /// Rebuilds off the context controller alone (a keystroke
  /// rebuilds only this sliver, never the whole page), scanning
  /// the LIVE editor text against the medication entries this
  /// screen already holds (`_data.medications`, active ∪
  /// archived) via [medicationNamesMentionedInContext] — known
  /// names only, no lexicon, no fuzzy matching. Visible only
  /// when at least one entry name is mentioned and the founder
  /// has not dismissed the hint for exactly that mention set
  /// (see [_contextMedHintDismissedKey]). UI hint only: it
  /// never modifies the text, the entries, or any saved data.
  Widget _contextMedNameHint() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _contextController,
      builder: (context, value, _) {
        final entries = parseMedicationBlob(_data.medications);
        final names =
            medicationNamesMentionedInContext(value.text, entries);
        if (names.isEmpty) return const SizedBox.shrink();
        final signature = names.map((n) => n.toLowerCase()).join('|');
        if (signature == _contextMedHintDismissedKey) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            key: const ValueKey('personal_context_med_hint'),
            decoration: BoxDecoration(
              color: NotelColors.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: NotelColors.warning.withValues(alpha: 0.45)),
            ),
            padding: const EdgeInsets.only(left: 10, top: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.medication_outlined,
                    size: 18, color: NotelColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Medication names in this text: ${names.join(', ')}. '
                    'For reports, your medication list wins over this '
                    'text, so keep the two in sync.',
                    style: const TextStyle(
                        color: NotelColors.textPrimary, fontSize: 12),
                  ),
                ),
                IconButton(
                  key: const ValueKey('personal_context_med_hint_dismiss'),
                  icon: const Icon(Icons.close,
                      size: 18, color: NotelColors.textSecondary),
                  tooltip: 'Dismiss',
                  onPressed: () => setState(
                      () => _contextMedHintDismissedKey = signature),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _mainPage() {
    return [
      // 1. Personal Context (native SettingsScreen.kt:915-993)
      _card([
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Personal Context',
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15)),
            IconButton(
              icon: Icon(
                  _contextHidden
                      ? Icons.visibility_off
                      : Icons.visibility,
                  color: NotelColors.primary),
              onPressed: () async {
                final v = !_contextHidden;
                setState(() => _contextHidden = v);
                await _store.setUserContextHidden(v);
              },
            ),
          ],
        ),
        // Workstream 3 — disclosure caption (replaces the old
        // goals framing, "Tell Tabs about your goals (e.g.
        // 'training for a marathon')"): this text is not a
        // private goals note. It is quoted word for word as
        // background in clinical reports and sent to the Health
        // Coach with every message, and the medication list —
        // not this text — is what reports treat as authoritative
        // for medications.
        const Text(
            'This text is quoted word for word as background in your '
            'clinical reports and is sent to the Health Coach with '
            'every message. Your medication list is authoritative '
            'for reports, so keep any medications mentioned here in '
            'sync with that list.',
            key: ValueKey('personal_context_caption'),
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 8),
        if (!_contextHidden || _data.userContext.isEmpty)
          TextField(
            key: const ValueKey('personal_context_field'),
            controller: _contextController,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(
                color: NotelColors.textPrimary, fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'Add background info here…',
              hintStyle:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 12),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12))),
            ),
            onChanged: (text) {
              // Native saves on every change and pushes debounced
              // (SettingsViewModel.saveUserContext, 3 s debounce).
              _contextDebounce?.cancel();
              _contextDebounce = Timer(const Duration(seconds: 3), () {
                _pushProfile({'userContext': text});
              });
            },
          )
        else
          GestureDetector(
            onTap: () async {
              setState(() => _contextHidden = false);
              await _store.setUserContextHidden(false);
            },
            child: Container(
              width: double.infinity,
              height: 80,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: NotelColors.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Hidden for your privacy',
                      style: TextStyle(
                          color: NotelColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                  SizedBox(height: 2),
                  Text('Click eye icon or tap here to reveal',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 11)),
                ],
              ),
            ),
          ),
        // Workstream 3 — known-names contradiction hint. Same
        // visibility gate as the editor itself: while the
        // context is privacy-hidden the hint stays hidden too,
        // because its text names medications.
        if (!_contextHidden || _data.userContext.isEmpty)
          _contextMedNameHint(),
      ]),
      const SizedBox(height: 16),
      // 2. Grouped menu (native :998-1113)
      _card(
        [
          _menuRow(Icons.person, 'User Profile', _Page.userProfile,
              key: const ValueKey('menu_user_profile')),
          const Divider(color: NotelColors.divider, height: 1),
          _menuRow(Icons.tune, 'Customize', _Page.customize),
          const Divider(color: NotelColors.divider, height: 1),
          _menuRow(Icons.auto_awesome, 'AI & Clinical Advocate',
              _Page.aiKnowledge),
          const Divider(color: NotelColors.divider, height: 1),
          _menuRow(Icons.timer, 'Event Counters', _Page.eventCounters),
          const Divider(color: NotelColors.divider, height: 1),
          _menuRow(Icons.notifications, 'Notifications', _Page.notifications),
          const Divider(color: NotelColors.divider, height: 1),
          _menuRow(Icons.sync, 'Sync Settings', _Page.syncSettings),
          if (_data.isAdmin) ...[
            const Divider(color: NotelColors.divider, height: 1),
            _menuRow(Icons.bluetooth, 'Tabs Live Beta', _Page.jotLive),
          ],
        ],
        padding: EdgeInsets.zero,
      ),
      const SizedBox(height: 16),
      // 3. Connected Apps singled-out card (native :1118-1137)
      _card(
        [
          _menuRow(Icons.favorite, 'Connected Apps', _Page.connectedApps,
              iconColor: NotelColors.primary,
              key: const ValueKey('menu_connected_apps')),
        ],
        padding: EdgeInsets.zero,
      ),
      const SizedBox(height: 16),
      // R70 WS3 — health-history import: fills older days in the
      // local history store from a Tabs metrics CSV export
      // (fill-gaps only; existing values always win).
      _card(
        [
          InkWell(
            key: const ValueKey('import_health_history'),
            onTap: _startHistoryImport,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  Icon(Icons.upload_file,
                      color: NotelColors.textSecondary, size: 22),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Import Health History (CSV)',
                            style: TextStyle(
                                color: NotelColors.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w500)),
                        SizedBox(height: 2),
                        Text(
                            'Fill in older days from a Tabs metrics export. '
                            'Days already on this device are kept.',
                            style: TextStyle(
                                color: NotelColors.textSecondary,
                                fontSize: 12)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right,
                      color: NotelColors.textSecondary, size: 20),
                ],
              ),
            ),
          ),
        ],
        padding: EdgeInsets.zero,
      ),
      const SizedBox(height: 24),
      // 4. Log out pill (native :1142-1154, color 0xFF801515)
      SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          key: const ValueKey('logout_button'),
          style: ElevatedButton.styleFrom(
            backgroundColor: NotelColors.logoutRed,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26)),
          ),
          onPressed: _showLogoutDialog,
          child: const Text('Log out',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        ),
      ),
      if (_data.isAdmin) ...[
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _page = _Page.debug),
            child: const Text('Developer Terminal Options',
                style: TextStyle(
                    color: NotelColors.textSecondary, fontSize: 11)),
          ),
        ),
      ],
      const SizedBox(height: 24),
      // 5. Footer (native :1170-1210)
      Column(
        children: [
          const Text('Tabs v1.0',
              style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
          const SizedBox(height: 6),
          // R49 SE1: 48dp hit areas for the footer text links (were
          // ≈17dp of bare text); the 12sp labels are unchanged.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openUrl('https://api.jottracker.com/terms.html'),
            child: Container(
              height: 48,
              alignment: Alignment.center,
              child: const Text('Terms of Use',
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(height: 2),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openUrl('https://api.jottracker.com/privacy.html'),
            child: Container(
              height: 48,
              alignment: Alignment.center,
              child: const Text('Privacy Policy',
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(height: 2),
          GestureDetector(
            key: const ValueKey('open_source_licenses'),
            behavior: HitTestBehavior.opaque,
            onTap: _openLicenses,
            child: Container(
              height: 48,
              alignment: Alignment.center,
              child: const Text('Open Source Licenses',
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            key: const ValueKey('reset_account_status'),
            onPressed: _showResetAccountDialog,
            child: Text('Reset Account Status',
                style: TextStyle(
                    // R49 SE2: full-opacity error = 6.95:1 on the
                    // background (was α0.5 = 2.49:1).
                    color: NotelColors.error,
                    fontSize: 10)),
          ),
        ],
      ),
    ];
  }

  Widget _menuRow(IconData icon, String title, _Page page,
      {Color iconColor = NotelColors.textSecondary, Key? key}) {
    return InkWell(
      key: key,
      onTap: () {
        setState(() {
          _page = page;
          // Round 64 — entering the AI page fresh always starts
          // with Past Professional Updates minimized.
          if (page == _Page.aiKnowledge) _pastUpdatesExpanded = false;
        });
        // Round 51 — opening Connected Apps re-reads its rows'
        // state, so connections made elsewhere (Google sign-in,
        // the Data Connections screen, another Settings visit's
        // flows) show reality without a restart. Last-known values
        // stay rendered while the re-check runs.
        if (page == _Page.connectedApps) {
          unawaited(_loadConnectionState());
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.w500,
                      // R49 SE7: row-title role unified at 16.
                      fontSize: 16)),
            ),
            const Icon(Icons.chevron_right,
                size: 20, color: NotelColors.textSecondary),
          ],
        ),
      ),
    );
  }

  // ── MEMBERSHIP (native :589-911) ─────────────────────────────────

  Widget _membershipPage() {
    final d = _data;
    return _card([
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.membershipTitle,
                    style: const TextStyle(
                        color: NotelColors.textPrimary,
                        fontWeight: FontWeight.bold,
                        // R49 SE7: card-title role = 16 bold.
                        fontSize: 16)),
                const SizedBox(height: 4),
                Text(d.membershipSubtitle,
                    style: TextStyle(
                        color: d.isUnlimited
                            ? NotelColors.success
                            : NotelColors.textSecondary,
                        fontSize: 13)),
              ],
            ),
          ),
          Container(
            padding:
                // R49 SE8: vertical padding on the 8dp grid (was 6).
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: d.isUnlimited
                  ? NotelColors.success.withValues(alpha: 0.15)
                  : NotelColors.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(d.membershipBadge,
                style: TextStyle(
                    color: d.isUnlimited
                        ? NotelColors.success
                        : NotelColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w900)),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Center(
        child: Column(
          children: [
            Text(d.membershipLevel,
                style: const TextStyle(
                    color: NotelColors.primary,
                    fontSize: 32,
                    fontWeight: FontWeight.w900)),
            const Text('MEMBERSHIP LEVEL',
                style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Text(
        d.isUnlimited
            ? 'You have full unlimited access to all AI features.'
            : 'Standard account. Upgrade for unlimited AI insights and clinical reports.',
        textAlign: TextAlign.center,
        style:
            const TextStyle(color: NotelColors.textSecondary, fontSize: 13),
      ),
      const SizedBox(height: 12),
      Center(
        child: OutlinedButton.icon(
          key: const ValueKey('refresh_membership'),
          // R49 SE6/S2: 48dp button height (stock M3 default is 40).
          style:
              OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: _loaded ? _refreshMembership : null,
          icon: const Icon(Icons.sync, size: 16, color: NotelColors.primary),
          label: const Text('Refresh Subscription Status',
              style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
      ),
      if (!d.isUnlimited) ...[
        const SizedBox(height: 24),
        if (_billing != null) ...[
          // Takeover Phase 2 — the REAL flow (production build):
          // live Play catalog, user-picked offer, server-verified
          // purchase. The panel carries its own plan cards, CTA
          // (label driven by the offer Play actually returned),
          // terms, and visible error states.
          BillingPlansPanel(
            service: _billing!,
            ctaKey: const ValueKey('membership_cta'),
            onUnlimited: () => unawaited(_reloadFromServer()),
          ),
        ] else ...[
          // Lab build — honest state: no Play catalog exists here,
          // so no price and NO trial is claimed (the old hardcoded
          // "Start 7-day free trial" label is removed; a trial may
          // only be named when Play actually returns one).
          _planCard('monthly', 'Monthly Plan', '', NotelColors.primary),
          const SizedBox(height: 12),
          // Takeover review fix (Juno): no "BEST VALUE" chip in the
          // Lab — there is no catalog price data here to compute
          // savings from, so the chip would be an unbacked claim.
          _planCard('yearly', 'Yearly Plan', '', NotelColors.success),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const ValueKey('membership_cta'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  // R49 SE6/S1+S2: dark-ink foreground (5.21:1 on
                  // primary; white was 3.80:1) and 48dp height.
                  foregroundColor: _chipInk,
                  minimumSize: const Size(64, 48)),
              onPressed: _showPurchaseUnavailable,
              icon: const Icon(Icons.star, size: 18),
              label: const Text('Subscribe with Google Play',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Auto-renews until canceled. Billed by Google Play.',
            textAlign: TextAlign.center,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 11),
          ),
        ],
        const SizedBox(height: 12),
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openUrl(
                // Takeover Phase 2 fix: this link named the LAB
                // package (com.notel.notel.playground.flutter),
                // whose Play subscriptions page does not exist.
                // Subscriptions live under the production package.
                //
                // Audit 1c fix: the sku must be the ONE Play
                // product ID (jot_membership_monthly) for both
                // base plans — the old ternary sent the
                // non-existent product jot_membership_yearly when
                // the yearly plan was selected. See
                // BillingProducts.subscriptionManagementUrl.
                BillingProducts.subscriptionManagementUrl),
            // R49 SE4: 48dp hit area (was ≈15dp of bare text);
            // the 11sp label itself is unchanged.
            child: Container(
              height: 48,
              alignment: Alignment.center,
              child: const Text(
                  'Manage or cancel anytime in Google Play Subscriptions',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: NotelColors.primary, fontSize: 11)),
            ),
          ),
        ),
      ] else ...[
        const SizedBox(height: 20),
        const Text(
            'Thank you for being a member! Your support keeps Tabs improving.',
            style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500)),
      ],
      const SizedBox(height: 12),
      const Text(
        'Tabs Premium is for education and personal self tracking only. It does not provide medical advice, diagnosis, or treatment. Talk to a qualified health professional about any health decisions.',
        textAlign: TextAlign.center,
        style: TextStyle(color: NotelColors.textSecondary, fontSize: 11),
      ),
    ]);
  }

  Widget _planCard(
      String id, String title, String chip, Color chipColor) {
    final selected = _selectedPlan == id;
    return GestureDetector(
      onTap: () => setState(() => _selectedPlan = id),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? NotelColors.primary.withValues(alpha: 0.08)
              : NotelColors.surfaceHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: selected
                  ? NotelColors.primary
                  : NotelColors.primary.withValues(alpha: 0.15),
              width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            Radio<String>(
              value: id,
              // ignore: deprecated_member_use
              groupValue: _selectedPlan,
              // ignore: deprecated_member_use
              onChanged: (v) => setState(() => _selectedPlan = v ?? id),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: NotelColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                  const SizedBox(height: 2),
                  // Native reads live Play pricing; the Lab has no Play
                  // catalog, so native's own fallback copy is shown.
                  const Text('Pricing shown in Google Play',
                      style: TextStyle(
                          color: NotelColors.textSecondary,
                          fontSize: 13)),
                ],
              ),
            ),
            // An empty chip renders nothing (Takeover Phase 2: the
            // Lab monthly card no longer claims a FREE TRIAL it
            // cannot verify against a live catalog).
            if (chip.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(chip,
                    style: TextStyle(
                        color: chipColor,
                        // R49 SE8: minimum text size is 10 (was 9).
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
          ],
        ),
      ),
    );
  }

  void _showPurchaseUnavailable() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Google Play',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: const Text(
            'Subscriptions are purchased through Google Play in the Tabs app. The Flutter Lab cannot start a subscription yet.',
            style: TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK', style: TextStyle(color: NotelColors.primary)),
          ),
        ],
      ),
    );
  }

  // ── USER PROFILE (native :2711-3460) ─────────────────────────────

  List<Widget> _userProfilePage() {
    final d = _data;
    // Round 44 — the User Profile medications list is a DISPLAY
    // filter over the full document: [MedicationDocument] retains
    // every raw row, and only its active indices render below
    // (shared model: parseable, not deleted, not archived —
    // archived ⟺ not present / defensive stamp). Archived and
    // deleted rows stay in `_data.medications`, so every save
    // from this screen still pushes the full list (see the
    // Medications card comment).
    final medDoc = MedicationDocument.fromRawRows(d.medications);
    final activeMedIndices = medDoc.activeIndices;
    final heightIn = d.heightCm == null ? null : (d.heightCm! / 2.54).round();
    final ft = heightIn == null ? null : heightIn ~/ 12;
    final inch = heightIn == null ? null : heightIn % 12;
    final weightLbs =
        d.weightKg == null ? null : (d.weightKg! * 2.20462).round();
    return [
      _sectionLabel('USER PROFILE'),
      _card([
        Row(
          children: [
            const Icon(Icons.face, color: NotelColors.primary, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Nickname',
                      style: TextStyle(
                          color: NotelColors.textPrimary,
                          // R49 SE7: explicit card-title size (was
                          // inherited), unified at 16.
                          fontSize: 16,
                          fontWeight: FontWeight.w500)),
                  Row(
                    children: [
                      Text(
                        d.nickname.isEmpty ? 'Not set' : d.nickname,
                        key: const ValueKey('nickname_value'),
                        style: TextStyle(
                            color: d.nickname.isEmpty
                                ? NotelColors.textSecondary
                                : NotelColors.primary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                      if (d.nickname.isNotEmpty && d.tag.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Text('#${d.tag}',
                            style: const TextStyle(
                                color: NotelColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            TextButton(
              key: const ValueKey('nickname_edit'),
              // R49 SE6/S2: 48dp button height (stock default is 40).
              style:
                  TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: _showNicknameDialog,
              child: const Text('Edit',
                  style: TextStyle(
                      color: NotelColors.textPrimary, fontSize: 12)),
            ),
          ],
        ),
      ]),
      const SizedBox(height: 16),
      _card([
        const Row(
          children: [
            Icon(Icons.person, color: NotelColors.primary, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Personal Health Profile',
                      style: TextStyle(
                          color: NotelColors.textPrimary,
                          // R49 SE7: explicit card-title size (was
                          // inherited), unified at 16.
                          fontSize: 16,
                          fontWeight: FontWeight.w500)),
                  Text('Fetched from Fitbit or manually updated',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (d.age != null && d.age! > 0)
          Text('Age: ${d.age}',
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 13)),
        if (heightIn != null && heightIn > 0)
          Text('Height: $ft\'$inch" ($heightIn in)',
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 13)),
        if (weightLbs != null && weightLbs > 0)
          Text('Weight: $weightLbs lbs',
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 13)),
        if (d.gender.isNotEmpty)
          Text('Gender: ${d.gender}',
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 13)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            key: const ValueKey('edit_profile_button'),
            style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.surfaceHigh,
                foregroundColor: NotelColors.textPrimary,
                // R49 SE6/S2: 48dp height (stock default is 40).
                minimumSize: const Size(64, 48)),
            onPressed: _showEditProfileDialog,
            child: const Text('Edit Profile',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            key: const ValueKey('auto_fill_button'),
            style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.surfaceHigh,
                foregroundColor: NotelColors.textPrimary,
                // R49 SE6/S2: 48dp height (stock default is 40).
                minimumSize: const Size(64, 48)),
            onPressed: _autoFillFromHealthConnect,
            icon: const Icon(Icons.sync, color: NotelColors.primary),
            label: const Text('Auto-Fill from Connected Apps'),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      // Medications (native :3029-3200): rows with the native date
      // range line + delete, and the Add Medication dialog (name,
      // started/ended free-text dates, Still taking). Native has no
      // in-place medication edit — changing an entry is delete + add
      // there too. Every change pushes the full list as the profile
      // `medications` JSON string, the exact SyncProfileRequest field
      // native's SyncManager sends (JotApi.kt:248).
      //
      // Round 44 (founder rule, supersedes the R39 profile
      // presentation): this list shows ACTIVE medications ONLY —
      // archived meds do not appear here at all (no "Ended: …"
      // rows, no Restore buttons; restore lives on the Tools →
      // Medications tab, unchanged). The filter is display-only:
      // it iterates [activeMedIndices] over the full document, so
      // `_data.medications` keeps every raw row and every save
      // from this screen (add/delete over the raw list, archive
      // via MedicationDocument splice-back) still pushes the full
      // list with hidden archived/deleted rows preserved.
      // When no med is active — even if archived meds exist —
      // the existing empty state below shows (no new copy).
      _card([
        const Text('Medications',
            style: TextStyle(
                color: NotelColors.textPrimary,
                // R49 SE7: same card-title role as the profile cards
                // above — explicit 16 (was inherited).
                fontSize: 16,
                fontWeight: FontWeight.w500)),
        const Text('Track your current medications',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 8),
        if (activeMedIndices.isEmpty)
          const Text(
              'No medications added yet. Tap the + button to add one manually.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 13))
        else
          ...activeMedIndices.map((rawIndex) {
            final m = d.medications[rawIndex];
            // Round 39 — classification goes through the shared
            // MedicationEntry model (the ONE synced source of
            // truth shared with the Tools Medications tab); only
            // active rows reach this map, so the range line is
            // always the Present form.
            final entry = medDoc.entryAt(rawIndex)!;
            final range = 'Started: ${entry.startDate} • Present';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${m['name'] ?? ''}',
                            style: const TextStyle(
                                color: NotelColors.textPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 14)),
                        Text(range,
                            style: const TextStyle(
                                color: NotelColors.textSecondary,
                                fontSize: 12)),
                      ],
                    ),
                  ),
                  // Vera R39 Finding 1: the archive button keys on
                  // the row's index in the FULL list (rawIndex, not
                  // its position among the visible active rows) and
                  // the handler targets that exact row — unique per
                  // rendered row even for id-less duplicate names.
                  // Archiving an active med here removes it from
                  // this list (Round 44 rule).
                  IconButton(
                    key: ValueKey('archive_medication_at_$rawIndex'),
                    icon: const Icon(Icons.archive,
                        size: 20, color: NotelColors.textSecondary),
                    tooltip: 'Archive',
                    onPressed: () => _archiveMedication(rawIndex),
                  ),
                  IconButton(
                    key: ValueKey('delete_medication_${m['id'] ?? ''}'),
                    icon: const Icon(Icons.delete,
                        size: 18, color: NotelColors.error),
                    onPressed: () => _deleteMedication('${m['id'] ?? ''}'),
                  ),
                ],
              ),
            );
          }),
        Align(
          alignment: Alignment.centerRight,
          child: FloatingActionButton.small(
            key: const ValueKey('add_medication_button'),
            backgroundColor: NotelColors.primary,
            onPressed: _showAddMedicationDialog,
            child: const Icon(Icons.add, color: Colors.white, size: 20),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      // Conditions (native :3202-3376): chips with remove, plus the
      // Add Condition catalog dialog. The profile push is the JSON
      // list of plain name strings native's ConditionRepository
      // persists (SyncManager.kt:430 sends it as `conditions`).
      _card([
        const Text('Conditions',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.w500)),
        const Text('Diagnosed or suspected conditions',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 8),
        if (d.conditions.isEmpty)
          const Text(
              'No conditions added yet. Tap the + button to search and add one.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 13))
        else
          Wrap(
            spacing: 8,
            children: d.conditions
                .map((c) => Chip(
                      key: ValueKey('condition_chip_${c['name'] ?? ''}'),
                      label: Text('${c['name'] ?? ''}'),
                      backgroundColor: NotelColors.surfaceHigh,
                      labelStyle:
                          const TextStyle(color: NotelColors.textPrimary),
                      onDeleted: () =>
                          _removeCondition('${c['name'] ?? ''}'),
                      deleteIconColor: NotelColors.error,
                    ))
                .toList(),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: FloatingActionButton.small(
            key: const ValueKey('add_condition_button'),
            backgroundColor: NotelColors.primary,
            onPressed: _showAddConditionDialog,
            child: const Icon(Icons.add, color: Colors.white, size: 20),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      // Privacy & Deletion (native :3378-3456)
      _card([
        InkWell(
          onTap: () =>
              setState(() => _privacyExpanded = !_privacyExpanded),
          child: const Row(
            children: [
              Icon(Icons.security, color: NotelColors.primary, size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Privacy & Deletion',
                        style: TextStyle(
                            color: NotelColors.textPrimary,
                            fontWeight: FontWeight.w500)),
                    Text('GDPR / CCPA compliance data deletion options',
                        style: TextStyle(
                            color: NotelColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              Icon(Icons.keyboard_arrow_down,
                  color: NotelColors.textSecondary),
            ],
          ),
        ),
        if (_privacyExpanded) ...[
          const SizedBox(height: 12),
          const Text(
              'You have the right to request deletion of all your sync information, logs, files, and credentials from our cloud servers and database permanently.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('delete_account_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    NotelColors.error.withValues(alpha: 0.15),
                foregroundColor: NotelColors.error,
              ),
              onPressed: _showDeleteAccountDialog,
              child: const Text('Permanently Delete Account & Data',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          if (_deleteError != null) ...[
            const SizedBox(height: 8),
            Text(_deleteError!,
                style: const TextStyle(
                    color: NotelColors.error, fontSize: 12)),
          ],
        ],
      ]),
    ];
  }

  Future<void> _showNicknameDialog() async {
    final controller = TextEditingController(text: _data.nickname);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: NotelColors.surface,
          title: const Text('Nickname',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('nickname_field'),
                controller: controller,
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: const InputDecoration(
                    hintText: 'Enter nickname...',
                    hintStyle: TextStyle(color: NotelColors.textSecondary)),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(error!,
                      style: const TextStyle(
                          color: NotelColors.error, fontSize: 11)),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: NotelColors.textPrimary)),
            ),
            TextButton(
              key: const ValueKey('nickname_save'),
              onPressed: () async {
                // Native validation (SettingsViewModel.kt:1509-1526).
                final trimmed =
                    controller.text.trim().replaceAll(RegExp(r'\s+'), ' ');
                if (trimmed.length < 2) {
                  setLocal(() => error =
                      'Nickname must be at least 2 characters');
                  return;
                }
                if (!RegExp(r'^[a-zA-Z ]+$').hasMatch(trimmed)) {
                  setLocal(() => error =
                      'Nickname can only contain letters and spaces');
                  return;
                }
                if (' '.allMatches(trimmed).length > 2) {
                  setLocal(() => error =
                      'Nickname can contain at most 2 spaces');
                  return;
                }
                final res = await _backend.updateNickname(trimmed);
                if (res != null && res['success'] == true) {
                  if (!mounted) return;
                  setState(() {
                    _data = _data.copyWith(
                      nickname: trimmed,
                      tag: res['tag']?.toString() ?? _data.tag,
                    );
                  });
                  if (ctx.mounted) Navigator.of(ctx).pop();
                } else {
                  setLocal(() => error =
                      res?['error']?.toString() ??
                          'Could not save nickname. Try again.');
                }
              },
              child: const Text('Save',
                  style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    // Not disposed here: the dialog's exit transition still builds
    // the field after showDialog returns (dispose-after-use crash).
  }

  Future<void> _showEditProfileDialog() async {
    final d = _data;
    final heightIn = d.heightCm == null ? 0 : (d.heightCm! / 2.54).round();
    final ageC = TextEditingController(
        text: (d.age != null && d.age! > 0) ? '${d.age}' : '');
    final genderC = TextEditingController(text: d.gender);
    final ftC = TextEditingController(
        text: heightIn > 0 ? '${heightIn ~/ 12}' : '');
    final inC = TextEditingController(
        text: heightIn > 0 ? '${heightIn % 12}' : '');
    final weightC = TextEditingController(
        text: d.weightKg != null
            ? '${(d.weightKg! * 2.20462).round()}'
            : '');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Edit Profile',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: ageC,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: NotelColors.textPrimary),
                  decoration: const InputDecoration(labelText: 'Age')),
              TextField(
                  controller: genderC,
                  style: const TextStyle(color: NotelColors.textPrimary),
                  decoration: const InputDecoration(labelText: 'Gender')),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: ftC,
                        keyboardType: TextInputType.number,
                        style:
                            const TextStyle(color: NotelColors.textPrimary),
                        decoration: const InputDecoration(
                            labelText: 'Height (ft)'))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: inC,
                        keyboardType: TextInputType.number,
                        style:
                            const TextStyle(color: NotelColors.textPrimary),
                        decoration: const InputDecoration(
                            labelText: 'Height (in)'))),
              ]),
              TextField(
                  controller: weightC,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: NotelColors.textPrimary),
                  decoration: const InputDecoration(labelText: 'Weight')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: const ValueKey('profile_save'),
            onPressed: () async {
              // Build the payload from ONLY the fields that are
              // non-blank and parseable (R29b Vera fix): the profile
              // push only protects keys that are omitted, so a blank
              // field must be left out entirely — coercing blanks to
              // age 0 / heightCm 0.0 / weightKg 0.0 / gender '' would
              // zero-clobber the server's real values whenever Save is
              // tapped after a failed pull (when every field renders
              // blank even though the server holds real data).
              final fields = <String, dynamic>{};
              final ageText = ageC.text.trim();
              final age = int.tryParse(ageText);
              if (ageText.isNotEmpty && age != null) {
                fields['age'] = age;
              }
              final ft = int.tryParse(ftC.text.trim());
              final inch = int.tryParse(inC.text.trim());
              double? heightCm;
              if (ft != null || inch != null) {
                heightCm = ((ft ?? 0) * 12 + (inch ?? 0)) * 2.54;
                fields['heightCm'] = heightCm;
              }
              final weightText = weightC.text.trim();
              final weightLbs = double.tryParse(weightText);
              double? weightKg;
              if (weightText.isNotEmpty && weightLbs != null) {
                weightKg = weightLbs / 2.20462;
                fields['weightKg'] = weightKg;
              }
              if (genderC.text.isNotEmpty) {
                fields['gender'] = genderC.text;
              }
              if (fields.isEmpty) {
                // Nothing parseable to save — make no call at all so
                // a failed-load Save can never touch the server copy.
                if (ctx.mounted) Navigator.of(ctx).pop();
                return;
              }
              // Native saveUserProfile (SettingsViewModel.kt:653-659):
              // DataStore + pushProfileData with cm/kg conversions.
              final ok = await _pushProfile(fields);
              if (ok && mounted) {
                setState(() {
                  _data = _data.copyWith(
                    age: fields.containsKey('age')
                        ? fields['age'] as int
                        : null,
                    heightCm: heightCm,
                    weightKg: weightKg,
                    gender: fields.containsKey('gender')
                        ? fields['gender'] as String
                        : null,
                  );
                });
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save',
                style: TextStyle(color: NotelColors.primary)),
          ),
        ],
      ),
    );
    // Controllers intentionally not disposed here — see nickname
    // dialog note (exit transition still builds the fields).
  }

  // ── Medications / Conditions / Auto-Fill (Round 30) ──────────────

  Future<bool> _saveMedications(List<Map<String, dynamic>> meds) async {
    final raw = jsonEncode(meds);
    setState(() => _data = _data.copyWith(medicationsRaw: raw));
    return await _pushProfile({'medications': raw});
  }

  /// Report-pdf fix (write-path audit, Oct 22, 2026) — the shared
  /// fresh-pull splice standard for EVERY medication mutation on
  /// this screen (the Tools Medications tab's `_mutateDoc`, Vera
  /// R48 F1; Lists/Notes/BP run the same discipline):
  ///
  /// 1. invalidate the cached pull and re-pull the FRESHEST
  ///    profile — a failed pull is a visible error + reload, and
  ///    NOTHING is pushed;
  /// 2. [splice] runs against the FRESH document and returns the
  ///    RAW ROWS to push, or null when its target cannot be
  ///    resolved unambiguously there — the op then REFUSES:
  ///    visible error, the fresh data is rendered, nothing is
  ///    pushed. Rows are raw (not a document encode) so each op
  ///    keeps its pre-fix payload shape byte-for-byte: add/delete
  ///    round-trip hidden rows verbatim (the R44 preservation
  ///    rule), and only archive — whose write IS the stamp —
  ///    returns document-encoded rows;
  /// 3. the spliced full list is saved through [_saveMedications].
  ///
  /// The pre-fix code spliced into `_data.medications` — this
  /// screen's LOAD-TIME snapshot — and pushed that stale list
  /// wholesale. The server stores the medications field whole
  /// (there is no per-row merge), so any whole-blob push built on
  /// a stale snapshot silently reverts every server-side change
  /// made after the screen loaded: a medication archived on
  /// another surface (or in the native app) resurrected as
  /// active, and a medication added there vanished. That is the
  /// exact shape of the Oct 22, 2026 server-blob evidence
  /// (escitalopram still `isPresent:true`, no desvenlafaxine row,
  /// minutes-old whole-list pushes carrying Sep 13 data).
  Future<void> _mutateMedications(
      List<Map<String, dynamic>>? Function(MedicationDocument fresh)
          splice) async {
    _backend.invalidateSyncPull();
    final body = await _backend.fetchSyncPull();
    if (body == null) {
      _snack('Could not save. Check your connection and try again.');
      await _reloadFromServer(reportLoadFailure: false);
      return;
    }
    final freshData = SettingsProfileData.fromPull(body);
    if (mounted) {
      setState(() => _data = freshData);
    } else {
      _data = freshData;
    }
    final fresh = MedicationDocument.fromRawRows(freshData.medications);
    final rows = splice(fresh);
    if (rows == null) {
      // Refused (target gone or ambiguous in the fresh data):
      // the fresh data stays rendered; never push, never claim
      // success.
      _snack('Could not save. Check your connection and try again.');
      return;
    }
    final saved = await _saveMedications(rows);
    if (saved) {
      // Phase 1 item 2a (spec §2.6): capture the change events
      // — ONLY now that the profile push has succeeded,
      // diffing the FRESH before-state against the pushed rows
      // (parsed back through the shared model; unparseable
      // rows ride through pushes verbatim and carry no fields
      // to diff). Emission is best-effort and cannot throw.
      // It is fired WITHOUT awaiting: this method's callers
      // dismiss their dialogs when it returns, and a
      // best-effort capture POST (20s transport timeout on a
      // dead connection) must never delay a completed save's
      // UI — the diff above is computed synchronously from the
      // fresh/pushed states either way.
      final afterEntries = <MedicationEntry>[];
      for (final row in rows) {
        final entry = MedicationEntry.fromBlobRow(row);
        if (entry != null) afterEntries.add(entry);
      }
      unawaited(emitMedicationChangeEvents(
        _backend,
        diffMedicationLists(
          before: fresh.entries,
          after: afterEntries,
          source: 'settings',
          now: DateTime.now(),
          idGen: generateMedicationUuid,
        ),
      ));
    }
  }

  /// The raw index [entry] occupies in [doc], or -1 — identity
  /// match over the document's aligned entries (the entry came
  /// from this document, via resolveFreshEntry).
  int _rawIndexOfEntry(MedicationDocument doc, MedicationEntry entry) {
    for (var i = 0; i < doc.length; i++) {
      if (identical(doc.entryAt(i), entry)) return i;
    }
    return -1;
  }

  Future<void> _deleteMedication(String id) async {
    // Native deleteMedication (SettingsViewModel.kt:976-989): drop
    // from the profile list and push the whole list — now spliced
    // into the FRESH list (see [_mutateMedications]): the rendered
    // row is re-resolved there by its id, never dropped out of
    // this screen's stale snapshot.
    final current = MedicationDocument.fromRawRows(_data.medications);
    MedicationEntry? target;
    for (final e in current.entries) {
      if (e.id == id) {
        target = e;
        break;
      }
    }
    if (target == null) {
      _snack('Could not save. Check your connection and try again.');
      return;
    }
    final rendered = target;
    await _mutateMedications((fresh) {
      final t = fresh.resolveFreshEntry(rendered);
      if (t == null) return null;
      final rawIndex = _rawIndexOfEntry(fresh, t);
      if (rawIndex < 0) return null;
      // Raw-row removal (the pre-fix delete's payload shape):
      // every other row — parseable or not — is pushed verbatim.
      return [
        for (var i = 0; i < fresh.rawRows.length; i++)
          if (i != rawIndex) fresh.rawRows[i],
      ];
    });
  }

  /// Round 39 — archive via the shared model (the same op the
  /// Tools Medications tab runs): archiving stamps the end date
  /// with today and flips `isPresent` off, native semantics.
  ///
  /// Vera R39 fix pass: [rawIndex] is the row's index in the full
  /// medications list — the op targets that exact row by position
  /// (Finding 1: no name/id first-match, so id-less duplicates
  /// can never stamp the wrong row).
  ///
  /// Report-pdf fix: the op now runs through [_mutateMedications]
  /// — the rendered entry is re-resolved in the FRESH document
  /// (identity → raw-index hint → unique id/composite, the shared
  /// [MedicationDocument.resolveFreshEntry] discipline) and the
  /// splice-back encode over the fresh rows retains unparseable
  /// rows verbatim and extra non-DTO keys (Finding 2), instead of
  /// stamping this screen's stale load-time snapshot and pushing
  /// it wholesale over newer server state.
  Future<void> _archiveMedication(int rawIndex) async {
    final rendered =
        MedicationDocument.fromRawRows(_data.medications).entryAt(rawIndex);
    if (rendered == null) {
      _snack('Could not save. Check your connection and try again.');
      return;
    }
    final now = DateTime.now();
    await _mutateMedications((fresh) {
      final t = fresh.resolveFreshEntry(rendered, rawIndexHint: rawIndex);
      if (t == null) return null;
      final updated = fresh.archiveEntry(t, now: now);
      // archiveEntry refuses by returning the same document —
      // treat that as this op's refusal too.
      if (identical(updated, fresh)) return null;
      return updated.encode();
    });
  }

  // Round 44: no unarchive/restore on this screen — archived
  // rows never render here (founder rule), so the R39
  // `_unarchiveMedication` handler was removed as dead code.
  // Restore stays available on the Tools → Medications tab.

  Future<void> _showAddMedicationDialog() async {
    final nameC = TextEditingController();
    final startC = TextEditingController();
    final endC = TextEditingController();
    var isPresent = true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: NotelColors.surface,
          title: const Text('Add Medication',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('medication_name_field'),
                  controller: nameC,
                  style: const TextStyle(color: NotelColors.textPrimary),
                  decoration:
                      const InputDecoration(labelText: 'Medication Name'),
                ),
                TextField(
                  key: const ValueKey('medication_start_field'),
                  controller: startC,
                  style: const TextStyle(color: NotelColors.textPrimary),
                  decoration: const InputDecoration(
                      labelText: 'Started Date (e.g. Jun 2026)'),
                ),
                Row(
                  children: [
                    Checkbox(
                      value: isPresent,
                      onChanged: (v) =>
                          setLocal(() => isPresent = v ?? true),
                    ),
                    const Text('Still taking (Present)',
                        style: TextStyle(
                            color: NotelColors.textPrimary, fontSize: 14)),
                  ],
                ),
                if (!isPresent)
                  TextField(
                    key: const ValueKey('medication_end_field'),
                    controller: endC,
                    style: const TextStyle(color: NotelColors.textPrimary),
                    decoration: const InputDecoration(
                        labelText: 'Ended Date (e.g. Jul 2026)'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: NotelColors.textSecondary)),
            ),
            TextButton(
              key: const ValueKey('medication_add'),
              onPressed: () async {
                final name = nameC.text.trim();
                if (name.isEmpty) return;
                // Native addMedication (SettingsViewModel.kt:948-974):
                // UUID id, endDate "Present" while still taking, dose /
                // frequency defaults from the Medication DTO.
                final now = DateTime.now();
                final med = <String, dynamic>{
                  'id': '${now.microsecondsSinceEpoch}',
                  'name': name,
                  'startDate': startC.text.trim(),
                  'endDate': isPresent ? 'Present' : endC.text.trim(),
                  'isPresent': isPresent,
                  'dose': 'As prescribed',
                  'frequency': 'Daily',
                  'updatedAt': now.millisecondsSinceEpoch,
                  'isDeleted': false,
                };
                // Report-pdf fix: append to the FRESH list (see
                // _mutateMedications) — appending to this screen's
                // load-time snapshot and pushing it wholesale
                // would revert any server-side change made since
                // the screen loaded.
                await _mutateMedications(
                    (fresh) => [...fresh.rawRows, med]);
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Add',
                  style: TextStyle(color: NotelColors.primary)),
            ),
          ],
        ),
      ),
    );
    // Controllers intentionally not disposed — see nickname dialog note.
  }

  List<String> get _conditionNames =>
      _data.conditions.map((c) => '${c['name'] ?? ''}').toList();

  Future<void> _saveConditions(List<String> names) async {
    // ConditionRepository.normalizeList: trim, drop blanks, dedupe
    // case-insensitively keeping the first spelling.
    final out = <String>[];
    for (final n in names) {
      final t = n.trim();
      if (t.isEmpty) continue;
      if (out.any((e) => e.toLowerCase() == t.toLowerCase())) continue;
      out.add(t);
    }
    final raw = jsonEncode(out);
    setState(() => _data = _data.copyWith(conditionsRaw: raw));
    await _pushProfile({'conditions': raw});
  }

  Future<void> _removeCondition(String name) async {
    await _saveConditions(
        _conditionNames.where((n) => n != name).toList());
  }

  Future<void> _showAddConditionDialog() async {
    final searchC = TextEditingController();
    var query = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final added = _conditionNames;
          final filtered = query.isEmpty
              ? commonConditions
              : commonConditions
                  .where((c) =>
                      c.toLowerCase().contains(query.toLowerCase()))
                  .toList();
          return AlertDialog(
            backgroundColor: NotelColors.surface,
            title: const Text('Add Condition',
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: double.maxFinite,
              height: 350,
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('condition_search_field'),
                    controller: searchC,
                    style: const TextStyle(color: NotelColors.textPrimary),
                    decoration: const InputDecoration(
                        labelText: 'Search Conditions'),
                    onChanged: (v) => setLocal(() => query = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final name = filtered[i];
                        final isAdded = added.contains(name);
                        return ListTile(
                          key: ValueKey('condition_option_$name'),
                          title: Text(name,
                              style: const TextStyle(
                                  color: NotelColors.textPrimary,
                                  // R49 preservation: ListTile titles
                                  // inherit theme titleMedium, which R49
                                  // made bold; w500 preserves the
                                  // pre-round weight of this picker.
                                  fontWeight: FontWeight.w500,
                                  fontSize: 13)),
                          trailing: isAdded
                              ? const Icon(Icons.check,
                                  color: NotelColors.primary, size: 18)
                              : null,
                          onTap: () async {
                            // Native toggles the condition in place and
                            // each change syncs immediately.
                            if (isAdded) {
                              await _removeCondition(name);
                            } else {
                              await _saveConditions(
                                  [..._conditionNames, name]);
                            }
                            setLocal(() {});
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                key: const ValueKey('condition_done'),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done',
                    style: TextStyle(color: NotelColors.primary)),
              ),
            ],
          );
        },
      ),
    );
    // Controller intentionally not disposed — see nickname dialog note.
  }

  /// Native `syncHealthProfile` (SettingsViewModel.kt:665-694): read
  /// the latest Health Connect weight/height, round to whole pounds /
  /// inches exactly as native does, keep age/gender as they are, and
  /// save through the same profile push as Edit Profile. When Health
  /// Connect holds neither value, nothing is saved and the user is
  /// told plainly.
  Future<void> _autoFillFromHealthConnect() async {
    final hc = widget.healthConnectService ?? HealthConnectService();
    double? weightKg;
    double? heightCm;
    try {
      weightKg = await hc.readLatestWeightKg();
    } catch (_) {
      weightKg = null;
    }
    try {
      heightCm = await hc.readLatestHeightCm();
    } catch (_) {
      heightCm = null;
    }
    if (!mounted) return;
    if ((weightKg == null || weightKg <= 0) &&
        (heightCm == null || heightCm <= 0)) {
      final code = hc.lastReadErrorCode;
      _snack(code != null
          ? 'Could not read Health Connect data [$code]'
          : 'No weight or height found in Health Connect yet.');
      return;
    }
    final fields = <String, dynamic>{};
    double? newWeightKg;
    double? newHeightCm;
    if (weightKg != null && weightKg > 0) {
      // Native rounds the HC value to whole pounds before saving.
      newWeightKg = (weightKg * 2.20462).round() / 2.20462;
      fields['weightKg'] = newWeightKg;
    }
    if (heightCm != null && heightCm > 0) {
      // Native rounds the HC value to whole inches before saving.
      newHeightCm = (heightCm / 2.54).round() * 2.54;
      fields['heightCm'] = newHeightCm;
    }
    final ok = await _pushProfile(fields);
    if (ok && mounted) {
      setState(() => _data =
          _data.copyWith(weightKg: newWeightKg, heightCm: newHeightCm));
      _snack('Profile updated from Health Connect.');
    }
  }

  // ── Physician Protocols / Knowledge Base editors (Round 30) ──────
  //
  // Both lists are plain profile strings joined by "\n\n" in native
  // (SettingsViewModel.editProfessionalUpdate / deleteProfessionalUpdate
  // :790-817, editKnowledgeItem :767-777, LogRepository
  // .deleteKnowledgeItem), pushed through POST /api/sync/profile.
  // The Room/Gemini ingestion pipeline (file upload, text-note
  // extraction) stays native-only and is NOT emulated here.

  String get _professionalType {
    final ctx = _data.userContext.toLowerCase();
    final kb = _data.knowledgeBase.toLowerCase();
    if (ctx.contains('doctor') ||
        ctx.contains('dr.') ||
        kb.contains('doctor') ||
        kb.contains('dr.')) {
      return 'Doctor';
    }
    if (ctx.contains('coach') || kb.contains('coach')) return 'Coach';
    if (ctx.contains('therapist') || kb.contains('therapist')) {
      return 'Therapist';
    }
    return 'Professional';
  }

  /// Native showProfessionalCheckIn gate (SettingsViewModel.kt
  /// :324-345) also scans log entries; the Flutter gate uses the two
  /// profile texts, which are the parts this screen owns.
  bool get _professionalGate {
    const keywords = [
      'doctor', 'dr.', 'coach', 'physician', 'therapist', 'running',
      'marathon', 'race', 'training',
    ];
    final ctx = _data.userContext.toLowerCase();
    final kb = _data.knowledgeBase.toLowerCase();
    return keywords.any((k) => ctx.contains(k) || kb.contains(k));
  }

  Future<void> _saveProfessionalUpdates(List<String> updates) async {
    final raw = updates.join('\n\n');
    setState(() => _data = _data.copyWith(professionalUpdates: raw));
    await _pushProfile({'professionalUpdates': raw});
  }

  Future<void> _saveKnowledgeBase(List<String> facts) async {
    final raw = facts.join('\n\n');
    setState(() => _data = _data.copyWith(knowledgeBase: raw));
    await _pushProfile({'knowledgeBase': raw});
  }

  // ── Round 65 — Digital Knowledge Extraction flows ─────────────
  //
  // Native order (LogRepository.ingestDocumentFile): the document
  // is SAVED first (here: verified server save through
  // KnowledgeDocumentService), extraction runs after; a failed
  // extraction leaves the document listed with an honest failed
  // state — never a fake "AI read".

  /// Native backfill: extract every listed document that has no
  /// cached text yet, one at a time, refreshing the tiles as each
  /// lands. Failures land in the store as the failed state.
  Future<void> _backfillKnowledgeDocs() async {
    for (final doc in _data.documents) {
      if (_kStore.stateFor(doc.id) == KnowledgeExtractionState.ready) {
        continue;
      }
      // Docfix: 'empty' is terminal for AUTO-backfill — extraction
      // already ran successfully and found no readable text; only
      // a manual retry from the viewer re-runs it.
      if (_kStore.stateFor(doc.id) == KnowledgeExtractionState.empty) {
        continue;
      }
      if (_kBusyDocs.contains(doc.id)) continue;
      _kBusyDocs.add(doc.id);
      try {
        await _kService.backfill(doc);
      } catch (_) {
        await _kStore.markFailed(doc.id);
      } finally {
        _kBusyDocs.remove(doc.id);
      }
      if (!mounted) return;
      setState(() {});
    }
  }

  Future<void> _refreshDocumentsFromPull() async {
    try {
      final docs = await _kService.freshDocuments();
      if (!mounted) return;
      setState(() => _data = _data.copyWith(documents: docs));
    } on KnowledgeSyncException {
      rethrow;
    }
  }

  /// "Select Document / PDF" (native ingestFile → ingestDocumentFile).
  Future<void> _pickAndAddDocument() async {
    setState(() => _kError = null);
    PickedKnowledgeFile? picked;
    try {
      picked = await _kPicker.pickDocument();
    } on KnowledgePickException catch (e) {
      if (!mounted) return;
      setState(() => _kError =
          '${e.message ?? "Couldn't open the file picker."} [${e.code}]');
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _kError = "Couldn't open the file picker. [UNKNOWN]");
      return;
    }
    if (picked == null || !mounted) return; // user cancelled
    setState(() => _kProcessing = true);
    try {
      final doc = await _kService.addDocument(
        name: picked.name,
        mimeType: picked.mimeType,
        base64Data: picked.base64Data,
      );
      await _refreshDocumentsFromPull();
      if (!mounted) return;
      setState(() => _kProcessing = false);
      // Extraction after the verified save, like native's
      // background extraction task.
      _kBusyDocs.add(doc.id);
      final state = await _kService.extractFromBytes(doc, picked.base64Data);
      _kBusyDocs.remove(doc.id);
      if (!mounted) return;
      setState(() {
        if (state == KnowledgeExtractionState.failed) {
          _kError =
              'Saved, but Gemini could not extract text from ${doc.name}. You can retry from the document list.';
        }
      });
    } on KnowledgeSyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _kProcessing = false;
        _kError = 'Could not save the document. [${e.code}]';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _kProcessing = false;
        _kError = 'Could not save the document. [UNKNOWN]';
      });
    }
  }

  /// "Add Text Note" dialog (native copy): Title (Optional) +
  /// "Note content / Text message", Process saves the note as a
  /// text/plain document (native ingestTextNote) and extracts it —
  /// for plain text the extraction call transcribes the note
  /// itself, exactly as native's process-document call does.
  Future<void> _showTextNoteDialog() async {
    final titleC = TextEditingController();
    final bodyC = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: NotelColors.surface,
          title: const Text('Add Text Note',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('note_title_field'),
                controller: titleC,
                onChanged: (_) => setLocal(() {}),
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration:
                    const InputDecoration(labelText: 'Title (Optional)'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('note_body_field'),
                controller: bodyC,
                minLines: 3,
                maxLines: 6,
                onChanged: (_) => setLocal(() {}),
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: const InputDecoration(
                    labelText: 'Note content / Text message'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: NotelColors.textSecondary)),
            ),
            TextButton(
              key: const ValueKey('note_process_button'),
              onPressed: bodyC.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(),
              child: const Text('Process',
                  style: TextStyle(color: NotelColors.primary)),
            ),
          ],
        ),
      ),
    );
    final body = bodyC.text;
    final title = titleC.text.trim().isEmpty ? 'Text Note' : titleC.text.trim();
    // Controllers intentionally not disposed — the dialog's exit
    // animation still rebuilds its fields (see the nickname
    // dialog note at _showEditJoinedEntryDialog).
    if (body.trim().isEmpty || !mounted) return;
    setState(() {
      _kError = null;
      _kProcessing = true;
    });
    try {
      final b64 = base64Encode(utf8.encode(body));
      final doc = await _kService.addDocument(
        name: title,
        mimeType: 'text/plain',
        base64Data: b64,
      );
      await _refreshDocumentsFromPull();
      if (!mounted) return;
      setState(() => _kProcessing = false);
      _kBusyDocs.add(doc.id);
      final state = await _kService.extractFromBytes(doc, b64);
      _kBusyDocs.remove(doc.id);
      if (!mounted) return;
      setState(() {
        if (state == KnowledgeExtractionState.failed) {
          _kError =
              'Saved, but Gemini could not extract text from $title. You can retry from the document list.';
        }
      });
    } on KnowledgeSyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _kProcessing = false;
        _kError = 'Could not save the note. [${e.code}]';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _kProcessing = false;
        _kError = 'Could not save the note. [UNKNOWN]';
      });
    }
  }

  Future<void> _retryExtraction(KnowledgeDocumentMeta doc) async {
    if (_kBusyDocs.contains(doc.id)) return;
    setState(() {
      _kError = null;
      _kBusyDocs.add(doc.id);
    });
    try {
      // Clear the failed marker by attempting fresh: backfill goes
      // through the server file data like native's retry path.
      // force: a manual retry also re-runs an 'empty' doc.
      final state = await _kService.backfill(doc, force: true);
      if (!mounted) return;
      setState(() {
        if (state == KnowledgeExtractionState.failed) {
          _kError =
              'Gemini could not extract text from ${doc.name}. [EXTRACTION_FAILED]';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _kError =
          'Gemini could not extract text from ${doc.name}. [EXTRACTION_FAILED]');
    } finally {
      _kBusyDocs.remove(doc.id);
      if (mounted) setState(() {});
    }
  }

  /// Per-document delete (native DocumentTile confirm dialog).
  Future<void> _confirmDeleteDocument(KnowledgeDocumentMeta doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Trash File?',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Text(
            "Are you sure you want to permanently delete '${doc.name}'?",
            style: const TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: ValueKey('confirm_delete_doc_${doc.id}'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(
                    color: NotelColors.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _kService.deleteDocument(doc.id);
      await _refreshDocumentsFromPull();
      if (!mounted) return;
      setState(() => _kError = null);
    } on KnowledgeSyncException catch (e) {
      if (!mounted) return;
      setState(
          () => _kError = 'Could not delete ${doc.name}. [${e.code}]');
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _kError = 'Could not delete ${doc.name}. [UNKNOWN]');
    }
  }

  /// "Clear All Files" (native confirm dialog copy).
  Future<void> _confirmClearAllDocuments() async {
    final docs = _data.documents;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Clear All Files?',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Text(
            'This will permanently delete all ${docs.length} uploaded files. This cannot be undone.',
            style: const TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: const ValueKey('confirm_clear_all_docs'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete All',
                style: TextStyle(
                    color: NotelColors.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _kService.clearAllDocuments();
      await _refreshDocumentsFromPull();
      if (!mounted) return;
      setState(() => _kError = null);
    } on KnowledgeSyncException catch (e) {
      if (!mounted) return;
      setState(() => _kError = 'Could not clear all files. [${e.code}]');
    } catch (_) {
      if (!mounted) return;
      setState(() => _kError = 'Could not clear all files. [UNKNOWN]');
    }
  }

  /// The document viewer (native FileViewerScreen): file name, the
  /// honest preview for the MIME family, and the AI Extracted
  /// Content panel with its states and the extracted-text editor.
  /// PDF raster preview is native PdfRenderer — no Dart/bridge
  /// equivalent exists in this app, so PDFs show native's own
  /// fallback line for unpreviewable types plus the extracted
  /// panel (see the round report's STOPPED item).
  Future<void> _openDocument(KnowledgeDocumentMeta doc) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final state = _kStore.stateFor(doc.id);
          final text = _kStore.textFor(doc.id);
          return AlertDialog(
            key: ValueKey('doc_viewer_${doc.id}'),
            backgroundColor: NotelColors.surface,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(doc.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: NotelColors.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
                if (state == KnowledgeExtractionState.ready)
                  const Text('AI read · tap below to view or edit',
                      style: TextStyle(
                          color: NotelColors.success, fontSize: 10)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (doc.mimeType == 'text/plain')
                    FutureBuilder<String?>(
                      future: _backend.fetchDocumentData(doc.id),
                      builder: (ctx2, snap) {
                        final raw = snap.data;
                        String shown;
                        if (raw != null) {
                          try {
                            shown = utf8.decode(base64Decode(raw));
                          } catch (_) {
                            shown = 'Could not read file.';
                          }
                        } else if (snap.connectionState ==
                            ConnectionState.done) {
                          shown = 'Could not read file.';
                        } else {
                          shown = '';
                        }
                        return Text(shown,
                            style: const TextStyle(
                                color: NotelColors.textSecondary,
                                fontSize: 13,
                                height: 1.5));
                      },
                    )
                  else if (doc.mimeType.startsWith('image/'))
                    FutureBuilder<String?>(
                      future: _backend.fetchDocumentData(doc.id),
                      builder: (ctx2, snap) {
                        final raw = snap.data;
                        if (raw == null) {
                          return const Text('Preview not available for this file type.',
                              style: TextStyle(
                                  color: NotelColors.textSecondary));
                        }
                        try {
                          return Image.memory(base64Decode(raw),
                              fit: BoxFit.contain);
                        } catch (_) {
                          return const Text('Preview not available for this file type.',
                              style: TextStyle(
                                  color: NotelColors.textSecondary));
                        }
                      },
                    )
                  else ...[
                    const Text('Preview not available for this file type.',
                        style:
                            TextStyle(color: NotelColors.textSecondary)),
                    Text('Type: ${doc.mimeType}',
                        style: const TextStyle(
                            color: NotelColors.textSecondary,
                            fontSize: 12)),
                  ],
                  const SizedBox(height: 16),
                  const Row(
                    children: [
                      Icon(Icons.auto_awesome,
                          color: NotelColors.primary, size: 18),
                      SizedBox(width: 8),
                      Text('AI Extracted Content',
                          style: TextStyle(
                              color: NotelColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    switch (state) {
                      KnowledgeExtractionState.ready =>
                        '${text?.length ?? 0} characters extracted',
                      KnowledgeExtractionState.failed =>
                        'No content could be extracted',
                      KnowledgeExtractionState.empty =>
                        'No readable text was found',
                      KnowledgeExtractionState.pending =>
                        'Processing… check back shortly',
                    },
                    style: TextStyle(
                        color: state == KnowledgeExtractionState.ready
                            ? NotelColors.success
                            : NotelColors.textSecondary,
                        fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  if (state == KnowledgeExtractionState.pending) ...[
                    const Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: NotelColors.primary),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Gemini is reading this file…',
                                  style: TextStyle(
                                      color: NotelColors.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500)),
                              Text(
                                  'This happens once. Pull down to refresh after a moment.',
                                  style: TextStyle(
                                      color: NotelColors.textSecondary,
                                      fontSize: 11)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      key: ValueKey('doc_extract_now_${doc.id}'),
                      onPressed: () async {
                        await _retryExtraction(doc);
                        setLocal(() {});
                      },
                      child: const Text('Extract now',
                          style: TextStyle(color: NotelColors.primary)),
                    ),
                  ] else if (state == KnowledgeExtractionState.failed) ...[
                    const Text(
                        'Gemini could not complete extraction for this file. Try again.',
                        style:
                            TextStyle(color: NotelColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 8),
                    TextButton(
                      key: ValueKey('doc_retry_extract_${doc.id}'),
                      onPressed: () async {
                        await _retryExtraction(doc);
                        setLocal(() {});
                      },
                      child: const Text('Retry extraction',
                          style: TextStyle(color: NotelColors.primary)),
                    ),
                  ] else if (state == KnowledgeExtractionState.empty) ...[
                    // Juno-ruled EMPTY copy, verbatim, with NO
                    // error-code suffix. Manually retryable.
                    const Text(
                        'Gemini read this file and found no readable text in it.',
                        style:
                            TextStyle(color: NotelColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 8),
                    TextButton(
                      key: ValueKey('doc_retry_extract_${doc.id}'),
                      onPressed: () async {
                        await _retryExtraction(doc);
                        setLocal(() {});
                      },
                      child: const Text('Retry extraction',
                          style: TextStyle(color: NotelColors.primary)),
                    ),
                  ] else ...[
                    Text(text ?? '',
                        key: ValueKey('doc_extracted_text_${doc.id}'),
                        style: const TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 13,
                            height: 1.4)),
                  ],
                ],
              ),
            ),
            actions: [
              if (state == KnowledgeExtractionState.ready)
                TextButton(
                  key: ValueKey('doc_edit_extract_${doc.id}'),
                  onPressed: () async {
                    final editC =
                        TextEditingController(text: text ?? '');
                    final saved = await showDialog<bool>(
                      context: ctx,
                      builder: (ectx) => AlertDialog(
                        backgroundColor: NotelColors.surface,
                        title: const Text('Edit extracted text',
                            style: TextStyle(
                                color: NotelColors.textPrimary,
                                fontWeight: FontWeight.bold)),
                        content: TextField(
                          key: ValueKey('doc_edit_field_${doc.id}'),
                          controller: editC,
                          minLines: 4,
                          maxLines: 10,
                          style: const TextStyle(
                              color: NotelColors.textPrimary),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(ectx).pop(false),
                            child: const Text('Cancel',
                                style: TextStyle(
                                    color: NotelColors.textSecondary)),
                          ),
                          TextButton(
                            key: ValueKey('doc_edit_save_${doc.id}'),
                            onPressed: () =>
                                Navigator.of(ectx).pop(true),
                            child: const Text('Save',
                                style: TextStyle(
                                    color: NotelColors.primary)),
                          ),
                        ],
                      ),
                    );
                    if (saved == true) {
                      await _kStore.saveEditedText(doc.id, editC.text);
                      setLocal(() {});
                      if (mounted) setState(() {});
                    }
                    // Controller intentionally not disposed (exit
                    // animation rebuilds the field — see above).
                  },
                  child: const Text('Edit',
                      style: TextStyle(color: NotelColors.primary)),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close',
                    style: TextStyle(color: NotelColors.textSecondary)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showAddUpdateDialog() async {
    final noteC = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('New Clinical Protocol',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: TextField(
          key: const ValueKey('protocol_note_field'),
          controller: noteC,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(color: NotelColors.textPrimary),
          decoration: const InputDecoration(labelText: 'What did they say?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: const ValueKey('protocol_save'),
            onPressed: () async {
              final note = noteC.text.trim();
              if (note.isEmpty) return;
              // Native addProfessionalUpdate (:779-788): prepend
              // "From the <Type> (<MMM dd, yyyy>): <note>".
              const months = [
                'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
              ];
              final now = DateTime.now();
              final dateStr =
                  '${months[now.month - 1]} ${now.day.toString().padLeft(2, '0')}, ${now.year}';
              final entry = 'From the $_professionalType ($dateStr): $note';
              final current = _data.professionalUpdates
                  .split('\n\n')
                  .where((s) => s.trim().isNotEmpty)
                  .toList();
              await _saveProfessionalUpdates([entry, ...current]);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save Update',
                style: TextStyle(color: NotelColors.primary)),
          ),
        ],
      ),
    );
    // Controller intentionally not disposed — see nickname dialog note.
  }

  Future<void> _showEditJoinedEntryDialog({
    required String title,
    required String initial,
    required void Function(String text) onSave,
    required String fieldKey,
    required String saveKey,
  }) async {
    final c = TextEditingController(text: initial);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: Text(title,
            style: const TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: TextField(
          key: ValueKey(fieldKey),
          controller: c,
          minLines: 2,
          maxLines: 5,
          style: const TextStyle(color: NotelColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: ValueKey(saveKey),
            onPressed: () async {
              final text = c.text.trim();
              if (text.isEmpty) return;
              onSave(text);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save',
                style: TextStyle(color: NotelColors.primary)),
          ),
        ],
      ),
    );
    // Controller intentionally not disposed — see nickname dialog note.
  }

  // ── CUSTOMIZE (native :1215-1292) ────────────────────────────────

  List<Widget> _customizePage() {
    return [
      _sectionLabel('NAVIGATION & APPEARANCE'),
      _card([
        _toggleRow(
          'Show Navigation Bar Labels',
          'Display text under icons in bottom navigation banner',
          _showNavLabels,
          (v) async {
            setState(() => _showNavLabels = v);
            await _store.setShowNavLabels(v);
          },
          key: const ValueKey('nav_labels_toggle'),
        ),
        // Round 30: the dock consumes this preference now (MainShell
        // passes it to NavDock, which renders native's labeled
        // geometry) — the R29b honesty note is retired because the
        // statement is true.
      ]),
      const SizedBox(height: 12),
      _card([
        const Text('Appearance',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14)),
        const SizedBox(height: 2),
        // Juno ruling (Oct 2026, verbatim copy): the picker is
        // disabled below, so the subtitle states the one appearance
        // that exists instead of offering a choice.
        const Text('Tabs currently uses the dark appearance.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
        const SizedBox(height: 10),
        // Juno ruling (Oct 2026): this picker renders DISABLED.
        // An interactive control is itself a claim — with no light
        // theme in the app (main.dart builds only notelDarkTheme()
        // and screens use dark NotelColors literals throughout) a
        // tappable Light/System choice would mislead: taps used to
        // save a selection nothing ever applied. So: taps do
        // nothing and write NOTHING (the setThemeMode write on tap
        // is removed), and Dark — the appearance actually in
        // effect — is always the shown selection, regardless of
        // any previously stored value (a stored LIGHT/SYSTEM is
        // left untouched in the store, just never presented as in
        // effect). Re-enabling waits on a real light theme
        // verified on device — a future package, not this one.
        Row(
          children: [
            for (final (mode, label) in const [
              ('LIGHT', 'Light'),
              ('DARK', 'Dark'),
              ('SYSTEM', 'System'),
            ])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ElevatedButton(
                    key: ValueKey('theme_$mode'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: mode == 'DARK'
                          ? NotelColors.primary
                          : NotelColors.surfaceHigh,
                      foregroundColor: mode == 'DARK'
                          ? Colors.white
                          : NotelColors.textSecondary,
                      // Disabled-state colors pinned to the same
                      // values, so the disabled row still reads as
                      // "Dark is current" instead of washing out.
                      disabledBackgroundColor: mode == 'DARK'
                          ? NotelColors.primary
                          : NotelColors.surfaceHigh,
                      disabledForegroundColor: mode == 'DARK'
                          ? Colors.white
                          : NotelColors.textSecondary,
                    ),
                    onPressed: null,
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: mode == 'DARK'
                                ? FontWeight.bold
                                : FontWeight.w500)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // Juno ruling (Oct 2026, verbatim copy) — replaces the
        // Lab-era caption that claimed the choice was saved.
        const Text(
            'Appearance cannot be changed right now. Tabs includes only the dark appearance.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
      ]),
    ];
  }

  // ── CONNECTED APPS (native :2240-2710) ───────────────────────────

  List<Widget> _connectedAppsPage() {
    return [
      _sectionLabel('LOCAL CONNECTIONS'),
      // Round 51 — this row used to be STATIC: it rendered the
      // not-connected card unconditionally and never read Health
      // Connect state at all, so it showed "Connect Health Data"
      // while Home (same bridge, real getStatus()) showed live
      // data. It now binds _hcStatus, native presentation
      // (SettingsScreen.kt:2251-2281): connected → the Active
      // card with NO connect CTA; partially connected → the
      // grant-remaining presentation the Data Connections screen
      // uses; not connected / unavailable / still loading → the
      // connect card + CTA, which opens the shared Data
      // Connections flow. A bridge failure adds the visible
      // [CODE] line (Home parity).
      _card([
        if (_hcStatus == HealthConnectStatus.connected) ...[
          const Row(
            children: [
              Icon(Icons.favorite, color: NotelColors.primary, size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Health Connect Active',
                        style: TextStyle(
                            color: NotelColors.textPrimary,
                            fontWeight: FontWeight.w500)),
                    Text('Live synchronization active',
                        style: TextStyle(
                            color: NotelColors.textSecondary,
                            fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('• Connected to local device sensors',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 13)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('open_connections'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.surfaceHigh,
                  foregroundColor: NotelColors.textPrimary),
              onPressed: _openConnections,
              child: const Text('Manage Health Connect',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ] else if (_hcStatus ==
            HealthConnectStatus.partiallyConnected) ...[
          const Text('Google Health Connect',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.w500)),
          const Text('Partially connected',
              style: TextStyle(
                  color: NotelColors.warning, fontSize: 12)),
          const SizedBox(height: 4),
          // HRV grant visibility: when the missing set is known,
          // NAME the data types that are not shared and give the
          // exact remedy (HealthConnectService.missingPermissionsMessage,
          // STALE_GRANT copy pattern — plain language, no codes);
          // the generic line stays as the fallback when it is not.
          if (_hcMissingLabels.isNotEmpty)
            Text(
                HealthConnectService.missingPermissionsMessage(
                    _hcMissingLabels),
                style: const TextStyle(
                    color: NotelColors.textSecondary, fontSize: 12))
          else
            const Text(
                'Some health permissions are still missing. Grant the remaining permissions to sync everything.',
                style: TextStyle(
                    color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('open_connections'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white),
              onPressed: _openConnections,
              child: const Text('Grant New Permissions',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ] else ...[
          const Text('Google Health Connect',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.w500)),
          const Text('Connect to grab data from Garmin, Oura, Fitbit and more.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('open_connections'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white),
              onPressed: _openConnections,
              child: const Text('Connect Health Data',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
        if (_hcErrorCode != null) ...[
          const SizedBox(height: 8),
          Text('Health Connect status check failed [$_hcErrorCode].',
              style:
                  const TextStyle(color: NotelColors.error, fontSize: 12)),
        ],
        // Defect 1b — diagnostics line: the last capture's HRV
        // outcome (counts + any code) from the persisted capture
        // diagnostics, so a missing-HRV recurrence is diagnosable
        // from this one screenshot. Counts are operational
        // metadata, not health values; codes ride in brackets like
        // the status-check line above.
        if (_hrvDiag != null) ...[
          const SizedBox(height: 8),
          Text(_hrvDiagnosticsLine(_hrvDiag!),
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 12)),
        ],
      ]),
      const SizedBox(height: 24),
      _sectionLabel('DAILY SCORE'),
      // Founder amendment #2 — the background-scoring enablement
      // surface. The background read grant lives ONLY in Health
      // Connect settings (it is never in the runtime request set),
      // so this card explains it and hands off there; Tabs itself
      // never prompts for it. Copy is Juno-final (correction
      // round): the strings make NO claim that background Health
      // Connect checking works on device today, and the unknown
      // grant state (MF-10: not yet read, or the read threw)
      // renders a neutral checking line — no grant claim and no
      // enablement button until the state is known.
      _card([
        const Text('Daily Score in the Background',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        if (_bgScoreAccess == true)
          const Text(
              'Background access is on. Tabs can work on your Daily Score in the background a few times a day at most, and Android may delay that work to save battery. When a background run creates a new Daily Score, Tabs can notify you if notifications are turned on for Tabs.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 12))
        else if (_bgScoreAccess == false)
          const Text(
              'Tabs can build your Daily Score in the background, so a score may be ready even on days you do not open the app. Android may delay background work to save battery, so a score is not guaranteed by a set time. To allow it, tap Open Health Connect Settings below, then tap Tabs, App permissions, Additional access, and turn on Background access.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 12))
        else
          const Text('Checking background access…',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        if (_bgScoreAccess == false) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('open_hc_settings_background'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.surfaceHigh,
                  foregroundColor: NotelColors.textPrimary),
              onPressed: _openHcSettingsForBackground,
              child: const Text('Open Health Connect Settings',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 24),
      _sectionLabel('INTEGRATED APPS'),
      _card([
        // Google Calendar (native :2293-2360): native's connect is a
        // Google sign-in chooser whose returned account email is
        // stored LOCALLY (SettingsViewModel.connectGoogleCalendar,
        // SettingsViewModel.kt:204-209) — native requests NO Calendar
        // API scope and makes NO server call for this row; the flag
        // only gates the AI coach's calendar features
        // (CoachViewModel.kt:1354, :1463). Mirrored exactly: no new
        // OAuth scope is requested here.
        if (_gCalConnected) ...[
          const Text('Google Calendar Active',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.w500)),
          Text('Connected as $_gCalEmail',
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('disconnect_calendar_button'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.surfaceHigh,
                  foregroundColor: NotelColors.textPrimary),
              onPressed: _disconnectGoogleCalendar,
              child: const Text('Disconnect Google Calendar',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ] else ...[
          const Text('Google Calendar',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.w500)),
          const Text(
              'Let your AI Clinical Advocate schedule events and update calendars.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const ValueKey('connect_calendar_button'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.surfaceHigh,
                  foregroundColor: NotelColors.textPrimary),
              onPressed: _showCalendarConnectDisclosure,
              icon: Image.asset('assets/images/ic_google_logo.png',
                  width: 20, height: 20),
              label: const Text('Connect Google Calendar',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
        const SizedBox(height: 20),
        // Google Account (native :2362-2710 + SettingsViewModel
        // .connectGoogleAccount :218-241): sign-in chooser, then the
        // ID token goes to POST /api/auth/link-google; local state
        // flips ONLY on the server's success (fail closed).
        if (_gAccountConnected) ...[
          const Text('Google Account Connected',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.w500)),
          Text('Connected as $_gAccountEmail',
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('disconnect_google_button'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.surfaceHigh,
                  foregroundColor: NotelColors.textPrimary),
              onPressed: _showDisconnectGoogleDialog,
              child: const Text('Disconnect Google Account',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ] else ...[
          const Text('Google Account',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.w500)),
          const Text(
              'Link your Google account to sign in with Google or email & password.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const ValueKey('connect_google_button'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.surfaceHigh,
                  foregroundColor: NotelColors.textPrimary),
              onPressed: _connectGoogleAccount,
              icon: Image.asset('assets/images/ic_google_logo.png',
                  width: 20, height: 20),
              label: const Text('Connect Google Account',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 24),
      _sectionLabel('ADVANCED DATA SOURCES'),
      _card([
        const Text('Fitbit Direct Sync',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.w500)),
        const Text('No longer available',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 8),
        const Text(
            'Google retired the Fitbit Web API on Oct 30, 2026. Fitbit data still reaches Tabs through Health Connect.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
      ]),
    ];
  }

  // ── Connected Apps flows (Round 30) ──────────────────────────────

  /// Takeover disclosures (audit P3) — the A1 calendar disclosure
  /// at the Connected Apps CONNECT moment. Until now the disclosure
  /// fired only at coach approve time, so a user who granted
  /// calendar permission manually via Android system settings never
  /// saw it. Tapping "Connect Google Calendar" now shows the
  /// disclosure FIRST (the same [calendarCoachDisclosure] text the
  /// approve-time gate uses); only Continue proceeds to the native
  /// connect flow below. "Not now" (or dismissing) connects
  /// nothing and starts no sign-in. The disclosure is duplicated,
  /// not moved: the approve-time gate still shows it before the
  /// system permission request.
  Future<void> _showCalendarConnectDisclosure() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Connect Google Calendar',
            style: TextStyle(color: NotelColors.textPrimary)),
        content: const Text(calendarCoachDisclosure,
            style: TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            key: const ValueKey('calendar_disclosure_not_now'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: const ValueKey('calendar_disclosure_continue'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    await _connectGoogleCalendar();
  }

  /// Native Calendar connect (SettingsScreen.kt:144-160 +
  /// SettingsViewModel.kt:204-209): chooser returns an account; only
  /// its email is stored, locally. A dismissed chooser is a quiet
  /// no-op (native parity); real failures surface as a snackbar.
  Future<void> _connectGoogleCalendar() async {
    try {
      final identity = await _google.signInForIdentity();
      await _store.setGoogleCalendarConnected(true);
      await _store.setGoogleCalendarEmail(identity.email);
      if (!mounted) return;
      setState(() {
        _gCalConnected = true;
        _gCalEmail = identity.email;
      });
      // Round 54 — verify usability at connect time WITHOUT
      // nagging: check the calendar permission state and, only
      // when permission is already granted, that a writable
      // calendar resolves. No prompt is ever fired from Settings
      // (native's ask moment is the first coach approve), and the
      // row stays connected either way — the flag is sign-in-based
      // (native parity); truth-telling happens at approve time.
      // The check is advisory only: any failure is swallowed.
      try {
        final calendar = widget.calendarService ?? CalendarService();
        final status = await calendar.getPermissionStatus();
        if (status.granted) {
          await calendar.listWritableCalendars();
        }
      } catch (_) {
        // Advisory check only — never blocks or un-connects.
      }
    } on GoogleSignInOutcome catch (e) {
      if (e.kind == GoogleSignInOutcomeKind.cancelled) return;
      _snack(e.message);
    } catch (_) {
      _snack('Google sign-in failed. Please try again.');
    }
  }

  Future<void> _disconnectGoogleCalendar() async {
    // Native disconnectGoogleCalendar: local state only.
    await _store.setGoogleCalendarConnected(false);
    await _store.setGoogleCalendarEmail('');
    if (!mounted) return;
    setState(() {
      _gCalConnected = false;
      _gCalEmail = '';
    });
  }

  /// Native Account link (SettingsScreen.kt:168-198 +
  /// SettingsViewModel.kt:218-241): chooser → POST /api/auth/
  /// link-google → local state flips ONLY on server success.
  Future<void> _connectGoogleAccount() async {
    final GoogleAccountIdentity identity;
    try {
      identity = await _google.signInForIdentity();
    } on GoogleSignInOutcome catch (e) {
      if (e.kind == GoogleSignInOutcomeKind.cancelled) return;
      _snack(e.message);
      return;
    } catch (_) {
      _snack('Google sign-in failed. Please try again.');
      return;
    }
    final res = await _backend.linkGoogle(identity.idToken);
    if (res != null && res['success'] == true) {
      await _store.setGoogleAccountConnected(true);
      await _store.setGoogleAccountEmail(identity.email);
      if (!mounted) return;
      setState(() {
        _gAccountConnected = true;
        _gAccountEmail = identity.email;
      });
      final msg = res['message']?.toString();
      if (msg != null && msg.isNotEmpty) _snack(msg);
    } else {
      // Fail closed (native): local state stays disconnected.
      _snack('Could not verify Google account. Check your connection and try again.');
    }
  }

  /// Native disconnect dialog (SettingsScreen.kt, showOnlyConfirm
  /// variant): the server is authoritative and refuses disconnecting
  /// the last usable sign-in method; its error stays in the dialog.
  Future<void> _showDisconnectGoogleDialog() async {
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: NotelColors.surface,
          title: const Text('Disconnect Google Account',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                  'Are you sure you want to disconnect this Google account? Tabs will refuse if you do not have another usable sign in method.',
                  style: TextStyle(
                      color: NotelColors.textSecondary, fontSize: 13)),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!,
                    style: const TextStyle(
                        color: NotelColors.error, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: NotelColors.textSecondary)),
            ),
            TextButton(
              key: const ValueKey('confirm_disconnect_google'),
              onPressed: () async {
                final res = await _backend.disconnectGoogle();
                if (res != null && res['error'] == null) {
                  await _store.setGoogleAccountConnected(false);
                  await _store.setGoogleAccountEmail('');
                  if (!mounted) return;
                  setState(() {
                    _gAccountConnected = false;
                    _gAccountEmail = '';
                  });
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  _snack('Google account disconnected successfully.');
                } else {
                  // Native preserves local state when the server
                  // could not confirm the disconnect.
                  setLocal(() => error = res?['error']?.toString() ??
                      'Could not disconnect Google account. Check your connection and try again.');
                }
              },
              child: const Text('Disconnect',
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ── AI & CLINICAL ADVOCATE (native :1545-2237) ───────────────────

  List<Widget> _aiPage() {
    final d = _data;
    final updates = d.professionalUpdates
        .split('\n\n')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    final facts = d.knowledgeBase
        .split('\n\n')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    final displayInsights = d.insights
        .where((i) => i.type != 'BodyLoad' && i.type != 'Biometrics')
        .take(15)
        .toList();
    return [
      if (updates.isNotEmpty || _professionalGate) ...[
        _sectionLabel('PHYSICIAN PROTOCOLS'),
        _card([
          const Text('New Physician Protocol',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('add_protocol_button'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white),
              onPressed: _showAddUpdateDialog,
              child: Text('Add $_professionalType Update',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          if (updates.isNotEmpty) ...[
            const SizedBox(height: 12),
            // Round 64 — collapsible Past Updates list, collapsed by
            // default (founder directive). Header pattern mirrors
            // Today Summary (today_summary_card.dart): a tappable
            // header row with title + chevron IconButton toggling an
            // AnimatedSize body; the Add button above stays visible
            // without expanding anything.
            InkWell(
              key: const ValueKey('past_updates_header'),
              onTap: () => setState(
                  () => _pastUpdatesExpanded = !_pastUpdatesExpanded),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Text('Past $_professionalType Updates',
                              style: const TextStyle(
                                  color: NotelColors.primary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 6),
                          Text('(${updates.length})',
                              key: const ValueKey('past_updates_count'),
                              style: const TextStyle(
                                  color: NotelColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('past_updates_toggle'),
                      onPressed: () => setState(() =>
                          _pastUpdatesExpanded = !_pastUpdatesExpanded),
                      tooltip: _pastUpdatesExpanded
                          ? 'Collapse Past $_professionalType Updates'
                          : 'Expand Past $_professionalType Updates',
                      icon: Icon(
                        _pastUpdatesExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 26,
                        color: NotelColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              child: _pastUpdatesExpanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: updates
                          .asMap()
                          .entries
                          .map((e) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Text(e.value,
                                          style: const TextStyle(
                                              color:
                                                  NotelColors.textPrimary,
                                              fontSize: 13)),
                                    ),
                                    IconButton(
                                      key: ValueKey('edit_protocol_${e.key}'),
                                      icon: const Icon(Icons.edit,
                                          size: 18,
                                          color: NotelColors.textSecondary),
                                      onPressed: () =>
                                          _showEditJoinedEntryDialog(
                                        title:
                                            'Edit $_professionalType Update',
                                        initial: e.value,
                                        fieldKey: 'protocol_edit_field',
                                        saveKey: 'protocol_edit_save',
                                        onSave: (text) {
                                          final list = [...updates];
                                          list[e.key] = text;
                                          _saveProfessionalUpdates(list);
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      key:
                                          ValueKey('delete_protocol_${e.key}'),
                                      icon: const Icon(Icons.delete,
                                          size: 18,
                                          color: NotelColors.error),
                                      onPressed: () {
                                        final list = [...updates]
                                          ..removeAt(e.key);
                                        _saveProfessionalUpdates(list);
                                      },
                                    ),
                                  ],
                                ),
                              ))
                          .toList(),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ]),
        const SizedBox(height: 24),
      ],
      _sectionLabel('FILE KNOWLEDGE BASE'),
      _card([
        // Native card header (:1787): title + "On-device" badge.
        // The badge is native's copy; extraction itself is a
        // server Gemini call (see the trace) — the copy is kept
        // verbatim because native source is the spec for copy.
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Digital Knowledge Extraction',
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.w500)),
            Row(
              children: [
                Icon(Icons.storage, size: 12, color: NotelColors.textSecondary),
                SizedBox(width: 4),
                Text('On-device',
                    style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
            'Upload notes or PDFs to extract permanent knowledge (patterns, triggers, facts) that Gemini will remember.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 16),
        if (_kProcessing)
          const Row(
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: NotelColors.primary),
              ),
              SizedBox(width: 12),
              Text('Gemini is reading your files...',
                  style: TextStyle(
                      color: NotelColors.textPrimary, fontSize: 14)),
            ],
          )
        else ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const ValueKey('select_document_button'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.surfaceHigh,
                  foregroundColor: NotelColors.textPrimary),
              onPressed: _pickAndAddDocument,
              icon: const Icon(Icons.upload_file, color: NotelColors.primary),
              label: const Text('Select Document / PDF'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const ValueKey('add_text_note_button'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.surfaceHigh,
                  foregroundColor: NotelColors.textPrimary),
              onPressed: _showTextNoteDialog,
              icon: const Icon(Icons.post_add, color: NotelColors.primary),
              label: const Text('Add Text Note'),
            ),
          ),
        ],
        if (_kError != null) ...[
          const SizedBox(height: 8),
          Text(_kError!,
              key: const ValueKey('knowledge_process_error'),
              style:
                  const TextStyle(color: NotelColors.error, fontSize: 12)),
        ],
        // Extracted Facts (native: only when knowledgeBase non-blank).
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 16),
          InkWell(
            key: const ValueKey('facts_toggle'),
            onTap: () => setState(() => _factsExpanded = !_factsExpanded),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Extracted Facts',
                    style: TextStyle(
                        color: NotelColors.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                Icon(
                    _factsExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: NotelColors.primary),
              ],
            ),
          ),
          if (_factsExpanded) ...[
            const SizedBox(height: 8),
            ...facts.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('Extraction ${e.key + 1}',
                                style: const TextStyle(
                                    color: NotelColors.primary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                          IconButton(
                            key: ValueKey('edit_fact_${e.key}'),
                            icon: const Icon(Icons.edit,
                                size: 16, color: NotelColors.primary),
                            onPressed: () => _showEditJoinedEntryDialog(
                              title: 'Edit Extracted Fact',
                              initial: e.value,
                              fieldKey: 'fact_edit_field',
                              saveKey: 'fact_edit_save',
                              onSave: (text) {
                                final list = [...facts];
                                list[e.key] = text;
                                _saveKnowledgeBase(list);
                              },
                            ),
                          ),
                          IconButton(
                            key: ValueKey('delete_fact_${e.key}'),
                            icon: const Icon(Icons.delete,
                                size: 16, color: NotelColors.error),
                            onPressed: () {
                              final list = [...facts]..removeAt(e.key);
                              _saveKnowledgeBase(list);
                            },
                          ),
                        ],
                      ),
                      InkWell(
                        onTap: () => setState(() {
                          if (_expandedFacts.contains(e.key)) {
                            _expandedFacts.remove(e.key);
                          } else {
                            _expandedFacts.add(e.key);
                          }
                        }),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.value.trim(),
                                maxLines:
                                    _expandedFacts.contains(e.key) ? null : 3,
                                overflow: _expandedFacts.contains(e.key)
                                    ? TextOverflow.visible
                                    : TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: NotelColors.textPrimary,
                                    fontSize: 13,
                                    height: 18 / 13)),
                            if (!_expandedFacts.contains(e.key)) ...[
                              const SizedBox(height: 4),
                              const Text('Tap to expand',
                                  style: TextStyle(
                                      color: NotelColors.textSecondary,
                                      fontSize: 11)),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                )),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('clear_knowledge_button'),
                onPressed: () => _saveKnowledgeBase(const []),
                child: const Text('Clear Knowledge Base',
                    style:
                        TextStyle(color: NotelColors.error, fontSize: 12)),
              ),
            ),
          ],
        ],
        // Original Documents (native: only when documents exist).
        if (d.documents.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Divider(color: NotelColors.divider, thickness: 0.5),
          const SizedBox(height: 12),
          InkWell(
            key: const ValueKey('documents_toggle'),
            onTap: () => setState(() => _docsExpanded = !_docsExpanded),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.folder,
                        color: NotelColors.primary, size: 16),
                    const SizedBox(width: 6),
                    Text('Original Documents (${d.documents.length})',
                        style: const TextStyle(
                            color: NotelColors.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
                Icon(
                    _docsExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: NotelColors.primary),
              ],
            ),
          ),
          if (_docsExpanded) ...[
            const SizedBox(height: 8),
            ...d.documents.map((doc) {
              final state = _kStore.stateFor(doc.id);
              final busy = _kBusyDocs.contains(doc.id);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: InkWell(
                  key: ValueKey('doc_tile_${doc.id}'),
                  onTap: () => _openDocument(doc),
                  child: Row(
                    children: [
                      Stack(
                        children: [
                          Icon(
                            doc.mimeType == 'application/pdf'
                                ? Icons.picture_as_pdf
                                : (doc.mimeType.startsWith('image/')
                                    ? Icons.image
                                    : Icons.description),
                            color: NotelColors.primary,
                            size: 28,
                          ),
                          if (state == KnowledgeExtractionState.ready)
                            const Positioned(
                              right: 0,
                              top: 0,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                    color: NotelColors.success,
                                    shape: BoxShape.circle),
                                child: SizedBox(width: 10, height: 10),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(doc.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: NotelColors.textPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500)),
                            Row(
                              children: [
                                Text(doc.typeLabel,
                                    style: const TextStyle(
                                        color: NotelColors.textSecondary,
                                        fontSize: 10)),
                                const SizedBox(width: 6),
                                if (busy || state == KnowledgeExtractionState.pending)
                                  const Text('• Extracting…',
                                      style: TextStyle(
                                          color: NotelColors.textSecondary,
                                          fontSize: 10))
                                else if (state == KnowledgeExtractionState.ready)
                                  const Text('• AI read',
                                      style: TextStyle(
                                          color: NotelColors.success,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w500))
                                else if (state ==
                                    KnowledgeExtractionState.empty)
                                  const Text('• No readable text found',
                                      style: TextStyle(
                                          color: NotelColors.textSecondary,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w500))
                                else
                                  const Text('• Extraction failed',
                                      style: TextStyle(
                                          color: NotelColors.error,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w500)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: ValueKey('delete_doc_${doc.id}'),
                        icon: const Icon(Icons.delete,
                            size: 18, color: NotelColors.error),
                        onPressed: () => _confirmDeleteDocument(doc),
                      ),
                    ],
                  ),
                ),
              );
            }),
            InkWell(
              key: const ValueKey('clear_all_docs_button'),
              onTap: _confirmClearAllDocuments,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.delete_sweep,
                        color: NotelColors.error, size: 14),
                    SizedBox(width: 4),
                    Text('Clear All Files',
                        style: TextStyle(
                            color: NotelColors.error,
                            fontSize: 11,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ]),
      const SizedBox(height: 24),
      _sectionLabel('AI CONFIGURATION'),
      _card([
        _toggleRow(
          'Auto AI Pings',
          'Automatically load smart tiles when opening the app.',
          d.autoAiSuggestions,
          (v) async {
            setState(() =>
                _data = _data.copyWith(autoAiSuggestions: v));
            await _pushProfile({'autoAiSuggestions': v});
          },
          key: const ValueKey('auto_ai_toggle'),
        ),
      ]),
      const SizedBox(height: 24),
      _sectionLabel('CLINICAL ADVOCACY'),
      _card([
        InkWell(
          onTap: () => setState(() => _page = _Page.progressReports),
          child: const Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Progress Reports',
                        style: TextStyle(
                            color: NotelColors.textPrimary,
                            fontWeight: FontWeight.w500)),
                    SizedBox(height: 4),
                    Text(
                        'Pick a report type, preview your data, and export a PDF for your physician.',
                        style: TextStyle(
                            color: NotelColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward, color: NotelColors.primary),
            ],
          ),
        ),
      ]),
      const SizedBox(height: 24),
      _sectionLabel('AI INSIGHTS HISTORY'),
      if (displayInsights.isEmpty)
        const Text(
            'No AI insights generated yet. Perform an AI action to see it here.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 14))
      else ...[
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.surfaceHigh,
                foregroundColor: NotelColors.textPrimary),
            onPressed: () =>
                setState(() => _showInsights = !_showInsights),
            child: Text(
                _showInsights ? 'Hide AI Insights' : 'Show Past AI Insights'),
          ),
        ),
        if (_showInsights)
          ...displayInsights.map((i) => Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _card([
                  Text(i.text,
                      style: const TextStyle(
                          color: NotelColors.textPrimary, fontSize: 13)),
                ]),
              )),
      ],
    ];
  }

  // ── EVENT COUNTERS (native :1294-1544) ──────────────────────────

  List<EventCounterItem> get _counters =>
      _data.eventCounters.map(EventCounterItem.fromMap).toList();

  /// The account that owns this screen's local tombstones — the
  /// widget email, read SYNCHRONOUSLY on purpose: the session-store
  /// email read is a secure-storage channel call, and the Round 51
  /// lesson is that such a read must never sit on a blocking path
  /// (an unguarded one once silently discarded this screen's whole
  /// load). Surfaces constructed without an email (the Research
  /// conditions flow) run unbound: the store ADOPTS an unowned set
  /// for the first account that reads it with an email, but since
  /// the correction round (Juno C2) a null-owner read of a set
  /// BOUND to an account returns empty, so a previous account's
  /// tombstones can never filter this surface's counters. Wipe
  /// paths, stated exactly (Vera F7): explicit logout / account
  /// deletion wipes the keys via SettingsStore.clear; a forced
  /// session expiry wipes just the two tombstone keys via
  /// SettingsStore.clearDeletedCounterIds (main.dart).
  String? get _tombstoneOwnerEmail {
    final e = widget.email;
    return (e != null && e.trim().isNotEmpty) ? e : null;
  }

  /// Defect D — applies the locally persisted delete tombstones to
  /// a pulled profile: counters whose id is tombstoned are removed
  /// from the list (BY ID ONLY — a row missing the `isArchived` key
  /// passes through untouched apart from that check), and
  /// tombstones whose id the pulled list no longer carries are
  /// pruned from the store (native self-cleaning). Filtering runs
  /// on the RAW pulled maps so no other key is rewritten here.
  /// Never throws: a store failure returns [data] unfiltered.
  Future<SettingsProfileData> _applyCounterTombstones(
      SettingsProfileData data) async {
    try {
      final owner = _tombstoneOwnerEmail;
      final tombstones =
          await _store.getDeletedCounterIds(ownerEmail: owner);
      if (tombstones.isEmpty) return data;
      final rawCounters = data.eventCounters;
      final serverIds =
          rawCounters.map((m) => '${m['id'] ?? ''}').toSet();
      final stillNeeded = pruneCounterTombstones(tombstones, serverIds);
      if (stillNeeded.length != tombstones.length) {
        await _store.setDeletedCounterIds(stillNeeded,
            ownerEmail: owner);
      }
      if (stillNeeded.isEmpty) return data;
      final filtered = rawCounters
          .where((m) => !stillNeeded.contains('${m['id'] ?? ''}'))
          .toList();
      if (filtered.length == rawCounters.length) return data;
      return data.copyWith(eventCountersRaw: jsonEncode(filtered));
    } catch (_) {
      return data;
    }
  }

  /// Defect D — the [_load] post-pass: filters tombstoned counters
  /// out of the CURRENT [_data] once the load has landed. If a save
  /// or a newer load changed the counters while the filter ran,
  /// that newer state wins and this pass does nothing.
  Future<void> _filterTombstonedCountersInPlace() async {
    final before = _data;
    final filtered = await _applyCounterTombstones(before);
    if (!mounted) return;
    if (filtered.eventCountersRaw == before.eventCountersRaw) return;
    if (_data.eventCountersRaw != before.eventCountersRaw) return;
    setState(() => _data = _data.copyWith(
        eventCountersRaw: filtered.eventCountersRaw));
  }

  /// Defect D — records a deleted counter's tombstone locally.
  /// Never throws; never leaves the device (SettingsStore is
  /// on-device secure storage; the tombstone keys are wiped by
  /// SettingsStore.clear on explicit logout / account deletion
  /// and by clearDeletedCounterIds on a forced session expiry).
  Future<void> _recordCounterTombstone(String id) async {
    try {
      await _store.addDeletedCounterId(id,
          ownerEmail: _tombstoneOwnerEmail);
    } catch (_) {}
  }

  /// Rolls a tombstone back when its delete push failed — the
  /// counter was never deleted server-side, so nothing may hide it.
  Future<void> _rollbackCounterTombstone(String id) async {
    try {
      await _store.removeDeletedCounterId(id,
          ownerEmail: _tombstoneOwnerEmail);
    } catch (_) {}
  }

  /// Counter-mutation durability (Oct 2026) — the choke point for
  /// every SETTINGS event-counter save (delete / restore /
  /// edit / create / end-and-save), rewritten after the founder's
  /// mutations never persisted. Correction round (Vera F4): this
  /// is not literally the only whole-blob eventCounters writer —
  /// the Health Coach's counter approval also pushes the blob.
  /// The real invariant every whole-blob eventCounters writer
  /// upholds: splice onto a FRESH, TOMBSTONE-FILTERED base (the
  /// Coach filters its spliced rows through the same tombstone
  /// set before pushing), so no writer can resurrect a locally
  /// deleted counter or drop a concurrent one.
  ///
  /// 1. RE-PULL FRESH FIRST (the standing whole-blob rule): the
  ///    cached pull is invalidated and the profile is re-read; the
  ///    mutation is computed against THAT list, never against the
  ///    possibly-stale [_data] snapshot the old code spliced onto.
  ///    Callers pass their INTENT as [transform], which is applied
  ///    to the fresh list — so a concurrent pull landing at any
  ///    point (including the epoch-checked re-issue inside the
  ///    backend) can never resurrect or drop a counter the splice
  ///    did not intend.
  /// 2. A failed fresh pull ABORTS the save with the honest
  ///    save-error snack — no push is fired onto a stale base.
  /// 3. For an end/delete, the id's tombstone is recorded locally
  ///    at save time (before the push, so no stale body landing
  ///    during the push can be applied unfiltered); a failed push
  ///    rolls it back.
  /// 4. [_data] is set from the PUSHED state only after the push
  ///    succeeds. On failure the save-error snack shows and a
  ///    reload runs; [_load] keeps the last-known data if that
  ///    reload also fails — the list never blanks and never claims
  ///    a save the server did not take.
  ///
  /// [historyTransform] likewise receives the FRESH history (and
  /// the fresh counters, so the end-and-save handler can tell
  /// whether its counter is really being removed) and returns the
  /// history to push, or null to leave history untouched. It runs
  /// BEFORE [transform] (Oct 28, 2026): a paired history+counter
  /// move — restoring a history entry recreates its counter — can
  /// share one fresh-data decision between the two transforms (the
  /// history transform records whether the entry was really still
  /// present, and the counter transform adds the counter only
  /// then), so the pair still moves atomically in this one push
  /// and a concurrent save that already restored the entry cannot
  /// duplicate the counter.
  /// Returns true only when the push landed.
  Future<bool> _saveCounters(
    List<EventCounterItem> Function(List<EventCounterItem> freshCounters)
        transform, {
    List<Map<String, dynamic>>? Function(
            List<Map<String, dynamic>> freshHistory,
            List<EventCounterItem> freshCounters)?
        historyTransform,
    String? deletedCounterId,
  }) async {
    // Vera F1 — save-in-flight guard: a second counter save while
    // one is already running is refused outright (the row buttons
    // are also disabled on [_counterSaveInFlight], but a tap that
    // lands before the disabling frame must not queue a second
    // mutation behind the first).
    if (_counterSaveInFlight) return false;
    _counterSaveInFlight = true;
    if (mounted) setState(() {});
    try {
      return await _saveCountersGuarded(transform,
          historyTransform: historyTransform,
          deletedCounterId: deletedCounterId);
    } finally {
      _counterSaveInFlight = false;
      if (mounted) setState(() {});
    }
  }

  Future<bool> _saveCountersGuarded(
    List<EventCounterItem> Function(List<EventCounterItem> freshCounters)
        transform, {
    List<Map<String, dynamic>>? Function(
            List<Map<String, dynamic>> freshHistory,
            List<EventCounterItem> freshCounters)?
        historyTransform,
    String? deletedCounterId,
  }) async {
    _backend.invalidateSyncPull();
    final body = await _backend.fetchSyncPull();
    if (body == null) {
      // Juno C1: an aborted save is not a synced state.
      _syncConfirmed = false;
      _snack('Could not save. Check your connection and try again.');
      return false;
    }
    final freshData = await _applyCounterTombstones(
        SettingsProfileData.fromPull(body));
    final freshCounters =
        freshData.eventCounters.map(EventCounterItem.fromMap).toList();
    // The history transform runs FIRST (see the _saveCounters doc):
    // paired history+counter moves share their fresh-data decision
    // through it before the counter transform is computed.
    String? historyRaw;
    if (historyTransform != null) {
      final newHistory =
          historyTransform(freshData.counterHistory, freshCounters);
      if (newHistory != null) {
        historyRaw = jsonEncode(newHistory);
      }
    }
    final counters = transform(freshCounters);
    final raw = jsonEncode(counters.map((c) => c.toMap()).toList());
    final fields = <String, dynamic>{'eventCounters': raw};
    if (historyRaw != null) {
      fields['counterHistory'] = historyRaw;
    }
    if (deletedCounterId != null) {
      await _recordCounterTombstone(deletedCounterId);
    }
    // This save deliberately does NOT route through _pushProfile:
    // on failure the tombstone rollback must land BEFORE (and
    // independently of) the best-effort reload _pushProfile runs,
    // whose _load continues into unrelated subsystems (knowledge
    // cache, connection state, reminder sync) that must never gate
    // the rollback. Success/failure handling otherwise mirrors
    // _pushProfile exactly: invalidate the pull cache on success;
    // on failure show the same save-error snack and reload (which
    // keeps last-known data if it also fails — see _load).
    final ok = await _backend.postSyncProfile(fields);
    if (!ok) {
      if (deletedCounterId != null) {
        await _rollbackCounterTombstone(deletedCounterId);
      }
      // Juno C1: a failed save drops the Synced chip until the
      // next successful pull/push (the reload below re-confirms
      // it only if its own pull lands).
      _syncConfirmed = false;
      _snack('Could not save. Check your connection and try again.');
      await _reloadFromServer(reportLoadFailure: false);
      return false;
    }
    _backend.invalidateSyncPull();
    if (mounted) {
      setState(() {
        _data = _data.copyWith(
            eventCountersRaw: raw, counterHistoryRaw: historyRaw);
        _hasRealData = true;
        _syncConfirmed = true;
      });
    }
    // Native arms/cancels the counter's 9 AM alarm in the same save
    // (SettingsViewModel.kt:1270); re-sync all event schedules.
    await _syncReminders();
    return true;
  }

  List<Widget> _countersPage() {
    final counters = _counters;
    // Unified split (founder direction, Oct 28, 2026): ONE
    // predicate — active iff neither archived nor delete-stamped
    // (EventCounterItem.isActive); every non-active counter lands
    // in the single PAST COUNTERS box below, together with the
    // ended-counter history entries. There is no separate
    // DELETED COUNTERS section any more.
    final active = counters.where((c) => c.isActive).toList();
    final past = counters.where((c) => c.isNonActive).toList();
    final history = _data.counterHistory;
    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _sectionLabel('EVENT COUNTERS'),
          // Juno C1 — the chip tells the truth about THIS session:
          // 'Synced' only after a load/save outcome that confirms
          // the on-screen data matches the server; a failed load
          // or an aborted/failed save shows 'Not synced' until the
          // next successful pull/push.
          Row(
            key: const ValueKey('counters_sync_chip'),
            children: [
              Icon(
                  _syncConfirmed ? Icons.cloud_done : Icons.cloud_off,
                  color: _syncConfirmed
                      ? NotelColors.primary
                      : NotelColors.textSecondary,
                  size: 16),
              const SizedBox(width: 4),
              Text(_syncConfirmed ? 'Synced' : 'Not synced',
                  style: const TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          key: const ValueKey('add_counter'),
          style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.surfaceHigh,
              foregroundColor: NotelColors.textPrimary,
              // R49 SE6/S2: 48dp height, matching this page's own
              // 48dp counter-row buttons (stock default is 40).
              minimumSize: const Size(64, 48)),
          onPressed:
              _counterSaveInFlight ? null : () => _showCounterDialog(null),
          icon: const Icon(Icons.add, color: NotelColors.primary),
          label: const Text('Add New Counter'),
        ),
      ),
      const SizedBox(height: 16),
      // Round 37 — visual polish (presentation only): one standard
      // _card per section instead of a single loose card; the muted
      // explainer is a page footer under the last section. Every
      // action keeps its exact pre-round behavior.
      if (counters.isEmpty)
        _card([
          const Text('No counters yet.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 13))
        ])
      else if (active.isNotEmpty)
        _counterCard(active),
      if (past.isNotEmpty || history.isNotEmpty) ...[
        const SizedBox(height: 16),
        _sectionLabel('PAST COUNTERS'),
        // ONE box for everything non-active (Oct 28, 2026): the
        // non-active event counters first, then the ended-counter
        // history entries, as divider-separated muted text rows in
        // a single card; every row's only action is 'Restore'.
        _card(_pastBoxRows(past, history),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
      ],
      const SizedBox(height: 12),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Text(
            'Track important upcoming or past events. All active counters will show on the main screen and sync with the AI.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
      ),
    ];
  }

  /// One section's counters in the standard card surface (same
  /// surface color / radius / padding family as every Settings
  /// card), rows separated by the standard divider — the menu-card
  /// rhythm from Rounds 29–30.
  Widget _counterCard(List<EventCounterItem> list) {
    final children = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      if (i > 0) {
        children.add(const Divider(color: NotelColors.divider, height: 1));
      }
      children.add(_counterRow(list[i]));
    }
    return _card(children,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8));
  }

  /// 'Mon DD, YYYY' — the date format for every row in the
  /// unified Past Counters box.
  String _monthDayYearLabel(int ms) {
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[date.month - 1]} ${date.day.toString().padLeft(2, '0')}, ${date.year}';
  }

  /// Tolerant int read for history-entry fields (num | numeric
  /// string, the SettingsProfileData parser's convention).
  int _historyInt(dynamic v) =>
      v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);

  /// The unified PAST COUNTERS box (founder direction, Oct 28,
  /// 2026): non-active event counters first, then the
  /// ended-counter history entries — divider-separated muted text
  /// rows in ONE card. Every row's only action is 'Restore'.
  List<Widget> _pastBoxRows(List<EventCounterItem> past,
      List<Map<String, dynamic>> history) {
    final rowWidgets = <Widget>[
      for (final c in past) _pastCounterRow(c),
      for (var i = 0; i < history.length; i++)
        _pastHistoryRow(history[i], i),
    ];
    final rows = <Widget>[];
    for (var i = 0; i < rowWidgets.length; i++) {
      if (i > 0) {
        rows.add(const Divider(color: NotelColors.divider, height: 1));
      }
      rows.add(rowWidgets[i]);
    }
    return rows;
  }

  /// The shared Restore button style for Past-box rows: ≥48dp tap
  /// target (this page's a11y precedent) while the label itself
  /// stays at the rows' 11px.
  ButtonStyle get _pastRestoreButtonStyle => TextButton.styleFrom(
        foregroundColor: NotelColors.textSecondary,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(fontSize: 11),
      );

  /// A non-active event counter in the Past Counters style:
  /// 'Name (Deleted: Mon DD, YYYY)' when it carries a delete
  /// stamp, name-only when it does not (rows archived before the
  /// stamp existed — a date is never invented for them). No
  /// per-row icon clutter; the row's ONLY action is 'Restore' —
  /// no edit, no end (ending a past counter means restoring it
  /// first, then ending it from the active list).
  Widget _pastCounterRow(EventCounterItem c) {
    final label = c.deletedAt == null
        ? c.name
        : '${c.name} (Deleted: ${_monthDayYearLabel(c.deletedAt!)})';
    return Row(
      key: ValueKey('counter_row_${c.id}'),
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(label,
                style: const TextStyle(
                    color: NotelColors.textSecondary, fontSize: 11)),
          ),
        ),
        TextButton(
          key: ValueKey('counter_restore_${c.id}'),
          style: _pastRestoreButtonStyle,
          // Vera F1 — disabled while a counter save is in flight.
          onPressed: _counterSaveInFlight
              ? null
              : () async {
                  // ABSOLUTE intent: restore THIS row by id —
                  // isArchived false AND the delete stamp cleared,
                  // every other field carried through intact.
                  await _saveCounters((fresh) => fresh
                      .map((x) => x.id == c.id
                          ? x.copyWith(isArchived: false, deletedAt: null)
                          : x)
                      .toList());
                },
          // Founder-directed copy (Oct 28, 2026): the action is
          // named 'Restore'. This supersedes Juno's earlier
          // 'Bring back' approval (Oct 27, 2026).
          child: const Text('Restore'),
        ),
      ],
    );
  }

  /// An ended-counter history entry in the same Past-box style:
  /// 'Name (Ended: Mon DD, YYYY)', with 'Restore' as its only
  /// action — restoring RECREATES the counter (see
  /// [_restoreHistoryEntry]).
  Widget _pastHistoryRow(Map<String, dynamic> h, int index) {
    final name = '${h['name'] ?? ''}';
    final targetMs = _historyInt(h['targetDate']);
    final endedMs = _historyInt(h['endedAt']);
    return Row(
      key: ValueKey('counter_history_row_$index'),
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('$name (Ended: ${_monthDayYearLabel(endedMs)})',
                style: const TextStyle(
                    color: NotelColors.textSecondary, fontSize: 11)),
          ),
        ),
        TextButton(
          key: ValueKey('counter_restore_history_$index'),
          style: _pastRestoreButtonStyle,
          // Vera F1 — disabled while a counter save is in flight.
          onPressed: _counterSaveInFlight
              ? null
              : () => _restoreHistoryEntry(
                  name: name, targetDateMs: targetMs, endedAtMs: endedMs),
          // Founder-directed copy (Oct 28, 2026): 'Restore' (see
          // the note on the event-counter row's button).
          child: const Text('Restore'),
        ),
      ],
    );
  }

  /// Restoring a HISTORY entry recreates its counter: the entry
  /// leaves counterHistory and a new ACTIVE counter built from the
  /// entry's stored name + targetDate joins eventCounters — both
  /// in ONE [_saveCounters] call (historyTransform + counter
  /// transform together), so the pair moves atomically against
  /// fresh data. The new id uses the Add Counter dialog's
  /// id-generation (creation time in epoch ms), bumped past any
  /// id the fresh list already carries so it is unique;
  /// isUp/autoUp/isFavorite default false.
  ///
  /// Dedupe (the End action's fresh-check pattern): the history
  /// transform runs first inside _saveCounters and records
  /// whether the FRESH history still carries this entry (matched
  /// on its name + targetDate + endedAt triple, removing exactly
  /// one match). If a concurrent save already restored/removed
  /// it, the transform leaves the history untouched and the
  /// counter transform adds nothing — no duplicate counter.
  Future<void> _restoreHistoryEntry({
    required String name,
    required int targetDateMs,
    required int endedAtMs,
  }) async {
    var entryStillPresent = false;
    await _saveCounters(
      (fresh) {
        if (!entryStillPresent) return fresh;
        var idMs = DateTime.now().millisecondsSinceEpoch;
        final usedIds = fresh.map((x) => x.id).toSet();
        while (usedIds.contains('$idMs')) {
          idMs++;
        }
        return [
          ...fresh,
          EventCounterItem(
            id: '$idMs',
            name: name,
            targetDate: targetDateMs,
          ),
        ];
      },
      historyTransform: (freshHistory, freshCounters) {
        final idx = freshHistory.indexWhere((h) =>
            '${h['name'] ?? ''}' == name &&
            _historyInt(h['targetDate']) == targetDateMs &&
            _historyInt(h['endedAt']) == endedAtMs);
        if (idx < 0) return null;
        entryStillPresent = true;
        return [...freshHistory]..removeAt(idx);
      },
    );
  }

  Widget _counterRow(EventCounterItem c) {
    // Active rows only (non-active rows render in the Past box):
    // full-strength name with the Tabs-purple day label.
    return Padding(
      key: ValueKey('counter_row_${c.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name,
                    style: const TextStyle(
                        color: NotelColors.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
                const SizedBox(height: 2),
                Text(c.daysLabel(),
                    style: const TextStyle(
                        color: NotelColors.primary, fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Right rail: the same three actions in the same order,
          // each on an explicit 48dp touch target with a tooltip
          // (the tooltip doubles as the semantics label).
          IconButton(
            key: ValueKey('counter_delete_${c.id}'),
            tooltip: 'Delete counter',
            constraints:
                const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.delete_outline,
                size: 18, color: NotelColors.textSecondary),
            // Vera F1 — disabled while a counter save is in flight.
            onPressed: _counterSaveInFlight
                ? null
                : () async {
                    // ABSOLUTE intent captured at tap time from the
                    // RENDERED row: this tap means "delete the
                    // counter I see" — set isArchived AND stamp
                    // deletedAt with the tap moment. _saveCounters
                    // applies those absolute values to the fresh
                    // row by id — never a toggle of the fresh row's
                    // own flag, which a double-tap or concurrent
                    // mutation would flip back. Single tap, no
                    // confirmation (Juno ruling, Oct 27, 2026): the
                    // Past box's 'Restore' is the undo.
                    final deletedAtMs =
                        DateTime.now().millisecondsSinceEpoch;
                    await _saveCounters((fresh) => fresh
                        .map((x) => x.id == c.id
                            ? x.copyWith(
                                isArchived: true, deletedAt: deletedAtMs)
                            : x)
                        .toList());
                  },
          ),
          IconButton(
            key: ValueKey('counter_edit_${c.id}'),
            tooltip: 'Edit counter',
            constraints:
                const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.edit,
                size: 18, color: NotelColors.textSecondary),
            onPressed:
                _counterSaveInFlight ? null : () => _showCounterDialog(c),
          ),
          IconButton(
            key: ValueKey('counter_end_${c.id}'),
            tooltip: 'End counter',
            constraints:
                const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.stop_circle,
                size: 18, color: NotelColors.textSecondary),
            onPressed: _counterSaveInFlight
                ? null
                : () async {
                    // Native endCounterAndSave: remove + append to
                    // history — computed against the FRESH lists
                    // inside _saveCounters, with the delete
                    // tombstone recorded at save time
                    // (deletedCounterId).
                    await _saveCounters(
                      (fresh) => fresh.where((x) => x.id != c.id).toList(),
                      historyTransform: (freshHistory, freshCounters) {
                        // Prepend the history entry only when the
                        // fresh list really still carries the
                        // counter — if a concurrent save already
                        // ended it, a second entry would duplicate
                        // the first.
                        final matches = freshCounters
                            .where((x) => x.id == c.id)
                            .toList();
                        if (matches.isEmpty) return null;
                        final target = matches.first;
                        return [
                          {
                            'name': target.name,
                            'targetDate': target.targetDate,
                            'endedAt':
                                DateTime.now().millisecondsSinceEpoch,
                          },
                          ...freshHistory,
                        ].take(20).toList();
                      },
                      deletedCounterId: c.id,
                    );
                  },
          ),
        ],
      ),
    );
  }

  Future<void> _showCounterDialog(EventCounterItem? existing) async {
    final nameC = TextEditingController(text: existing?.name ?? '');
    var date = existing != null
        ? DateTime.fromMillisecondsSinceEpoch(existing.targetDate)
        : DateTime.now();
    var isUp = existing?.isUp ?? false;
    var autoUp = existing?.autoUp ?? false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: NotelColors.surface,
          title: Text(existing != null ? 'Edit Counter' : 'New Counter',
              style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('counter_name_field'),
                  controller: nameC,
                  style: const TextStyle(color: NotelColors.textPrimary),
                  decoration: const InputDecoration(
                      labelText: 'Event Name (e.g. Next Doctor Appt)'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              color: NotelColors.textPrimary)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.calendar_today,
                          color: NotelColors.primary),
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setLocal(() => date = picked);
                        }
                      },
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(
                        child: Text('Count Up (Past Event)?',
                            style: TextStyle(
                                color: NotelColors.textPrimary,
                                fontSize: 12))),
                    Switch(
                        value: isUp,
                        onChanged: (v) => setLocal(() => isUp = v)),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(
                        child: Text(
                            'Auto switch to Count Up when day arrives?',
                            style: TextStyle(
                                color: NotelColors.textPrimary,
                                fontSize: 12))),
                    Switch(
                        value: autoUp,
                        onChanged: (v) => setLocal(() => autoUp = v)),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: NotelColors.textSecondary)),
            ),
            TextButton(
              key: const ValueKey('counter_save'),
              onPressed: () async {
                final name = nameC.text.trim();
                if (name.isEmpty) return;
                final ms = DateTime(date.year, date.month, date.day)
                    .millisecondsSinceEpoch;
                final bool ok;
                if (existing != null) {
                  ok = await _saveCounters((fresh) => fresh
                      .map((x) => x.id == existing.id
                          ? x.copyWith(
                              name: name,
                              targetDate: ms,
                              isUp: isUp,
                              autoUp: autoUp)
                          : x)
                      .toList());
                } else {
                  ok = await _saveCounters((fresh) {
                    // Native dedupes duplicate names with (2), (3)…
                    // — against the FRESH list, inside the transform.
                    final names = fresh.map((x) => x.name).toSet();
                    var unique = name;
                    var suffix = 2;
                    while (names.contains(unique)) {
                      unique = '$name ($suffix)';
                      suffix++;
                    }
                    return [
                      ...fresh,
                      EventCounterItem(
                        id: '${DateTime.now().millisecondsSinceEpoch}',
                        name: unique,
                        targetDate: ms,
                        isUp: isUp,
                        autoUp: autoUp,
                        isFavorite: fresh.isEmpty,
                      ),
                    ];
                  });
                }
                // A failed save keeps the dialog open with the
                // error already shown — never pop as if it saved.
                if (ok && ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Save',
                  style: TextStyle(color: NotelColors.primary)),
            ),
          ],
        ),
      ),
    );
    // Controller intentionally not disposed here — see nickname
    // dialog note (exit transition still builds the field).
  }

  // ── NOTIFICATIONS (native :3462-3753) ────────────────────────────
  //
  // Round 30: enabling any toggle runs native's permission gate
  // first (_ensureNotificationPermission — rationale dialog before
  // the system prompt, toggle flips only on grant); the preference
  // persists exactly as native does (DataStore locally for check-in;
  // profile push for the rest) and ReminderSync arms/cancels the
  // on-device schedule. Event reminders additionally arm one 9:00 AM
  // alarm per active event counter (see _saveCounters + _load).

  List<Widget> _notificationsPage() {
    final d = _data;
    return [
      _sectionLabel('NOTIFICATIONS'),
      _card([
        _toggleRow(
          'Habit Reminders',
          'Daily ping at 7:00 PM if you have unchecked habits remaining.',
          d.habitReminderEnabled,
          (v) async {
            if (v && !await _ensureNotificationPermission()) return;
            setState(() => _data = _data.copyWith(habitReminderEnabled: v));
            await _pushProfile({'habitReminderEnabled': v});
            await _syncReminders(report: true);
          },
          key: const ValueKey('habit_reminder_toggle'),
        ),
        const SizedBox(height: 20),
        _toggleRow(
          'Project Reminders',
          'Daily ping at 8:00 PM if you have unchecked project tasks remaining.',
          d.projectReminderEnabled,
          (v) async {
            if (v && !await _ensureNotificationPermission()) return;
            setState(
                () => _data = _data.copyWith(projectReminderEnabled: v));
            await _pushProfile({'projectReminderEnabled': v});
            await _syncReminders(report: true);
          },
          key: const ValueKey('project_reminder_toggle'),
        ),
        const SizedBox(height: 20),
        _toggleRow(
          'Event Reminders',
          'Daily ping at 9:00 AM on the day of scheduled events.',
          d.eventReminderEnabled,
          (v) async {
            if (v && !await _ensureNotificationPermission()) return;
            setState(() => _data = _data.copyWith(eventReminderEnabled: v));
            await _pushProfile({'eventReminderEnabled': v});
            await _syncReminders(report: true);
          },
          key: const ValueKey('event_reminder_toggle'),
        ),
        const SizedBox(height: 20),
        _toggleRow(
          'Remind me to log how I feel',
          'Daily at 4:00 AM, only if you have not checked in yet.',
          _checkInEnabled,
          (v) async {
            if (v) {
              if (!await _ensureNotificationPermission(checkIn: true)) {
                return;
              }
              setState(() => _checkInDenied = false);
            }
            setState(() => _checkInEnabled = v);
            await _store.setCheckInReminderEnabled(v);
            await _syncReminders(report: true);
          },
          key: const ValueKey('checkin_reminder_toggle'),
        ),
        if (_checkInDenied) ...[
          const SizedBox(height: 4),
          const Text(
              'Notifications are turned off on this phone, so the reminder cannot fire. You can turn them on in system settings.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
        ],
        const SizedBox(height: 20),
        _toggleRow(
          'HR Spike Alerts',
          'Real-time alert when your heart rate exceeds ${d.spikeThreshold} BPM.',
          d.hrSpikeAlertsEnabled,
          (v) async {
            if (v && !await _ensureNotificationPermission()) return;
            setState(
                () => _data = _data.copyWith(hrSpikeAlertsEnabled: v));
            final fields = <String, dynamic>{'hrSpikeAlertsEnabled': v};
            if (v && d.spikeThreshold < 40) {
              fields['spikeThreshold'] = 110;
              setState(() => _data = _data.copyWith(spikeThreshold: 110));
            }
            await _pushProfile(fields);
          },
          key: const ValueKey('spike_alerts_toggle'),
        ),
        if (d.hrSpikeAlertsEnabled) ...[
          const SizedBox(height: 12),
          _ThresholdField(
            label: 'Alert Threshold',
            keyName: 'spike_threshold_field',
            value: d.spikeThreshold,
            suffix: 'BPM',
            // Native guards (SettingsScreen.kt spike field): digits
            // only, max 3 chars, saved only when in 40..250.
            min: 40,
            max: 250,
            maxLength: 3,
            onSave: (v) async {
              setState(() => _data = _data.copyWith(spikeThreshold: v));
              await _pushProfile({'spikeThreshold': v});
            },
          ),
        ],
        const SizedBox(height: 20),
        _toggleRow(
          'Delta Spike Alerts',
          'Alert if BPM jumps more than ${d.spikeDeltaThreshold} points relative to your last reading (checked every 2-5 mins).',
          d.hrDeltaEnabled,
          (v) async {
            if (v && !await _ensureNotificationPermission()) return;
            setState(() => _data = _data.copyWith(hrDeltaEnabled: v));
            final fields = <String, dynamic>{'hrDeltaEnabled': v};
            if (v && d.spikeDeltaThreshold < 5) {
              fields['spikeDeltaThreshold'] = 30;
              setState(
                  () => _data = _data.copyWith(spikeDeltaThreshold: 30));
            }
            await _pushProfile(fields);
          },
          key: const ValueKey('delta_alerts_toggle'),
        ),
        if (d.hrDeltaEnabled) ...[
          const SizedBox(height: 12),
          _ThresholdField(
            label: 'Jump Threshold',
            keyName: 'delta_threshold_field',
            value: d.spikeDeltaThreshold,
            suffix: 'BPM',
            prefix: '+',
            // Native guards (SettingsScreen.kt delta field): digits
            // only, max 2 chars, saved only when in 5..99.
            min: 5,
            max: 99,
            maxLength: 2,
            onSave: (v) async {
              setState(
                  () => _data = _data.copyWith(spikeDeltaThreshold: v));
              await _pushProfile({'spikeDeltaThreshold': v});
            },
          ),
        ],
        const SizedBox(height: 16),
        const Text(
            'Habit, project, and check-in reminders are scheduled on this device and fire daily at the times shown while their toggle is on. Event reminders fire at 9:00 AM on the day of each active event counter. HR spike and delta alert preferences save exactly as in the native app, but the alerts do not fire from the Flutter app yet: in the native app they run from an always-on heart rate monitor service.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
        if (_notifDenied) ...[
          const SizedBox(height: 8),
          const Text(
              'Notifications are turned off on this phone, so reminders cannot fire. You can turn them on in system settings.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
        ],
        if (_notifError != null) ...[
          const SizedBox(height: 8),
          Text('Notification scheduling hit a problem [$_notifError].',
              style:
                  const TextStyle(color: NotelColors.error, fontSize: 11)),
        ],
      ]),
    ];
  }

  // (The threshold field itself is the stateful _ThresholdField
  // below the screen class — it owns a controller so an out-of-range
  // submit can revert the visible text to the stored value.)

  // ── SYNC SETTINGS (native :3754-3866) ────────────────────────────

  List<Widget> _syncPage() {
    final d = _data;
    String? lastSyncLabel;
    if (_lastSyncMs > 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(_lastSyncMs);
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      var hour = dt.hour % 12;
      if (hour == 0) hour = 12;
      final ampm = dt.hour >= 12 ? 'PM' : 'AM';
      lastSyncLabel =
          'Last synced: ${months[dt.month - 1]} ${dt.day}, $hour:${dt.minute.toString().padLeft(2, '0')} $ampm';
    }
    return [
      _sectionLabel('PRIVACY'),
      _card([
        _toggleRow(
          'Share data with friends',
          'Allow mutual friends to see your daily sleep, heart rate, and score',
          d.shareDataWithFriends,
          (v) async {
            setState(
                () => _data = _data.copyWith(shareDataWithFriends: v));
            await _pushProfile({'shareDataWithFriends': v});
          },
          key: const ValueKey('share_data_toggle'),
        ),
      ]),
      const SizedBox(height: 24),
      _sectionLabel('MANUAL SYNC'),
      _card([
        const Text(
            'Manually push all your local data to the cloud and pull the latest from the server. This happens automatically in the background, but you can trigger it here anytime.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            key: const ValueKey('sync_now_button'),
            style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white),
            onPressed: (_syncing || _recovering) ? null : _manualSync,
            icon: const Icon(Icons.cloud_upload, color: Colors.white),
            label: Text(_syncing ? 'Syncing...' : 'Sync Now',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        if (lastSyncLabel != null) ...[
          const SizedBox(height: 8),
          Text(lastSyncLabel,
              style: TextStyle(
                  color: NotelColors.textSecondary.withValues(alpha: 0.6),
                  fontSize: 11)),
        ],
      ]),
      const SizedBox(height: 24),
      _sectionLabel('RECOVERY'),
      _card([
        const Text(
            'If your data appears missing or out of date, use this to pull a fresh copy from the server and restore everything.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            key: const ValueKey('recover_button'),
            style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.surfaceHigh,
                foregroundColor: NotelColors.textPrimary),
            onPressed: (_syncing || _recovering) ? null : _recover,
            icon:
                const Icon(Icons.cloud_download, color: NotelColors.primary),
            label: Text(_recovering ? 'Recovering...' : 'Recover Account Data',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ]),
      const SizedBox(height: 24),
      // Lab-only forced-crash test hook (Juno Ruling 2026-10-27,
      // C6). CrashTestHook renders nothing unless this build is
      // the lab flavor; a production-flavor build can never reach
      // it. Placed by LOCAL CACHE so it sits with the other
      // diagnostics-adjacent sections.
      if (CrashReporting.isLabFlavor()) ...[
        _sectionLabel('LAB TEST HOOKS'),
        CrashTestHook(visible: CrashReporting.isLabFlavor()),
        const SizedBox(height: 24),
      ],
      _sectionLabel('LOCAL CACHE'),
      _card([
        const Text(
            'Delete all locally cached Key Metrics (weights, breathing rates, SpO2, and resting heart rates) saved on this device. This triggers a fresh sync from Health Connect or Fitbit on your next reload.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 12),
        const Text(
            'The Flutter Lab does not keep a Key Metrics cache, so there is nothing to clear here yet.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
      ]),
      const SizedBox(height: 24),
      _sectionLabel('MOVE TO THE TABS APP'),
      _card([
        const Text(
            'Some of your data lives only on this device: what your '
            'Health Coach remembers about you, your health history, '
            'the text extracted from your Knowledge Base documents, '
            'your food-checker history, and settings like these. '
            'Export it here in the Tabs Lab, '
            'then open the Tabs app, sign in with the same account, '
            'and choose Import from Tabs Lab on this same screen. '
            'The file contains health information, so send it only '
            'to yourself and delete it after importing.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            key: const ValueKey('migration_export_button'),
            style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white),
            onPressed: _migrationBusy ? null : _exportMigration,
            icon: const Icon(Icons.ios_share, color: Colors.white),
            label: Text(
                _migrationBusy ? 'Working...' : 'Export data for the Tabs app',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            key: const ValueKey('migration_import_button'),
            style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.surfaceHigh,
                foregroundColor: NotelColors.textPrimary),
            onPressed: _migrationBusy ? null : _importMigration,
            icon:
                const Icon(Icons.file_download, color: NotelColors.primary),
            label: const Text('Import from Tabs Lab',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        if (_migrationStatus != null) ...[
          const SizedBox(height: 12),
          Text(_migrationStatus!,
              key: const ValueKey('migration_status'),
              style: const TextStyle(
                  color: NotelColors.textPrimary, fontSize: 12)),
        ],
      ]),
    ];
  }

  // ── TAKEOVER Phase 4 — migration export / import ─────────────────

  /// The signed-in account for the migration checks: the widget's
  /// email first, then the session's stored email (the same
  /// resolution the knowledge load uses).
  Future<String?> _migrationEmail() async {
    var email = widget.email;
    if (email == null || email.isEmpty) {
      try {
        email = await _backend.readEmail();
      } catch (_) {}
    }
    return email;
  }

  /// Lab side: build the verbatim bundle and hand it to the share
  /// sheet as a file. Every failure lands in the status line with
  /// its code — never silent.
  Future<void> _exportMigration() async {
    setState(() {
      _migrationBusy = true;
      _migrationStatus = null;
    });
    try {
      final email = await _migrationEmail();
      final json = await _migration.buildExportJson(ownerEmail: email);
      final launched = await _migrationShare.shareMigrationFile(
        fileName: MigrationBundleService.fileName,
        content: json,
      );
      if (!mounted) return;
      setState(() => _migrationStatus = launched
          ? 'Your export is ready. Send the file to yourself, then '
              'open the Tabs app, sign in with the same account, and '
              'choose Import from Tabs Lab on this screen.'
          : 'Could not open the share sheet. Try again. '
              '[SHARE_FAILED]');
    } on MigrationException catch (e) {
      if (!mounted) return;
      setState(() => _migrationStatus = e.message);
    } on MigrationFileException catch (e) {
      if (!mounted) return;
      setState(() => _migrationStatus =
          'Could not share the export file. [${e.code}]');
    } catch (_) {
      if (!mounted) return;
      setState(() => _migrationStatus =
          'Export failed unexpectedly. Try again. [EXPORT_FAILED]');
    } finally {
      if (mounted) setState(() => _migrationBusy = false);
    }
  }

  /// Production side: pick the file, validate it against the
  /// signed-in account, and write the raw stores verbatim. ORDERING
  /// (Ivy's trap): [MigrationBundleService.importBundleJson] writes
  /// the blobs directly to secure storage, so no coach-memory load
  /// can run against a half-imported state. STALE MIRRORS (Vera
  /// BLOCK, Phase 4 fix): if Coach/History was opened earlier this
  /// session, the coach (and knowledge) mirrors are already warmed
  /// with pre-import state — the import invalidates those mirrors
  /// after its writes complete, so the next load reads the imported
  /// blob and no later persist can overwrite it from the stale
  /// mirror. A refusal (owner mismatch, damaged file) writes
  /// nothing and explains itself in the status line. After a
  /// successful import the reminder schedules are rebuilt
  /// immediately, so the imported check-in toggle takes effect
  /// without another screen visit.
  Future<void> _importMigration() async {
    String? text;
    try {
      text = await _migrationPicker.pickMigrationText();
    } on MigrationFileException catch (e) {
      if (!mounted) return;
      setState(() => _migrationStatus =
          'Could not read that file. [${e.code}]');
      return;
    }
    if (text == null) return; // user cancelled the picker
    setState(() {
      _migrationBusy = true;
      _migrationStatus = null;
    });
    try {
      final email = await _migrationEmail();
      final result =
          await _migration.importBundleJson(text, currentEmail: email);
      // Refresh the local-only values this screen renders from the
      // store the import just rewrote (check-in toggle above all —
      // it is a reconcile input below).
      try {
        _checkInEnabled = await _store.getCheckInReminderEnabled();
        // No theme-mode re-read: the disabled Appearance picker
        // never displays it (Juno ruling, Oct 2026). The imported
        // value stays in the store untouched.
        _showNavLabels = await _store.getShowNavLabels();
        _contextHidden = await _store.getUserContextHidden();
      } catch (_) {}
      await _reconcileAfterImport();
      if (!mounted) return;
      setState(() => _migrationStatus =
          'Imported ${result.importedKeys.length} data '
          '${result.importedKeys.length == 1 ? 'store' : 'stores'} '
          'from your Tabs Lab export. Your coach memory, settings, '
          'and history are now in this app, and your reminders have '
          'been rescheduled.');
    } on MigrationException catch (e) {
      if (!mounted) return;
      setState(() => _migrationStatus = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _migrationStatus =
          'Import failed unexpectedly. Nothing was changed. '
          '[IMPORT_FAILED]');
    } finally {
      if (mounted) setState(() => _migrationBusy = false);
    }
  }

  /// Post-import reminder rebuild: the same full resync the
  /// first-run hook performs (syncAll + user-reminder reconcile),
  /// driven by the freshly imported local settings + the server
  /// profile. Failures surface through the notifications error
  /// state, never as an import failure — the data already landed.
  Future<void> _reconcileAfterImport() async {
    try {
      await performReminderResync(
        backend: _backend,
        settingsStore: _store,
        notifications: _notifs,
      );
    } on NotificationServiceException catch (e) {
      if (mounted) setState(() => _notifError = e.code);
    } catch (_) {
      if (mounted) setState(() => _notifError = 'SCHEDULE_FAILED');
    }
  }

  /// Native manualSync = syncAllData (push + pull). The Lab's writes
  /// already go straight to the server, so the honest equivalent is a
  /// fresh pull; success stamps last-sync exactly as native does.
  Future<void> _manualSync() async {
    setState(() => _syncing = true);
    _backend.invalidateSyncPull();
    final body = await _backend.fetchSyncPull();
    if (!mounted) return;
    setState(() => _syncing = false);
    if (body != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _store.setLastSyncTimeMs(now);
      setState(() {
        _lastSyncMs = now;
        _data = SettingsProfileData.fromPull(body);
        // Vera F2: a manual sync IS a real data load — it must
        // set the same durability state _load sets, or a later
        // failed load would treat this data as never-loaded and
        // blank the screen to defaults (Defect B side door).
        _hasRealData = true;
        _syncConfirmed = true;
      });
      // Vera F2: the tombstone post-pass _load runs — a counter
      // deleted locally must not reappear via Sync Now while its
      // tombstone is still active.
      unawaited(_filterTombstonedCountersInPlace());
      _snack('Sync complete!');
    } else {
      _syncConfirmed = false;
      _snack('Sync failed. Check your connection and try again.');
    }
  }

  /// Native recoverAccountData = pullAllData with a fresh copy. Same
  /// honest pull equivalent as Sync Now, from a cold cache.
  Future<void> _recover() async {
    setState(() => _recovering = true);
    _backend.invalidateSyncPull();
    final body = await _backend.fetchSyncPull();
    if (!mounted) return;
    setState(() => _recovering = false);
    if (body != null) {
      setState(() {
        _data = SettingsProfileData.fromPull(body);
        // Vera F2: same durability state as _load / Sync Now.
        _hasRealData = true;
        _syncConfirmed = true;
      });
      unawaited(_filterTombstonedCountersInPlace());
      _snack('Recovered your latest data from the server.');
    } else {
      _syncConfirmed = false;
      _snack('Recovery failed. Check your connection and try again.');
    }
  }

  // ── Account dialogs (native :3944-4024) ──────────────────────────

  Future<void> _showLogoutDialog() async {
    var loggingOut = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: NotelColors.surface,
          title: const Text('Logout?',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loggingOut
                    ? 'Saving and syncing your data to the cloud...'
                    : 'Your data will be synced to the cloud before logging out.',
                style: const TextStyle(color: NotelColors.textPrimary),
              ),
              const SizedBox(height: 8),
              const Text(
                'Note: saving and syncing everything to the server may take a minute or two depending on how much data you have. Please keep the app open.',
                style: TextStyle(
                    color: NotelColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: loggingOut ? null : () => Navigator.of(ctx).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: NotelColors.textSecondary)),
            ),
            TextButton(
              key: const ValueKey('confirm_logout'),
              onPressed: loggingOut
                  ? null
                  : () async {
                      setLocal(() => loggingOut = true);
                      // Flush a Personal Context edit still inside
                      // its 3 s debounce before the wipe, or the edit
                      // would be lost on an immediate logout (R29b).
                      if (_contextDebounce?.isActive ?? false) {
                        _contextDebounce!.cancel();
                        await _pushProfile(
                            {'userContext': _contextController.text});
                      }
                      try {
                        await _actions.logout();
                      } catch (_) {
                        // AccountActions isolates every wipe step, so
                        // this is only a last-resort guard: even an
                        // unexpected wipe error must still complete
                        // the flow and fire onLogout rather than
                        // wedging this dialog in its logging-out
                        // state (R29b Vera fix).
                      }
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      widget.onLogout?.call();
                    },
              child: Text(loggingOut ? 'Saving...' : 'Logout',
                  style: const TextStyle(color: NotelColors.primary)),
            ),
          ],
        ),
      ),
    );
  }

  /// "Reset Account Status" dialog — founder fix (Oct 2026),
  /// deliberately diverging from native (SettingsScreen.kt:4005-
  /// 4022, where the same label hid a "Delete Account?" dialog whose
  /// confirm, `restartOnboarding`, deleted the account server-side;
  /// the Round 29 port copied that). The label now tells the truth:
  /// the reset clears the account's setup/onboarding status
  /// server-side and logs out, so the next sign-in runs setup again —
  /// the account, password, and data are NOT deleted (permanent
  /// deletion lives in User Profile → "Permanently Delete Account &
  /// Data"). Copy signed off by Juno (Oct 2026) with one required
  /// wording change, landed verbatim: the second paragraph must not
  /// promise "everything will still be here" — the logout wipe
  /// destroys device-only data (Coach memory; on-device health
  /// history incl. imported days and frozen Daily Scores), so the
  /// copy names those losses explicitly.
  Future<void> _showResetAccountDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Reset Account Status?',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: const Text(
            'This will log you out and reset your account\'s setup status. The next time you sign in, you\'ll go through the app setup again, like a new account.\n\nYour account, password, and server-saved data are not deleted — your logs, profile, and files will still be here when you finish setup. Like any log-out, this clears data stored only on this device: Coach memory is lost for good, and device-only health history is cleared — recent days re-sync from Health Connect, but imported history and past Daily Scores don\'t come back.',
            style: TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: const ValueKey('confirm_reset_account_status'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              // Same fault wrapper as the sibling account dialogs
              // (R29b pattern): resetAccountStatus is internally
              // fault-isolated, but a throw must still land on the
              // honest error state, never on a dead button.
              bool ok;
              try {
                ok = await _actions.resetAccountStatus();
              } catch (_) {
                ok = false;
              }
              if (ok) {
                widget.onLogout?.call();
              } else {
                _snack(
                    'Could not reset your account status. Check your connection and try again.');
              }
            },
            child: const Text('Reset',
                style: TextStyle(color: NotelColors.primary)),
          ),
        ],
      ),
    );
  }

  /// Native User Profile delete dialog (SettingsScreen.kt:3414-3456).
  Future<void> _showDeleteAccountDialog() async {
    var deleting = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: NotelColors.surface,
          title: const Text('Delete Account and Data?',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontWeight: FontWeight.bold)),
          content: const Text(
              'This action is permanent and cannot be undone. All your notes, history, files, health sync logs, and account profiles will be instantly purged from our servers and database.',
              style: TextStyle(
                  color: NotelColors.textSecondary, fontSize: 14)),
          actions: [
            TextButton(
              onPressed:
                  deleting ? null : () => Navigator.of(ctx).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: NotelColors.textSecondary)),
            ),
            TextButton(
              key: const ValueKey('confirm_delete_account'),
              onPressed: deleting
                  ? null
                  : () async {
                      setLocal(() => deleting = true);
                      bool ok;
                      try {
                        ok = await _actions.deleteAccount();
                      } catch (_) {
                        // deleteAccount returns false itself when the
                        // server delete fails, so a throw here can
                        // only come from the local wipe AFTER a
                        // successful server delete — the account is
                        // gone; complete the flow and fire onLogout
                        // rather than leaving a live local session
                        // behind (R29b Vera fix).
                        ok = true;
                      }
                      if (!mounted) return;
                      if (ok) {
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        widget.onLogout?.call();
                      } else {
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        setState(() => _deleteError =
                            'Could not delete your account. Check your connection and try again.');
                      }
                    },
              child: Text(deleting ? 'Deleting...' : 'Delete Permanently',
                  style: const TextStyle(color: NotelColors.error)),
            ),
          ],
        ),
      ),
    );
  }
}

/// HR threshold entry field with native's input guards ported
/// (SettingsScreen.kt spike field ~:3644-3655, delta field
/// ~:3725-3736): digits-only input with a length cap, and a value is
/// saved ONLY when it parses into [min]..[max]. Anything else is not
/// pushed and the visible text reverts to the current stored value —
/// previously any parsed int (0, -20, 99999) went verbatim to the
/// server profile (R29b Vera fix).
class _ThresholdField extends StatefulWidget {
  final String label;
  final String keyName;
  final int value;
  final String suffix;
  final String? prefix;
  final int min;
  final int max;
  final int maxLength;
  final ValueChanged<int> onSave;

  const _ThresholdField({
    required this.label,
    required this.keyName,
    required this.value,
    required this.suffix,
    this.prefix,
    required this.min,
    required this.max,
    required this.maxLength,
    required this.onSave,
  });

  @override
  State<_ThresholdField> createState() => _ThresholdFieldState();
}

class _ThresholdFieldState extends State<_ThresholdField> {
  late final TextEditingController _controller =
      TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(_ThresholdField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the field in sync when the stored value changes under it
    // (enable-time fix-up, server reload) — but never clobber text
    // the user is mid-edit on when it already parses to the value.
    if (widget.value != oldWidget.value &&
        int.tryParse(_controller.text) != widget.value) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String text) {
    final v = int.tryParse(text);
    if (v != null && v >= widget.min && v <= widget.max) {
      widget.onSave(v);
    } else {
      // Out of range (or unparseable): do not push; revert the field
      // to the current stored value, as native's guard implies.
      _controller.text = '${widget.value}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(widget.label,
              style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500)),
        ),
        SizedBox(
          width: 110,
          child: TextField(
            key: ValueKey(widget.keyName),
            controller: _controller,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(widget.maxLength),
            ],
            style: const TextStyle(color: NotelColors.textPrimary),
            decoration: InputDecoration(
              suffixText: widget.suffix,
              prefixText: widget.prefix,
              suffixStyle: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 12),
            ),
            onSubmitted: _submit,
          ),
        ),
      ],
    );
  }
}
