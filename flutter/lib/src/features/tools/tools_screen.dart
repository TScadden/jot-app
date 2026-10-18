import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/features/tools/blood_pressure_tool_screen.dart';
import 'package:tabs_lab/src/features/tools/body_info_screen.dart';
import 'package:tabs_lab/src/features/tools/community_screen.dart';
import 'package:tabs_lab/src/features/tools/food_screen.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';
import 'package:tabs_lab/src/features/tools/key_metrics_screen.dart';
import 'package:tabs_lab/src/features/tools/lists_screen.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';
import 'package:tabs_lab/src/features/tools/notes_screen.dart';
import 'package:tabs_lab/src/features/tools/project_focus_screen.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';
import 'package:tabs_lab/src/features/tools/research_screen.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';
import 'package:tabs_lab/src/features/tools/tips_tricks_screen.dart';
import 'package:tabs_lab/src/features/tools/tool_placeholder_screen.dart';
import 'package:tabs_lab/src/features/tools/trends_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Round 17 — the Tools screen (native `InfoScreen.kt`), UI only.
///
/// Faithful port of the native tool grid:
/// - AppBar: "Tools" title + reorder action (SwapVert icon normally,
///   purple "Done" pill in edit mode).
/// - Info banner: "Explore your health resources. Long-press to reorder."
///   (edit mode: "Drag tiles to reorder. Tap 'Done' to save.").
/// - 2-column grid of square cards: 42dp purple icon badge, 15sp bold
///   title, 11sp secondary description. 20dp card radius, 1dp
///   primary@15% border.
/// - Long-press drag reorders the tiles (also entering edit mode, like
///   native). The order persists via [ToolOrderStore] — native persists
///   it in `NotelPreferences.infoTileOrder`.
/// - Tapping a tile pushes a blank placeholder screen with the tool's
///   title (round-9 pattern). No tool functionality in this round.
///
/// The screen plays a slide-in-from-right entrance each time the Tools
/// tab is selected (the shell remounts it per selection), matching the
/// founder's requested transition. Honored: reduced motion renders the
/// final state instantly.
class ToolTile {
  final String id;
  final String title;
  final IconData icon;
  final String description;

  const ToolTile(this.id, this.title, this.icon, this.description);
}

/// The native `DEFAULT_INFO_TILES` order, verbatim.
const List<ToolTile> defaultToolTiles = [
  ToolTile('habits', 'Habits', Icons.check_circle, 'Daily routine tracking'),
  ToolTile('reminders', 'Reminders', Icons.notifications, 'Scheduled alerts'),
  ToolTile('lists', 'Lists', Icons.list, 'Checklists & Tasks'),
  ToolTile('notes', 'Notes', Icons.edit, 'Quick notes & thoughts'),
  ToolTile('project_focus', 'Project Focus', Icons.science, 'Track experiments'),
  ToolTile('sleep', 'Sleep', Icons.bedtime, 'Analysis & Debt'),
  ToolTile('body_info', 'Body Info', Icons.accessibility_new, 'Impact & Side Effects'),
  ToolTile('medications', 'Medications', Icons.medication, 'Prescriptions & Doses'),
  ToolTile('tips_and_tricks', 'Tips and Tricks', Icons.lightbulb, 'Master your data'),
  ToolTile('health_coach', 'Health Coach', Icons.question_mark, 'Personalized Advice'),
  ToolTile('key_metrics', 'Key Metrics', Icons.bar_chart, 'Your Body Data'),
  ToolTile('trends', 'Trends', Icons.trending_up, 'Patterns over time'),
  ToolTile('blood_pressure', 'Blood Pressure', Icons.favorite, 'Systolic & Diastolic'),
  ToolTile('food', 'Food', Icons.restaurant, 'Sensitivity Checker'),
  ToolTile('research', 'Research', Icons.menu_book, 'Health research library'),
  ToolTile('community', 'Community', Icons.people, 'Friends & Leaderboard'),
];

/// Pure reorder helper: moves [draggedId] to [targetId]'s position.
/// Returns the original list (same instance) when the move is a no-op.
List<ToolTile> moveTile(List<ToolTile> tiles, String draggedId, String targetId) {
  final from = tiles.indexWhere((t) => t.id == draggedId);
  final to = tiles.indexWhere((t) => t.id == targetId);
  if (from < 0 || to < 0 || from == to) return tiles;
  final next = List<ToolTile>.of(tiles);
  final item = next.removeAt(from);
  next.insert(to, item);
  return next;
}

/// Pure order application (mirrors native's `LaunchedEffect(savedOrderJson)`):
/// saved ids first (unknown ids dropped), then any missing tiles appended
/// in default order.
List<ToolTile> applyTileOrder(List<ToolTile> defaults, List<String> savedIds) {
  final byId = <String, ToolTile>{for (final t in defaults) t.id: t};
  final ordered = <ToolTile>[];
  for (final id in savedIds) {
    final t = byId.remove(id);
    if (t != null) ordered.add(t);
  }
  ordered.addAll(defaults.where((t) => byId.containsKey(t.id)));
  return ordered;
}

/// Persists the tile order (JSON list of ids). Injectable read/write so
/// tests never touch platform channels.
class ToolOrderStore {
  static const String storageKey = 'tools_tile_order_v1';

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) => const FlutterSecureStorage().write(key: key, value: value);

  /// Test seam.
  void debugSetIO({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  }) {
    if (read != null) _read = read;
    if (write != null) _write = write;
  }

  Future<List<String>?> loadOrder() async {
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded.whereType<String>().toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveOrder(List<String> ids) async {
    try {
      await _write(storageKey, jsonEncode(ids));
    } catch (_) {
      // Order persistence is a nicety; never break the UI over it.
    }
  }
}

class ToolsScreen extends StatefulWidget {
  /// Injectable for tests.
  final ToolOrderStore? orderStore;

  const ToolsScreen({super.key, this.orderStore});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen>
    with SingleTickerProviderStateMixin {
  late final ToolOrderStore _store;
  List<ToolTile> _tiles = defaultToolTiles;
  bool _editMode = false;

  late final AnimationController _enter;
  bool _enterScheduled = false;

  @override
  void initState() {
    super.initState();
    _store = widget.orderStore ?? ToolOrderStore();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _loadOrder();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Inherited widgets (MediaQuery) can't be read in initState.
    if (_enterScheduled) return;
    _enterScheduled = true;
    if (animationsDisabled(context)) {
      _enter.value = 1.0;
    } else {
      _enter.forward();
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _loadOrder() async {
    final saved = await _store.loadOrder();
    if (!mounted || saved == null || saved.isEmpty) return;
    setState(() => _tiles = applyTileOrder(defaultToolTiles, saved));
  }

  Future<void> _saveOrder() =>
      _store.saveOrder(_tiles.map((t) => t.id).toList());

  /// Round 18 — tiles now open their real screens (real backend data).
  /// Unknown ids fall back to the placeholder (should never happen).
  void _onTileTap(ToolTile tile) {
    if (_editMode) return;
    final Widget screen = switch (tile.id) {
      'habits' => const HabitsScreen(),
      'reminders' => const RemindersScreen(),
      'lists' => const ListsScreen(),
      'notes' => const NotesScreen(),
      'project_focus' => const ProjectFocusScreen(),
      'sleep' => const SleepScreen(),
      'body_info' => const BodyInfoScreen(),
      'medications' => const MedicationsScreen(),
      'tips_and_tricks' => const TipsTricksScreen(),
      'health_coach' => const HealthCoachScreen(),
      'key_metrics' => const KeyMetricsScreen(),
      'trends' => const TrendsScreen(),
      'blood_pressure' => const BloodPressureToolScreen(),
      'food' => const FoodToolScreen(),
      'research' => const ResearchToolScreen(),
      'community' => const CommunityToolScreen(),
      _ => ToolPlaceholderScreen(tile: tile),
    };
    Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => screen,
      ),
    );
  }

  void _reorder(String draggedId, String targetId) {
    final next = moveTile(_tiles, draggedId, targetId);
    if (identical(next, _tiles)) return;
    setState(() => _tiles = next);
    unawaited(_saveOrder());
  }

  void _exitEditMode() {
    setState(() => _editMode = false);
    unawaited(_saveOrder());
  }

  @override
  Widget build(BuildContext context) {
    final content = Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text(
          'Tools',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          if (_editMode)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: GestureDetector(
                  onTap: _exitEditMode,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: NotelColors.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check, size: 16, color: Colors.white),
                        SizedBox(width: 6),
                        Text(
                          'Done',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
            IconButton(
              onPressed: () => setState(() => _editMode = true),
              icon: const Icon(
                Icons.swap_vert,
                semanticLabel: 'Reorder tiles',
                color: NotelColors.textSecondary,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _InfoBanner(editMode: _editMode),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 1.0,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
              children: [
                for (final tile in _tiles) _reorderableCell(tile),
              ],
            ),
          ),
        ],
      ),
    );

    if (animationsDisabled(context)) return content;
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1.0, 0.0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _enter, curve: Curves.easeOut)),
      child: content,
    );
  }

  Widget _reorderableCell(ToolTile tile) {
    final card = _ToolCard(
      tile: tile,
      editMode: _editMode,
      onTap: () => _onTileTap(tile),
    );
    return DragTarget<ToolTile>(
      onWillAcceptWithDetails: (details) => details.data.id != tile.id,
      onAcceptWithDetails: (details) => _reorder(details.data.id, tile.id),
      builder: (context, candidate, rejected) {
        return LongPressDraggable<ToolTile>(
          data: tile,
          delay: const Duration(milliseconds: 350),
          onDragStarted: () {
            if (!_editMode) setState(() => _editMode = true);
          },
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: (MediaQuery.sizeOf(context).width - 32 - 14) / 2,
              child: _ToolCard(tile: tile, editMode: true, dragging: true),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: card),
          child: card,
        );
      },
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final bool editMode;

  const _InfoBanner({required this.editMode});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: editMode
            ? NotelColors.primary.withValues(alpha: 0.12)
            : NotelColors.surfaceHigh.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            editMode ? Icons.open_with : Icons.touch_app,
            size: 16,
            color: editMode
                ? NotelColors.primaryText
                : NotelColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              editMode
                  ? "Drag tiles to reorder. Tap 'Done' to save."
                  : 'Explore your health resources. Long-press to reorder.',
              style: TextStyle(
                fontSize: 12,
                fontWeight:
                    editMode ? FontWeight.bold : FontWeight.w500,
                color: editMode
                    ? NotelColors.primaryText
                    : NotelColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  final ToolTile tile;
  final bool editMode;
  final bool dragging;
  final VoidCallback? onTap;

  const _ToolCard({
    required this.tile,
    this.editMode = false,
    this.dragging = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = dragging
        ? NotelColors.primary
        : editMode
            ? NotelColors.primary.withValues(alpha: 0.45)
            : NotelColors.cardBorder;
    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: borderColor,
          width: dragging ? 2 : 1,
        ),
        boxShadow: dragging
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: NotelColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  tile.icon,
                  size: 22,
                  color: NotelColors.primary,
                  semanticLabel: tile.title,
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tile.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      height: 1.27,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tile.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.27,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (editMode && !dragging)
            const Positioned(
              top: 0,
              right: 0,
              child: Icon(
                Icons.drag_handle,
                size: 20,
                color: Color(0x997C6EFF),
                semanticLabel: 'Drag handle',
              ),
            ),
        ],
      ),
    );

    final scaled = dragging
        ? Transform.scale(scale: 1.05, child: card)
        : card;

    if (onTap == null || editMode) return scaled;
    return GestureDetector(onTap: onTap, child: scaled);
  }
}
