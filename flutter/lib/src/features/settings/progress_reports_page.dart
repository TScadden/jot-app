import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/clinician_report_pdf.dart';
import 'package:tabs_lab/src/data/downloads_saver.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 66 — Progress Reports page (Settings → AI & Clinical
/// Advocate → Progress Reports), the Flutter port of native
/// `ProgressReportsScreen.kt`. Renders inside the Settings scroll
/// column; the Settings top bar shows "Progress Reports" and its
/// back button returns to AI & Clinical Advocate (unchanged).
///
/// Layout mirrors native's cards: Overview (type picker, custom
/// category checkboxes, time range, stats, honest coverage,
/// medical disclaimer) → Preview (summary line, hourly chart,
/// generation state, Export button, last-exported, "What's in
/// this report" disclosure) → Details (per-category share rows) →
/// Appointment card. PDF generation + share confirmation follow
/// native's pipeline (see progress_report.dart / _pdf.dart).
class ProgressReportsPage extends StatefulWidget {
  final SettingsProfileData profileData;
  final TabsBackend backend;
  final SettingsStore store;
  final HealthConnectService? healthConnectService;
  final ReminderNotificationService? notificationService;

  /// Round 65's extracted-text store (Settings passes its shared
  /// instance; defaults to the same singleton).
  final KnowledgeExtractionStore? knowledgeStore;

  /// Test seams: production uses Printing.sharePdf + a save into
  /// the app documents directory.
  final Future<void> Function(List<int> bytes, String fileName)? sharePdf;
  final Future<String> Function(List<int> bytes, String fileName)? savePdf;

  /// Test seam for the automatic Downloads copy (Juno Ruling 2):
  /// production uses [ReportDownloadsSaver] over the Health Connect
  /// bridge channel (MediaStore). Returns whether the copy landed;
  /// a throw is treated the same as a false return — a failed
  /// Downloads copy never blocks generation or sharing.
  final Future<bool> Function(List<int> bytes, String fileName)?
      saveToDownloads;
  final ReportGenerationPipeline? pipeline;

  /// Test seam for the Phase 1 item 3 one-page clinician report
  /// (defaults to a pipeline wired to the page's backend + the
  /// stored-score history).
  final ClinicianReportPipeline? clinicianPipeline;

  const ProgressReportsPage({
    super.key,
    required this.profileData,
    required this.backend,
    required this.store,
    this.healthConnectService,
    this.notificationService,
    this.knowledgeStore,
    this.sharePdf,
    this.savePdf,
    this.saveToDownloads,
    this.pipeline,
    this.clinicianPipeline,
  });

  @override
  State<ProgressReportsPage> createState() => _ProgressReportsPageState();
}

/// Native appointment-reminder notification id (NotificationHelper
/// 770002). Note: 770002 sits INSIDE the event-counter hash range
/// (700000–799998) — the same accepted exposure as check-in 770001,
/// not its own disjoint block. Kept as native's id regardless.
const appointmentReminderId = 770002;

/// Builds the report's profile input from the Settings profile
/// data (the sync pull's decoded blobs, via [SettingsProfileData]).
///
/// Medications (report-pdf fix, Juno Ruling 1): the active list is
/// the shared medication model's own filter —
/// `!entry.isDeleted && !entry.isArchived`
/// ([activeMedicationEntries]) — where
/// [MedicationEntry.isArchived] is the archived stamp OR
/// `!isPresent` (medications.dart, R35 precedent). Filtering on
/// `isPresent` alone was the defect: a row carrying
/// `isArchived == true` with `isPresent == true` passed it and an
/// archived medication (escitalopram, archived Oct 16, 2026)
/// rendered as active in the report. Entries keep their stored
/// record order and their stored name/dose/frequency — nothing is
/// sorted, deduped, or rewritten here.
ReportProfileInput reportProfileInputFromSettings(SettingsProfileData d) {
  final conditions = <String>[
    for (final row in d.conditions)
      if ('${row['name'] ?? ''}'.trim().isNotEmpty) '${row['name']}'.trim(),
  ];
  final parsed = <MedicationEntry>[];
  for (final row in d.medications) {
    final m = MedicationEntry.fromBlobRow(row);
    if (m != null) parsed.add(m);
  }
  return ReportProfileInput(
    userContext: d.userContext,
    age: d.age ?? 0,
    heightCm: d.heightCm ?? 0,
    weightKg: d.weightKg ?? 0,
    gender: d.gender,
    conditions: conditions,
    activeMedications: activeMedicationEntries(parsed),
    // Item 3: the full parsed list rides along for the clinician
    // report's declared-form change derivation ONLY — the active
    // list above remains the sole source of the printed med list.
    allMedications: parsed,
  );
}

class _ProgressReportsPageState extends State<ProgressReportsPage> {
  ReportFocus _focus = ReportFocus.health;
  bool _last30Days = true;
  Set<int> _customIds = {};
  bool _customSeeded = false;

  List<QuickLogCategory> _categories = const [];
  List<QuickLogEntry> _entries = const [];
  bool _loaded = false;

  int? _selectedHour;
  bool _showSources = false;

  ReportStage? _stage;
  bool _cancelRequested = false;
  String? _failureMessage;
  bool _failureAllowRaw = false;

  int _lastExportMs = 0;
  String? _appointmentDateIso;
  String _appointmentTypeKey = 'health';
  String? _pickedDateIso;
  ReportFocus _appointmentFocus = ReportFocus.health;

  ReportReady? _pendingShare;

  TabsBackend get _backend => widget.backend;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait<dynamic>([
      _backend.fetchLogCategories(),
      _backend.fetchLogEntryDtos(),
      widget.store.getReportLastType(),
      widget.store.getReportLastRange30d(),
      widget.store.getReportLastExportMs(),
      widget.store.getReportAppointmentDate(),
      widget.store.getReportAppointmentType(),
    ]);
    if (!mounted) return;
    setState(() {
      _categories = results[0] as List<QuickLogCategory>;
      _entries = results[1] as List<QuickLogEntry>;
      _focus = ReportFocus.fromKey(results[2] as String);
      _last30Days = results[3] as bool;
      _lastExportMs = results[4] as int;
      _appointmentDateIso = results[5] as String?;
      _appointmentTypeKey = results[6] as String;
      _appointmentFocus = ReportFocus.fromKey(_appointmentTypeKey);
      _loaded = true;
      _seedCustomIfNeeded();
    });
  }

  void _seedCustomIfNeeded() {
    // Native: preselect ALL categories the first time Custom opens
    // (only while the custom set is still empty).
    if (_focus == ReportFocus.custom &&
        !_customSeeded &&
        _customIds.isEmpty &&
        _categories.isNotEmpty) {
      _customIds = _categories.map((c) => c.id).toSet();
      _customSeeded = true;
    }
  }

  Future<void> _pickFocus(ReportFocus f) async {
    setState(() {
      _focus = f;
      _seedCustomIfNeeded();
    });
    await widget.store.setReportLastType(f.key);
  }

  Future<void> _pickRange(bool isMonth) async {
    setState(() => _last30Days = isMonth);
    await widget.store.setReportLastRange30d(isMonth);
  }

  List<QuickLogCategory> get _selected =>
      resolveReportCategories(_categories, _focus, _customIds);

  ReportProfileInput get _profileInput =>
      reportProfileInputFromSettings(widget.profileData);

  Future<String> _defaultSave(List<int> bytes, String fileName) async {
    // The saved copy lands in the app documents directory; the
    // share sheet shares the same bytes. The automatic Downloads
    // copy is a SEPARATE step over the same bytes (Juno Ruling 2 —
    // see [_defaultSaveToDownloads]); this app-private save is
    // unchanged.
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// The automatic Downloads copy (Juno Ruling 2): the bridge
  /// plugin's MediaStore writer (the CSV bridge's channel, extended
  /// with a byte hand-off — see downloads_saver.dart). Never throws:
  /// the saver reports failure as false.
  Future<bool> _defaultSaveToDownloads(
          List<int> bytes, String fileName) =>
      ReportDownloadsSaver.instance.savePdf(bytes: bytes, fileName: fileName);

  Future<void> _generate({bool forceRaw = false}) async {
    if (_stage != null) return;
    setState(() {
      _cancelRequested = false;
      _failureMessage = null;
      _failureAllowRaw = false;
      _stage = ReportStage.collecting;
    });
    final pipeline = widget.pipeline ??
        ReportGenerationPipeline(
          collector: ReportDataCollector(
            backend: _backend,
            hc: widget.healthConnectService ?? HealthConnectService(),
            // R65's document store, read the same way native's
            // collector reads its DAO: the pull's document rows,
            // each with its on-device extracted text (blank/failed
            // extractions skipped — native's rule).
            documentsLoader: () async {
              final pull = await _backend.fetchSyncPull();
              final docs = KnowledgeDocumentMeta.listFromPull(pull);
              if (docs.isEmpty) return const [];
              final store =
                  widget.knowledgeStore ?? KnowledgeExtractionStore.instance;
              await store.load(await _backend.readEmail());
              return [
                for (final d in docs)
                  if (store.textFor(d.id) case final t?
                      when t.trim().isNotEmpty)
                    t,
              ];
            },
          ),
          backend: _backend,
        );
    final outcome = await pipeline.generate(
      selectedCategories: _selected,
      last30Days: _last30Days,
      profile: _profileInput,
      forceRawFallback: forceRaw,
      onStage: (s) {
        if (mounted) setState(() => _stage = s);
      },
      isCancelled: () => _cancelRequested,
      renderPdf: (snapshot, aiSummary,
              {required bool isRawFallback, String? aiFailureReason}) =>
          buildReportPdfBytes(snapshot,
              aiSummary: aiSummary,
              isRawFallback: isRawFallback,
              aiFailureReason: aiFailureReason),
      savePdf: widget.savePdf ?? _defaultSave,
      saveToDownloads: widget.saveToDownloads ?? _defaultSaveToDownloads,
    );
    if (!mounted) return;
    setState(() => _stage = null);
    if (_cancelRequested) return;
    switch (outcome) {
      case ReportReady ready:
        // Vera's feature (native): hold the file for an explicit
        // share confirmation — never open the share sheet
        // unprompted.
        setState(() => _pendingShare = ready);
        _showShareConfirmation();
      case ReportFailed failed:
        if (failed.message == 'Cancelled') return;
        setState(() {
          _failureMessage = failed.message;
          _failureAllowRaw = failed.allowRawFallback;
        });
    }
  }

  /// Phase 1, item 3 — the one-page clinician report: a separate
  /// generate action on this page (founder Q8 crew assumption),
  /// reusing the same save/Downloads/share machinery. No AI call;
  /// the existing report's flow is not modified.
  Future<void> _generateClinician() async {
    if (_stage != null) return;
    setState(() {
      _cancelRequested = false;
      _failureMessage = null;
      _failureAllowRaw = false;
      _stage = ReportStage.collecting;
    });
    final pipeline = widget.clinicianPipeline ??
        ClinicianReportPipeline(
          collector: ReportDataCollector(
            backend: _backend,
            hc: widget.healthConnectService ?? HealthConnectService(),
          ),
          clinicianCollector: ClinicianReportCollector(
            // Stored, write-once Daily Scores only (spec §5.3).
            scoreLoader: () async {
              final days = await HealthHistoryStore.instance.readAll();
              return {
                for (final e in days.entries)
                  if (e.value.dailyScore != null) e.key: e.value.dailyScore!,
              };
            },
            eventsLoader: () => _backend.fetchMedicationChangeEvents(),
            categoriesLoader: () => _backend.fetchLogCategories(),
          ),
        );
    final outcome = await pipeline.generate(
      selectedCategories: _selected,
      last30Days: _last30Days,
      profile: _profileInput,
      onStage: (s) {
        if (mounted) setState(() => _stage = s);
      },
      isCancelled: () => _cancelRequested,
      renderPdf: (data) async => buildClinicianPdfBytes(data,
          fonts: await loadClinicianPdfFonts()),
      savePdf: widget.savePdf ?? _defaultSave,
      saveToDownloads: widget.saveToDownloads ?? _defaultSaveToDownloads,
    );
    if (!mounted) return;
    setState(() => _stage = null);
    if (_cancelRequested) return;
    switch (outcome) {
      case ReportReady ready:
        setState(() => _pendingShare = ready);
        _showShareConfirmation();
      case ReportFailed failed:
        if (failed.message == 'Cancelled') return;
        setState(() {
          _failureMessage = failed.message;
          _failureAllowRaw = failed.allowRawFallback;
        });
    }
  }

  Future<void> _showShareConfirmation() async {
    final ready = _pendingShare;
    if (ready == null) return;
    final share = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NotelColors.surface,
        title: const Text('Share health report',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'This PDF contains your health data. Only share it with people you trust.',
                style:
                    TextStyle(color: NotelColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 8),
            Text(ready.fileName,
                style: const TextStyle(
                    color: NotelColors.textPrimary, fontSize: 12)),
            const SizedBox(height: 8),
            Text('For informational purposes only. Not medical advice.',
                style: TextStyle(
                    color: NotelColors.textSecondary.withValues(alpha: 0.7),
                    fontSize: 11)),
            if (ready.aiFailureReason != null) ...[
              const SizedBox(height: 8),
              Text('AI summary unavailable: ${ready.aiFailureReason}',
                  style: const TextStyle(
                      color: NotelColors.textSecondary, fontSize: 11)),
            ],
            // Juno Ruling 2: the Downloads attempt finished before
            // this dialog opened and its outcome travels with the
            // ready outcome — this line is its disclosure.
            if (ready.downloadsSaved != null) ...[
              const SizedBox(height: 8),
              Text(
                  ready.downloadsSaved!
                      ? 'A copy was also saved to your Downloads folder.'
                      : 'This report could not be saved to Downloads. It is saved in the app and you can still share it now.',
                  style: const TextStyle(
                      color: NotelColors.textSecondary, fontSize: 11)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now',
                style: TextStyle(color: NotelColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Share',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _pendingShare = null);
    if (share != true) {
      // Saved-file transparency (Juno Ruling 2 wording): the PDF
      // is already saved in the app even when the user declines to
      // share right now, and in Downloads too when that copy
      // landed.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ready.downloadsSaved == true
              ? 'Report saved in Downloads and in the app. Export again any time to share it.'
              : 'Report saved in the app. It could not be saved to Downloads. Export again any time to share it.')));
      return;
    }
    // Native marks the export when the share sheet is launched.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await widget.store.setReportLastExportMs(nowMs);
    if (mounted) setState(() => _lastExportMs = nowMs);
    final shareFn = widget.sharePdf ??
        (bytes, name) => Printing.sharePdf(
            bytes: Uint8List.fromList(bytes), filename: name);
    try {
      await shareFn(ready.pdfBytes, ready.fileName);
    } catch (_) {
      if (mounted) {
        // Juno Ruling 2: name Downloads only when that copy landed.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ready.downloadsSaved == true
                ? 'Could not open the share sheet. The report is saved in Downloads and in the app.'
                : 'Could not open the share sheet. The report is saved in the app.')));
      }
    }
  }

  // ── Appointment ─────────────────────────────────────────────────

  Future<void> _saveAppointment() async {
    final date = _pickedDateIso;
    if (date == null) return;
    await widget.store.setReportAppointmentDate(date);
    await widget.store.setReportAppointmentType(_appointmentFocus.key);
    if (mounted) {
      setState(() {
        _appointmentDateIso = date;
        _appointmentTypeKey = _appointmentFocus.key;
        _pickedDateIso = null;
      });
    }
    await _syncAppointmentReminder();
  }

  Future<void> _clearAppointment() async {
    await widget.store.setReportAppointmentDate(null);
    if (mounted) setState(() => _appointmentDateIso = null);
    final notifs = widget.notificationService;
    if (notifs != null) {
      try {
        await notifs.cancel(appointmentReminderId);
      } catch (_) {
        // Visible failure rule: the clear itself already landed;
        // a stale one-shot reminder is the worst case.
      }
    }
  }

  /// Day-before 9:00 AM local reminder through the existing
  /// notification machinery (native AppointmentReminderScheduler),
  /// id 770002 — native's id (inside the event-counter hash range;
  /// see the note on [appointmentReminderId]).
  Future<void> _syncAppointmentReminder() async {
    final notifs = widget.notificationService;
    final iso = _appointmentDateIso;
    if (notifs == null || iso == null) return;
    final date = DateTime.tryParse(iso);
    if (date == null) return;
    final fire = DateTime(date.year, date.month, date.day - 1, 9);
    try {
      if (fire.isAfter(DateTime.now())) {
        final typeLabel =
            ReportFocus.fromKey(_appointmentTypeKey).label;
        final dateLabel =
            '${_monthNames[date.month - 1]} ${date.day}';
        await notifs.scheduleOnce(
          id: appointmentReminderId,
          title: 'Appointment tomorrow',
          body:
              'Your visit is on $dateLabel. Export your $typeLabel report so it is ready.',
          channelId: 'appointment_reminder',
          channelName: 'Appointment reminders',
          when: fire,
          highImportance: true,
        );
      } else {
        await notifs.cancel(appointmentReminderId);
      }
    } on NotificationServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not schedule the appointment reminder [${e.code}]')));
      }
    }
  }

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final selectedIds = selected.map((c) => c.id).toSet();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final inRange = _loaded
        ? logsInRange(_entries, selectedIds,
            last30Days: _last30Days, nowMs: nowMs)
        : const <QuickLogEntry>[];
    final hasAnyLogs = _entries.isNotEmpty;
    final generating = _stage != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _overviewCard(selected, inRange),
        const SizedBox(height: 16),
        _previewCard(inRange, selected, hasAnyLogs, generating),
        if (selected.isNotEmpty) ...[
          const SizedBox(height: 16),
          _detailsCard(selected, inRange),
        ],
        const SizedBox(height: 16),
        _appointmentCard(),
      ],
    );
  }

  Widget _card(List<Widget> children, {BoxBorder? border}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: border,
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _sectionLabel(String text) => Text(text,
      style: const TextStyle(
          color: NotelColors.primary,
          fontSize: 12,
          fontWeight: FontWeight.w600));

  Widget _pickerButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: selected
                ? NotelColors.primary.withValues(alpha: 0.18)
                : NotelColors.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              maxLines: 1,
              style: TextStyle(
                  color: selected
                      ? NotelColors.primary
                      : NotelColors.textSecondary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
        ),
      ),
    );
  }

  Widget _overviewCard(
      List<QuickLogCategory> selected, List<QuickLogEntry> inRange) {
    final denom = coverageDenominator(_entries,
        last30Days: _last30Days, nowMs: DateTime.now().millisecondsSinceEpoch);
    return _card([
      _sectionLabel('Report type'),
      const SizedBox(height: 8),
      Row(children: [
        for (var i = 0; i < ReportFocus.values.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          _pickerButton(
            label: ReportFocus.values[i].label,
            selected: _focus == ReportFocus.values[i],
            onTap: () => _pickFocus(ReportFocus.values[i]),
          ),
        ],
      ]),
      const SizedBox(height: 6),
      Text(_focus.description,
          style: TextStyle(
              color: NotelColors.textSecondary.withValues(alpha: 0.75),
              fontSize: 11)),
      if (_focus == ReportFocus.custom) ...[
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Include these categories',
                style: TextStyle(color: NotelColors.textSecondary, fontSize: 12)),
            Row(children: [
              TextButton(
                onPressed: () => setState(() =>
                    _customIds = _categories.map((c) => c.id).toSet()),
                child: const Text('Select all',
                    style: TextStyle(color: NotelColors.primary, fontSize: 12)),
              ),
              TextButton(
                onPressed: () => setState(() => _customIds = {}),
                child: const Text('Clear',
                    style: TextStyle(
                        color: NotelColors.textSecondary, fontSize: 12)),
              ),
            ]),
          ],
        ),
        const SizedBox(height: 4),
        for (final c in _categories)
          InkWell(
            onTap: () => setState(() {
              _customIds = _customIds.contains(c.id)
                  ? (_customIds.toSet()..remove(c.id))
                  : (_customIds.toSet()..add(c.id));
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Checkbox(
                  value: _customIds.contains(c.id),
                  onChanged: null,
                  activeColor: NotelColors.primary,
                ),
                const SizedBox(width: 8),
                Text(c.name,
                    style: const TextStyle(
                        color: NotelColors.textPrimary, fontSize: 14)),
              ]),
            ),
          ),
      ],
      const SizedBox(height: 12),
      _sectionLabel('Time range'),
      const SizedBox(height: 8),
      Row(children: [
        _pickerButton(
            label: 'This Month',
            selected: _last30Days,
            onTap: () => _pickRange(true)),
        const SizedBox(width: 8),
        _pickerButton(
            label: 'All Time',
            selected: !_last30Days,
            onTap: () => _pickRange(false)),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        _stat('${inRange.length}', 'Entries'),
        _stat('${selected.length}', 'Categories'),
        _stat(_last30Days ? '30' : 'All', 'Days covered'),
      ]),
      const SizedBox(height: 8),
      Center(
        child: Text(
            'Logged ${distinctDaysLogged(inRange)} of $denom days',
            style: TextStyle(
                color: NotelColors.textSecondary.withValues(alpha: 0.75),
                fontSize: 11)),
      ),
      const SizedBox(height: 12),
      // Native MedicalDisclaimerBanner (verbatim wording).
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: NotelColors.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition. AI insights are informational only. Consult a healthcare professional.',
          textAlign: TextAlign.center,
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 11),
        ),
      ),
    ]);
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(children: [
          Text(value,
              style: const TextStyle(
                  color: NotelColors.primary,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: NotelColors.textSecondary, fontSize: 11)),
        ]),
      );

  Widget _previewCard(List<QuickLogEntry> inRange,
      List<QuickLogCategory> selected, bool hasAnyLogs, bool generating) {
    return _card([
      _sectionLabel('Preview'),
      const SizedBox(height: 4),
      Text(
        '${_focus.label} report, ${_last30Days ? 'this month' : 'all time'}. '
        '${inRange.length} entries across ${selected.length} categories.',
        style:
            const TextStyle(color: NotelColors.textSecondary, fontSize: 13),
      ),
      if (inRange.isNotEmpty) ...[
        const SizedBox(height: 8),
        const Text('Log activity by hour',
            style: TextStyle(
                color: NotelColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        SizedBox(height: 210, child: _hourlyChart(inRange)),
        if (_selectedHour != null)
          Text(
            '${formatHourLabel(_selectedHour!)}: ${hourlyCounts(inRange)[_selectedHour!] ?? 0} entries',
            style: const TextStyle(
                color: NotelColors.textSecondary, fontSize: 12),
          ),
      ] else ...[
        const SizedBox(height: 12),
        Center(
          child: Column(children: [
            Icon(Icons.bar_chart,
                size: 40,
                color: NotelColors.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            Text(
              selected.isEmpty
                  ? 'No categories selected'
                  : 'Nothing to preview yet',
              style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              selected.isEmpty
                  ? 'Pick at least one category above to see a preview.'
                  : 'Log symptoms, meds, or sleep and your activity will show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: NotelColors.textSecondary.withValues(alpha: 0.7),
                  fontSize: 12),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      if (generating) ...[
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: NotelColors.primary),
          ),
          const SizedBox(width: 10),
          Text(reportStageLabels[_stage] ?? 'Generating report...',
              style: const TextStyle(
                  color: NotelColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _cancelRequested = true),
            child: const Text('Cancel Report Generation',
                style: TextStyle(color: NotelColors.error, fontSize: 11)),
          ),
        ),
      ],
      if (_failureMessage != null) ...[
        Text(_failureMessage!,
            style: const TextStyle(color: NotelColors.error, fontSize: 12)),
        if (_failureAllowRaw)
          TextButton(
            onPressed: () => _generate(forceRaw: true),
            child: const Text('Generate Raw Data Report (Without AI)',
                style: TextStyle(
                    color: NotelColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
        const SizedBox(height: 8),
      ],
      SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton(
          onPressed: (!generating && hasAnyLogs && selected.isNotEmpty)
              ? () => _generate()
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: NotelColors.primary,
            disabledBackgroundColor:
                NotelColors.primary.withValues(alpha: 0.4),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: generating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.picture_as_pdf,
                        size: 18, color: NotelColors.textPrimary),
                    SizedBox(width: 8),
                    Text('Export PDF Report',
                        style: TextStyle(
                            color: NotelColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton(
          onPressed: !generating ? () => _generateClinician() : null,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: NotelColors.primary),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.description_outlined,
                  size: 18, color: NotelColors.primary),
              SizedBox(width: 8),
              Text('Export Clinician Report (1 page)',
                  style: TextStyle(
                      color: NotelColors.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
      if (!hasAnyLogs) ...[
        const SizedBox(height: 6),
        Text('Add some notes first to generate a report.',
            style: TextStyle(
                color: NotelColors.textSecondary.withValues(alpha: 0.5),
                fontSize: 11)),
      ],
      if (_lastExportMs > 0) ...[
        const SizedBox(height: 8),
        Center(
          child: Text('Last exported ${formatExportTimestamp(_lastExportMs)}',
              style: TextStyle(
                  color: NotelColors.textSecondary.withValues(alpha: 0.6),
                  fontSize: 11)),
        ),
      ],
      const SizedBox(height: 8),
      InkWell(
        onTap: () => setState(() => _showSources = !_showSources),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("What's in this report",
                  style: TextStyle(
                      color: NotelColors.textSecondary, fontSize: 12)),
              Icon(_showSources ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: NotelColors.textSecondary),
            ],
          ),
        ),
      ),
      if (_showSources) ...[
        const SizedBox(height: 4),
        _sourceRow('Your logged entries',
            'Symptoms, meds, sleep, and notes you recorded'),
        const SizedBox(height: 10),
        _sourceRow('Health Connect biometrics',
            'Heart rate, sleep, and activity from your device'),
        const SizedBox(height: 10),
        _sourceRow('AI generated summary',
            'Written by AI from your data. Informational only, not medical advice.'),
      ],
    ]);
  }

  Widget _sourceRow(String title, String detail) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle,
              size: 16, color: NotelColors.primary.withValues(alpha: 0.7)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: NotelColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                Text(detail,
                    style: const TextStyle(
                        color: NotelColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ],
      );

  Widget _hourlyChart(List<QuickLogEntry> inRange) {
    final data = hourlyCounts(inRange);
    final maxVal = data.values.fold<int>(1, (a, b) => a > b ? a : b);
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 24,
      itemBuilder: (_, hour) {
        final count = data[hour] ?? 0;
        final isSel = _selectedHour == hour;
        return GestureDetector(
          onTap: () => setState(
              () => _selectedHour = isSel ? null : hour),
          child: Container(
            width: 40,
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (count > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('$count',
                        style: TextStyle(
                            color: isSel
                                ? NotelColors.primary
                                : NotelColors.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                Container(
                  width: 12,
                  height: count == 0 ? 0 : (count / maxVal) * 120,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isSel
                          ? [NotelColors.primary, NotelColors.primary]
                          : [
                              NotelColors.primary.withValues(alpha: 0.6),
                              NotelColors.primary.withValues(alpha: 0.2),
                            ],
                    ),
                    borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(hourBarLabel(hour),
                    maxLines: 1,
                    style: TextStyle(
                        color: isSel
                            ? NotelColors.primary
                            : NotelColors.textSecondary,
                        fontSize: 9,
                        fontWeight:
                            isSel ? FontWeight.bold : FontWeight.w500)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailsCard(
      List<QuickLogCategory> selected, List<QuickLogEntry> inRange) {
    final total = inRange.isEmpty ? 1 : inRange.length;
    return _card([
      _sectionLabel('Details'),
      const SizedBox(height: 12),
      for (var i = 0; i < selected.length; i++) ...[
        if (i > 0) const SizedBox(height: 14),
        _categoryRow(selected[i],
            inRange.where((e) => e.categoryId == selected[i].id).length, total),
      ],
    ]);
  }

  Widget _categoryRow(QuickLogCategory c, int count, int total) {
    final pct = count / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(c.name,
                style: const TextStyle(
                    color: NotelColors.textPrimary, fontSize: 14)),
            Text('$count',
                style: TextStyle(
                    color: c.color, fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 8,
          decoration: BoxDecoration(
            color: NotelColors.surfaceHigh,
            borderRadius: BorderRadius.circular(4),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: pct.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: c.color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _appointmentCard() {
    final saved = _appointmentDateIso;
    return _card(
      [
        const Row(children: [
          Icon(Icons.event_note, size: 22, color: NotelColors.primary),
          SizedBox(width: 8),
          Text('Prepare for an appointment',
              style: TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Save the date and the report type you want ready for your visit. We will remind you the day before to export it.',
          style: TextStyle(color: NotelColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (saved != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: NotelColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Appointment: ${formatIsoDate(saved)}${appointmentCountdown(saved) != null ? ' (${appointmentCountdown(saved)})' : ''}',
                      style: const TextStyle(
                          color: NotelColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                    Text(
                        '${ReportFocus.fromKey(_appointmentTypeKey).label} report saved',
                        style: const TextStyle(
                            color: NotelColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              Column(children: [
                TextButton(
                  onPressed: () =>
                      _pickFocus(ReportFocus.fromKey(_appointmentTypeKey)),
                  child: const Text('Use this type',
                      style:
                          TextStyle(color: NotelColors.primary, fontSize: 12)),
                ),
                TextButton(
                  onPressed: _clearAppointment,
                  child: const Text('Clear',
                      style: TextStyle(
                          color: NotelColors.textSecondary, fontSize: 12)),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: now,
                firstDate: DateTime(now.year - 1),
                lastDate: DateTime(now.year + 5),
              );
              if (picked != null && mounted) {
                setState(() => _pickedDateIso = dateStrOf(picked));
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.surfaceHigh,
              foregroundColor: NotelColors.textPrimary,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.calendar_month,
                size: 18, color: NotelColors.primary),
            label: Text(
                _pickedDateIso != null
                    ? 'Visit on ${formatIsoDate(_pickedDateIso!)}'
                    : 'Pick a date',
                style: const TextStyle(fontSize: 13)),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          for (var i = 0; i < ReportFocus.values.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _pickerButton(
              label: ReportFocus.values[i].label,
              selected: _appointmentFocus == ReportFocus.values[i],
              onTap: () =>
                  setState(() => _appointmentFocus = ReportFocus.values[i]),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _pickedDateIso != null ? _saveAppointment : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
              disabledBackgroundColor:
                  NotelColors.primary.withValues(alpha: 0.4),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Save appointment',
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold)),
          ),
        ),
      ],
      border: Border.all(
          color: NotelColors.primary.withValues(alpha: 0.25), width: 1),
    );
  }
}
