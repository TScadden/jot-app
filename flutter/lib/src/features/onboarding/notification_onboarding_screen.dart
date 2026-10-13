import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 32 — port of native `NotificationOnboardingScreen.kt`
/// (route `notification_onboarding`), the notification-permission
/// step.
///
/// Native behavior:
/// - Header carries Back AND Skip; Skip advances without any
///   permission request.
/// - The centered card asks "Allow Tabs to send you notifications?"
///   with "Allow" / "Don't Allow".
/// - "Allow" requests `POST_NOTIFICATIONS` (API 33+; below that it
///   advances directly) and advances to the connections step
///   REGARDLESS of the grant result — native's launcher callback
///   ignores the boolean.
/// - "Don't Allow" advances without requesting.
///
/// The request itself goes through Round 30's
/// [ReminderNotificationService.requestNotificationsPermission]
/// (flutter_local_notifications — the same plugin path Settings
/// uses, and the manifest already carries POST_NOTIFICATIONS from
/// Round 30). Failures surface visibly as `[CODE]` (team lesson: no
/// silent channel failures) and the step stays put so the user can
/// still choose "Don't Allow".
class NotificationOnboardingScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onNavigateNext;
  final VoidCallback onSkip;
  final ReminderNotificationService? notificationService;

  const NotificationOnboardingScreen({
    super.key,
    required this.onBack,
    required this.onNavigateNext,
    required this.onSkip,
    this.notificationService,
  });

  @override
  State<NotificationOnboardingScreen> createState() =>
      _NotificationOnboardingScreenState();
}

class _NotificationOnboardingScreenState
    extends State<NotificationOnboardingScreen> {
  late final ReminderNotificationService _service;
  bool _requesting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service =
        widget.notificationService ?? LocalReminderNotificationService();
  }

  Future<void> _onAllow() async {
    if (_requesting) return;
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      await _service.requestNotificationsPermission();
    } on NotificationServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _requesting = false;
        _error = '[${e.code}] Notification permission request failed.';
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _requesting = false;
        _error = '[PERMISSION_REQUEST_FAILED] Notification permission '
            'request failed.';
      });
      return;
    }
    if (!mounted) return;
    // Native advances on ANY grant result, granted or denied.
    widget.onNavigateNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OnboardingHeader(
                  onBack: widget.onBack,
                  onSkip: widget.onSkip,
                ),
              ),
              Expanded(
                child: Center(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: NotelColors.surface,
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: NotelColors.cardBorder),
                    ),
                    padding: const EdgeInsets.symmetric(
                      vertical: 32,
                      horizontal: 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.notifications_outlined,
                          color: NotelColors.primary,
                          size: 36,
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Allow Tabs to send you\nnotifications?',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: NotelColors.textPrimary,
                            height: 23 / 17,
                          ),
                        ),
                        const SizedBox(height: 28),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton(
                            onPressed: _requesting ? null : _onAllow,
                            style: FilledButton.styleFrom(
                              backgroundColor: NotelColors.surfaceHigh,
                              foregroundColor: NotelColors.primary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            child: _requesting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: NotelColors.primary,
                                    ),
                                  )
                                : const Text('Allow'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton(
                            onPressed:
                                _requesting ? null : widget.onSkip,
                            style: FilledButton.styleFrom(
                              backgroundColor: NotelColors.surfaceHigh
                                  .withValues(alpha: 0.5),
                              foregroundColor:
                                  NotelColors.primary.withValues(alpha: 0.8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            child: const Text("Don't Allow"),
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: NotelColors.error,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
