import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart' show HrSample;
import 'package:tabs_lab/src/data/lean_test_session.dart';
import 'package:tabs_lab/src/data/lean_test_strings.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Phase 1, item 6 — Guided Lean Test screen (spec
/// `phase1-item6-lean-test-spec.md`; strings from the founder-
/// override Juno re-ruling §8 + §9, disclaimer version 2).
///
/// Phases: (0) safety screen → (1) rest 10 min → (2) stand
/// transition → (3) standing minutes 0–10 → (4) result. Every phase
/// and elapsed value derives from the persisted session timestamps;
/// the periodic rebuild below is display-only. The standing phase
/// starts only from the S7 tap, never auto-resumes, and never
/// extends. Single-word button chrome (`Save`, `Confirm`, `Cancel`,
/// `Close`) is the app's existing generic control vocabulary, not
/// feature copy — every sentence is in `lean_test_strings.dart`.
class LeanTestScreen extends StatefulWidget {
  final LeanTestSessionStore? store;
  final LeanTestGateway? gateway;
  final DateTime Function()? clock;

  const LeanTestScreen({super.key, this.store, this.gateway, this.clock});

  @override
  State<LeanTestScreen> createState() => _LeanTestScreenState();
}

/// Production gateway: TabsBackend + the VC 100107 optimistic
/// outbox + Health Connect stored-sample reads.
class BackendLeanTestGateway implements LeanTestGateway {
  final TabsBackend backend;
  final LogEntryOutbox outbox;
  final HealthConnectService healthConnect;

  BackendLeanTestGateway({
    TabsBackend? backend,
    LogEntryOutbox? outbox,
    HealthConnectService? healthConnect,
  })  : backend = backend ?? TabsBackend(),
        outbox = outbox ?? LogEntryOutbox.instance,
        healthConnect = healthConnect ?? HealthConnectService();

  @override
  Future<int?> resolveCategoryId() async {
    try {
      final categories = await backend.fetchLogCategories();
      return resolveLeanCategoryId(categories);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int> allocateEntryId() async {
    var serverMaxId = 0;
    try {
      final entries = await backend.fetchLogEntryDtos();
      final merged = outbox.merge(entries);
      for (final e in merged) {
        if (e.id > serverMaxId) serverMaxId = e.id;
      }
    } catch (_) {
      // Offline: the outbox allocator still guards the id space
      // from its persisted high-water mark.
    }
    return outbox.allocateEntryIdForBackend(
      backend: backend,
      serverMaxId: serverMaxId,
    );
  }

  @override
  Future<bool> stageEntry(QuickLogEntry entry) async {
    final ok = await outbox.stageForBackend(
      entry,
      backend: backend,
      serverKnown: false,
    );
    if (ok) unawaited(outbox.flush(backend));
    return ok;
  }

  @override
  Future<List<QuickLogEntry>> loadEntries() async {
    try {
      final entries = await backend.fetchLogEntryDtos();
      return outbox.merge(entries);
    } catch (_) {
      return outbox.merge(const []);
    }
  }

  @override
  Future<List<HrSample>> readHrSamples(String dateStr) =>
      healthConnect.readHeartRateSamples(dateStr);
}

class _LeanTestScreenState extends State<LeanTestScreen> {
  late final LeanTestSessionStore _store;
  late final LeanTestGateway _gateway;
  late final LeanTestCloser _closer;

  bool _loading = true;
  LeanTestSession? _session;
  bool _interrupted = false;
  bool _confirmed = false;
  LeanTestResult? _result;
  String? _stopLine;
  bool _noEntryClosed = false;
  List<LeanTestResult> _pastResults = const [];
  Timer? _ticker;

  // Capture form state (one form is live at a time).
  final _hrController = TextEditingController();
  final _sysController = TextEditingController();
  final _diaController = TextEditingController();
  final _noteController = TextEditingController();
  final _offerController = TextEditingController();
  LeanAssistOffer? _offer;
  String _assistSource = 'manual';
  int? _assistSampleTMs;

  DateTime _now() => widget.clock?.call() ?? DateTime.now();
  int get _nowMs => _now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? LeanTestSessionStore();
    _gateway = widget.gateway ?? BackendLeanTestGateway();
    _closer = LeanTestCloser(store: _store, gateway: _gateway);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final session = _session;
      if (session != null &&
          session.standingStartedAtMs != null &&
          session.standingExpired(_nowMs) &&
          session.hasAnyRecordedValue) {
        setState(() => _interrupted = true);
      } else {
        setState(() {});
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _hrController.dispose();
    _sysController.dispose();
    _diaController.dispose();
    _noteController.dispose();
    _offerController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Pending-retry first (migraine pattern): a result built by a
    // killed session stages with its persisted id before anything
    // else renders.
    await retryPendingLeanTestEntry(
      store: _store,
      stage: (entry) => _gateway.stageEntry(entry),
    );
    var session = await _store.load();
    var interrupted = false;
    if (session != null) {
      switch (session.relaunchAt(_nowMs)) {
        case LeanRelaunch.discardSilently:
          await _store.clear();
          session = null;
        case LeanRelaunch.interrupted:
          interrupted = true;
        case LeanRelaunch.resume:
        case LeanRelaunch.transition:
          break;
      }
    }
    var past = const <LeanTestResult>[];
    try {
      past = leanPastResults(await _gateway.loadEntries());
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _session = session;
      _interrupted = interrupted;
      _pastResults = past;
      _loading = false;
    });
  }

  // ── Session actions ────────────────────────────────────────────

  Future<void> _start() async {
    if (!_confirmed) return;
    final now = _nowMs;
    final session = LeanTestSession(startedAtMs: now, restStartedAtMs: now);
    await _store.save(session);
    if (!mounted) return;
    setState(() {
      _session = session;
      _result = null;
      _stopLine = null;
      _noEntryClosed = false;
    });
  }

  Future<void> _saveSession(LeanTestSession session) async {
    await _store.save(session);
    if (!mounted) return;
    setState(() => _session = session);
  }

  void _clearForm() {
    _hrController.clear();
    _sysController.clear();
    _diaController.clear();
    _noteController.clear();
    _offer = null;
    _assistSource = 'manual';
    _assistSampleTMs = null;
  }

  LeanCapture _captureFromForm({required int minute, bool standing = false}) {
    final hr = leanEnteredValue(_hrController.text);
    return LeanCapture(
      minute: minute,
      tMs: _nowMs,
      hr: hr,
      sys: leanEnteredValue(_sysController.text),
      dia: leanEnteredValue(_diaController.text),
      source: hr != null ? _assistSource : 'manual',
      sampleTMs: hr != null ? _assistSampleTMs : null,
      symptomNote: standing && _noteController.text.trim().isNotEmpty
          ? _noteController.text.trim()
          : null,
    );
  }

  Future<void> _submitRestCapture(int minute) async {
    final session = _session;
    if (session == null) return;
    final capture = _captureFromForm(minute: minute);
    _clearForm();
    await _saveSession(session.copyWith(
      baselineCaptures: [...session.baselineCaptures, capture],
    ));
  }

  Future<void> _submitStandingCapture(int minute) async {
    final session = _session;
    if (session == null) return;
    final capture = _captureFromForm(minute: minute, standing: true);
    _clearForm();
    final updated =
        session.copyWith(checkpoints: [...session.checkpoints, capture]);
    await _saveSession(updated);
    if (minute >= leanStandingMinutes) {
      final close = await _closer.closeCompleted(updated);
      if (!mounted) return;
      setState(() {
        _session = null;
        _result = close.result;
        _stopLine = null;
      });
    }
  }

  Future<void> _standNow() async {
    final session = _session;
    if (session == null || session.standingStartedAtMs != null) return;
    // The standing clock starts from THIS tap's timestamp only.
    await _saveSession(session.copyWith(standingStartedAtMs: _nowMs));
  }

  Future<void> _stopRest() async {
    final session = _session;
    if (session == null) return;
    final close = await _closer.closeRestStop(session, _nowMs);
    if (!mounted) return;
    setState(() {
      _session = null;
      _stopLine = leanN5;
      if (close.result != null) {
        _result = close.result;
        _noEntryClosed = false;
      } else {
        // §9 Q2: no recorded values — no entry, no completion line.
        _result = null;
        _noEntryClosed = true;
      }
    });
  }

  Future<void> _stopStanding() async {
    final session = _session;
    if (session == null) return;
    final close = await _closer.closeStandingStop(session, _nowMs);
    if (!mounted) return;
    setState(() {
      _session = null;
      _result = close.result;
      _stopLine = leanS11Response;
    });
  }

  Future<void> _closeInterrupted() async {
    final session = _session;
    if (session == null) return;
    final close = await _closer.closeInterrupted(session);
    if (!mounted) return;
    setState(() {
      _session = null;
      _interrupted = false;
      _result = close.result;
      _stopLine = null;
    });
  }

  Future<void> _discardAndRestart() async {
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _session = null;
      _interrupted = false;
      _confirmed = false;
      _result = null;
      _stopLine = null;
      _noEntryClosed = false;
    });
  }

  // ── Health Connect assist ──────────────────────────────────────

  Future<void> _requestAssist({required int checkpointTMs}) async {
    final now = _now();
    final dateStr =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    List<HrSample> samples = const [];
    try {
      samples = await _gateway.readHrSamples(dateStr);
    } catch (_) {}
    final offer = leanAssistOffer(
      samples,
      nowMs: _nowMs,
      checkpointTMs: checkpointTMs,
    );
    if (!mounted || offer == null) return;
    // The offer writes NOTHING until the user confirms it.
    setState(() {
      _offer = offer;
      _offerController.text = '${offer.sample.bpm}';
    });
  }

  void _confirmOffer() {
    final offer = _offer;
    if (offer == null) return;
    final edited = leanEnteredValue(_offerController.text);
    setState(() {
      _offer = null;
      if (edited != null) {
        _hrController.text = '$edited';
        _assistSource = 'health_connect';
        _assistSampleTMs = offer.sample.timeMs;
      }
    });
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        title: const Text(
          leanS1Label,
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_noEntryClosed) return _noEntryView();
    if (_result != null) return _resultView(_result!);
    if (_interrupted && _session != null) return _interruptedView();
    final session = _session;
    if (session == null) return _safetyView();
    if (session.standingStartedAtMs != null) return _standingView(session);
    if (session.phaseAt(_nowMs) == LeanPhase.transition) {
      return _transitionView(session);
    }
    return _restView(session);
  }

  Widget _safetyView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const Text(leanE1, style: _bodyStyle),
        const SizedBox(height: 12),
        const Text(leanE2, style: _bodyStyle),
        const SizedBox(height: 12),
        // D1: its own block, no less prominent than S2.
        Container(
          key: const ValueKey('lean_d1_block'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: NotelColors.primary, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            leanD1,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: NotelColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(leanS2, style: _bodyStyle),
        const SizedBox(height: 12),
        const Text(leanS3, style: _bodyStyle),
        const SizedBox(height: 12),
        const Text(leanS4a, style: _bodyStyle),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _confirmed,
          onChanged: (v) => setState(() => _confirmed = v ?? false),
          title: const Text(leanS4Confirmation, style: _bodyStyle),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const Text(leanS4b, style: _bodyStyle),
        const SizedBox(height: 8),
        const Text(leanS4c, style: _bodyStyle),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _confirmed ? () => unawaited(_start()) : null,
          child: const Text(leanS5),
        ),
        if (_pastResults.isNotEmpty) ...[
          const SizedBox(height: 28),
          const Text(
            leanN4,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          for (final past in _pastResults) _pastResultCard(past),
        ],
      ],
    );
  }

  Widget _pastResultCard(LeanTestResult past) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(past.completionLine, style: _bodyStyle),
          for (final line in past.valueLines())
            Text(line, style: _secondaryStyle),
        ],
      ),
    );
  }

  Widget _restView(LeanTestSession session) {
    final nowMs = _nowMs;
    final due = session.dueBaselineMinute(nowMs);
    final remainingSeconds =
        (leanRestMinutes * 60 - (nowMs - session.restStartedAtMs) ~/ 1000)
            .clamp(0, leanRestMinutes * 60);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              const Text(leanS6, style: _bodyStyle),
              const SizedBox(height: 12),
              Text(
                _timerText(remainingSeconds),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary,
                ),
              ),
              if (due != null) ...[
                const SizedBox(height: 20),
                _captureForm(
                  prompt: leanN1,
                  standing: false,
                  checkpointTMs: session.restStartedAtMs + due * 60000,
                  onSave: () => unawaited(_submitRestCapture(due)),
                ),
              ],
            ],
          ),
        ),
        _stopBar(onStop: () => unawaited(_stopRest())),
      ],
    );
  }

  Widget _transitionView(LeanTestSession session) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              const Text(leanS8, style: _bodyStyle),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => unawaited(_standNow()),
                child: const Text(leanS7),
              ),
            ],
          ),
        ),
        // The transition stop follows the rest-stop rules (§9),
        // with elapsed rest minute 10.
        _stopBar(onStop: () => unawaited(_stopRest())),
      ],
    );
  }

  Widget _standingView(LeanTestSession session) {
    final nowMs = _nowMs;
    final current = session.currentStandingMinute(nowMs);
    final submitted =
        session.checkpoints.any((c) => c.minute == current);
    final elapsedSeconds =
        (nowMs - (session.standingStartedAtMs ?? nowMs)) ~/ 1000;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              Text(
                _timerText(elapsedSeconds),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              if (!submitted)
                _captureForm(
                  prompt: leanS9(current),
                  standing: true,
                  checkpointTMs:
                      (session.standingStartedAtMs ?? nowMs) + current * 60000,
                  onSave: () => unawaited(_submitStandingCapture(current)),
                )
              else
                const Text(leanS8, style: _bodyStyle),
            ],
          ),
        ),
        // S11: present on every standing screen, without scrolling.
        _stopBar(onStop: () => unawaited(_stopStanding())),
      ],
    );
  }

  Widget _interruptedView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const Text(leanN3Line, style: _bodyStyle),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: () => unawaited(_closeInterrupted()),
          child: const Text(leanN3Close),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => unawaited(_discardAndRestart()),
          child: const Text(leanN3Discard),
        ),
      ],
    );
  }

  Widget _noEntryView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(_stopLine ?? leanN5, style: _bodyStyle),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _resultView(LeanTestResult result) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const Text(
          leanS12Heading,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Text(result.completionLine, style: _bodyStyle),
        const SizedBox(height: 4),
        const Text(leanHistoryHint, style: _secondaryStyle),
        if (_stopLine != null) ...[
          const SizedBox(height: 12),
          Text(_stopLine!, style: _bodyStyle),
        ],
        const SizedBox(height: 12),
        for (final line in result.valueLines())
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: _bodyStyle),
          ),
        const SizedBox(height: 16),
        // S2 again, in full, on the result screen.
        const Text(leanS2, style: _bodyStyle),
      ],
    );
  }

  // ── Shared pieces ──────────────────────────────────────────────

  Widget _stopBar({required VoidCallback onStop}) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: onStop,
            child: const Text(leanS11Action),
          ),
        ),
      ),
    );
  }

  Widget _captureForm({
    required String prompt,
    required bool standing,
    required int checkpointTMs,
    required VoidCallback onSave,
  }) {
    final offer = _offer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(prompt, style: _bodyStyle),
        const SizedBox(height: 12),
        TextField(
          controller: _hrController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: 'bpm'),
        ),
        const SizedBox(height: 12),
        const Text(leanBpLabel, style: _bodyStyle),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _sysController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'Systolic'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _diaController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'Diastolic'),
              ),
            ),
          ],
        ),
        if (standing) ...[
          const SizedBox(height: 12),
          const Text(leanS10, style: _bodyStyle),
          TextField(controller: _noteController),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: () =>
              unawaited(_requestAssist(checkpointTMs: checkpointTMs)),
          child: const Text(leanN2),
        ),
        if (offer != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: NotelColors.cardBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(offer.displayLine, style: _bodyStyle),
                const SizedBox(height: 8),
                TextField(
                  controller: _offerController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(suffixText: 'bpm'),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _offer = null),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: _confirmOffer,
                      child: const Text('Confirm'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        ElevatedButton(onPressed: onSave, child: const Text('Save')),
      ],
    );
  }

  String _timerText(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

const TextStyle _bodyStyle = TextStyle(
  fontSize: 15,
  height: 1.4,
  color: NotelColors.textPrimary,
);

const TextStyle _secondaryStyle = TextStyle(
  fontSize: 13,
  height: 1.4,
  color: NotelColors.textSecondary,
);
