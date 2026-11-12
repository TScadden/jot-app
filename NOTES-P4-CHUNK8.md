## Completion: Reject Empty AI Report Responses as Failures
- Files changed: flutter/lib/src/data/progress_report.dart.
- Exact acceptance condition: res.statusCode == 200 && result is String && result.trim().isNotEmpty.
- Failure class & retry parity: AiFailureClass.server (via missingResult: res.statusCode == 200), sharing the 2-attempt budget and fallback path.
- TODO_JUNO items: none.
- What was not verified: host tests (Flutter SDK not installed on host; crew runs tests).
