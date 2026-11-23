import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// MCP v1.1 — "Connect an AI" screen (Juno copy pack §c, FINAL,
/// `build-tabs-mcp-v11/JUNO-COPY.md`). Every user-facing string
/// on this screen is Juno's verbatim text from [ConnectAiCopy];
/// any change needs her re-sign. The two failure lines
/// ([ConnectAiCopy.loadError] / [ConnectAiCopy.disconnectError])
/// are the exceptions: Juno's pack carries no error strings, so
/// they follow the app's existing failure-line patterns
/// (streak_screen / history_screen) and are flagged for her in
/// the PR.
///
/// This screen is SEE + REVOKE ONLY. There is deliberately no
/// connection-creation UI and no credential display anywhere:
/// connecting happens in the AI app's own sign-in flow, and the
/// list payload is metadata only (name, connected date,
/// last-used date). Rows come from `GET /api/api-tokens` via
/// [TabsBackend.fetchAiConnections]; Disconnect confirms, then
/// POSTs the revoke and removes the row only on success — a
/// failed revoke keeps the row and surfaces an error (never a
/// silent no-op).
class ConnectAiCopy {
  // Juno §c — verbatim.
  static const String title = 'Connect an AI';
  static const String howItWorks =
      "Start in your AI app: add Tabs as a connection, sign in, and "
      "approve. That's it — nothing connects without your say-so.";
  static const String blurb =
      'Connecting an AI lets it read your Tabs data — your log '
      'entries, Daily Scores, streak, gems, badges, and medications '
      'list. It can only read, never change anything. Disconnect '
      'anytime here, and access stops right away.';
  static const String connectedLabel = 'Connected';
  static const String emptyState =
      'Nothing is connected yet. To connect an AI, open your AI app '
      "and add Tabs as a connection — you'll sign in and approve "
      'it there.';
  static const String disconnectButton = 'Disconnect';
  static String disconnectConfirmTitle(String name) =>
      'Disconnect $name?';
  static String disconnectConfirmBody(String name) =>
      '$name will stop being able to read your Tabs data right '
      'away. Anything it already read stays with that company, '
      'under its own privacy policy.';
  static const String confirmButton = 'Disconnect';
  static const String cancelButton = 'Cancel';
  static const String helpLinkLabel = 'How to connect an AI';

  // Failure lines — app-pattern chrome, flagged for Juno (see
  // the class doc). NOT from her pack.
  static const String loadError =
      "Couldn't load your connections right now. Try again later.";
  static const String disconnectError =
      "Couldn't disconnect that app — try again.";
  static const String helpOpenError =
      "Couldn't open that page — try again.";
}

/// The help page (Juno copy pack §d), live with the v1.1 server
/// deploy. Opened in the browser, never in-app.
const String connectAiHelpUrl =
    'https://jottracker.com/use-tabs-with-ai.html';

class ConnectAiScreen extends StatefulWidget {
  final TabsBackend? backend;

  /// Test seam for the help link (url_launcher's platform channel
  /// is awkward to drive in widget tests). Returns true when the
  /// browser opened. Production default: [launchUrl] external.
  final Future<bool> Function(Uri uri)? openUrl;

  const ConnectAiScreen({super.key, this.backend, this.openUrl});

  @override
  State<ConnectAiScreen> createState() => _ConnectAiScreenState();
}

class _ConnectAiScreenState extends State<ConnectAiScreen> {
  late final TabsBackend _backend;

  /// Null until the first load lands (the loading row renders).
  List<AiConnectionDto>? _connections;
  String? _loadError;

  /// Ids with a revoke in flight — their Disconnect buttons are
  /// disabled so a connection can't be double-revoked.
  final Set<String> _revoking = {};

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  Future<void> _load() async {
    List<AiConnectionDto>? list;
    try {
      list = await _backend.fetchAiConnections();
    } catch (_) {
      list = null;
    }
    if (!mounted) return;
    setState(() {
      if (list == null) {
        // Keep any already-shown rows on a refresh failure; the
        // error line explains, and pull-to-refresh can retry.
        _loadError = ConnectAiCopy.loadError;
        _connections ??= const [];
      } else {
        _connections = list;
        _loadError = null;
      }
    });
  }

  Future<void> _confirmDisconnect(AiConnectionDto connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: Text(
          ConnectAiCopy.disconnectConfirmTitle(connection.name),
          style: const TextStyle(
            color: NotelColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          ConnectAiCopy.disconnectConfirmBody(connection.name),
          style: const TextStyle(color: NotelColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              ConnectAiCopy.cancelButton,
              style: TextStyle(color: NotelColors.textSecondary),
            ),
          ),
          TextButton(
            key: const ValueKey('confirm_disconnect'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              ConnectAiCopy.confirmButton,
              style: TextStyle(color: NotelColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _revoking.add(connection.id));
    var success = false;
    try {
      success = await _backend.revokeAiConnection(connection.id);
    } catch (_) {
      success = false;
    }
    if (!mounted) return;
    setState(() {
      _revoking.remove(connection.id);
      if (success) {
        _connections = _connections
            ?.where((c) => c.id != connection.id)
            .toList();
      }
    });
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(ConnectAiCopy.disconnectError)),
      );
    }
  }

  Future<void> _openHelp() async {
    final uri = Uri.parse(connectAiHelpUrl);
    var opened = false;
    try {
      opened = await (widget.openUrl ??
          (u) => launchUrl(u, mode: LaunchMode.externalApplication))(
        uri,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(ConnectAiCopy.helpOpenError)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final connections = _connections;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back, color: NotelColors.primary),
          tooltip: 'Back',
        ),
        title: const Text(
          ConnectAiCopy.title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        centerTitle: true,
        actions: const [SizedBox(width: 48)],
      ),
      body: RefreshIndicator(
        color: NotelColors.primary,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              ConnectAiCopy.howItWorks,
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 14,
                height: 20 / 14,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              ConnectAiCopy.blurb,
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
                height: 20 / 14,
              ),
            ),
            const SizedBox(height: 24),
            const _SectionLabel(ConnectAiCopy.connectedLabel),
            const SizedBox(height: 8),
            if (connections == null)
              const _LoadingRow()
            else if (connections.isEmpty)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  ConnectAiCopy.emptyState,
                  style: TextStyle(
                    color: Color(0x807A8FAF),
                    fontSize: 14,
                    height: 20 / 14,
                  ),
                ),
              )
            else
              for (var i = 0; i < connections.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                _AiConnectionRow(
                  key: ValueKey('ai_connection_${connections[i].id}'),
                  connection: connections[i],
                  revoking: _revoking.contains(connections[i].id),
                  onDisconnect: () => _confirmDisconnect(connections[i]),
                ),
              ],
            if (_loadError != null) ...[
              const SizedBox(height: 12),
              Text(
                _loadError!,
                style: const TextStyle(
                  color: NotelColors.error,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 24),
            _HelpLinkRow(onTap: _openHelp),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: NotelColors.textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: NotelColors.primary,
          ),
        ),
      ),
    );
  }
}

/// One connected AI app: name, when it connected, when it was
/// last used (when the server reports it), and its Disconnect
/// button. Styled to match the Data connections rows (20dp
/// radius surface card, 14sp bold name, 12sp status lines).
class _AiConnectionRow extends StatelessWidget {
  final AiConnectionDto connection;
  final bool revoking;
  final VoidCallback onDisconnect;

  const _AiConnectionRow({
    super.key,
    required this.connection,
    required this.revoking,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final connectedAt = connection.connectedAt;
    final lastUsedAt = connection.lastUsedAt;
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                color: NotelColors.legacyDarkHairlineFaint,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.smart_toy_outlined,
                color: NotelColors.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connection.name,
                    style: const TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (connectedAt != null)
                    Text(
                      'Connected ${_formatConnectionDate(connectedAt)}',
                      style: const TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  if (lastUsedAt != null)
                    Text(
                      'Last used ${_formatConnectionDate(lastUsedAt)}',
                      style: const TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              key: ValueKey('disconnect_${connection.id}'),
              onPressed: revoking ? null : onDisconnect,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: NotelColors.error,
              ),
              child: revoking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: NotelColors.primary,
                      ),
                    )
                  : const Text(ConnectAiCopy.disconnectButton),
            ),
          ],
        ),
      ),
    );
  }
}

/// The help link row: Juno's label, opens the help page in the
/// browser. A full-width tappable row (48dp+ hit area).
class _HelpLinkRow extends StatelessWidget {
  final VoidCallback onTap;
  const _HelpLinkRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.help_outline,
                  color: NotelColors.primary,
                  size: 24,
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Text(
                    ConnectAiCopy.helpLinkLabel,
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  Icons.open_in_new,
                  color: NotelColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `MMM d, yyyy` (e.g. "Nov 22, 2026"), device-local — the app's
/// house date format (hand-rolled month table, the
/// medications.dart / heart_data.dart pattern; no intl).
String _formatConnectionDate(DateTime d) {
  const months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[d.month]} ${d.day}, ${d.year}';
}
