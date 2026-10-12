import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18b — Notes tool screen, DISPLAY-ONLY.
///
/// REAL DATA SOURCE (fixed round 18b): the native app does NOT store notes
/// as log entries. Per native `NotesViewModel`, notes live in the
/// `"__user_notes__"` pseudo-list inside the profile `userLists` blob
/// (each item a string `"title_||_body_||_timestampMs"`). Round 18 wrongly
/// wired this screen to sync-pull `entries` (log entries) — the founder
/// reported "My notes are just showing all my logs."
///
/// - Data: `TabsBackend.fetchProfile()['userLists']` via
///   `TabsBackend.decodeProfileList`, keeping every list named
///   `"__user_notes__"` (the account can hold more than one; items from
///   all of them are merged).
/// - Item parse mirrors native `NotesScreen.kt`: 3 parts →
///   (title, body, timestamp); 2 parts → ("New Note", parts[0],
///   parts[1] as timestamp); otherwise ("New Note", whole text, no
///   timestamp). Native sorts by id descending (newest first); the blob
///   has no ids, so we sort by timestamp descending, untimestamped last.
/// - DEFERRED (later round): adding, editing, and deleting notes.
///
/// [parseUserNotes] and [formatNoteDate] are pure and unit-tested.

/// One rendered note row, parsed from a `__user_notes__` list item.
class NoteEntry {
  final String title;
  final String text;
  final int? timestampMs;

  const NoteEntry({
    required this.title,
    required this.text,
    required this.timestampMs,
  });
}

/// The pseudo-list name the native app uses for real user notes
/// (native `NotesViewModel`).
const String userNotesListName = '__user_notes__';

/// Parses every `"__user_notes__"` list in the decoded `userLists` blob
/// into displayable [NoteEntry]s, newest first. Items that are blank
/// after parsing are dropped; malformed rows are skipped. Never throws.
List<NoteEntry> parseUserNotes(List<Map<String, dynamic>> decoded) {
  final out = <NoteEntry>[];
  for (final list in decoded) {
    if ('${list['name'] ?? ''}' != userNotesListName) continue;
    final rawItems = list['items'];
    if (rawItems is! List) continue;
    for (final item in rawItems) {
      final text = '$item'.trim();
      if (text.isEmpty) continue;
      final parts = text.split('_||_');
      final String title;
      final String body;
      final int? ts;
      if (parts.length == 3) {
        title = parts[0].trim().isEmpty ? 'New Note' : parts[0].trim();
        body = parts[1].trim();
        ts = int.tryParse(parts[2].trim());
      } else if (parts.length == 2) {
        title = 'New Note';
        body = parts[0].trim();
        ts = int.tryParse(parts[1].trim());
      } else {
        title = 'New Note';
        body = text;
        ts = null;
      }
      if (body.isEmpty) continue; // no body → nothing honest to show
      out.add(NoteEntry(
        title: title,
        text: body,
        timestampMs: ts != null && ts > 0 ? ts : null,
      ));
    }
  }
  // Newest first; entries without a timestamp sink to the end.
  out.sort((a, b) {
    final ta = a.timestampMs ?? -1;
    final tb = b.timestampMs ?? -1;
    return tb.compareTo(ta);
  });
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

/// Round 18 — display-only Notes screen.
///
/// [backend] is injectable so widget tests can drive the screen with a
/// mock client; production defaults to a real [TabsBackend].
class NotesScreen extends StatefulWidget {
  final TabsBackend? backend;

  const NotesScreen({super.key, this.backend});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  late final TabsBackend _backend;
  bool _loading = true;
  bool _failed = false;
  bool _loadFailed = false; // sync pull itself was null (auth/network)
  List<NoteEntry> _notes = const [];

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
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
      final decoded =
          TabsBackend.decodeProfileList(profile['userLists']);
      setState(() {
        _notes = parseUserNotes(decoded);
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
    if (_notes.isEmpty) {
      return const Center(
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
              'Your notes will appear here.',
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: _notes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _noteCard(_notes[i]),
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
      padding: const EdgeInsets.symmetric(
          horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: NotelColors.surfaceHigh.withValues(alpha: 0.08),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
        ),
      ),
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
    );
  }
}
