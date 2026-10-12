import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 (Team B) — Body Info tool, READ-ONLY port of the native
/// `BodyInfoScreen.kt` layout ("Body Info & Impact Map").
///
/// Data source: `decodeProfileList((await fetchProfile())['conditions'])`
/// — the server-synced conditions blob (plain name strings or
/// `{name: ...}` maps). Each condition renders as an impact-zone card in
/// the native expandable-card style.
///
/// Rendered (layout per native):
/// - Intro copy (verbatim native) + the purple "Medications tab" note.
/// - Body Impact Visualizer card with the accessibility icon and a
///   "N conditions tracked" / "All body zones normal" status line.
/// - "Your Conditions" section header + "N Active" count badge.
/// - One card per condition: icon badge, name, "Diagnosed or suspected
///   condition." detail.
/// - Empty state (check icon, "All Body Zones Normal") when the blob is
///   empty or the fetch fails — honest empty, never invented.
///
/// Note: the native screen's active impacts are AI-evaluated from log
/// entries, which this read-only port does not run. This port shows the
/// synced conditions list in the same visual language.
///
/// DEFERRED: logging lab draws / peptide shots / medication entries and
/// the AI impact analysis.

/// One read-only condition from the profile blob.
class BodyCondition {
  final String name;

  const BodyCondition({required this.name});

  /// Tolerant parse: null when no usable name. Never throws.
  static BodyCondition? fromJson(Map<String, dynamic> json) {
    try {
      final name = (json['name'] ?? json['condition'] ?? json['title'])
          ?.toString()
          .trim();
      if (name == null || name.isEmpty) return null;
      return BodyCondition(name: name);
    } catch (_) {
      return null;
    }
  }
}

/// Collects conditions from the decoded blob. Never throws.
List<BodyCondition> collectConditions(List<Map<String, dynamic>> decoded) {
  final out = <BodyCondition>[];
  final seen = <String>{};
  for (final map in decoded) {
    final c = BodyCondition.fromJson(map);
    if (c != null && seen.add(c.name.toLowerCase())) out.add(c);
  }
  return out;
}

class BodyInfoScreen extends StatefulWidget {
  /// Injectable for tests.
  final TabsBackend? backend;

  const BodyInfoScreen({super.key, this.backend});

  @override
  State<BodyInfoScreen> createState() => _BodyInfoScreenState();
}

class _BodyInfoScreenState extends State<BodyInfoScreen> {
  late final TabsBackend _backend;
  bool _loading = true;
  List<BodyCondition> _conditions = const [];

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await _backend.fetchProfile();
      final decoded = TabsBackend.decodeProfileList(profile?['conditions']);
      final conditions = collectConditions(decoded);
      if (!mounted) return;
      setState(() {
        _conditions = conditions;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Honest empty on any failure — nothing is invented.
      setState(() {
        _conditions = const [];
        _loading = false;
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
          'Body Info & Impact Map',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                color: NotelColors.primary,
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Track how medications, labs, peptide shots, and symptoms affect your body zones in real time.',
                      style: TextStyle(
                        fontSize: 14,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Note: Medication & peptide dose cards are active exclusively for entries logged directly from the Medications tab.',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: NotelColors.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _visualizerCard(),
                const SizedBox(height: 16),
                _sectionHeader(),
                const SizedBox(height: 12),
                if (_conditions.isEmpty)
                  _emptyState()
                else
                  ..._conditions.map(_conditionCard),
              ],
            ),
    );
  }

  Widget _visualizerCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.accessibility_new,
            size: 140,
            color: NotelColors.primary,
            semanticLabel: 'Body Visualizer',
          ),
          const SizedBox(height: 16),
          const Text(
            'Body Impact Visualizer',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _conditions.isEmpty
                ? 'All body zones normal'
                : '${_conditions.length} condition${_conditions.length == 1 ? '' : 's'} tracked',
            style: const TextStyle(
              fontSize: 14,
              color: NotelColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Your Conditions',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: NotelColors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '${_conditions.length} Active',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: NotelColors.primary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _conditionCard(BodyCondition condition) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: NotelColors.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: NotelColors.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(
                  color: NotelColors.primary,
                  width: 1.5,
                ),
              ),
              child: const Icon(
                Icons.medical_services,
                size: 22,
                color: NotelColors.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    condition.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Active',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: NotelColors.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Diagnosed or suspected condition.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.23,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(
            Icons.check_circle,
            size: 48,
            color: NotelColors.primary.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 12),
          const Text(
            'All Body Zones Normal',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'No conditions tracked in your profile yet.',
            style: TextStyle(
              fontSize: 13,
              color: NotelColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
