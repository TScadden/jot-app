import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

/// Body Info & Impact Map — port of the native `BodyInfoScreen.kt` +
/// `BodyInfoViewModel.kt` + `BodyImpactEngine.kt`.
///
/// Round 48 — the round-18 port showed only the profile conditions
/// blob and skipped the screen's actual feature. Native behavior,
/// now implemented:
/// 1. Log entries (sync pull `entries[]`, the same rows native syncs
///    into its local DB) are evaluated LOCALLY by a verbatim Dart port
///    of `BodyImpactEngine.evaluateLogs` — keyword rules per body
///    zone, severity-scaled active windows, medication/peptide rules
///    gated to Medications-Tab entries. Local impacts render first.
/// 2. The candidate entries (only those with a local impact) are then
///    sent to `POST /api/ai/body-impacts` with the profile context,
///    exactly like native's Gemini pass; a non-empty AI result
///    REPLACES the local list (native rule), with the same
///    med-tab gating for PEPTIDE / SYSTEMIC items. Any AI failure
///    keeps the local impacts — never invented, never blanked.
/// 3. Each impact is an expandable card: region icon, status, details,
///    a time-remaining badge; expanding shows LOGGED ENTRY DETAILS —
///    the original log text, the logged timestamp, and the active
///    window (native `ExpandableBodyZoneCard`).
/// 4. Empty state is native's: "All Body Zones Normal" + "Log a lab
///    draw, peptide shot, or medication entry to see real-time body
///    impact tracking."
///
/// The profile conditions list from round 18 is kept BELOW the impact
/// zones as reference ("Your Conditions") — it is real synced data,
/// shown only when present.
///
/// Sync-DTO note (same as the History screen's identity checks): log
/// entries carry no `source` field over sync, so "from the
/// Medications Tab" is detected the Flutter way — `chips` containing
/// "Medication Tab", or the entry text containing "logged from
/// medications tab" (native checks both its source field and text).

/// One evaluated body impact (port of native `EvaluatedBodyImpact`).
class BodyImpact {
  final String id;
  final String regionId; // HEAD, EYES, LEFT_ARM, …
  final String regionName;
  final String status;
  final String details;
  final Color color;
  final IconData icon;
  final int timestampMs;
  final int durationMinutes;
  final String originalLogText;
  final int? relatedLogId;

  const BodyImpact({
    required this.id,
    required this.regionId,
    required this.regionName,
    required this.status,
    required this.details,
    required this.color,
    required this.icon,
    required this.timestampMs,
    required this.durationMinutes,
    this.originalLogText = '',
    this.relatedLogId,
  });

  int get expiresAtMs => timestampMs + durationMinutes * 60 * 1000;

  /// Native `getTimeRemainingText`: "0m" when expired, else
  /// "Xh Ym" / "Ym" / "<1m".
  String timeRemainingText(int nowMs) {
    final remaining = expiresAtMs - nowMs;
    if (remaining <= 0) return '0m';
    final hours = remaining ~/ (60 * 60 * 1000);
    final minutes = (remaining ~/ (60 * 1000)) % 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m';
    return '<1m';
  }
}

bool _containsAny(String text, List<String> keywords) =>
    keywords.any((k) => text.contains(k));

/// Whether an entry counts as logged from the Medications Tab (see
/// the class doc for the sync-DTO identity rule).
bool isMedTabEntry(QuickLogEntry entry) {
  final text = '${entry.body} ${entry.manualText} ${entry.chips}'.toLowerCase();
  return entry.chips.contains('Medication Tab') ||
      text.contains('logged from medications tab');
}

String _substringAfter(String s, String delim) {
  final i = s.indexOf(delim);
  return i == -1 ? s : s.substring(i + delim.length);
}

String _substringBefore(String s, String delim) {
  final i = s.indexOf(delim);
  return i == -1 ? s : s.substring(0, i);
}

/// Verbatim port of native `BodyImpactEngine.evaluateLogs`.
/// [nowMs] is injectable for tests. Only impacts whose active window
/// has not expired are returned, newest first.
List<BodyImpact> evaluateBodyImpacts(List<QuickLogEntry> entries, int nowMs) {
  final results = <BodyImpact>[];

  for (final entry in entries) {
    final text =
        '${entry.body} ${entry.manualText} ${entry.chips}'.trim().toLowerCase();
    final displayText = [
      if (entry.body.isNotEmpty) entry.body,
      if (entry.manualText.isNotEmpty) entry.manualText,
    ].join(' · ');

    final isSevere = _containsAny(
        text, ['sharp', 'severe', 'extreme', 'terrible', 'intense', 'heavy']);
    final isMild =
        _containsAny(text, ['mild', 'slight', 'minor', 'dull', 'light']);
    final ageHours = (nowMs - entry.timestamp) ~/ (60 * 60 * 1000);

    bool active(int durationHours) =>
        nowMs < entry.timestamp + durationHours * 60 * 60 * 1000;

    // 1. Headaches & Neurological (1–6h window)
    if (_containsAny(text, [
      'headache', 'migraine', 'dizzy', 'dizziness', 'brain fog', 'head pressure'
    ])) {
      final duration = text.contains('migraine')
          ? (isSevere ? 6 : 4)
          : isSevere
              ? 3
              : isMild
                  ? 1
                  : 2;
      if (active(duration)) {
        results.add(BodyImpact(
          id: 'head_${entry.id}',
          regionId: 'HEAD',
          regionName: 'Head & Neurological',
          status: 'Symptom Active (${ageHours}h ago)',
          details:
              'Head symptoms logged. Ensure adequate hydration, rest, and electrolyte balance.',
          color: const Color(0xFFFF7043),
          icon: Icons.psychology,
          timestampMs: entry.timestamp,
          durationMinutes: duration * 60,
          originalLogText: displayText,
          relatedLogId: entry.id,
        ));
      }
    }

    // 2. Labs / Blood Draws (4–6h window)
    if (_containsAny(text, [
      'lab', 'blood draw', 'bloodwork', 'cbc', 'venipuncture', 'phlebotomy',
      'blood test'
    ])) {
      final duration = (isSevere || text.contains('multiple')) ? 6 : 4;
      if (active(duration)) {
        final isLeftArm = text.contains('left') || text.contains('l arm');
        final isRightArm = text.contains('right') || text.contains('r arm');
        results.add(BodyImpact(
          id: 'lab_${entry.id}',
          regionId: isRightArm && !isLeftArm ? 'RIGHT_ARM' : 'LEFT_ARM',
          regionName: 'Arm (Vein Zone)',
          status: 'Tender / Post-Lab Draw (${ageHours}h ago)',
          details:
              'Blood draw logged. Drink extra water today to help replenish fluid & blood volume.',
          color: const Color(0xFFFF5252),
          icon: Icons.water_drop,
          timestampMs: entry.timestamp,
          durationMinutes: duration * 60,
          originalLogText: displayText,
          relatedLogId: entry.id,
        ));
      }
    }

    final strictlyFromMedTab = isMedTabEntry(entry);

    // 3. Peptide Shots & SubQ Injections (24h, Medications Tab only)
    if (strictlyFromMedTab &&
        _containsAny(text, [
          'peptide', 'shot', 'injection', 'subq', 'needle', 'pin',
          'semaglutide', 'tirzepatide'
        ])) {
      if (active(24)) {
        results.add(BodyImpact(
          id: 'injection_${entry.id}',
          regionId: 'PEPTIDE',
          regionName: 'Peptide Shot',
          status: 'Peptide Shot (${ageHours}h ago)',
          details:
              'Peptide shot logged. Remember to rotate to the opposite side or thigh for your next dose.',
          color: const Color(0xFFAB47BC),
          icon: Icons.vaccines,
          timestampMs: entry.timestamp,
          durationMinutes: 24 * 60,
          originalLogText: displayText,
          relatedLogId: entry.id,
        ));
      }
    }

    // 4. Ocular / Eyes (12–18h window)
    if (_containsAny(text, [
      'dry eyes', 'blurred vision', 'eye strain', 'eye pressure', 'vision',
      'eyes'
    ])) {
      final duration = isSevere ? 18 : 12;
      if (active(duration)) {
        results.add(BodyImpact(
          id: 'eyes_${entry.id}',
          regionId: 'EYES',
          regionName: 'Eyes & Ocular Area',
          status: 'Side Effect Watch (${ageHours}h ago)',
          details:
              'Ocular symptoms logged. Keep eyes hydrated with drops and monitor for sensitivity.',
          color: const Color(0xFFFFB300),
          icon: Icons.visibility,
          timestampMs: entry.timestamp,
          durationMinutes: duration * 60,
          originalLogText: displayText,
          relatedLogId: entry.id,
        ));
      }
    }

    // 5. GI / Stomach (4–8h window)
    if (_containsAny(text, [
      'nausea', 'stomach ache', 'upset stomach', 'reflux', 'gi distress',
      'cramps'
    ])) {
      final duration = isSevere ? 8 : 4;
      if (active(duration)) {
        results.add(BodyImpact(
          id: 'stomach_${entry.id}',
          regionId: 'ABDOMEN',
          regionName: 'Stomach & GI Tract',
          status: 'GI Strain (${ageHours}h ago)',
          details:
              'Digestive strain logged. Consider lighter meals and stay hydrated.',
          color: const Color(0xFF26A69A),
          icon: Icons.restaurant,
          timestampMs: entry.timestamp,
          durationMinutes: duration * 60,
          originalLogText: displayText,
          relatedLogId: entry.id,
        ));
      }
    }

    // 6. Back / Spine (1–4h window)
    if (_containsAny(text, [
      'back pain', 'back ache', 'sharp back pain', 'lower back', 'upper back',
      'spine', 'lumbar', 'back'
    ])) {
      final duration = (isSevere || text.contains('sharp'))
          ? 4
          : isMild
              ? 1
              : 3;
      if (active(duration)) {
        results.add(BodyImpact(
          id: 'back_${entry.id}',
          regionId: 'BACK',
          regionName: 'Back & Spine',
          status: 'Musculoskeletal / Pain (${ageHours}h ago)',
          details:
              'Back pain logged. Consider gentle stretching, posture adjustments, or heat therapy.',
          color: const Color(0xFFEF5350),
          icon: Icons.fitness_center,
          timestampMs: entry.timestamp,
          durationMinutes: duration * 60,
          originalLogText: displayText,
          relatedLogId: entry.id,
        ));
      }
    }

    // 7. General Pain & Muscle Soreness catch-all (12h window)
    if (_containsAny(text, ['pain', 'sore', 'ache', 'cramp', 'tender', 'stiff'])) {
      final isChest = _containsAny(text, ['chest', 'rib', 'heart']);
      final isLeg =
          _containsAny(text, ['leg', 'thigh', 'knee', 'calf', 'hamstring']);
      final isArm =
          _containsAny(text, ['bicep', 'tricep', 'shoulder', 'elbow', 'wrist']);
      if (active(12)) {
        final (region, regionLabel) = isChest
            ? ('CHEST', 'Chest & Ribs')
            : isLeg
                ? ('THIGHS', 'Legs & Thighs')
                : isArm
                    ? ('LEFT_ARM', 'Arm & Shoulder')
                    : ('BACK', 'Musculoskeletal / Back');
        // Only add if the region isn't already covered by a
        // higher-priority match (native rule).
        if (results.every((r) => r.regionId != region)) {
          results.add(BodyImpact(
            id: 'symptom_${entry.id}',
            regionId: region,
            regionName: regionLabel,
            status: 'Symptom / Pain (${ageHours}h ago)',
            details:
                'Pain or soreness logged. Monitor for changes and rest affected area.',
            color: const Color(0xFFFF7043),
            icon: Icons.warning,
            timestampMs: entry.timestamp,
            durationMinutes: 12 * 60,
            originalLogText: displayText,
            relatedLogId: entry.id,
          ));
        }
      }
    }

    // 8. Medication Dose (Medications Tab only, not peptide/injection)
    final isPeptideOrInjection = _containsAny(
        text, ['peptide', 'shot', 'injection', 'subq', 'needle', 'pin']);
    if (strictlyFromMedTab && !isPeptideOrInjection) {
      final duration = _containsAny(text,
              ['twice daily', 'twice a day', '2x daily', '2x a day', 'bid', '12h'])
          ? 12
          : _containsAny(text,
                  ['three times', '3x daily', '3x a day', 'tid', '8h'])
              ? 8
              : _containsAny(text,
                      ['four times', '4x daily', '4x a day', 'qid', '6h'])
                  ? 6
                  : _containsAny(
                          text, ['once daily', 'once a day', 'qd', '24h'])
                      ? 24
                      : 12;
      if (active(duration)) {
        final medName = _substringBefore(
                _substringAfter(
                    _substringAfter(displayText, 'Took Medication:'),
                    'Medication:'),
                '(')
            .trim();
        final medLower = medName.toLowerCase();
        final specificDetails = medLower.contains('ivabradine') ||
                medLower.contains('corlanor')
            ? 'Ivabradine (7.5mg active). Primary Goal: Lowers heart rate by inhibiting funny current (If). Key Side Effects: Phosphenes (luminous visual bursts), bradycardia (slow heart rate), dizziness, 1st-degree AV block, & fatigue.'
            : medLower.contains('semaglutide') ||
                    medLower.contains('ozempic') ||
                    medLower.contains('wegovy')
                ? 'Semaglutide GLP-1 receptor agonist. Primary Goal: Glycemic control & weight regulation. Key Side Effects: Nausea, delayed gastric emptying, acid reflux, constipation, & fatigue.'
                : medLower.contains('tirzepatide') ||
                        medLower.contains('mounjaro') ||
                        medLower.contains('zepbound')
                    ? 'Tirzepatide Dual GIP/GLP-1 agonist. Primary Goal: Metabolic & weight regulation. Key Side Effects: Nausea, mild diarrhea, decreased appetite, & injection site sensitivity.'
                    : medLower.contains('metformin')
                        ? 'Metformin. Primary Goal: Insulin sensitivity. Key Side Effects: GI distress, cramping, B12 depletion watch, & mild nausea.'
                        : medLower.contains('lisinopril') ||
                                medLower.contains('losartan') ||
                                medLower.contains('amlodipine')
                            ? 'Antihypertensive medication. Primary Goal: Blood pressure management. Key Side Effects: Dizziness on standing, dry cough, mild fatigue, & electrolyte shifts.'
                            : medName.isNotEmpty
                                ? 'Logged: $medName. Gemini AI monitoring active response. Common Side Effects: Mild dizziness, GI changes, fatigue, & blood pressure shifts.'
                                : 'Medication dose logged. Gemini AI tracking systemic side-effects, therapeutic goals, and active duration.';
        results.add(BodyImpact(
          id: 'med_${entry.id}',
          regionId: 'SYSTEMIC',
          regionName:
              medName.isNotEmpty ? 'Systemic ($medName)' : 'Systemic / Medication Active',
          status: 'Medication Active (${ageHours}h ago)',
          details: specificDetails,
          color: const Color(0xFF4ECDC4),
          icon: Icons.medication,
          timestampMs: entry.timestamp,
          durationMinutes: duration * 60,
          originalLogText: displayText,
          relatedLogId: entry.id,
        ));
      }
    }
  }

  results.sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
  return results;
}

/// Region color for AI-returned impacts (native BodyInfoViewModel map).
Color bodyRegionColor(String regionId) {
  switch (regionId.toUpperCase()) {
    case 'HEAD':
      return const Color(0xFFFF7043);
    case 'EYES':
      return const Color(0xFFFFB300);
    case 'LEFT_ARM':
    case 'RIGHT_ARM':
      return const Color(0xFFFF5252);
    case 'ABDOMEN':
      return const Color(0xFF26A69A);
    case 'LEFT_SIDE':
    case 'RIGHT_SIDE':
      return const Color(0xFFAB47BC);
    case 'BACK':
      return const Color(0xFFEF5350);
    default:
      return const Color(0xFF42A5F5);
  }
}

/// Maps the AI body-impacts response (`result.impacts`) onto
/// [BodyImpact]s, native BodyInfoViewModel rules: unknown regions fall
/// back to BACK; PEPTIDE / SYSTEMIC items are dropped unless their log
/// entry came from the Medications Tab. Tolerant parsing — malformed
/// items are skipped, never thrown.
List<BodyImpact> mapAiBodyImpacts(
    dynamic responseBody, List<QuickLogEntry> entries) {
  final result = responseBody is Map ? responseBody['result'] : null;
  final items = result is Map ? result['impacts'] : null;
  if (items is! List) return const [];
  final byId = {for (final e in entries) e.id: e};
  final out = <BodyImpact>[];
  for (final raw in items) {
    if (raw is! Map) continue;
    final logIdRaw = raw['logId'];
    final logId = logIdRaw is num
        ? logIdRaw.toInt()
        : int.tryParse('${logIdRaw ?? ''}');
    if (logId == null) continue;
    final entry = byId[logId];
    final regionRaw = '${raw['region'] ?? ''}'.toUpperCase();
    const known = {
      'HEAD', 'EYES', 'LEFT_ARM', 'RIGHT_ARM', 'CHEST', 'ABDOMEN',
      'LEFT_SIDE', 'RIGHT_SIDE', 'BACK', 'THIGHS', 'PEPTIDE', 'SYSTEMIC',
    };
    final region = known.contains(regionRaw) ? regionRaw : 'BACK';
    final isMedOrPeptide = region == 'PEPTIDE' || region == 'SYSTEMIC';
    if (isMedOrPeptide && (entry == null || !isMedTabEntry(entry))) {
      continue;
    }
    final durationRaw = raw['durationMinutes'];
    final duration = durationRaw is num
        ? durationRaw.toInt()
        : int.tryParse('${durationRaw ?? ''}') ?? 24 * 60;
    out.add(BodyImpact(
      id: 'ai_${logId}_$region',
      regionId: region,
      regionName: '${raw['regionName'] ?? ''}',
      status: '${raw['status'] ?? ''}',
      details: '${raw['details'] ?? ''}',
      color: bodyRegionColor(region),
      icon: Icons.warning,
      timestampMs: entry?.timestamp ?? DateTime.now().millisecondsSinceEpoch,
      durationMinutes: duration,
      originalLogText:
          entry != null ? '${entry.body} ${entry.manualText}'.trim() : '',
      relatedLogId: logId,
    ));
  }
  return out;
}

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
  bool _aiAnalyzing = false;
  List<BodyImpact> _impacts = const [];
  List<BodyCondition> _conditions = const [];
  String? _expandedId;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _load();
  }

  Future<void> _load() async {
    List<QuickLogEntry> entries = const [];
    List<BodyCondition> conditions = const [];
    Map<String, dynamic>? profile;
    try {
      profile = await _backend.fetchProfile();
      conditions = collectConditions(
          TabsBackend.decodeProfileList(profile?['conditions']));
      entries = await _backend.fetchLogEntryDtos();
    } catch (_) {
      // Honest empty on any failure — nothing is invented.
    }
    final local = evaluateBodyImpacts(
        entries, DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    setState(() {
      _conditions = conditions;
      _impacts = local;
      _loading = false;
    });

    // Native step 2: AI pass over ONLY the candidate entries (those
    // with a local impact). A non-empty AI result replaces the local
    // list; any failure keeps the local list untouched.
    final candidateIds =
        local.map((i) => i.relatedLogId).whereType<int>().toSet();
    if (candidateIds.isEmpty) return;
    final candidates =
        entries.where((e) => candidateIds.contains(e.id)).toList();
    setState(() => _aiAnalyzing = true);
    try {
      final userContext = '${profile?['userContext'] ?? ''}';
      final meds = '${profile?['medications'] ?? ''}';
      final response = await _backend.postAi('/api/ai/body-impacts', {
        'entries': candidates.map((e) => e.toSyncJson()).toList(),
        'userContext':
            'User Profile Context: $userContext\nProfile Medications: $meds',
      }).timeout(const Duration(seconds: 20));
      final aiImpacts = mapAiBodyImpacts(response, entries);
      if (!mounted) return;
      if (aiImpacts.isNotEmpty) {
        setState(() => _impacts = aiImpacts);
      }
    } catch (_) {
      // Local impacts stay — honest, already on screen.
    } finally {
      if (mounted) setState(() => _aiAnalyzing = false);
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
          ? const SkeletonGroup(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 110),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(height: 152, radius: 20),
                  SizedBox(height: 16),
                  SkeletonBox(height: 96, radius: 20),
                  SizedBox(height: 16),
                  SkeletonBox(height: 96, radius: 20),
                ],
              ),
            ),
          )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
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
                _impactsHeader(),
                const SizedBox(height: 12),
                if (_impacts.isEmpty)
                  _emptyState()
                else
                  ..._impacts.map(_impactCard),
                if (_conditions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _conditionsHeader(),
                  const SizedBox(height: 12),
                  ..._conditions.map(_conditionCard),
                ],
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
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
            _impacts.isNotEmpty
                ? '${_impacts.length} active body zones tracked'
                : _conditions.isEmpty
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

  Widget _impactsHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Expanded(
          child: Text(
            'Active Body Impact Zones',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
        ),
        if (_aiAnalyzing)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: NotelColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      color: NotelColors.primary, strokeWidth: 1.5),
                ),
                SizedBox(width: 6),
                Text(
                  'AI Analyzing...',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.primary,
                  ),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: NotelColors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '${_impacts.length} Active',
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

  Widget _impactCard(BodyImpact impact) {
    final expanded = _expandedId == impact.id;
    final now = DateTime.now().millisecondsSinceEpoch;
    final logged = DateTime.fromMillisecondsSinceEpoch(impact.timestampMs);
    final loggedText =
        '${_monthName(logged.month)} ${logged.day}, ${logged.year} at ${_hour12(logged)}';
    final totalMins = impact.durationMinutes;
    final hrs = totalMins ~/ 60;
    final mins = totalMins % 60;
    final durationStr = hrs > 0 && mins > 0
        ? '${hrs}h ${mins}m'
        : hrs > 0
            ? '${hrs}h'
            : '${mins}m';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () =>
            setState(() => _expandedId = expanded ? null : impact.id),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: NotelColors.surface.withValues(alpha: expanded ? 0.95 : 0.8),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: expanded
                  ? impact.color
                  : Colors.white.withValues(alpha: 0.05),
              width: expanded ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: impact.color.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(color: impact.color, width: 1.5),
                    ),
                    child: Icon(impact.icon, size: 22, color: impact.color),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                impact.regionName,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: NotelColors.textPrimary,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: impact.color.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.schedule,
                                      size: 12, color: impact.color),
                                  const SizedBox(width: 4),
                                  Text(
                                    impact.timeRemainingText(now),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: impact.color,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          impact.status,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: impact.color,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          impact.details,
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.23,
                            color: NotelColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: NotelColors.textSecondary,
                  ),
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: NotelColors.surfaceHigh.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LOGGED ENTRY DETAILS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                          color: impact.color,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        impact.originalLogText.isNotEmpty
                            ? '"${impact.originalLogText}"'
                            : 'Logged Entry #${impact.relatedLogId ?? ''}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Logged: $loggedText',
                        style: const TextStyle(
                          fontSize: 11,
                          color: NotelColors.textSecondary,
                        ),
                      ),
                      Text(
                        'Active Window: $durationStr',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: impact.color,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _conditionsHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Your Conditions',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: NotelColors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '${_conditions.length} Active',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: NotelColors.primaryText,
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
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
                border: Border.all(color: NotelColors.primary, width: 1.5),
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
            'Log a lab draw, peptide shot, or medication entry to see real-time body impact tracking.',
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

  String _monthName(int m) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return (m >= 1 && m <= 12) ? months[m] : '';
  }

  /// "h:mm AM/PM" — native "MMM d, yyyy 'at' h:mm a" time part.
  String _hour12(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    final ap = d.hour < 12 ? 'AM' : 'PM';
    return '$h:$mm $ap';
  }
}
