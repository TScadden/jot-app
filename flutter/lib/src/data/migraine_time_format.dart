// Migraine attack time formatting — ported verbatim from the Lab
// (`attack_loggers/time_format.dart`, itself a port of the Kotlin
// formatters). Production migraine surfaces use these two functions
// ONLY (Juno ruling 2026-10-26, §A/§E): one elapsed format and one
// timestamp format everywhere, including the Trends entry body.

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Elapsed-attack display: "45 min" or "2h 15m" (Kotlin-verbatim logic).
String formatElapsedDuration(int elapsedMin) {
  if (elapsedMin < 60) return '$elapsedMin min';
  return '${elapsedMin ~/ 60}h ${elapsedMin % 60}m';
}

/// Port of Kotlin `DateTimeFormatter.ofPattern("MMM d, h:mm a")` used by
/// the migraine history rows and Trends entries.
///
/// Example: `Oct 9, 1:29 AM`.
String formatAttackTimestamp(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final ampm = dt.hour < 12 ? 'AM' : 'PM';
  final minute = dt.minute.toString().padLeft(2, '0');
  return '${_months[dt.month - 1]} ${dt.day}, $hour12:$minute $ampm';
}
