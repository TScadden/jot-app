import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';
import 'package:tabs_lab/src/data/calendar_service.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/reminder_alarm_sync.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart'
    show habitStreak;
import 'package:tabs_lab/src/features/tools/project_focus_screen.dart'
    show collectFocusTests;
import 'package:tabs_lab/src/features/tools/reminders_screen.dart'
    show
        buildReminderRow,
        nextReminderId,
        parseReminderModels,
        runReminderCreatePermissionGate;
import 'package:tabs_lab/src/features/tools/sleep_screen.dart'
    show sleepDebtMinsOrNull;
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Round 48 (Team C) — Health Coach, full Flutter port of native
/// `CoachHistoryScreen.kt` + `CoachScreen.kt` + `CoachViewModel.kt`.
///
/// Round 18 shipped the chat core only. Round 48 closes the deferred
/// gaps, all wired to the same server paths native uses (JotApi.kt):
/// - Sessions and messages PERSIST: a first send creates the session
///   (`POST api/sync/coach_sessions`), an AI title is fetched
///   (`POST api/ai/coach/title`, native fallback "Chat"), and every
///   message is pushed (`POST api/sync/coach_messages`) — the same
///   upsert pushes native's SyncManager performs for unsynced rows.
/// - Session deletion in history AND in chat:
///   `DELETE api/sync/coach_sessions/{id}`.
/// - The coach's action proposals are parsed from the reply tags
///   exactly like native `parseCoachMessageContent` and rendered as
///   approve/deny cards (note, file, list, reminder, calendar event,
///   calendar deletion, medications) with native's card copy and
///   resolved-state badges. Approvals write through the same synced
///   stores native writes: notes → log entries (classify via
///   `POST api/ai/classify-coach-note`, fallback category 7), lists →
///   profile `userLists`, reminders → profile `reminders`,
///   medications → profile `medications`, files → knowledge
///   documents (`POST api/sync/documents`, using native's own
///   reconstruction from the "📄 Uploaded file:" message).
///   Typed shortcuts ("approve", "yes, set it", …) resolve a pending
///   proposal exactly like native `sendMessage`.
/// - The user context sent to `POST api/ai/coach` carries native's
///   action-proposal instructions, so the server can emit the tags.
///
/// BLOCKED (no Flutter bridge, documented for the parent): attaching
/// a NEW file from this app (native uses the Android file picker +
/// `POST api/ai/process-document` extraction; the Flutter app has no
/// file-picker plugin).
///
/// Round 54 — real Google Calendar access: the CalendarContract
/// bridge (calendar_service.dart + MainActivity.kt) ports native's
/// calendar paths. When the SettingsStore flag says Google Calendar
/// is connected (native's sign-in-based flag), the prompt carries
/// native's CONNECTED branch with the live upcoming-events context,
/// calendar cards enable Approve, and approvals run native's flow:
/// permission re-check at approve (disclosure first, then the
/// system READ+WRITE request; a grant replays the pending approve),
/// writable-calendar insert / exact-title delete in the bridge, and
/// native's exact confirmation/error messages. When the flag is
/// off, Round 48's honest treatment stays exactly as-is: the
/// NOT-connected prompt instruction, the limitation stated ON the
/// card, a disabled approve control, and a working deny/dismiss.
///
/// Membership-gated like native: a non-unlimited account sees an
/// honest locked state (no paywall built). AI failures show a
/// visible error bubble — a reply is never fabricated.

/// Native `CoachViewModel.welcomeMessage` — shown for a new session
/// and inserted as the session's first message on creation.
const String coachWelcomeMessage =
    "Hi, I'm $kCoachName, your Tabs Coach.\n"
    'Ask me anything about your health, habits, and data.';

/// Native `MedicalDisclaimerBanner` copy, verbatim — the banner
/// above all coach content (CoachScreen.kt). Round 18 invented
/// different copy; Round 48 mirrors native exactly.
const String coachDisclaimer =
    'Tabs is not a medical device. It does not diagnose, treat, cure, '
    'or prevent any condition. AI insights are informational only. '
    'Consult a healthcare professional.';

/// Round 48 fix round (Juno F1) — the limitation stated ON pending
/// calendar proposal cards: calendar changes require the native
/// Tabs app, and this app cannot perform them.
const String coachCalendarCardLimitation =
    'Calendar changes require the native Tabs app. '
    'This app cannot add or delete calendar events.';

/// Round 48 fix round (Juno F1) — snackbar shown if a calendar
/// approval is attempted through the resolution path: it names
/// the NATIVE Tabs app (this build is itself Tabs on Android, so
/// the old "Open Tabs on Android…" copy named the wrong thing).
const String coachCalendarUnavailableMessage =
    'Calendar changes require the native Tabs app. '
    'Open the native Tabs app to add or delete calendar events.';

/// Round 54 — native's Toast on calendar permission denial
/// (CoachScreen.kt:106), shown here as a snackbar (the Flutter
/// equivalent) while the proposal stays pending.
const String coachCalendarPermissionDeniedMessage =
    CalendarService.permissionDeniedMessage;

/// Round 54 — the disclosure shown BEFORE the system calendar
/// permission request at a calendar approval (MF-3 discipline:
/// explain in-app first, request only from Continue). Native asks
/// bare at first approve; the disclosure is this build's deliberate
/// addition and changes none of native's outcomes. Takeover
/// disclosures (audit P3): the canonical text now lives in
/// calendar_service.dart ([calendarCoachDisclosure]) because
/// Settings duplicates it at the Connected Apps connect moment;
/// this name remains as an alias so existing callers/tests are
/// unchanged.
const String coachCalendarPermissionDisclosure = calendarCoachDisclosure;

/// Round 54 fix round (Juno A2) — scope notice shown ON a pending
/// calendar-DELETION proposal card in the connected state only:
/// the bridge deletes every exact-title match in the day window,
/// and the card must say so before the user taps Approve. Display
/// only — the delete selection itself is unchanged. When the flag
/// is off the card keeps the Round 48 limitation instead.
const String coachCalendarDeleteScopeNotice =
    'This deletes every event with this exact title on this date, '
    'across all your calendars.';

/// Round 48 fix round (Juno F2) — honest reason shown when a
/// Coach reminder approval stops at the permission gate. The
/// proposal stays pending and nothing is written.
const String coachReminderPermissionDeniedMessage =
    'Notification permission was not granted, so this reminder '
    'was not set. The proposal is still pending.';

/// Round 48 fix round (Vera F2) — honest reason shown when a
/// Coach note approval cannot re-pull the existing entries: the
/// approval aborts before any id is computed, so no entry is
/// posted (a blind post would use id 1 and overwrite a real one).
const String coachNotePullFailedMessage =
    'Could not load your existing history, so that note was not '
    'saved. Check your connection and try again.';

/// Round 48 fix round (Juno F3) — the distinct failure for a file
/// approval with no "📄 Uploaded file:" source message in this
/// session: the file was never attached in this app, so retrying
/// the save cannot help.
/// Round 55 Step 3 — honest failure for a LOG_ENTRY approval whose
/// category name does not resolve against the pull's categories:
/// nothing is logged and the proposal stays pending.
const String coachLogEntryUnknownCategoryMessage =
    'That category was not found in your categories, so that entry '
    'was not logged. The proposal is still pending.';

/// Round 55 Step 3 — honest failure for a LOG_ENTRY approval whose
/// re-pull failed (same discipline as the note flow: abort before
/// any id math, never the id-1 overwrite).
const String coachLogEntryPullFailedMessage =
    'Could not load your existing history, so that entry was not '
    'logged. Check your connection and try again.';

/// Round 55 Step 3 — honest failure for a COUNTER approval whose
/// date does not parse as yyyy-MM-dd.
const String coachCounterInvalidDateMessage =
    'That counter date could not be read, so the counter was not '
    'created. The proposal is still pending.';

const String coachFileNotAttachedMessage =
    'That file was not attached in this app, so there is nothing '
    'to save from here.';

/// A UUID v4 string (native uses `UUID.randomUUID()` for session,
/// message, medication, and document ids).
String newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  String hex(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${hex(0)}${hex(1)}${hex(2)}${hex(3)}-${hex(4)}${hex(5)}-'
      '${hex(6)}${hex(7)}-${hex(8)}${hex(9)}-${hex(10)}${hex(11)}'
      '${hex(12)}${hex(13)}${hex(14)}${hex(15)}';
}

int _asIntOr(dynamic v, int fallback) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

// ── Models ──────────────────────────────────────────────────────────────────

/// A coach session from the sync pull (native `CoachSessionDto`).
class CoachSessionSummary {
  final String id;
  final String title;
  final int createdAt;
  final int updatedAt;

  const CoachSessionSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CoachSessionSummary.fromJson(Map<String, dynamic> json) {
    return CoachSessionSummary(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? 'Chat'}',
      createdAt: _asIntOr(json['createdAt'], 0),
      updatedAt: _asIntOr(json['updatedAt'], 0),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

/// A coach chat message (mirrors `CoachMessageDto`). [content] is the
/// RAW stored content — proposal tags included, exactly as native
/// stores them; the UI renders [parsed] instead.
class CoachChatMessage {
  final String id;
  final String sessionId;
  final String role; // 'user' | 'coach' | 'error' (error = local only)
  final String content;
  final int timestamp;

  const CoachChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.timestamp,
  });

  factory CoachChatMessage.fromJson(Map<String, dynamic> json) {
    return CoachChatMessage(
      id: '${json['id'] ?? ''}',
      sessionId: '${json['sessionId'] ?? ''}',
      role: '${json['role'] ?? 'coach'}',
      content: '${json['content'] ?? ''}',
      timestamp: _asIntOr(json['timestamp'], 0),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'role': role,
        'content': content,
        'timestamp': timestamp,
      };

  CoachChatMessage copyWith({String? content}) => CoachChatMessage(
        id: id,
        sessionId: sessionId,
        role: role,
        content: content ?? this.content,
        timestamp: timestamp,
      );

  /// The proposal parse of [content] (native `parseCoachMessageContent`).
  CoachParsedContent get parsed => parseCoachMessageContent(content);
}

// ── Proposal parsing (native parseCoachMessageContent port) ────────────────

enum CoachProposalStatus { none, pending, approved, denied }

/// One proposed medication (native `Medication` from a
/// `[PROPOSE_MEDICATION:Name|Start|End|isPresent;...]` tag).
class CoachMedProposal {
  final String name;
  final String startDate;
  final String endDate;
  final bool isPresent;

  /// Round 55 Step 3: dose/frequency from the extended 6-field
  /// grammar. Empty for legacy 4-field tags (approvals then keep
  /// the historical placeholders).
  final String dose;
  final String frequency;

  const CoachMedProposal({
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.isPresent,
    this.dose = '',
    this.frequency = '',
  });
}

/// The result of parsing one coach message's raw content: the clean
/// display text plus every proposal and its status.
class CoachParsedContent {
  final String cleanContent;
  final String? noteText;
  final CoachProposalStatus noteStatus;
  final String? fileName;
  final CoachProposalStatus fileStatus;
  final String? listName;
  final List<String> listItems;
  final CoachProposalStatus listStatus;
  final String? reminderTitle;
  final String? reminderTime;
  final CoachProposalStatus reminderStatus;
  final String? calendarTitle;
  final String? calendarDate;
  final String? calendarTime;
  final String? calendarDesc;
  final CoachProposalStatus calendarStatus;
  final String? calendarDeleteTitle;
  final String? calendarDeleteDate;
  final CoachProposalStatus calendarDeleteStatus;
  final List<CoachMedProposal> medications;
  final CoachProposalStatus medicationStatus;
  final String? logEntryCategory;
  final String? logEntryText;
  final CoachProposalStatus logEntryStatus;
  final String? counterName;
  final String? counterDate;
  final CoachProposalStatus counterStatus;

  const CoachParsedContent({
    required this.cleanContent,
    this.noteText,
    this.noteStatus = CoachProposalStatus.none,
    this.fileName,
    this.fileStatus = CoachProposalStatus.none,
    this.listName,
    this.listItems = const [],
    this.listStatus = CoachProposalStatus.none,
    this.reminderTitle,
    this.reminderTime,
    this.reminderStatus = CoachProposalStatus.none,
    this.calendarTitle,
    this.calendarDate,
    this.calendarTime,
    this.calendarDesc,
    this.calendarStatus = CoachProposalStatus.none,
    this.calendarDeleteTitle,
    this.calendarDeleteDate,
    this.calendarDeleteStatus = CoachProposalStatus.none,
    this.medications = const [],
    this.medicationStatus = CoachProposalStatus.none,
    this.logEntryCategory,
    this.logEntryText,
    this.logEntryStatus = CoachProposalStatus.none,
    this.counterName,
    this.counterDate,
    this.counterStatus = CoachProposalStatus.none,
  });
}

/// Extracts the first `[VERB_KIND: value]` tag for [kind], checking
/// PROPOSE → APPROVED → DENIED exactly like native. Returns the
/// content with the matched tag removed (trimmed), the tag value,
/// and the status.
(String, String?, CoachProposalStatus) _takeTag(String content, String kind) {
  const verbs = [
    ('PROPOSE', CoachProposalStatus.pending),
    ('APPROVED', CoachProposalStatus.approved),
    ('DENIED', CoachProposalStatus.denied),
  ];
  for (final (verb, status) in verbs) {
    final re = RegExp('\\[${verb}_$kind:\\s*([^\\]]+)\\]',
        caseSensitive: false, dotAll: true);
    final m = re.firstMatch(content);
    if (m != null) {
      return (
        content.replaceFirst(m.group(0)!, '').trim(),
        m.group(1)!.trim(),
        status,
      );
    }
  }
  return (content, null, CoachProposalStatus.none);
}

/// Whether [v] reads as a present flag (the legacy grammar's
/// 4th field / the extended grammar's 6th field).
bool _isPresentFlag(String v) {
  final t = v.trim().toLowerCase();
  return t == 'true' || t == 'false';
}

/// Round 55 Step 3 — medication tag disambiguation rule, final
/// form after the Round 55 fix pass (Vera 4d, fail-safe):
/// - Exactly 6 fields AND field 6 is a recognizable present flag
///   (true/false): the EXTENDED grammar
///   Name|Dose|Frequency|StartDate|EndDate|isPresent.
/// - 6 or more fields where field 6 is NOT a recognizable present
///   flag, OR more than 6 fields at all (for example a medication
///   name that itself contains a pipe, shifting every slot): FAIL
///   SAFE to a placeholders parse — name is field 1, dose and
///   frequency stay EMPTY (never a shifted value), and
///   start/end/present come from the FINAL three fields, with
///   present parsed from the very last field.
/// - Exactly 5 fields: the extended grammar
///   (Name|Dose|Frequency|StartDate|isPresent, empty EndDate) is
///   taken ONLY when field 5 IS a present flag and field 4 is
///   NOT one. Otherwise the tag is legacy (Name|StartDate|EndDate|
///   isPresent, any 5th field ignored — exactly as pre-Round-55
///   tags with trailing data behaved).
/// - 4 or fewer fields: the LEGACY grammar
///   Name|StartDate|EndDate|isPresent (dose/frequency stay empty,
///   so approvals keep the historical placeholders).
List<CoachMedProposal> _parseMedicationString(String raw) {
  final out = <CoachMedProposal>[];
  for (final item in raw.split(';')) {
    final parts = item.split('|');
    final name = (parts.isNotEmpty ? parts[0] : '').trim();
    if (name.isEmpty) continue;
    String dose = '';
    String frequency = '';
    String startDate;
    var endDate = '';
    bool isPresent;
    if (parts.length >= 6 &&
        !(parts.length == 6 && _isPresentFlag(parts[5]))) {
      // Fail-safe placeholders parse (see the rule above): no
      // dose/frequency is read from shifted slots; the dates and
      // the present flag come from the final three fields.
      startDate = parts[parts.length - 3].trim();
      endDate = parts[parts.length - 2].trim();
      isPresent =
          parts[parts.length - 1].trim().toLowerCase() == 'true';
    } else if (parts.length >= 6) {
      dose = parts[1].trim();
      frequency = parts[2].trim();
      startDate = parts[3].trim();
      endDate = parts[4].trim();
      isPresent = parts[5].trim().toLowerCase() == 'true';
    } else if (parts.length == 5 &&
        _isPresentFlag(parts[4]) &&
        !_isPresentFlag(parts[3])) {
      dose = parts[1].trim();
      frequency = parts[2].trim();
      startDate = parts[3].trim();
      isPresent = parts[4].trim().toLowerCase() == 'true';
    } else {
      startDate = parts.length > 1 ? parts[1].trim() : '';
      endDate = parts.length > 2 ? parts[2].trim() : '';
      isPresent =
          parts.length > 3 && parts[3].trim().toLowerCase() == 'true';
    }
    if (isPresent) endDate = 'Present';
    out.add(CoachMedProposal(
      name: name,
      startDate: startDate,
      endDate: endDate,
      isPresent: isPresent,
      dose: dose,
      frequency: frequency,
    ));
  }
  return out;
}

/// Ports native `parseCoachMessageContent` (CoachViewModel.kt):
/// strips every `[PROPOSE_*]` / `[APPROVED_*]` / `[DENIED_*]` action
/// tag from the display text and reports each proposal + status.
/// Pure and unit-tested. Never throws.
CoachParsedContent parseCoachMessageContent(String rawContent) {
  // Round 55 fix pass (Vera): the REMEMBER extraction also runs
  // here, so a stored/synced message can neither render nor
  // re-persist a REMEMBER line.
  var clean = extractCoachRememberLine(rawContent).$1;

  String? noteText;
  var noteStatus = CoachProposalStatus.none;
  (clean, noteText, noteStatus) = _takeTag(clean, 'NOTE');

  String? fileName;
  var fileStatus = CoachProposalStatus.none;
  (clean, fileName, fileStatus) = _takeTag(clean, 'FILE');

  String? listName;
  var listItems = <String>[];
  var listStatus = CoachProposalStatus.none;
  String? listRaw;
  (clean, listRaw, listStatus) = _takeTag(clean, 'LIST');
  if (listRaw != null) {
    final parts = listRaw.split('|');
    listName = parts.first.trim();
    if (parts.length > 1) {
      listItems = [
        for (final p in parts.sublist(1))
          if (p.trim().isNotEmpty) p.trim(),
      ];
    }
  }

  String? reminderTitle;
  String? reminderTime;
  var reminderStatus = CoachProposalStatus.none;
  String? reminderRaw;
  (clean, reminderRaw, reminderStatus) = _takeTag(clean, 'REMINDER');
  if (reminderRaw != null) {
    final parts = reminderRaw.split('|');
    reminderTitle = parts.first.trim();
    reminderTime = parts.length > 1 ? parts[1].trim() : null;
  }

  String? calendarTitle;
  String? calendarDate;
  String? calendarTime;
  String? calendarDesc;
  var calendarStatus = CoachProposalStatus.none;
  String? calendarRaw;
  (clean, calendarRaw, calendarStatus) = _takeTag(clean, 'CALENDAR_EVENT');
  if (calendarRaw != null) {
    final parts = calendarRaw.split('|');
    calendarTitle = parts.first.trim();
    calendarDate = parts.length > 1 ? parts[1].trim() : null;
    calendarTime = parts.length > 2 ? parts[2].trim() : null;
    calendarDesc = parts.length > 3 ? parts[3].trim() : null;
  }

  String? calendarDeleteTitle;
  String? calendarDeleteDate;
  var calendarDeleteStatus = CoachProposalStatus.none;
  String? deleteRaw;
  (clean, deleteRaw, calendarDeleteStatus) =
      _takeTag(clean, 'DELETE_CALENDAR_EVENT');
  if (deleteRaw != null) {
    final parts = deleteRaw.split('|');
    calendarDeleteTitle = parts.first.trim();
    calendarDeleteDate = parts.length > 1 ? parts[1].trim() : null;
  }

  // Medications: native collects ALL tags of the winning verb.
  var medications = <CoachMedProposal>[];
  var medicationStatus = CoachProposalStatus.none;
  for (final (verb, status) in [
    ('PROPOSE', CoachProposalStatus.pending),
    ('APPROVED', CoachProposalStatus.approved),
    ('DENIED', CoachProposalStatus.denied),
  ]) {
    final re = RegExp('\\[${verb}_MEDICATION:\\s*([^\\]]+)\\]',
        caseSensitive: false, dotAll: true);
    final matches = re.allMatches(clean).toList();
    if (matches.isNotEmpty) {
      for (final m in matches) {
        medications.addAll(_parseMedicationString(m.group(1)!));
        clean = clean.replaceFirst(m.group(0)!, '');
      }
      clean = clean.trim();
      medicationStatus = status;
      break;
    }
  }

  String? logEntryCategory;
  String? logEntryText;
  var logEntryStatus = CoachProposalStatus.none;
  String? logEntryRaw;
  (clean, logEntryRaw, logEntryStatus) = _takeTag(clean, 'LOG_ENTRY');
  if (logEntryRaw != null) {
    final idx = logEntryRaw.indexOf('|');
    if (idx >= 0) {
      logEntryCategory = logEntryRaw.substring(0, idx).trim();
      logEntryText = logEntryRaw.substring(idx + 1).trim();
    } else {
      logEntryCategory = '';
      logEntryText = logEntryRaw.trim();
    }
    if (logEntryCategory.isEmpty) logEntryCategory = null;
    if (logEntryText.isEmpty) logEntryText = null;
  }

  String? counterName;
  String? counterDate;
  var counterStatus = CoachProposalStatus.none;
  String? counterRaw;
  (clean, counterRaw, counterStatus) = _takeTag(clean, 'COUNTER');
  if (counterRaw != null) {
    final parts = counterRaw.split('|');
    counterName = parts.first.trim();
    counterDate = parts.length > 1 ? parts[1].trim() : null;
    if (counterName.isEmpty) counterName = null;
  }

  return CoachParsedContent(
    cleanContent: clean,
    noteText: noteText,
    noteStatus: noteStatus,
    fileName: fileName,
    fileStatus: fileStatus,
    listName: listName,
    listItems: listItems,
    listStatus: listStatus,
    reminderTitle: reminderTitle,
    reminderTime: reminderTime,
    reminderStatus: reminderStatus,
    calendarTitle: calendarTitle,
    calendarDate: calendarDate,
    calendarTime: calendarTime,
    calendarDesc: calendarDesc,
    calendarStatus: calendarStatus,
    calendarDeleteTitle: calendarDeleteTitle,
    calendarDeleteDate: calendarDeleteDate,
    calendarDeleteStatus: calendarDeleteStatus,
    medications: medications,
    medicationStatus: medicationStatus,
    logEntryCategory: logEntryCategory,
    logEntryText: logEntryText,
    logEntryStatus: logEntryStatus,
    counterName: counterName,
    counterDate: counterDate,
    counterStatus: counterStatus,
  );
}

/// Rewrites a `[PROPOSE_KIND:` prefix to `[NEWVERB_KIND:` in raw
/// stored content (native's approve/deny persistence). All
/// occurrences, case-insensitive — like native's replace.
String rewriteProposalTag(String content, String kind, String newVerb) {
  return content.replaceAll(
    RegExp('\\[PROPOSE\\_$kind:', caseSensitive: false),
    '[${newVerb}_$kind:',
  );
}

/// Cleans AI text for display: strips HTML tags, decodes the common
/// entities, and removes markdown emphasis markers (native renders
/// `**bold**` / `*italic*` as styled spans, so the markers never
/// reach the user there either). Raw markup never renders.
String cleanCoachDisplayText(String raw) {
  var text = raw.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  text = text.replaceAllMapped(
      RegExp(r'\*\*(.+?)\*\*', dotAll: true), (m) => m.group(1)!);
  text = text.replaceAllMapped(
      RegExp(r'\*(.+?)\*', dotAll: true), (m) => m.group(1)!);
  return text.trim();
}

// ── Coach request context (native sendMessage enrichment) ───────────────────

const _weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
  'Sunday'
];
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'
];

String _pad2(int v) => v.toString().padLeft(2, '0');

/// "EEEE, MMMM dd, yyyy HH:mm" (native's SimpleDateFormat pattern).
String formatCoachNow(DateTime now) =>
    '${_weekdayNames[now.weekday - 1]}, ${_monthNames[now.month - 1]} '
    '${_pad2(now.day)}, ${now.year} ${_pad2(now.hour)}:${_pad2(now.minute)}';

/// "yyyy-MM-dd".
String formatCoachDateOnly(DateTime now) =>
    '${now.year}-${_pad2(now.month)}-${_pad2(now.day)}';

/// The enriched user context native `CoachViewModel.sendMessage`
/// sends: the profile's base context plus the action-proposal
/// instructions (lists, reminders, medications) and native's
/// calendar branch (CoachViewModel.kt:1364-1392).
///
/// NOT connected (native :1390-1392, mirrored by Round 48 with this
/// build's CURRENT TIME line and an explicit delete-tag ban): the
/// AI is guided to send the user to Settings -> Connected Apps to
/// connect Google Calendar first and NOT to output calendar tags.
///
/// CONNECTED (Round 54, native :1364-1388 verbatim): the CURRENT
/// TIME line, the IMPORTANT DATE RESOLUTION RULES block, the live
/// upcoming-events context ([calendarEventsContext] — native's
/// `getUpcomingCalendarEvents` output), the two proposal tag
/// formats, and the CRITICAL RULES FOR READING & SCHEDULING
/// EVENTS 1-3.
String coachEnrichedUserContext(String? baseUserContext,
    {required DateTime now,
    String healthContext = '',
    String memoryContext = '',
    bool calendarConnected = false,
    String calendarEventsContext = coachCalendarNotConnectedContext}) {
  final todayStr = formatCoachNow(now);
  final todayDateOnly = formatCoachDateOnly(now);
  final calendarInstructions = calendarConnected
      ? '''
CURRENT TIME: The user's current local date and time is $todayStr. Today's date is $todayDateOnly.

IMPORTANT DATE RESOLUTION RULES:
- "today" = $todayDateOnly
- "tomorrow" = the day after $todayDateOnly
- "next [weekday]" = the next occurrence of that weekday after today
- If the user says "add an event for today" or "schedule something today", use $todayDateOnly as the date — do NOT ask what day they want.
- If the user says "add an event" without specifying a day, infer the date from context or use today ($todayDateOnly) as default.

$calendarEventsContext

CALENDAR EVENTS: Since Google Calendar is connected, you can propose scheduling events, setting appointments, calendar updates, or deletions.
Format for Proposing Event: [PROPOSE_CALENDAR_EVENT:Event Title|YYYY-MM-DD|hh:mm AM/PM|Description]
Use 12-hour format with AM/PM for the time (e.g. 02:30 PM). Suggest a reasonable date, time, and description based on context if not fully specified.
If the user wants changes, simply generate a new revised [PROPOSE_CALENDAR_EVENT:...] tag.

Format for Deleting Event: [PROPOSE_DELETE_CALENDAR_EVENT:Event Title|YYYY-MM-DD]
If the user wants to cancel or delete an event, propose it using this tag.

CRITICAL RULES FOR READING & SCHEDULING EVENTS:
1. When discussing or listing read-only calendar events (like those in the context above), DO NOT ALTER THEIR TITLES OR APPEND APP-SPECIFIC PHRASES. Use their exact names (e.g. if the event is "Physical therapy", call it "Physical therapy", not "Physical therapy for ehlers danlos syndrome").
2. Use normal 12-hour time format with AM/PM (e.g., "02:30 PM") in your conversational responses.
3. When asked "what do I have today", include ALL events on $todayDateOnly regardless of whether they are past or future — the user wants the full day's schedule.'''
      : '''
CURRENT TIME: The user's current local date and time is $todayStr. Today's date is $todayDateOnly.

CALENDAR EVENTS: Since Google Calendar is NOT connected yet, if the user asks you to schedule a calendar event or appointment, politely guide them to connect their Google Calendar first in Settings -> Connected Apps. Do NOT output a [PROPOSE_CALENDAR_EVENT:...] tag. Do NOT output a [PROPOSE_DELETE_CALENDAR_EVENT:...] tag.''';

  final actionInstructions = '''
SYSTEM RULES FOR PROPOSING ACTIONS:

LISTS: If the user mentions lists, tasks, items to buy, check off, do, pack, or track, helpfully ask if they'd like to turn it into a list. Format: [PROPOSE_LIST:ListName|Item1|Item2|Item3|...]
Example: [PROPOSE_LIST:Packing List|T-shirts|Socks|Toothbrush]

REMINDERS: If the user mentions wanting to be reminded of something, wanting to remember something at a certain time, or asks you to set a reminder, propose a reminder. Format: [PROPOSE_REMINDER:Reminder Title|HH:MM]
Use 24-hour format for the time. Example: [PROPOSE_REMINDER:Take medication|08:00]
If no specific time is mentioned, suggest a reasonable time based on context.

LOG ENTRIES: If the user asks you to log, record, or note an entry in one of their existing log categories, propose logging it. Format: [PROPOSE_LOG_ENTRY:CategoryName|Entry text]
Use the exact name of one of the user's existing categories (they are named in the recent logs context above). Example: [PROPOSE_LOG_ENTRY:Symptoms|Headache started after lunch]

EVENT COUNTERS: If the user wants to track how many days it has been since an event, or how many days remain until an event, propose an event counter. Format: [PROPOSE_COUNTER:Counter name|yyyy-MM-dd]
Example: [PROPOSE_COUNTER:Last migraine|2026-10-01]

MEDICATIONS: You MUST actively inspect the user's message and the contents of any uploaded files/documents (indicated by "📄 Uploaded file: [filename]\\n\\n[contents]") for medications. If the user mentions starting, taking, stopping, or updating medications, or if the uploaded document says the user is taking or was taking any medications, you MUST propose adding them.
Format: Propose ALL found medications in a single tag by separating them with a semicolon.
Each medication format: Name|Dose|Frequency|StartDate|EndDate|isPresent
Include the dose (for example "60 mg") and frequency (for example "3 times daily") when the user or the document states them; leave them empty when they are not stated.
Use 'isPresent' as 'true' if the user is currently taking the medication, or 'false' if they have stopped. If they are currently taking it, the EndDate should be empty.
Dates should look like "Jun 2026", "2025-12-05", "Dec 2025" or similar based on context.
Example for multiple medications: [PROPOSE_MEDICATION:Pyridostigmine|60 mg|3 times daily|Jun 2026||true;Metoprolol|25 mg|Once daily|Jan 2025|May 2026|false]

MEMORY: When the user states a durable health or goal fact or a decision (what they are trying, what they decided to start, or what they stopped), end your reply with exactly one line in the form REMEMBER: followed by one short sentence capturing only what the user stated. If the user describes an effect, capture it as their report, starting with 'User reported', and not as an established result. Include at most one REMEMBER line per reply, and only when there is a durable fact or decision to remember.

$calendarInstructions

Only include ONE action tag per response. (Note: For multiple medications, combine them into a single [PROPOSE_MEDICATION:...] tag separated by semicolons as shown above). Do not include markdown formatting inside the brackets.''';

  final base = (baseUserContext ?? '').trim();
  // Round 55 Step 1/2: the fresh health block (and, adjacent to it,
  // the coach-memory block) rides between the user's base context
  // and the action instructions. With neither block present the
  // result is byte-identical to the pre-Round-55 shape.
  final extra = [
    if (healthContext.trim().isNotEmpty) healthContext.trim(),
    if (memoryContext.trim().isNotEmpty) memoryContext.trim(),
  ].join('\n\n');
  final parts = [
    if (base.isNotEmpty) base,
    if (extra.isNotEmpty) extra,
    actionInstructions,
  ];
  return parts.join('\n\n');
}

// ── Round 55 Step 1: real-data coach context ────────────────────────────────
//
// The server forwards userContext as a sanitized plain-text string
// and strips square brackets and angle brackets from it, so every
// section below is plain text with plain headings and NO brackets
// or angle brackets in data values (see _coachPlain). Biometric
// rule: a 0 is a failed read and is treated as missing everywhere
// below — it is never printed, averaged, or counted as a night.

/// Hard budget for the added health context, in characters.
const int coachHealthContextBudget = 9000;

/// Strips the characters the server sanitizer would remove anyway
/// (and any raw JSON look) from a data value riding userContext.
String coachPlainText(String raw) => raw
    .replaceAll('[', '(')
    .replaceAll(']', ')')
    .replaceAll('<', '')
    .replaceAll('>', '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _coachDateStr(DateTime d) =>
    '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}';

int? _coachPositiveInt(dynamic v) {
  final n = v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
  return (n != null && n > 0) ? n : null;
}

double? _coachPositiveDouble(dynamic v) {
  final n = v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
  return (n != null && n > 0) ? n : null;
}

/// R61 — sleep minutes in coach context use the single shared compact
/// formatter (founder ruling, Oct 15, 2026: `7h6m` everywhere).
/// Exact-hour values now render both parts (`8h0m`, previously `8h`).
String _coachFmtMins(int mins) => formatSleepMinutes(mins);

String _coachFmtHours(double hours) {
  final mins = (hours * 60).round();
  return _coachFmtMins(mins);
}

/// Health Connect snapshot precomputed by the chat screen's guarded
/// loader. Every field is nullable/empty when its source was missing
/// or failed — the assembler omits those sections entirely.
class CoachHealthSnapshot {
  /// Sleep nights with real data (mins greater than 0).
  final List<({String date, int mins})> sleepNights;

  /// Current sleep debt as a positive number of minutes owed.
  final int? sleepDebtMins;
  final int? restingLatestBpm;
  final String? restingLatestDate;
  final double? restingAvg7Bpm;
  final int? daytimeHrTodayBpm;
  final double? hrvLatestMs;
  final int? spikesLast7Total;
  final int? spikesToday;
  final List<({String name, int streak})> habits;
  final BpRecord? latestBp;
  final ({int sys, int dia})? bpAvg7;
  final String? weatherLine;

  const CoachHealthSnapshot({
    this.sleepNights = const [],
    this.sleepDebtMins,
    this.restingLatestBpm,
    this.restingLatestDate,
    this.restingAvg7Bpm,
    this.daytimeHrTodayBpm,
    this.hrvLatestMs,
    this.spikesLast7Total,
    this.spikesToday,
    this.habits = const [],
    this.latestBp,
    this.bpAvg7,
    this.weatherLine,
  });
}

int _logRelevanceRank(String categoryName) {
  final n = categoryName.toLowerCase();
  if (n.contains('symptom')) return 0;
  if (n.contains('medication') || n.contains('med')) return 1;
  if (n.contains('mood') || n.contains('energy')) return 2;
  return 3;
}

/// Dated, categorized digest lines for the last 14 days of pull
/// entries, most relevant first (symptom, then medication, then
/// mood categories, then everything else; newest first inside a
/// rank). Capped at [cap] lines. Plain text only.
List<String> coachLogDigestLines(
  List<Map<String, dynamic>> entries,
  List<Map<String, dynamic>> categories, {
  required DateTime now,
  int cap = 20,
}) {
  final catNames = <int, String>{
    for (final c in categories)
      if (_asIntOr(c['id'], -1) >= 0)
        _asIntOr(c['id'], 0): coachPlainText('${c['name'] ?? ''}'),
  };
  final cutoff = DateTime(now.year, now.month, now.day)
      .subtract(const Duration(days: 14))
      .millisecondsSinceEpoch;
  final rows = <({int rank, int ts, String line})>[];
  for (final e in entries) {
    final ts = _asIntOr(e['timestamp'], 0);
    if (ts < cutoff || ts <= 0) continue;
    var body = coachPlainText('${e['body'] ?? ''}');
    if (body.isEmpty) body = coachPlainText('${e['manualText'] ?? ''}');
    if (body.isEmpty) continue;
    if (body.length > 160) body = '${body.substring(0, 157)}...';
    final catId = _asIntOr(e['categoryId'], 0);
    final cat = catNames[catId] ?? 'General';
    final date = _coachDateStr(DateTime.fromMillisecondsSinceEpoch(ts));
    rows.add((
      rank: _logRelevanceRank(cat),
      ts: ts,
      line: '$date $cat: $body',
    ));
  }
  rows.sort((a, b) {
    final r = a.rank.compareTo(b.rank);
    return r != 0 ? r : b.ts.compareTo(a.ts);
  });
  return [for (final r in rows.take(cap)) r.line];
}

/// Feeling check-in history for the bodyLoadHistory request field:
/// one plain line per energy day, 2026-10-12: 3/5, for the last 14
/// days. Detection is the app's existing rule (Mood and Energy
/// category plus the Daily Ranking chip, see feeling_checkin_card).
String buildCoachBodyLoadHistory(
  List<Map<String, dynamic>> entries,
  List<Map<String, dynamic>> categories, {
  required DateTime now,
}) {
  final cats = <QuickLogCategory>[];
  for (final c in categories) {
    try {
      cats.add(QuickLogCategory.fromJson(c));
    } catch (_) {}
  }
  final moodId = resolveFeelingCategoryId(cats);
  if (moodId == null) return '';
  final byDay = <String, ({int ts, int value})>{};
  final cutoffDay = DateTime(now.year, now.month, now.day)
      .subtract(const Duration(days: 14));
  for (final e in entries) {
    if (_asIntOr(e['categoryId'], -1) != moodId) continue;
    if (!chipsContainFeelingTag('${e['chips'] ?? ''}')) continue;
    final m = RegExp(r'Feeling:\s*([1-5])\s*/\s*5')
        .firstMatch('${e['body'] ?? ''}');
    if (m == null) continue;
    final ts = _asIntOr(e['timestamp'], 0);
    if (ts <= 0) continue;
    final when = DateTime.fromMillisecondsSinceEpoch(ts);
    final dayStart = feelingDayStart(when);
    if (dayStart.isBefore(cutoffDay)) continue;
    final key = _coachDateStr(dayStart);
    final value = int.parse(m.group(1)!);
    final prev = byDay[key];
    if (prev == null || ts >= prev.ts) byDay[key] = (ts: ts, value: value);
  }
  final days = byDay.keys.toList()..sort();
  return [for (final d in days) '$d: ${byDay[d]!.value}/5'].join('\n');
}

/// Assembles the compact plain-text health block from the profile
/// map already in hand, the pull entries/categories, and a Health
/// Connect snapshot. Failure-tolerant by construction: missing
/// sources simply omit their section. Hard budget
/// [coachHealthContextBudget]: the log digest is truncated first,
/// then the oldest sleep nights.
String buildCoachHealthContext({
  Map<String, dynamic>? profile,
  List<Map<String, dynamic>> entries = const [],
  List<Map<String, dynamic>> categories = const [],
  CoachHealthSnapshot? health,
  String knowledgeDocumentsText = '',
  required DateTime now,
}) {
  final p = profile ?? const <String, dynamic>{};
  var logLines = coachLogDigestLines(entries, categories, now: now);
  // Round 65: extracted document texts (native's report path joins
  // them into the AI context the same way). They ride as the
  // LOWEST-priority section: chunks (split on the "\n\n" joins) are
  // dropped from the end before anything else is truncated, so the
  // extracted text can never displace clinician updates or the
  // fresh health sections under the budget below.
  var docChunks = knowledgeDocumentsText
      .split('\n\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  // A 0-minute night is a failed read, never a real night — the
  // assembler enforces it too, not just the loader.
  var nights = [
    for (final n in health?.sleepNights ?? const <({String date, int mins})>[])
      if (n.mins > 0) n,
  ]..sort((a, b) => a.date.compareTo(b.date));
  if (nights.length > 7) nights = nights.sublist(nights.length - 7);

  String assemble() {
    final sections = <String>[];

    // Professional / clinician updates first: native advice treats
    // them as highest priority.
    final pro = coachPlainText('${p['professionalUpdates'] ?? ''}');
    if (pro.isNotEmpty) {
      final capped = pro.length > 2000 ? pro.substring(0, 2000) : pro;
      sections.add('CLINICIAN UPDATES (highest priority):\n$capped');
    }

    // Profile: demographics in the native enriched shape.
    final demo = <String>[];
    final gender = coachPlainText('${p['gender'] ?? ''}');
    if (gender.isNotEmpty) demo.add('Gender: $gender');
    final age = _coachPositiveInt(p['age']);
    if (age != null) demo.add('Age: $age');
    final heightCm = _coachPositiveDouble(p['heightCm']);
    if (heightCm != null) {
      demo.add('Height: ${heightCm.round()} cm');
    }
    final weightKg = _coachPositiveDouble(p['weightKg']);
    if (weightKg != null) {
      demo.add('Weight: ${(weightKg * 2.20462).round()} lbs');
    }
    if (demo.isNotEmpty) {
      sections.add('Profile Info: ${demo.join(', ')}');
    }

    final conditions = TabsBackend.decodeProfileList(p['conditions']);
    final condNames = [
      for (final c in conditions)
        if (coachPlainText('${c['name'] ?? ''}').isNotEmpty)
          coachPlainText('${c['name'] ?? ''}'),
    ];
    if (condNames.isNotEmpty) {
      sections.add('Conditions: ${condNames.join(', ')}');
    }

    // Active medications from the profile map in hand.
    final medRows = TabsBackend.decodeProfileList(p['medications']);
    final medLines = <String>[];
    for (final row in medRows) {
      final med = MedicationEntry.fromBlobRow(row);
      if (med == null || med.isDeleted || med.isArchived) continue;
      final parts = <String>[coachPlainText(med.name)];
      if (med.dose.trim().isNotEmpty) {
        parts.add('dose ${coachPlainText(med.dose)}');
      }
      if (med.rawFrequency.trim().isNotEmpty) {
        parts.add(coachPlainText(med.rawFrequency));
      }
      medLines.add(parts.join(', '));
    }
    if (medLines.isNotEmpty) {
      sections.add('Active medications:\n${medLines.map((l) => '- $l').join('\n')}');
    }

    // Today's vitals keys already in the profile map.
    final vitals = <String>[];
    final tSleep = _coachPositiveInt(p['todaySleepMins']);
    if (tSleep != null) vitals.add('sleep last night ${_coachFmtMins(tSleep)}');
    final tHr = _coachPositiveInt(p['todayAvgHr']);
    if (tHr != null) vitals.add('daytime heart rate average $tHr bpm');
    final tSpikesRaw = p['todaySpikes'];
    final tSpikes = tSpikesRaw is num
        ? tSpikesRaw.toInt()
        : (tSpikesRaw is String ? int.tryParse(tSpikesRaw) : null);
    if (tSpikes != null) {
      vitals.add(tSpikes == 1 ? '1 heart rate spike today' : '$tSpikes heart rate spikes today');
    }
    final tDebtRaw = p['todaySleepDebt'];
    final tDebt = tDebtRaw is num
        ? tDebtRaw.toInt()
        : (tDebtRaw is String ? int.tryParse(tDebtRaw) : null);
    if (tDebt != null) {
      vitals.add(tDebt == 0
          ? 'sleep debt none'
          : 'sleep debt about ${_coachFmtMins(tDebt.abs())}');
    }
    if (vitals.isNotEmpty) {
      sections.add('Today from profile: ${vitals.join('; ')}.');
    }

    // Health Connect sections.
    if (health != null) {
      if (nights.isNotEmpty) {
        final avgMins =
            nights.fold<int>(0, (a, n) => a + n.mins) / nights.length;
        final last = nights.last;
        final perNight =
            nights.map((n) => '${n.date} ${_coachFmtMins(n.mins)}').join(', ');
        var line =
            'Sleep last ${nights.length} nights: avg ${_coachFmtHours(avgMins / 60)}; '
            'last night ${_coachFmtMins(last.mins)}';
        final debt = health.sleepDebtMins;
        if (debt != null && debt > 0) {
          line += '; sleep debt about ${_coachFmtMins(debt)}';
        }
        sections.add('$line.\nPer night: $perNight.');
      }
      final hrParts = <String>[];
      if (health.restingLatestBpm != null && health.restingLatestBpm! > 0) {
        hrParts.add('resting heart rate ${health.restingLatestBpm} bpm'
            '${health.restingLatestDate != null ? ' on ${health.restingLatestDate}' : ''}');
      }
      if (health.restingAvg7Bpm != null && health.restingAvg7Bpm! > 0) {
        hrParts.add(
            'resting heart rate 7 day average ${health.restingAvg7Bpm!.round()} bpm');
      }
      if (health.daytimeHrTodayBpm != null && health.daytimeHrTodayBpm! > 0) {
        hrParts.add(
            'daytime heart rate today (7am to 11pm) average ${health.daytimeHrTodayBpm} bpm');
      }
      if (health.hrvLatestMs != null && health.hrvLatestMs! > 0) {
        hrParts.add('latest HRV ${health.hrvLatestMs!.round()} ms');
      }
      if (hrParts.isNotEmpty) {
        sections.add('Heart: ${hrParts.join('; ')}.');
      }
      if (health.spikesLast7Total != null || health.spikesToday != null) {
        final parts = <String>[];
        if (health.spikesLast7Total != null) {
          parts.add('${health.spikesLast7Total} heart rate spikes in the last 7 days');
        }
        if (health.spikesToday != null) {
          parts.add('${health.spikesToday} today');
        }
        sections.add('Heart rate spikes: ${parts.join('; ')}.');
      }
      if (health.latestBp != null) {
        final bp = health.latestBp!;
        if (bp.systolic > 0 && bp.diastolic > 0) {
          var line =
              'Blood pressure: latest ${bp.systolic}/${bp.diastolic} mmHg';
          if (health.bpAvg7 != null) {
            line +=
                '; 7 day average ${health.bpAvg7!.sys}/${health.bpAvg7!.dia} mmHg';
          }
          sections.add('$line.');
        }
      }
      if (health.habits.isNotEmpty) {
        final lines = [
          for (final h in health.habits)
            '- ${coachPlainText(h.name)}: current streak ${h.streak} ${h.streak == 1 ? 'day' : 'days'}',
        ];
        sections.add('Habits:\n${lines.join('\n')}');
      }
      if (health.weatherLine != null &&
          health.weatherLine!.trim().isNotEmpty) {
        sections.add('Weather today: ${coachPlainText(health.weatherLine!)}.');
      }
    }

    // Goals: event counters (day counts like Settings and Home)
    // plus an active Project Focus test when it parses cheaply.
    final goalLines = <String>[];
    final counterRows = TabsBackend.decodeProfileList(p['eventCounters']);
    for (final row in counterRows) {
      try {
        final c = EventCounterItem.fromMap(row);
        if (c.isArchived || c.name.trim().isEmpty) continue;
        goalLines.add(
            '- ${coachPlainText(c.name)}: ${c.daysLabel(now: now)}');
      } catch (_) {}
    }
    try {
      final focusDecoded = TabsBackend.decodeProfileList(p['focusState']);
      final tests = collectFocusTests(focusDecoded)
          .where((t) => !t.isCompletedAt(now.millisecondsSinceEpoch))
          .toList();
      if (tests.isNotEmpty) {
        final t = tests.first;
        final startDay = DateTime.fromMillisecondsSinceEpoch(t.startTimestamp);
        final dayCount = DateTime(now.year, now.month, now.day)
                .difference(DateTime(startDay.year, startDay.month, startDay.day))
                .inDays +
            1;
        final logged = t.logs.values.where((v) => v).length;
        goalLines.add(
            '- Active Project Focus test: ${coachPlainText(t.title)}, day $dayCount of ${t.durationDays}, logged $logged ${logged == 1 ? 'day' : 'days'} so far');
      }
    } catch (_) {}
    if (goalLines.isNotEmpty) {
      sections.add('Goals and event counters:\n${goalLines.join('\n')}');
    }

    if (logLines.isNotEmpty) {
      sections.add(
          'Recent logs, last 14 days, most relevant first:\n${logLines.join('\n')}');
    }

    // Round 65: knowledge documents LAST (lowest priority — see
    // the docChunks note at the top of this function).
    if (docChunks.isNotEmpty) {
      sections.add(
          'Knowledge documents (extracted):\n${docChunks.join('\n\n')}');
    }
    return sections.join('\n\n');
  }

  var result = assemble();
  // Budget: drop extracted-document chunks first (Round 65), then
  // truncate the log digest, then the oldest sleep nights.
  while (result.length > coachHealthContextBudget && docChunks.isNotEmpty) {
    docChunks = docChunks.sublist(0, docChunks.length - 1);
    result = assemble();
  }
  while (result.length > coachHealthContextBudget && logLines.isNotEmpty) {
    logLines = logLines.sublist(0, logLines.length - 1);
    result = assemble();
  }
  // Then drop the oldest sleep nights.
  while (result.length > coachHealthContextBudget && nights.length > 1) {
    nights = nights.sublist(1);
    result = assemble();
  }
  if (result.length > coachHealthContextBudget) {
    result = result.substring(0, coachHealthContextBudget);
  }
  return result;
}

// ── Round 55 Step 2: coach memory (device-local v1) ─────────────────────────
//
// Memory is device-local only: no synced storage exists for it
// (the sync profile is a server column whitelist and unknown keys
// are dropped), so facts live in CoachMemoryStore on this device
// and the UI says so plainly. Capture has exactly two sources:
// deterministic events this client itself performs (approved or
// dismissed proposals, below) and REMEMBER lines the model is
// instructed to emit — extracted before display and before
// persistence, so neither the rendered text nor the stored
// coach message ever contains one.

/// Extracts REMEMBER lines from a coach reply. Returns the reply
/// with EVERY standalone REMEMBER line stripped — trailing lines
/// (all of them, loop-stripped) and any standalone REMEMBER line
/// anywhere else in the reply, including a bare trailing
/// `REMEMBER:` with no fact — plus the captured fact: the last
/// fact-bearing REMEMBER line's text (null when no REMEMBER line
/// carried a fact). Round 55 fix pass (Vera): a REMEMBER line
/// must never render or persist regardless of its position.
(String, String?) extractCoachRememberLine(String reply) {
  final kept = <String>[];
  String? fact;
  for (final line in reply.split('\n')) {
    final m = RegExp(r'^REMEMBER:\s*(.*)$', caseSensitive: false)
        .firstMatch(line.trim());
    if (m != null) {
      final f = m.group(1)!.trim();
      if (f.isNotEmpty) fact = f;
      continue;
    }
    kept.add(line);
  }
  return (kept.join('\n').trim(), fact);
}

/// The memory section injected into the enriched context, newest
/// first, physically adjacent to the fresh health sections (it is
/// passed as the memoryContext of coachEnrichedUserContext, which
/// places it directly after the health block). The closing
/// instruction lets the coach note a remembered start/stop date
/// alongside the fresh values above it, exactly as recorded —
/// it must never state or imply causation (Juno, Round 55 fix).
String buildCoachMemoryContext(List<CoachMemoryFact> facts) {
  if (facts.isEmpty) return '';
  final lines = <String>[];
  // Round 55 fix pass (Vera LOW): the injected section is capped
  // at the store's fact cap even when handed a longer list.
  for (final f in facts.take(CoachMemoryStore.maxFacts)) {
    final text = coachPlainText(f.text);
    if (text.isEmpty) continue;
    final hasDatePrefix =
        RegExp(r'^\d{4}-\d{2}-\d{2}:').hasMatch(text);
    if (hasDatePrefix) {
      lines.add('- $text');
    } else if (f.createdAt > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(f.createdAt);
      lines.add('- ${_coachDateStr(d)}: $text');
    } else {
      lines.add('- $text');
    }
  }
  if (lines.isEmpty) return '';
  return 'FROM EARLIER SESSIONS (coach memory, this device):\n'
      '${lines.join('\n')}\n'
      'You may reference these facts. When a fact mentions '
      'something the user started, stopped, or is trying, you may '
      'note its date together with the related values in the '
      'fresh health data above, exactly as recorded. Do not state '
      'or imply that it caused, helped, worsened, or changed any '
      'health value, symptom, or outcome.';
}

String _coachMemoryDate(DateTime now) => _coachDateStr(now);

String _coachTruncateFact(String text) {
  final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length > 80 ? '${t.substring(0, 77)}...' : t;
}

/// The deterministic memory event for one proposal resolution —
/// written only for events this client itself performed (an
/// approval that actually saved, or a dismissal). Null for kinds
/// with nothing durable to remember.
String? coachMemoryEventForProposal(
  String kind, {
  required bool approve,
  required CoachParsedContent parsed,
  required DateTime now,
}) {
  final date = _coachMemoryDate(now);
  if (!approve) {
    final topic = switch (kind) {
      'note' => parsed.noteText,
      'file' => parsed.fileName,
      'list' => parsed.listName,
      'reminder' => parsed.reminderTitle,
      'medication' => parsed.medications.isNotEmpty
          ? parsed.medications.map((m) => m.name).join(', ')
          : null,
      'calendar' => parsed.calendarTitle,
      'calendarDelete' => parsed.calendarDeleteTitle,
      'logEntry' => parsed.logEntryText,
      'counter' => parsed.counterName,
      _ => null,
    };
    final topicText =
        (topic == null || topic.trim().isEmpty) ? '' : ' "${_coachTruncateFact(topic)}"';
    return '$date: Dismissed a $kind proposal$topicText from Coach.';
  }
  return switch (kind) {
    'note' =>
      '$date: Logged an entry from Coach: "${_coachTruncateFact(parsed.noteText ?? '')}" (approved from Coach).',
    'file' =>
      '$date: Saved the document "${_coachTruncateFact(parsed.fileName ?? '')}" to the Tabs database (approved from Coach).',
    'list' =>
      '$date: Created the list "${parsed.listName ?? ''}" with ${parsed.listItems.length} items (approved from Coach).',
    'reminder' =>
      '$date: Set a reminder "${parsed.reminderTitle ?? ''}"${parsed.reminderTime != null && parsed.reminderTime!.trim().isNotEmpty ? ' at ${parsed.reminderTime!.trim()}' : ''} (approved from Coach).',
    'medication' =>
      '$date: Added medications: ${parsed.medications.map((m) => m.name).join(', ')} (approved from Coach).',
    'logEntry' =>
      '$date: Logged an entry from Coach: "${_coachTruncateFact(parsed.logEntryText ?? '')}" (approved from Coach).',
    'counter' =>
      '$date: Created an event counter "${parsed.counterName ?? ''}" for ${parsed.counterDate ?? ''} (approved from Coach).',
    _ => null,
  };
}

/// Round 48 fix round (Vera F6) — decodes a profile blob into its
/// RAW JSON rows, preserving every row exactly as stored: non-Map
/// rows (plain strings, numbers) stay as they are, and Map rows
/// keep every key, known or not. This is the lists_screen /
/// notes_screen raw pattern (`decodeUserListsRaw` /
/// `decodeUserNotesRaw`): Coach blob appends splice into THESE
/// rows and re-encode, so untouched rows survive verbatim instead
/// of being dropped or coerced by
/// `TabsBackend.decodeProfileList` (which drops non-Map rows and
/// rewrites string rows as `{'name': …}`). Tolerates a JSON
/// string (including double-encoded), an already-decoded list, a
/// single map, and garbage (→ empty). Never throws.
List<dynamic> decodeCoachProfileBlobRaw(dynamic raw) {
  dynamic decoded = raw;
  var guard = 0;
  while (decoded is String && decoded.trim().isNotEmpty && guard < 3) {
    guard++;
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {
      return const [];
    }
  }
  if (decoded is List) return List<dynamic>.of(decoded);
  if (decoded is Map) return [decoded];
  return const [];
}

/// The string-keyed map view of one raw blob row, or null when the
/// row is not a map at all (such rows are preserved verbatim on
/// writes but carry no fields to read).
Map<String, dynamic>? coachRawRowMap(dynamic row) {
  if (row is! Map) return null;
  return <String, dynamic>{
    for (final e in row.entries) '${e.key}': e.value,
  };
}

/// The outcome of one proposal approval write: success, or a
/// failure carrying the SPECIFIC honest reason to show when one
/// is known (permission denied at the gate, a failed re-pull
/// before id math, a file that was never attached in this app).
/// A null [error] falls back to the generic save-failure message.
class CoachApprovalOutcome {
  final bool ok;
  final String? error;

  /// Round 54 — when true, a failure's [error] is appended as a
  /// coach message (and persisted), mirroring native's calendar
  /// handlers, which post their outcome messages into the chat
  /// instead of only flashing them. The proposal tag is NOT
  /// flipped either way on failure.
  final bool errorAsCoachMessage;

  /// Round 54 fix round (Juno A2) — for a successful calendar
  /// DELETE approval, how many rows the bridge actually deleted.
  /// The confirmation copy is count-aware: 1 keeps native's
  /// verbatim singular string, >1 uses the plural string. Null
  /// for every other outcome.
  final int? deletedRows;

  const CoachApprovalOutcome.success({this.deletedRows})
      : ok = true,
        error = null,
        errorAsCoachMessage = false;

  const CoachApprovalOutcome.failure([this.error])
      : ok = false,
        errorAsCoachMessage = false,
        deletedRows = null;

  /// A failure whose [error] is posted into the chat as a coach
  /// message (Round 54 calendar outcomes, native parity).
  const CoachApprovalOutcome.failureAsMessage(String message)
      : ok = false,
        error = message,
        errorAsCoachMessage = true,
        deletedRows = null;
}

/// The typed-shortcut decision native `sendMessage` makes when the
/// last message carries a PENDING proposal: returns 'approve' or
/// 'deny' when [text] is one of native's shortcut phrases for that
/// proposal kind, else null. [kind] is one of 'note', 'file',
/// 'list', 'reminder', 'medication' (native checks in that order;
/// calendar proposals have no typed shortcut).
String? coachTextShortcut(String kind, String text) {
  final lower = text.trim().toLowerCase();
  const saveApprove = {
    'approve', 'yes', 'save', 'save it', 'save that', 'please save it',
    'please save that',
  };
  const saveDeny = {
    'deny', 'no', "don't save", "don't save that", 'cancel',
    "no don't save",
  };
  switch (kind) {
    case 'note':
    case 'file':
      if (saveApprove.contains(lower)) return 'approve';
      if (saveDeny.contains(lower)) return 'deny';
      return null;
    case 'list':
      if (saveApprove.contains(lower) ||
          {'create', 'create it', 'create that'}.contains(lower)) {
        return 'approve';
      }
      if ({'deny', 'no', "don't save", "don't create", 'cancel',
              "no don't create"}
          .contains(lower)) {
        return 'deny';
      }
      return null;
    case 'reminder':
      if ({'yes', 'set it', 'set', 'create', 'add', 'sure', 'ok'}
          .contains(lower)) {
        return 'approve';
      }
      if ({'no', 'cancel', "don't", "don't set"}.contains(lower)) {
        return 'deny';
      }
      return null;
    case 'medication':
      if ({'yes', 'add', 'add it', 'approve', 'save', 'sure', 'ok'}
          .contains(lower)) {
        return 'approve';
      }
      if ({'no', 'cancel', "don't", "don't add"}.contains(lower)) {
        return 'deny';
      }
      return null;
    case 'logEntry':
      // Mirrors the note shortcuts (it is a log write, like a note).
      if (saveApprove.contains(lower)) return 'approve';
      if (saveDeny.contains(lower)) return 'deny';
      return null;
    case 'counter':
      // Mirrors the list shortcuts (it creates a named thing).
      if (saveApprove.contains(lower) ||
          {'create', 'create it', 'create that'}.contains(lower)) {
        return 'approve';
      }
      if ({'deny', 'no', "don't save", "don't create", 'cancel',
              "no don't create"}
          .contains(lower)) {
        return 'deny';
      }
      return null;
  }
  return null;
}

/// Which pending proposal kind a parsed message carries, in native
/// `sendMessage`'s check order (note → file → list → reminder →
/// medication). Null when nothing is pending.
String? pendingProposalKind(CoachParsedContent parsed) {
  if (parsed.noteStatus == CoachProposalStatus.pending &&
      parsed.noteText != null) {
    return 'note';
  }
  if (parsed.fileStatus == CoachProposalStatus.pending &&
      parsed.fileName != null) {
    return 'file';
  }
  if (parsed.listStatus == CoachProposalStatus.pending &&
      parsed.listName != null) {
    return 'list';
  }
  if (parsed.reminderStatus == CoachProposalStatus.pending &&
      parsed.reminderTitle != null) {
    return 'reminder';
  }
  if (parsed.medicationStatus == CoachProposalStatus.pending &&
      parsed.medications.isNotEmpty) {
    return 'medication';
  }
  // Round 55 kinds, checked after the native five so the native
  // priority order is unchanged.
  if (parsed.logEntryStatus == CoachProposalStatus.pending &&
      parsed.logEntryText != null) {
    return 'logEntry';
  }
  if (parsed.counterStatus == CoachProposalStatus.pending &&
      parsed.counterName != null) {
    return 'counter';
  }
  return null;
}

// ── History screen ──────────────────────────────────────────────────────────

class HealthCoachScreen extends StatefulWidget {
  final TabsBackend? backend;

  /// Injectable notification-service seam (the same one the
  /// Reminders screen uses), forwarded to the chat screen so a
  /// Coach-approved reminder runs the create permission gate and
  /// the alarm reconcile against it. Null in production.
  final ReminderNotificationService? notificationService;

  /// Injectable coach-memory store + account binding (Round 55
  /// Step 2). Null in production.
  final CoachMemoryStore? coachMemoryStore;

  /// Injectable extracted-text store (Round 65), warmed here so the
  /// chat's send path can read its mirror synchronously. Null in
  /// production.
  final KnowledgeExtractionStore? knowledgeStore;
  final String? accountEmail;
  /// Injectable calendar bridge (Round 54), forwarded to the chat
  /// screen. Null in production.
  final CalendarService? calendarService;

  /// Injectable settings store (Round 54): the source of the
  /// Google Calendar connected flag + email (native's sign-in
  /// based state). Null in production.
  final SettingsStore? settingsStore;

  const HealthCoachScreen(
      {super.key,
      this.backend,
      this.notificationService,
      this.coachMemoryStore,
      this.knowledgeStore,
      this.accountEmail,
      this.calendarService,
      this.settingsStore});

  @override
  State<HealthCoachScreen> createState() => _HealthCoachScreenState();
}

class _HealthCoachScreenState extends State<HealthCoachScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  late final CalendarService _calendar =
      widget.calendarService ?? CalendarService();
  late final SettingsStore _settingsStore =
      widget.settingsStore ?? SettingsStore();
  bool _calConnected = false;
  String _calEmail = '';

  bool? _unlocked;
  String? _gateError;
  List<CoachSessionSummary> _sessions = const [];
  Map<String, List<CoachChatMessage>> _messagesBySession = const {};
  Map<String, dynamic>? _pull;
  List<CoachMemoryFact> _memoryFacts = const [];
  String? _resolvedAccountEmail;
  bool _loading = true;
  String? _error;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _loadCalendarFlag();
    _load();
  }

  /// Round 54 — the calendar flag is on-device state (native
  /// keeps it in DataStore only). It loads on its OWN path, never
  /// blocking the history load (the R51 Connected Apps pattern);
  /// a failed read leaves it off, which is native's default and
  /// the honest state.
  Future<void> _loadCalendarFlag() async {
    try {
      final calConnected =
          await _settingsStore.getGoogleCalendarConnected();
      final calEmail = await _settingsStore.getGoogleCalendarEmail();
      if (!mounted) return;
      setState(() {
        _calConnected = calConnected;
        _calEmail = calEmail;
      });
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final pull = await _backend.fetchSyncPull();
      if (!mounted) return;
      // Round 55: unlocked = isUnlimited OR isAdmin, both strictly
      // from the sync pull (fail-closed: a failed/null pull leaves
      // _unlocked false). The server already ORs admin into
      // isUnlimited, but the client rule now matches the spec and
      // the Settings membership derivation exactly.
      final unlimited =
          pull?['isUnlimited'] == true || pull?['isAdmin'] == true;
      setState(() {
        _pull = pull;
        _unlocked = unlimited;
        _loading = false;
        if (unlimited && pull != null) {
          _sessions = parseCoachSessions(pull['coachSessions']);
          _messagesBySession = groupCoachMessages(pull['coachMessages']);
        }
        _error = (!unlimited && pull == null)
            ? 'Could not verify membership. Check your connection and try again.'
            : null;
      });
      if (unlimited) {
        try {
          _resolvedAccountEmail =
              widget.accountEmail ?? await _backend.readEmail();
        } catch (_) {
          _resolvedAccountEmail = widget.accountEmail;
        }
        try {
          final store =
              widget.coachMemoryStore ?? CoachMemoryStore.instance;
          _memoryFacts = store.cachedFacts;
          // Background warm: the tile count refreshes when the
          // disk read lands; nothing here awaits storage IO.
          unawaited(store.load(_resolvedAccountEmail).then((facts) {
            if (mounted) setState(() => _memoryFacts = facts);
          }));
        } catch (_) {}
        // Round 65: warm the extracted-text mirror the same way,
        // so a chat opened from here can include document text
        // without the send path awaiting storage IO.
        try {
          final kStore =
              widget.knowledgeStore ?? KnowledgeExtractionStore.instance;
          unawaited(kStore.load(_resolvedAccountEmail));
        } catch (_) {}
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unlocked = false;
        _gateError =
            'Could not verify membership. Check your connection and try again.';
      });
    }
  }

  Future<void> _openChat({CoachSessionSummary? session}) async {
    // Round 22 — shared slide route (was MaterialPageRoute, whose
    // Material 3 fade transition ghosted; see slide_page_route.dart).
    await Navigator.of(context).push(
      SlidePageRoute<void>(
        reducedMotion: animationsDisabled(context),
        builder: (_) => CoachChatScreen(
          backend: _backend,
          notificationService: widget.notificationService,
          coachMemoryStore: widget.coachMemoryStore,
          knowledgeStore: widget.knowledgeStore,
          accountEmail: _resolvedAccountEmail ?? widget.accountEmail,
          calendarService: _calendar,
          // Vera F4 — the tombstone read stays with the store's
          // owner (this screen); the chat resolves the set lazily
          // at approve time so it is as fresh as the push it
          // guards.
          counterTombstoneIds: () => _settingsStore
              .getDeletedCounterIds(
                  ownerEmail:
                      _resolvedAccountEmail ?? widget.accountEmail),
          calendarConnected: _calConnected,
          calendarEmail: _calEmail,
          sessionId: session?.id,
          sessionTitle: session?.title ?? 'New Chat',
          sessionCreatedAt: session?.createdAt ?? 0,
          initialMessages: session == null
              ? const []
              : (_messagesBySession[session.id] ?? const []),
          profile: (_pull?['profile'] is Map<String, dynamic>)
              ? _pull!['profile'] as Map<String, dynamic>
              : null,
          pullEntries: _pullEntries(),
          pullCategories: _pullCategories(),
          pullDocuments: KnowledgeDocumentMeta.listFromPull(_pull),
        ),
      ),
    );
    // A chat may have created or deleted a session; re-pull fresh.
    _backend.invalidateSyncPull();
    if (mounted) _load();
  }

  List<Map<String, dynamic>> _pullEntries() {
    final raw = _pull?['entries'];
    if (raw is! List) return const [];
    return [for (final e in raw) if (e is Map<String, dynamic>) e];
  }

  List<Map<String, dynamic>> _pullCategories() {
    final raw = _pull?['categories'];
    if (raw is! List) return const [];
    return [for (final c in raw) if (c is Map<String, dynamic>) c];
  }

  Widget _coachMemoryTile() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: InkWell(
        onTap: _openCoachMemory,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: NotelColors.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              const Icon(Icons.psychology_outlined,
                  color: NotelColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Coach memory',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: NotelColors.textPrimary)),
                    const SizedBox(height: 2),
                    Text(
                        _memoryFacts.isEmpty
                            ? 'Stored on this device'
                            : '${_memoryFacts.length} ${_memoryFacts.length == 1 ? 'fact' : 'facts'} stored on this device',
                        style: const TextStyle(
                            fontSize: 12,
                            color: NotelColors.textSecondary)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  size: 20, color: NotelColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openCoachMemory() async {
    await Navigator.of(context).push(
      SlidePageRoute<void>(
        reducedMotion: animationsDisabled(context),
        builder: (_) => CoachMemoryScreen(
          store: widget.coachMemoryStore ?? CoachMemoryStore.instance,
          accountEmail: _resolvedAccountEmail ?? widget.accountEmail,
          initialFacts: _memoryFacts,
        ),
      ),
    );
    try {
      final store = widget.coachMemoryStore ?? CoachMemoryStore.instance;
      unawaited(store
          .load(_resolvedAccountEmail ?? widget.accountEmail)
          .then((facts) {
        if (mounted) setState(() => _memoryFacts = facts);
      }));
    } catch (_) {}
  }

  /// Native `CoachHistoryViewModel.deleteSession`: local removal +
  /// `DELETE api/sync/coach_sessions/{id}`. The row only leaves the
  /// list when the server delete succeeds — no phantom state.
  Future<void> _deleteSession(CoachSessionSummary session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Delete Chat',
            style: TextStyle(color: NotelColors.textPrimary)),
        content: Text('Delete "${session.title}"? This cannot be undone.',
            style: const TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete',
                style: TextStyle(
                    color: NotelColors.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await _backend.deleteCoachSession(session.id);
    if (!mounted) return;
    if (ok) {
      _backend.invalidateSyncPull();
      setState(() {
        _sessions = [
          for (final s in _sessions)
            if (s.id != session.id) s,
        ];
        _actionError = null;
      });
    } else {
      setState(() {
        _actionError =
            'Could not delete that chat. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textPrimary, semanticLabel: 'Back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Tabs Coach History',
          style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
      ),
      floatingActionButton: _unlocked == true
          ? Padding(
              padding: const EdgeInsets.only(bottom: 72),
              child: FloatingActionButton(
                onPressed: () => _openChat(),
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white,
                tooltip: 'New Chat',
                child: const Icon(Icons.add),
              ),
            )
          : null,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const SkeletonGroup(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 110),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(height: 72, radius: 16),
              SizedBox(height: 16),
              SkeletonBox(height: 72, radius: 16),
              SizedBox(height: 16),
              SkeletonBox(height: 72, radius: 16),
            ],
          ),
        ),
      );
    }
    if (_unlocked == false) {
      return _LockedCoachView(
        message: _gateError ??
            _error ??
            'Health Coach requires a Tabs membership. '
                'Upgrade in the native app to unlock it.',
      );
    }
    if (_sessions.isEmpty) {
      return Column(
        children: [
          _coachMemoryTile(),
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CoachMascotFigure(
                        height: 96, semanticLabel: '$kCoachName, Tabs Coach'),
                    SizedBox(height: 16),
                    Text('No chats yet.',
                        style: TextStyle(
                            fontSize: 16,
                            color: NotelColors.textSecondary)),
                    SizedBox(height: 4),
                    Text('Tap the + button to start a conversation with '
                        '$kCoachName.',
                        style: TextStyle(
                            fontSize: 14,
                            color: NotelColors.textSecondary)),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        _coachMemoryTile(),
        if (_actionError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: NotelColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: NotelColors.error.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_actionError!,
                        style: const TextStyle(
                            fontSize: 13, color: NotelColors.textPrimary)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 18, color: NotelColors.textSecondary),
                    onPressed: () => setState(() => _actionError = null),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
            itemCount: _sessions.length,
            separatorBuilder: (context, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final session = _sessions[i];
              return InkWell(
                onTap: () => _openChat(session: session),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: NotelColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(session.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: NotelColors.textPrimary)),
                            const SizedBox(height: 4),
                            Text(formatCoachDate(session.updatedAt),
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: NotelColors.textSecondary)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: NotelColors.error,
                            semanticLabel: 'Delete Chat'),
                        onPressed: () => _deleteSession(session),
                      ),
                      const Icon(Icons.chevron_right,
                          size: 20, color: NotelColors.textSecondary),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Round 55 Step 2 — the Coach memory control screen: every stored
/// fact, per-item delete, and Clear all, with the honest device-local
/// line. Reached from the Coach History screen's Coach memory entry.
class CoachMemoryScreen extends StatefulWidget {
  final CoachMemoryStore store;
  final String? accountEmail;
  final List<CoachMemoryFact> initialFacts;

  const CoachMemoryScreen({
    super.key,
    required this.store,
    this.accountEmail,
    this.initialFacts = const [],
  });

  @override
  State<CoachMemoryScreen> createState() => _CoachMemoryScreenState();
}

class _CoachMemoryScreenState extends State<CoachMemoryScreen> {
  late List<CoachMemoryFact> _facts;

  @override
  void initState() {
    super.initState();
    _facts = List.of(widget.initialFacts);
    _reload();
  }

  Future<void> _reload() async {
    final facts = await widget.store.load(widget.accountEmail);
    if (mounted) setState(() => _facts = facts);
  }

  Future<void> _deleteAt(int index) async {
    final facts = await widget.store.deleteAt(index, widget.accountEmail);
    if (mounted) setState(() => _facts = facts);
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Clear coach memory',
            style: TextStyle(color: NotelColors.textPrimary)),
        content: const Text(
            'Delete every fact the coach has remembered on this device? This cannot be undone.',
            style: TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear all',
                style: TextStyle(
                    color: NotelColors.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.clearAll(widget.accountEmail);
    if (mounted) setState(() => _facts = const []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textPrimary, semanticLabel: 'Back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Coach memory',
          style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary),
        ),
        actions: [
          if (_facts.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: const Text('Clear all',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: NotelColors.error)),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Coach memory is stored on this device. It is not synced to your other devices.',
              style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: NotelColors.textSecondary),
            ),
          ),
          Expanded(
            child: _facts.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.psychology_outlined,
                              size: 64,
                              color: NotelColors.textSecondary),
                          SizedBox(height: 16),
                          Text('No coach memory yet.',
                              style: TextStyle(
                                  fontSize: 16,
                                  color: NotelColors.textSecondary)),
                          SizedBox(height: 4),
                          Text(
                              'Facts the coach remembers from your '
                              'chats and approved actions will appear '
                              'here.',
                              style: TextStyle(
                                  fontSize: 14,
                                  color: NotelColors.textSecondary),
                              textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _facts.length,
                    separatorBuilder: (context, _) =>
                        const SizedBox(height: 12),
                    itemBuilder: (context, i) {
                      final fact = _facts[i];
                      final dateLabel = fact.createdAt > 0
                          ? formatCoachDate(fact.createdAt)
                          : '';
                      // Round 55 fix pass (Mira S12): a leading
                      // yyyy-MM-dd: prefix is display noise (the
                      // date already renders below) — stripped
                      // here only; the stored text and the context
                      // builder keep it.
                      final displayText = fact.text.replaceFirst(
                          RegExp(r'^\d{4}-\d{2}-\d{2}:\s*'), '');
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: NotelColors.surface,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(displayText,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.normal,
                                          height: 1.4,
                                          color:
                                              NotelColors.textPrimary)),
                                  if (dateLabel.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(dateLabel,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: NotelColors
                                                .textSecondary)),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18,
                                  color: NotelColors.error,
                                  semanticLabel: 'Delete memory'),
                              onPressed: () => _deleteAt(i),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LockedCoachView extends StatelessWidget {
  final String message;

  const _LockedCoachView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: NotelColors.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: NotelColors.cardBorder),
              ),
              child: const Icon(Icons.lock_outline,
                  size: 44, color: NotelColors.textSecondary),
            ),
            const SizedBox(height: 24),
            const Text(
              'Health Coach is locked',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(
                  fontSize: 14, height: 1.5, color: NotelColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Chat screen ─────────────────────────────────────────────────────────────

class CoachChatScreen extends StatefulWidget {
  final TabsBackend? backend;

  /// Injectable notification-service seam (the same one the
  /// Reminders screen uses): a Coach-approved reminder runs the
  /// shared create permission gate and the alarm reconcile
  /// against this service. Null in production (the local
  /// notifications service is used).
  final ReminderNotificationService? notificationService;

  /// Injectable Health Connect seam for the Round 55 context loader.
  /// Null in production (a default [HealthConnectService] is used).
  final HealthConnectService? healthConnectService;

  /// R70 WS2 — injectable union reader (store ∪ fresh HC) for the
  /// context loader's historical numbers. Null in production
  /// (built from [healthConnectService]).
  final HealthHistoryQueries? historyQueries;

  /// Injectable coach-memory store (Round 55 Step 2). Null in
  /// production (the shared device-local instance is used).
  final CoachMemoryStore? coachMemoryStore;

  /// Injectable extracted-text store (Round 65). Null in
  /// production (the shared device-local instance is used).
  final KnowledgeExtractionStore? knowledgeStore;

  /// Knowledge documents from the pull (Round 65), newest first —
  /// their cached extracted texts join the coach context.
  final List<KnowledgeDocumentMeta> pullDocuments;

  /// The account email the memory store is bound to. Null resolves
  /// from the stored session at first use.
  final String? accountEmail;
  /// Injectable calendar bridge (Round 54). Null in production.
  final CalendarService? calendarService;

  /// Injectable counter-tombstone resolver (correction round,
  /// Vera F4): returns the account's locally persisted
  /// deleted-counter ids (SettingsStore, owned by the parent
  /// screen, which holds the store seam — the same value/seam
  /// pattern as calendarConnected / calendarEmail). The counter
  /// approval calls it at approve time and filters its spliced
  /// rows through the set before pushing. Null resolves to the
  /// empty set.
  final Future<Set<String>> Function()? counterTombstoneIds;

  /// Native's sign-in-based Google Calendar flag (SettingsStore).
  /// False (the default) keeps Round 48's not-connected treatment
  /// exactly; true enables the connected prompt branch, live
  /// upcoming-events context, and calendar approvals.
  final bool calendarConnected;

  /// The connected calendar account email (SettingsStore), passed
  /// to the bridge so its insert selection can prefer the calendar
  /// owned by this account, exactly like native.
  final String calendarEmail;

  final String? sessionId;
  final String sessionTitle;
  final int sessionCreatedAt;
  final List<CoachChatMessage> initialMessages;
  final Map<String, dynamic>? profile;
  final List<Map<String, dynamic>> pullEntries;
  final List<Map<String, dynamic>> pullCategories;

  const CoachChatScreen({
    super.key,
    this.backend,
    this.notificationService,
    this.healthConnectService,
    this.historyQueries,
    this.coachMemoryStore,
    this.knowledgeStore,
    this.accountEmail,
    this.calendarService,
    this.counterTombstoneIds,
    this.calendarConnected = false,
    this.calendarEmail = '',
    this.sessionId,
    this.sessionTitle = 'New Chat',
    this.sessionCreatedAt = 0,
    this.initialMessages = const [],
    this.profile,
    this.pullEntries = const [],
    this.pullCategories = const [],
    this.pullDocuments = const [],
  });

  @override
  State<CoachChatScreen> createState() => _CoachChatScreenState();
}

class _CoachChatScreenState extends State<CoachChatScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();

  late final ReminderNotificationService _notifs;
  late final CalendarService _calendar;

  late final String _sessionId;
  late String _title;
  late int _createdAt;
  late bool _sessionPersisted;
  late List<CoachChatMessage> _messages;
  CoachChatMessage? _welcomeMessage;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Measures the first message's sender-label row so
  /// [_scrollToBottom] can tell whether scrolling to the end would
  /// slice that row at the viewport's top edge (see there).
  final GlobalKey _firstLabelKey = GlobalKey();
  bool _sending = false;
  bool _actionBusy = false;

  // Round 55 Step 1: the health block + body-load history are
  // assembled ONCE per chat session and cached here; a new session
  // (a new screen state) assembles fresh. Every source inside the
  // loader is failure-tolerant, so a failed source simply omits
  // its section and never blocks a send.
  String? _cachedHealthContext;
  String? _cachedBodyLoadHistory;
  String _cachedMemoryContext = '';
  String? _resolvedAccountEmail;

  CoachMemoryStore get _memoryStore =>
      widget.coachMemoryStore ?? CoachMemoryStore.instance;

  Future<String?> _accountEmail() async {
    if (_resolvedAccountEmail != null) return _resolvedAccountEmail;
    if (widget.accountEmail != null) {
      _resolvedAccountEmail = widget.accountEmail;
      return _resolvedAccountEmail;
    }
    try {
      _resolvedAccountEmail = await _backend.readEmail();
    } catch (_) {
      _resolvedAccountEmail = null;
    }
    return _resolvedAccountEmail;
  }

  /// Captures one memory fact (both Round 55 sources funnel here)
  /// and refreshes the injected memory section for later sends in
  /// this session. The record itself is a synchronous mirror update
  /// with background persistence — memory must never break or delay
  /// a chat or an approval, so no storage IO is awaited here.
  Future<void> _captureMemory(String text, String source) async {
    try {
      final email = await _accountEmail();
      final facts = _memoryStore.recordFact(
        text: text,
        source: source,
        email: email,
      );
      _cachedMemoryContext = buildCoachMemoryContext(facts);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _notifs =
        widget.notificationService ?? LocalReminderNotificationService();
    _calendar = widget.calendarService ?? CalendarService();
    _sessionId = widget.sessionId ?? newUuid();
    _title = widget.sessionTitle;
    _createdAt = widget.sessionCreatedAt;
    _sessionPersisted = widget.sessionId != null;
    _messages = List.of(widget.initialMessages);
    if (widget.sessionId == null) {
      // Native's new-session greeting (inserted into the session on
      // creation, i.e. at the first send). It only SEEDS the visible
      // history when the caller provided none — provided
      // initialMessages are the history and must render (the
      // pre-Round-48 constructor contract).
      _welcomeMessage = CoachChatMessage(
        id: newUuid(),
        sessionId: _sessionId,
        role: 'coach',
        content: coachWelcomeMessage,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      if (_messages.isEmpty) {
        _messages = [_welcomeMessage!];
      }
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final maxExtent = _scroll.position.maxScrollExtent;
      var target = maxExtent;
      // Clipped first sender label (founder report, VC 100103): when
      // the thread only BARELY overflows the viewport (greeting + one
      // short question + one long answer), scrolling to the absolute
      // bottom can strand the first message's sender-label row
      // ('Bandit · Tabs Coach' + avatar) sliced in half at the
      // viewport's top edge, flush under the disclaimer banner. The
      // label row sits at the very top of the first item: in content
      // coordinates it spans the list's top padding (8, in the
      // ListView below) to 8 + its height. A scroll offset inside
      // that span cuts the row; at or below 8 the row is fully
      // visible, and past the span it has fully scrolled away (the
      // bubble body straddling the edge is normal chat behavior).
      // So only when maxScrollExtent itself falls inside the span —
      // a window one label-row tall — stay top-anchored at 0 instead
      // of slicing the row. Every other case, including the
      // post-approval flows that append a confirmation message a
      // screenful down, still lands at the latest message exactly
      // as before.
      final labelHeight = _firstLabelKey.currentContext?.size?.height;
      if (labelHeight != null &&
          maxExtent > 8 &&
          maxExtent < 8 + labelHeight) {
        target = 0;
      }
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<bool> _persistSession(int updatedAt) {
    return _backend.syncCoachSessions([
      {
        'id': _sessionId,
        'title': _title,
        'createdAt': _createdAt,
        'updatedAt': updatedAt,
      },
    ]);
  }

  Future<bool> _persistMessages(List<CoachChatMessage> messages) {
    if (messages.isEmpty) return Future.value(true);
    return _backend
        .syncCoachMessages([for (final m in messages) m.toJson()]);
  }

  void _notifySyncFailure() {
    _snack('Could not save this chat to your account. Check your '
        'connection — it may not appear on your other devices.');
  }

  /// Guarded Health Connect read (the Sleep/Key Metrics pattern):
  /// a timeout or throw becomes null, never a blocked send.
  Future<T?> _coachGuarded<T>(Future<T> Function() call) async {
    try {
      return await call().timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }

  Future<CoachHealthSnapshot> _loadCoachHealthSnapshot() async {
    try {
      final hc = widget.healthConnectService ?? HealthConnectService();
      final now = DateTime.now();
      final todayStr = _coachDateStr(now);
      List<({String date, int mins})> sleepNights = const [];
      int? sleepDebt;
      int? restingLatest;
      String? restingDate;
      double? restingAvg;
      int? daytimeHr;
      double? hrv;
      int? spikesTotal;
      int? spikesToday;
      var bpRecords = <BpRecord>[];
      final connected = await _coachGuarded(() => hc.isConnected()) ?? false;
      if (connected) {
        // R70 WS2 — the historical numbers come from the union
        // (store ∪ fresh HC): same context format, deeper data.
        // The sleep map spans 28 days so the debt computation
        // (which itself takes the last 10 nights with data, the
        // existing definition) and the context assembler (last 7
        // nights) both see their full windows even when HC's own
        // retention has thinned; resting HR / spikes keep their
        // exact 7-day windows, so their definitions do not move.
        final queries = widget.historyQueries ??
            HealthHistoryQueries(hc: hc);
        final sleepUnion = await _coachGuarded(() =>
            queries.loadDays(28, metrics: {HistoryMetric.sleep}));
        final sleepMap = sleepUnion?.sleepMinutes ?? const <String, int>{};
        sleepNights = [
          for (final e in sleepMap.entries) (date: e.key, mins: e.value),
        ];
        final debt = sleepDebtMinsOrNull(sleepMap, todayStr);
        if (debt != null && debt < 0) sleepDebt = -debt;
        final hrUnion = await _coachGuarded(() => queries.loadDays(7,
            metrics: {HistoryMetric.restingHr, HistoryMetric.spikes}));
        final restingMap = hrUnion?.restingHr ?? const <String, int>{};
        final restingDates = restingMap.keys.toList()..sort();
        if (restingDates.isNotEmpty) {
          restingLatest = restingMap[restingDates.last];
          restingDate = restingDates.last;
          restingAvg = restingMap.values.fold<int>(0, (a, b) => a + b) /
              restingMap.length;
        }
        final samples =
            await _coachGuarded(() => hc.readHeartRateSamples(todayStr)) ??
                const <HrSample>[];
        daytimeHr = daytimeHeartRateAvg(samples);
        for (var i = 0; i < 7 && hrv == null; i++) {
          final d = _coachDateStr(now.subtract(Duration(days: i)));
          final v = await _coachGuarded(() => hc.readHrvRmssd(d));
          if (v != null && v > 0) hrv = v;
        }
        final spikeMap = hrUnion?.spikes ?? const <String, int>{};
        if (spikeMap.isNotEmpty) {
          spikesTotal = spikeMap.values.fold<int>(0, (a, b) => a + b);
          spikesToday = spikeMap[todayStr];
        }
        bpRecords = [
          ...?await _coachGuarded(() => hc.readBloodPressure(7)),
        ];
      }
      try {
        final manual = await _backend.fetchManualBpLogs();
        bpRecords = [...bpRecords, ...manual];
      } catch (_) {}
      bpRecords = bpRecords
          .where((r) => r.systolic > 0 && r.diastolic > 0)
          .toList();
      BpRecord? latestBp;
      ({int sys, int dia})? bpAvg;
      if (bpRecords.isNotEmpty) {
        latestBp = bpRecords.reduce(
            (a, b) => a.timeEpochMs >= b.timeEpochMs ? a : b);
        final cutoff =
            now.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
        final recent =
            bpRecords.where((r) => r.timeEpochMs >= cutoff).toList();
        if (recent.isNotEmpty) {
          bpAvg = (
            sys: (recent.fold<int>(0, (a, r) => a + r.systolic) /
                    recent.length)
                .round(),
            dia: (recent.fold<int>(0, (a, r) => a + r.diastolic) /
                    recent.length)
                .round(),
          );
        }
      }
      var habitRows = const <({String name, int streak})>[];
      try {
        final habits = await _backend.fetchHabitsOrNull();
        if (habits != null) {
          habitRows = [
            for (final h in habits)
              if (h.title.trim().isNotEmpty)
                (name: h.title, streak: habitStreak(h.logs)),
          ];
        }
      } catch (_) {}
      // Weather is intentionally omitted in Round 55: the weather
      // client's 5-minute cache is per-instance (Home constructs a
      // fresh client per call), so there is no shared cached entry
      // for the coach to reuse without a new network fetch on the
      // send path. See the Round 55 report.
      return CoachHealthSnapshot(
        sleepNights: sleepNights,
        sleepDebtMins: sleepDebt,
        restingLatestBpm: restingLatest,
        restingLatestDate: restingDate,
        restingAvg7Bpm: restingAvg,
        daytimeHrTodayBpm: daytimeHr,
        hrvLatestMs: hrv,
        spikesLast7Total: spikesTotal,
        spikesToday: spikesToday,
        habits: habitRows,
        latestBp: latestBp,
        bpAvg7: bpAvg,
      );
    } catch (_) {
      return const CoachHealthSnapshot();
    }
  }

  Future<void> _ensureCoachContext() async {
    if (_cachedHealthContext != null) return;
    CoachHealthSnapshot snapshot;
    try {
      snapshot = await _loadCoachHealthSnapshot();
    } catch (_) {
      snapshot = const CoachHealthSnapshot();
    }
    // Round 65: the extracted document texts join through the
    // SAME R55 assembler (lowest-priority section — see
    // buildCoachHealthContext), never a second path. The store is
    // owner-bound; a load failure simply omits the section. The
    // top-level knowledgeBase request field stays exactly native
    // (the profile facts string, CoachViewModel.kt:1418).
    var knowledgeDocsText = '';
    try {
      final store = widget.knowledgeStore ?? KnowledgeExtractionStore.instance;
      final email = await _accountEmail();
      // Synchronous owner-gated mirror ONLY — the send path never
      // awaits storage IO (the CoachMemoryStore contract, R55).
      // The mirror is warmed by the History screen's load before
      // any chat opens and by Settings' loads.
      knowledgeDocsText =
          store.joinedCachedTextsFor(email, widget.pullDocuments);
      unawaited(store.load(email));
    } catch (_) {
      knowledgeDocsText = '';
    }
    _cachedHealthContext = buildCoachHealthContext(
      profile: widget.profile,
      entries: widget.pullEntries,
      categories: widget.pullCategories,
      health: snapshot,
      knowledgeDocumentsText: knowledgeDocsText,
      now: DateTime.now(),
    );
    _cachedBodyLoadHistory = buildCoachBodyLoadHistory(
      widget.pullEntries,
      widget.pullCategories,
      now: DateTime.now(),
    );
    // Memory: Round 55 fix pass (Vera) — the memory context is
    // built ONLY from owner-verified facts for this account: the
    // owner-gated cachedFactsFor(email) (Vera's sanctioned
    // alternative to awaiting load here — the send path must
    // never await disk IO, per the store's contract, since a
    // wedged storage channel would hang the chat). The mirror is
    // warmed by the History screen's load before any chat opens
    // and by recordFact in-session; a background load also
    // refreshes the section for later sends. The unguarded
    // cachedFacts are never read here, so one account's facts
    // can never be injected into another's chat.
    try {
      final email = await _accountEmail();
      _cachedMemoryContext =
          buildCoachMemoryContext(_memoryStore.cachedFactsFor(email));
      unawaited(_memoryStore.load(email).then((facts) {
        _cachedMemoryContext = buildCoachMemoryContext(facts);
      }));
    } catch (_) {
      _cachedMemoryContext = '';
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _actionBusy) return;

    // Native sendMessage: a typed approve/deny shortcut against the
    // last message's PENDING proposal resolves it without posting
    // the text as a chat message.
    final lastReal = _messages.lastWhere(
      (m) => m.role != 'error' && m.content.isNotEmpty,
      orElse: () => const CoachChatMessage(
          id: '', sessionId: '', role: '', content: '', timestamp: 0),
    );
    if (lastReal.id.isNotEmpty && lastReal.role == 'coach') {
      final kind = pendingProposalKind(lastReal.parsed);
      if (kind != null) {
        final shortcut = coachTextShortcut(kind, text);
        if (shortcut != null) {
          setState(() => _input.clear());
          await _resolveProposal(lastReal, kind,
              approve: shortcut == 'approve');
          return;
        }
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final userMsg = CoachChatMessage(
      id: newUuid(),
      sessionId: _sessionId,
      role: 'user',
      content: text,
      timestamp: now,
    );
    setState(() {
      _sending = true;
      _input.clear();
      _messages = [
        ..._messages,
        userMsg,
        CoachChatMessage(
          id: 'loading-$now',
          sessionId: _sessionId,
          role: 'coach',
          content: '',
          timestamp: now,
        ),
      ];
    });
    _scrollToBottom();

    // Persist the session + user message first, like native's local
    // insert (server is this app's store, so failures are surfaced).
    var persistFailed = false;
    if (!_sessionPersisted) {
      _createdAt = now;
      final sessionOk = await _persistSession(now);
      // Persist the full visible history (the seeded welcome for a
      // fresh session; the caller-provided messages when the chat was
      // opened with history) plus the new user message — never just
      // [welcome, userMsg], which would drop provided history from
      // the stored session. The loading bubble is excluded.
      final msgsOk = await _persistMessages([
        for (final m in _messages)
          if (!m.id.startsWith('loading-')) m,
      ]);
      persistFailed = !(sessionOk && msgsOk);
      if (sessionOk && msgsOk) {
        _sessionPersisted = true;
        // Native asks the AI for a session title in the background.
        _generateTitle(text);
      }
    } else {
      persistFailed = !(await _persistMessages([userMsg]));
    }
    if (persistFailed) _notifySyncFailure();

    // CoachRequest body, matching JotApi.kt: messages, userContext
    // (native-enriched with the action-proposal instructions),
    // knowledgeBase, recentEntries (last 10 entry DTOs).
    final history = _messages
        .where((m) => m.role == 'user' || m.role == 'coach')
        .where((m) => m.content.isNotEmpty)
        .map((m) => m.toJson())
        .toList();
    final kb = '${widget.profile?['knowledgeBase'] ?? ''}'.trim();
    await _ensureCoachContext();
    // Round 54 — native computes the upcoming-events context on
    // every send (CoachViewModel.kt:1363). Connected: the live
    // bridge read, formatted exactly like native; a bridge failure
    // mirrors native's outer catch ("Calendar events are
    // unavailable right now."). Not connected: native's own
    // not-connected return (unused by the not-connected branch).
    // Takeover disclosures (audit P4): the read is permission-aware
    // via [CalendarService.upcomingEventsContext] — when calendar
    // read permission is not granted the context is the unavailable
    // string, NEVER "No events found." (that string now means a
    // successful read that genuinely returned zero events).
    var calendarEventsContext = coachCalendarNotConnectedContext;
    if (widget.calendarConnected) {
      calendarEventsContext = await _calendar.upcomingEventsContext();
    }
    final body = {
      'messages': history,
      'userContext': coachEnrichedUserContext(
        widget.profile?['userContext']?.toString(),
        now: DateTime.now(),
        healthContext: _cachedHealthContext ?? '',
        memoryContext: _cachedMemoryContext,
        calendarConnected: widget.calendarConnected,
        calendarEventsContext: calendarEventsContext,
      ),
      'knowledgeBase': kb.isEmpty ? null : kb,
      'bodyLoadHistory': _cachedBodyLoadHistory ?? '',
      'recentEntries': [
        for (final e in widget.pullEntries.take(10))
          {
            'id': e['id'] ?? 0,
            'categoryId': e['categoryId'] ?? 0,
            'body': '${e['body'] ?? ''}',
            'chips': '${e['chips'] ?? ''}',
            'manualText': '${e['manualText'] ?? ''}',
            'timestamp': e['timestamp'] ?? 0,
          },
      ],
    };

    final res = await _backend.postAi('/api/ai/coach', body);
    if (!mounted) return;
    final reply = res?['result'];
    final withoutLoading = _messages
        .where((m) => !(m.role == 'coach' && m.content.isEmpty))
        .toList();
    if (reply is String && reply.trim().isNotEmpty) {
      // Round 55 Step 2: a trailing REMEMBER line is extracted
      // BEFORE the message is displayed or persisted, so neither
      // the rendered text nor the stored message contains it.
      final (cleanReply, rememberedFact) = extractCoachRememberLine(reply);
      if (rememberedFact != null) {
        await _captureMemory(rememberedFact, 'coach');
      }
      if (cleanReply.isEmpty) {
        // The reply was ONLY a memory line: there is no visible
        // coach text to show or store. The fact is captured above;
        // nothing is fabricated in its place.
        setState(() {
          _sending = false;
          _messages = withoutLoading;
        });
        _scrollToBottom();
        return;
      }
      final coachMsg = CoachChatMessage(
        id: newUuid(),
        sessionId: _sessionId,
        role: 'coach',
        content: cleanReply,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      setState(() {
        _sending = false;
        _messages = [...withoutLoading, coachMsg];
      });
      final bumped = await _persistSession(coachMsg.timestamp);
      final msgsOk = await _persistMessages([coachMsg]);
      if (!(bumped && msgsOk)) _notifySyncFailure();
    } else {
      // Visible error — never a fabricated reply. The error bubble
      // is local-only and is never persisted.
      setState(() {
        _sending = false;
        _messages = [
          ...withoutLoading,
          CoachChatMessage(
            id: newUuid(),
            sessionId: _sessionId,
            role: 'error',
            content:
                'The coach could not reply right now. Check your connection and try again.',
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
      });
    }
    _scrollToBottom();
  }

  /// Native background title generation: POST /api/ai/coach/title,
  /// falling back to "Chat" exactly like native.
  Future<void> _generateTitle(String firstMessage) async {
    try {
      final title = await _backend.fetchCoachTitle(firstMessage);
      if (!mounted) return;
      final resolved = title ?? 'Chat';
      if (resolved == _title) return;
      setState(() => _title = resolved);
      await _persistSession(DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // Title is cosmetic; native swallows failures the same way.
    }
  }

  Future<void> _deleteCurrentSession() async {
    final ok = await _backend.deleteCoachSession(_sessionId);
    if (!mounted) return;
    if (ok) {
      _backend.invalidateSyncPull();
      Navigator.of(context).pop();
    } else {
      _snack('Could not delete this chat. Check your connection and '
          'try again.');
    }
  }

  // ── Proposal resolution ─────────────────────────────────────────────────

  static const _tagKindByKind = {
    'note': 'NOTE',
    'file': 'FILE',
    'list': 'LIST',
    'reminder': 'REMINDER',
    'medication': 'MEDICATION',
    'logEntry': 'LOG_ENTRY',
    'counter': 'COUNTER',
    'calendar': 'CALENDAR_EVENT',
    'calendarDelete': 'DELETE_CALENDAR_EVENT',
  };

  /// Approves or denies the [kind] proposal on [message], mirroring
  /// native's handlers: the underlying write happens FIRST (on
  /// approve); only on success is the stored tag flipped to
  /// APPROVED_*/DENIED_* and native's confirmation message appended
  /// and persisted. A failed write leaves the proposal pending and
  /// shows a visible error — no phantom state.
  Future<void> _resolveProposal(
    CoachChatMessage message,
    String kind, {
    required bool approve,
  }) async {
    if (_actionBusy) return;
    final parsed = message.parsed;

    if (approve &&
        (kind == 'calendar' || kind == 'calendarDelete') &&
        !widget.calendarConnected) {
      // Not connected: a calendar write cannot be performed or
      // faked. The card itself already states this limitation and
      // disables its approve control (Juno F1); this guard is the
      // backstop for any other entry into the resolution path.
      // The proposal stays pending (denying still works).
      _snack(coachCalendarUnavailableMessage);
      return;
    }

    setState(() => _actionBusy = true);
    try {
      String? confirmation;
      if (approve) {
        // Round 54 — native's ask moment: calendar approvals first
        // re-check READ+WRITE permission (CoachScreen.kt:193-230).
        // Missing permission runs the disclosure-then-request gate;
        // denial leaves the proposal pending with native's message
        // and performs zero writes.
        if (kind == 'calendar' || kind == 'calendarDelete') {
          bool granted;
          try {
            granted = await _runCalendarPermissionGate();
          } on CalendarException catch (e) {
            _snack('$coachCalendarPermissionDeniedMessage '
                '[${e.code}]');
            return;
          } catch (_) {
            _snack(coachCalendarPermissionDeniedMessage);
            return;
          }
          if (!granted) {
            _snack(coachCalendarPermissionDeniedMessage);
            return;
          }
          if (!mounted) return;
        }
        final outcome = switch (kind) {
          'note' => await _approveNote(parsed.noteText!),
          'file' => await _approveFile(parsed.fileName!),
          'list' => await _approveList(parsed),
          'reminder' => await _approveReminder(parsed),
          'medication' => await _approveMedications(parsed.medications),
          'logEntry' => await _approveLogEntry(parsed),
          'counter' => await _approveCounter(parsed),
          'calendar' => await _approveCalendarEvent(parsed),
          'calendarDelete' => await _approveCalendarDelete(parsed),
          _ => const CoachApprovalOutcome.failure(),
        };
        if (!outcome.ok) {
          // Round 54 — native's calendar handlers post their
          // failure messages INTO the chat (the proposal stays
          // pending and nothing is flipped); mirror that for
          // calendar outcomes flagged errorAsCoachMessage.
          if (outcome.errorAsCoachMessage && outcome.error != null) {
            final errMsg = CoachChatMessage(
              id: newUuid(),
              sessionId: _sessionId,
              role: 'coach',
              content: outcome.error!,
              timestamp: DateTime.now().millisecondsSinceEpoch,
            );
            if (!mounted) return;
            setState(() => _messages = [..._messages, errMsg]);
            _scrollToBottom();
            if (!await _persistMessages([errMsg])) {
              _notifySyncFailure();
            }
            return;
          }
          // A specific honest reason wins (permission denied,
          // failed re-pull, file never attached here); only a
          // genuine save failure gets the generic message.
          _snack(outcome.error ??
              'Could not save that. Check your connection and '
                  'try again.');
          return;
        }
        confirmation = switch (kind) {
          'note' => "Great! I've saved that note to your history.",
          'file' =>
            "Great! I've saved to your Tabs database. You can view it anytime in the Knowledge Extraction settings.",
          'list' =>
            'Awesome! I\'ve created the list "${parsed.listName}" with ${parsed.listItems.length} items.',
          'reminder' =>
            'Done! I\'ve set a reminder for "${parsed.reminderTitle}"${_reminderTimeLabel(parsed.reminderTime)}.',
          'medication' =>
            'Added medications: ${_medicationSummary(parsed.medications)}.',
          'logEntry' =>
            'Great! I\'ve logged that entry${parsed.logEntryCategory != null ? ' in ${parsed.logEntryCategory}' : ''}.',
          'counter' =>
            'Done! I\'ve created the event counter "${parsed.counterName}".',
          'calendar' => coachCalendarAddedConfirmation(
              parsed.calendarTitle!,
              parsed.calendarDate,
              parsed.calendarTime),
          'calendarDelete' => (outcome.deletedRows ?? 1) > 1
              ? coachCalendarDeletedPluralConfirmation(
                  outcome.deletedRows!,
                  parsed.calendarDeleteTitle!,
                  parsed.calendarDeleteDate)
              : coachCalendarDeletedConfirmation(
                  parsed.calendarDeleteTitle!,
                  parsed.calendarDeleteDate),
          _ => null,
        };
      } else {
        confirmation = switch (kind) {
          'note' => "Okay, I won't save that note.",
          'file' => "Okay, I won't save that file to the database.",
          'list' => "Okay, I won't create that list.",
          'reminder' => "Okay, I won't set that reminder.",
          'logEntry' => "Okay, I won't log that entry.",
          'counter' => "Okay, I won't create that counter.",
          'calendar' => "Okay, I won't add that to your calendar.",
          'calendarDelete' => "Okay, I won't delete that event.",
          // Native's medication deny inserts no confirmation.
          _ => null,
        };
      }

      final updated = message.copyWith(
        content: rewriteProposalTag(
          extractCoachRememberLine(message.content).$1,
          _tagKindByKind[kind]!,
          approve ? 'APPROVED' : 'DENIED',
        ),
      );
      final toPersist = <CoachChatMessage>[updated];
      CoachChatMessage? confirmationMsg;
      if (confirmation != null) {
        confirmationMsg = CoachChatMessage(
          id: newUuid(),
          sessionId: _sessionId,
          role: 'coach',
          content: confirmation,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        toPersist.add(confirmationMsg);
      }
      if (!mounted) return;
      setState(() {
        _messages = [
          for (final m in _messages)
            if (m.id == message.id) updated else m,
          ?confirmationMsg,
        ];
      });
      _scrollToBottom();
      final persisted = await _persistMessages(toPersist);
      if (!persisted) _notifySyncFailure();
      // Round 55 Step 2: deterministic memory capture — only for a
      // resolution this client actually performed (an approval
      // reaches here only after its write succeeded; a dismissal
      // always reaches here).
      final memoryEvent = coachMemoryEventForProposal(
        kind,
        approve: approve,
        parsed: parsed,
        now: DateTime.now(),
      );
      if (memoryEvent != null) {
        await _captureMemory(memoryEvent, 'coach-action');
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  String _reminderTimeLabel(String? timeStr) {
    if (timeStr == null || timeStr.trim().isEmpty) return '';
    final parts = timeStr.split(':');
    final hour = parts.isNotEmpty ? int.tryParse(parts[0].trim()) : null;
    final minute = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
    if (hour == null || minute == null) return ' at $timeStr';
    final amPm = hour < 12 ? 'AM' : 'PM';
    final h12 = hour % 12 == 0 ? 12 : hour % 12;
    return ' at $h12:${minute.toString().padLeft(2, '0')} $amPm';
  }

  String _medicationSummary(List<CoachMedProposal> meds) {
    return meds
        .map((m) =>
            '${m.name} (Started: ${m.startDate}${m.isPresent ? ', Present' : ', Ended: ${m.endDate}'})')
        .join(', ');
  }

  /// Round 54 — native's approve-time permission flow
  /// (CoachScreen.kt:89-113, :193-230): when READ+WRITE are
  /// already granted, proceed immediately. Otherwise show the
  /// in-app disclosure FIRST (MF-3 discipline) and fire the
  /// system request only from its Continue button; a grant lets
  /// the caller replay the pending approve, a denial (or a
  /// dismissed disclosure) returns false and the caller writes
  /// nothing. Bridge failures throw [CalendarException] so the
  /// caller can surface the visible error code.
  Future<bool> _runCalendarPermissionGate() async {
    final status = await _calendar.getPermissionStatus();
    if (status.granted) return true;
    if (!mounted) return false;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Calendar access needed',
            style: TextStyle(color: NotelColors.textPrimary)),
        content: const Text(coachCalendarPermissionDisclosure,
            style: TextStyle(color: NotelColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return false;
    final after = await _calendar.requestPermissions();
    return after.granted;
  }

  /// Native `approveProposedCalendarEvent`: the bridge performs
  /// native's writable-calendar selection, date/time parsing, and
  /// insert. Outcomes map to native's exact messages; every
  /// failure is flagged so the message is posted into the chat
  /// (native parity) with the proposal left pending.
  Future<CoachApprovalOutcome> _approveCalendarEvent(
      CoachParsedContent parsed) async {
    try {
      final outcome = await _calendar.insertEvent(
        title: parsed.calendarTitle!,
        date: parsed.calendarDate,
        time: parsed.calendarTime,
        description: parsed.calendarDesc,
        connectedEmail: widget.calendarEmail,
      );
      return switch (outcome) {
        CalendarInsertOutcome.inserted =>
          const CoachApprovalOutcome.success(),
        CalendarInsertOutcome.noWritableCalendar =>
          const CoachApprovalOutcome.failureAsMessage(
              coachCalendarNoWritableMessage),
        CalendarInsertOutcome.nullUri =>
          const CoachApprovalOutcome.failureAsMessage(
              coachCalendarNullUriMessage),
      };
    } on CalendarException catch (e) {
      // Native's outer catch posts FriendlyErrors
      // .coachCalendarAddFailure; the visible code is appended so
      // a screenshot still diagnoses the bridge failure (LESSONS).
      return CoachApprovalOutcome.failureAsMessage(
          '$coachCalendarAddFailureMessage [${e.code}]');
    } catch (_) {
      return const CoachApprovalOutcome.failureAsMessage(
          coachCalendarAddFailureMessage);
    }
  }

  /// Native `approveProposedCalendarDeleteEvent`: the bridge
  /// deletes every exact-title match in the day window. rows > 0
  /// succeeds and carries the row count so the confirmation is
  /// count-aware (Juno A2: 1 = native's verbatim singular, >1 =
  /// the plural string); 0 posts native's not-found message and
  /// the proposal stays pending (native flips the tag only on
  /// success).
  Future<CoachApprovalOutcome> _approveCalendarDelete(
      CoachParsedContent parsed) async {
    try {
      final rows = await _calendar.deleteEvents(
        title: parsed.calendarDeleteTitle!,
        date: parsed.calendarDeleteDate,
      );
      if (rows > 0) {
        return CoachApprovalOutcome.success(deletedRows: rows);
      }
      return CoachApprovalOutcome.failureAsMessage(
          coachCalendarDeleteNotFoundMessage(
              parsed.calendarDeleteTitle!));
    } on CalendarException catch (e) {
      return CoachApprovalOutcome.failureAsMessage(
          '$coachCalendarDeleteFailureMessage [${e.code}]');
    } catch (_) {
      return const CoachApprovalOutcome.failureAsMessage(
          coachCalendarDeleteFailureMessage);
    }
  }

  /// Native `handleCoachNote`: classify into a category
  /// (fallback 7), then save as a log entry via the entries upsert
  /// with a fresh id (max(existing) + 1).
  ///
  /// Round 48 fix round (Vera F2, coach half): the re-pull is
  /// NULL-CHECKED before any id math. On a failed pull the old
  /// code fell through with maxId 0 and posted
  /// `QuickLogEntry(id: 1, …)` — an id-keyed upsert that would
  /// overwrite the user's real entry 1. A failed pull now aborts
  /// honestly: visible specific error, zero posts.
  Future<CoachApprovalOutcome> _approveNote(String noteText) async {
    try {
      final categories = <String, String>{
        for (final c in widget.pullCategories)
          if (_asIntOr(c['id'], 0) != 0 || '${c['id']}' == '0')
            '${c['id']}': '${c['name'] ?? ''}',
      };
      final categoryId =
          await _backend.classifyCoachNote(noteText, categories) ?? 7;
      _backend.invalidateSyncPull();
      final pull = await _backend.fetchSyncPull();
      if (pull == null) {
        return const CoachApprovalOutcome.failure(
            coachNotePullFailedMessage);
      }
      final entries = pull['entries'];
      var maxId = 0;
      if (entries is List) {
        for (final e in entries) {
          if (e is Map) {
            final id = _asIntOr(e['id'], 0);
            if (id > maxId) maxId = id;
          }
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final saved = await _backend.postLogEntries([
        QuickLogEntry(
          id: maxId + 1,
          categoryId: categoryId,
          body: noteText,
          chips: '',
          manualText: '',
          timestamp: now,
        ),
      ]);
      return saved
          ? const CoachApprovalOutcome.success()
          : const CoachApprovalOutcome.failure();
    } catch (_) {
      return const CoachApprovalOutcome.failure();
    }
  }

  /// Round 55 Step 3 — approves a LOG_ENTRY proposal: re-pulls,
  /// then resolves the category by name from the RE-PULLED
  /// categories (case-insensitive; unknown category fails
  /// honestly and the proposal stays pending) and upserts the
  /// entry with the note flow's discipline — a failed or
  /// contract-violating re-pull aborts before any id math, and
  /// the new id is max(existing) + 1.
  Future<CoachApprovalOutcome> _approveLogEntry(
      CoachParsedContent parsed) async {
    try {
      _backend.invalidateSyncPull();
      final pull = await _backend.fetchSyncPull();
      if (pull == null) {
        return const CoachApprovalOutcome.failure(
            coachLogEntryPullFailedMessage);
      }
      // Round 55 fix pass (Vera 4a): a contract-violating pull
      // (entries missing or not a list) aborts BEFORE any id
      // math — the note flow's null-check discipline.
      final entries = pull['entries'];
      if (entries is! List) {
        return const CoachApprovalOutcome.failure(
            coachLogEntryPullFailedMessage);
      }
      // Round 55 fix pass (Vera 4b): the category resolves
      // against the RE-PULLED categories, never the stale
      // navigation-time widget.pullCategories.
      final wanted =
          (parsed.logEntryCategory ?? '').trim().toLowerCase();
      int? categoryId;
      final pulledCategories = pull['categories'];
      if (wanted.isNotEmpty && pulledCategories is List) {
        for (final c in pulledCategories) {
          if (c is Map &&
              '${c['name'] ?? ''}'.trim().toLowerCase() == wanted) {
            final id = _asIntOr(c['id'], -999);
            if (id != -999) categoryId = id;
            break;
          }
        }
      }
      if (categoryId == null) {
        return const CoachApprovalOutcome.failure(
            coachLogEntryUnknownCategoryMessage);
      }
      var maxId = 0;
      for (final e in entries) {
        if (e is Map) {
          final id = _asIntOr(e['id'], 0);
          if (id > maxId) maxId = id;
        }
      }
      final saved = await _backend.postLogEntries([
        QuickLogEntry(
          id: maxId + 1,
          categoryId: categoryId,
          body: parsed.logEntryText ?? '',
          chips: '',
          manualText: '',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      return saved
          ? const CoachApprovalOutcome.success()
          : const CoachApprovalOutcome.failure();
    } catch (_) {
      return const CoachApprovalOutcome.failure();
    }
  }

  /// Round 55 Step 3 — approves a COUNTER proposal: appends one
  /// event-counter row to the profile eventCounters blob, splicing
  /// the blob's RAW rows (the list approval's pattern) and building
  /// the new row through EventCounterItem.toMap so its shape is
  /// field-for-field the row Settings creates. Settings' create
  /// values are mirrored: the id is the creation time in epoch ms,
  /// duplicate names gain a (2), (3) suffix, and isFavorite is true
  /// only when this is the first counter. isUp is set when the
  /// target day is already past, so the counter reads as days-since
  /// immediately; a future target reads as days-until.
  ///
  /// Correction round (Vera F4): this approval is a whole-blob
  /// eventCounters writer OUTSIDE Settings' _saveCounters, so it
  /// upholds the same invariant itself — the spliced rows are
  /// filtered through the local delete-tombstone set BEFORE the
  /// push. Without that, approving a counter while a tombstone is
  /// active would re-push the deleted id server-side and cement
  /// the resurrection the tombstone exists to prevent.
  Future<CoachApprovalOutcome> _approveCounter(
      CoachParsedContent parsed) async {
    try {
      final rawDate = (parsed.counterDate ?? '').trim();
      final parsedDate = DateTime.tryParse(rawDate);
      // Round 55 fix pass (Vera LOW): the parsed date must
      // ROUND-TRIP — Dart's parser normalizes out-of-range
      // components (2026-02-31 rolls into March), so the parsed
      // year/month/day must equal the split components exactly.
      final dateParts = rawDate.split('-');
      final roundTrips = parsedDate != null &&
          dateParts.length == 3 &&
          int.tryParse(dateParts[0]) == parsedDate.year &&
          int.tryParse(dateParts[1]) == parsedDate.month &&
          int.tryParse(dateParts[2]) == parsedDate.day;
      if (!roundTrips ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(rawDate)) {
        return const CoachApprovalOutcome.failure(
            coachCounterInvalidDateMessage);
      }
      _backend.invalidateSyncPull();
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        return const CoachApprovalOutcome.failure();
      }
      final rows = decodeCoachProfileBlobRaw(profile['eventCounters']);
      // Vera F4 — tombstone filter (see the doc comment above).
      // The set is resolved at approve time through the parent's
      // seam; filterDeletedCounters is the shared authority — it
      // runs on parsed items only to decide WHICH ids survive,
      // and the RAW rows are then kept verbatim (the Vera F6 raw
      // pattern — non-Map rows and unknown keys are never
      // rewritten here).
      final tombstones = await (widget.counterTombstoneIds?.call() ??
          Future<Set<String>>.value(const <String>{}));
      if (tombstones.isNotEmpty) {
        final survivingIds = filterDeletedCounters(
          [
            for (final row in rows)
              if (coachRawRowMap(row) != null)
                EventCounterItem.fromMap(coachRawRowMap(row)!),
          ],
          tombstones,
        ).map((c) => c.id).toSet();
        rows.removeWhere((row) {
          final m = coachRawRowMap(row);
          return m != null && !survivingIds.contains('${m['id'] ?? ''}');
        });
      }
      final names = <String>{
        for (final row in rows)
          if (coachRawRowMap(row) != null)
            '${coachRawRowMap(row)!['name'] ?? ''}',
      };
      var unique = (parsed.counterName ?? '').trim();
      if (unique.isEmpty) {
        return const CoachApprovalOutcome.failure();
      }
      var suffix = 2;
      final baseName = unique;
      while (names.contains(unique)) {
        unique = '$baseName ($suffix)';
        suffix++;
      }
      final now = DateTime.now();
      final targetDay = DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
      final today = DateTime(now.year, now.month, now.day);
      final item = EventCounterItem(
        id: '${now.millisecondsSinceEpoch}',
        name: unique,
        targetDate: targetDay.millisecondsSinceEpoch,
        isUp: targetDay.isBefore(today),
        autoUp: false,
        isFavorite: rows.isEmpty,
        isArchived: false,
      );
      rows.add(item.toMap());
      final saved = await _backend
          .postSyncProfile({'eventCounters': jsonEncode(rows)});
      return saved
          ? const CoachApprovalOutcome.success()
          : const CoachApprovalOutcome.failure();
    } catch (_) {
      return const CoachApprovalOutcome.failure();
    }
  }

  /// Native `approveProposedFile` fallback path: reconstruct the
  /// document from the "📄 Uploaded file: `<name>`\n\n`<text>`" user
  /// message in this session and push it via
  /// `POST /api/sync/documents`.
  ///
  /// Round 48 fix round (Juno F3): when NO such source message
  /// exists, the failure is not a save failure — the file was
  /// never attached in this app — so it carries its own accurate
  /// message instead of the generic connection copy (retrying
  /// could never help). Genuine save failures keep the generic
  /// message.
  Future<CoachApprovalOutcome> _approveFile(String fileName) async {
    try {
      final prefix = '📄 Uploaded file: $fileName';
      CoachChatMessage? uploadMsg;
      for (final m in _messages) {
        if (m.role == 'user' && m.content.startsWith(prefix)) {
          uploadMsg = m;
          break;
        }
      }
      if (uploadMsg == null) {
        return const CoachApprovalOutcome.failure(
            coachFileNotAttachedMessage);
      }
      final sep = uploadMsg.content.indexOf('\n\n');
      final extracted =
          sep >= 0 ? uploadMsg.content.substring(sep + 2) : '';
      final docId = newUuid();
      // Round 65: syncDocuments now verifies the server's
      // `{synced: n}` accounts for the row (R57 pattern), so a
      // success here is a verified save, not a status-only 200.
      final saved = await _backend.syncDocuments([
        {
          'id': docId,
          'name': fileName,
          'mimeType': 'text/plain',
          'fileData': base64Encode(utf8.encode(extracted)),
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        },
      ]);
      if (saved && extracted.trim().isNotEmpty) {
        // Native ingestPreExtractedDocumentFile stores the
        // already-extracted text ON the document (local Room);
        // the Lab's equivalent is the account-bound extraction
        // cache, so the approved file shows "AI read" in Settings
        // and feeds the coach context like any other document.
        try {
          final store =
              widget.knowledgeStore ?? KnowledgeExtractionStore.instance;
          await store.load(await _accountEmail());
          await store.saveText(docId, extracted);
        } catch (_) {
          // The document itself is saved and verified; a local
          // cache failure only means a later backfill re-extracts.
        }
      }
      return saved
          ? const CoachApprovalOutcome.success()
          : const CoachApprovalOutcome.failure();
    } catch (_) {
      return const CoachApprovalOutcome.failure();
    }
  }

  /// Native `approveProposedList`: append `{name, items}` to the
  /// profile's FULL userLists blob (freshest pull → append → push
  /// all rows, including the `__user_notes__` pseudo-list).
  ///
  /// Round 48 fix round (Vera F6): the append splices the blob's
  /// RAW rows ([decodeCoachProfileBlobRaw]) — non-Map rows and
  /// unknown keys survive verbatim instead of being dropped or
  /// coerced by `decodeProfileList`.
  Future<CoachApprovalOutcome> _approveList(
      CoachParsedContent parsed) async {
    try {
      _backend.invalidateSyncPull();
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        return const CoachApprovalOutcome.failure();
      }
      final rows = decodeCoachProfileBlobRaw(profile['userLists']);
      rows.add({'name': parsed.listName, 'items': parsed.listItems});
      final saved = await _backend
          .postSyncProfile({'userLists': jsonEncode(rows)});
      return saved
          ? const CoachApprovalOutcome.success()
          : const CoachApprovalOutcome.failure();
    } catch (_) {
      return const CoachApprovalOutcome.failure();
    }
  }

  /// Native `approveProposedReminder`: append a FIXED reminder row
  /// (HH:MM parsed, 9:00 default like native) to the profile's FULL
  /// reminders blob (freshest pull → append → push all rows).
  ///
  /// Round 48 fix round (Juno F2 — BLOCKING): approval runs the
  /// Reminders create flow's permission gate
  /// ([runReminderCreatePermissionGate]: exact-alarm advisory
  /// FIRST → rationale dialog → system request ONLY from Allow)
  /// BEFORE anything is written. Denial at any step leaves the
  /// proposal pending, writes nothing, appends no confirmation,
  /// and shows the honest reason. After a successful write the
  /// FULL alarm reconcile runs, so the reminder is actually
  /// scheduled — the old path wrote an enabled row nobody ever
  /// scheduled while telling the user it was set.
  ///
  /// Round 48 fix round (Vera F6): the append splices the blob's
  /// RAW rows; the map view of those rows is used only to compute
  /// the next id and to build the alarm-reconcile models (the
  /// ReminderDocument retention pattern, over raw rows).
  Future<CoachApprovalOutcome> _approveReminder(
      CoachParsedContent parsed) async {
    try {
      final granted = await runReminderCreatePermissionGate(
        context: context,
        notifs: _notifs,
      );
      if (!granted) {
        return const CoachApprovalOutcome.failure(
            coachReminderPermissionDeniedMessage);
      }
      final parts = (parsed.reminderTime ?? '').split(':');
      final hour = parts.isNotEmpty
          ? int.tryParse(parts[0].trim()) ?? 9
          : 9;
      final minute = parts.length > 1
          ? int.tryParse(parts[1].trim()) ?? 0
          : 0;
      _backend.invalidateSyncPull();
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        return const CoachApprovalOutcome.failure();
      }
      final rows = decodeCoachProfileBlobRaw(profile['reminders']);
      final mapRows = <Map<String, dynamic>>[
        for (final row in rows)
          if (coachRawRowMap(row) != null) coachRawRowMap(row)!,
      ];
      final newRow = buildReminderRow(
        id: nextReminderId(mapRows),
        title: parsed.reminderTitle!,
        type: 'FIXED',
        fixedHour: hour,
        fixedMinute: minute,
        intervalHours: 2,
        intervalMinutes: 0,
        startHour: 8,
        startMinute: 0,
        endHour: 21,
        endMinute: 0,
        isEnabled: true,
        customDays: false,
        dayConfigs: const [],
      );
      rows.add(newRow);
      final saved = await _backend
          .postSyncProfile({'reminders': jsonEncode(rows)});
      if (!saved) return const CoachApprovalOutcome.failure();
      // The row is saved; now schedule it. A scheduling failure
      // never un-saves the row (the Reminders screen's rule) — it
      // surfaces as a non-blocking note instead.
      try {
        final alarmsOk = await reconcileReminderAlarms(
          _notifs,
          parseReminderModels([...mapRows, newRow]),
        );
        if (!alarmsOk) {
          _snack('Reminder saved. The alarm could not be scheduled '
              '— check notification permissions.');
        }
      } catch (_) {
        _snack('Reminder saved. The alarm could not be scheduled '
            '— check notification permissions.');
      }
      return const CoachApprovalOutcome.success();
    } catch (_) {
      return const CoachApprovalOutcome.failure();
    }
  }

  /// Native `approveProposedMedication`: append the proposed meds
  /// to the profile's FULL medications blob, deduplicating by name
  /// like native (existing rows win; untouched rows round-trip
  /// verbatim).
  ///
  /// Round 48 fix round (Vera F6): the append splices the blob's
  /// RAW rows — non-Map rows and unknown keys survive verbatim
  /// (the MedicationDocument retention rule, over raw rows);
  /// existing names are read from the map rows only.
  Future<CoachApprovalOutcome> _approveMedications(
      List<CoachMedProposal> meds) async {
    try {
      _backend.invalidateSyncPull();
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        return const CoachApprovalOutcome.failure();
      }
      final rows = decodeCoachProfileBlobRaw(profile['medications']);
      final existingNames = <String>{
        for (final row in rows)
          if (coachRawRowMap(row) != null)
            '${coachRawRowMap(row)!['name'] ?? ''}'.trim().toLowerCase(),
      };
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final med in meds) {
        if (existingNames.contains(med.name.trim().toLowerCase())) {
          continue;
        }
        rows.add({
          'id': newUuid(),
          'name': med.name,
          'startDate': med.startDate,
          'endDate': med.isPresent ? 'Present' : med.endDate,
          'isPresent': med.isPresent,
          // Round 55 Step 3: the extended grammar carries real
          // dose/frequency — write those. The placeholders remain
          // only for legacy-shape tags that carry neither.
          'dose': med.dose.trim().isNotEmpty ? med.dose.trim() : 'As prescribed',
          // Round 55 fix pass (Juno M1): the stated frequency or
          // empty — never a fabricated 'Daily'.
          'frequency': med.frequency.trim(),
          'updatedAt': now,
          'isDeleted': false,
        });
      }
      final saved = await _backend
          .postSyncProfile({'medications': jsonEncode(rows)});
      return saved
          ? const CoachApprovalOutcome.success()
          : const CoachApprovalOutcome.failure();
    } catch (_) {
      return const CoachApprovalOutcome.failure();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Native shows the chat delete action when there is more than
    // the greeting on screen.
    final realMessages =
        _messages.where((m) => m.role != 'error').length;
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textPrimary, semanticLabel: 'Back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            const CoachMascotAvatar(size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _title,
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (_sessionPersisted && realMessages > 1)
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: NotelColors.error, semanticLabel: 'Delete Chat'),
              onPressed: _deleteCurrentSession,
            ),
        ],
      ),
      body: Column(
        children: [
          const _DisclaimerBanner(),
          Expanded(
            child: ListView.separated(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: _messages.length,
              separatorBuilder: (context, _) =>
                  const SizedBox(height: 14),
              itemBuilder: (context, i) => _ChatBubble(
                labelKey: i == 0 ? _firstLabelKey : null,
                message: _messages[i],
                sessionMessages: _messages,
                actionBusy: _actionBusy,
                calendarConnected: widget.calendarConnected,
                onProposal: (kind, approve) => _resolveProposal(
                    _messages[i], kind,
                    approve: approve),
              ),
            ),
          ),
          _InputBar(
            controller: _input,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

class _DisclaimerBanner extends StatelessWidget {
  const _DisclaimerBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: NotelColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        coachDisclaimer,
        style: TextStyle(
            fontSize: 11, color: NotelColors.textSecondary),
        textAlign: TextAlign.center,
      ),
    );
  }
}

// ── Chat bubble + proposal cards ────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final CoachChatMessage message;

  /// Every message in this session (Round 55 fix pass, Mira N9:
  /// the File proposal card checks it for its upload source, the
  /// same existence check _approveFile performs).
  final List<CoachChatMessage> sessionMessages;
  final bool actionBusy;

  /// Round 54 — when Google Calendar is connected, calendar cards
  /// offer the real approve (native's labels); when not, they keep
  /// Round 48's limitation treatment.
  final bool calendarConnected;
  final void Function(String kind, bool approve) onProposal;

  /// Set only on the thread's first bubble: measures its
  /// sender-label row for [_CoachChatScreenState._scrollToBottom]'s
  /// clipped-label guard. Null on every other bubble.
  final Key? labelKey;

  const _ChatBubble({
    this.labelKey,
    required this.message,
    this.sessionMessages = const [],
    required this.actionBusy,
    this.calendarConnected = false,
    required this.onProposal,
  });

  /// Whether this session holds the "📄 Uploaded file:" source
  /// message for [fileName] — mirrors _approveFile's lookup.
  bool _hasFileSource(String fileName) {
    final prefix = '📄 Uploaded file: $fileName';
    return sessionMessages
        .any((m) => m.role == 'user' && m.content.startsWith(prefix));
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isError = message.role == 'error';
    final isLoading = message.role == 'coach' && message.content.isEmpty;
    final parsed = message.parsed;
    final displayText = isUser
        ? cleanCoachDisplayText(message.content)
        : cleanCoachDisplayText(parsed.cleanContent);

    final color = isUser
        ? NotelColors.primary.withValues(alpha: 0.15)
        : isError
            ? NotelColors.error.withValues(alpha: 0.12)
            : NotelColors.surfaceHigh.withValues(alpha: 0.5);
    final radius = isUser
        ? const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(20),
            bottomRight: Radius.circular(4),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(20),
          );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isUser && !isError)
              Padding(
                key: labelKey,
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CoachMascotAvatar(size: 20),
                    SizedBox(width: 6),
                    Text('$kCoachName · Tabs Coach',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: NotelColors.primary)),
                  ],
                ),
              ),
            if (displayText.isNotEmpty || isLoading)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: color, borderRadius: radius),
                child: isLoading
                    ? const SizedBox(
                        width: 40,
                        child: LinearProgressIndicator(
                            color: NotelColors.primary),
                      )
                    : Text(
                        displayText,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.45,
                          color: isUser
                              ? NotelColors.primary
                              : isError
                                  ? NotelColors.error
                                  : NotelColors.textPrimary,
                        ),
                      ),
              ),
            if (!isUser && !isError) ..._proposalWidgets(parsed),
          ],
        ),
      ),
    );
  }

  List<Widget> _proposalWidgets(CoachParsedContent parsed) {
    final out = <Widget>[];

    void addCard(Widget card) {
      out.add(const SizedBox(height: 8));
      out.add(card);
    }

    // Note — native card copy.
    if (parsed.noteText != null) {
      switch (parsed.noteStatus) {
        case CoachProposalStatus.pending:
          addCard(_ProposalCard(
            emoji: '📝',
            title: 'Suggested Note Log',
            approveLabel: 'Approve',
            denyLabel: 'Dismiss',
            busy: actionBusy,
            onApprove: () => onProposal('note', true),
            onDeny: () => onProposal('note', false),
            children: [
              Text('“${parsed.noteText}”',
                  style: const TextStyle(
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                      height: 1.4,
                      color: NotelColors.textPrimary)),
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Note Saved', color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Note Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    // File — native card copy.
    if (parsed.fileName != null) {
      switch (parsed.fileStatus) {
        case CoachProposalStatus.pending:
          addCard(_ProposalCard(
            emoji: '📁',
            title: 'Save Document to Tabs DB?',
            approveLabel: 'Approve',
            denyLabel: 'Dismiss',
            // Round 55 fix pass (Mira N9): when this session has
            // no uploaded-file source message, the limitation is
            // stated on the card face and approve is disabled
            // (the _approveFile snackbar remains the backstop).
            approveEnabled: _hasFileSource(parsed.fileName!),
            notice: _hasFileSource(parsed.fileName!)
                ? null
                : coachFileNotAttachedMessage,
            busy: actionBusy,
            onApprove: () => onProposal('file', true),
            onDeny: () => onProposal('file', false),
            children: [
              Text(
                  'Would you like to save "${parsed.fileName}" to your permanent Tabs database?',
                  style: const TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: NotelColors.textPrimary)),
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Document Saved to Tabs DB',
              color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Document Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    // List — native card copy.
    if (parsed.listName != null) {
      switch (parsed.listStatus) {
        case CoachProposalStatus.pending:
          addCard(_ProposalCard(
            emoji: '📋',
            title: 'Create List?',
            approveLabel: 'Approve',
            denyLabel: 'Dismiss',
            busy: actionBusy,
            onApprove: () => onProposal('list', true),
            onDeny: () => onProposal('list', false),
            children: [
              Text('Create list "${parsed.listName}" with items:',
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
              const SizedBox(height: 6),
              for (final item in parsed.listItems)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('•  $item',
                      style: const TextStyle(
                          fontSize: 13,
                          color: NotelColors.textPrimary)),
                ),
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ List Created', color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ List Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    // Reminder — native card copy ("Set It").
    if (parsed.reminderTitle != null) {
      switch (parsed.reminderStatus) {
        case CoachProposalStatus.pending:
          addCard(_ProposalCard(
            emoji: '🔔',
            title: 'Set Reminder?',
            approveLabel: 'Set It',
            denyLabel: 'Dismiss',
            busy: actionBusy,
            onApprove: () => onProposal('reminder', true),
            onDeny: () => onProposal('reminder', false),
            children: [
              Text(parsed.reminderTitle!,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
              if (parsed.reminderTime != null) ...[
                const SizedBox(height: 4),
                Text('🕐 ${_formatReminderTime(parsed.reminderTime!)}',
                    style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary)),
              ],
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Reminder Set', color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Reminder Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    // Calendar event — native card copy. Round 54: when Google
    // Calendar is connected the approve control is live with
    // native's label ('Approve & Add'); when not connected, the
    // Round 48 (Juno F1) treatment stays: the limitation stated ON
    // the card and the approve control disabled and labelled
    // accordingly. Dismiss works fully either way.
    if (parsed.calendarTitle != null) {
      switch (parsed.calendarStatus) {
        case CoachProposalStatus.pending:
          addCard(_ProposalCard(
            emoji: '📅',
            title: 'Proposed Calendar Event',
            approveLabel:
                calendarConnected ? 'Approve & Add' : 'Native App Required',
            approveEnabled: calendarConnected,
            notice: calendarConnected ? null : coachCalendarCardLimitation,
            denyLabel: 'Dismiss',
            busy: actionBusy,
            onApprove: () => onProposal('calendar', true),
            onDeny: () => onProposal('calendar', false),
            children: [
              Text(parsed.calendarTitle!,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
              if ((parsed.calendarDate ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('📅 ${_formatCoachDatePremium(parsed.calendarDate!)}',
                    style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary)),
              ],
              if ((parsed.calendarTime ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('🕐 ${_formatReminderTime(parsed.calendarTime!)}',
                    style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary)),
              ],
              if ((parsed.calendarDesc ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(parsed.calendarDesc!,
                    style: const TextStyle(
                        fontSize: 12,
                        color: NotelColors.textSecondary)),
              ],
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Event Scheduled & Added to Calendar',
              color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Event Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    // Calendar deletion — native card copy. Round 54: connected
    // enables the real approve ('Approve & Delete', native's
    // label); not connected keeps the Round 48 (Juno F1)
    // treatment: limitation ON the card, approve disabled and
    // labelled accordingly. Dismiss works fully either way.
    // Round 54 fix round (Juno A2): connected pending cards also
    // carry the delete-scope notice in the card's notice slot
    // (display only); the flag-off limitation is untouched.
    if (parsed.calendarDeleteTitle != null) {
      switch (parsed.calendarDeleteStatus) {
        case CoachProposalStatus.pending:
          addCard(_ProposalCard(
            emoji: '📅',
            title: 'Proposed Calendar Deletion',
            titleColor: NotelColors.error,
            approveLabel: calendarConnected
                ? 'Approve & Delete'
                : 'Native App Required',
            approveEnabled: calendarConnected,
            notice: calendarConnected
                ? coachCalendarDeleteScopeNotice
                : coachCalendarCardLimitation,
            denyLabel: 'Dismiss',
            busy: actionBusy,
            onApprove: () => onProposal('calendarDelete', true),
            onDeny: () => onProposal('calendarDelete', false),
            children: [
              Text(parsed.calendarDeleteTitle!,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
              if ((parsed.calendarDeleteDate ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                    'Scheduled for: ${_formatCoachDatePremium(parsed.calendarDeleteDate!)}',
                    style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary)),
              ],
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Event Deleted from Calendar',
              color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Deletion Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    // Log entry — Round 55 Step 3.
    if (parsed.logEntryText != null) {
      switch (parsed.logEntryStatus) {
        case CoachProposalStatus.pending:
          addCard(_ProposalCard(
            emoji: '📓',
            title: 'Proposed Log Entry',
            approveLabel: 'Approve',
            denyLabel: 'Dismiss',
            busy: actionBusy,
            onApprove: () => onProposal('logEntry', true),
            onDeny: () => onProposal('logEntry', false),
            children: [
              Text('“${parsed.logEntryText}”',
                  style: const TextStyle(
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                      height: 1.4,
                      color: NotelColors.textPrimary)),
              if (parsed.logEntryCategory != null &&
                  parsed.logEntryCategory!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(parsed.logEntryCategory!,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: NotelColors.textSecondary)),
              ],
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Entry Logged', color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Log Entry Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    // Event counter — Round 55 Step 3.
    if (parsed.counterName != null) {
      switch (parsed.counterStatus) {
        case CoachProposalStatus.pending:
          final target = parsed.counterDate == null
              ? null
              : DateTime.tryParse(parsed.counterDate!);
          final daysLabel = target == null
              ? (parsed.counterDate ?? '')
              : EventCounterItem(
                  id: '',
                  name: parsed.counterName!,
                  targetDate: DateTime(target.year, target.month, target.day)
                      .millisecondsSinceEpoch,
                  isUp: DateTime(target.year, target.month, target.day)
                      .isBefore(DateTime(DateTime.now().year,
                          DateTime.now().month, DateTime.now().day)),
                ).daysLabel();
          addCard(_ProposalCard(
            emoji: '⏳',
            title: 'Proposed Event Counter',
            approveLabel: 'Approve',
            denyLabel: 'Dismiss',
            busy: actionBusy,
            onApprove: () => onProposal('counter', true),
            onDeny: () => onProposal('counter', false),
            children: [
              Text(parsed.counterName!,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
              if ((parsed.counterDate ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                    target == null
                        ? parsed.counterDate!
                        : '${_monthNames[target.month - 1]} ${target.day}, ${target.year} — $daysLabel',
                    style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary)),
              ],
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Counter Created', color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Counter Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    // Medications — native card copy ("Approve & Add" / "Dismiss").
    if (parsed.medications.isNotEmpty) {
      switch (parsed.medicationStatus) {
        case CoachProposalStatus.pending:
          addCard(_ProposalCard(
            emoji: '💊',
            title: parsed.medications.length > 1
                ? 'Proposed Medications'
                : 'Proposed Medication',
            approveLabel: 'Approve & Add',
            denyLabel: 'Dismiss',
            busy: actionBusy,
            onApprove: () => onProposal('medication', true),
            onDeny: () => onProposal('medication', false),
            children: [
              for (var i = 0; i < parsed.medications.length; i++) ...[
                Text(parsed.medications[i].name,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  parsed.medications[i].isPresent
                      ? 'Started: ${parsed.medications[i].startDate} • Present'
                      : 'Started: ${parsed.medications[i].startDate} • Ended: ${parsed.medications[i].endDate}',
                  style: const TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary),
                ),
                if (parsed.medications[i].dose.trim().isNotEmpty ||
                    parsed.medications[i].frequency
                        .trim()
                        .isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (parsed.medications[i].dose.trim().isNotEmpty)
                        parsed.medications[i].dose.trim(),
                      if (parsed.medications[i].frequency
                          .trim()
                          .isNotEmpty)
                        parsed.medications[i].frequency.trim(),
                    ].join(' • '),
                    style: const TextStyle(
                        fontSize: 12,
                        color: NotelColors.textSecondary),
                  ),
                ],
                if (i < parsed.medications.length - 1)
                  const SizedBox(height: 8),
              ],
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(_ProposalBadge(
              text: parsed.medications.length > 1
                  ? '✓ Medications Added to Profile'
                  : '✓ Medication Added to Profile',
              color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(_ProposalBadge(
              text: parsed.medications.length > 1
                  ? '✗ Medications Dismissed'
                  : '✗ Medication Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    return out;
  }
}

/// Round 55 fix pass (Mira S7): a parseable date renders in the
/// premium long form, "October 13, 2026"; the raw string is the
/// fallback only when parsing fails.
String _formatCoachDatePremium(String raw) {
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return raw;
  return '${_monthNames[parsed.month - 1]} ${parsed.day}, '
      '${parsed.year}';
}

/// Formats an "HH:MM" reminder time as 12-hour, like native's card.
String _formatReminderTime(String raw) {
  final parts = raw.split(':');
  final hour = parts.isNotEmpty ? int.tryParse(parts[0].trim()) : null;
  final minute = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
  if (hour == null || minute == null) return raw;
  final amPm = hour < 12 ? 'AM' : 'PM';
  final h12 = hour % 12 == 0 ? 12 : hour % 12;
  return '$h12:${minute.toString().padLeft(2, '0')} $amPm';
}

class _ProposalBadge extends StatelessWidget {
  final String text;
  final Color color;

  const _ProposalBadge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  final String emoji;
  final String title;

  /// Title color. Defaults to the Round 55 design's title color
  /// (textSecondary) so every existing card renders unchanged;
  /// Round 54's calendar-DELETION card passes NotelColors.error.
  final Color titleColor;
  final List<Widget> children;
  final String approveLabel;
  final String denyLabel;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  /// Optional limitation stated ON the card itself, above the
  /// action row (Juno F1: the calendar cards must not reveal
  /// their limitation only after a tap).
  final String? notice;

  /// Whether the approve control is enabled. False renders it
  /// disabled (and [approveLabel] should say why) regardless of
  /// [busy]; deny/dismiss is never affected.
  final bool approveEnabled;

  const _ProposalCard({
    required this.emoji,
    required this.title,
    this.titleColor = NotelColors.textSecondary,
    required this.children,
    required this.approveLabel,
    required this.denyLabel,
    required this.busy,
    required this.onApprove,
    required this.onDeny,
    this.notice,
    this.approveEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: titleColor)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
          if (notice != null) ...[
            const SizedBox(height: 10),
            Text(
              notice!,
              style: const TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: NotelColors.textSecondary),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onDeny,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NotelColors.textSecondary,
                    side: const BorderSide(color: NotelColors.divider),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(denyLabel,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: (busy || !approveEnabled) ? null : onApprove,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NotelColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(approveLabel,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _InputBar(
      {required this.controller, required this.sending, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: NotelColors.background,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                maxLines: 4,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(
                    color: NotelColors.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Ask $kCoachName anything...',
                  hintStyle: const TextStyle(
                      color: NotelColors.textSecondary),
                  filled: true,
                  fillColor:
                      NotelColors.surfaceHigh.withValues(alpha: 0.25),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                        color: NotelColors.surfaceHigh
                            .withValues(alpha: 0.5)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                        color: NotelColors.surfaceHigh
                            .withValues(alpha: 0.5)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                        color: NotelColors.primary.withValues(alpha: 0.5)),
                  ),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 48,
              child: ElevatedButton(
                onPressed: sending ? null : onSend,
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                  disabledBackgroundColor: NotelColors.surfaceHigh,
                ),
                child: sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.send, semanticLabel: 'Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pure parsing/formatting helpers (unit-tested) ───────────────────────────

/// Parses sync-pull `coachSessions` → newest-first summaries.
/// Skips malformed rows; never throws.
List<CoachSessionSummary> parseCoachSessions(dynamic raw) {
  if (raw is! List) return const [];
  final out = <CoachSessionSummary>[];
  for (final item in raw) {
    if (item is Map<String, dynamic> && '${item['id'] ?? ''}'.isNotEmpty) {
      out.add(CoachSessionSummary.fromJson(item));
    }
  }
  out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return out;
}

/// Groups sync-pull `coachMessages` by session id, oldest-first.
/// Skips malformed rows; never throws.
Map<String, List<CoachChatMessage>> groupCoachMessages(dynamic raw) {
  final out = <String, List<CoachChatMessage>>{};
  if (raw is! List) return out;
  for (final item in raw) {
    if (item is Map<String, dynamic> &&
        '${item['sessionId'] ?? ''}'.isNotEmpty) {
      final msg = CoachChatMessage.fromJson(item);
      out.putIfAbsent(msg.sessionId, () => []).add(msg);
    }
  }
  for (final list in out.values) {
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }
  return out;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// Formats an epoch-ms timestamp like the native history list:
/// "Oct 11, 6:16 PM".
String formatCoachDate(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final amPm = dt.hour < 12 ? 'AM' : 'PM';
  final minute = dt.minute.toString().padLeft(2, '0');
  return '${_months[dt.month - 1]} ${dt.day}, $hour12:$minute $amPm';
}
