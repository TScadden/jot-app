import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tabs_lab/src/data/calendar_service.dart';
import 'package:tabs_lab/src/data/common_conditions.dart';
import 'package:tabs_lab/src/data/google_sign_in_service.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';
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
/// Honest unavailable states (native presentation kept, flagged in
/// the round report): Play purchase flow, file/text-note knowledge
/// ingestion + progress-report PDF (native on-device Room/Gemini
/// pipelines with no Flutter equivalent), Tabs Live BLE, and
/// Developer Terminal test notifications.
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

  /// Injectable for tests (native opens these in the system browser).
  final Future<bool> Function(Uri uri)? urlLauncher;

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
    this.urlLauncher,
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
  late final SettingsStore _store;
  late final AccountActions _actions;
  late final ReminderNotificationService _notifs;
  late final GoogleSignInService _google;
  late final HealthConnectService _hc;

  late _Page _page;
  SettingsProfileData _data = const SettingsProfileData();
  bool _loaded = false;

  // Device-only settings (SettingsStore).
  bool _showNavLabels = true;
  String _themeMode = 'DARK';
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

  String _selectedPlan = 'monthly';
  bool _syncing = false;
  bool _recovering = false;
  bool _showInsights = false;
  bool _privacyExpanded = false;
  String? _deleteError;

  final _contextController = TextEditingController();
  bool _contextSeeded = false;
  Timer? _contextDebounce;

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
    _load();
  }

  @override
  void dispose() {
    _contextDebounce?.cancel();
    _contextController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait<dynamic>([
      _backend.fetchSyncPull(),
      _store.getShowNavLabels(),
      _store.getThemeMode(),
      _store.getUserContextHidden(),
      _store.getCheckInReminderEnabled(),
      _store.getLastSyncTimeMs(),
    ]);
    if (!mounted) return;
    final data = SettingsProfileData.fromPull(
        results[0] as Map<String, dynamic>?);
    setState(() {
      _data = data;
      _showNavLabels = results[1] as bool;
      _themeMode = results[2] as String;
      _contextHidden = results[3] as bool;
      _checkInEnabled = results[4] as bool;
      _lastSyncMs = results[5] as int;
      _loaded = true;
      if (!_contextSeeded) {
        _contextController.text = data.userContext;
        _contextSeeded = true;
      }
    });
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
      if (!mounted) return;
      setState(() {
        _hcStatus = status;
        _hcErrorCode = null;
      });
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

  Future<void> _reloadFromServer() async {
    _backend.invalidateSyncPull();
    await _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
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
    } else {
      _snack('Could not save. Check your connection and try again.');
      await _reloadFromServer();
    }
    return ok;
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          if (_page == _Page.progressReports) ..._unavailablePage(
              'Progress Reports build a PDF from your on-device log history in the native app. PDF report generation is not available in the Flutter Lab yet.'),
        ],
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
        const Text("Tell Tabs about your goals (e.g. 'training for a marathon').",
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
        setState(() => _page = page);
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
          onPressed: _loaded ? _reloadFromServer : null,
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
        _planCard('monthly', 'Monthly Plan', 'FREE TRIAL',
            NotelColors.primary),
        const SizedBox(height: 12),
        _planCard('yearly', 'Yearly Plan', 'BEST VALUE',
            NotelColors.success),
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
            // Native CTA label comes from the live Play trial period;
            // with no Play catalog in the Lab it falls back to the
            // configured 7-day trial (flagged in the round report).
            label: const Text('Start 7-day free trial',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Auto-renews until canceled. Billed by Google Play.',
          textAlign: TextAlign.center,
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 11),
        ),
        const SizedBox(height: 12),
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openUrl(
                'https://play.google.com/store/account/subscriptions?sku=${_selectedPlan == 'monthly' ? 'jot_membership_monthly' : 'jot_membership_yearly'}&package=com.notel.notel.playground.flutter'),
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

  Future<void> _saveMedications(List<Map<String, dynamic>> meds) async {
    final raw = jsonEncode(meds);
    setState(() => _data = _data.copyWith(medicationsRaw: raw));
    await _pushProfile({'medications': raw});
  }

  Future<void> _deleteMedication(String id) async {
    // Native deleteMedication (SettingsViewModel.kt:976-989): drop
    // from the profile list and push the whole list.
    await _saveMedications(
        _data.medications.where((m) => '${m['id'] ?? ''}' != id).toList());
  }

  /// Round 39 — archive via the shared model (the same op the
  /// Tools Medications tab runs): archiving stamps the end date
  /// with today and flips `isPresent` off, native semantics.
  ///
  /// Vera R39 fix pass: [rawIndex] is the row's index in the full
  /// medications list — the op targets that exact row by position
  /// (Finding 1: no name/id first-match, so id-less duplicates
  /// can never stamp the wrong row), and the document is built
  /// from the raw maps `_data.medications` already holds, so the
  /// splice-back encode retains unparseable rows verbatim and
  /// extra non-DTO keys (Finding 2). Saved through the existing
  /// [_saveMedications], so push/failure behavior is unchanged.
  Future<void> _archiveMedication(int rawIndex) async {
    final doc = MedicationDocument.fromRawRows(_data.medications);
    final updated = doc.archiveAt(rawIndex, now: DateTime.now());
    await _saveMedications(updated.encode());
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
                await _saveMedications([..._data.medications, med]);
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
        const Text("Choose how Tabs looks. System follows your phone's setting.",
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
        const SizedBox(height: 10),
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
                      backgroundColor: _themeMode == mode
                          ? NotelColors.primary
                          : NotelColors.surfaceHigh,
                      foregroundColor: _themeMode == mode
                          ? Colors.white
                          : NotelColors.textSecondary,
                    ),
                    onPressed: () async {
                      setState(() => _themeMode = mode);
                      await _store.setThemeMode(mode);
                    },
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: _themeMode == mode
                                ? FontWeight.bold
                                : FontWeight.w500)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // The Lab renders the native dark palette; the choice persists
        // exactly as native's DataStore key does (flagged in report).
        const Text(
            'Your choice is saved on this device. The Flutter Lab currently renders the dark theme.',
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
          const Text(
              'Some health permissions are still missing. Grant the remaining permissions to sync everything.',
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
              onPressed: _connectGoogleCalendar,
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
            Text('Past $_professionalType Updates',
                style: const TextStyle(
                    color: NotelColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            ...updates.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(e.value,
                            style: const TextStyle(
                                color: NotelColors.textPrimary,
                                fontSize: 13)),
                      ),
                      IconButton(
                        key: ValueKey('edit_protocol_${e.key}'),
                        icon: const Icon(Icons.edit,
                            size: 18, color: NotelColors.textSecondary),
                        onPressed: () => _showEditJoinedEntryDialog(
                          title: 'Edit $_professionalType Update',
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
                        key: ValueKey('delete_protocol_${e.key}'),
                        icon: const Icon(Icons.delete,
                            size: 18, color: NotelColors.error),
                        onPressed: () {
                          final list = [...updates]..removeAt(e.key);
                          _saveProfessionalUpdates(list);
                        },
                      ),
                    ],
                  ),
                )),
          ],
        ]),
        const SizedBox(height: 24),
      ],
      _sectionLabel('FILE KNOWLEDGE BASE'),
      _card([
        const Text('Digital Knowledge Extraction',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        if (facts.isEmpty)
          const Text('No extracted facts yet.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 12))
        else
          ...facts.asMap().entries.map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(e.value,
                          style: const TextStyle(
                              color: NotelColors.textPrimary, fontSize: 13)),
                    ),
                    IconButton(
                      key: ValueKey('edit_fact_${e.key}'),
                      icon: const Icon(Icons.edit,
                          size: 18, color: NotelColors.textSecondary),
                      onPressed: () => _showEditJoinedEntryDialog(
                        title: 'Edit Fact',
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
                          size: 18, color: NotelColors.error),
                      onPressed: () {
                        final list = [...facts]..removeAt(e.key);
                        _saveKnowledgeBase(list);
                      },
                    ),
                  ],
                ),
              )),
        const SizedBox(height: 8),
        const Text(
            'Uploading documents and text notes for extraction runs in the native app and is not available in the Flutter Lab yet.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
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

  Future<void> _saveCounters(List<EventCounterItem> counters,
      {List<Map<String, dynamic>>? history}) async {
    final raw =
        jsonEncode(counters.map((c) => c.toMap()).toList());
    final fields = <String, dynamic>{'eventCounters': raw};
    String? historyRaw;
    if (history != null) {
      historyRaw = jsonEncode(history);
      fields['counterHistory'] = historyRaw;
    }
    setState(() {
      _data = _data.copyWith(
          eventCountersRaw: raw, counterHistoryRaw: historyRaw);
    });
    await _pushProfile(fields);
    // Native arms/cancels the counter's 9 AM alarm in the same save
    // (SettingsViewModel.kt:1270); re-sync all event schedules.
    await _syncReminders();
  }

  List<Widget> _countersPage() {
    final counters = _counters;
    final active = counters.where((c) => !c.isArchived).toList();
    final archived = counters.where((c) => c.isArchived).toList();
    final history = _data.counterHistory;
    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _sectionLabel('EVENT COUNTERS'),
          const Row(
            children: [
              Icon(Icons.cloud_done, color: NotelColors.primary, size: 16),
              SizedBox(width: 4),
              Text('Synced',
                  style: TextStyle(
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
          onPressed: () => _showCounterDialog(null),
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
        _counterCard(active, archived: false),
      if (archived.isNotEmpty) ...[
        const SizedBox(height: 16),
        _sectionLabel('ARCHIVED'),
        _counterCard(archived, archived: true),
      ],
      if (history.isNotEmpty) ...[
        const SizedBox(height: 16),
        _sectionLabel('PAST COUNTERS'),
        _card(_pastCounterRows(history),
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
  Widget _counterCard(List<EventCounterItem> list,
      {required bool archived}) {
    final children = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      if (i > 0) {
        children.add(const Divider(color: NotelColors.divider, height: 1));
      }
      children.add(_counterRow(list[i], archived: archived));
    }
    return _card(children,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8));
  }

  List<Widget> _pastCounterRows(List<Map<String, dynamic>> history) {
    final rows = <Widget>[];
    for (var i = 0; i < history.length; i++) {
      if (i > 0) {
        rows.add(const Divider(color: NotelColors.divider, height: 1));
      }
      final h = history[i];
      final ended = h['endedAt'];
      final ms = ended is num
          ? ended.toInt()
          : (ended is String ? int.tryParse(ended) ?? 0 : 0);
      final date = DateTime.fromMillisecondsSinceEpoch(ms);
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      final label =
          '${months[date.month - 1]} ${date.day.toString().padLeft(2, '0')}, ${date.year}';
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('${h['name'] ?? ''} (Ended: $label)',
            style: const TextStyle(
                color: NotelColors.textSecondary, fontSize: 11)),
      ));
    }
    return rows;
  }

  Widget _counterRow(EventCounterItem c, {required bool archived}) {
    // Archived rows recede: name and day label both render in the
    // muted secondary tone at the smaller sizes. Active rows stay
    // full strength with the Tabs-purple day label.
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
                    style: TextStyle(
                        color: archived
                            ? NotelColors.textSecondary
                            : NotelColors.textPrimary,
                        fontWeight:
                            archived ? FontWeight.w600 : FontWeight.bold,
                        fontSize: archived ? 12 : 13)),
                const SizedBox(height: 2),
                Text(c.daysLabel(),
                    style: TextStyle(
                        color: archived
                            ? NotelColors.textSecondary
                            : NotelColors.primary,
                        fontSize: archived ? 10 : 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Right rail: the same three actions in the same order,
          // each on an explicit 48dp touch target with a tooltip
          // (the tooltip doubles as the semantics label).
          IconButton(
            key: ValueKey('counter_archive_${c.id}'),
            tooltip: archived ? 'Unarchive counter' : 'Archive counter',
            constraints:
                const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(archived ? Icons.unarchive : Icons.archive,
                size: 18, color: NotelColors.textSecondary),
            onPressed: () async {
              final updated = _counters
                  .map((x) => x.id == c.id
                      ? x.copyWith(isArchived: !x.isArchived)
                      : x)
                  .toList();
              await _saveCounters(updated);
            },
          ),
          IconButton(
            key: ValueKey('counter_edit_${c.id}'),
            tooltip: 'Edit counter',
            constraints:
                const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.edit,
                size: 18, color: NotelColors.textSecondary),
            onPressed: () => _showCounterDialog(c),
          ),
          IconButton(
            key: ValueKey('counter_end_${c.id}'),
            tooltip: 'End counter',
            constraints:
                const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.stop_circle,
                size: 18, color: NotelColors.textSecondary),
            onPressed: () async {
              // Native endCounterAndSave: remove + append to history.
              final remaining =
                  _counters.where((x) => x.id != c.id).toList();
              final history = [
                {
                  'name': c.name,
                  'targetDate': c.targetDate,
                  'endedAt': DateTime.now().millisecondsSinceEpoch,
                },
                ..._data.counterHistory,
              ].take(20).toList();
              await _saveCounters(remaining, history: history);
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
                final counters = _counters;
                if (existing != null) {
                  await _saveCounters(counters
                      .map((x) => x.id == existing.id
                          ? x.copyWith(
                              name: name,
                              targetDate: ms,
                              isUp: isUp,
                              autoUp: autoUp)
                          : x)
                      .toList());
                } else {
                  // Native dedupes duplicate names with (2), (3)…
                  final names = counters.map((x) => x.name).toSet();
                  var unique = name;
                  var suffix = 2;
                  while (names.contains(unique)) {
                    unique = '$name ($suffix)';
                    suffix++;
                  }
                  counters.add(EventCounterItem(
                    id: '${DateTime.now().millisecondsSinceEpoch}',
                    name: unique,
                    targetDate: ms,
                    isUp: isUp,
                    autoUp: autoUp,
                    isFavorite: counters.isEmpty,
                  ));
                  await _saveCounters(counters);
                }
                if (ctx.mounted) Navigator.of(ctx).pop();
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
    ];
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
      });
      _snack('Sync complete!');
    } else {
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
      setState(() => _data = SettingsProfileData.fromPull(body));
      _snack('Recovered your latest data from the server.');
    } else {
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

  /// Native "Reset Account Status" dialog (SettingsScreen.kt:4005-
  /// 4022): title "Delete Account?", confirm calls restartOnboarding
  /// which deletes the account server-side and logs out.
  Future<void> _showResetAccountDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Delete Account?',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: const Text(
            'This will permanently delete your account and all associated data from our servers. You will be logged out immediately and cannot undo this.',
            style: TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            key: const ValueKey('confirm_reset_delete'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final ok = await _actions.deleteAccount();
              if (ok) {
                widget.onLogout?.call();
              } else {
                _snack(
                    'Could not delete your account. Check your connection and try again.');
              }
            },
            child: const Text('Delete Account',
                style: TextStyle(color: Colors.red)),
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
