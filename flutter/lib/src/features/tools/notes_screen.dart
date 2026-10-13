import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 48 — Notes tool screen, FULL read/write port of native
/// `ui/screen/NotesScreen.kt` + `NotesViewModel.kt`.
///
/// REAL DATA SOURCE (fixed round 18b): the native app does NOT store
/// notes as log entries. Notes live in the `"__user_notes__"`
/// pseudo-list inside the profile `userLists` blob (each item a
/// string `"title_||_body_||_timestampMs"`), pushed whole via
/// `POST /api/sync/profile` (`SyncManager.pushProfileData`).
///
/// - Actions (native parity): add a note (title optional + body,
///   from the compose card at the top), edit a note (tap a card →
///   native's edit dialog; the original timestamp is preserved),
///   delete a note (the card's ✕, immediate like native).
/// - Item parse mirrors native: 3 parts → (title, body, timestamp);
///   2 parts → ("New Note", parts[0], parts[1] as timestamp);
///   otherwise ("New Note", whole text, no timestamp). Sorted by
///   timestamp descending, untimestamped last (native sorts by local
///   id descending = newest first; the blob has no ids). Round 48
///   fix: a TITLE-ONLY note (native allows adding one) now renders —
///   previously an empty body dropped the note entirely.
/// - Writes follow the identity-safe full-list rule: re-pull the
///   freshest profile (cache invalidated first), splice into the RAW
///   rows — every other list, pseudo-list row, and unknown key
///   preserved verbatim — then push the complete blob. Each note
///   carries its raw (row index, item index, exact stored string);
///   a splice whose target no longer matches aborts with a visible
///   error instead of touching the wrong note. Failed pushes show
///   an error and reload from the server.
///
/// [parseUserNotes], [formatNoteDate], and the `notesWith*` splice
/// helpers are pure and unit-tested.

/// One rendered note row, parsed from a `__user_notes__` list item.
class NoteEntry {
  final String title;
  final String text;
  final int? timestampMs;

  /// Identity of the stored item inside the raw `userLists` rows:
  /// the row index, the item's index within that row, and the exact
  /// stored string. -1 / '' when parsed from a decoded view without
  /// raw identity (display-only callers).
  final int listRowIndex;
  final int itemIndex;
  final String rawText;

  const NoteEntry({
    required this.title,
    required this.text,
    required this.timestampMs,
    this.listRowIndex = -1,
    this.itemIndex = -1,
    this.rawText = '',
  });
}

/// The pseudo-list name the native app uses for real user notes
/// (native `NotesViewModel`).
const String userNotesListName = '__user_notes__';

/// The field separator inside a stored note item (native format).
const String noteFieldSeparator = '_||_';

/// Parses a stored timestamp field tolerantly: epoch-ms integer
/// (native), numeric string, or ISO-8601 string. Null when
/// unparseable.
int? parseNoteTimestamp(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final asInt = int.tryParse(trimmed);
  if (asInt != null) return asInt;
  final asDouble = double.tryParse(trimmed);
  if (asDouble != null) return asDouble.toInt();
  return DateTime.tryParse(trimmed)?.millisecondsSinceEpoch;
}

/// Builds the stored item string for a note, exactly like native
/// `NotesViewModel`: blank title becomes "New Note", the body is
/// trimmed, and [timestampMs] is the note's creation time (edits
/// preserve the original).
String encodeNoteItem(String title, String body, int timestampMs) {
  final finalTitle = title.trim().isEmpty ? 'New Note' : title.trim();
  return '$finalTitle$noteFieldSeparator${body.trim()}'
      '$noteFieldSeparator$timestampMs';
}

/// Parses one raw item list into displayable [NoteEntry]s (unsorted).
List<NoteEntry> _parseNoteItems(
    List<dynamic> rawItems, int listRowIndex) {
  final out = <NoteEntry>[];
  for (var itemIndex = 0; itemIndex < rawItems.length; itemIndex++) {
    final text = '${rawItems[itemIndex]}'.trim();
    if (text.isEmpty) continue;
    final parts = text.split(noteFieldSeparator);
    final String title;
    final String body;
    final int? ts;
    if (parts.length == 3) {
      title = parts[0].trim().isEmpty ? 'New Note' : parts[0].trim();
      body = parts[1].trim();
      ts = parseNoteTimestamp(parts[2]);
    } else if (parts.length == 2) {
      title = 'New Note';
      body = parts[0].trim();
      ts = parseNoteTimestamp(parts[1]);
    } else {
      title = 'New Note';
      body = text;
      ts = null;
    }
    // Nothing honest to show only when there is neither a real
    // title nor a body (e.g. "_||__||_123"). A title-only note —
    // which native can create — renders with an empty body.
    if (body.isEmpty && title == 'New Note') continue;
    out.add(NoteEntry(
      title: title,
      text: body,
      timestampMs: ts != null && ts > 0 ? ts : null,
      listRowIndex: listRowIndex,
      itemIndex: itemIndex,
      rawText: '${rawItems[itemIndex]}',
    ));
  }
  return out;
}

int _noteSortCompare(NoteEntry a, NoteEntry b) {
  final ta = a.timestampMs ?? -1;
  final tb = b.timestampMs ?? -1;
  final byTime = tb.compareTo(ta);
  if (byTime != 0) return byTime;
  // Deterministic tie-break on storage position (List.sort is not
  // stable): later-stored notes first, matching native's
  // id-descending order as closely as the blob allows.
  final byRow = b.listRowIndex.compareTo(a.listRowIndex);
  if (byRow != 0) return byRow;
  return b.itemIndex.compareTo(a.itemIndex);
}

/// Parses every `"__user_notes__"` list in the decoded `userLists`
/// blob into displayable [NoteEntry]s, newest first. Items that are
/// blank after parsing are dropped; malformed rows are skipped.
/// Never throws.
List<NoteEntry> parseUserNotes(List<Map<String, dynamic>> decoded) {
  final out = <NoteEntry>[];
  for (var rowIndex = 0; rowIndex < decoded.length; rowIndex++) {
    final list = decoded[rowIndex];
    if ('${list['name'] ?? ''}' != userNotesListName) continue;
    final rawItems = list['items'];
    if (rawItems is! List) continue;
    out.addAll(_parseNoteItems(rawItems, rowIndex));
  }
  out.sort(_noteSortCompare);
  return out;
}

/// Decodes the raw `userLists` profile value into its raw JSON rows,
/// preserving every row (and every key inside a row) exactly as
/// stored, so a later full-blob push never drops data. Tolerates a
/// JSON string (including double-encoded), an already-decoded list,
/// a single map, and garbage (→ empty). Never throws.
List<dynamic> decodeUserListsRaw(dynamic raw) {
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

/// Parses notes directly from RAW `userLists` rows (see
/// [decodeUserListsRaw]), keeping each note's raw identity for
/// edit/delete splices. Newest first. Never throws.
List<NoteEntry> parseUserNotesFromRaw(List<dynamic> rows) {
  final out = <NoteEntry>[];
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    final row = rows[rowIndex];
    if (row is! Map) continue;
    if ('${row['name'] ?? ''}' != userNotesListName) continue;
    final rawItems = row['items'];
    if (rawItems is! List) continue;
    out.addAll(_parseNoteItems(rawItems, rowIndex));
  }
  out.sort(_noteSortCompare);
  return out;
}

/// The raw item values of a raw row (unmodified, any JSON type).
List<dynamic> _rawRowItems(dynamic row) {
  if (row is Map) {
    final items = row['items'];
    if (items is List) return List<dynamic>.of(items);
  }
  return const [];
}

/// Returns a copy of [row] with its items replaced, preserving every
/// other key the server stored on the row.
dynamic _rowWithItems(dynamic row, List<dynamic> items) {
  if (row is Map) {
    final copy = <String, dynamic>{};
    row.forEach((k, v) => copy['$k'] = v);
    copy['items'] = items;
    return copy;
  }
  return <String, dynamic>{'name': userNotesListName, 'items': items};
}

int? _firstNotesRowIndex(List<dynamic> rows) {
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row is Map && '${row['name'] ?? ''}' == userNotesListName) {
      return i;
    }
  }
  return null;
}

/// Locates the item [note] refers to inside fresh rows: the stored
/// position is trusted only when the exact raw string still matches
/// there (or elsewhere in the SAME pseudo-list row); otherwise a
/// unique exact match across all pseudo-list rows wins; anything
/// else returns null so the caller aborts instead of touching the
/// wrong note.
(int, int)? _locateNote(List<dynamic> rows, NoteEntry note) {
  if (note.listRowIndex >= 0 && note.listRowIndex < rows.length) {
    final items = _rawRowItems(rows[note.listRowIndex]);
    if (note.itemIndex >= 0 &&
        note.itemIndex < items.length &&
        '${items[note.itemIndex]}' == note.rawText) {
      return (note.listRowIndex, note.itemIndex);
    }
    for (var i = 0; i < items.length; i++) {
      if ('${items[i]}' == note.rawText) return (note.listRowIndex, i);
    }
  }
  final matches = <(int, int)>[];
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    if (row is! Map || '${row['name'] ?? ''}' != userNotesListName) {
      continue;
    }
    final items = _rawRowItems(row);
    for (var i = 0; i < items.length; i++) {
      if ('${items[i]}' == note.rawText) matches.add((r, i));
    }
  }
  return matches.length == 1 ? matches.single : null;
}

/// Splice: append a new note (native `addNote`). The note lands in
/// the FIRST `__user_notes__` row (native's repository lookup), or a
/// new pseudo-list row is appended when none exists. Null when both
/// title and body are blank (native refuses).
List<dynamic>? notesWithAddedNote(
    List<dynamic> rows, String title, String body, int nowMs) {
  if (title.trim().isEmpty && body.trim().isEmpty) return null;
  final item = encodeNoteItem(title, body, nowMs);
  final rowIndex = _firstNotesRowIndex(rows);
  if (rowIndex == null) {
    return [
      ...rows,
      <String, dynamic>{
        'name': userNotesListName,
        'items': [item],
      },
    ];
  }
  final items = _rawRowItems(rows[rowIndex])..add(item);
  final out = List<dynamic>.of(rows);
  out[rowIndex] = _rowWithItems(rows[rowIndex], items);
  return out;
}

/// Splice: replace a note's stored string with an edit that
/// preserves the note's ORIGINAL timestamp (native `editNote`).
/// Null when the note cannot be identified with certainty.
List<dynamic>? notesWithEditedNote(List<dynamic> rows, NoteEntry note,
    String newTitle, String newBody, int nowMs) {
  final at = _locateNote(rows, note);
  if (at == null) return null;
  final (rowIndex, itemIndex) = at;
  // Preserve the original creation time like native: from the
  // stored string's timestamp field (3-part or 2-part shape).
  var ts = note.timestampMs;
  if (ts == null) {
    final parts = note.rawText.split(noteFieldSeparator);
    if (parts.length == 3) ts = parseNoteTimestamp(parts[2]);
    if (parts.length == 2) ts = parseNoteTimestamp(parts[1]);
  }
  final items = _rawRowItems(rows[rowIndex]);
  items[itemIndex] = encodeNoteItem(newTitle, newBody, ts ?? nowMs);
  final out = List<dynamic>.of(rows);
  out[rowIndex] = _rowWithItems(rows[rowIndex], items);
  return out;
}

/// Splice: remove a note (native `deleteNote`). Null when the note
/// cannot be identified with certainty.
List<dynamic>? notesWithoutNote(List<dynamic> rows, NoteEntry note) {
  final at = _locateNote(rows, note);
  if (at == null) return null;
  final (rowIndex, itemIndex) = at;
  final items = _rawRowItems(rows[rowIndex])..removeAt(itemIndex);
  final out = List<dynamic>.of(rows);
  out[rowIndex] = _rowWithItems(rows[rowIndex], items);
  return out;
}

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Native `SimpleDateFormat("MMM d, yyyy h:mm a")`, device-local, no intl
/// dependency in the Flutter module.
String formatNoteDate(int timestampMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final amPm = d.hour < 12 ? 'AM' : 'PM';
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${_monthNames[d.month - 1]} ${d.day}, ${d.year} '
      '$h12:${d.minute.toString().padLeft(2, '0')} $amPm';
}

/// Round 48 — full Notes screen (see file header).
///
/// [backend] is injectable so widget tests can drive the screen with
/// a mock client; production defaults to a real [TabsBackend].
class NotesScreen extends StatefulWidget {
  final TabsBackend? backend;

  const NotesScreen({super.key, this.backend});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  late final TabsBackend _backend;
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();
  bool _loading = true;
  bool _failed = false;
  bool _loadFailed = false; // profile itself was null (auth/network)
  bool _writing = false;
  List<dynamic> _rows = const [];

  List<NoteEntry> get _notes => parseUserNotesFromRaw(_rows);
  bool get _canAdd =>
      _titleController.text.trim().isNotEmpty ||
      _bodyController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _titleController.addListener(_onComposeChanged);
    _bodyController.addListener(_onComposeChanged);
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _onComposeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
      _loadFailed = false;
    });
    try {
      final profile = await _backend.fetchProfile();
      if (!mounted) return;
      if (profile == null) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        return;
      }
      // Real notes live in the "__user_notes__" pseudo-list(s) of the
      // userLists blob — never in sync-pull log entries.
      setState(() {
        _rows = decodeUserListsRaw(profile['userLists']);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _showSaveError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Could not save that change. Check your connection and try again.')));
  }

  /// Identity-safe write: re-pull the freshest blob, splice the
  /// change into it, push the WHOLE blob back. On any failure the
  /// error is shown and the screen reloads from the server.
  Future<bool> _mutate(
      List<dynamic>? Function(List<dynamic> freshRows) splice) async {
    if (_writing) return false;
    setState(() => _writing = true);
    try {
      _backend.invalidateSyncPull();
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        _showSaveError();
        await _load();
        return false;
      }
      final fresh = decodeUserListsRaw(profile['userLists']);
      final next = splice(fresh);
      if (next == null) {
        _showSaveError();
        if (mounted) setState(() => _rows = fresh);
        return false;
      }
      final ok = await _backend
          .postSyncProfile({'userLists': jsonEncode(next)});
      if (!mounted) return false;
      if (ok) {
        _backend.invalidateSyncPull();
        setState(() => _rows = next);
        return true;
      }
      _showSaveError();
      await _load();
      return false;
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _addNote() async {
    final title = _titleController.text;
    final body = _bodyController.text;
    if (title.trim().isEmpty && body.trim().isEmpty) return;
    final ok = await _mutate((fresh) => notesWithAddedNote(
        fresh, title, body, DateTime.now().millisecondsSinceEpoch));
    if (ok && mounted) {
      _titleController.clear();
      _bodyController.clear();
    }
  }

  Future<void> _showEditDialog(NoteEntry note) async {
    final titleController = TextEditingController(
        // Native pre-fills a blank title for legacy notes whose
        // stored title is the placeholder.
        text: note.title == 'New Note' && note.rawText.split(noteFieldSeparator).length < 3
            ? ''
            : note.title);
    final bodyController = TextEditingController(text: note.text);
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Edit Note',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: NotelColors.textPrimary),
              decoration: const InputDecoration(
                hintText: 'Title (optional)...',
                hintStyle: TextStyle(color: NotelColors.textSecondary),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bodyController,
              textCapitalization: TextCapitalization.sentences,
              maxLines: 6,
              style: const TextStyle(color: NotelColors.textPrimary),
              decoration: const InputDecoration(
                hintText: 'Note content...',
                hintStyle: TextStyle(color: NotelColors.textSecondary),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext)
                .pop((titleController.text, bodyController.text)),
            style: FilledButton.styleFrom(
                backgroundColor: NotelColors.primary),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    titleController.dispose();
    bodyController.dispose();
    if (result == null || !mounted) return;
    await _mutate((fresh) => notesWithEditedNote(fresh, note, result.$1,
        result.$2, DateTime.now().millisecondsSinceEpoch));
  }

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
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Notes',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: NotelColors.primary),
      );
    }
    if (_failed || _loadFailed) {
      return _failureState();
    }
    final notes = _notes;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _composeCard(),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: notes.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('📝', style: TextStyle(fontSize: 48)),
                      SizedBox(height: 12),
                      Text(
                        'No notes yet',
                        style: TextStyle(
                          color: NotelColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Write your first note above',
                        style: TextStyle(
                          color: NotelColors.textSecondary,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  itemCount: notes.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _noteCard(notes[i]),
                ),
        ),
      ],
    );
  }

  /// Native compose card: optional title, body, round add button
  /// (enabled when either field has text, exactly like native).
  Widget _composeCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: NotelColors.surfaceHigh.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white.withValues(alpha: 0.03)),
      ),
      child: Column(
        children: [
          TextField(
            controller: _titleController,
            enabled: !_writing,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(
                color: NotelColors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'Title (optional)...',
              hintStyle:
                  TextStyle(color: NotelColors.textSecondary, fontSize: 14),
              border: InputBorder.none,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _bodyController,
                  enabled: !_writing,
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 4,
                  style: const TextStyle(
                      color: NotelColors.textPrimary, fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: 'Write a note...',
                    hintStyle: TextStyle(
                        color: NotelColors.textSecondary, fontSize: 14),
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: (_canAdd && !_writing) ? _addNote : null,
                style: FilledButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  disabledBackgroundColor:
                      NotelColors.surfaceHigh.withValues(alpha: 0.3),
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(11),
                ),
                child: const Icon(Icons.add,
                    size: 20, semanticLabel: 'Add Note'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _failureState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📝', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            const Text(
              'Couldn\'t load notes',
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Check your connection and try again.',
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _load,
              style: FilledButton.styleFrom(
                  backgroundColor: NotelColors.primary),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noteCard(NoteEntry note) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: NotelColors.surfaceHigh.withValues(alpha: 0.08),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _writing ? null : () => _showEditDialog(note),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title,
                      style: const TextStyle(
                        color: NotelColors.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      note.text,
                      style: const TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 13,
                        height: 18 / 13,
                      ),
                    ),
                    if (note.timestampMs != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        formatNoteDate(note.timestampMs!),
                        style: TextStyle(
                          color: NotelColors.textSecondary
                              .withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.close,
                    size: 14,
                    color:
                        NotelColors.textSecondary.withValues(alpha: 0.4),
                    semanticLabel: 'Delete Note'),
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
                onPressed: _writing
                    ? null
                    : () => _mutate(
                        (fresh) => notesWithoutNote(fresh, note)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
