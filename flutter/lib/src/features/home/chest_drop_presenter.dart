import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/chest_service.dart';
import 'package:tabs_lab/src/features/home/chest_open_flow.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_presenter.dart';
import 'package:tabs_lab/src/features/settings/report_generation_presenter.dart';

/// Chest drop prompt (CHESTS package, Nov 26, 2026; UX decision:
/// a fresh drop is offered right after the day-completion
/// celebration — "Open now" / "Later").
///
/// Presentation is decoupled from Home's lifecycle exactly like
/// the streak celebration (Nov 21, 2026 precedent): Home's
/// settlement path hands the drop to [ChestDropService], and the
/// app-root [ChestDropPresenter] shows it on the root navigator —
/// but only once no celebration is pending or showing, so the
/// prompt lands AFTER the celebration, never over it. A drop held
/// while the app is backgrounded is presented on the next
/// foreground. "Later" files the chest to the inbox (it is already
/// in the synced inventory; nothing else to do).
class ChestDropService {
  ChestDropService._();

  static final ChestDropService instance = ChestDropService._();

  ChestDrop? _pending;
  bool _showing = false;
  void Function()? _presenter;

  ChestDrop? get pending => _pending;
  bool get isShowing => _showing;

  void registerPresenter(void Function() present) {
    _presenter = present;
    if (_pending != null) present();
  }

  void unregisterPresenter(void Function() present) {
    if (_presenter == present) _presenter = null;
  }

  /// Hand a fresh drop to the presenter. One prompt at a time: a
  /// second hold while one is pending/showing is a no-op (the
  /// chest is in the inbox either way).
  void hold(ChestDrop drop) {
    if (_pending != null || _showing) return;
    _pending = drop;
    _presenter?.call();
  }

  void handleResumed() {
    if (_pending != null) _presenter?.call();
  }

  /// Consume [drop] and run [show]. The pending slot clears BEFORE
  /// the show so the prompt presents exactly once.
  Future<void> presentHeld(ChestDrop drop, Future<void> Function() show) async {
    if (!identical(_pending, drop)) return;
    _pending = null;
    _showing = true;
    try {
      await show();
    } finally {
      _showing = false;
    }
  }

  @visibleForTesting
  void debugReset() {
    _pending = null;
    _showing = false;
    _presenter = null;
  }
}

/// The drop prompt dialog itself (Juno draft copy via [ChestCopy]).
class ChestDropPrompt extends StatelessWidget {
  final ChestDrop drop;
  final ChestService? chestService;

  const ChestDropPrompt({super.key, required this.drop, this.chestService});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('chestDropPrompt'),
      title: const Text(ChestCopy.dropTitle),
      content: Text(ChestCopy.dropBody(drop.tier)),
      actions: [
        TextButton(
          key: const Key('chestDropLater'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(ChestCopy.dropLater),
        ),
        FilledButton(
          key: const Key('chestDropOpenNow'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(ChestCopy.dropOpenNow),
        ),
      ],
    );
  }
}

/// App-root presenter for chest drops: mounted once above the
/// app's Navigator alongside [StreakCelebrationPresenter]. While a
/// drop is held but the celebration still owns the stage, it
/// retries on a short timer until the stage clears.
class ChestDropPresenter extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;
  final ChestDropService? service;
  final ChestService? chestService;

  const ChestDropPresenter({
    super.key,
    required this.child,
    this.navigatorKey,
    this.service,
    this.chestService,
  });

  @override
  State<ChestDropPresenter> createState() => _ChestDropPresenterState();
}

class _ChestDropPresenterState extends State<ChestDropPresenter>
    with WidgetsBindingObserver {
  ChestDropService get _service => widget.service ?? ChestDropService.instance;

  late final void Function() _presentCallback = _tryPresent;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service.registerPresenter(_presentCallback);
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryPresent());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.unregisterPresenter(_presentCallback);
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _service.handleResumed();
    }
  }

  bool get _celebrationOwnsStage =>
      StreakCelebrationService.instance.pending != null ||
      StreakCelebrationService.instance.isShowing;

  void _tryPresent() {
    if (!mounted) return;
    final pending = _service.pending;
    if (pending == null) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    if (_celebrationOwnsStage) {
      // The prompt belongs AFTER the celebration: poll until the
      // celebration route has been dismissed.
      _retryTimer ??= Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _tryPresent(),
      );
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    final navContext =
        (widget.navigatorKey ?? reportPresentationNavigatorKey).currentContext;
    if (navContext == null) return;
    unawaited(
      _service.presentHeld(pending, () async {
        final openNow = await showDialog<bool>(
          context: navContext,
          builder: (_) =>
              ChestDropPrompt(drop: pending, chestService: widget.chestService),
        );
        if (openNow == true && navContext.mounted) {
          await showChestOpenFlow(
            navContext,
            chest: ChestItem(id: pending.id, tier: pending.tier),
            service: widget.chestService,
          );
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
