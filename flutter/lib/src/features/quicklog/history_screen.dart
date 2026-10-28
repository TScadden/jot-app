import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/intake_logging.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

// ── Round 42 — entry editing (pure helpers, ports of native
// `EntryDetailViewModel` in EntryDetailScreen.kt) ────────────────────

/// Parses an entry's chips JSON-array string into labels. Tolerant,
/// never throws: malformed payloads render as NO chips (native decodes
/// `List<String>` and falls back to `emptyList()` on error). Raw JSON
/// is never rendered to a screen.
List<String> parseEntryChips(String chipsJson) {
  final raw = chipsJson.trim();
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.map((c) => '$c').where((c) => c.isNotEmpty).toList();
    }
  } catch (_) {
    // Fall through: malformed chips are no chips.
  }
  return const [];
}

/// Native detail body display + edit-field initial value:
/// `body + "\n\n" + manualText` when manualText is non-blank, else body.
///
/// Phase 1 item 4 guard: an Intake-tagged entry's manualText is a
/// structured JSON payload, never user copy — it displays BODY ONLY,
/// so the payload can never render on screen.
String entryCombinedText(QuickLogEntry entry) => isIntakeEntry(entry)
    ? entry.body
    : entry.manualText.isNotBlank
        ? '${entry.body}\n\n${entry.manualText}'
        : entry.body;

/// Native `updateText(body, "")`: the edited combined text becomes the
/// body and manualText is cleared. Same id/timestamp/chips/category.
///
/// Intake-tagged entries never reach this helper from the UI (their
/// text-edit affordance routes to the intake editor sheet, which
/// rewrites body + payload together — see _EntryDetailDialogState).
QuickLogEntry editedEntryText(QuickLogEntry entry, String newText) =>
    entry.copyWith(body: newText, manualText: '');

/// Native `updateCategory(categoryId)`: sets the category AND replaces
/// the chips with a JSON array holding exactly the new category name
/// (`JSONArray(listOf(catName))`), or `[]` when the name is blank.
/// Same id/timestamp/body/manualText.
///
/// Phase 1 item 4 guard: for an Intake-tagged entry a category
/// change preserves the entry's chips (the reserved tag + kind) —
/// ONLY the categoryId changes, or the entry would silently stop
/// being an intake record.
QuickLogEntry editedEntryCategory(
  QuickLogEntry entry,
  QuickLogCategory category,
) {
  if (isIntakeEntry(entry)) {
    return entry.copyWith(categoryId: category.id);
  }
  final chips =
      category.name.trim().isEmpty ? '[]' : jsonEncode([category.name]);
  return entry.copyWith(categoryId: category.id, chips: chips);
}

/// Native picker order: `CategoryDao.getAllCategories()` is
/// `ORDER BY sortOrder ASC`. Input is the account's REAL categories
/// from the sync pull — never hardcoded.
List<QuickLogCategory> sortedCategoriesForPicker(
  List<QuickLogCategory> categories,
) {
  final sorted = categories.toList();
  sorted.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return sorted;
}

/// Locked check-in detection (Round 21 identity — the sync DTO has no
/// `source` field): the entry sits in the resolved Mood & Energy
/// category AND carries the reserved "Daily Ranking" chip. Native
/// locks by `source == "Energy check-in"` regardless of date, so this
/// identity check carries no date window either — the [04:00, +1d)
/// energy-day window in [hasFeelingCheckIn] only decides whether
/// TODAY already has a check-in, not whether an entry IS one.
bool isLockedCheckInEntry(
  QuickLogEntry entry,
  List<QuickLogCategory> categories,
) {
  final moodId = resolveFeelingCategoryId(categories);
  if (moodId == null || entry.categoryId != moodId) return false;
  return chipsContainFeelingTag(entry.chips);
}

/// Native category-change guard for medication entries:
/// `source == "Medications Tab" || chips.contains("Medication Tab")`.
/// The sync DTO carries no source, so the chips half is what Flutter
/// can check. Text editing stays allowed for these entries (native
/// `updateText` has no medication guard).
bool isMedicationTabEntry(QuickLogEntry entry) =>
    entry.chips.contains('Medication Tab');

extension _StringNotBlank on String {
  bool get isNotBlank => trim().isNotEmpty;
}

/// The ONE per-entry sync badge state model, shared by the
/// History cards and Quick Log's recent-suggestion chips (F5):
/// the states and copy live here only, so the two surfaces can
/// never diverge. A row with no outbox record AFTER the outbox's
/// disk load has landed came from (or has since been confirmed by)
/// the server pull: Synced. A staged row reads Syncing while its
/// push is pending and Not synced after a failed push. Before the
/// load lands, a row's state is genuinely unknown — a record
/// staged by a previous session may sit on disk unseen — so it
/// reads Syncing (unconfirmed), never Synced; the load's
/// completion notification corrects it immediately.
class LogEntrySyncBadge extends StatelessWidget {
  final LogEntryOutbox outbox;
  final int entryId;

  const LogEntrySyncBadge({
    super.key,
    required this.outbox,
    required this.entryId,
  });

  @override
  Widget build(BuildContext context) {
    final status = outbox.statusFor(entryId);
    final (icon, label, color) = switch (status) {
      LogEntrySyncStatus.failed => (
          Icons.cloud_off,
          'Not synced',
          NotelColors.error,
        ),
      LogEntrySyncStatus.pending => (
          Icons.cloud_upload,
          'Syncing',
          NotelColors.primary,
        ),
      null when !outbox.isLoaded => (
          Icons.cloud_upload,
          'Syncing',
          NotelColors.primary,
        ),
      null => (Icons.cloud_done, 'Synced', NotelColors.primary),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Round 19 — the History view (clock-arrow icon on Quick Log). A
/// faithful Flutter port of native `HistoryScreen.kt` +
/// `HistoryViewModel.kt`, plus the founder addendum: the circular-arrow
/// button moved here from the Quick Log input row.
///
/// Round 19b (founder, Oct 12 2026): the AI Insights tab was removed —
/// the backend "insights" payload turned out to be raw biometric JSON
/// blobs rendered as garbage (epoch-0 dates, "Original entry
/// unavailable"). History is LOGS only now, full width, no tab bar.
///
/// What the moved button does (traced from native source):
/// `QuickLogScreen`'s replay icon calls
/// `QuickLogViewModel.repeatLastEntry()` — it takes the single most
/// recent log entry and inserts a DUPLICATE of it (same category, body,
/// chips, new timestamp, source "Repeat Last Entry"). It is NOT an
/// undo/delete. That exact behavior is preserved here.
///
/// Data: the user's REAL history — sync-pull `entries[]` (the same
/// source native syncs into its local DB; his ~580 entries). Native
/// loads the whole list via a Room Flow with NO pagination (LazyColumn
/// renders lazily); this port mirrors that — one pull, full list.
/// Honest empty/error states; never fake entries.
class HistoryScreen extends StatefulWidget {
  final TabsBackend? backend;

  /// Migraine log trio fix 1 (Juno ruling 2026-10-27,
  /// 2026-10-27-migraine-log-trio-juno.md §A condition 3): when
  /// set, once the initial load lands, the entry with this id is
  /// opened in its detail dialog — the Today Summary completion
  /// line's tap lands on THAT entry, not the list top.
  final int? focusEntryId;

  final LogEntryOutbox? outbox;

  const HistoryScreen({
    super.key,
    this.backend,
    this.focusEntryId,
    this.outbox,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  LogEntryOutbox get _outbox => widget.outbox ?? LogEntryOutbox.instance;

  bool _loading = true;
  bool _focusHandled = false;
  String? _loadError;
  List<QuickLogEntry> _entries = const [];

  /// Ids present in the most recent raw server pull, before the
  /// outbox overlay. This is how an edit knows whether its row is a
  /// server-known update or a still-local creation.
  Set<int> _serverEntryIds = const {};
  List<QuickLogCategory> _categories = const [];
  DateTime? _lastSyncAt;

  String _searchQuery = '';
  int? _categoryFilter;
  bool _todayOnly = false;

  static const _chipInk = Color(0xFF0A0A0E); // native LegacyDarkChipInk

  @override
  void initState() {
    super.initState();
    _outbox.addListener(_onOutboxChanged);
    _load();
  }

  @override
  void dispose() {
    _outbox.removeListener(_onOutboxChanged);
    super.dispose();
  }

  /// The outbox is the sync-state source for the cards: a background
  /// push landing (or failing) re-renders the affected badge, and a
  /// row staged elsewhere merges in over the displayed list.
  void _onOutboxChanged() {
    if (!mounted) return;
    setState(() {
      _entries = _outbox.merge(_entries);
    });
  }

  /// Kicks the outbox disk load WITHOUT gating the screen load on
  /// it. Storage reads ride a platform channel whose latency must
  /// never hold the list hostage (the app's caches all load lazily
  /// the same way): [LogEntryOutbox.merge] over a not-yet-loaded
  /// outbox is the identity, and the load's completion notification
  /// re-merges the overlay via [_onOutboxChanged] the moment it
  /// lands — a frame later in the worst case. Until it lands, rows
  /// render the unconfirmed (Syncing) badge rather than borrowing
  /// Synced for a state nobody has verified yet.
  void _primeOutbox() {
    unawaited(() async {
      try {
        await _outbox.load(ownerEmail: await _backend.readEmail());
      } catch (_) {
        try {
          await _outbox.load();
        } catch (_) {}
      }
    }());
  }

  /// Initial load (and retry from the error state).
  ///
  /// Round 19c: the initial open no longer shows a full-screen
  /// spinner either — the body renders a skeleton shaped like the
  /// real history (search field, filter chips, entry cards) while
  /// this runs (see `_buildInitialSkeleton`). `_loading` still means
  /// ONLY "initial load / error retry" — round 19b's mutation paths
  /// (optimistic delete/repeat + quiet `_revalidate()`) never touch
  /// it and are unchanged.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    // Migraine log trio fix 2: the initial load must NOT be served
    // by the 5-minute sync-pull TTL cache — it hid a just-saved
    // migraine entry from the founder (the entry existed; History
    // showed the cached pre-save pull). Invalidate first, exactly
    // as _revalidate() does for post-mutation refreshes.
    _backend.invalidateSyncPull();
    await _fetchIntoState();
  }

  /// Stale-while-revalidate (founder addendum #3, Oct 12 2026).
  ///
  /// ROOT CAUSE of the old "every action reloads the whole screen" bug:
  /// mutations (delete, repeat) and the old manual sync button all
  /// funnelled into `_refresh()`, which called `_load()` — and `_load()`
  /// unconditionally set `_loading = true`, swapping the whole body for
  /// a spinner and refetching everything. Mutations now update
  /// `_entries` locally (optimistically) and this quiet revalidation
  /// merges fresh server state in the background WITHOUT ever touching
  /// `_loading`/`_loadError` — what's on screen stays on screen.
  Future<void> _revalidate() async {
    _backend.invalidateSyncPull();
    await _fetchIntoState(quiet: true, retryPending: false);
  }

  /// Background push + reconcile for staged entries. A successful
  /// flush invalidates the pull (inside the outbox) and revalidates;
  /// a failed flush leaves the rows on screen with their Not synced
  /// badge — never a rollback of a durably saved local change.
  Future<void> _flushOutboxThenRevalidate() async {
    if (!_outbox.hasPending) return;
    final allOk = await _outbox.flush(_backend);
    if (!mounted) return;
    if (allOk) {
      await _revalidate();
    } else {
      setState(() {});
    }
  }

  Future<void> _fetchIntoState({
    bool quiet = false,
    bool retryPending = true,
  }) async {
    _primeOutbox();
    try {
      final pull = await _backend.fetchSyncPull();
      if (!mounted) return;
      if (pull == null) {
        // Quiet failure keeps the displayed data; only the bare
        // initial load surfaces the error screen — and only when
        // there is not even a locally staged entry to show.
        if (!quiet) {
          setState(() {
            _entries = _outbox.merge(_entries);
            _loading = false;
            _loadError = _entries.isEmpty
                ? "Couldn't reach the Tabs server. "
                    'Check your connection and retry.'
                : null;
          });
          unawaited(_outbox.flush(_backend));
        }
        return;
      }
      final serverEntries = _sorted(pull);
      setState(() {
        _serverEntryIds = {for (final e in serverEntries) e.id};
        _entries = _outbox.merge(serverEntries);
        _lastSyncAt = DateTime.now();
        _loading = false;
        _loadError = null;
      });
      // Categories ride the same cached pull (no extra fetch).
      final cats = await _backend.fetchLogCategories();
      if (mounted) {
        setState(() {
          _categories = cats;
        });
      }
      if (!quiet && mounted) _maybeOpenFocusedEntry();
      // History opening is a normal sync trigger: rows staged by an
      // earlier session (including one killed before its push) retry
      // here, behind the already-rendered list.
      if (retryPending && mounted) {
        unawaited(_flushOutboxThenRevalidate());
      }
    } catch (e) {
      if (!mounted) return;
      if (!quiet) {
        setState(() {
          _loading = false;
          _loadError = 'Something went wrong loading history: $e';
        });
      }
      // Quiet failure: keep what's on screen; the next action retries.
    }
  }

  /// Fix 1 focus: open the focused entry's detail dialog exactly
  /// once, after the initial load (entries AND categories) is in
  /// state, so the dialog titles itself with the real category.
  /// Absent entry → nothing opens; the list stands as-is.
  void _maybeOpenFocusedEntry() {
    final focusId = widget.focusEntryId;
    if (focusId == null || _focusHandled) return;
    _focusHandled = true;
    final entry = _entries.where((e) => e.id == focusId).firstOrNull;
    if (entry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showEntryDetail(entry);
    });
  }

  List<QuickLogEntry> _sorted(Map<String, dynamic> pull) {
    final raw = pull['entries'];
    final out = <QuickLogEntry>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          try {
            out.add(QuickLogEntry.fromJson(e));
          } catch (_) {}
        }
      }
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  List<QuickLogEntry> get _filtered {
    var list = _entries;
    if (_todayOnly) {
      final now = DateTime.now();
      final midnight = DateTime(
        now.year,
        now.month,
        now.day,
      ).millisecondsSinceEpoch;
      list = list.where((e) => e.timestamp >= midnight).toList();
    }
    if (_categoryFilter != null) {
      list = list.where((e) => e.categoryId == _categoryFilter).toList();
    }
    final q = _searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((e) => e.body.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  /// F1: the id is allocated by the outbox AFTER its disk load
  /// settles (see [LogEntryOutbox.allocateEntryId]) — never
  /// synchronously from a possibly-unloaded [LogEntryOutbox.maxId],
  /// which could hand a killed session's pending id to a new entry
  /// and let stage() overwrite the pending record.
  Future<int> _nextEntryId() {
    var serverMaxId = 0;
    for (final e in _entries) {
      if (e.id > serverMaxId) serverMaxId = e.id;
    }
    return _outbox.allocateEntryIdForBackend(
      backend: _backend,
      serverMaxId: serverMaxId,
    );
  }

  /// The moved circular-arrow button: native `repeatLastEntry()`
  /// behavior, preserved exactly — duplicate the most recent entry.
  Future<void> _repeatLastEntry() async {
    if (_entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No entries yet to repeat.')),
      );
      return;
    }
    final last = _entries.first; // server orders timestamp DESC
    final dupe = QuickLogEntry(
      id: await _nextEntryId(),
      categoryId: last.categoryId,
      body: last.body,
      chips: last.chips,
      manualText: last.manualText,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    // Local-first: the duplicate is staged durably, appears at the
    // top immediately (its timestamp is now, and the list is
    // timestamp-DESC), and pushes in the background. A failed push
    // keeps it visible with a Not synced badge — no rollback of a
    // saved local entry.
    final staged = await _outbox.stageForBackend(
      dupe,
      backend: _backend,
      serverKnown: false,
    );
    if (!mounted) return;
    if (!staged) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't repeat that entry — try again."),
        ),
      );
      return;
    }
    setState(() => _entries = _outbox.merge([dupe, ..._entries]));
    final today = todayEntryCount(_entries);
    // Round 59: a repeated entry is an entry creation — mirror
    // the new today count into the Home snapshot + widget, same
    // as the Quick Log save path.
    _syncHomeEntryCount(today);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Last entry repeated · $today today')),
    );
    unawaited(_flushOutboxThenRevalidate());
  }

  /// Round 59 — entry creation/deletion here changes today's count,
  /// which the Home strip + home-screen widget render from
  /// [HomeDataCache]. Mirror + persist (persist pushes the widget),
  /// exactly as the Quick Log save path does. Fire-and-forget;
  /// neither call can throw.
  void _syncHomeEntryCount(int todayCount) {
    HomeDataCache.instance.applyLogCountToday(todayCount);
    unawaited(HomeDataCache.instance.persist());
  }

  Future<void> _deleteEntry(QuickLogEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete entry?',
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: const Text(
          'This cannot be undone.',
          style: TextStyle(color: NotelColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: NotelColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: NotelColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // In-flight interplay: a push already on the wire may be
    // carrying this very row. Deleting underneath it would let the
    // push resurrect the row server-side after the delete (a
    // local-only create would land as a brand-new row; a server
    // DELETE could land first and the upsert recreate the row).
    // So: mark the row deleting (pushes starting now skip it), join
    // the in-flight push, and only then classify — a create that
    // just landed has left the queue and takes the server DELETE
    // path below; one whose push failed is back in the queue as a
    // local-only record and takes the cancel-only path.
    _outbox.markDeleting(entry.id);
    try {
      await _outbox.settleInFlightPush();
      if (!mounted) return;
      final index = _entries.indexWhere((e) => e.id == entry.id);
      if (index < 0) return;
      // Pending-outbox interplay: a queued upsert for this row must be
      // cancelled BEFORE any server delete, or a later flush would
      // resurrect the row. A local-only creation never reached the
      // server, so cancelling its upsert IS the whole delete. A
      // server-known row still needs the server DELETE below; if that
      // fails, the cancelled edit is restored with the row.
      final pendingRecord = _outbox.recordFor(entry.id);
      LogEntryOutboxRecord? cancelledRecord;
      if (pendingRecord != null) {
        cancelledRecord = await _outbox.cancel(entry.id);
        if (!mounted) return;
        if (cancelledRecord == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Couldn't delete that entry — try again."),
            ),
          );
          return;
        }
        if (!pendingRecord.serverKnown) {
          setState(() => _entries = [..._entries]..removeAt(index));
          _syncHomeEntryCount(todayEntryCount(_entries));
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Entry removed')));
          return;
        }
      }
      // Optimistic delete: the entry disappears immediately — no reload,
      // no loading flash. Restored at its original position if the
      // server DELETE fails.
      setState(() => _entries = [..._entries]..removeAt(index));
      final ok = await _backend.deleteLogEntry(entry.id);
      if (!mounted) return;
      if (ok) {
        // Round 59: deleting a today entry lowers the strip/widget
        // count the same way creating one raises it.
        _syncHomeEntryCount(todayEntryCount(_entries));
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Entry removed')));
        // Quiet background reconcile — never blanks the screen.
        unawaited(_revalidate());
      } else {
        if (cancelledRecord != null) {
          await _outbox.restore(cancelledRecord);
          if (!mounted) return;
        }
        setState(() {
          final restored = [..._entries];
          restored.insert(
            index > restored.length ? restored.length : index,
            entry,
          );
          _entries = restored;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't delete that entry — try again."),
          ),
        );
      }
    } finally {
      _outbox.unmarkDeleting(entry.id);
    }
  }

  /// Round 42 — save path for entry edits (native `LogRepository
  /// .updateEntry` + sync push): POST the edited entry through the
  /// existing entries upsert, REUSING its existing id, so the server
  /// updates the row in place — never a new id, never a duplicate.
  ///
  /// Local-first semantics: the edit is staged durably in the
  /// outbox, the History row is replaced in place at once, and the
  /// server push runs in the background. The returned bool means
  /// "durably accepted locally" — the only failure that returns
  /// false is a local persistence failure (or a lock guard above),
  /// in which case the list is NOT touched and the caller surfaces
  /// the honest error. A background push failure never rolls the
  /// row back: the card's sync badge reads Not synced and the
  /// outbox retries on the next sync trigger.
  Future<bool> _saveEntryEdit(QuickLogEntry updated) async {
    final original = _entries.where((e) => e.id == updated.id).firstOrNull;
    if (original == null) return false;
    // Belt-and-suspenders lock guards, mirroring the native view
    // model early-returns: check-in entries never save at all, and
    // medication-tab entries never change category.
    if (isLockedCheckInEntry(original, _categories)) return false;
    if (isMedicationTabEntry(original) &&
        updated.categoryId != original.categoryId) {
      return false;
    }
    final serverKnown = _outbox.recordFor(updated.id)?.serverKnown ??
        (_serverEntryIds.contains(updated.id) ||
            _outbox.isServerKnown(updated.id));
    final staged = await _outbox.stageForBackend(
      updated,
      backend: _backend,
      serverKnown: serverKnown,
    );
    if (!mounted) return staged;
    if (!staged) return false;
    setState(() {
      _entries = _entries.map((e) => e.id == updated.id ? updated : e).toList();
    });
    // Background push + quiet reconcile — never blanks the screen.
    unawaited(_flushOutboxThenRevalidate());
    return true;
  }

  void _showEntryDetail(QuickLogEntry entry) {
    showDialog(
      context: context,
      builder: (context) => _EntryDetailDialog(
        entry: entry,
        categories: _categories,
        formatDateTime: _formatDateTime,
        onSave: _saveEntryEdit,
        onDeleteEntry: _deleteEntry,
      ),
    );
  }

  String _formatDateTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    const months = [
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
    final amPm = d.hour < 12 ? 'AM' : 'PM';
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year} · $h12:$min $amPm';
  }

  String _formatSyncTime(DateTime d) {
    const months = [
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
    final amPm = d.hour < 12 ? 'AM' : 'PM';
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day} · $h12:$min $amPm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          // Audit 6d (Oct 27, 2026) — house label.
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          color: NotelColors.textSecondary,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'History',
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
            Text(
              _lastSyncAt != null
                  ? 'Last synced: ${_formatSyncTime(_lastSyncAt!)}'
                  : 'Saved locally',
              style: const TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
        actions: [
          // Founder addendum: the circular-arrow button moved here from
          // the Quick Log input row. Behavior preserved exactly —
          // duplicates the most recent entry (native repeatLastEntry).
          // (Founder addendum #4, Oct 12 2026: the manual sync button
          // that sat next to this was removed — sync runs automatically
          // in the background; only the button/wiring went away.)
          IconButton(
            onPressed: _repeatLastEntry,
            icon: const Icon(Icons.replay),
            tooltip: 'Repeat last entry',
            color: NotelColors.primary,
          ),
        ],
      ),
      body: _loading
          ? _buildInitialSkeleton()
          : _loadError != null
              ? _buildLoadError()
              : Column(
                  children: [
                    _buildSearchBar(),
                    _buildCategoryFilterRow(),
                    Expanded(child: _buildLogsTab()),
                  ],
                ),
    );
  }

  /// Round 19c — initial-load skeleton, shaped like the real history:
  /// a search-field block, a filter-chip row, and entry cards (chip
  /// line, two body lines, timestamp line) in the real list's padding.
  /// Shown only for the initial load / error retry — never for 19b's
  /// quiet revalidations.
  Widget _buildInitialSkeleton() {
    return SkeletonGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SkeletonBox(height: 48, radius: 14),
          ),
          const SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SkeletonBox(width: 64, height: 36, radius: 12),
                SizedBox(width: 8),
                SkeletonBox(width: 52, height: 36, radius: 12),
                SizedBox(width: 8),
                SkeletonBox(width: 96, height: 36, radius: 12),
                SizedBox(width: 8),
                SkeletonBox(width: 84, height: 36, radius: 12),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemCount: 4,
              itemBuilder: (_, _) => Container(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: NotelColors.surface,
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 72, height: 18, radius: 8),
                    SizedBox(height: 10),
                    SkeletonBox(height: 15, radius: 4),
                    SizedBox(height: 6),
                    SkeletonBox(width: 180, height: 15, radius: 4),
                    SizedBox(height: 10),
                    SkeletonBox(width: 110, height: 11, radius: 4),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadError() {
    // R53 S11: Pattern A error state (was Pattern B).
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 56,
              color: NotelColors.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              _loadError!,
              style: const TextStyle(
                fontSize: 14,
                height: 1.5,
                color: NotelColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _load,
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(color: NotelColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search entries…',
          hintStyle: const TextStyle(color: NotelColors.textSecondary),
          prefixIcon: const Icon(
            Icons.search,
            color: NotelColors.textSecondary,
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  onPressed: () => setState(() => _searchQuery = ''),
                  // Audit 6d (Oct 27, 2026) — house label.
                  tooltip: 'Clear search',
                  icon: const Icon(
                    Icons.clear,
                    color: NotelColors.textSecondary,
                  ),
                )
              : null,
          filled: true,
          fillColor: NotelColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: NotelColors.primary.withValues(alpha: 0.25),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: NotelColors.primary),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryFilterRow() {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemCount: _categories.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            // "Today" filter chip.
            final on = _todayOnly;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _todayOnly = !on),
              // R49 HI1: 48dp hit area around the 36dp visual chip.
              child: SizedBox(
                height: 48,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: on ? NotelColors.primary : NotelColors.surface,
                      border: Border.all(
                        color: on
                            ? NotelColors.primary
                            : NotelColors.primary.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Text(
                      'TODAY',
                      style: TextStyle(
                        color: on ? _chipInk : NotelColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          if (index == 1) {
            final allSelected = _categoryFilter == null;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _categoryFilter = null),
              // R49 HI1: 48dp hit area around the 36dp visual chip.
              child: SizedBox(
                height: 48,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: allSelected
                          ? NotelColors.primary
                          : NotelColors.surface,
                      border: Border.all(
                        color: allSelected
                            ? NotelColors.primary
                            : NotelColors.primary.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Text(
                      'ALL',
                      style: TextStyle(
                        color:
                            allSelected ? _chipInk : NotelColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          final cat = _categories[index - 2];
          final selected = _categoryFilter == cat.id;
          final catColor = cat.color;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                setState(() => _categoryFilter = selected ? null : cat.id),
            // R49 HI1: 48dp hit area around the 36dp visual chip.
            child: SizedBox(
              height: 48,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: selected ? catColor : NotelColors.surface,
                    border: Border.all(
                      color: selected
                          ? catColor
                          : catColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    cat.name,
                    style: TextStyle(
                      color: selected ? _chipInk : NotelColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLogsTab() {
    final filtered = _filtered;
    if (filtered.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CoachMascotFigure(height: 96),
            SizedBox(height: 12),
            Text(
              'No entries yet',
              style: TextStyle(color: NotelColors.textSecondary),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemCount: filtered.length,
      itemBuilder: (context, index) => _buildEntryCard(filtered[index]),
    );
  }

  /// Per-entry sync badge, in the same slot the card has always
  /// rendered its sync state — delegates to the shared
  /// [LogEntrySyncBadge] so History and Quick Log can never drift
  /// apart in states or copy (F5).
  Widget _entrySyncBadge(QuickLogEntry entry) =>
      LogEntrySyncBadge(outbox: _outbox, entryId: entry.id);

  /// Native `EntryCard`: 16dp card, accent-color border,
  /// category chip, body (max 4 lines), timestamp + sync badge,
  /// delete with confirmation. (Left accent strip removed
  /// Oct 27, 2026 at the founder's direction; the border stays.)
  Widget _buildEntryCard(QuickLogEntry entry) {
    final cat = _categories.where((c) => c.id == entry.categoryId).firstOrNull;
    final accent = cat?.color ?? NotelColors.primary;
    // Native HistoryScreen EntryCard: check-in entries show their
    // locked "Daily Ranking" tag on the card instead of the category
    // chip. All other entries keep the category chip.
    final lockedCheckIn = isLockedCheckInEntry(entry, _categories);
    final chipLabel = lockedCheckIn ? feelingCheckInTag : cat?.name;
    final chipColor = lockedCheckIn ? NotelColors.primary : accent;
    // R53 HI5: chip label ink. Primary case (incl. the locked
    // check-in tag, which shares this builder) uses primaryText on
    // its @15%-over-surface tint (5.92:1). For all other category
    // colors, the label keeps chipColor only where chipColor on its
    // own @15%-over-surface tint computes >= 4.5:1 per skill §2;
    // otherwise it falls back to textPrimary. Tint and border are
    // unchanged.
    Color chipLabelColor(Color color) {
      if (color == NotelColors.primary) return NotelColors.primaryText;
      double linearize(double c) => c <= 0.03928
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
      double luminance(double r, double g, double b) =>
          0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b);
      const bg = NotelColors.surface;
      final tintLum = luminance(
        color.r * 0.15 + bg.r * 0.85,
        color.g * 0.15 + bg.g * 0.85,
        color.b * 0.15 + bg.b * 0.85,
      );
      final chipLum = luminance(color.r, color.g, color.b);
      final light = math.max(chipLum, tintLum);
      final dark = math.min(chipLum, tintLum);
      final ratio = (light + 0.05) / (dark + 0.05);
      return ratio >= 4.5 ? color : NotelColors.textPrimary;
    }

    final chipLabelColorValue = chipLabelColor(chipColor);
    return GestureDetector(
      onTap: () => _showEntryDetail(entry),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: NotelColors.surface,
          border: Border.all(color: accent.withValues(alpha: 0.20)),
        ),
        child: Padding(
            // R49 HI6: vertical card padding 14→16 (the right-4
            // delete-button inset is construction; kept).
            padding: const EdgeInsets.fromLTRB(16, 16, 4, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: chipLabel != null
                          ? Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: chipColor.withValues(alpha: 0.15),
                                  border: Border.all(
                                    color: chipColor.withValues(alpha: 0.45),
                                  ),
                                ),
                                child: Text(
                                  chipLabel,
                                  style: TextStyle(
                                    color: chipLabelColorValue,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    SizedBox(
                      // R49 HI2: 48dp target (was 28×28). R53: glyph
                      // 16->18, full-opacity textSecondary.
                      width: 48,
                      height: 48,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => _deleteEntry(entry),
                        // Audit 6d (Oct 27, 2026) — house label
                        // (destructive action; top of the Low list).
                        tooltip: 'Delete entry',
                        icon: const Icon(Icons.delete, size: 18),
                        color: NotelColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  entry.body,
                  style: const TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    height: 1.45,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDateTime(entry.timestamp),
                      style: const TextStyle(
                        // R49 HI3: full-opacity primary = 4.82:1
                        // on surface (was α0.55 = 2.32:1).
                        color: NotelColors.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3,
                      ),
                    ),
                    // Honest per-entry status from the outbox:
                    // Synced only when no unconfirmed local
                    // version of this row exists.
                    _entrySyncBadge(entry),
                  ],
                ),
              ],
            ),
          ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Round 42 — entry detail dialog. Port of native `EntryDetailScreen`:
/// - NORMAL entries: a "CHANGE CATEGORY" row (account categories in
///   native sortOrder order; a tap saves IMMEDIATELY, exactly like
///   native — there is no category save button) and an Edit affordance
///   opening the text editor. Chips render as parsed tiles, never raw
///   JSON; the only chips mutation native allows is the category
///   change replacing them with `[newCategoryName]`.
/// - Check-in entries (Round 21 identity): NO edit affordance and NO
///   category row — the native lock note stands in their place, and
///   the "Daily Ranking" tile carries its lock icon + note.
/// - Medication-tab entries: the native banner replaces the category
///   row (category locked); text editing stays available.
/// Saves go through [onSave], which now reports LOCAL acceptance:
/// the dialog adopts a category the moment it is tapped, and only a
/// local persistence failure (onSave false) restores the old values
/// with an honest inline error. A later server-push failure does not
/// revert anything — the History card's badge reads Not synced while
/// the outbox keeps retrying.
class _EntryDetailDialog extends StatefulWidget {
  final QuickLogEntry entry;
  final List<QuickLogCategory> categories;
  final String Function(int timestamp) formatDateTime;
  final Future<bool> Function(QuickLogEntry updated) onSave;

  /// Phase 1 item 4 — the History delete flow (confirmation +
  /// outbox-aware delete), handed to the intake editor sheet's
  /// delete action when an intake entry is edited from here.
  final Future<void> Function(QuickLogEntry entry)? onDeleteEntry;

  const _EntryDetailDialog({
    required this.entry,
    required this.categories,
    required this.formatDateTime,
    required this.onSave,
    this.onDeleteEntry,
  });

  @override
  State<_EntryDetailDialog> createState() => _EntryDetailDialogState();
}

class _EntryDetailDialogState extends State<_EntryDetailDialog> {
  late QuickLogEntry _entry;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
  }

  bool get _isCheckIn => isLockedCheckInEntry(_entry, widget.categories);
  bool get _isMedTab => isMedicationTabEntry(_entry);

  /// Phase 1 item 4: an Intake-tagged entry's text edit routes to
  /// the intake editor sheet — never the free-text editor, which
  /// would clear the structured payload (editedEntryText semantics).
  bool get _isIntake => isIntakeEntry(_entry);

  QuickLogCategory? get _category =>
      widget.categories.where((c) => c.id == _entry.categoryId).firstOrNull;

  Future<void> _changeCategory(QuickLogCategory cat) async {
    if (_saving || cat.id == _entry.categoryId) return;
    final previous = _entry;
    final updated = editedEntryCategory(_entry, cat);
    // Optimistic: the tapped category is adopted on this frame,
    // before any persistence or network future can complete. The
    // founder's dead-tap ("click it, nothing happens, takes a
    // minute, then it switches") was the old success-gated adoption.
    setState(() {
      _saving = true;
      _error = null;
      _entry = updated;
    });
    final ok = await widget.onSave(updated);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) {
        _entry = previous;
        _error = "Couldn't save that change — try again.";
      }
    });
  }

  Future<void> _editText() async {
    if (_isIntake) {
      await _editIntake();
      return;
    }
    final updated = await showDialog<QuickLogEntry>(
      context: context,
      builder: (context) =>
          _EditEntryTextDialog(entry: _entry, onSave: widget.onSave),
    );
    if (updated != null && mounted) {
      setState(() => _entry = updated);
    }
  }

  /// Phase 1 item 4 — the intake editor route: the sheet is
  /// prefilled from the entry's payload and its save rewrites body
  /// + payload together through the ordinary History save path
  /// (same id; timestamp changes only when the user edits Time).
  /// The payload is never cleared and never rendered as copy.
  Future<void> _editIntake() async {
    QuickLogEntry? updated;
    await showIntakeEditorSheet(
      context: context,
      existing: _entry,
      onSave: (draft, existing) async {
        final u = editIntakeEntry(_entry, draft: draft);
        final ok = await widget.onSave(u);
        if (ok) updated = u;
        return ok;
      },
      onDelete: widget.onDeleteEntry == null
          ? null
          : () async {
              final entry = _entry;
              // Close this detail dialog first; the delete flow
              // (its own confirmation + outbox semantics) runs
              // against the History list underneath.
              Navigator.of(context).pop();
              await widget.onDeleteEntry!(entry);
            },
    );
    if (updated != null && mounted) {
      setState(() => _entry = updated!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chips = parseEntryChips(_entry.chips);
    final pickerCats = sortedCategoriesForPicker(widget.categories);
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        _category?.name ?? 'Entry',
        style: const TextStyle(
          color: NotelColors.textPrimary,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isCheckIn)
              // Native locked note in place of every edit affordance.
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock, size: 12, color: NotelColors.textSecondary),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'This entry was logged automatically and cannot '
                      'be edited.',
                      style: TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              )
            else if (_isMedTab)
              const Text(
                'LOGGED VIA MEDICATIONS TAB',
                style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              )
            else ...[
              const Text(
                'CHANGE CATEGORY',
                style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              // Native LazyRow. A SingleChildScrollView+Row is used
              // instead of a horizontal ListView: a viewport inside an
              // AlertDialog breaks the dialog's intrinsic sizing.
              SizedBox(
                height: 40,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < pickerCats.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Builder(
                          builder: (context) {
                            final cat = pickerCats[i];
                            final selected = cat.id == _entry.categoryId;
                            final color = cat.color;
                            return GestureDetector(
                              onTap:
                                  _saving ? null : () => _changeCategory(cat),
                              child: Container(
                                height: 40,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  color: selected
                                      ? color
                                      : NotelColors.surfaceHigh,
                                  border: Border.all(
                                    color: selected
                                        ? color
                                        : color.withValues(alpha: 0.35),
                                  ),
                                ),
                                child: Text(
                                  cat.name.toUpperCase(),
                                  style: TextStyle(
                                    color: selected
                                        ? Colors.white
                                        : NotelColors.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              entryCombinedText(_entry),
              style: const TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 17,
                height: 24 / 17,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Logged on ${widget.formatDateTime(_entry.timestamp)}',
              style: const TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 12,
              ),
            ),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'ASSOCIATED TILES',
                style: TextStyle(
                  color: NotelColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final chip in chips)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: NotelColors.surfaceHigh,
                        border: Border.all(
                          color: NotelColors.primary.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isCheckIn && chip == feelingCheckInTag) ...[
                            const Icon(
                              Icons.lock,
                              size: 12,
                              color: NotelColors.textSecondary,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            chip,
                            style: const TextStyle(
                              color: NotelColors.textPrimary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              if (_isCheckIn) ...[
                const SizedBox(height: 8),
                const Text(
                  'This tag was added automatically and cannot be '
                  'changed.',
                  style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: NotelColors.error, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_isCheckIn)
          TextButton(
            onPressed: _saving ? null : _editText,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit, size: 16, color: NotelColors.primary),
                SizedBox(width: 6),
                Text(
                  'Edit',
                  style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Close',
            style: TextStyle(
              color: NotelColors.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

/// Native "Edit Entry Text" dialog: one field labelled "Note Content"
/// holding the combined text (no character limit, no empty-text
/// validation — native has neither), Save / Cancel. Save calls
/// [onSave] with `updateText(edited, "")` semantics; on a LOCAL
/// persistence failure the dialog stays open with the error shown
/// and nothing is adopted. On local acceptance the dialog closes at
/// once and the server push continues in the background.
class _EditEntryTextDialog extends StatefulWidget {
  final QuickLogEntry entry;
  final Future<bool> Function(QuickLogEntry updated) onSave;

  const _EditEntryTextDialog({required this.entry, required this.onSave});

  @override
  State<_EditEntryTextDialog> createState() => _EditEntryTextDialogState();
}

class _EditEntryTextDialogState extends State<_EditEntryTextDialog> {
  late final TextEditingController _controller;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: entryCombinedText(widget.entry));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final updated = editedEntryText(widget.entry, _controller.text);
    final ok = await widget.onSave(updated);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, updated);
    } else {
      setState(() {
        _saving = false;
        _error = "Couldn't save that edit — try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NotelColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text(
        'Edit Entry Text',
        style: TextStyle(
          color: NotelColors.textPrimary,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 250,
              child: TextField(
                key: const ValueKey('entry_text_editor'),
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(color: NotelColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Note Content',
                  labelStyle: const TextStyle(color: NotelColors.textSecondary),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: NotelColors.primary.withValues(alpha: 0.5),
                    ),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: NotelColors.primary),
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: NotelColors.error,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: NotelColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text(
            'Save',
            style: TextStyle(
              color: NotelColors.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
