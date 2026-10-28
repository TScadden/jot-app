import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/correlation_insight_store.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

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
///   normally for everyone.
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

  /// Premium flag. When null, production reads
  /// [QuickLogCache.instance.snapshot] the way the other surfaces
  /// seed their gate (unknown membership reads as not unlimited,
  /// so numbers never leak on an unknown gate).
  final bool? isUnlimited;

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
    this.computeCallback,
  });

  @override
  State<PatternsScreen> createState() => _PatternsScreenState();
}

class _PatternsScreenState extends State<PatternsScreen> {
  List<InsightRecord> _records = const [];
  bool _loaded = false;

  bool get _isUnlimited =>
      widget.isUnlimited ?? QuickLogCache.instance.snapshot.isUnlimited;

  @override
  void initState() {
    super.initState();
    if (widget.records != null) {
      _records = widget.records!;
      _loaded = true;
      return;
    }
    unawaited(_loadCached());
  }

  /// Cache read only. Reading the insight store is not a compute:
  /// [PatternsScreen.computeCallback] is never touched here or
  /// anywhere else in this screen.
  Future<void> _loadCached() async {
    List<InsightRecord> loaded = const [];
    try {
      if (widget.recordsLoader != null) {
        loaded = await widget.recordsLoader!();
      } else {
        final dynamic store =
            widget.insightStore ?? CorrelationInsightStore.instance;
        dynamic result;
        try {
          result = await store.readAll();
        } catch (_) {
          try {
            result = await store.load();
          } catch (_) {
            result = await store.getAll();
          }
        }
        if (result is List) {
          loaded = result.whereType<InsightRecord>().toList();
        } else if (result is Map) {
          loaded = result.values.whereType<InsightRecord>().toList();
        }
      }
    } catch (_) {
      loaded = const [];
    }
    if (!mounted) return;
    setState(() {
      _records = loaded;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final records = _loaded ? _records : const <InsightRecord>[];
    final display = records.isEmpty && _loaded
        ? placeholderRecords()
        : orderedRecords(records);
    final visible = [
      for (final record in display)
        if (_isUnlimited || record.state != InsightState.numbers) record,
    ];
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
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _InsightCard(record: visible[i]),
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
    final out = <Widget>[
      _bodyText(
        correlationProgressSentence(
          groupALabel: labelA,
          groupAN: a.n,
          groupBLabel: labelB,
          groupBN: b.n,
        ),
      ),
    ];
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
