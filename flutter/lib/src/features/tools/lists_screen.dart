import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 — Lists tool screen, DISPLAY-ONLY. Faithful port of native
/// `ui/screen/ListsScreen.kt` minus the write path:
///
/// - Data: `TabsBackend.decodeProfileList(profile['userLists'])` — the
///   userLists JSON blob synced from the native app. Per-list shape
///   mirrors native `UserListSyncDto` in `JotApi.kt`:
///   `{name, items: [strings]}`.
/// - The `"__user_notes__"` pseudo-list is filtered out exactly like
///   native (`filteredLists`).
/// - Renders each list as an expandable card (first list expanded, like
///   native's auto-select-first) with the native item rows: a 7dp purple
///   dot + 14sp text. Item count sits under the list name.
/// - DEFERRED (later round): creating lists, adding/editing/deleting
///   items, deleting lists. The native new-list dialog, per-item edit
///   and ✕ delete affordances are omitted; content is read-only.
///
/// `UserListModel` / [visibleUserLists] are pure and unit-tested.

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

/// Round 18 — display-only Lists screen.
///
/// [backend] is injectable so widget tests can drive the screen with a
/// mock client; production defaults to a real [TabsBackend].
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
  List<UserListModel> _lists = const [];
  final Set<int> _expanded = {};

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
      final rows =
          TabsBackend.decodeProfileList(profile['userLists']);
      final lists =
          visibleUserLists(rows.map(UserListModel.fromJson).toList());
      setState(() {
        _lists = lists;
        _loading = false;
        // Native auto-selects the first list once lists load.
        if (lists.isNotEmpty) _expanded.add(0);
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
          'Lists',
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
    if (_lists.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('📋', style: TextStyle(fontSize: 52)),
            SizedBox(height: 16),
            Text(
              'No lists yet',
              style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Your checklists will appear here.',
              style: TextStyle(
                color: NotelColors.textSecondary,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: _lists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) =>
          _listCard(_lists[i], i),
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
                  Icon(
                    expanded
                        ? Icons.expand_less
                        : Icons.expand_more,
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
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  children: [
                    for (final item in list.items) _itemRow(item),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _itemRow(String text) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(
          horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: NotelColors.surfaceHigh.withValues(alpha: 0.08),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
        ),
      ),
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
        ],
      ),
    );
  }
}
