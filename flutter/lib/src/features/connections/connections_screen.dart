import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/features/connections/health_connect_disclosure.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 12 — data connections screen.
///
/// Faithful port of the native `DataConnectionsScreen.kt`:
/// - TopAppBar: centered "Data connections" (20sp Bold), purple back arrow,
///   48dp spacer balancing the nav icon.
/// - "Your connections" / "Add connections" sections with tappable
///   ConnectionItem rows (20dp radius, NotelSurface, 1dp surfaceHigh@30%
///   border, 44dp logo circle, 14sp Bold name + 12sp status, chevron).
/// - "Unavailable" section: the retired Fitbit card with the native copy
///   verbatim (Google retired the Fitbit Web API Oct 30, 2026).
/// - "How to connect a tracker" help section, native copy verbatim.
/// - Management bottom sheet for a connected row (status, grant-remaining
///   when partial, "Deactivate in Tabs", "Manage system permissions").
///
/// Health Connect row states: Connected (green) / Partially connected
/// (warning) / Available (tap → permission flow) / Not available on this
/// device (disabled). Every channel failure surfaces visibly as [CODE].
class ConnectionsScreen extends StatefulWidget {
  final HealthConnectService? healthConnectService;
  final VoidCallback? onBack;

  const ConnectionsScreen({super.key, this.healthConnectService, this.onBack});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  late final HealthConnectService _service;
  HealthConnectStatus? _status;
  bool _persistedConnected = false;
  bool _requesting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.healthConnectService ?? HealthConnectService();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    // Fast first paint from persisted state (shared with onboarding),
    // then confirm with the live check.
    try {
      final persisted = await _service.hasPersistedConnection();
      if (mounted) setState(() => _persistedConnected = persisted);
    } catch (_) {}
    try {
      final status = await _service.getStatus();
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } on HealthConnectException catch (e) {
      if (mounted) {
        setState(() {
          _status = _persistedConnected
              ? HealthConnectStatus.connected
              : HealthConnectStatus.notConnected;
          _error = '[${e.code}] ${e.message}';
        });
      }
    }
  }

  Future<void> _onConnectTap() async {
    if (_requesting) return;
    // MF-3 (Juno compliance): prominent in-app disclosure BEFORE the
    // system permission UI. "Not now" or dismissal never triggers it.
    final proceed = await showHealthConnectDisclosure(context);
    if (!proceed || !mounted) return;
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      final granted = await _service.requestPermissions();
      if (!mounted) return;
      setState(() {
        _requesting = false;
        if (granted.containsAll(HealthConnectService.requiredPermissions)) {
          _status = HealthConnectStatus.connected;
        } else if (granted.isEmpty) {
          _error = 'No permissions were granted.';
          _status = HealthConnectStatus.notConnected;
        } else {
          _status = HealthConnectStatus.partiallyConnected;
        }
      });
    } on HealthConnectException catch (e) {
      if (mounted) {
        setState(() {
          _requesting = false;
          _error = '[${e.code}] ${e.message}';
        });
      }
    }
  }

  Future<void> _onDisconnect() async {
    try {
      await _service.disconnect();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _status = HealthConnectStatus.notConnected;
        _persistedConnected = false;
      });
    }
  }

  Future<void> _openManageSheet() async {
    final status = _status;
    if (status != HealthConnectStatus.connected &&
        status != HealthConnectStatus.partiallyConnected) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: NotelColors.surface,
      builder: (sheetContext) => _ManageSheet(
        status: status!,
        onGrantRemaining: () async {
          Navigator.of(sheetContext).pop();
          await _onConnectTap();
        },
        onDeactivate: () async {
          Navigator.of(sheetContext).pop();
          await _onDisconnect();
        },
        onManageSystem: () async {
          try {
            await _service.openHealthConnectSettings();
          } on HealthConnectException catch (e) {
            if (mounted) setState(() => _error = '[${e.code}] ${e.message}');
          }
        },
      ),
    );
    // Re-verify after the sheet closes (user may have changed permissions).
    _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final showLoading = status == null && !_persistedConnected;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back, color: NotelColors.primary),
          tooltip: 'Back',
        ),
        title: const Text(
          'Data connections',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        centerTitle: true,
        actions: const [SizedBox(width: 48)],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionLabel('Your connections'),
            const SizedBox(height: 8),
            if (showLoading)
              const _LoadingRow()
            else if (status == HealthConnectStatus.connected ||
                status == HealthConnectStatus.partiallyConnected ||
                (_persistedConnected && status == null))
              _ConnectionItem(
                logo: const _HealthConnectLogo(),
                name: 'Android Health (Google Fit, Samsung)',
                statusText: status == HealthConnectStatus.partiallyConnected
                    ? 'Partially connected'
                    : 'Connected',
                statusColor: status == HealthConnectStatus.partiallyConnected
                    ? NotelColors.warning
                    : NotelColors.success,
                onTap: _openManageSheet,
              )
            else
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  'No trackers connected yet.',
                  style: TextStyle(
                    color: Color(0x807A8FAF),
                    fontSize: 14,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            _SectionLabel('Add connections'),
            const SizedBox(height: 8),
            if (showLoading)
              const _LoadingRow()
            else if (status == HealthConnectStatus.unavailable)
              const _ConnectionItem(
                logo: _HealthConnectLogo(),
                name: 'Android Health (Google Fit, Samsung)',
                statusText: 'Not available on this device',
                statusColor: NotelColors.textSecondary,
                onTap: null,
              )
            else if (status == HealthConnectStatus.notConnected ||
                (!_persistedConnected && status == null))
              _ConnectionItem(
                logo: const _HealthConnectLogo(),
                name: 'Android Health (Google Fit, Samsung)',
                statusText: 'Available',
                statusColor: NotelColors.textSecondary,
                onTap: _requesting ? null : _onConnectTap,
                trailing: _requesting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NotelColors.primary,
                        ),
                      )
                    : null,
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  "You've connected every supported tracker.",
                  style: TextStyle(
                    color: Color(0x807A8FAF),
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: NotelColors.error,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 24),
            _SectionLabel('Unavailable'),
            const SizedBox(height: 8),
            const _FitbitCard(),
            const SizedBox(height: 32),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'How to connect a tracker',
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Most trackers (Fitbit, Garmin, Samsung) sync their data to a central hub like Health Connect. \n\nWe recommend using Android Health (Health Connect) as it acts as a universal bridge for Google Fit, Samsung Health, Oura, and more. This ensures Tabs always has your latest heart rate, sleep phases, and activity patterns.',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 14,
                      height: 20 / 14,
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Fitbit devices can still sync through Health Connect, so your Fitbit data keeps flowing into Tabs that way.',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 14,
                      height: 20 / 14,
                    ),
                  ),
                ],
              ),
            ),
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

class _ConnectionItem extends StatelessWidget {
  final Widget logo;
  final String name;
  final String statusText;
  final Color statusColor;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _ConnectionItem({
    required this.logo,
    required this.name,
    required this.statusText,
    required this.statusColor,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.6 : 1.0,
      child: Container(
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
                    child: logo,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          statusText,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  trailing ??
                      Icon(
                        Icons.chevron_right,
                        color:
                            NotelColors.textSecondary.withValues(alpha: 0.5),
                        size: 20,
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HealthConnectLogo extends StatelessWidget {
  const _HealthConnectLogo();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/ic_health_connect.png',
      width: 28,
      height: 28,
      errorBuilder: (_, _, _) => const Icon(
        Icons.favorite,
        color: NotelColors.primary,
        size: 24,
      ),
    );
  }
}

/// Port of the native FitbitLogo(): teal dot-grid, 24dp.
class _FitbitLogo extends StatelessWidget {
  const _FitbitLogo();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(24, 24),
      painter: _FitbitLogoPainter(),
    );
  }
}

class _FitbitLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const color = Color(0xFF00B0B9);
    final dotRadius = 2 * size.width / 24;
    final spacing = 5 * size.width / 24;
    final paint = Paint()..color = color;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final points = [
      Offset(cx, cy),
      Offset(cx - spacing, cy),
      Offset(cx + spacing, cy),
      Offset(cx - spacing * 2, cy),
      Offset(cx + spacing * 2, cy),
      Offset(cx, cy - spacing),
      Offset(cx, cy + spacing),
      Offset(cx - spacing, cy - spacing),
      Offset(cx + spacing, cy - spacing),
      Offset(cx - spacing, cy + spacing),
      Offset(cx + spacing, cy + spacing),
      Offset(cx, cy - spacing * 2),
      Offset(cx, cy + spacing * 2),
    ];
    for (final p in points) {
      canvas.drawCircle(p, dotRadius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FitbitCard extends StatelessWidget {
  const _FitbitCard();

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
      padding: const EdgeInsets.all(16),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: NotelColors.legacyDarkHairlineFaint,
                    shape: BoxShape.circle,
                  ),
                  child: Center(child: _FitbitLogo()),
                ),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fitbit (Direct Sync)',
                      style: TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'No longer available',
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            'Google retired the Fitbit Web API, so direct syncing from Fitbit is no longer possible. Your previously saved history stays in Tabs. Health Connect keeps working as before.',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
              height: 18 / 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ManageSheet extends StatelessWidget {
  final HealthConnectStatus status;
  final Future<void> Function() onGrantRemaining;
  final Future<void> Function() onDeactivate;
  final Future<void> Function() onManageSystem;

  const _ManageSheet({
    required this.status,
    required this.onGrantRemaining,
    required this.onDeactivate,
    required this.onManageSystem,
  });

  @override
  Widget build(BuildContext context) {
    final isPartial = status == HealthConnectStatus.partiallyConnected;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: NotelColors.legacyDarkHairlineFaint,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const _HealthConnectLogo(),
          ),
          const SizedBox(height: 16),
          const Text(
            'Android Health (Google Fit, Samsung)',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
            textAlign: TextAlign.center,
          ),
          Text(
            isPartial ? 'Partially connected' : 'Connected',
            style: TextStyle(
              color: isPartial ? NotelColors.warning : NotelColors.success,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (isPartial) ...[
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                color: NotelColors.error.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: NotelColors.error.withValues(alpha: 0.2),
                ),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    'New Metrics Available!',
                    style: TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Tabs now supports Blood Oxygen, Resting HR, and Breathing Rate, but they require additional permissions.',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () => onGrantRemaining(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Grant New Permissions',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: isPartial ? 24 : 48),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => onDeactivate(),
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.error.withValues(alpha: 0.1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                side: BorderSide(
                  color: NotelColors.error.withValues(alpha: 0.3),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Deactivate in Tabs',
                style: TextStyle(
                  color: NotelColors.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => onManageSystem(),
              child: const Text(
                'Manage system permissions',
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            "Deactivating stops Tabs from pulling new data. To completely revoke access, use the 'Manage system permissions' button above.",
            style: TextStyle(
              color: NotelColors.textSecondary.withValues(alpha: 0.7),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
