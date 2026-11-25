import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'downloads_saver.dart';
import 'health_connect_service.dart';
import 'knowledge_documents.dart';
import 'progress_report.dart';
import 'progress_report_pdf.dart';
import 'quick_log_models.dart';
import 'report_generation_journal.dart';
import 'report_generation_service.dart';
import 'tabs_backend.dart';
import 'weekly_automation.dart';
import 'weekly_report.dart';

import 'package:tabs_lab/src/features/settings/settings_profile.dart';

/// Weekly Report — page-free production wiring (Background
/// Generation package, 2026-11-24).
///
/// Extracted from the Progress Reports page State so the SAME
/// wiring runs in the foreground (the page consumes it — no
/// behavior change on the first-open path) and in the WorkManager
/// background isolate (WeeklyReportBackgroundRunner.production).
/// This file owns:
///
/// - [resolveWeeklyEntitlement] — the entitlement resolver
///   (server membership `isUnlimited`, fail-closed, lapsed
///   derived from a non-empty archive);
/// - [WeeklyGenerationExecutor] — the generation seam: one weekly
///   run through a dedicated weekly [ReportGenerationService]
///   whose only notifier is a [WeeklySilentNotifier] and whose
///   journal is IN-MEMORY (the durable weekly record is the
///   archive store; the standard service's journal key stays
///   singleton-owned and is never written by weekly runs);
/// - [buildWeeklyPipeline] / [defaultWeeklySavePdf] — the
///   production pipeline + save steps the background entry needs
///   (the page keeps building its own standard pipeline, whose
///   providers are wired to the page's standard service exactly
///   as before, and hands it to the executor as its builder).

/// The weekly entitlement resolution. The entitlement SOURCE is
/// the app's existing one — the server membership's
/// `isUnlimited` (the clinician gate's source; a running trial
/// counts as Premium while the trial runs, per the server's own
/// computation) — no second gate is invented. Fail-closed: an
/// unverified check never reads as Premium. A non-Premium user
/// WITH archive entries is lapsed (their reports stay readable
/// forever); without entries, free.
Future<WeeklyEntitlement> resolveWeeklyEntitlement({
  Future<WeeklyEntitlement> Function()? overrideCheck,
  required Future<bool> Function() isUnlimitedCheck,
  required Future<bool> Function() hasArchiveRecords,
}) async {
  try {
    if (overrideCheck != null) {
      return await overrideCheck();
    }
    if (await isUnlimitedCheck()) return WeeklyEntitlement.premium;
  } catch (_) {
    // Fail-closed: an unknown entitlement is never Premium.
  }
  return await hasArchiveRecords()
      ? WeeklyEntitlement.lapsed
      : WeeklyEntitlement.free;
}

/// One weekly generation run through the dedicated weekly
/// service, shared by the manual action (Package 1), the
/// first-open automation (Package 2, foreground), and the
/// background automation (this package): forceRawFallback (data
/// pipeline only — NO AI narrative, zero Gemini cost) over the
/// fixed Mon–Sun window.
class WeeklyGenerationExecutor {
  WeeklyGenerationExecutor({
    required this.weeklyService,
    required this.pipelineBuilder,
    required this.categoriesLoader,
    required this.profileLoader,
    required this.recordsLoader,
    required this.savePdf,
    required this.saveToDownloads,
    this.otherServiceGenerating,
    this.fallbackCategories,
  });

  /// The dedicated weekly service (silent notifier, in-memory
  /// journal — see the file header).
  final ReportGenerationService weeklyService;

  /// Builds the pipeline for one run. The page passes its
  /// standard pipeline builder (providers wired to the page's
  /// standard service, exactly as before this extraction); the
  /// background entry passes [buildWeeklyPipeline] wired to
  /// [weeklyService].
  final ReportGenerationPipeline Function() pipelineBuilder;

  final Future<List<QuickLogCategory>> Function() categoriesLoader;
  final Future<ReportProfileInput> Function() profileLoader;

  /// The archive records as the caller currently knows them —
  /// the PDF render's previous-week source (the render evaluation
  /// and the coordinator's archive evaluation run on identical
  /// inputs).
  final Future<List<WeeklyArchiveRecord>> Function() recordsLoader;

  final Future<String> Function(List<int> bytes, String fileName) savePdf;
  final Future<bool> Function(List<int> bytes, String fileName) saveToDownloads;

  /// The standard service's generating flag (the page's second
  /// lock); null in the background isolate, where no standard
  /// service runs.
  final bool Function()? otherServiceGenerating;

  /// The category fallback when no Health-focus categories
  /// resolve (the page passes its current selection; the
  /// background entry passes the full loaded list).
  final List<QuickLogCategory> Function(List<QuickLogCategory> all)?
  fallbackCategories;

  /// The coordinator's generation seam: drives the weekly
  /// service for the DUE week (Package 2's window — the current
  /// Mon–Sun week on a Sunday-night trigger, not Package 1's
  /// most recently completed week) and hands back the held ready
  /// outcome. A failed/cancelled run — or a held outcome for a
  /// DIFFERENT week (a stale manual completion) — returns null:
  /// nothing is archived and the week stays due.
  Future<WeeklyGenerationResult?> runAutoGeneration(
    WeeklyWeekWindow week,
    DateTime now,
  ) async {
    if (weeklyService.isGenerating ||
        (otherServiceGenerating?.call() ?? false)) {
      return null;
    }
    await startWeeklyGeneration(
      week,
      now,
      closedBefore: weeklyClosedBefore(week, now),
    );
    final ready = weeklyService.pendingShare;
    if (ready == null) return null;
    final start = ready.snapshot.weekStart;
    final end = ready.snapshot.weekEnd;
    if (start == null || end == null) return null;
    if (WeeklyWeekWindow(start, end).startKey != week.startKey) return null;
    return WeeklyGenerationResult(
      snapshot: ready.snapshot,
      fileName: ready.fileName,
      savedPath: ready.savedPath,
    );
  }

  /// One weekly generation run. [closedBefore] is the
  /// evaluator's Flag 1 bound for the PDF line; null keeps
  /// Package 1's manual default (the whole finished week
  /// counts), while the automation passes [weeklyClosedBefore]
  /// so a still-running Sunday never counts as a complete day
  /// in the PDF either.
  Future<void> startWeeklyGeneration(
    WeeklyWeekWindow window,
    DateTime now, {
    DateTime? closedBefore,
  }) async {
    final categories = await categoriesLoader();
    final weeklyCategories = resolveReportCategories(
      categories,
      ReportFocus.health,
      {},
    );
    final selected = weeklyCategories.isNotEmpty
        ? weeklyCategories
        : (fallbackCategories?.call(categories) ?? categories);
    final profile = await profileLoader();
    final records = await recordsLoader();
    final pipeline = pipelineBuilder();
    await weeklyService.start(
      ({required onStage, required isCancelled}) => pipeline.generate(
        selectedCategories: selected,
        last30Days: false,
        weekStart: window.start,
        weekEnd: window.end,
        profile: profile,
        forceRawFallback: true,
        forceRawBanner: RawReportBanner.explicitChoice,
        onStage: onStage,
        isCancelled: isCancelled,
        now: now,
        renderPdf:
            (
              snapshot,
              aiSummary, {
              required bool isRawFallback,
              RawReportBanner? rawBanner,
            }) {
              // The PDF's ONE weekly line, from the same evaluator
              // the archive record uses (identical inputs at render
              // time and at archive time).
              final previous = WeeklyReportStore.previousOf(records, window);
              final evaluation = evaluateWeeklyCompleteness(
                snapshot: snapshot,
                week: window,
                generationCompleted: true,
                closedBefore: closedBefore,
                previousWeek: previous,
              );
              return buildReportPdfBytes(
                snapshot,
                aiSummary: aiSummary,
                isRawFallback: isRawFallback,
                rawBanner: rawBanner ?? RawReportBanner.explicitChoice,
                weeklyLine: evaluation.pdfLine,
              );
            },
        savePdf: savePdf,
        saveToDownloads: saveToDownloads,
      ),
      request: ReportRequestIdentity(
        kind: 'weekly',
        focusKey: ReportFocus.health.key,
        last30Days: false,
        categoryIds: selected.map((c) => c.id).toList(),
        forceRaw: true,
      ),
    );
  }
}

/// A fresh dedicated weekly service for a background run: the
/// existing silent notifier construction (Package 1's
/// zero-notification guarantee for the service path) and an
/// in-memory journal (never written to durable storage).
ReportGenerationService buildWeeklyGenerationService() =>
    ReportGenerationService(
      notifier: WeeklySilentNotifier(),
      journal: ReportGenerationJournal.inMemory({}),
    );

/// The background entry's pipeline: the standard pipeline wired
/// to the WEEKLY service (its artifact-save hook and wire
/// identity providers), with the page's documents loader shape
/// (the pull's document rows + on-device extracted texts).
ReportGenerationPipeline buildWeeklyPipeline({
  required TabsBackend backend,
  required ReportGenerationService weeklyService,
  HealthConnectService? hc,
  KnowledgeExtractionStore? knowledgeStore,
}) {
  return ReportGenerationPipeline(
    collector: ReportDataCollector(
      backend: backend,
      hc: hc ?? HealthConnectService(),
      documentsLoader: () async {
        final pull = await backend.fetchSyncPull();
        final docs = KnowledgeDocumentMeta.listFromPull(pull);
        if (docs.isEmpty) return const [];
        final store = knowledgeStore ?? KnowledgeExtractionStore.instance;
        await store.load(await backend.readEmail());
        return [
          for (final d in docs)
            if (store.textFor(d.id) case final t? when t.trim().isNotEmpty) t,
        ];
      },
    ),
    backend: backend,
    onArtifactSaved: weeklyService.noteArtifactSaved,
    reportGenerationIdProvider: () => weeklyService.currentReportGenerationId,
    checkPickupFirstProvider: () => weeklyService.currentCheckPickupFirst,
    pickupCheckIdProvider: () => weeklyService.currentPickupCheckId,
    generationInvalidatedProvider: () =>
        weeklyService.currentGenerationInvalidated,
    prefetchedNarrativeProvider: weeklyService.takePrefetchedNarrative,
  );
}

/// The saved-copy location (app documents directory) — the
/// page's default save, shared with the background entry.
Future<String> defaultWeeklySavePdf(List<int> bytes, String fileName) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// The automatic Downloads copy (Juno Ruling 2) — the page's
/// default, shared with the background entry. Never throws.
Future<bool> defaultWeeklySaveToDownloads(List<int> bytes, String fileName) =>
    ReportDownloadsSaver.instance.savePdf(bytes: bytes, fileName: fileName);

/// The background entry's profile loader: the profile input
/// built from a fresh sync pull (the same source the page's
/// [SettingsProfileData] came from when Settings loaded it).
Future<ReportProfileInput> loadWeeklyProfileFromPull(
  TabsBackend backend,
) async {
  final pull = await backend.fetchSyncPull();
  return reportProfileInputFromSettings(SettingsProfileData.fromPull(pull));
}
