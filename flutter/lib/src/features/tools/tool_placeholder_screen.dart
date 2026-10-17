import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 17 — blank placeholder for a tool screen.
///
/// Tapping a tool card opens this (same pattern as the round-9 blank
/// tabs): empty navy background with the tool's title. Real tool
/// functionality lands in future rounds.
class ToolPlaceholderScreen extends StatelessWidget {
  final ToolTile tile;

  const ToolPlaceholderScreen({super.key, required this.tile});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: NotelColors.primary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          tile.title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: const SizedBox.expand(),
    );
  }
}
