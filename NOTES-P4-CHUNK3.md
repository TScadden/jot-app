# NOTES-P4-CHUNK3.md — Phase 4 Chunk 3: Clinician Missing Biometric Zones (Sleep only)

- **Branch**: `agy/phase4-build`
- **Base ref**: `origin/release/vc100116` at commit `9d796d7ee8b7b658700c87c6fd78534fa7ce0af5` (`9d796d7e`)
- **Preceding tips**: Commit `44b37376b` (Chunk 1) and `48d837714` (Chunk 2)
- **Status**: IN PROGRESS (Skeleton initialized)

## 1. Goal & Context
Tabs report reliability program, VC 100127 mega-package. Source spec: `PHASE4-AUDIT.md`, Q4 package 3 (first half: Clinician Missing Biometric Zones, Sleep only).
In the clinician PDF, Sleep Duration and Deep Sleep are already collected into `ReportSnapshot` (`sleepSeries` and `deepSleepSeries`) by `ReportDataCollector.collect`, but currently dropped inside the clinician renderer. On a healthy account, the clinician page prints nothing about sleep — neither data nor a statement.
This chunk adds the Sleep zone only (HRV and HR zones are Chunk 4):
1. Add a compact Sleep zone to `clinicianPageLines` rendering Sleep Duration and Deep Sleep from snapshot series already collected.
2. Render real statistical summary (recorded nights or days in range, average, range) when status is `success` or `storedOnly` and data exists.
3. When status is `noData`, `permissionDenied`, `stale`, or `error`, or the series is empty, render an explicit honest not-available statement inside the zone. Never omit the zone and never print zero as if it were measured.
4. Respect strict one-page geometry budget (`_maxContentHeight = 770pt`). Keep Sleep zone compact and verify page budget.
5. Reuse approved labels/status strings; define single-quoted constants for missing copy with `TODO_JUNO_` markers.
6. Add targeted fixtures in `clinician_report_test.dart`.

## 2. Files in Scope
- `flutter/lib/src/data/clinician_report.dart`
- `flutter/lib/src/data/clinician_report_pdf.dart`
- `flutter/test/clinician_report_test.dart`
- `NOTES-P4-CHUNK3.md`

## 3. TODO_JUNO List
- `TODO_JUNO_SLEEP_ZONE_UNAVAILABLE`: Pending
- `TODO_JUNO_DEEP_SLEEP_ZONE_UNAVAILABLE`: Pending

## 4. Geometry Measurement
- Page content height budget: `_maxContentHeight = 770pt`
- Baseline height: Pending measurement
- Cumulative height with Sleep zone: Pending measurement

## 5. Targeted Tests
- Command: `flutter test test/clinician_report_test.dart` (run from `flutter/`)
- Test status: Pending

## 6. Not Verified
- Heart rate and HRV zones (deferred to Phase 4 Chunk 4).
- Standard report / AI narrative (Chunks 5+).
- Host flutter runtime execution if Dart/Flutter SDK is not on host PATH.
- Backend server routes or database migrations (`jot-server` untouched).

## Completion: Sleep Zone Data Prep
- Files changed: flutter/lib/src/data/clinician_report.dart.
- Pair discipline: unavailable form for failure statuses (permissionDenied, stale, error); no-data form for clean empty reads; never merged.
- TODO_JUNO items: summary line template flagged for Juno confirmation before merge.
- Not verified: host tests (no Flutter SDK on host; crew runs tests); PDF rendering/layout deferred to rendering chunk.


## Completion: Clinician Sleep Zone Rendering
- Files changed: flutter/lib/src/data/clinician_report_pdf.dart.
- Decision rule: line builder if summary != null and status is success/storedOnly; no-data constant if status is noData or summary is null with success/storedOnly; unavailable constant for all other statuses or missing metadata.
- Geometry: 752pt usable height (595x842, marginAll 45), zone cost ~58pt absorbed by Spacer slack; page-count verification deferred to the crew because this host has no Flutter SDK.
- TODO_JUNO items: none.
- Not verified: PDF page count and test execution (deferred to the crew because this host has no Flutter SDK).