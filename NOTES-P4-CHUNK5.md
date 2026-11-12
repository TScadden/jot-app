## Completion: Correlation Insights Bridge to Snapshot and AI Request
- Files changed: flutter/lib/src/data/progress_report.dart.
- Payload shape: key correlation_insights whose value is newline-joined verified lines or null when empty/failed.
- Load failure handling: catch on insightsLoader records correlationInsightsLoadFailed=true with empty list, sending null in payload.
- TODO_JUNO items: none.
- What was not verified: host tests (Flutter SDK not installed on host; crew runs tests).
