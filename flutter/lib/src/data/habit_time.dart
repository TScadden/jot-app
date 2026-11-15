import 'package:flutter/material.dart';

/// VC 100137 — the habit scheduled-time value model, shared by the
/// Habits screen (add chip + per-habit editor + display) and the
/// notification projection in `notification_service.dart` (the
/// Nov 11 lesson's one-shared-implementation rule: the screen and
/// the sync must never disagree about what a stored value means).
///
/// Stored format (server contract, native parity): exactly
/// `'Anytime'` or a zero-padded 24h `'HH:mm'` string — the same
/// shape native writes with `String.format("%02d:%02d")`. Anything
/// else stored server-side (legacy rows, garbage) parses to null
/// and behaves as Anytime everywhere: displayed as Anytime, never
/// scheduled.

/// The stored value for "no set time".
const String kHabitAnytime = 'Anytime';

final RegExp _habitTimePattern = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

/// Parses a stored target-time value into its hour/minute.
/// Returns null for `'Anytime'`, null/empty input, and every
/// malformed value (non-padded `'7:30'`, `'24:00'`, `'12:60'`,
/// free text) — callers treat null as "no set time".
({int hour, int minute})? parseHabitTargetTime(String? stored) {
  if (stored == null) return null;
  final m = _habitTimePattern.firstMatch(stored.trim());
  if (m == null) return null;
  return (hour: int.parse(m.group(1)!), minute: int.parse(m.group(2)!));
}

/// Whether [stored] carries a specific scheduled time.
bool hasHabitTargetTime(String? stored) => parseHabitTargetTime(stored) != null;

/// The [TimeOfDay] for a stored value, or null when it has no
/// specific time (see [parseHabitTargetTime]).
TimeOfDay? habitTargetTimeOfDay(String? stored) {
  final parsed = parseHabitTargetTime(stored);
  if (parsed == null) return null;
  return TimeOfDay(hour: parsed.hour, minute: parsed.minute);
}

/// Formats a picked [time] for STORAGE: zero-padded 24h `'HH:mm'`,
/// regardless of the user's locale (the server contract and the
/// native `"%02d:%02d"` write agree on this shape).
String formatHabitTargetTimeForStorage(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

/// Formats a stored value for DISPLAY: `'Anytime'` when the value
/// carries no specific time, otherwise the time rendered by
/// [TimeOfDay.format], which goes through [MaterialLocalizations]
/// — a 12h-locale user sees e.g. `7:30 AM`, a 24h-locale user sees
/// `07:30`. The raw stored `'HH:mm'` is never shown directly.
String formatHabitTargetTimeForDisplay(String? stored, BuildContext context) {
  final time = habitTargetTimeOfDay(stored);
  if (time == null) return kHabitAnytime;
  return time.format(context);
}
