import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/migraine_time_format.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Migraine attack block inside the Today Summary card's expanded
/// area (Juno ruling 2026-10-26 §A). Every string is Juno's FINAL
/// copy, verbatim — see the ruling before touching any literal.
///
/// The block is a pure view of the shared app-level
/// [MigraineController]: idle → Start; active → elapsed (30s tick
/// driven by the card), started line, aura chips, meds field, pain
/// slider, End. Mid-attack edits persist immediately through the
/// controller (Lab `updateActiveAttack` semantics).
class MigraineBlock extends StatelessWidget {
  final MigraineController controller;

  const MigraineBlock({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final attack = controller.activeAttack;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Migraine attack',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            if (attack == null)
              _IdleContent(controller: controller)
            else
              _ActiveContent(
                key: ValueKey('migraine-active-${attack.id}'),
                controller: controller,
                attack: attack,
              ),
          ],
        );
      },
    );
  }
}

class _IdleContent extends StatelessWidget {
  final MigraineController controller;
  const _IdleContent({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 56,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: NotelColors.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: () => unawaited(controller.startAttack()),
            child: const Text(
              'Start attack',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
        if (controller.startError != null) ...[
          const SizedBox(height: 8),
          Text(
            controller.startError!,
            style: const TextStyle(
              fontSize: 13,
              color: NotelColors.error,
            ),
          ),
        ],
        const SizedBox(height: 8),
        const Text(
          'One tap. Pressure attaches automatically.',
          style: TextStyle(
            fontSize: 12,
            color: NotelColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

const _auraOptions = [
  ('None', 'NONE'),
  ('Visual', 'VISUAL'),
  ('Sensory', 'SENSORY'),
  ('Speech', 'SPEECH'),
  ('Motor', 'MOTOR'),
];

class _ActiveContent extends StatefulWidget {
  final MigraineController controller;
  final MigraineAttack attack;
  const _ActiveContent({
    super.key,
    required this.controller,
    required this.attack,
  });

  @override
  State<_ActiveContent> createState() => _ActiveContentState();
}

class _ActiveContentState extends State<_ActiveContent> {
  late String _aura;
  late final TextEditingController _medsController;
  late int _pain;

  MigraineAttack get _attack => widget.attack;

  @override
  void initState() {
    super.initState();
    _aura = _attack.auraPhase;
    _medsController = TextEditingController(text: _attack.medsTaken);
    _pain = _attack.painPeak > 0 ? _attack.painPeak : 5;
  }

  @override
  void dispose() {
    _medsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final elapsedMin = _attack.elapsedMinutes(
        DateTime.now().millisecondsSinceEpoch);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          formatElapsedDuration(elapsedMin),
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: NotelColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _attack.pressureAtStartHpa > 0
              ? 'Started at ${_attack.pressureAtStartHpa.toStringAsFixed(0)} hPa'
              : 'Started — logging',
          style: const TextStyle(
            fontSize: 13,
            color: NotelColors.textSecondary,
          ),
        ),
        if (!controller.notificationPosted) ...[
          const SizedBox(height: 8),
          const Text(
            'Notifications are off. End the attack here when it passes.',
            style: TextStyle(
              fontSize: 12,
              color: NotelColors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 14),
        const _SectionLabel('Aura phase'),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < _auraOptions.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: _AuraChip(
                  label: _auraOptions[i].$1,
                  selected: _aura == _auraOptions[i].$2,
                  onTap: () {
                    setState(() => _aura = _auraOptions[i].$2);
                    unawaited(controller.updateActive(
                        auraPhase: _auraOptions[i].$2));
                  },
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        const _SectionLabel('Meds taken'),
        const SizedBox(height: 8),
        TextField(
          controller: _medsController,
          onChanged: (v) =>
              unawaited(controller.updateActive(medsTaken: v)),
          style: const TextStyle(color: NotelColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'e.g. sumatriptan',
            hintStyle: const TextStyle(color: NotelColors.textSecondary),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: NotelColors.fieldBorderIdle),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: NotelColors.primary),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          ),
        ),
        const SizedBox(height: 14),
        _SectionLabel('Pain right now: $_pain / 10'),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: NotelColors.primary,
            thumbColor: NotelColors.primary,
          ),
          child: Slider(
            value: _pain.toDouble(),
            min: 1,
            max: 10,
            divisions: 8,
            label: '$_pain',
            onChanged: (v) => setState(() => _pain = v.toInt()),
            onChangeEnd: (v) =>
                unawaited(controller.updateActive(painPeak: v.toInt())),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 56,
          child: FilledButton(
            style: FilledButton.styleFrom(
              // Lab-verbatim end-attack green (Kotlin low-stimulation
              // treatment, kept for this control only).
              backgroundColor: const Color(0xFF1F7A5C),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: () => _showReliefDialog(context),
            child: const Text(
              'End attack',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Juno §A — the Lab relief dialog, verbatim. Default selected
  /// value 3 (this dialog only). Back dismisses and the attack KEEPS
  /// RUNNING; Save ends the attack (end time = the Save tap).
  Future<void> _showReliefDialog(BuildContext context) {
    var relief = 3;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          backgroundColor: NotelColors.surfaceHigh,
          title: const Text(
            'Relief rating',
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'How much relief do you feel now?',
                style: TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var v = 1; v <= 5; v++)
                    ReliefOption(
                      value: v,
                      selected: relief == v,
                      onTap: () => setDialogState(() => relief = v),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '$relief / 5',
                style: const TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          actions: [
            SizedBox(
              height: 56,
              child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text(
                  'Back',
                  style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 17,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 56,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                ),
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  HapticFeedback.mediumImpact();
                  unawaited(widget.controller.endWithReliefDialog(
                    reliefRating: relief,
                    finalPainPeak: _pain,
                  ));
                },
                child: const Text(
                  'Save',
                  style: TextStyle(fontSize: 17, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One relief-rating option (1–5). 48dp × 56dp hit area.
class ReliefOption extends StatelessWidget {
  final int value;
  final bool selected;
  final VoidCallback onTap;
  const ReliefOption({
    super.key,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 48,
        height: 56,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? NotelColors.primary : NotelColors.surface,
          border: Border.all(
            color: selected
                ? NotelColors.primary
                : NotelColors.fieldBorderIdle,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          '$value',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _AuraChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _AuraChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? NotelColors.primary : NotelColors.surfaceHigh,
          border: Border.all(
            color: selected
                ? NotelColors.primary
                : NotelColors.legacyDarkDivider,
          ),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : NotelColors.textPrimary,
          ),
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
    return Text(
      text,
      style: const TextStyle(
        color: NotelColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// Presents the post-tap details form (Juno §C) for an ENDED attack.
/// The attack already ended at the notification tap; this form only
/// completes its record. Dismissing discards the edits.
Future<void> showMigraineDetailsForm(
  BuildContext context, {
  required MigraineController controller,
  required MigraineAttack attack,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => MigraineDetailsForm(
      controller: controller,
      attack: attack,
    ),
  );
}

/// Juno §C details form. Relief starts with NOTHING pre-selected
/// (condition 2 — the dialog's default of 3 must not carry here).
/// Pain, aura, and meds are prefilled from the mid-attack captures;
/// pain commits only if it was prefilled or the slider is touched;
/// relief commits only if selected. Edits commit ONLY on Save.
class MigraineDetailsForm extends StatefulWidget {
  final MigraineController controller;
  final MigraineAttack attack;
  const MigraineDetailsForm({
    super.key,
    required this.controller,
    required this.attack,
  });

  @override
  State<MigraineDetailsForm> createState() => _MigraineDetailsFormState();
}

class _MigraineDetailsFormState extends State<MigraineDetailsForm> {
  int? _relief;
  late int _pain;
  bool _painTouched = false;
  late String _aura;
  late final TextEditingController _medsController;
  String? _saveError;
  bool _saving = false;

  bool get _painPrefilled => widget.attack.painPeak > 0;

  @override
  void initState() {
    super.initState();
    _pain = _painPrefilled ? widget.attack.painPeak : 5;
    _aura = widget.attack.auraPhase;
    _medsController = TextEditingController(text: widget.attack.medsTaken);
  }

  @override
  void dispose() {
    _medsController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final ok = await widget.controller.saveDetails(
      attackId: widget.attack.id,
      reliefRating: _relief,
      painPeak: _pain,
      commitPain: _painPrefilled || _painTouched,
      auraPhase: _aura,
      medsTaken: _medsController.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _saveError = 'Could not save the attack. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final attack = widget.attack;
    final endMs = attack.endTimestamp ?? attack.startTimestamp;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: NotelColors.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Migraine attack ended',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'You ended this attack at ${formatAttackTimestamp(endMs)} when you tapped the notification. Add the details below to finish the record.',
              style: const TextStyle(
                fontSize: 13,
                color: NotelColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            const _SectionLabel('Relief rating'),
            const SizedBox(height: 4),
            const Text(
              'How much relief do you feel now?',
              style: TextStyle(
                fontSize: 13,
                color: NotelColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var v = 1; v <= 5; v++)
                  ReliefOption(
                    value: v,
                    selected: _relief == v,
                    onTap: () => setState(() => _relief = v),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _SectionLabel('Peak pain: $_pain / 10'),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: NotelColors.primary,
                thumbColor: NotelColors.primary,
              ),
              child: Slider(
                value: _pain.toDouble(),
                min: 1,
                max: 10,
                divisions: 8,
                label: '$_pain',
                onChanged: (v) => setState(() {
                  _pain = v.toInt();
                  _painTouched = true;
                }),
              ),
            ),
            const SizedBox(height: 8),
            const _SectionLabel('Aura phase'),
            const SizedBox(height: 8),
            Row(
              children: [
                for (var i = 0; i < _auraOptions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _AuraChip(
                      label: _auraOptions[i].$1,
                      selected: _aura == _auraOptions[i].$2,
                      onTap: () =>
                          setState(() => _aura = _auraOptions[i].$2),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            const _SectionLabel('Meds taken'),
            const SizedBox(height: 8),
            TextField(
              controller: _medsController,
              style: const TextStyle(color: NotelColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'e.g. sumatriptan',
                hintStyle:
                    const TextStyle(color: NotelColors.textSecondary),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: NotelColors.fieldBorderIdle),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: NotelColors.primary),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              ),
            ),
            if (_saveError != null) ...[
              const SizedBox(height: 12),
              Text(
                _saveError!,
                style: const TextStyle(
                  fontSize: 13,
                  color: NotelColors.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  height: 56,
                  child: TextButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text(
                      'Not now',
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 17,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                    ),
                    onPressed: _saving ? null : () => unawaited(_save()),
                    child: const Text(
                      'Save',
                      style: TextStyle(fontSize: 17, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'If you leave without saving, the attack stays ended and relief stays unset.',
              style: TextStyle(
                fontSize: 12,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
