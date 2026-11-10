import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/correlation_insight_store.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

/// Phase 1 item 5 — the Patterns surface (spec §5/§6, Juno's final
/// rulings for item 5).
///
/// HONESTY / ARCHITECTURE RULES (binding, spec §6 + Juno R1/R2/R4):
/// - This screen renders ONLY from cached [InsightRecord]s read
///   through the correlation insight store. It NEVER computes:
///   there is no compute call in `initState`/`build`, and the
///   injectable [PatternsScreen.computeCallback] exists purely so
///   tests can prove that (a counting callback must stay at zero
///   after the screen opens — spec §8 test A7).
/// - Fixed order: families F1→F5, splits in engine order, groups
///   A-then-B. Nothing is ever sorted by any value (Juno R1).
/// - Side-by-side averages only: no delta, no arrow, no percent,
///   no directional colour anywhere (Juno R2/R4). Both groups
///   always render together.
/// - Every user-visible string comes from correlation_copy.dart
///   (Juno's verbatim set) or from the record's own stored labels;
///   this file hardcodes no outcome copy of its own.
/// - Premium gate (founder Q2 crew assumption): numbers-state
///   cards render only for unlimited users. For everyone else the
///   numbers cards are OMITTED entirely (no averages anywhere in
///   the tree, no teaser/locked copy — no ruled copy exists for
///   that state), while progress and unavailable cards render
///   normally for everyone. The gate is tri-state (H1-05P): an
///   UNKNOWN membership holds the numbers decision in a pending
///   state instead of reading as non-member.
/// - Failure states (H1-08 + Juno's signed follow-up ruling): a
///   failed records read — or a failed membership resolution —
///   renders the Slot 1 error state INSTEAD of the card list;
///   a successful read of zero records is the new-user state
///   and never routes to the error string.
/// - F2 unavailable records collapse to ONE card on this surface
///   (the first in display order stands for the family) and F2
///   progress cards carry their ruled split header — Juno's
///   composition sign-off of Nov 8, 2026. Renderer only: the
///   engine's per-split records are never altered here.
class PatternsScreen extends StatefulWidget {
  /// Records rendered directly (tests, previews). When null, the
  /// screen loads the cached records through [recordsLoader] or
  /// [insightStore] (default: the correlation insight store).
  final List<InsightRecord>? records;

  /// Injectable cache reader (tests / wiring). Must only READ the
  /// insight cache — never a compute entry point.
  final Future<List<InsightRecord>> Function()? recordsLoader;

  /// Injectable insight store. Duck-typed at the call site so the
  /// surface only depends on a cache read (`readAll`/`load`/
  /// `getAll`), never on any compute API the store may also carry.
  final Object? insightStore;

  /// Premium flag — tri-state (H1-05P). An explicit value wins.
  /// When null, the [QuickLogCache] snapshot seeds the gate ONLY
  /// when its membership is known; when it is genuinely unknown
  /// the screen holds the numbers decision in a pending state
  /// (skeleton + Juno's pending label, other cards normal) and
  /// resolves membership itself via [membershipLoader] (default:
  /// the backend's failure-distinguishing fetch). Unknown never
  /// reads as non-member, so a Premium user's numbers are never
  /// silently filtered by a cold cache.
  final bool? isUnlimited;

  /// Injectable membership resolver for the unknown-gate path:
  /// returns the resolved `isUnlimited`, or null when the
  /// resolution itself failed. A timeout counts as failure
  /// (Juno's signed follow-up ruling): failure lands in the
  /// Slot 1 error state, and Try again re-runs both the records
  /// load and this resolution.
  final Future<bool?> Function()? membershipLoader;

  /// Counting compute callback for the no-compute-on-open test
  /// (spec §8 A7). The screen NEVER invokes it; it exists so a
  /// test can inject a counter and assert zero calls.
  final VoidCallback? computeCallback;

  const PatternsScreen({
    super.key,
    this.records,
    this.recordsLoader,
    this.insightStore,
    this.isUnlimited,
    this.membershipLoader,
    this.computeCallback,
  });

  @override
  State<PatternsScreen> createState() => _PatternsScreenState();
}

class _PatternsScreenState extends State<PatternsScreen> {
  List<InsightRecord> _records = const [];
  bool _loaded = false;

  /// Records-load failure (H1-08): a thrown/failed read is NOT an
  /// empty store. Kept separate from [_membershipResolveFailed]
  /// so a late records success can never clear a membership
  /// failure (or vice versa); either one puts the surface in the
  /// Slot 1 error state.
  bool _recordsLoadFailed = false;

  /// Membership-resolution failure (Juno's signed follow-up
  /// ruling): also lands in the Slot 1 error state — the same
  /// error string, the same retry, no membership-specific copy.
  bool _membershipResolveFailed = false;

  bool get _loadFailed => _recordsLoadFailed || _membershipResolveFailed;

  /// Tri-state gate (H1-05P): null means membership is genuinely
  /// unknown — the numbers decision is held, never guessed.
  bool? _isUnlimitedResolved;

  /// The pending state renders only while membership is unknown
  /// AND no failure has landed: the error state and the pending
  /// state never coexist (one state at a time).
  bool get _membershipPending =>
      _isUnlimitedResolved == null && !_loadFailed;

  /// Defined bound on the screen's own membership resolution
  /// (Juno follow-up condition 5): a resolution that has not
  /// answered inside this window counts as failed — no unbounded
  /// pending.
  static const Duration _membershipResolveTimeout = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    // Tri-state seed: explicit widget value wins; else the cache
    // snapshot ONLY when its membership is known (the Quick Log
    // discipline — seed if known, never guess if not).
    _isUnlimitedResolved = widget.isUnlimited ??
        (QuickLogCache.instance.snapshot.membershipKnown
            ? QuickLogCache.instance.snapshot.isUnlimited
            : null);
    if (widget.records != null) {
      _records = widget.records!;
      _loaded = true;
    } else {
      unawaited(_loadCached());
    }
    if (_isUnlimitedResolved == null) {
      unawaited(_resolveMembership());
    }
  }

  /// Cache read only. Reading the insight store is not a compute:
  /// [PatternsScreen.computeCallback] is never touched here or
  /// anywhere else in this screen.
  ///
  /// A failed read lands in the Slot 1 error state (H1-08); a
  /// successful read returning zero records is the legitimate
  /// new-user state and renders placeholders as before.
  Future<void> _loadCached() async {
    try {
      final loaded = widget.recordsLoader != null
          ? await widget.recordsLoader!()
          : await _readStoreRecords();
      if (!mounted) return;
      setState(() {
        _records = loaded;
        _loaded = true;
        _recordsLoadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _recordsLoadFailed = true;
      });
    }
  }

  /// Reads the insight store, distinguishing a genuine failure
  /// from an empty result. The real store goes through its
  /// failure-distinguishing read; duck-typed test stores keep the
  /// readAll/load/getAll chain, but if EVERY read throws, the
  /// failure propagates instead of reading as empty.
  Future<List<InsightRecord>> _readStoreRecords() async {
    final dynamic store =
        widget.insightStore ?? CorrelationInsightStore.instance;
    if (store is CorrelationInsightStore) {
      final map = await store.readAllOrThrow();
      return map.values.toList();
    }
    dynamic result;
    var ok = false;
    Object? failure;
    try {
      result = await store.readAll();
      ok = true;
    } catch (e) {
      failure = e;
      try {
        result = await store.load();
        ok = true;
      } catch (e) {
        failure = e;
        try {
          result = await store.getAll();
          ok = true;
        } catch (e) {
          failure = e;
        }
      }
    }
    if (!ok) {
      throw failure ?? StateError('insight store read failed');
    }
    if (result is List) {
      return result.whereType<InsightRecord>().toList();
    }
    if (result is Map) {
      return result.values.whereType<InsightRecord>().toList();
    }
    return const [];
  }

  /// The screen's own membership resolution for the unknown-gate
  /// path. Success resolves the gate in a single state update
  /// (the pending label disappears in that same update). Failure
  /// — a null result, a throw, or the resolve timeout — lands in
  /// the Slot 1 error state (Juno's signed follow-up ruling).
  Future<void> _resolveMembership() async {
    bool? result;
    try {
      result = await _loadMembershipOrNull().timeout(
        _membershipResolveTimeout,
        onTimeout: () => null,
      );
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _membershipResolveFailed = true;
        _loaded = true;
      });
    } else {
      setState(() {
        _isUnlimitedResolved = result;
        _membershipResolveFailed = false;
      });
    }
  }

  /// Loads membership through a future that can never complete
  /// with an error: any throw from the loader — synchronous, via
  /// a returned error future, or from an async loader body (the
  /// production shape: [_fetchMembershipFromBackend] is async) —
  /// becomes a null result here, inside this wrapper.
  ///
  /// This interposition matters: an async loader that throws
  /// before its first await returns an ALREADY error-completed
  /// future, and handing that future straight to
  /// [Future.timeout] let the error escape the try/catch in
  /// [_resolveMembership] as an uncaught async error (D-T02 pin
  /// (8b)) — the Slot 1 failure state was never reached. Awaiting
  /// the loader inside this async wrapper attaches its error
  /// handler at the moment the loader is invoked and converts
  /// the error to null before the timeout race ever sees a
  /// future, so the timeout only ever races a value/null
  /// completion (or the never-completing case it bounds).
  Future<bool?> _loadMembershipOrNull() async {
    try {
      return await (widget.membershipLoader != null
          ? widget.membershipLoader!()
          : _fetchMembershipFromBackend());
    } catch (_) {
      return null;
    }
  }

  Future<bool?> _fetchMembershipFromBackend() async {
    final membership = await TabsBackend().fetchMembershipOrNull();
    return membership?.isUnlimited;
  }

  /// Slot 1 retry: re-runs BOTH the records load and (while the
  /// gate is still unresolved) the membership resolution. The
  /// pending state may reappear for the fresh in-flight check;
  /// if either side fails again, the surface returns to the same
  /// Slot 1 error state.
  void _retry() {
    setState(() {
      _recordsLoadFailed = false;
      _membershipResolveFailed = false;
      if (widget.records == null) _loaded = false;
    });
    if (widget.records == null) unawaited(_loadCached());
    if (_isUnlimitedResolved == null) unawaited(_resolveMembership());
  }

  @override
  Widget build(BuildContext context) {
    final records = _loaded ? _records : const <InsightRecord>[];
    final display = records.isEmpty && _loaded
        ? placeholderRecords()
        : orderedRecords(records);
    // Numbers cards render only for a KNOWN unlimited gate:
    // known non-members omit them (as before), and while the
    // gate is unknown the decision is held (pending state) —
    // numbers are never presented as final on an unknown gate.
    final visible = collapseF2UnavailableRecords([
      for (final record in display)
        if (_isUnlimitedResolved == true ||
            record.state != InsightState.numbers)
          record,
    ]);
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        title: const Text(
          correlationTitle,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            correlationIntro,
            style: TextStyle(fontSize: 13, color: NotelColors.textSecondary),
          ),
          const SizedBox(height: 12),
          // Juno item 5 R5: the disclaimer renders EXACTLY ONCE on
          // this surface, below the intro.
          const Text(
            correlationSurfaceDisclaimer,
            style: TextStyle(fontSize: 11, color: NotelColors.textSecondary),
          ),
          const SizedBox(height: 16),
          if (_loadFailed) ...[
            // Slot 1 (Juno S1 + signed follow-up ruling): the
            // error state REPLACES the card list entirely — no
            // placeholder, progress, unavailable, or numbers
            // cards, no skeleton, and no pending label alongside
            // it. One state at a time.
            const Text(
              correlationLoadError,
              style: TextStyle(
                fontSize: 14,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _retry,
                child: const Text(correlationLoadRetryLabel),
              ),
            ),
          ] else ...[
            if (_membershipPending) ...[
              // H1-05P pending state (Juno S4): skeleton + the
              // pending label exactly once, only while membership
              // is genuinely unknown. Progress and unavailable
              // cards render normally below; numbers are held.
              const SkeletonGroup(
                child: SkeletonBox(height: 96, radius: 18),
              ),
              const SizedBox(height: 12),
              const Text(
                correlationMembershipPendingLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: NotelColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
            ],
            for (var i = 0; i < visible.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _InsightCard(record: visible[i]),
            ],
          ],
          const SizedBox(height: 94),
        ],
      ),
    );
  }
}

/// Compact sleep-duration format (founder's standing house rule:
/// sleep durations render compactly everywhere): always both
/// parts, e.g. 352 minutes -> `5h52m`, 300 -> `5h0m`.
String _compactSleepMinutes(double minutes) {
  final total = minutes.round();
  return '${total ~/ 60}h${total % 60}m';
}

/// Fixed display order (Juno R1): F1→F5, splits in engine order,
/// F5 anchors in their stored order. The sort is stable (original
/// index is the final tiebreaker) and never value-dependent.
List<InsightRecord> orderedRecords(List<InsightRecord> records) {
  const familyOrder = {'F1': 0, 'F2': 1, 'F3': 2, 'F4': 3, 'F5': 4};
  const f2SplitOrder = {
    'fluid-score': 0,
    'sodium-score': 1,
    'fluid-flare': 2,
    'sodium-flare': 3,
    'fluid-migraine': 4,
    'sodium-migraine': 5,
  };
  int splitRank(InsightRecord r) {
    if (r.familyId == 'F1') {
      // F1a (short nights) before F1b (below Sleep Need).
      return (r.splitId == 'F1b' || r.splitId.contains('need')) ? 1 : 0;
    }
    if (r.familyId == 'F2') return f2SplitOrder[r.splitId] ?? 99;
    return 0;
  }

  final indexed = records.asMap().entries.toList();
  indexed.sort((a, b) {
    final fa = familyOrder[a.value.familyId] ?? 99;
    final fb = familyOrder[b.value.familyId] ?? 99;
    if (fa != fb) return fa.compareTo(fb);
    final sa = splitRank(a.value);
    final sb = splitRank(b.value);
    if (sa != sb) return sa.compareTo(sb);
    return a.key.compareTo(b.key);
  });
  return [for (final e in indexed) e.value];
}

/// F2 unavailable collapse (Juno, Nov 8, 2026 — composition
/// sign-off (b) points 1–3): the engine emits one unavailable
/// record per F2 split (six), all carrying the single family-level
/// fact that no intake is logged yet. The surface renders that
/// fact ONCE: the first F2 unavailable record in display order
/// stands for the whole family at the family's fixed position,
/// and the rest are not rendered. Renderer only — the engine,
/// the store, and the per-split records are untouched, and only
/// the unavailable state collapses: progress and numbers F2 cards
/// stay per-split.
List<InsightRecord> collapseF2UnavailableRecords(
  List<InsightRecord> records,
) {
  var f2UnavailableSeen = false;
  final out = <InsightRecord>[];
  for (final record in records) {
    if (record.familyId == 'F2' &&
        record.state == InsightState.unavailable) {
      if (f2UnavailableSeen) continue;
      f2UnavailableSeen = true;
    }
    out.add(record);
  }
  return out;
}

/// Zero-count progress records for the global new-user state
/// (spec §3.5/§2.10), built LOCALLY by this surface: no
/// `placeholderRecords()` helper exists in the engine/store files
/// at the time this surface was written (flagged in the build
/// report). No statistics are computed here: every count is 0
/// precisely because no cached record exists. Group labels are
/// the copy file's pinned registry labels; F2 renders its
/// unavailable form (its input logging does not exist for a new
/// user), per spec §3.5.
List<InsightRecord> placeholderRecords() {
  InsightRecord progress(
    String familyId,
    String splitId,
    String labelA,
    String labelB,
  ) => InsightRecord(
    familyId: familyId,
    splitId: splitId,
    windowKey: correlationWindowKeyLast90,
    state: InsightState.progress,
    groups: [
      InsightGroup(label: labelA, n: 0),
      InsightGroup(label: labelB, n: 0),
    ],
    computedAtMs: 0,
    throughDate: '',
    inputFingerprint: '',
  );
  return [
    progress('F1', 'F1a', f1aGroupALabel, f1aGroupBLabel),
    progress('F1', 'F1b', f1bGroupALabel, f1bGroupBLabel),
    const InsightRecord(
      familyId: 'F2',
      splitId: '',
      windowKey: correlationWindowKeyLast90,
      state: InsightState.unavailable,
      groups: [],
      computedAtMs: 0,
      throughDate: '',
      inputFingerprint: '',
    ),
    progress('F3', 'F3', f3GroupALabel, f3GroupBLabel),
    progress('F4', 'F4', f4GroupALabel, f4GroupBLabel),
    progress('F5', 'F5', f5GroupALabel, f5GroupBLabel),
  ];
}

class _InsightCard extends StatefulWidget {
  final InsightRecord record;
  const _InsightCard({required this.record});

  @override
  State<_InsightCard> createState() => _InsightCardState();
}

class _InsightCardState extends State<_InsightCard> {
  bool _expanded = false;

  InsightRecord get _record => widget.record;

  bool get _isF5 => _record.familyId == 'F5';
  bool get _isF2 => _record.familyId == 'F2';
  bool get _isIncidence =>
      _record.incidence != null &&
      (_record.splitId.contains('flare') ||
          _record.splitId.contains('migraine'));

  String? get _splitHeader {
    if (!_isF2) return null;
    if (_record.splitId.startsWith('fluid')) return correlationFluidHeader;
    if (_record.splitId.startsWith('sodium')) return correlationSodiumHeader;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NotelColors.legacyDarkDivider),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _children(),
      ),
    );
  }

  List<Widget> _children() {
    switch (_record.state) {
      case InsightState.numbers:
        return _numbersChildren();
      case InsightState.progress:
        return _progressChildren();
      case InsightState.unavailable:
        return _unavailableChildren();
    }
  }

  Widget _headerText(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: NotelColors.textPrimary,
    ),
  );

  Widget _bodyText(String text) => Text(
    text,
    style: const TextStyle(fontSize: 14, color: NotelColors.textPrimary),
  );

  Widget _captionText(String text) => Text(
    text,
    style: const TextStyle(fontSize: 12, color: NotelColors.textSecondary),
  );

  /// S8 — F1–F4 cards only, and only when the record carries a
  /// through date (a stale record keeps its ORIGINAL date — the
  /// surface never substitutes today).
  Widget? _s8Line() {
    if (_isF5 || _record.throughDate.isEmpty) return null;
    return _captionText(correlationWindowLine(_record.throughDate));
  }

  List<Widget> _numbersChildren() {
    if (_isF5) return _f5NumbersChildren();
    final out = <Widget>[];
    final splitHeader = _splitHeader;
    if (splitHeader != null) {
      out.add(_headerText(splitHeader));
      out.add(const SizedBox(height: 8));
    } else if (_record.headerLabel != null) {
      out.add(_headerText(_record.headerLabel!));
      out.add(const SizedBox(height: 8));
    }
    // Lag line for the lagged score families (F1, F2 score splits).
    if (_record.familyId == 'F1' || (_isF2 && !_isIncidence)) {
      out.add(_captionText(correlationLagHeader));
      out.add(const SizedBox(height: 8));
    }
    if (_isIncidence) {
      final inc = _record.incidence!;
      out.add(
        _bodyText(
          _record.splitId.contains('migraine')
              ? correlationMigraineIncidenceSentence(
                  x: inc.x,
                  n: inc.n,
                  y: inc.y,
                  m: inc.m,
                )
              : correlationFlareIncidenceSentence(
                  x: inc.x,
                  n: inc.n,
                  y: inc.y,
                  m: inc.m,
                ),
        ),
      );
    } else {
      final a = _record.groups[0];
      final b = _record.groups[1];
      out.add(
        _bodyText(
          correlationComparisonSentence(
            groupALabel: a.label,
            groupAN: a.n,
            groupAMean: a.mean!,
            groupBLabel: b.label,
            groupBN: b.n,
            groupBMean: b.mean!,
          ),
        ),
      );
      // F3 co-occurrence (S5): only when the record carries a
      // co-occurrence computed from the same days. The copy
      // formatter takes pre-formatted strings, so the record's
      // sleep-minute values are formatted compactly here.
      final co = _record.coOccurrence;
      if (_record.familyId == 'F3' && co != null) {
        out.add(const SizedBox(height: 8));
        out.add(
          _bodyText(
            correlationCoOccurrenceSentence(
              groupADays: co.groupADays,
              confounderLabel: co.confounderLabel,
              valueA: _compactSleepMinutes(co.valueA),
              groupBDays: co.groupBDays,
              valueB: _compactSleepMinutes(co.valueB),
            ),
          ),
        );
      }
    }
    final s8 = _s8Line();
    if (s8 != null) {
      out.add(const SizedBox(height: 8));
      out.add(s8);
    }
    out.add(const SizedBox(height: 8));
    out.add(_captionText(correlationCaption));
    if (!_isIncidence) {
      out.add(_detailExpansion());
    }
    return out;
  }

  List<Widget> _f5NumbersChildren() {
    final header = _record.headerLabel ?? _record.subjectName;
    final before = _record.groups[0];
    final after = _record.groups[1];
    return [
      if (header != null) ...[_headerText(header), const SizedBox(height: 8)],
      _bodyText(medWindowBeforeLabel),
      _bodyText(medWindowValue(before.mean!, before.n)),
      // Juno S9 (micro-ruling): a neighboring same-med change
      // shortened this window — the note is mandatory wherever
      // its average renders, once per truncated window.
      if (_record.beforeTruncatedSpan != null) ...[
        const SizedBox(height: 8),
        _captionText(
          f5TruncationNote(
            window: 'before',
            spanDays: _record.beforeTruncatedSpan!,
            name: _record.subjectName ?? '',
          ),
        ),
      ],
      const SizedBox(height: 8),
      _bodyText(medWindowAfterLabel),
      _bodyText(medWindowValue(after.mean!, after.n)),
      if (_record.afterTruncatedSpan != null) ...[
        const SizedBox(height: 8),
        _captionText(
          f5TruncationNote(
            window: 'after',
            spanDays: _record.afterTruncatedSpan!,
            name: _record.subjectName ?? '',
          ),
        ),
      ],
      const SizedBox(height: 8),
      _captionText(medWindowRuleNote),
      const SizedBox(height: 8),
      _captionText(correlationCaption),
      // No S8 on F5: the family is event-anchored, not windowed.
    ];
  }

  /// Detail expansion: median lines per group (S2 discipline).
  /// The toggle is icon-only so every TEXT string on this surface
  /// stays inside Juno's ruled set or the record's own stored
  /// labels.
  Widget _detailExpansion() {
    // Component outcomes (scoreSleep/scoreHrv/scoreRestingHr) are
    // NOT rendered on this surface: Juno's ruled set has no
    // component label, so rendering them through the S2 sentence
    // would mislabel component averages as Daily Score averages.
    // Rendering is held pending a Juno-ruled component label; the
    // engine records keep carrying componentOutcomes untouched.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              color: NotelColors.textSecondary,
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
        ),
        if (_expanded) ...[
          for (final group in _record.groups)
            if (group.median != null)
              _bodyText(correlationMedianLine(group.median!)),
        ],
      ],
    );
  }

  List<Widget> _progressChildren() {
    final a = _record.groups.isNotEmpty
        ? _record.groups[0]
        : const InsightGroup(label: '', n: 0);
    final b = _record.groups.length > 1
        ? _record.groups[1]
        : const InsightGroup(label: '', n: 0);
    // F5 progress uses its pinned before/after group labels.
    final labelA = _isF5 ? f5GroupALabel : a.label;
    final labelB = _isF5 ? f5GroupBLabel : b.label;
    final out = <Widget>[];
    // F2 progress cards carry their ruled split header (Fluid
    // target / Sodium target), same style and position as the
    // numbers state, so fluid and sodium cards are distinguishable
    // in this state too (Juno, Nov 8, 2026 — composition sign-off
    // (b) point 2). No other family gains a header here.
    final splitHeader = _splitHeader;
    if (splitHeader != null) {
      out.add(_headerText(splitHeader));
      out.add(const SizedBox(height: 8));
    }
    out.add(
      _bodyText(
        correlationProgressSentence(
          groupALabel: labelA,
          groupAN: a.n,
          groupBLabel: labelB,
          groupBN: b.n,
        ),
      ),
    );
    final s8 = _s8Line();
    if (s8 != null) {
      out.add(const SizedBox(height: 8));
      out.add(s8);
    }
    // S3 caption: Juno's ruling is "every card, every time".
    out.add(const SizedBox(height: 8));
    out.add(_captionText(correlationCaption));
    return out;
  }

  List<Widget> _unavailableChildren() {
    return [
      _bodyText(_isF5 ? correlationUnavailableF5 : correlationUnavailableF2),
      const SizedBox(height: 8),
      // S3 caption: Juno's ruling is "every card, every time".
      _captionText(correlationCaption),
    ];
  }
}
