import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 48 — Lists tool screen, FULL read/write port of native
/// `ui/screen/ListsScreen.kt` + `ListsViewModel.kt`:
///
/// - Data: the `userLists` JSON blob in the profile sync blob (native
///   `SyncManager.pushProfileData` serializes local lists as
///   `UserListSyncDto{name, items: [strings]}` and pushes the whole
///   blob via `POST /api/sync/profile`). The `"__user_notes__"`
///   pseudo-list is filtered out exactly like native.
/// - Actions (native parity): create list, delete list (with the
///   native confirm dialog), add item, edit item (tap a row, inline
///   edit), delete item.
/// - Writes follow the identity-safe full-list rule: re-pull the
///   freshest profile (cache invalidated first), splice the change
///   into the RAW decoded rows — every other row and every unknown
///   key preserved verbatim — then push the complete blob. A failed
///   push shows an error and reloads from the server; the screen
///   never claims an unsaved state.
///
/// [UserListModel] / [visibleUserLists] / the `userListsWith*` splice
/// helpers are pure and unit-tested.

/// One list from the `userLists` profile blob (native `UserListSyncDto`).
class UserListModel {
  final String name;
  final List<String> items;

  const UserListModel({required this.name, required this.items});

  factory UserListModel.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final items = <String>[];
    if (raw is List) {
      for (final item in raw) {
        if (item == null) continue;
        final text = '$item'.trim();
        if (text.isNotEmpty) items.add(text);
      }
    }
    return UserListModel(name: '${json['name'] ?? ''}', items: items);
  }
}

/// The internal notes pseudo-list never shows as a user list (native
/// `ListsScreen` filters `"__user_notes__"` the same way).
const String notesPseudoListName = '__user_notes__';

/// Drops the notes pseudo-list; the rest pass through in order.
List<UserListModel> visibleUserLists(List<UserListModel> lists) =>
    lists.where((l) => l.name != notesPseudoListName).toList();

/// Parses user-list rows fail-soft: a row that throws is skipped
/// instead of killing the whole list. Never throws.
List<UserListModel> parseUserListModels(
    List<Map<String, dynamic>> rows) {
  final out = <UserListModel>[];
  for (final row in rows) {
    try {
      out.add(UserListModel.fromJson(row));
    } catch (_) {
      // Skip the bad row; keep the rest.
    }
  }
  return out;
}

/// Decodes the raw `userLists` profile value into its raw JSON rows,
/// preserving every row (and every key inside a row) exactly as
/// stored, so a later full-blob push never drops data this screen
/// does not render. Tolerates a JSON string (including
/// double-encoded), an already-decoded list, a single map, and
/// garbage (→ empty). Never throws.
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

/// The display name of a raw row, or null when the row carries none.
String? userListRowName(dynamic row) {
  if (row is Map) {
    final name = row['name'];
    return name?.toString();
  }
  if (row is String) return row;
  return null;
}

/// The raw item values of a raw row (unmodified, any JSON type).
List<dynamic> userListRowRawItems(dynamic row) {
  if (row is Map) {
    final items = row['items'];
    if (items is List) return List<dynamic>.of(items);
  }
  return const [];
}

/// Visible (non-notes) list models in row order, built from raw rows.
List<UserListModel> visibleListsFromRaw(List<dynamic> rows) {
  final models = <UserListModel>[];
  for (final row in rows) {
    final name = userListRowName(row);
    if (name == null || name == notesPseudoListName) continue;
    models.add(UserListModel(
      name: name,
      items: [
        for (final item in userListRowRawItems(row))
          if (item != null && '$item'.trim().isNotEmpty) '$item'.trim(),
      ],
    ));
  }
  return models;
}

/// Maps a VISIBLE list index (notes pseudo-list excluded) to its raw
/// row index. Null when out of range.
int? rawIndexForVisibleList(List<dynamic> rows, int visibleIndex) {
  if (visibleIndex < 0) return null;
  var seen = -1;
  for (var i = 0; i < rows.length; i++) {
    final name = userListRowName(rows[i]);
    if (name == null || name == notesPseudoListName) continue;
    seen++;
    if (seen == visibleIndex) return i;
  }
  return null;
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
  return <String, dynamic>{'name': userListRowName(row) ?? '', 'items': items};
}

List<dynamic> _spliceRow(
    List<dynamic> rows, int rawIndex, dynamic newRow) {
  final out = List<dynamic>.of(rows);
  out[rawIndex] = newRow;
  return out;
}

/// Splice: append a new empty list (native `createList`). Null when
/// the name is blank (native refuses blank names).
List<dynamic>? userListsWithNewList(List<dynamic> rows, String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  return [
    ...rows,
    <String, dynamic>{'name': trimmed, 'items': <String>[]},
  ];
}

/// Resolves which raw row a rendered-list operation targets: the
/// row at the visible index is trusted only when its name still
/// equals [expectedName]; otherwise a unique visible list with that
/// name wins; anything else (gone or ambiguous) returns null so the
/// caller aborts instead of touching the wrong list.
int? _resolveListRow(
    List<dynamic> rows, int visibleIndex, String expectedName) {
  final atIndex = rawIndexForVisibleList(rows, visibleIndex);
  if (atIndex != null && userListRowName(rows[atIndex]) == expectedName) {
    return atIndex;
  }
  final matches = <int>[];
  for (var i = 0; i < rows.length; i++) {
    final name = userListRowName(rows[i]);
    if (name != null &&
        name != notesPseudoListName &&
        name == expectedName) {
      matches.add(i);
    }
  }
  return matches.length == 1 ? matches.single : null;
}

/// Splice: remove the visible list at [visibleIndex] (native
/// `deleteList`). Null when the list cannot be identified with
/// certainty in the freshest rows.
List<dynamic>? userListsWithoutList(
    List<dynamic> rows, int visibleIndex, String expectedName) {
  final rawIndex = _resolveListRow(rows, visibleIndex, expectedName);
  if (rawIndex == null) return null;
  return List<dynamic>.of(rows)..removeAt(rawIndex);
}

/// Splice: append [text] to the visible list at [visibleIndex]
/// (native `addItem`). Null on blank text or an unresolvable list.
List<dynamic>? userListsWithAddedItem(List<dynamic> rows, int visibleIndex,
    String expectedName, String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final rawIndex = _resolveListRow(rows, visibleIndex, expectedName);
  if (rawIndex == null) return null;
  final items = userListRowRawItems(rows[rawIndex])..add(trimmed);
  return _spliceRow(rows, rawIndex, _rowWithItems(rows[rawIndex], items));
}

/// Locates the raw item position for an edit/delete: the rendered
/// [itemIndex] is trusted only when the value there still equals
/// [expectedText]; otherwise a unique exact match wins; anything
/// else (gone or ambiguous) returns null so the caller aborts
/// instead of touching the wrong row.
int? _locateItem(List<dynamic> items, int itemIndex, String expectedText) {
  if (itemIndex >= 0 &&
      itemIndex < items.length &&
      '${items[itemIndex]}' == expectedText) {
    return itemIndex;
  }
  final matches = <int>[
    for (var i = 0; i < items.length; i++)
      if ('${items[i]}' == expectedText) i,
  ];
  return matches.length == 1 ? matches.single : null;
}

/// Splice: replace one item's text (native `editItem`). Null when
/// the new text is blank or the target item cannot be identified
/// with certainty.
List<dynamic>? userListsWithEditedItem(List<dynamic> rows, int visibleIndex,
    String expectedName, int itemIndex, String expectedText,
    String newText) {
  final trimmed = newText.trim();
  if (trimmed.isEmpty) return null;
  final rawIndex = _resolveListRow(rows, visibleIndex, expectedName);
  if (rawIndex == null) return null;
  final items = userListRowRawItems(rows[rawIndex]);
  final at = _locateItem(items, itemIndex, expectedText);
  if (at == null) return null;
  items[at] = trimmed;
  return _spliceRow(rows, rawIndex, _rowWithItems(rows[rawIndex], items));
}

/// Splice: remove one item (native `deleteItem`). Null when the
/// target item cannot be identified with certainty.
List<dynamic>? userListsWithoutItem(List<dynamic> rows, int visibleIndex,
    String expectedName, int itemIndex, String expectedText) {
  final rawIndex = _resolveListRow(rows, visibleIndex, expectedName);
  if (rawIndex == null) return null;
  final items = userListRowRawItems(rows[rawIndex]);
  final at = _locateItem(items, itemIndex, expectedText);
  if (at == null) return null;
  items.removeAt(at);
  return _spliceRow(rows, rawIndex, _rowWithItems(rows[rawIndex], items));
}

/// Round 48 — full Lists screen (see file header).
///
/// [backend] is injectable so widget tests can drive the screen with
/// a mock client; production defaults to a real [TabsBackend].
class ListsScreen extends StatefulWidget {
  final TabsBackend? backend;

  const ListsScreen({super.key, this.backend});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  late final TabsBackend _backend;
  bool _loading = true;
  bool _failed = false;
  bool _loadFailed = false; // profile itself was null (auth/network)
  bool _writing = false;
  List<dynamic> _rows = const [];
  final Set<int> _expanded = {};
  // (listIndex, itemIndex) currently in inline-edit mode, if any.
  (int, int)? _editing;

  List<UserListModel> get _lists => visibleListsFromRaw(_rows);

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
      _expanded.clear();
      _editing = null;
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
      final rows = decodeUserListsRaw(profile['userLists']);
      setState(() {
        _rows = rows;
        _loading = false;
        // Native auto-selects the first list once lists load.
        if (_lists.isNotEmpty) _expanded.add(0);
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
  /// error is shown and the screen reloads from the server — no
  /// phantom success. [expandIndex] re-expands a list after the
  /// write lands (list indices can shift across a reload).
  Future<void> _mutate(
    List<dynamic>? Function(List<dynamic> freshRows) splice, {
    int? expandIndex,
  }) async {
    if (_writing) return;
    setState(() => _writing = true);
    try {
      _backend.invalidateSyncPull();
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        _showSaveError();
        await _load();
        return;
      }
      final fresh = decodeUserListsRaw(profile['userLists']);
      final next = splice(fresh);
      if (next == null) {
        // The target moved or vanished in the freshest data — abort
        // rather than guess, show the error, render the fresh data.
        _showSaveError();
        if (mounted) {
          setState(() {
            _rows = fresh;
            _editing = null;
          });
        }
        return;
      }
      final ok = await _backend
          .postSyncProfile({'userLists': jsonEncode(next)});
      if (!mounted) return;
      if (ok) {
        _backend.invalidateSyncPull();
        setState(() {
          _rows = next;
          _editing = null;
          if (expandIndex != null) _expanded.add(expandIndex);
        });
      } else {
        _showSaveError();
        await _load();
      }
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _showNewListDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        var text = '';
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: NotelColors.surface,
            title: const Text('New List',
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.bold)),
            content: TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: NotelColors.textPrimary),
              decoration: const InputDecoration(
                hintText: 'e.g. Foods good for MCAS',
                hintStyle: TextStyle(color: NotelColors.textSecondary),
              ),
              onChanged: (v) => setDialogState(() => text = v),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) {
                  Navigator.of(dialogContext).pop(v);
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel',
                    style: TextStyle(color: NotelColors.textSecondary)),
              ),
              FilledButton(
                onPressed: text.trim().isEmpty
                    ? null
                    : () => Navigator.of(dialogContext).pop(text),
                style: FilledButton.styleFrom(
                    backgroundColor: NotelColors.primary),
                child: const Text('Create'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    if (name == null || !mounted) return;
    final newVisibleIndex = _lists.length;
    await _mutate(
      (fresh) => userListsWithNewList(fresh, name),
      expandIndex: newVisibleIndex,
    );
  }

  Future<void> _confirmDeleteList(int index, UserListModel list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: Text('Delete "${list.name}"?',
            style: const TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.bold)),
        content: const Text(
          'This will permanently delete the list and all its items.',
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style:
                FilledButton.styleFrom(backgroundColor: NotelColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _mutate(
        (fresh) => userListsWithoutList(fresh, index, list.name));
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
          'Lists',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add,
                color: NotelColors.textPrimary, semanticLabel: 'New List'),
            onPressed: _writing ? null : _showNewListDialog,
          ),
        ],
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
    final lists = _lists;
    if (lists.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📋', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 16),
            const Text(
              'No lists yet',
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Tap + in the top right to create your first list',
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _writing ? null : _showNewListDialog,
              style: FilledButton.styleFrom(
                  backgroundColor: NotelColors.primary),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New List'),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: lists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _listCard(lists[i], i),
    );
  }

  Widget _failureState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📋', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 16),
            const Text(
              'Couldn\'t load lists',
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Check your connection and try again.',
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
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

  Widget _listCard(UserListModel list, int index) {
    final expanded = _expanded.contains(index);
    final count = list.items.length;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: NotelColors.surfaceHigh.withValues(alpha: 0.12),
        border: Border.all(
          color: expanded
              ? NotelColors.primary.withValues(alpha: 0.3)
              : NotelColors.primary.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(index);
              } else {
                _expanded.add(index);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Text('📋', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          list.name,
                          style: const TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          count == 0
                              ? 'No items yet'
                              : '$count item${count == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: expanded
                                ? NotelColors.primary
                                : NotelColors.textSecondary,
                            fontSize: 12,
                            fontWeight: expanded
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (expanded)
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          color: NotelColors.error.withValues(alpha: 0.7),
                          size: 20,
                          semanticLabel: 'Delete list'),
                      onPressed: _writing
                          ? null
                          : () => _confirmDeleteList(index, list),
                    ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: NotelColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(
              height: 1,
              color: NotelColors.legacyDarkDivider,
              indent: 16,
              endIndent: 16,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: _AddItemField(
                enabled: !_writing,
                onAdd: (text) => _mutate(
                  (fresh) =>
                      userListsWithAddedItem(fresh, index, list.name, text),
                  expandIndex: index,
                ),
              ),
            ),
            if (count == 0)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'This list is empty',
                  style: TextStyle(
                    color: NotelColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  children: [
                    for (var itemIndex = 0;
                        itemIndex < list.items.length;
                        itemIndex++)
                      _itemRow(list, index, itemIndex),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _itemRow(UserListModel list, int listIndex, int itemIndex) {
    final text = list.items[itemIndex];
    if (_editing == (listIndex, itemIndex)) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _EditItemField(
          initial: text,
          onSave: (newText) => _mutate(
            (fresh) => userListsWithEditedItem(
                fresh, listIndex, list.name, itemIndex, text, newText),
            expandIndex: listIndex,
          ),
          onCancel: () => setState(() => _editing = null),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: NotelColors.surfaceHigh.withValues(alpha: 0.08),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _writing
            ? null
            : () => setState(() => _editing = (listIndex, itemIndex)),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(top: 6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: NotelColors.primary.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 14,
                    height: 20 / 14,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close,
                    size: 14,
                    color:
                        NotelColors.textSecondary.withValues(alpha: 0.4),
                    semanticLabel: 'Delete item'),
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
                onPressed: _writing
                    ? null
                    : () => _mutate(
                          (fresh) => userListsWithoutItem(
                              fresh, listIndex, list.name, itemIndex, text),
                          expandIndex: listIndex,
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Native add-item row: text field + round add button (enabled only
/// with non-blank text, exactly like native).
class _AddItemField extends StatefulWidget {
  final bool enabled;
  final ValueChanged<String> onAdd;

  const _AddItemField({required this.enabled, required this.onAdd});

  @override
  State<_AddItemField> createState() => _AddItemFieldState();
}

class _AddItemFieldState extends State<_AddItemField> {
  final TextEditingController _controller = TextEditingController();
  String _text = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_text.trim().isEmpty || !widget.enabled) return;
    widget.onAdd(_text);
    _controller.clear();
    setState(() => _text = '');
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = widget.enabled && _text.trim().isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: widget.enabled,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(
                color: NotelColors.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Add an item...',
              hintStyle: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 14),
              filled: true,
              fillColor:
                  NotelColors.surfaceHigh.withValues(alpha: 0.08),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color:
                        NotelColors.surfaceHigh.withValues(alpha: 0.2)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color:
                        NotelColors.surfaceHigh.withValues(alpha: 0.2)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color: NotelColors.primary.withValues(alpha: 0.6)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
            ),
            onChanged: (v) => setState(() => _text = v),
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: canAdd ? _submit : null,
          style: FilledButton.styleFrom(
            backgroundColor: NotelColors.primary,
            disabledBackgroundColor:
                NotelColors.surfaceHigh.withValues(alpha: 0.3),
            shape: const CircleBorder(),
            padding: const EdgeInsets.all(12),
          ),
          child: const Icon(Icons.add, size: 20, semanticLabel: 'Add item'),
        ),
      ],
    );
  }
}

/// Native inline item edit row: text field + save/cancel buttons.
class _EditItemField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  const _EditItemField({
    required this.initial,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<_EditItemField> createState() => _EditItemFieldState();
}

class _EditItemFieldState extends State<_EditItemField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            autofocus: true,
            style: const TextStyle(
                color: NotelColors.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor:
                  NotelColors.surfaceHigh.withValues(alpha: 0.08),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: NotelColors.primary),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color:
                        NotelColors.surfaceHigh.withValues(alpha: 0.2)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: NotelColors.primary),
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
            ),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) widget.onSave(v);
            },
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.check,
              size: 18,
              color: NotelColors.primary,
              semanticLabel: 'Save'),
          onPressed: () {
            final v = _controller.text;
            if (v.trim().isNotEmpty) widget.onSave(v);
          },
        ),
        IconButton(
          icon: const Icon(Icons.close,
              size: 18,
              color: NotelColors.textSecondary,
              semanticLabel: 'Cancel'),
          onPressed: widget.onCancel,
        ),
      ],
    );
  }
}
