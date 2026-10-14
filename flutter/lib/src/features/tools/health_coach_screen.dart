import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/calendar_service.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/reminder_alarm_sync.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart'
    show
        buildReminderRow,
        nextReminderId,
        parseReminderModels,
        runReminderCreatePermissionGate;
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
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
    "Hi! I'm Tabs Coach. I have context on your recent logs, health "
    'history, and knowledge base. How can I help you today?';

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
/// addition and changes none of native's outcomes.
const String coachCalendarPermissionDisclosure =
    'Tabs Coach needs read and write access to your calendar. When Google Calendar is connected, the Coach reads the titles and times of your events for today and the next 14 days and sends them to the Tabs AI service so it can answer with your schedule in context. The Coach can also add events to, and delete events from, your calendar, only for proposals you tap Approve on. Nothing is added or deleted without your approval. Tap Continue to allow calendar access.';

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

  const CoachMedProposal({
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.isPresent,
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

List<CoachMedProposal> _parseMedicationString(String raw) {
  final out = <CoachMedProposal>[];
  for (final item in raw.split(';')) {
    final parts = item.split('|');
    final name = (parts.isNotEmpty ? parts[0] : '').trim();
    if (name.isEmpty) continue;
    final startDate = parts.length > 1 ? parts[1].trim() : '';
    var endDate = parts.length > 2 ? parts[2].trim() : '';
    final isPresent =
        parts.length > 3 && parts[3].trim().toLowerCase() == 'true';
    if (isPresent) endDate = 'Present';
    out.add(CoachMedProposal(
      name: name,
      startDate: startDate,
      endDate: endDate,
      isPresent: isPresent,
    ));
  }
  return out;
}

/// Ports native `parseCoachMessageContent` (CoachViewModel.kt):
/// strips every `[PROPOSE_*]` / `[APPROVED_*]` / `[DENIED_*]` action
/// tag from the display text and reports each proposal + status.
/// Pure and unit-tested. Never throws.
CoachParsedContent parseCoachMessageContent(String rawContent) {
  var clean = rawContent;

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

MEDICATIONS: You MUST actively inspect the user's message and the contents of any uploaded files/documents (indicated by "📄 Uploaded file: [filename]\\n\\n[contents]") for medications. If the user mentions starting, taking, stopping, or updating medications, or if the uploaded document says the user is taking or was taking any medications, you MUST propose adding them.
Format: Propose ALL found medications in a single tag by separating them with a semicolon.
Each medication format: Name|StartDate|EndDate|isPresent
Use 'isPresent' as 'true' if the user is currently taking the medication, or 'false' if they have stopped. If they are currently taking it, the EndDate should be empty.
Dates should look like "Jun 2026", "2025-12-05", "Dec 2025" or similar based on context.
Example for multiple medications: [PROPOSE_MEDICATION:Pyridostigmine|Jun 2026||true;Metoprolol|Jan 2025|May 2026|false]

$calendarInstructions

Only include ONE action tag per response. (Note: For multiple medications, combine them into a single [PROPOSE_MEDICATION:...] tag separated by semicolons as shown above). Do not include markdown formatting inside the brackets.''';

  final base = (baseUserContext ?? '').trim();
  return base.isEmpty ? actionInstructions : '$base\n\n$actionInstructions';
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
      final unlimited = pull?['isUnlimited'] == true;
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
          calendarService: _calendar,
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
              fontSize: 20,
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
      return const Center(
          child: CircularProgressIndicator(color: NotelColors.primary));
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.chat_bubble_outline,
                  size: 64, color: NotelColors.textSecondary),
              SizedBox(height: 16),
              Text('No chats yet.',
                  style: TextStyle(
                      fontSize: 16, color: NotelColors.textSecondary)),
              SizedBox(height: 4),
              Text('Tap the + button to start a conversation.',
                  style: TextStyle(
                      fontSize: 14, color: NotelColors.textSecondary)),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
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
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
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
                                    fontSize: 18,
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
                          color: NotelColors.textSecondary),
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

  /// Injectable calendar bridge (Round 54). Null in production.
  final CalendarService? calendarService;

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
    this.calendarService,
    this.calendarConnected = false,
    this.calendarEmail = '',
    this.sessionId,
    this.sessionTitle = 'New Chat',
    this.sessionCreatedAt = 0,
    this.initialMessages = const [],
    this.profile,
    this.pullEntries = const [],
    this.pullCategories = const [],
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
  bool _sending = false;
  bool _actionBusy = false;

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
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
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
    // Round 54 — native computes the upcoming-events context on
    // every send (CoachViewModel.kt:1363). Connected: the live
    // bridge read, formatted exactly like native; a bridge failure
    // mirrors native's outer catch ("Calendar events are
    // unavailable right now."). Not connected: native's own
    // not-connected return (unused by the not-connected branch).
    var calendarEventsContext = coachCalendarNotConnectedContext;
    if (widget.calendarConnected) {
      try {
        final events = await _calendar.getUpcomingEvents();
        calendarEventsContext = formatUpcomingCalendarEvents(events);
      } on CalendarException {
        calendarEventsContext = calendarEventsUnavailableContext;
      } catch (_) {
        calendarEventsContext = calendarEventsUnavailableContext;
      }
    }
    final body = {
      'messages': history,
      'userContext': coachEnrichedUserContext(
        widget.profile?['userContext']?.toString(),
        now: DateTime.now(),
        calendarConnected: widget.calendarConnected,
        calendarEventsContext: calendarEventsContext,
      ),
      'knowledgeBase': kb.isEmpty ? null : kb,
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
      final coachMsg = CoachChatMessage(
        id: newUuid(),
        sessionId: _sessionId,
        role: 'coach',
        content: reply,
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
          'calendar' => "Okay, I won't add that to your calendar.",
          'calendarDelete' => "Okay, I won't delete that event.",
          // Native's medication deny inserts no confirmation.
          _ => null,
        };
      }

      final updated = message.copyWith(
        content: rewriteProposalTag(
          message.content,
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
      final saved = await _backend.syncDocuments([
        {
          'id': newUuid(),
          'name': fileName,
          'mimeType': 'text/plain',
          'fileData': base64Encode(utf8.encode(extracted)),
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        },
      ]);
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
          'dose': 'As prescribed',
          'frequency': 'Daily',
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
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: NotelColors.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Text('✨', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _title,
                style: const TextStyle(
                    fontSize: 20,
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
                message: _messages[i],
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
  final bool actionBusy;

  /// Round 54 — when Google Calendar is connected, calendar cards
  /// offer the real approve (native's labels); when not, they keep
  /// Round 48's limitation treatment.
  final bool calendarConnected;
  final void Function(String kind, bool approve) onProposal;

  const _ChatBubble({
    required this.message,
    required this.actionBusy,
    this.calendarConnected = false,
    required this.onProposal,
  });

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
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text('✨ Tabs Coach',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: NotelColors.primary)),
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
            denyLabel: 'Deny',
            busy: actionBusy,
            onApprove: () => onProposal('note', true),
            onDeny: () => onProposal('note', false),
            children: [
              Text('"${parsed.noteText}"',
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
              text: '✗ Suggestion Dismissed', color: NotelColors.error));
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
            denyLabel: 'Deny',
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
              text: '✗ Save Suggestion Dismissed',
              color: NotelColors.error));
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
            denyLabel: 'Deny',
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
                          color: NotelColors.textSecondary)),
                ),
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ List Created Successfully',
              color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ List Suggestion Dismissed',
              color: NotelColors.error));
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
            denyLabel: 'Deny',
            busy: actionBusy,
            onApprove: () => onProposal('reminder', true),
            onDeny: () => onProposal('reminder', false),
            children: [
              Text(parsed.reminderTitle!,
                  style: const TextStyle(
                      fontSize: 15,
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
              text: '✗ Reminder Dismissed', color: NotelColors.error));
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
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
              if ((parsed.calendarDate ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('📅 ${parsed.calendarDate}',
                    style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary)),
              ],
              if ((parsed.calendarTime ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('🕐 ${parsed.calendarTime}',
                    style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary)),
              ],
              if ((parsed.calendarDesc ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(parsed.calendarDesc!,
                    style: const TextStyle(
                        fontSize: 12,
                        color: NotelColors.textSecondary)),
              ],
              const SizedBox(height: 12),
              const Text(
                "If you want changes, type them in the chat. I'll update the proposal and ask for your approval again.",
                style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    color: NotelColors.textSecondary),
              ),
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Event Scheduled & Added to Calendar',
              color: NotelColors.success));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Event Dismissed', color: NotelColors.error));
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
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary)),
              if ((parsed.calendarDeleteDate ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Scheduled for: ${parsed.calendarDeleteDate}',
                    style: const TextStyle(
                        fontSize: 13,
                        color: NotelColors.textSecondary)),
              ],
            ],
          ));
        case CoachProposalStatus.approved:
          addCard(const _ProposalBadge(
              text: '✓ Event Deleted from Calendar',
              color: NotelColors.error));
        case CoachProposalStatus.denied:
          addCard(const _ProposalBadge(
              text: '✗ Deletion Dismissed',
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
              for (final med in parsed.medications) ...[
                Text(med.name,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.textPrimary)),
                Text(
                  med.isPresent
                      ? 'Started: ${med.startDate} • Present'
                      : 'Started: ${med.startDate} • Ended: ${med.endDate}',
                  style: const TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary),
                ),
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
          addCard(const _ProposalBadge(
              text: '✗ Suggestion Dismissed',
              color: NotelColors.textSecondary));
        case CoachProposalStatus.none:
          break;
      }
    }

    return out;
  }
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
    this.titleColor = NotelColors.primary,
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
      padding: const EdgeInsets.all(14),
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
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
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
                    foregroundColor: NotelColors.error,
                    side: BorderSide(
                        color: NotelColors.error.withValues(alpha: 0.4)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(denyLabel,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
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
                          fontSize: 12, fontWeight: FontWeight.bold)),
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
                  hintText: 'Ask Coach anything...',
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
