import Flutter
import UIKit

#if canImport(HealthKit)
import HealthKit
#endif

/// HealthKit bridge plugin (iOS counterpart to the Android
/// `health_connect_bridge` plugin).
///
/// Seam: this plugin registers a FlutterMethodChannel with EXACTLY
/// the same name the Android bridge serves —
/// `com.notel.notel.playground.flutter/health_connect`
/// (`HealthConnectService.channelName` in Dart) — so the single Dart
/// `HealthConnectService` drives both platforms and its existing
/// payload parsers are reused verbatim. This plugin declares only
/// iOS in its pubspec, so it never registers on Android, and the
/// Android plugin never registers on iOS.
///
/// Payload contract (binding): every read returns the SAME map
/// shapes / keys / types the Kotlin `HealthConnectBridgePlugin`
/// returns, so the Dart parsers in `health_connect_service.dart`
/// work unchanged. Mapping rules (design doc
/// `app-store-healthkit-wiring-design-2026-11-11.md` §4 + founder
/// rules):
/// - HR bpm ≤ 0 dropped (a biometric 0 is always a failed read);
///   samples distinct by time, sorted ascending.
/// - Steps: null when no points, never 0.
/// - Calories: active energy primary; total (active + basal) is the
///   fallback only when active is absent for the day; kcal ≤ 0
///   dropped.
/// - Resting HR: one value per local day; a day with no resting
///   record stays absent — NO heart-rate-average fallback is
///   synthesized on iOS (design §4).
/// - Local-day boundaries are the device's local timezone, matching
///   the Kotlin bridge's day semantics.
/// - HRV: iOS has no RMSSD. SDNN points travel ONLY through the
///   separate `readHrvSdnnSamples` series (design §5) — never
///   through the RMSSD-shaped `readHrvSamples` / `readHrvRmssd`
///   methods, which stay unimplemented on iOS.
///
/// Honest-surface rules: HealthKit does not disclose read-permission
/// denial, so `getGrantedPermissions` is NOT fabricated — it stays
/// unimplemented (the Dart side records the grant layer as unknown;
/// truth on iOS is carried by the honest availability model in
/// Dart, `probeIosAvailability`: requested + real-read evidence,
/// never an authorization status).
/// `requestPermissions` (chunk 6) runs the read-only authorization
/// request in context over `healthReadTypes` — read types only, no
/// write types, ever. `cancelRequest` stays unimplemented: HealthKit
/// has no API to cancel an in-flight authorization request, so
/// there is no honest analogue (the Dart timeout path tolerates
/// the resulting MissingPluginException).
public class HealthkitBridgePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.notel.notel.playground.flutter/health_connect",
      binaryMessenger: registrar.messenger())
    let instance = HealthkitBridgePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  #if canImport(HealthKit)
  private let store = HKHealthStore()

  /// The read-only HealthKit type set this bridge reads (and the
  /// set a later chunk's authorization request will ask for).
  /// Read-only by design: no share/write types are ever included,
  /// and the app ships no NSHealthUpdateUsageDescription.
  static var healthReadTypes: Set<HKObjectType> {
    var types: Set<HKObjectType> = [
      HKObjectType.quantityType(forIdentifier: .heartRate)!,
      HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
      HKObjectType.quantityType(forIdentifier: .stepCount)!,
      HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
      HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!,
      HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
      HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
      HKObjectType.quantityType(forIdentifier: .bodyMass)!,
      HKObjectType.quantityType(forIdentifier: .height)!,
      HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
      HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
      HKObjectType.workoutType(),
    ]
    if let bp = HKObjectType.correlationType(forIdentifier: .bloodPressure) {
      types.insert(bp)
    }
    return types
  }
  #endif

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      #if canImport(HealthKit)
        result(HKHealthStore.isHealthDataAvailable())
      #else
        result(false)
      #endif
    #if canImport(HealthKit)
    case "probeReadAccess":
      probeReadAccess(result: result)
    case "requestPermissions":
      requestPermissions(result: result)
    case "readHeartRateSamples":
      readHeartRateSamples(dateStr: argDateStr(call), result: result)
    case "readRestingHeartRate":
      readRestingHeartRate(dateStr: argDateStr(call), result: result)
    case "readRestingHrHistory":
      readRestingHrHistory(days: argDays(call, defaultDays: 7, maxDays: 180), result: result)
    case "readSteps":
      readSteps(dateStr: argDateStr(call), result: result)
    case "readStepsHistory":
      readStepsHistory(days: argDays(call, defaultDays: 30, maxDays: 400), result: result)
    case "readActiveCalories":
      readActiveCalories(dateStr: argDateStr(call), result: result)
    case "readCaloriesHistory":
      readCaloriesHistory(days: argDays(call, defaultDays: 7, maxDays: 180), result: result)
    case "readTotalCaloriesHistory":
      readTotalCaloriesHistory(days: argDays(call, defaultDays: 30, maxDays: 400), result: result)
    case "readBloodPressure":
      readBloodPressure(days: argDays(call, defaultDays: 7, maxDays: 180), result: result)
    case "readRespiratoryRate":
      readRespiratoryRate(dateStr: argDateStr(call), result: result)
    case "readOxygenSaturation":
      readOxygenSaturation(dateStr: argDateStr(call), result: result)
    case "readLatestWeightKg":
      readLatestWeightKg(result: result)
    case "readLatestHeightCm":
      readLatestHeightCm(result: result)
    case "readHrvSdnnSamples":
      readHrvSdnnSamples(days: argDays(call, defaultDays: 30, maxDays: 3650), result: result)
    case "readSpikeCounts":
      readSpikeCounts(days: argDays(call, defaultDays: 30, maxDays: 365), result: result)
    case "readExerciseSessions":
      readExerciseSessions(days: argDays(call, defaultDays: 30, maxDays: 400), result: result)
    case "readSleepMinutes":
      readSleepMinutes(dateStr: argDateStr(call), result: result)
    case "readSleepStages":
      readSleepStages(dateStr: argDateStr(call), result: result)
    case "readSleepHistory":
      readSleepHistory(days: argDays(call, defaultDays: 30, maxDays: 3650), result: result)
    #endif
    default:
      // Everything else stays honestly unimplemented on iOS:
      // - getGrantedPermissions: HealthKit never discloses read
      //   grants/denials; a fabricated list would lie to the Dart
      //   availability layer. (The honest model is chunk 5's
      //   `probeIosAvailability` in Dart.)
      // - cancelRequest: HealthKit has no API to cancel an
      //   in-flight authorization request — no honest analogue
      //   exists, so this stays unimplemented by design.
      // - readHrvSamples / readHrvRmssd: RMSSD-shaped methods; iOS
      //   HRV is SDNN only and travels via readHrvSdnnSamples.
      // - openHealthConnectSettings, exportCsvFile,
      //   savePdfToDownloads, startRefreshKeepAlive,
      //   stopRefreshKeepAlive, takePendingScoreTap: Android-only
      //   surfaces with no true HealthKit analogue.
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Argument + date helpers

  private func argDateStr(_ call: FlutterMethodCall) -> String? {
    (call.arguments as? [String: Any])?["dateStr"] as? String
  }

  private func argDays(_ call: FlutterMethodCall, defaultDays: Int, maxDays: Int) -> Int {
    let raw = ((call.arguments as? [String: Any])?["days"] as? NSNumber)?.intValue ?? defaultDays
    return min(max(raw, 1), maxDays)
  }

  #if canImport(HealthKit)

  private var calendar: Calendar { Calendar.current }

  private var dayFormatter: DateFormatter {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
  }

  /// Kotlin `localDateOf`: "today"/blank/unparseable → today, else
  /// the parsed local date.
  private func localDate(of dateStr: String?) -> Date {
    let today = calendar.startOfDay(for: Date())
    guard let s = dateStr, !s.isEmpty, s != "today" else { return today }
    if let parsed = dayFormatter.date(from: s) {
      return calendar.startOfDay(for: parsed)
    }
    return today
  }

  /// Kotlin `dayRange`: [local start of day, next local start).
  private func dayRange(of dateStr: String?) -> (start: Date, end: Date) {
    let start = localDate(of: dateStr)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
    return (start, end)
  }

  /// Kotlin history window: [tomorrowStart − days, tomorrowStart).
  private func historyWindow(days: Int) -> (start: Date, end: Date) {
    let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
      ?? Date()
    let start = calendar.date(byAdding: .day, value: -days, to: end) ?? end
    return (start, end)
  }

  private func dateString(of date: Date) -> String { dayFormatter.string(from: date) }

  private func epochMs(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

  /// Kotlin error contract: a stable code, a fixed message, and the
  /// exception CLASS only in details (never health values).
  private func fail(_ result: @escaping FlutterResult, code: String, message: String, error: Error?) {
    result(FlutterError(
      code: code,
      message: message,
      details: error.map { String(describing: type(of: $0)) }))
  }

  // MARK: - Query plumbing

  private func querySamples(
    type: HKSampleType,
    start: Date,
    end: Date,
    strictStart: Bool = true,
    ascending: Bool = true,
    limit: Int = HKObjectQueryNoLimit,
    completion: @escaping ([HKSample]?, Error?) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(
      withStart: start, end: end,
      options: strictStart ? [.strictStartDate] : [])
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)
    let query = HKSampleQuery(
      sampleType: type, predicate: predicate, limit: limit,
      sortDescriptors: [sort]
    ) { _, samples, error in
      completion(samples, error)
    }
    store.execute(query)
  }

  private func queryStatisticsSum(
    type: HKQuantityType,
    unit: HKUnit,
    start: Date,
    end: Date,
    completion: @escaping (Double?, Error?) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
    let query = HKStatisticsQuery(
      quantityType: type, quantitySamplePredicate: predicate,
      options: [.cumulativeSum]
    ) { _, statistics, error in
      if let error = error {
        completion(nil, error)
      } else {
        completion(statistics?.sumQuantity()?.doubleValue(for: unit), nil)
      }
    }
    store.execute(query)
  }

  /// Per-local-day cumulative sums over [start, end) via a day
  /// statistics collection anchored at the window start (a local
  /// midnight). Every bucket in the window is reported, with a nil
  /// value for days with no samples — callers shape the payload.
  private func queryDailySums(
    type: HKQuantityType,
    unit: HKUnit,
    start: Date,
    end: Date,
    completion: @escaping ([(dayStart: Date, value: Double?)]?, Error?) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
    var interval = DateComponents()
    interval.day = 1
    let query = HKStatisticsCollectionQuery(
      quantityType: type, quantitySamplePredicate: predicate,
      options: [.cumulativeSum], anchorDate: start, intervalComponents: interval)
    query.initialResultsHandler = { _, collection, error in
      if let error = error {
        completion(nil, error)
        return
      }
      guard let collection = collection else {
        completion([], nil)
        return
      }
      var out: [(dayStart: Date, value: Double?)] = []
      collection.enumerateStatistics(from: start, to: end) { statistics, _ in
        out.append((dayStart: statistics.startDate,
                    value: statistics.sumQuantity()?.doubleValue(for: unit)))
      }
      completion(out, nil)
    }
    store.execute(query)
  }

  private func quantitySamples(
    identifier: HKQuantityTypeIdentifier,
    start: Date,
    end: Date,
    ascending: Bool = true,
    limit: Int = HKObjectQueryNoLimit,
    completion: @escaping ([HKQuantitySample]?, Error?) -> Void
  ) {
    guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
      completion(nil, nil)
      return
    }
    querySamples(type: type, start: start, end: end, ascending: ascending, limit: limit) { samples, error in
      completion(samples as? [HKQuantitySample], error)
    }
  }

  /// Latest quantity sample in a window (Kotlin `bestRecord` has a
  /// package-priority tier HealthKit cannot see; recency is the
  /// honest iOS analogue). Samples with value ≤ 0 are failed reads
  /// and never win.
  private func latestQuantity(
    identifier: HKQuantityTypeIdentifier,
    unit: HKUnit,
    start: Date,
    end: Date,
    completion: @escaping (Double?, Error?) -> Void
  ) {
    quantitySamples(identifier: identifier, start: start, end: end, ascending: false) { samples, error in
      if let error = error {
        completion(nil, error)
        return
      }
      let best = (samples ?? []).first { $0.quantity.doubleValue(for: unit) > 0 }
      completion(best?.quantity.doubleValue(for: unit), nil)
    }
  }

  // MARK: - Interval math (ports of the Kotlin merge/subtract rules)

  private func mergeIntervals(_ intervals: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
    let cleaned = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    var out: [(start: Date, end: Date)] = []
    for iv in cleaned {
      if let last = out.last, iv.start <= last.end {
        if iv.end > last.end {
          out[out.count - 1] = (start: last.start, end: iv.end)
        }
      } else {
        out.append(iv)
      }
    }
    return out
  }

  /// Kotlin `subtractAwake`: the session interval minus its merged,
  /// clamped awake intervals.
  private func subtractAwake(
    sessionStart: Date, sessionEnd: Date, awake: [(start: Date, end: Date)]
  ) -> [(start: Date, end: Date)] {
    guard sessionEnd > sessionStart else { return [] }
    let clamped = mergeIntervals(awake)
      .map { (start: max($0.start, sessionStart), end: min($0.end, sessionEnd)) }
      .filter { $0.end > $0.start }
    if clamped.isEmpty { return [(start: sessionStart, end: sessionEnd)] }
    var pieces: [(start: Date, end: Date)] = []
    var cursor = sessionStart
    for iv in clamped {
      if iv.start > cursor { pieces.append((start: cursor, end: iv.start)) }
      if iv.end > cursor { cursor = iv.end }
    }
    if cursor < sessionEnd { pieces.append((start: cursor, end: sessionEnd)) }
    return pieces
  }

  private func mergedMinutes(_ intervals: [(start: Date, end: Date)]) -> Int {
    // Kotlin per-stage rule: each merged interval contributes its
    // whole minutes (truncated per interval).
    mergeIntervals(intervals).reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
  }

  // MARK: - probeReadAccess

  /// One tiny real read — a SAMPLE query for today's step records,
  /// limit 1, results discarded. Chunk 5 (Vera's chunk-2 note): the
  /// probe is an `HKSampleQuery`, the closer analogue of the Kotlin
  /// probe's deliberate record-path read, rather than a statistics
  /// query. Semantics are unchanged: success means THIS read path
  /// worked; it is not proof every read works. No health values
  /// cross the channel (success is a boolean; failure carries the
  /// error class only). HealthKit never throws for a read denial
  /// (denied types read as no data), so this probe can never
  /// fabricate a grant verdict.
  private func probeReadAccess(result: @escaping FlutterResult) {
    guard let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
      fail(result, code: "PROBE_READ_FAILED", message: "Probe read failed.", error: nil)
      return
    }
    let (start, end) = dayRange(of: "today")
    querySamples(type: steps, start: start, end: end, limit: 1) { _, error in
      if let error = error {
        self.fail(result, code: "PROBE_READ_FAILED", message: "Probe read failed.", error: error)
      } else {
        result(true)
      }
    }
  }

  // MARK: - Authorization (chunk 6)

  /// The read-only authorization request, in context:
  /// `requestAuthorization(toShare: EMPTY, read: healthReadTypes)`
  /// — no share/write types are ever requested (the app ships no
  /// NSHealthUpdateUsageDescription, by design).
  ///
  /// The completion maps to the Dart contract the Android
  /// `requestPermissions` honors, translated honestly: Android
  /// answers with the granted-permission list, but HealthKit
  /// discloses no grant list, so success answers a Bool (the
  /// completion's success flag) and failure answers a FlutterError
  /// with a stable code and the error CLASS only in details —
  /// never health values. A completed sheet where the user shared
  /// nothing still completes with success: that is indistinguishable
  /// from an empty Health app, and the Dart availability model
  /// (requested + real-read evidence) carries that truth.
  ///
  /// There is deliberately no pending-request tracking here: the
  /// timeout/supersede discipline lives in the Dart layer (the same
  /// layer that owns it on Android), and HealthKit coalesces
  /// repeat requests for already-determined types without
  /// re-presenting the sheet.
  private func requestPermissions(result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      fail(result, code: "HEALTHKIT_UNAVAILABLE",
           message: "Health data is not available on this device.", error: nil)
      return
    }
    store.requestAuthorization(
      toShare: Set<HKSampleType>(), read: Self.healthReadTypes
    ) { success, error in
      if let error = error {
        self.fail(result, code: "AUTHORIZATION_FAILED",
                  message: "Authorization request failed.", error: error)
      } else {
        result(success)
      }
    }
  }

  // MARK: - Heart rate

  /// Dart shape: [{t: epochMs, bpm}] — bpm ≤ 0 dropped, distinct by
  /// time, sorted ascending (Kotlin contract).
  private func readHeartRateSamples(dateStr: String?, result: @escaping FlutterResult) {
    let (start, end) = dayRange(of: dateStr)
    quantitySamples(identifier: .heartRate, start: start, end: end) { samples, error in
      if let error = error {
        self.fail(result, code: "HR_SAMPLES_READ_FAILED",
                  message: "Could not read heart rate samples.", error: error)
        return
      }
      let unit = HKUnit.count().unitDivided(by: .minute())
      var seen = Set<Int64>()
      var out: [[String: Any]] = []
      for sample in samples ?? [] {
        let bpm = Int(sample.quantity.doubleValue(for: unit).rounded())
        if bpm <= 0 { continue }
        let t = self.epochMs(sample.startDate)
        if seen.insert(t).inserted {
          out.append(["t": t, "bpm": bpm])
        }
      }
      out.sort { ($0["t"] as? Int64 ?? 0) < ($1["t"] as? Int64 ?? 0) }
      result(out)
    }
  }

  // MARK: - Resting heart rate

  /// Latest resting HR sample of the day; null when none.
  private func readRestingHeartRate(dateStr: String?, result: @escaping FlutterResult) {
    let (start, end) = dayRange(of: dateStr)
    latestQuantity(identifier: .restingHeartRate,
                   unit: HKUnit.count().unitDivided(by: .minute()),
                   start: start, end: end) { value, error in
      if let error = error {
        self.fail(result, code: "RHR_READ_FAILED",
                  message: "Could not read resting heart rate.", error: error)
      } else {
        result(value.map { Int($0.rounded()) })
      }
    }
  }

  /// Dart shape: [{date: "YYYY-MM-DD", bpm}] — one value per local
  /// day (the day's earliest resting record, mirroring the Kotlin
  /// record path). NO average fallback: a day with no resting
  /// record stays absent (design §4).
  private func readRestingHrHistory(days: Int, result: @escaping FlutterResult) {
    let (start, end) = historyWindow(days: days)
    quantitySamples(identifier: .restingHeartRate, start: start, end: end) { samples, error in
      if let error = error {
        self.fail(result, code: "RHR_HISTORY_READ_FAILED",
                  message: "Could not read resting heart rate history.", error: error)
        return
      }
      let unit = HKUnit.count().unitDivided(by: .minute())
      var bpmByDate: [String: Int] = [:]
      for sample in samples ?? [] {
        let bpm = Int(sample.quantity.doubleValue(for: unit).rounded())
        if bpm <= 0 { continue }
        let date = self.dateString(of: sample.startDate)
        if bpmByDate[date] == nil { bpmByDate[date] = bpm }
      }
      let out: [[String: Any]] = bpmByDate.keys.sorted().map { date in
        ["date": date, "bpm": bpmByDate[date]!]
      }
      result(out)
    }
  }

  // MARK: - Steps

  /// Day step total; null when no data (never 0).
  private func readSteps(dateStr: String?, result: @escaping FlutterResult) {
    guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
      fail(result, code: "STEPS_READ_FAILED", message: "Could not read steps.", error: nil)
      return
    }
    let (start, end) = dayRange(of: dateStr)
    queryStatisticsSum(type: type, unit: .count(), start: start, end: end) { value, error in
      if let error = error {
        self.fail(result, code: "STEPS_READ_FAILED", message: "Could not read steps.", error: error)
      } else {
        result(value.map { Int($0.rounded()) })
      }
    }
  }

  /// Dart shape: [{date, count}] for every day in the window; days
  /// with no data carry 0 and Dart applies the founder zero rule
  /// (Kotlin contract).
  private func readStepsHistory(days: Int, result: @escaping FlutterResult) {
    guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
      fail(result, code: "STEPS_HISTORY_READ_FAILED", message: "Could not read step history.", error: nil)
      return
    }
    let (start, end) = historyWindow(days: days)
    queryDailySums(type: type, unit: .count(), start: start, end: end) { buckets, error in
      if let error = error {
        self.fail(result, code: "STEPS_HISTORY_READ_FAILED",
                  message: "Could not read step history.", error: error)
        return
      }
      let out: [[String: Any]] = (buckets ?? []).map { bucket in
        ["date": self.dateString(of: bucket.dayStart),
         "count": Int((bucket.value ?? 0).rounded())]
      }
      result(out)
    }
  }

  // MARK: - Energy (calories)

  /// `active ?: total` for one day (design §4 iOS analogue): active
  /// energy is primary; total = active + basal is the fallback only
  /// when active is absent. Null when neither exists; kcal ≤ 0
  /// dropped.
  private func readActiveCalories(dateStr: String?, result: @escaping FlutterResult) {
    guard let activeType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
          let basalType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) else {
      fail(result, code: "CALORIES_READ_FAILED", message: "Could not read active calories.", error: nil)
      return
    }
    let (start, end) = dayRange(of: dateStr)
    queryStatisticsSum(type: activeType, unit: .kilocalorie(), start: start, end: end) { active, error in
      if let error = error {
        self.fail(result, code: "CALORIES_READ_FAILED",
                  message: "Could not read active calories.", error: error)
        return
      }
      self.queryStatisticsSum(type: basalType, unit: .kilocalorie(), start: start, end: end) { basal, error2 in
        if let error2 = error2 {
          self.fail(result, code: "CALORIES_READ_FAILED",
                    message: "Could not read active calories.", error: error2)
          return
        }
        if let active = active, active > 0 {
          result(Int(active.rounded()))
          return
        }
        let total = (active ?? 0) + (basal ?? 0)
        if (active != nil || basal != nil), total > 0 {
          result(Int(total.rounded()))
        } else {
          result(nil)
        }
      }
    }
  }

  /// Dart shape: [{date, kcal}] — per day `active ?: total`, 0 when
  /// both absent (Kotlin contract; Dart treats 0 as missing).
  private func readCaloriesHistory(days: Int, result: @escaping FlutterResult) {
    guard let activeType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
          let basalType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) else {
      fail(result, code: "CALORIES_HISTORY_READ_FAILED", message: "Could not read calorie history.", error: nil)
      return
    }
    let (start, end) = historyWindow(days: days)
    queryDailySums(type: activeType, unit: .kilocalorie(), start: start, end: end) { activeBuckets, error in
      if let error = error {
        self.fail(result, code: "CALORIES_HISTORY_READ_FAILED",
                  message: "Could not read calorie history.", error: error)
        return
      }
      self.queryDailySums(type: basalType, unit: .kilocalorie(), start: start, end: end) { basalBuckets, error2 in
        if let error2 = error2 {
          self.fail(result, code: "CALORIES_HISTORY_READ_FAILED",
                    message: "Could not read calorie history.", error: error2)
          return
        }
        var basalByDate: [String: Double] = [:]
        for bucket in basalBuckets ?? [] {
          basalByDate[self.dateString(of: bucket.dayStart)] = bucket.value ?? 0
        }
        let out: [[String: Any]] = (activeBuckets ?? []).map { bucket in
          let date = self.dateString(of: bucket.dayStart)
          let active = bucket.value
          let total = (active ?? 0) + (basalByDate[date] ?? 0)
          let kcal: Int
          if let active = active, active > 0 {
            kcal = Int(active.rounded())
          } else if active != nil || basalByDate[date] != nil {
            kcal = total > 0 ? Int(total.rounded()) : 0
          } else {
            kcal = 0
          }
          return ["date": date, "kcal": kcal]
        }
        result(out)
      }
    }
  }

  /// Dart shape: [{date, kcal}] — per-day TOTAL (active + basal)
  /// only, the badges ladder figure (Kotlin contract).
  private func readTotalCaloriesHistory(days: Int, result: @escaping FlutterResult) {
    guard let activeType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
          let basalType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) else {
      fail(result, code: "TOTAL_CALORIES_HISTORY_READ_FAILED", message: "Could not read total calorie history.", error: nil)
      return
    }
    let (start, end) = historyWindow(days: days)
    queryDailySums(type: activeType, unit: .kilocalorie(), start: start, end: end) { activeBuckets, error in
      if let error = error {
        self.fail(result, code: "TOTAL_CALORIES_HISTORY_READ_FAILED",
                  message: "Could not read total calorie history.", error: error)
        return
      }
      self.queryDailySums(type: basalType, unit: .kilocalorie(), start: start, end: end) { basalBuckets, error2 in
        if let error2 = error2 {
          self.fail(result, code: "TOTAL_CALORIES_HISTORY_READ_FAILED",
                    message: "Could not read total calorie history.", error: error2)
          return
        }
        var basalByDate: [String: Double] = [:]
        for bucket in basalBuckets ?? [] {
          basalByDate[self.dateString(of: bucket.dayStart)] = bucket.value ?? 0
        }
        let out: [[String: Any]] = (activeBuckets ?? []).map { bucket in
          let date = self.dateString(of: bucket.dayStart)
          let total = (bucket.value ?? 0) + (basalByDate[date] ?? 0)
          return ["date": date, "kcal": total > 0 ? Int(total.rounded()) : 0]
        }
        result(out)
      }
    }
  }

  // MARK: - Blood pressure

  /// HealthKit stores BP as correlations of systolic + diastolic
  /// quantity samples. Dart shape: [{t: epochMs, sys, dia}] sorted
  /// descending by t (Kotlin contract). Pairs with a ≤ 0 component
  /// are failed reads and dropped.
  private func readBloodPressure(days: Int, result: @escaping FlutterResult) {
    guard let bpType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure),
          let sysType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
          let diaType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic) else {
      fail(result, code: "BP_READ_FAILED", message: "Could not read blood pressure records.", error: nil)
      return
    }
    let end = Date()
    let start = end.addingTimeInterval(-Double(days) * 86400)
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
    let query = HKCorrelationQuery(
      type: bpType, predicate: predicate, samplePredicates: nil
    ) { _, correlations, error in
      if let error = error {
        self.fail(result, code: "BP_READ_FAILED",
                  message: "Could not read blood pressure records.", error: error)
        return
      }
      let unit = HKUnit.millimeterOfMercury()
      var out: [[String: Any]] = []
      for correlation in correlations ?? [] {
        guard
          let sysSample = correlation.objects(for: sysType).first as? HKQuantitySample,
          let diaSample = correlation.objects(for: diaType).first as? HKQuantitySample
        else { continue }
        let sys = Int(sysSample.quantity.doubleValue(for: unit).rounded())
        let dia = Int(diaSample.quantity.doubleValue(for: unit).rounded())
        if sys <= 0 || dia <= 0 { continue }
        out.append(["t": self.epochMs(correlation.startDate), "sys": sys, "dia": dia])
      }
      out.sort { ($0["t"] as? Int64 ?? 0) > ($1["t"] as? Int64 ?? 0) }
      result(out)
    }
    store.execute(query)
  }

  // MARK: - Respiratory rate / oxygen saturation

  /// Latest reading in the 30 days ending on [dateStr] (Kotlin
  /// lookback rule); null when none.
  private func readRespiratoryRate(dateStr: String?, result: @escaping FlutterResult) {
    let (startOfDay, endOfDay) = dayRange(of: dateStr)
    let start = startOfDay.addingTimeInterval(-30 * 86400)
    latestQuantity(identifier: .respiratoryRate,
                   unit: HKUnit.count().unitDivided(by: .minute()),
                   start: start, end: endOfDay) { value, error in
      if let error = error {
        self.fail(result, code: "RESPIRATORY_READ_FAILED",
                  message: "Could not read respiratory rate.", error: error)
      } else {
        result(value)
      }
    }
  }

  /// Same 30-day lookback. HealthKit stores saturation as a
  /// fraction (0–1); the bridge returns percent, matching the
  /// Kotlin bridge's scaled value.
  private func readOxygenSaturation(dateStr: String?, result: @escaping FlutterResult) {
    let (startOfDay, endOfDay) = dayRange(of: dateStr)
    let start = startOfDay.addingTimeInterval(-30 * 86400)
    latestQuantity(identifier: .oxygenSaturation, unit: .percent(),
                   start: start, end: endOfDay) { value, error in
      if let error = error {
        self.fail(result, code: "OXYGEN_READ_FAILED",
                  message: "Could not read oxygen saturation.", error: error)
      } else {
        result(value.map { $0 * 100.0 })
      }
    }
  }

  // MARK: - Weight / height

  /// Latest body-mass sample in the last 90 days, kilograms; null
  /// when none.
  private func readLatestWeightKg(result: @escaping FlutterResult) {
    let (startOfDay, endOfDay) = dayRange(of: "today")
    let start = startOfDay.addingTimeInterval(-90 * 86400)
    latestQuantity(identifier: .bodyMass, unit: .gramUnit(with: .kilo),
                   start: start, end: endOfDay) { value, error in
      if let error = error {
        self.fail(result, code: "WEIGHT_READ_FAILED",
                  message: "Could not read weight records.", error: error)
      } else {
        result(value)
      }
    }
  }

  /// Latest height sample in the last 365 days, centimetres; null
  /// when none.
  private func readLatestHeightCm(result: @escaping FlutterResult) {
    let end = Date()
    let start = end.addingTimeInterval(-365 * 86400)
    latestQuantity(identifier: .height, unit: .meter(),
                   start: start, end: end) { value, error in
      if let error = error {
        self.fail(result, code: "HEIGHT_READ_FAILED",
                  message: "Could not read height records.", error: error)
      } else {
        result(value.map { $0 * 100.0 })
      }
    }
  }

  // MARK: - HRV (SDNN only — design §5)

  /// SDNN samples over the history window. This is the design §5
  /// separate series: its own method name and its own payload
  /// ([{t: epochMs, ms}]) — deliberately NOT the RMSSD payload
  /// (which carries a `tier` key and feeds `attributeDailyHrv`).
  /// SDNN values are never returned through `readHrvSamples` or
  /// `readHrvRmssd`; those stay unimplemented on iOS. No conversion
  /// between SDNN and RMSSD exists or is invented here.
  private func readHrvSdnnSamples(days: Int, result: @escaping FlutterResult) {
    let (start, end) = historyWindow(days: days)
    quantitySamples(identifier: .heartRateVariabilitySDNN, start: start, end: end) { samples, error in
      if let error = error {
        self.fail(result, code: "HRV_SDNN_READ_FAILED",
                  message: "Could not read heart rate variability (SDNN) samples.", error: error)
        return
      }
      var out: [[String: Any]] = []
      for sample in samples ?? [] {
        let ms = sample.quantity.doubleValue(for: .second()) * 1000.0
        if ms <= 0 { continue }
        out.append(["t": self.epochMs(sample.startDate), "ms": ms])
      }
      out.sort { ($0["t"] as? Int64 ?? 0) < ($1["t"] as? Int64 ?? 0) }
      result(out)
    }
  }

  // MARK: - Spike counts

  /// The Kotlin spike rule computed over HealthKit HR samples —
  /// an honest analogue (pure arithmetic over the same samples,
  /// not an HC-specific aggregation): a spike event starts at the
  /// first sample ≥ 100 bpm and absorbs subsequent ≥ 100 samples
  /// within 5 minutes of the previous one. Zero-bpm samples are
  /// dropped first. Only days with at least one usable sample
  /// appear; a day's count may be 0 (real).
  /// Dart shape: [{date, count}] sorted ascending.
  private func readSpikeCounts(days: Int, result: @escaping FlutterResult) {
    let (start, end) = historyWindow(days: days)
    quantitySamples(identifier: .heartRate, start: start, end: end) { samples, error in
      if let error = error {
        self.fail(result, code: "SPIKE_COUNTS_READ_FAILED",
                  message: "Could not read heart rate spikes.", error: error)
        return
      }
      let unit = HKUnit.count().unitDivided(by: .minute())
      var byDay: [String: [(t: Int64, bpm: Int)]] = [:]
      for sample in samples ?? [] {
        let bpm = Int(sample.quantity.doubleValue(for: unit).rounded())
        if bpm <= 0 { continue }
        let date = self.dateString(of: sample.startDate)
        byDay[date, default: []].append((t: self.epochMs(sample.startDate), bpm: bpm))
      }
      var out: [[String: Any]] = []
      for date in byDay.keys.sorted() {
        let daySamples = (byDay[date] ?? []).sorted { $0.t < $1.t }
        var count = 0
        var inEvent = false
        var eventEndMs: Int64 = 0
        for s in daySamples where s.bpm >= 100 {
          if !inEvent || s.t > eventEndMs {
            count += 1
            inEvent = true
          }
          eventEndMs = s.t + 300_000
        }
        out.append(["date": date, "count": count])
      }
      result(out)
    }
  }

  // MARK: - Exercise sessions

  /// Dart shape: [{startMs, endMs}] sorted ascending (Kotlin
  /// contract; day attribution happens in Dart).
  private func readExerciseSessions(days: Int, result: @escaping FlutterResult) {
    let (start, end) = historyWindow(days: days)
    querySamples(type: HKObjectType.workoutType(), start: start, end: end) { samples, error in
      if let error = error {
        self.fail(result, code: "EXERCISE_SESSIONS_READ_FAILED",
                  message: "Could not read exercise sessions.", error: error)
        return
      }
      var out: [[String: Any]] = []
      for sample in samples ?? [] {
        out.append(["startMs": self.epochMs(sample.startDate),
                    "endMs": self.epochMs(sample.endDate)])
      }
      out.sort { ($0["startMs"] as? Int64 ?? 0) < ($1["startMs"] as? Int64 ?? 0) }
      result(out)
    }
  }

  // MARK: - Sleep (chunk 3)

  private enum SleepStage {
    case inBed, asleepUnspecified, awake, core, deep, rem, other
  }

  /// Stage classification with the design §4 mapping:
  /// asleepCore → light (core), asleepDeep → deep, asleepREM → REM,
  /// awake → awake. The stage cases exist only on iOS 16+; on
  /// iOS 15 every sample is inBed / asleepUnspecified / awake,
  /// which is exactly the pre-iOS 16 stage-less shape.
  private func sleepStage(of sample: HKCategorySample) -> SleepStage {
    if #available(iOS 16.0, *) {
      switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
      case .some(.inBed): return .inBed
      case .some(.asleepUnspecified): return .asleepUnspecified
      case .some(.awake): return .awake
      case .some(.asleepCore): return .core
      case .some(.asleepDeep): return .deep
      case .some(.asleepREM): return .rem
      default: return .other
      }
    }
    switch sample.value {
    case HKCategoryValueSleepAnalysis.inBed.rawValue: return .inBed
    // Raw value 1 is `asleep` (renamed `asleepUnspecified` in
    // iOS 16; the named case is iOS 16+ in current SDKs, so the
    // pre-16 branch compares the raw value directly).
    case 1: return .asleepUnspecified
    case HKCategoryValueSleepAnalysis.awake.rawValue: return .awake
    default: return .other
    }
  }

  private struct SleepCluster {
    var start: Date
    var end: Date
    var samples: [HKCategorySample]
  }

  /// HealthKit has no session object: a session is a contiguous
  /// cluster of sleep samples (a new cluster starts when the gap
  /// from the previous sample's end exceeds 90 minutes). The
  /// cluster span is the in-bed/asleep span; its date is the
  /// wake/end date (design §4).
  private func clusterSleep(_ samples: [HKCategorySample]) -> [SleepCluster] {
    let sorted = samples.sorted { $0.startDate < $1.startDate }
    var clusters: [SleepCluster] = []
    for sample in sorted {
      if let last = clusters.last,
         sample.startDate.timeIntervalSince(last.end) <= 90 * 60 {
        clusters[clusters.count - 1].end = max(last.end, sample.endDate)
        clusters[clusters.count - 1].samples.append(sample)
      } else {
        clusters.append(SleepCluster(start: sample.startDate, end: sample.endDate, samples: [sample]))
      }
    }
    return clusters
  }

  private func stageIntervals(
    _ cluster: SleepCluster, stages: [SleepStage]
  ) -> [(start: Date, end: Date)] {
    cluster.samples
      .filter { stages.contains(sleepStage(of: $0)) }
      .map { (start: $0.startDate, end: $0.endDate) }
  }

  private func sleepSamples(
    start: Date, end: Date,
    completion: @escaping ([HKCategorySample]?, Error?) -> Void
  ) {
    guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
      completion(nil, nil)
      return
    }
    querySamples(type: type, start: start, end: end) { samples, error in
      completion(samples as? [HKCategorySample], error)
    }
  }

  /// Raw sessions over the history window, shipped faithfully for
  /// Dart's `summarizeSleepSessions` — the exact Kotlin payload:
  /// {date: wake/end local date, startMs, endMs, awake: [[startMs,
  /// endMs], ...], deep: [[startMs, endMs], ...]}, stage intervals
  /// raw (unmerged, unclamped). Pre-iOS 16 stage-less sessions map
  /// with EMPTY awake/deep lists — totals still compute in Dart.
  /// (The bridge payload carries awake + deep only, exactly like
  /// Kotlin; the core/REM stage detail crosses via readSleepStages.)
  private func readSleepHistory(days: Int, result: @escaping FlutterResult) {
    let (start, end) = historyWindow(days: days)
    // Widen the query by a day so a session that started the prior
    // evening is whole; clusters ending at/before the window start
    // are dropped below.
    let queryStart = start.addingTimeInterval(-86400)
    sleepSamples(start: queryStart, end: end) { samples, error in
      if let error = error {
        self.fail(result, code: "SLEEP_HISTORY_READ_FAILED",
                  message: "Could not read sleep history.", error: error)
        return
      }
      let clusters = self.clusterSleep(samples ?? []).filter { $0.end > start }
      var out: [[String: Any]] = []
      for cluster in clusters {
        let awake: [[Int64]] = self.stageIntervals(cluster, stages: [.awake])
          .map { [self.epochMs($0.start), self.epochMs($0.end)] }
        let deep: [[Int64]] = self.stageIntervals(cluster, stages: [.deep])
          .map { [self.epochMs($0.start), self.epochMs($0.end)] }
        out.append([
          "date": self.dateString(of: cluster.end),
          "startMs": self.epochMs(cluster.start),
          "endMs": self.epochMs(cluster.end),
          "awake": awake,
          "deep": deep,
        ])
      }
      out.sort {
        let d0 = $0["date"] as? String ?? ""
        let d1 = $1["date"] as? String ?? ""
        if d0 != d1 { return d0 < d1 }
        return ($0["startMs"] as? Int64 ?? 0) < ($1["startMs"] as? Int64 ?? 0)
      }
      result(out)
    }
  }

  /// Single-day sleep minutes under the founder's summed-bouts
  /// rule (Kotlin contract): sessions attributed by wake date;
  /// asleep = session minus merged awake, unioned across the
  /// night's sessions; total whole minutes computed once from
  /// milliseconds. Null when no session ends that day.
  private func readSleepMinutes(dateStr: String?, result: @escaping FlutterResult) {
    let requested = localDate(of: dateStr)
    let (startOfDay, endOfDay) = dayRange(of: dateStr)
    let queryStart = startOfDay.addingTimeInterval(-86400)
    sleepSamples(start: queryStart, end: endOfDay) { samples, error in
      if let error = error {
        self.fail(result, code: "SLEEP_READ_FAILED",
                  message: "Could not read sleep session.", error: error)
        return
      }
      let requestedStr = self.dateString(of: requested)
      let candidates = self.clusterSleep(samples ?? [])
        .filter { self.dateString(of: $0.end) == requestedStr }
      if candidates.isEmpty {
        result(nil)
        return
      }
      var asleepPieces: [(start: Date, end: Date)] = []
      for cluster in candidates {
        asleepPieces += self.subtractAwake(
          sessionStart: cluster.start, sessionEnd: cluster.end,
          awake: self.stageIntervals(cluster, stages: [.awake]))
      }
      let totalMs = self.mergeIntervals(asleepPieces)
        .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) * 1000 }
      result(Int(totalMs / 60000))
    }
  }

  /// Per-stage breakdown for the Sleep Profile screen. Dart shape:
  /// {minutesAsleep, deepMinutes, lightMinutes, remMinutes,
  /// efficiency} — the longest session ending in the Kotlin window
  /// (startOfDay, endOfDay + 12h) wins. Stage minutes come from
  /// merged stage intervals: asleepCore → light, asleepDeep →
  /// deep, asleepREM → rem; efficiency = asleep ÷ in-bed × 100.
  ///
  /// Stage-less sessions (pre-iOS 16: inBed/asleep only, no
  /// core/deep/REM samples): the three stage keys are OMITTED, so
  /// the Dart parser yields null stage fields — never 0-as-data
  /// (design §4) — while minutesAsleep and efficiency still
  /// compute. A stage key is likewise omitted when that stage has
  /// no intervals in a staged session.
  private func readSleepStages(dateStr: String?, result: @escaping FlutterResult) {
    let (startOfDay, endOfDay) = dayRange(of: dateStr)
    let windowEnd = endOfDay.addingTimeInterval(12 * 3600)
    let queryStart = startOfDay.addingTimeInterval(-86400)
    sleepSamples(start: queryStart, end: windowEnd) { samples, error in
      if let error = error {
        self.fail(result, code: "SLEEP_STAGES_READ_FAILED",
                  message: "Could not read sleep stages.", error: error)
        return
      }
      let candidates = self.clusterSleep(samples ?? []).filter {
        $0.end > startOfDay && $0.end < windowEnd
      }
      guard let session = candidates.max(by: {
        $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start)
      }) else {
        result(nil)
        return
      }
      let awakeMinutes = self.mergedMinutes(self.stageIntervals(session, stages: [.awake]))
      let timeInBed = Int(session.end.timeIntervalSince(session.start) / 60)
      let totalAsleep = timeInBed - awakeMinutes
      let efficiency = timeInBed > 0 ? Int(Double(totalAsleep) / Double(timeInBed) * 100) : 0
      var out: [String: Any] = [
        "minutesAsleep": totalAsleep,
        "efficiency": efficiency,
      ]
      let deep = self.stageIntervals(session, stages: [.deep])
      if !deep.isEmpty { out["deepMinutes"] = self.mergedMinutes(deep) }
      let light = self.stageIntervals(session, stages: [.core])
      if !light.isEmpty { out["lightMinutes"] = self.mergedMinutes(light) }
      let rem = self.stageIntervals(session, stages: [.rem])
      if !rem.isEmpty { out["remMinutes"] = self.mergedMinutes(rem) }
      result(out)
    }
  }

  #endif
}
