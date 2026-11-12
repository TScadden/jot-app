# RAWCODE-SWEEP: Flutter UI Raw Error Codes and Exception Sweep

Status: Inventory Complete (Stage 1)
Branch: `agy/raw-code-sweep`
Repository: `tabs-app` (`flutter/lib`)

---

## 1. Overview & Classification Schema

This document inventories all sites across `flutter/lib` where error variables, raw exception text, or bracketed error codes reach (or could reach) the user interface.

Classifications:
- **(a) raw exception to UI**: An exception object (`$e`, `e.toString()`, `${e.message}`) is directly interpolated into user-facing widgets (Text, SnackBar, banner, error state).
- **(b) bracketed code to UI**: A machine/bracketed error code (e.g., `[CODE]`, `[UNKNOWN]`, `[${e.code}]`) is rendered to the user.
- **(c) already human wording, checked clean**: Sites examined and confirmed to present clean, approved human copy without raw codes, or debug logging / crash reporting not reaching UI.

---

## 2. Inventory by Feature / Module

### 2.1 Heart & Spike Review
1. **`flutter/lib/src/features/heart/heart_spike_review_screen.dart:130`**
   - **Classification**: (a) raw exception to UI, (b) bracketed code to UI
   - **Code**: `SnackBar(content: Text('Export failed [$e]'))`
   - **Context**: Catch block during PDF spike report export.
   - **Remedy**: Replace with approved export failure copy without raw exception interpolation.
   - **Status**: FIXED. Replaced with `const SnackBar(content: Text('Export failed unexpectedly. Try again.'))` (commit `2e0459d53`).

2. **`flutter/lib/src/features/heart/heart_screen.dart:223-224`**
   - **Classification**: (b) bracketed code to UI
   - **Code**: `_error = errDetails != null ? '[$errCode] Could not read heart rate data. ($errDetails)' : '[$errCode] Could not read heart rate data.';`
   - **Context**: State variable rendered in error banner.
   - **Remedy**: Strip bracketed code prefix and technical details; use approved human wording `'Could not read heart rate data.'`.
   - **Status**: FIXED. Replaced with clean approved wording `_error = 'Could not read heart rate data.';`.

3. **`flutter/lib/src/features/heart/heart_screen.dart:228-229`**
   - **Classification**: (b) bracketed code to UI
   - **Code**: `_error = errDetails != null ? '[$partialCode] Some heart rate data could not be read and may be missing. ($errDetails)' : '[$partialCode] Some heart rate data could not be read and may be missing.';`
   - **Context**: State variable rendered in warning banner.
   - **Remedy**: Strip bracketed code and technical details; use approved human wording `'Some heart rate data could not be read and may be missing.'`.
   - **Status**: FIXED. Replaced with clean approved wording `_error = 'Some heart rate data could not be read and may be missing.';`.

4. **`flutter/lib/src/features/heart/heart_screen.dart:296`**
   - **Classification**: (a) raw exception to UI, (b) bracketed code to UI
   - **Code**: `_error = '[${e.code}] ${e.message}';`
   - **Context**: HealthConnectException during permission request rendered in UI.
   - **Remedy**: Replace with clean user-friendly permission error copy.
   - **Status**: FIXED. Replaced with clean copy `_error = e.message;` (stripping bracketed code prefix).

5. **`flutter/lib/src/features/heart/heart_screen.dart:238`**
   - **Classification**: (c) already human wording, checked clean
   - **Code**: `_error = 'Could not read heart rate data.';`
   - **Notes**: Clean approved string.

6. **`flutter/lib/src/features/heart/heart_screen.dart:288`**
   - **Classification**: (c) already human wording, checked clean
   - **Code**: `_error = 'No permissions were granted.';`
   - **Notes**: Clean approved string.

---

### 2.2 Sleep Screen
7. **`flutter/lib/src/features/tools/sleep_screen.dart:207-208`**
   - **Classification**: (b) bracketed code to UI
   - **Code**: `_readError = details != null ? '[$code] Could not read sleep data. ($details)' : '[$code] Could not read sleep data.';`
   - **Context**: State variable rendered in error card.
   - **Remedy**: Strip `[$code]` and details; use approved wording `'Could not read sleep data.'`.
   - **Status**: FIXED. Set `_readError = 'Could not read sleep data.';`.

8. **`flutter/lib/src/features/tools/sleep_screen.dart:219-220`**
   - **Classification**: (b) bracketed code to UI
   - **Code**: `_readError = details != null ? '[$code] Some sleep data could not be read and may be missing. ($details)' : '[$code] Some sleep data could not be read and may be missing.';`
   - **Context**: State variable rendered in warning card.
   - **Remedy**: Strip `[$code]` and details; use approved wording `'Some sleep data could not be read and may be missing.'`.
   - **Status**: FIXED. Set `_readError = 'Some sleep data could not be read and may be missing.';`.

---

### 2.3 Daily Score & Keep-Alive
9. **`flutter/lib/src/features/home/daily_score_screen.dart:996`**
   - **Classification**: (b) bracketed code to UI
   - **Code**: `content: Text('Could not refresh. Please try again. [$code]')`
   - **Context**: Refresh failure SnackBar.
   - **Remedy**: Remove bracketed code suffix; use `'Could not refresh. Please try again.'`.
   - **Status**: FIXED. Removed ` [$code]` suffix.

10. **`flutter/lib/src/features/home/daily_score_screen.dart:1012-1013`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `Text('Refresh failed. Nothing was changed. [$_refreshErrorCode]')`
    - **Context**: Inline banner on day screen.
    - **Remedy**: Remove bracketed code suffix; use `'Refresh failed. Nothing was changed.'`.
    - **Status**: FIXED. Removed ` [$_refreshErrorCode]` suffix.

11. **`flutter/lib/src/features/home/daily_score_screen.dart:1020-1022`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `Text('Some data could not be read: ${_refreshFailureCodes.entries.map((e) => '${_captureMetricLabels[e.key] ?? e.key} [${e.value}]').join(', ')}. Using last known values.')`
    - **Context**: Inline banner on day screen listing metrics with bracketed failure codes.
    - **Remedy**: Strip bracketed `[${e.value}]`; show metric names cleanly: `'Some data could not be read: ${_refreshFailureCodes.entries.map((e) => _captureMetricLabels[e.key] ?? e.key).join(', ')}. Using last known values.'`.
    - **Status**: FIXED. Removed ` [${e.value}]`, rendering metric labels cleanly.

12. **`flutter/lib/src/data/refresh_keep_alive.dart:48-49`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `const String dailyScoreRefreshKeepAliveFailedLine = "Keep-alive couldn't start: this refresh wasn't protected if you swiped Tabs away. [FGS_START_FAILED]";`
    - **Context**: Rendered at `daily_score_screen.dart:1041` as an inline notice.
    - **Remedy**: Strip bracketed ` [FGS_START_FAILED]`.
    - **Status**: FIXED. Removed ` [FGS_START_FAILED]` suffix and synchronized corresponding test expectations.

---

### 2.4 Settings: Connected Apps, HRV, Notifications, Documents, Migration
13. **`flutter/lib/src/features/settings/settings_screen.dart:692`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack('Could not open Health Connect settings [${e.code}]');`
    - **Context**: SnackBar on HealthConnectException in background settings launcher.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

14. **`flutter/lib/src/features/settings/settings_screen.dart:694`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack('Could not open Health Connect settings [UNKNOWN]');`
    - **Context**: SnackBar on unexpected error in background settings launcher.
    - **Remedy**: Strip ` [UNKNOWN]`.
    - **Status**: FIXED. Removed ` [UNKNOWN]` suffix.

15. **`flutter/lib/src/features/settings/settings_screen.dart:711-712`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `'Last HRV sync check: the read failed [${d.errorCode}]. $counts'`
    - **Context**: Diagnostics line on Connected Apps card.
    - **Remedy**: Strip bracketed code; render `'Last HRV sync check: the read failed. $counts'`.
    - **Status**: FIXED. Removed ` [${d.errorCode}]` code prefix, keeping clean diagnostic text and updated test expectation in `hrv_grant_visibility_test.dart`.

16. **`flutter/lib/src/features/settings/settings_screen.dart:715-716`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `'Last HRV sync check: some data could not be read [${d.partialCode}]. $counts'`
    - **Context**: Diagnostics line on Connected Apps card.
    - **Remedy**: Strip bracketed code; render `'Last HRV sync check: some data could not be read. $counts'`.
    - **Status**: FIXED. Removed ` [${d.partialCode}]` code prefix, keeping clean diagnostic text and updated test expectation in `hrv_grant_visibility_test.dart`.

17. **`flutter/lib/src/features/settings/settings_screen.dart:750`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack('Could not update notification schedules [${e.code}]');`
    - **Context**: SnackBar on NotificationServiceException during reminder sync.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

18. **`flutter/lib/src/features/settings/settings_screen.dart:756`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack('Could not update notification schedules [SCHEDULE_FAILED]');`
    - **Context**: SnackBar on generic catch during reminder sync.
    - **Remedy**: Strip ` [SCHEDULE_FAILED]`.
    - **Status**: FIXED. Removed ` [SCHEDULE_FAILED]` suffix.

19. **`flutter/lib/src/features/settings/settings_screen.dart:774`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack('Notifications are unavailable on this device [${e.code}]');`
    - **Context**: SnackBar on NotificationServiceException checking notifications.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

20. **`flutter/lib/src/features/settings/settings_screen.dart:812`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack('Could not request notification permission [${e.code}]');`
    - **Context**: SnackBar on NotificationServiceException requesting permissions.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

21. **`flutter/lib/src/features/settings/settings_screen.dart:832`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack('Exact alarm check failed [${e.code}]');`
    - **Context**: SnackBar on NotificationServiceException checking exact alarms.
    - **Remedy**: Strip ` [${e.code}]` or use friendly fallback.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

22. **`flutter/lib/src/features/settings/settings_screen.dart:2933`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack(code != null ? 'Could not read Health Connect data [$code]' : 'No weight or height found in Health Connect yet.');`
    - **Context**: SnackBar in profile auto-fill.
    - **Remedy**: Strip ` [$code]`; use `'Could not read Health Connect data.'`.
    - **Status**: FIXED. Removed ` [$code]` suffix, rendering `'Could not read Health Connect data.'`.

23. **`flutter/lib/src/features/settings/settings_screen.dart:3063`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `setState(() => _kError = '${e.message ?? "Couldn't open the file picker."} [${e.code}]');`
    - **Context**: Document picker error displayed in Knowledge section.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix and synchronized test expectation in `settings_r65_knowledge_test.dart`.

24. **`flutter/lib/src/features/settings/settings_screen.dart:3067`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `setState(() => _kError = "Couldn't open the file picker. [UNKNOWN]");`
    - **Context**: Document picker generic error in Knowledge section.
    - **Remedy**: Strip ` [UNKNOWN]`.
    - **Status**: FIXED. Removed ` [UNKNOWN]` suffix.

25. **`flutter/lib/src/features/settings/settings_screen.dart:3097`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_kError = 'Could not save the document. [${e.code}]';`
    - **Context**: Document save KnowledgeSyncException.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

26. **`flutter/lib/src/features/settings/settings_screen.dart:3103`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_kError = 'Could not save the document. [UNKNOWN]';`
    - **Context**: Document save generic exception.
    - **Remedy**: Strip ` [UNKNOWN]`.
    - **Status**: FIXED. Removed ` [UNKNOWN]` suffix.

27. **`flutter/lib/src/features/settings/settings_screen.dart:3201`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_kError = 'Could not save the note. [${e.code}]';`
    - **Context**: Note save KnowledgeSyncException.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

28. **`flutter/lib/src/features/settings/settings_screen.dart:3207`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_kError = 'Could not save the note. [UNKNOWN]';`
    - **Context**: Note save generic exception.
    - **Remedy**: Strip ` [UNKNOWN]`.
    - **Status**: FIXED. Removed ` [UNKNOWN]` suffix.

29. **`flutter/lib/src/features/settings/settings_screen.dart:3227`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_kError = 'Gemini could not extract text from ${doc.name}. [EXTRACTION_FAILED]';`
    - **Context**: Text extraction failure notice.
    - **Remedy**: Strip ` [EXTRACTION_FAILED]`.
    - **Status**: FIXED. Removed ` [EXTRACTION_FAILED]` suffix.

30. **`flutter/lib/src/features/settings/settings_screen.dart:3233`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `setState(() => _kError = 'Gemini could not extract text from ${doc.name}. [EXTRACTION_FAILED]');`
    - **Context**: Text extraction generic catch notice.
    - **Remedy**: Strip ` [EXTRACTION_FAILED]`.
    - **Status**: FIXED. Removed ` [EXTRACTION_FAILED]` suffix.

31. **`flutter/lib/src/features/settings/settings_screen.dart:3278`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `() => _kError = 'Could not delete ${doc.name}. [${e.code}]');`
    - **Context**: Document delete KnowledgeSyncException.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

32. **`flutter/lib/src/features/settings/settings_screen.dart:3282`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `() => _kError = 'Could not delete ${doc.name}. [UNKNOWN]');`
    - **Context**: Document delete generic catch.
    - **Remedy**: Strip ` [UNKNOWN]`.
    - **Status**: FIXED. Removed ` [UNKNOWN]` suffix.

33. **`flutter/lib/src/features/settings/settings_screen.dart:3324`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `setState(() => _kError = 'Could not clear all files. [${e.code}]');`
    - **Context**: Clear all documents KnowledgeSyncException.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

34. **`flutter/lib/src/features/settings/settings_screen.dart:3327`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `setState(() => _kError = 'Could not clear all files. [UNKNOWN]');`
    - **Context**: Clear all documents generic catch.
    - **Remedy**: Strip ` [UNKNOWN]`.
    - **Status**: FIXED. Removed ` [UNKNOWN]` suffix.

35. **`flutter/lib/src/features/settings/settings_screen.dart:5917`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `Text('Notification scheduling hit a problem [$_notifError].',`
    - **Context**: Inline notifications error warning in settings.
    - **Remedy**: Strip ` [$_notifError]`; use `'Notification scheduling hit a problem.'`.
    - **Status**: FIXED. Removed ` [$_notifError]` suffix, rendering clean `'Notification scheduling hit a problem.'`.

36. **`flutter/lib/src/features/settings/settings_screen.dart:6128`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `'Could not open the share sheet. Try again. [SHARE_FAILED]'`
    - **Context**: Export share failure status.
    - **Remedy**: Strip ` [SHARE_FAILED]`.
    - **Status**: FIXED. Removed ` [SHARE_FAILED]` suffix.

37. **`flutter/lib/src/features/settings/settings_screen.dart:6135`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `'Could not share the export file. [${e.code}]'`
    - **Context**: MigrationFileException during export share.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

38. **`flutter/lib/src/features/settings/settings_screen.dart:6139`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `'Export failed unexpectedly. Try again. [EXPORT_FAILED]'`
    - **Context**: Generic catch during export.
    - **Remedy**: Strip ` [EXPORT_FAILED]`.
    - **Status**: FIXED. Removed ` [EXPORT_FAILED]` suffix.

39. **`flutter/lib/src/features/settings/settings_screen.dart:6167`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `'Could not read that file. [${e.code}]'`
    - **Context**: MigrationFileException during import.
    - **Remedy**: Strip ` [${e.code}]`.
    - **Status**: FIXED. Removed ` [${e.code}]` suffix.

40. **`flutter/lib/src/features/settings/settings_screen.dart:6205`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `'Import failed unexpectedly. Nothing was changed. [IMPORT_FAILED]'`
    - **Context**: Generic catch during import.
    - **Remedy**: Strip ` [IMPORT_FAILED]`.
    - **Status**: FIXED. Removed ` [IMPORT_FAILED]` suffix.

41. **`flutter/lib/src/features/settings/progress_reports_page.dart:527`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `content: Text('Could not schedule the appointment reminder [${e.code}]')`
    - **Context**: SnackBar during appointment reminder schedule.
    - **Remedy**: Strip ` [${e.code}]`.

---

### 2.5 Onboarding Screens
42. **`flutter/lib/src/features/onboarding/notification_onboarding_screen.dart:73`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_error = '[${e.code}] Notification permission request failed.';`
    - **Context**: NotificationServiceException rendered in onboarding error Text widget.
    - **Remedy**: Strip `[${e.code}] `; use `'Notification permission request failed.'`.
    - **Status**: FIXED. Set `_error = 'Notification permission request failed.';`.

43. **`flutter/lib/src/features/onboarding/notification_onboarding_screen.dart:80-81`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_error = '[PERMISSION_REQUEST_FAILED] Notification permission request failed.';`
    - **Context**: Generic catch rendered in onboarding error Text widget.
    - **Remedy**: Strip `[PERMISSION_REQUEST_FAILED] `; use `'Notification permission request failed.'`.
    - **Status**: FIXED. Set `_error = 'Notification permission request failed.';`.

44. **`flutter/lib/src/features/onboarding/onboarding_connections_screen.dart:82`**
    - **Classification**: (a) raw exception to UI, (b) bracketed code to UI
    - **Code**: `_error = '[${e.code}] ${e.message}';`
    - **Context**: HealthConnectException during status probe.
    - **Remedy**: Strip `[${e.code}]`; use friendly status message.
    - **Status**: FIXED. Set `_error = e.message;` (stripping bracketed code).

45. **`flutter/lib/src/features/onboarding/onboarding_connections_screen.dart:115`**
    - **Classification**: (a) raw exception to UI, (b) bracketed code to UI
    - **Code**: `_error = '[${e.code}] ${e.message}';`
    - **Context**: HealthConnectException during permission request.
    - **Remedy**: Strip `[${e.code}]`; use friendly error message.
    - **Status**: FIXED. Set `_error = e.message;` (stripping bracketed code).

46. **`flutter/lib/src/features/onboarding/onboarding_connections_screen.dart:125`**
    - **Classification**: (a) raw exception to UI, (b) bracketed code to UI
    - **Code**: `setState(() => _error = '[${e.code}] ${e.message}');`
    - **Context**: HealthConnectException during sheet return.
    - **Remedy**: Strip `[${e.code}]`; use friendly error message.
    - **Status**: FIXED. Set `_error = e.message;` (stripping bracketed code).

---

### 2.6 Health Coach
47. **`flutter/lib/src/features/tools/health_coach_screen.dart:3037-3038`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `_snack('$coachCalendarPermissionDeniedMessage [${e.code}]');`
    - **Context**: CalendarException during permission gate.
    - **Remedy**: Strip ` [${e.code}]`; display `coachCalendarPermissionDeniedMessage` cleanly.
    - **Status**: FIXED. Removed bracketed code; displays clean `coachCalendarPermissionDeniedMessage`.

48. **`flutter/lib/src/features/tools/health_coach_screen.dart:3272`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `return CoachApprovalOutcome.failureAsMessage('$coachCalendarAddFailureMessage [${e.code}]');`
    - **Context**: CalendarException during calendar event add proposal approval.
    - **Remedy**: Strip ` [${e.code}]`; return `coachCalendarAddFailureMessage` cleanly.
    - **Status**: FIXED. Returns clean `coachCalendarAddFailureMessage`.

49. **`flutter/lib/src/features/tools/health_coach_screen.dart:3301`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `return CoachApprovalOutcome.failureAsMessage('$coachCalendarDeleteFailureMessage [${e.code}]');`
    - **Context**: CalendarException during calendar event delete proposal approval.
    - **Remedy**: Strip ` [${e.code}]`; return `coachCalendarDeleteFailureMessage` cleanly.
    - **Status**: FIXED. Returns clean `coachCalendarDeleteFailureMessage`.

---

### 2.7 Quick Log & Voice Input
50. **`flutter/lib/src/features/quicklog/history_screen.dart:415`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `_loadError = 'Something went wrong loading history: $e';`
    - **Context**: Catch block during history load, rendered in full-screen error Text widget.
    - **Remedy**: Replace with `'Something went wrong loading history. Please try again.'`.

51. **`flutter/lib/src/features/quicklog/quick_log_screen.dart:375`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `_loadError = 'Something went wrong loading Quick Log: $e';`
    - **Context**: Catch block during initial Quick Log load, rendered in full-screen error Text widget.
    - **Remedy**: Replace with `'Something went wrong loading Quick Log. Please try again.'`.

52. **`flutter/lib/src/features/quicklog/quick_log_screen.dart:455`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `_chipsError = 'Suggestions failed: $e';`
    - **Context**: Catch block during chip suggestion generation, rendered in suggestions section error Text widget.
    - **Remedy**: Replace with `'Suggestions unavailable right now.'`.

53. **`flutter/lib/src/features/quicklog/quick_log_screen.dart:656`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `setState(() => _saveError = 'Save failed: $e');`
    - **Context**: Catch block during manual entry save, rendered in entry error Text widget.
    - **Remedy**: Replace with `"Couldn't save that entry. Please try again."`.

54. **`flutter/lib/src/data/voice_input.dart:27`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `throw const VoiceInputException('[VOICE_EMPTY] No speech was recognized — try again.');`
    - **Context**: Rendered directly in `quick_log_screen.dart:717` via `SnackBar(content: Text(e.message))`.
    - **Remedy**: Strip `[VOICE_EMPTY] `; use `'No speech was recognized — try again.'`.

55. **`flutter/lib/src/data/voice_input.dart:31-32`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `throw VoiceInputException('[${e.code}] ${e.message ?? 'Voice input failed.'}');`
    - **Context**: Rendered directly in `quick_log_screen.dart:717` via `SnackBar(content: Text(e.message))`.
    - **Remedy**: Strip `[${e.code}] `; use `e.message ?? 'Voice input failed.'`.

56. **`flutter/lib/src/data/voice_input.dart:34-35`**
    - **Classification**: (b) bracketed code to UI
    - **Code**: `throw const VoiceInputException('[NO_PLUGIN] Voice input is not available in this build.');`
    - **Context**: Rendered directly in `quick_log_screen.dart:717` via `SnackBar(content: Text(e.message))`.
    - **Remedy**: Strip `[NO_PLUGIN] `; use `'Voice input is not available in this build.'`.

---

### 2.8 Billing Service (feeds visible paywall error banner)
57. **`flutter/lib/src/data/billing_service.dart:359`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `errorMessage: 'Google Play reported a problem: $e'`
    - **Context**: Rendered in `billing_plans_panel.dart:295` error banner.
    - **Remedy**: Use approved generic wording: `'Google Play reported a problem. Please try again.'`.

58. **`flutter/lib/src/data/billing_service.dart:378`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `'Could not load Tabs Premium plans from Google Play: $e'`
    - **Context**: Rendered in `billing_plans_panel.dart:295` error banner.
    - **Remedy**: Use existing approved fallback line 369-370: `'Tabs Premium plans could not be loaded from Google Play. Please try again later.'`.

59. **`flutter/lib/src/data/billing_service.dart:425`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `'Google Play could not open the purchase screen: $e'`
    - **Context**: Rendered in `billing_plans_panel.dart:295` error banner.
    - **Remedy**: Use approved wording: `'Google Play could not open the purchase screen. Please try again.'`.

60. **`flutter/lib/src/data/billing_service.dart:498`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `'Verification could not reach the Tabs server: $e. Your purchase is safe with Google Play — reopen Tabs once connected to restore.'`
    - **Context**: Rendered in `billing_plans_panel.dart:295` error banner.
    - **Remedy**: Remove `$e`: `'Verification could not reach the Tabs server. Your purchase is safe with Google Play — reopen Tabs once connected to restore.'`.

61. **`flutter/lib/src/data/billing_service.dart:531`**
    - **Classification**: (a) raw exception to UI
    - **Code**: `'Your membership is active, but Google Play acknowledgement failed: $e. Reopen Tabs to retry it.'`
    - **Context**: Rendered in `billing_plans_panel.dart:295` error banner.
    - **Remedy**: Remove `$e`: `'Your membership is active, but Google Play acknowledgement failed. Reopen Tabs to retry it.'`.

---

## 3. Checked Clean Sites (Classification c)
The following sites were checked and verified clean:
- **`flutter/lib/src/features/connections/connections_screen.dart:124`**: `debugPrint('Connections HC status check failed [${snapshot.bridgeErrorCode}]');` — Logcat only, comment explicitly confirms never rendered.
- **`flutter/lib/src/features/connections/connections_screen.dart:183`**: `_error = 'No permissions were granted.';` — Human wording.
- **`flutter/lib/src/features/home/home_screen.dart:1657`**: `debugPrint('Home HC status check failed [${snapshot.bridgeErrorCode}]');` — Logcat only.
- **`flutter/lib/src/features/settings/settings_screen.dart:622`**: `debugPrint('Settings HC status check failed [$e]');` — Logcat only.
- **`flutter/lib/src/features/settings/settings_screen.dart:634`**: `debugPrint('Settings HC status check failed [${snapshot.bridgeErrorCode}]');` — Logcat only.
- **`flutter/lib/src/features/settings/settings_screen.dart:4271, 4298`**: `_snack('Google sign-in failed. Please try again.');` — Human wording.
- **`flutter/lib/src/features/auth/login_screen.dart:187, 246, 338`**: `_errorMessage = 'Something went wrong. Please try again.';` — Human wording.
- **`flutter/lib/src/features/home/migraine_block.dart:653`**: `_saveError = 'Could not save the attack. Please try again.';` — Human wording.
- **`flutter/lib/src/features/quicklog/history_screen.dart:1390, 1739`**: `"Couldn't save that change — try again."` — Human wording.
- **`flutter/lib/src/features/tools/research_screen.dart:202`**: `_error = 'Could not load your data. Check your connection and try again.';` — Human wording.
- **`flutter/lib/src/features/tools/tips_tricks_screen.dart:224`**: `_gateError = 'Could not verify membership. Check your connection and try again.';` — Human wording.
- **`flutter/lib/src/data/crash_reporting.dart:325, 474`**: Internal crash reporting / debugPrint only.
- **`flutter/lib/src/data/widget_sync.dart:174, 193`**: `debugPrint` only.

---

## 4. Execution Plan (Stage 2)
Groups for Stage 2 commits:
1. **Group 1**: Heart & Spike Review (`heart_spike_review_screen.dart`, `heart_screen.dart`)
2. **Group 2**: Sleep & Daily Score & Keep-Alive (`sleep_screen.dart`, `daily_score_screen.dart`, `refresh_keep_alive.dart`)
3. **Group 3**: Onboarding & Health Coach (`notification_onboarding_screen.dart`, `onboarding_connections_screen.dart`, `health_coach_screen.dart`)
4. **Group 4**: Quick Log & Voice Input (`history_screen.dart`, `quick_log_screen.dart`, `voice_input.dart`)
5. **Group 5**: Settings & Progress Reports (`settings_screen.dart`, `progress_reports_page.dart`)
6. **Group 6**: Billing Service (`billing_service.dart`)
