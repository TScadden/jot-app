# NOTES-P4-CHUNK1.md — Phase 4 Chunk 1: Daily Score Availability and Collector Truth

- **Branch**: `agy/phase4-build`
- **Base ref**: `origin/release/vc100116` (verified commit `9d796d7ee8b7b658700c87c6fd78534fa7ce0af5`, matching `9d796d7e`)
- **Status**: IN PROGRESS (Skeleton initialized)

## 1. Goal & Context
The founder mandate is that a report must never ship silently partial.
In the clinician PDF, Daily Score load failures were previously swallowed (`catch (_) { scores = const {}; }`), causing a failed score read to render identically to a genuine zero-coverage range ("Not enough data to display chart" + "Daily Score recorded on 0 of N days"). Furthermore, Daily Score had no entry in `ReportSnapshot.sectionMetadata`, so the Z8 availability footer could never disclose the failure.
This chunk fixes truth plumbing only:
1. Adds `dailyScore` to `ReportSnapshot.sectionMetadata` in `ReportDataCollector.collect` (canonical key order, using existing `DataSourceStatus` machinery).
2. Eliminates the silent swallow in `ClinicianReportCollector.extend`, recording failure under `dailyScore` in `sectionMetadata` while keeping page generation resilient with an empty map.
3. Exposes `dailyScore` through existing availability loops in both the standard report (Section 4) and clinician report (Z8 footer), adding label mapping only.
4. Adds/updates targeted tests to distinguish score-loader failures from genuine zero coverage.

## 2. Files in Scope
- `flutter/lib/src/data/progress_report.dart`
- `flutter/lib/src/data/clinician_report.dart`
- `flutter/test/clinician_report_test.dart`
- `flutter/test/progress_report_availability_truth_test.dart`
- `NOTES-P4-CHUNK1.md`

## 3. TODO_JUNO List
(Pending inspection of existing labels; will record any constant introduced or 'none')

## 4. Targeted Tests
Command: `flutter test test/clinician_report_test.dart test/progress_report_availability_truth_test.dart` (run from `flutter/`)
- Status: Pending

## 5. Not Verified
- Full test suite outside the two targeted test files.
- Live PDF rendering on physical devices or real display drivers.
- Backend server routes or database migrations (untouched in this chunk).
