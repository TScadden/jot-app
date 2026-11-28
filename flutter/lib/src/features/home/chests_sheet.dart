import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/chest_service.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/features/home/chest_open_flow.dart';
import 'package:tabs_lab/src/features/home/gems_sheet.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Chests inbox sheet (CHESTS package, Nov 26, 2026): opened by
/// tapping the Home gem pill. Lists the unopened chests grouped by
/// tier (counts in the group headers, newest first within a tier —
/// the server's order), each row with an Open action that closes
/// the sheet and pushes the open flow. The empty state is Juno's
/// draft line. Copy lives in [ChestCopy]; strings replace in place
/// when Juno's ruling lands.
///
/// The Gems sheet (explainer + freeze buy) stays one tap away via
/// the "About gems" footer, so moving the pill's tap target to the
/// inbox orphans nothing.
Future<void> showChestsSheet({
  required BuildContext context,
  ChestService? chestService,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => ChestsSheet(chestService: chestService),
  );
}

class ChestsSheet extends StatefulWidget {
  /// Tests inject a fake-backed service; production leaves null
  /// and the sheet uses the shared [ChestService.instance].
  final ChestService? chestService;

  const ChestsSheet({super.key, this.chestService});

  @override
  State<ChestsSheet> createState() => _ChestsSheetState();
}

class _ChestsSheetState extends State<ChestsSheet> {
  late final ChestService _chests;

  /// Ruling #7/#8: a failed inventory load shows the ruled error
  /// + retry, never the empty state (a failed load is not an
  /// empty inventory).
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _chests = widget.chestService ?? ChestService.instance;
    _chests.addListener(_onChanged);
    // Opening the inbox is a sync point: a drop granted while the
    // app was closed shows up here (and on the pill badge).
    unawaited(_sync());
  }

  Future<void> _sync() async {
    final result = await _chests.syncInventory();
    if (!mounted) return;
    setState(() => _loadFailed = result == null && !_chests.loaded);
  }

  @override
  void dispose() {
    _chests.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openChest(ChestItem chest) async {
    final nav = Navigator.of(context);
    nav.pop();
    await showChestOpenFlow(nav.context, chest: chest, service: _chests);
  }

  @override
  Widget build(BuildContext context) {
    final inventory = _chests.inventory;
    final groups = _chests.groupedByTier;
    // Group display order: the order tiers first appear in the
    // (newest-first) inventory.
    final groupOrder = <ChestTier>[];
    for (final chest in inventory) {
      if (!groupOrder.contains(chest.tier)) groupOrder.add(chest.tier);
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ChestCopy.sheetTitle,
              key: Key('chestsSheetTitle'),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            if (_loadFailed && inventory.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ChestCopy.loadError,
                      key: Key('chestsLoadError'),
                      style: TextStyle(
                        fontSize: 14,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      key: const Key('chestsLoadRetry'),
                      onPressed: () => unawaited(_sync()),
                      child: const Text(ChestCopy.loadRetry),
                    ),
                  ],
                ),
              )
            else if (inventory.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  ChestCopy.emptyState,
                  key: Key('chestsEmptyState'),
                  style: TextStyle(
                    fontSize: 14,
                    color: NotelColors.textSecondary,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final tier in groupOrder) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: Text(
                          tier.rowName,
                          key: Key('chestsGroup-${tier.wireName}'),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: ChestTierColors.of(tier),
                          ),
                        ),
                      ),
                      for (final chest in groups[tier]!)
                        _ChestRow(
                          chest: chest,
                          onOpen: () => unawaited(_openChest(chest)),
                        ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('chestsAboutGems'),
                onPressed: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  unawaited(showGemsSheet(context: nav.context));
                },
                child: const Text(GemCopy.explainerHeading),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChestRow extends StatelessWidget {
  final ChestItem chest;
  final VoidCallback onOpen;

  const _ChestRow({required this.chest, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Image.asset(
            chest.tier.spriteAsset,
            key: Key('chestRowSprite-${chest.id}'),
            width: 52,
            height: 52,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              chest.tier.rowName,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: NotelColors.textPrimary,
              ),
            ),
          ),
          FilledButton(
            key: Key('chestOpen-${chest.id}'),
            onPressed: onOpen,
            child: const Text(ChestCopy.openAction),
          ),
        ],
      ),
    );
  }
}
