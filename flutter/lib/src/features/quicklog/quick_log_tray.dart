import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Lab (TikTok-UI exploration) — the MORPHING quick-log tray.
///
/// The reference pattern: a bottom tray inset from both edges,
/// floating above the dock zone, that never leaves the screen
/// between related states — it RESIZES and re-contents with a
/// spring-like morph (~340ms) instead of pushing a new page.
///
/// - Root state ('Quick Log'): the log-type choices the pencil
///   flow offers, as icon rows — the free-text note entry first
///   ('Your quick note', the Quick Log screen's own card title),
///   then the account's REAL categories (sync pull, cache-seeded
///   like the Quick Log screen itself — never hardcoded).
/// - Choosing the note entry MORPHS the tray into its editor
///   state (the reference's Status-tray pattern): back circle in
///   the header, centered title, a filled field that takes the
///   primary outline when focused, and a full-width solid primary
///   pill button carrying the flow's existing action word ('Log').
///   Saving writes through [saveQuickLogNote] — the Quick Log
///   screen's own note path (same payload, same outbox staging).
/// - Choosing a category dismisses the tray and opens the full
///   Quick Log screen (via [onOpenFullQuickLog]), so every type
///   reachable before stays reachable and functional.
/// - Barrier tap and the header ✕ dismiss. The keyboard pushes
///   the tray up (the sheet pads for the view inset).
///
/// Zero new copy: every string here already exists in the Quick
/// Log flow ('Quick Log', 'Your quick note', the details field's
/// hint, 'Log', and the account's own category names).
Future<void> showQuickLogTray(
  BuildContext context, {
  TabsBackend? backend,
  LogEntryOutbox? outbox,
  VoidCallback? onOpenFullQuickLog,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: QuickLogTray(
        backend: backend,
        outbox: outbox,
        onOpenFullQuickLog: onOpenFullQuickLog,
      ),
    ),
  );
}

class QuickLogTray extends StatefulWidget {
  final TabsBackend? backend;
  final LogEntryOutbox? outbox;

  /// Called after the tray dismisses itself when a category row
  /// (or the fallback full-screen row) is chosen.
  final VoidCallback? onOpenFullQuickLog;

  const QuickLogTray({
    super.key,
    this.backend,
    this.outbox,
    this.onOpenFullQuickLog,
  });

  @override
  State<QuickLogTray> createState() => _QuickLogTrayState();
}

enum _TrayState { root, noteEditor }

class _QuickLogTrayState extends State<QuickLogTray> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  LogEntryOutbox get _outbox => widget.outbox ?? LogEntryOutbox.instance;

  _TrayState _state = _TrayState.root;
  List<QuickLogCategory> _categories = const [];
  final TextEditingController _noteController = TextEditingController();
  bool _hasText = false;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _noteController.addListener(() {
      final has = _noteController.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    // Cache seed first (the Quick Log screen's round-19c pattern),
    // then the real pull refreshes the list in the background.
    final cached = QuickLogCache.instance.snapshot;
    if (cached.categoriesLoaded) _categories = cached.categories;
    unawaited(_loadCategories());
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final pull = await _backend.fetchSyncPull();
      if (pull == null || !mounted) return;
      final entries = await _backend.fetchLogEntryDtos();
      final categories = await _backend.fetchLogCategories();
      if (!mounted) return;
      setState(() => _categories = rankCategories(categories, entries));
    } catch (_) {
      // Keep the cache seed (or the note-only root) — honest state.
    }
  }

  void _openCategory() {
    final open = widget.onOpenFullQuickLog;
    Navigator.of(context).pop();
    if (open != null) {
      // Let the sheet's pop start before the tab switch begins.
      WidgetsBinding.instance.addPostFrameCallback((_) => open());
    }
  }

  Future<void> _saveNote() async {
    if (_saving || !_hasText) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final result = await saveQuickLogNote(
        backend: _backend,
        outbox: _outbox,
        text: _noteController.text,
      );
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _saving = false;
          _saveError = "Couldn't save that entry on this device. "
              'Try again.';
        });
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
            content: Text('Entry logged · ${result.todayCount} today')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Save failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = animationsDisabled(context);
    final morphDuration =
        reduced ? Duration.zero : const Duration(milliseconds: 340);
    // Lab v3: the tray surface is PURPLE GLASS — the same tray in
    // the same place (12dp side/bottom inset, 28dp radius, same
    // morph), now a translucent purple tint (primary 18% over the
    // #232329 base, at 92%) over a real BackdropFilter blur
    // (sigma 18) of the Home content it floats above, with a
    // hairline border and a light top edge.
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: LabBlackColors.trayGlass,
              borderRadius: BorderRadius.circular(28),
              border:
                  Border.all(color: LabBlackColors.hairline, width: 1),
            ),
            child: Stack(
              children: [
                AnimatedSize(
                  duration: morphDuration,
                  curve: Curves.easeInOutCubic,
                  alignment: Alignment.bottomCenter,
                  child: AnimatedSwitcher(
                    duration: morphDuration,
                    switchInCurve: Curves.easeInOutCubic,
                    switchOutCurve: Curves.easeInOutCubic,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.04),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: _state == _TrayState.root
                        ? _buildRoot(key: const ValueKey('tray_root'))
                        : _buildEditor(key: const ValueKey('tray_editor')),
                  ),
                ),
                // The glass top edge: a 1px light line fading at
                // both ends, sitting on the tray's top border.
                Positioned(
                  top: 0,
                  left: 28,
                  right: 28,
                  child: Container(
                    height: 1,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          LabBlackColors.glassEdge,
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _trayHeader({
    required String title,
    VoidCallback? onBack,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 56,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: LabBlackColors.textPrimary,
                ),
              ),
              if (onBack != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: _circleButton(
                      icon: Icons.arrow_back_ios_new,
                      size: 16,
                      onTap: onBack,
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _circleButton(
                    icon: Icons.close,
                    size: 18,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(color: LabBlackColors.hairline, height: 1),
      ],
    );
  }

  Widget _circleButton({
    required IconData icon,
    required double size,
    required VoidCallback onTap,
  }) {
    return Material(
      color: LabBlackColors.nested,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: size, color: LabBlackColors.textPrimary),
        ),
      ),
    );
  }

  Widget _buildRoot({required Key key}) {
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _trayHeader(title: 'Quick Log'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _row(
                icon: Icons.edit,
                label: 'Your quick note',
                onTap: () => setState(() => _state = _TrayState.noteEditor),
              ),
              for (final cat in _categories)
                _row(
                  icon: Icons.circle,
                  iconColor: cat.color,
                  label: cat.name,
                  onTap: _openCategory,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row({
    required IconData icon,
    Color? iconColor,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: LabBlackColors.nested,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: icon == Icons.circle ? 14 : 19,
                color: iconColor ?? NotelColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: LabBlackColors.textPrimary,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: LabBlackColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor({required Key key}) {
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _trayHeader(
          title: 'Your quick note',
          onBack: () => setState(() => _state = _TrayState.root),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _noteController,
                autofocus: true,
                style: const TextStyle(
                  color: LabBlackColors.textPrimary,
                  fontSize: 14,
                ),
                cursorColor: NotelColors.primary,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: 'Add optional details about these symptoms…',
                  hintStyle: const TextStyle(
                    color: LabBlackColors.textSecondary,
                    fontSize: 13,
                  ),
                  filled: true,
                  fillColor: LabBlackColors.nested,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: LabBlackColors.hairline,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: NotelColors.primary,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _saveError!,
                  style: const TextStyle(
                    color: NotelColors.error,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              // Lab v3: the tray's primary action is its strongest
              // glass element — the same 50dp full-width pill in the
              // same place, now primary at 45% over a real
              // BackdropFilter blur (sigma 12) with a 1px light
              // edge. Disabled (empty note) drops to a faint tint.
              SizedBox(
                height: 50,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(25),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: ElevatedButton(
                      onPressed: _hasText && !_saving ? _saveNote : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LabBlackColors.glassLogButton,
                        disabledBackgroundColor:
                            NotelColors.primary.withValues(alpha: 0.18),
                        foregroundColor: Colors.white,
                        disabledForegroundColor:
                            Colors.white.withValues(alpha: 0.5),
                        side: const BorderSide(
                          color: LabBlackColors.glassEdge,
                          width: 1,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                      ),
                  child: const Text(
                    'Log',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
