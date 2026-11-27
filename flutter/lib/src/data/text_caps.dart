import 'package:flutter/material.dart';

import 'package:tabs_lab/src/theme/notel_colors.dart';

/// GAP-9 (Nov 27, 2026) — per-field free-text caps, per Juno's
/// binding ruling (JUNO-RULING.md §1). The server enforces the
/// same numbers; the counting rule is identical on both sides
/// (Dart `String.length` == JS `string.length`, UTF-16 code
/// units), and a value exactly AT the cap is valid.
///
/// The caps stop the pathological paste — they do not edit
/// users. Every number is a generous multiple of the largest
/// plausible legitimate use (see the ruling's sizing table).
abstract final class TextCaps {
  /// Personal context (`user_profiles.user_context`).
  static const int personalContext = 10000;

  /// Knowledge base (`user_profiles.knowledge_base`).
  static const int knowledgeBase = 262144;

  /// Professional updates (`user_profiles.professional_updates`).
  static const int professionalUpdates = 20000;

  /// Reddit summaries (`user_profiles.reddit_summaries`).
  /// Machine-generated — no user-editable field in the app;
  /// the cap binds the server and any future editor.
  static const int redditSummaries = 65536;

  /// Quick-log note body (`log_entries.body`).
  static const int logEntryBody = 10000;

  /// Quick-log manual text (`log_entries.manual_text`).
  static const int logEntryManualText = 10000;

  /// Standalone note body (Notes tool, `__user_notes__` items).
  static const int noteBody = 10000;

  /// Note title (Notes tool + Settings "Add Text Note").
  static const int noteTitle = 200;

  /// Custom category name (`categories.name`).
  static const int categoryName = 100;

  /// Custom item name (user-list items, quick-log item labels).
  static const int itemName = 100;

  /// Nickname (`users.nickname`; the minimum of 2 also stands).
  static const int nickname = 50;

  /// Juno §2 — the exact at-cap string, every capped field.
  static const String atCapMessage =
      "You've hit the character limit for this field.";

  /// Juno §2 — on label fields (title / names / nickname) the
  /// counter appears once the user is within this many
  /// characters of the cap. On prose fields it is always visible
  /// (Flutter's built-in `maxLength` counter, `{current} / {cap}`).
  static const int labelCounterWindow = 20;

  /// The counter text for a label field at [current] length, or
  /// an empty string (counter hidden) when the field is outside
  /// the near-cap window.
  static String labelCounter(int current, int cap) =>
      current >= cap - labelCounterWindow ? '$current / $cap' : '';
}

/// Juno §2 counter + at-cap line for a capped field, driven
/// directly by the field's controller so no screen setState
/// plumbing is needed. Place directly under the field; the
/// field itself carries `maxLength` +
/// `LengthLimitingTextInputFormatter` for enforcement and
/// `counterText: ''` in its decoration (this widget replaces
/// the built-in counter so the format is exactly Juno's
/// `{current} / {cap}`, plain digits, on every field).
///
/// - Prose fields ([labelStyle] false): counter always visible.
/// - Label fields ([labelStyle] true): counter appears only
///   within [TextCaps.labelCounterWindow] of the cap.
/// - At the cap, the exact at-cap string shows under the field.
class CapCounter extends StatelessWidget {
  final TextEditingController controller;
  final int cap;
  final bool labelStyle;

  const CapCounter({
    super.key,
    required this.controller,
    required this.cap,
    this.labelStyle = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final len = value.text.length;
        final counter =
            labelStyle ? TextCaps.labelCounter(len, cap) : '$len / $cap';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (counter.isNotEmpty)
              Text(
                counter,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: NotelColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            AtCapMessage(currentLength: len, cap: cap),
          ],
        );
      },
    );
  }
}

/// Juno §2 — the at-cap line, shown under a capped field for as
/// long as the field stays at the cap, in the field's error
/// style. Renders nothing below the cap.
class AtCapMessage extends StatelessWidget {
  final int currentLength;
  final int cap;

  const AtCapMessage({
    super.key,
    required this.currentLength,
    required this.cap,
  });

  @override
  Widget build(BuildContext context) {
    if (currentLength < cap) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(top: 6),
      child: Text(
        TextCaps.atCapMessage,
        style: TextStyle(color: NotelColors.error, fontSize: 12),
      ),
    );
  }
}
