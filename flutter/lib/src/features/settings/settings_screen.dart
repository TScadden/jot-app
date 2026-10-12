import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

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
/// Honest unavailable states (native presentation kept, flagged in
/// the round report): Play purchase flow, Google Calendar / Google
/// Account linking (native GoogleSignIn SDK flows), profile Auto-Fill
/// (no HC weight/height reads in Flutter), file/text-note knowledge
/// ingestion + physician protocols + progress-report PDF (native
/// on-device Room/Gemini pipelines with no Flutter equivalent),
/// Tabs Live BLE, Developer Terminal test notifications, and the
/// notification-permission gate before reminder toggles (the Lab has
/// no notification scheduler; toggles persist the synced preference).
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

  /// Injectable for tests (native opens these in the system browser).
  final Future<bool> Function(Uri uri)? urlLauncher;

  const SettingsScreen({
    super.key,
    this.email,
    this.onLogout,
    this.backend,
    this.settingsStore,
    this.accountActions,
    this.healthConnectService,
    this.urlLauncher,
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

  _Page _page = _Page.main;
  SettingsProfileData _data = const SettingsProfileData();
  bool _loaded = false;

  // Device-only settings (SettingsStore).
  bool _showNavLabels = true;
  String _themeMode = 'DARK';
  bool _contextHidden = true;
  bool _checkInEnabled = true;
  int _lastSyncMs = 0;

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
    _backend = widget.backend ?? TabsBackend();
    _store = widget.settingsStore ?? SettingsStore();
    _actions = widget.accountActions ??
        AccountActions(backend: _backend, settingsStore: _store);
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
  Future<bool> _pushProfile(Map<String, dynamic> fields) async {
    final ok = await _backend.postSyncProfile(fields);
    if (!ok) {
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
          onTap: () => setState(() => _page = page),
          child: Container(
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
            backgroundColor: const Color(0xFF801515),
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
          GestureDetector(
            onTap: () => _openUrl('https://api.jottracker.com/terms.html'),
            child: const Text('Terms of Use',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: () => _openUrl('https://api.jottracker.com/privacy.html'),
            child: const Text('Privacy Policy',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ),
          const SizedBox(height: 4),
          TextButton(
            key: const ValueKey('reset_account_status'),
            onPressed: _showResetAccountDialog,
            child: Text('Reset Account Status',
                style: TextStyle(
                    color: NotelColors.error.withValues(alpha: 0.5),
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
      onTap: () => setState(() => _page = page),
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
                      fontSize: 15)),
            ),
            const Icon(Icons.keyboard_arrow_right,
                color: NotelColors.textSecondary),
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
                        fontSize: 18)),
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
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                foregroundColor: Colors.white),
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
            onTap: () => _openUrl(
                'https://play.google.com/store/account/subscriptions?sku=${_selectedPlan == 'monthly' ? 'jot_membership_monthly' : 'jot_membership_yearly'}&package=com.notel.notel.playground.flutter'),
            child: const Text(
                'Manage or cancel anytime in Google Play Subscriptions',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: NotelColors.primary, fontSize: 11)),
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
                      fontSize: 9,
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
                foregroundColor: NotelColors.textPrimary),
            onPressed: _showEditProfileDialog,
            child: const Text('Edit Profile',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.surfaceHigh,
                foregroundColor: NotelColors.textPrimary),
            onPressed: () => _snack(
                'Auto-fill needs Health Connect weight and height reads, which are not available in the Flutter Lab yet.'),
            icon: const Icon(Icons.sync, color: NotelColors.primary),
            label: const Text('Auto-Fill from Connected Apps'),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      // Medications + Conditions (native :3029/:3202 live inside this
      // page; the full editors are native Room-backed, read-only here).
      _card([
        const Text('Medications',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.w500)),
        const Text('Track your current and historical medications',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 8),
        ...d.medications.map((m) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('${m['name'] ?? ''}',
                  style: const TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 14)),
            )),
        const Text(
            'Adding and editing medications is not available in the Flutter Lab yet.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
      ]),
      const SizedBox(height: 16),
      _card([
        const Text('Conditions',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.w500)),
        const Text('Diagnosed or suspected conditions',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: d.conditions
              .map((c) => Chip(
                    label: Text('${c['name'] ?? ''}'),
                    backgroundColor: NotelColors.surfaceHigh,
                    labelStyle:
                        const TextStyle(color: NotelColors.textPrimary),
                  ))
              .toList(),
        ),
        const Text(
            'Adding and removing conditions is not available in the Flutter Lab yet.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
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
              final age = int.tryParse(ageC.text) ?? 0;
              final totalIn =
                  (int.tryParse(ftC.text) ?? 0) * 12 +
                      (int.tryParse(inC.text) ?? 0);
              final weightLbs = double.tryParse(weightC.text) ?? 0;
              final heightCm = totalIn * 2.54;
              final weightKg = weightLbs / 2.20462;
              // Native saveUserProfile (SettingsViewModel.kt:653-659):
              // DataStore + pushProfileData with cm/kg conversions.
              final ok = await _pushProfile({
                'age': age,
                'heightCm': heightCm,
                'weightKg': weightKg,
                'gender': genderC.text,
              });
              if (ok && mounted) {
                setState(() {
                  _data = _data.copyWith(
                    age: age,
                    heightCm: heightCm,
                    weightKg: weightKg,
                    gender: genderC.text,
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
      _card([
        const Text('Google Health Connect',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.w500)),
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
            onPressed: () {
              Navigator.of(context).push(
                SlidePageRoute(
                  reducedMotion: animationsDisabled(context),
                  builder: (_) => ConnectionsScreen(
                      healthConnectService: widget.healthConnectService),
                ),
              );
            },
            child: const Text('Connect Health Data',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ]),
      const SizedBox(height: 24),
      _sectionLabel('INTEGRATED APPS'),
      _card([
        const Text('Google Calendar',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.w500)),
        const Text(
            'Let your AI Clinical Advocate schedule events and update calendars.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 8),
        const Text(
            'Google Calendar linking uses the native Google sign-in flow and is not available in the Flutter Lab yet.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
        const SizedBox(height: 16),
        const Text('Google Account',
            style: TextStyle(
                color: NotelColors.textPrimary, fontWeight: FontWeight.w500)),
        const Text(
            'Link your Google account to sign in with Google or email & password.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 8),
        const Text(
            'Linking or disconnecting a Google account is not available in the Flutter Lab yet.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
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
      if (updates.isNotEmpty) ...[
        _sectionLabel('PHYSICIAN PROTOCOLS'),
        _card([
          ...updates.map((u) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(u,
                    style: const TextStyle(
                        color: NotelColors.textPrimary, fontSize: 13)),
              )),
          const Text(
              'Adding and editing protocol updates is not available in the Flutter Lab yet.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
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
          ...facts.map((f) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(f,
                    style: const TextStyle(
                        color: NotelColors.textPrimary, fontSize: 13)),
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
              foregroundColor: NotelColors.textPrimary),
          onPressed: () => _showCounterDialog(null),
          icon: const Icon(Icons.add, color: NotelColors.primary),
          label: const Text('Add New Counter'),
        ),
      ),
      const SizedBox(height: 16),
      _card([
        if (counters.isEmpty)
          const Text('No counters yet.',
              style:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 13))
        else ...[
          ...active.map((c) => _counterRow(c, archived: false)),
          if (archived.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('ARCHIVED',
                  style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w900)),
            ),
            ...archived.map((c) => _counterRow(c, archived: true)),
          ],
        ],
        const SizedBox(height: 12),
        const Text(
            'Track important upcoming or past events. All active counters will show on the main screen and sync with the AI.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Past Counters:',
              style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
          ...history.map((h) {
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
            return Text('${h['name'] ?? ''} (Ended: $label)',
                style: const TextStyle(
                    color: NotelColors.textSecondary, fontSize: 11));
          }),
        ],
      ]),
    ];
  }

  Widget _counterRow(EventCounterItem c, {required bool archived}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name,
                    style: TextStyle(
                        color: NotelColors.textPrimary,
                        fontWeight:
                            archived ? FontWeight.w600 : FontWeight.bold,
                        fontSize: archived ? 12 : 13)),
                Text(c.daysLabel(),
                    style: TextStyle(
                        color: archived
                            ? NotelColors.textSecondary
                            : NotelColors.primary,
                        fontSize: archived ? 10 : 11)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(archived ? Icons.unarchive : Icons.archive,
                size: 20, color: NotelColors.textSecondary),
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
            icon: const Icon(Icons.edit,
                size: 20, color: NotelColors.textSecondary),
            onPressed: () => _showCounterDialog(c),
          ),
          IconButton(
            icon: const Icon(Icons.stop_circle,
                size: 20, color: NotelColors.textSecondary),
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
  // Native gates enabling a reminder on the POST_NOTIFICATIONS system
  // permission (checkAndToggle / handleCheckInReminderToggle with a
  // rationale dialog for the check-in reminder). The Flutter Lab has
  // no notification scheduler or permission channel, so the toggles
  // persist the preference exactly as native does (DataStore locally
  // for check-in; profile push for the rest) and the copy says the
  // Lab cannot fire them yet — flagged in the round report.

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
            setState(() => _data = _data.copyWith(habitReminderEnabled: v));
            await _pushProfile({'habitReminderEnabled': v});
          },
          key: const ValueKey('habit_reminder_toggle'),
        ),
        const SizedBox(height: 20),
        _toggleRow(
          'Project Reminders',
          'Daily ping at 8:00 PM if you have unchecked project tasks remaining.',
          d.projectReminderEnabled,
          (v) async {
            setState(
                () => _data = _data.copyWith(projectReminderEnabled: v));
            await _pushProfile({'projectReminderEnabled': v});
          },
          key: const ValueKey('project_reminder_toggle'),
        ),
        const SizedBox(height: 20),
        _toggleRow(
          'Event Reminders',
          'Daily ping at 9:00 AM on the day of scheduled events.',
          d.eventReminderEnabled,
          (v) async {
            setState(() => _data = _data.copyWith(eventReminderEnabled: v));
            await _pushProfile({'eventReminderEnabled': v});
          },
          key: const ValueKey('event_reminder_toggle'),
        ),
        const SizedBox(height: 20),
        _toggleRow(
          'Remind me to log how I feel',
          'Daily at 4:00 AM, only if you have not checked in yet.',
          _checkInEnabled,
          (v) async {
            setState(() => _checkInEnabled = v);
            await _store.setCheckInReminderEnabled(v);
          },
          key: const ValueKey('checkin_reminder_toggle'),
        ),
        const SizedBox(height: 20),
        _toggleRow(
          'HR Spike Alerts',
          'Real-time alert when your heart rate exceeds ${d.spikeThreshold} BPM.',
          d.hrSpikeAlertsEnabled,
          (v) async {
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
          _thresholdField(
            'Alert Threshold',
            'spike_threshold_field',
            d.spikeThreshold,
            'BPM',
            null,
            (v) async {
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
          _thresholdField(
            'Jump Threshold',
            'delta_threshold_field',
            d.spikeDeltaThreshold,
            'BPM',
            '+',
            (v) async {
              setState(
                  () => _data = _data.copyWith(spikeDeltaThreshold: v));
              await _pushProfile({'spikeDeltaThreshold': v});
            },
          ),
        ],
        const SizedBox(height: 16),
        const Text(
            'Reminder preferences save exactly as in the native app. The Flutter Lab does not schedule notifications yet, so these reminders will not fire from the Lab.',
            style:
                TextStyle(color: NotelColors.textSecondary, fontSize: 11)),
      ]),
    ];
  }

  Widget _thresholdField(String label, String keyName, int value,
      String suffix, String? prefix, ValueChanged<int> onSave) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500)),
        ),
        SizedBox(
          width: 110,
          child: TextFormField(
            key: ValueKey(keyName),
            initialValue: '$value',
            keyboardType: TextInputType.number,
            style: const TextStyle(color: NotelColors.textPrimary),
            decoration: InputDecoration(
              suffixText: suffix,
              prefixText: prefix,
              suffixStyle: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 12),
            ),
            onFieldSubmitted: (text) {
              final v = int.tryParse(text);
              if (v != null) onSave(v);
            },
          ),
        ),
      ],
    );
  }

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
                      await _actions.logout();
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
                      final ok = await _actions.deleteAccount();
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
