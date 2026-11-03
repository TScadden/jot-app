import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Lab (TikTok-UI exploration) — the reference layout system's
/// section label: small (~13sp) semibold muted text sitting
/// OUTSIDE and above its grouped card, aligned to the card's
/// inner content edge (16dp screen margin + 16dp card padding).
/// The label text is always an existing card title — this widget
/// introduces no copy of its own.
class HomeSectionLabel extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;

  const HomeSectionLabel({super.key, required this.text, this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: NotelColors.textSecondary,
        ),
      ),
    );
    if (onTap == null) return Align(alignment: Alignment.centerLeft, child: label);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: label,
      ),
    );
  }
}
