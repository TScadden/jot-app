import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 — Notes tool screen, DISPLAY-ONLY. Layout follows native
/// `ui/screen/NotesScreen.kt`'s note cards (purple 14sp bold title, 13sp
/// body, 11sp secondary date, 14dp rounded cards).
///
/// - Data: `/api/sync/pull` `entries` via `TabsBackend.fetchSyncPull()`.
///   Each entry follows native `LogEntryDtoModel`
///   (`{id, categoryId, body, chips, manualText, timestamp, updatedAt}`).
/// - Title: the entry's category name from the sync pull's `categories`
///   map (real data), falling back to `"Note"` only when the category is
///   unknown — no invented titles.
/// - Text: `body` plus `manualText` joined with a blank line, mirroring
///   native `EntryDetailScreen`'s display of the same fields. Entries with
///   no text at all are skipped rather than rendered as blank cards.
/// - Newest first; dates render "MMM d, yyyy h:mm a" like native.
/// - DEFERRED (later round): adding, editing, and deleting notes. The
///   native add-note input area, edit dialog, and ✕ delete affordance
///   are omitted; cards are read-only.
///
/// [parseNoteEntries] and [formatNoteDate] are pure and unit-tested.

/// One rendered note row, parsed from a sync-pull entry map.
class NoteEntry {
  final String title; // category name, or "Note" when unknown
  final String text; // body + manualText
  final int? timestampMs;

  const NoteEntry({
    required this.title,
    required this.text,
    required this.timestampMs,
  });
}

/// Parses sync-pull `entries` into displayable [NoteEntry]s (newest
/// first). Blank entries (no body and no manualText) are dropped;
/// malformed rows are skipped. Never throws.
List<NoteEntry> parseNoteEntries(Map<String, dynamic>? body) {
  final categories = <String, String>{};
  final rawCategories = body?['categories'];
  if (rawCategories is Map) {
    rawCategories.forEach((k, v) {
      categories['$k'] = '$v';
    });
  }
  final rawEntries = body?['entries'];
  if (rawEntries is! List) return const [];
  final out = <NoteEntry>[];
  for (final e in rawEntries) {
    if (e is! Map<String, dynamic>) continue;
    final bodyText = '${e['body'] ?? ''}'.trim();
    final manualText = '${e['manualText'] ?? ''}'.trim();
    final text = manualText.isNotEmpty
        ? (bodyText.isNotEmpty ? '$bodyText\n\n$manualText' : manualText)
        : bodyText;
    if (text.isEmpty) continue; // no text → nothing honest to show
    final categoryId = '${e['categoryId'] ?? ''}';
    final title =
        categories[categoryId]?.trim().isNotEmpty == true
            ? categories[categoryId]!.trim()
            : 'Note';
    final ts = _asInt(e['timestamp']);
    out.add(NoteEntry(
      title: title,
      text: text,
      timestampMs: ts != null && ts > 0 ? ts : null,
    ));
  }
  // Newest first; entries without a timestamp sink to the end.
  out.sort((a, b) {
    final ta = a.timestampMs ?? -1;
    final tb = b.timestampMs ?? -1;
    return tb.compareTo(ta);
  });
  return out;
}

int? _asInt(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
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
      final body = await _backend.fetchSyncPull();
      if (!mounted) return;
      if (body == null) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        return;
      }
      setState(() {
        _notes = parseNoteEntries(body);
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
