import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/chest_service.dart';
import 'package:tabs_lab/src/features/home/chest_drop_presenter.dart';
import 'package:tabs_lab/src/features/home/chest_open_flow.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Developer Terminal chest popup test (Nov 26, 2026).
///
/// A10 GREP FENCE: this file must never reference the server
/// backend, the production chest service (in any form — neither
/// its shared instance nor a fresh construction), the real gem
/// balance service, or any reporting API, and it must never read
/// or write any persistence. The whole test is built from plain
/// values passed in by the caller: the caller hands over the
/// current balance as a read-only number, the panel keeps a
/// SIMULATED balance in its own widget state, and every run is
/// driven by a locally fabricated open script (see
/// [ChestSimEntry.buildSimResult]) delivered through the open
/// flow's injected opener + balance-sink seam. The fabricated
/// opener ignores the chest id and returns the script; the sink
/// updates ONLY the panel's in-memory simulated balance. Nothing
/// here touches the real chest inventory (it is never read), the
/// real gem balance, or the network — Vera verifies the fence
/// and the A10-style isolation test snapshots persistence, the
/// profile-side records, and the real gem balance around a full
/// simulated run (open flow plus drop-prompt preview).
///
/// Placement: the entry renders ONLY when the caller gates it on
/// the signed-in account's pulled `dev_access` flag (the same
/// gate as the streak SIM in the Developer Terminal).
class ChestSimEntry extends StatefulWidget {
  /// The current balance, read by the caller and passed in as a
  /// plain value; the panel's simulated balance starts there.
  /// The panel itself reads nothing.
  final int initialBalance;

  const ChestSimEntry({super.key, required this.initialBalance});

  /// The clearly fake chest id every simulated run uses. It is
  /// never a real inventory id, and the fabricated opener ignores
  /// it entirely.
  static const String simChestId = 'chest-popup-test-simulated';

  /// The pure script builder: compose the open script for a
  /// simulated run from plain values, in memory only.
  ///
  /// [tapUpgrades] holds one setter per chance tap (true = that
  /// tap upgrades); shorter lists pad with false. The final tier
  /// comes from the production tier walk, so the tier caps are
  /// the real ones: a Streak chest upgrades at most once in
  /// effect, a Daily chest at most twice, and MEGA is terminal —
  /// no toggle pattern can move it. The grant is the FINAL tier's
  /// production payout (Daily 10 / Streak 25 / MEGA 100), and the
  /// new balance is the simulated balance plus that grant.
  @visibleForTesting
  static ChestOpenResult buildSimResult({
    required ChestTier startTier,
    required List<bool> tapUpgrades,
    required int simBalance,
  }) {
    final outcomes = List<bool>.generate(
      3,
      (i) => i < tapUpgrades.length && tapUpgrades[i],
    );
    final finalTier = ChestOpenResult.tierAfter(startTier, outcomes, 3);
    final gemsGranted = finalTier.payout;
    return ChestOpenResult(
      tapOutcomes: outcomes,
      finalTier: finalTier,
      gemsGranted: gemsGranted,
      newBalance: simBalance + gemsGranted,
    );
  }

  @override
  State<ChestSimEntry> createState() => _ChestSimEntryState();
}

class _ChestSimEntryState extends State<ChestSimEntry> {
  ChestTier _tier = ChestTier.daily;
  final List<bool> _tapUpgrades = <bool>[false, false, false];

  /// The SIMULATED balance: panel state only, seeded from the
  /// caller's plain value, raised by each simulated payout, and
  /// discarded when the panel leaves. Never persisted, never
  /// adopted anywhere.
  late int _simBalance;

  @override
  void initState() {
    super.initState();
    _simBalance = widget.initialBalance;
  }

  /// Play the shipped open flow with the composed script. The
  /// fabricated opener returns the scripted result for any id;
  /// the balance sink lands on the simulated balance only.
  Future<void> _play() async {
    final result = ChestSimEntry.buildSimResult(
      startTier: _tier,
      tapUpgrades: List<bool>.of(_tapUpgrades),
      simBalance: _simBalance,
    );
    await showChestOpenFlow(
      context,
      chest: ChestItem(id: ChestSimEntry.simChestId, tier: _tier),
      opener: (_) async => result,
      onBalance: (newBalance) {
        if (mounted) setState(() => _simBalance = newBalance);
      },
    );
  }

  /// Preview the shipped drop prompt with a fabricated drop of
  /// the chosen tier. The prompt is shown directly as a dialog —
  /// no drop service, no presenter. "Open now" chains into the
  /// simulated open flow with the panel's current tier/script
  /// settings; "Later" just dismisses.
  Future<void> _previewDrop() async {
    final openNow = await showDialog<bool>(
      context: context,
      builder: (_) => ChestDropPrompt(
        drop: ChestDrop(id: ChestSimEntry.simChestId, tier: _tier),
      ),
    );
    if (openNow == true && mounted) await _play();
  }

  @override
  Widget build(BuildContext context) {
    final isMega = _tier == ChestTier.mega;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Juno ruling (build-chests-dev-test/JUNO-RULING.md) —
        // every string in this panel is byte-exact from it.
        const Text(
          'Chest popup test',
          key: Key('chestSimTitle'),
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Simulated. Nothing here touches your real chests or gems.',
          key: Key('chestSimNote'),
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 11),
        ),
        const SizedBox(height: 16),
        const Text(
          'Tier',
          key: Key('chestSimTierLabel'),
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final tier in ChestTier.values)
              ChoiceChip(
                key: Key('chestSimTier-${tier.wireName}'),
                label: Text(tier.dropName),
                selected: _tier == tier,
                onSelected: (_) => setState(() => _tier = tier),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < 3; i++)
          // Row + Switch, the settings screen's own toggle idiom
          // (a ListTile inside the dev card's DecoratedBox trips
          // Flutter's ink-splash assertion).
          Row(
            children: [
              Expanded(
                child: Text(
                  'Upgrade on tap ${i + 1}',
                  style: const TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 14,
                  ),
                ),
              ),
              Switch(
                key: Key('chestSimUpgrade${i + 1}'),
                value: _tapUpgrades[i],
                activeThumbColor: NotelColors.primary,
                // MEGA is terminal: the setters disable entirely.
                onChanged: isMega
                    ? null
                    : (v) => setState(() => _tapUpgrades[i] = v),
              ),
            ],
          ),
        if (isMega)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              "MEGA can't upgrade.",
              key: Key('chestSimMegaHelper'),
              style: TextStyle(
                fontSize: 12,
                color: LabBlackColors.textSecondary,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Simulated balance: $_simBalance gems',
          key: Key('chestSimBalance'),
          style: const TextStyle(
            color: NotelColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            key: const Key('chestSimPlayButton'),
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () => unawaited(_play()),
            child: const Text('Play chest popup'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            key: const Key('chestSimDropPreviewButton'),
            onPressed: () => unawaited(_previewDrop()),
            child: const Text('Preview drop prompt'),
          ),
        ),
      ],
    );
  }
}
