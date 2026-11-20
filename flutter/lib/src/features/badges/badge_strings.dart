import 'package:tabs_lab/src/data/badge_engine.dart';

/// Badge copy — EVERY user-facing string in the badges feature
/// lives here, verbatim from Juno's ruling
/// (~/workspace/build-badges/JUNO-STRINGS.md, Nov 20, 2026; Vera
/// byte-compares). No other badge file hardcodes copy. Section
/// references below are to that file.
///
/// Number formatting (§7, binding everywhere in this feature):
/// full comma-grouped integers, never abbreviated, never decimal.
abstract final class BadgeStrings {
  // ── §7 number formatting ──────────────────────────────────────
  /// `78,400` — en-US grouping, integers only.
  static String num(int v) {
    final s = v.abs().toString();
    final buf = StringBuffer(v < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  // ── §1 Drawer ─────────────────────────────────────────────────
  static const String drawerLabel = 'Badges';

  static String drawerSemantics(int earnedBadges) => earnedBadges >= 1
      ? 'Badges, $earnedBadges of 12 earned'
      : 'Badges, none earned yet';

  // ── §2 Screen + summary card ──────────────────────────────────
  static const String screenTitle = 'Badges';
  static const String screenSubtitle = 'Earned and in progress';

  static String earnedCount(int n) =>
      n == 1 ? '1 badge earned' : '$n badges earned';

  static const String topBadgeLabel = 'Top badge';

  /// `{Rung} · {Badge name}` (§2 template).
  static String topBadgeValue(int rungIndex, String badgeName) =>
      '${badgeRungName(rungIndex)} · $badgeName';

  static const String topBadgeNoneValue = 'None yet';
  static const String topBadgeNoneDetail =
      'Earn your first rung to see it here.';

  // ── §10 Empty state ───────────────────────────────────────────
  static const String emptyHeadline = 'No badges yet';
  static const String emptyBody =
      'Every badge below shows what it takes to earn its first rung. '
      'Your progress updates as you use Tabs.';

  // ── §3 Sections ───────────────────────────────────────────────
  static const String sectionLogging = 'Logging';
  static const String sectionStreaks = 'Streaks';
  static const String sectionActivity = 'Activity';
  static const String sectionSleep = 'Sleep';

  static String sectionCount(int n) => '$n of 3';

  static String sectionName(String sectionId) => switch (sectionId) {
        BadgeSections.logging => sectionLogging,
        BadgeSections.streaks => sectionStreaks,
        BadgeSections.activity => sectionActivity,
        BadgeSections.sleep => sectionSleep,
        _ => sectionId,
      };

  // ── §3 Tile semantics ─────────────────────────────────────────
  static String tileSemanticsEarned(String name, int rungIndex) =>
      '$name, ${badgeRungName(rungIndex)}';
  static String tileSemanticsNotEarned(String name) =>
      '$name, not earned yet';
  static String tileSemanticsBlocked(String name) =>
      '$name, permission needed';

  // ── §4 Display names ──────────────────────────────────────────
  static String badgeName(String metricId) => switch (metricId) {
        'total_logs' => 'Total logs',
        'logs_in_day' => 'Logs in a day',
        'morning_logger' => 'Morning logger',
        'day_streak' => 'Day streak',
        'perfect_weeks' => 'Perfect weeks',
        'freeze_saver' => 'Freeze saver',
        'calories_month' => 'Monthly calories',
        'steps_day' => 'Big step day',
        'active_week' => 'Active week',
        'nights_tracked' => 'Nights tracked',
        'sleep_week' => 'Full sleep week',
        'early_to_bed' => 'Early to bed',
        _ => metricId,
      };

  // ── §5 Form A (requirement) / Form B (threshold) lines ────────
  /// Form A — the goal form, detail view's next-rung block only.
  static String requirementLine(String metricId, int n) {
    final v = num(n);
    return switch (metricId) {
      'total_logs' => 'Reach $v logs all time',
      'logs_in_day' => 'Reach $v logs in one day',
      'morning_logger' => n == 1
          ? 'Reach 1 day with a log before 9 AM'
          : 'Reach $v days with a log before 9 AM',
      'day_streak' => 'Reach a $v-day streak',
      'perfect_weeks' => n == 1
          ? 'Reach 1 week with all 7 Daily Summaries'
          : 'Reach $v weeks with all 7 Daily Summaries',
      'freeze_saver' => n == 1
          ? 'Reach 1 time a freeze saved your streak'
          : 'Reach $v times a freeze saved your streak',
      'calories_month' => 'Reach $v calories in one month',
      'steps_day' => 'Reach $v steps in one day',
      'active_week' => 'Reach $v active minutes in one week',
      'nights_tracked' => 'Reach $v nights tracked',
      'sleep_week' => n == 1
          ? 'Reach 1 week with all 7 nights tracked'
          : 'Reach $v weeks with all 7 nights tracked',
      'early_to_bed' => n == 1
          ? 'Reach 1 night in bed by 10 PM'
          : 'Reach $v nights in bed by 10 PM',
      _ => 'Reach $v',
    };
  }

  /// Form B — the receipt form: tiles (next rung's threshold) and
  /// the detail view / summary card (current rung's threshold).
  static String thresholdLine(String metricId, int n) {
    final v = num(n);
    return switch (metricId) {
      'total_logs' => '$v logs all time',
      'logs_in_day' => '$v logs in one day',
      'morning_logger' =>
        n == 1 ? '1 day with a log before 9 AM' : '$v days with a log before 9 AM',
      'day_streak' => '$v-day streak',
      'perfect_weeks' => n == 1
          ? '1 week with all 7 Daily Summaries'
          : '$v weeks with all 7 Daily Summaries',
      'freeze_saver' => n == 1
          ? '1 time a freeze saved your streak'
          : '$v times a freeze saved your streak',
      'calories_month' => '$v calories in one month',
      'steps_day' => '$v steps in one day',
      'active_week' => '$v active minutes in one week',
      'nights_tracked' => '$v nights tracked',
      'sleep_week' => n == 1
          ? '1 week with all 7 nights tracked'
          : '$v weeks with all 7 nights tracked',
      'early_to_bed' =>
        n == 1 ? '1 night in bed by 10 PM' : '$v nights in bed by 10 PM',
      _ => '$v',
    };
  }

  /// Detail-view labels around the §5 lines.
  static const String nextRungHeading = 'Next rung';
  static const String noRungsYet = 'No rungs yet';

  /// `{x} to go` — detail view only, under the progress line.
  static String toGo(int x) => '${num(x)} to go';

  // ── §6 Maxed ──────────────────────────────────────────────────
  static const String maxed = 'Maxed';

  // ── §7 Progress line ──────────────────────────────────────────
  /// `{current} of {next}` — no unit word, by ruling.
  static String progressLine(int current, int next) =>
      '${num(current)} of ${num(next)}';

  // ── §8 Unlock dialog ──────────────────────────────────────────
  static const String unlockTitleSingle = 'Badge unlocked';
  static const String unlockTitlePlural = 'Badges unlocked';

  /// `{Badge name} — {Rung}` (per-rung and grouped 1-rung forms).
  static String unlockLine(String badgeName, int rungIndex) =>
      '$badgeName — ${badgeRungName(rungIndex)}';

  /// `{Badge name} — {Rung} ({k} rungs)` (grouped, k ≥ 2).
  static String unlockGroupedLine(String badgeName, int rungIndex, int k) =>
      '$badgeName — ${badgeRungName(rungIndex)} ($k rungs)';

  static const String unlockGemsLine = '+5 gems';

  /// `Total: +{total} gems` — total counts ledger-confirmed
  /// grants only (§13).
  static String unlockTotalLine(int total) => 'Total: +${num(total)} gems';

  /// `{n} rungs unlocked` (grouped layout count line).
  static String unlockCountLine(int n) => '$n rungs unlocked';

  static const String backfillIntroHc =
      'Earned from your history in Tabs and Health Connect.';
  static const String backfillIntroTabs = 'Earned from your history in Tabs.';

  static const String pendingGemsFooter =
      'Some gems will be added after sync.';
  static const String dismiss = 'Done';

  // ── §9 Health Connect needs-permission state ──────────────────
  static const String permissionTitle = 'Permission needed';
  static const String permissionBody =
      "Tabs couldn't read the sections below because permission wasn't "
      'granted. Badges in those sections show no progress until access '
      'is granted.';
  static const String permissionBlockedLabel = 'Needs permission:';
  static const String permissionGuidance =
      'Grant access in Health Connect, then return to Badges.';
  static const String permissionPrimaryAction =
      'Open Health Connect Settings';
  static const String permissionSecondaryAction = 'Not now';
  static const String permissionTileLine = 'Permission needed';

  // ── §12 Release notes (carried for the release step; the build
  // itself does not render them) ────────────────────────────────
  static const String releaseNotes =
      'New: Badges. Find Badges in the drawer to see the badges you '
      'have earned for logging, streaks, activity, and sleep — 12 '
      'badges with 15 rungs each, from Bronze III to Diamond I. New '
      'rungs unlock automatically from your Tabs and Health Connect '
      'history and pay 5 gems each.';
}
