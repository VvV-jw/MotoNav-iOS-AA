import Foundation

// Both platforms replay the same bytes and seed. These timings measure computer core work, never display FPS.
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ why: String) {
    checks += 1
    guard value() else { fatalError("quality check \(checks): \(why)") }
}
func near(_ a: Double, _ b: Double, _ why: String) {
    check(a.isNaN && b.isNaN || abs(a - b) <= 1e-5, "\(why) got \(a) expected \(b)")
}
func number(_ object: [String: Any], _ key: String) -> Double { (object[key] as! NSNumber).doubleValue }
func numbers(_ value: Any) -> [Double] { (value as! [NSNumber]).map(\.doubleValue) }
func line(_ length: Double, _ step: Double) -> [Double] {
    var result: [Double] = []
    for i in 0...Int(ceil(length / step)) { result.append(min(length, Double(i) * step)); result.append(0) }
    return result
}
struct Input {
    let id: String
    var xy, centers: [Double]
    let inset, progress, start, end: Double
    init(_ data: [String: Any]) {
        id = data["id"] as! String
        inset = number(data, "safeInsetMeters"); start = number(data, "inspectedStartMeters"); end = number(data, "inspectedEndMeters")
        progress = data["nanProgress"] as? Bool == true ? .nan : number(data, "progressMeters")
        if let generator = data["generator"] as? [String: Any] {
            let length = number(generator, "lengthMeters")
            xy = line(length, number(generator, "routeStepMeters")); centers = line(length, number(generator, "tileStepMeters"))
        } else { xy = numbers(data["routeXY"]!); centers = numbers(data["readyCentersXY"]!) }
        if data["nonfiniteRoute"] as? Bool == true { xy[0] = .nan }
        if data["infiniteRoute"] as? Bool == true { xy[0] = .infinity }
        if data["infiniteTile"] as? Bool == true { centers[0] = -.infinity }
    }
    init(id: String, xy: [Double], centers: [Double], inset: Double, progress: Double, start: Double, end: Double) {
        self.id = id; self.xy = xy; self.centers = centers; self.inset = inset
        self.progress = progress; self.start = start; self.end = end
    }
    func evaluate() -> RouteCoverage.Result {
        RouteCoverage.evaluate(routeXY: xy, readyCentersXY: centers, half: 292.0 / 0.38 + 50.0 + inset,
                               progressMeters: progress, inspectedStartMeters: start, inspectedEndMeters: end)
    }
}
struct Reference {
    var state = "UNKNOWN", contiguous = 0.0, gap = Double.nan, total = 0.0
    var candidateChecks = 0
}
// Deliberately all-pairs, independent slab intersections: correctness and workload baseline.
func reference(_ input: Input) -> Reference {
    var result = Reference(), distance = [Double](repeating: 0, count: input.xy.count / 2)
    for i in 1..<distance.count {
        distance[i] = distance[i - 1] + hypot(input.xy[2 * i] - input.xy[2 * i - 2], input.xy[2 * i + 1] - input.xy[2 * i - 1])
    }
    result.total = distance.last!
    let p = input.progress.isFinite ? max(0, min(result.total, input.progress)) : 0
    guard input.start.isFinite, input.end.isFinite, input.start >= 0, input.end >= input.start else { result.state = "SCANNING"; return result }
    let begin = max(p, input.start), end = min(result.total, input.end)
    if begin > p + 1e-6 || end < p - 1e-6 { return result }
    var endpoint = false
    for j in stride(from: 0, to: input.centers.count, by: 2) {
        endpoint = endpoint || abs(input.xy[input.xy.count - 2] - input.centers[j]) <= input.inset + 1e-6 && abs(input.xy[input.xy.count - 1] - input.centers[j + 1]) <= input.inset + 1e-6
    }
    if result.total <= 1e-6 { result.state = endpoint ? "READY" : "GAP"; result.gap = endpoint ? .nan : 0; return result }
    var covered: [(Double, Double)] = []
    for i in 1..<distance.count {
        let span = distance[i] - distance[i - 1]
        if span <= 1e-6 || distance[i] < begin - 1e-6 || distance[i - 1] > end + 1e-6 { continue }
        for j in stride(from: 0, to: input.centers.count, by: 2) {
            result.candidateChecks += 1
            var a = max(0, (begin - distance[i - 1]) / span), b = min(1, (end - distance[i - 1]) / span)
            var intersects = true
            for axis in 0..<2 {
                let origin = input.xy[2 * i - 2 + axis], delta = input.xy[2 * i + axis] - origin
                let lower = input.centers[j + axis] - input.inset, upper = input.centers[j + axis] + input.inset
                if abs(delta) < 1e-15 {
                    if origin < lower - 1e-6 || origin > upper + 1e-6 { intersects = false; break }
                } else {
                    let x = (lower - origin) / delta, y = (upper - origin) / delta
                    a = max(a, min(x, y)); b = min(b, max(x, y))
                    if a > b + 1e-6 { intersects = false; break }
                }
            }
            if intersects { covered.append((distance[i - 1] + a * span, distance[i - 1] + b * span)) }
        }
    }
    covered.sort { $0.0 < $1.0 }; var cursor = p
    for interval in covered {
        if interval.0 > cursor + 1e-6 { break }
        cursor = max(cursor, interval.1); if cursor >= end - 1e-6 { break }
    }
    cursor = max(p, min(end, cursor)); result.contiguous = max(0, cursor - p)
    let gap = cursor < end - 1e-6 || p >= result.total - 1e-6 && !endpoint
    result.state = gap ? "GAP" : end >= result.total - 1e-6 ? "READY" : "UNKNOWN"; result.gap = gap ? cursor : .nan
    return result
}
func compare(_ input: Input, _ actual: RouteCoverage.Result, _ expected: Reference) {
    check(actual.state.rawValue == expected.state, "\(input.id) independent reference state")
    near(actual.contiguousMetersAhead, expected.contiguous, "\(input.id) independent reference continuity")
    near(actual.firstGapMeters, expected.gap, "\(input.id) independent reference gap")
    near(actual.totalMeters, expected.total, "\(input.id) independent reference total")
}
func resultJSON(_ input: Input, _ result: RouteCoverage.Result) -> [String: Any] {
    ["id": input.id, "state": result.state.rawValue, "contiguousMetersAhead": result.contiguousMetersAhead,
     "firstGapMeters": result.firstGapMeters.isFinite ? result.firstGapMeters as Any : NSNull(), "totalMeters": result.totalMeters,
     "routePoints": input.xy.count / 2, "readyTiles": input.centers.count / 2, "candidateChecks": result.candidateChecks]
}
var seed: UInt64 = 0x12345678
func random(_ n: Int) -> Int { seed = (seed &* 1664525 &+ 1013904223) & 0xffffffff; return Int(seed % UInt64(n)) }
func randomReplay() -> Int {
    for scenario in 0..<160 {
        var xy = [Double](repeating: 0, count: 66), centers = [Double](repeating: 0, count: 80)
        for i in 1..<33 { xy[2 * i] = xy[2 * i - 2] + Double(random(601) - 300); xy[2 * i + 1] = xy[2 * i - 1] + Double(random(601) - 300) }
        for j in centers.indices { centers[j] = Double(random(2401) - 1200) }
        let input = Input(id: "seeded_\(scenario)", xy: xy, centers: centers, inset: Double(80 + random(321)), progress: Double(random(1000)), start: 0, end: .greatestFiniteMagnitude)
        compare(input, input.evaluate(), reference(input))
    }
    return 160
}
func fingerprint(_ bytes: Data) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in bytes { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
    return "fnv1a64:" + String(hash, radix: 16)
}
func policyReplay() {
    for bits in 0..<32 {
        let foreground = bits & 1 != 0, wifiOnly = bits & 2 != 0, chargingOnly = bits & 4 != 0, wifi = bits & 8 != 0, charging = bits & 16 != 0
        let actual = PrefetchPolicy.decide(foreground: foreground, wifiOnly: wifiOnly, chargingOnly: chargingOnly, unmeteredWifi: wifi, charging: charging)
        let waitWifi = !foreground && wifiOnly && !wifi, waitCharging = !foreground && chargingOnly && !charging
        let expected = waitWifi && waitCharging ? "WAIT_NETWORK_AND_CHARGING" : waitWifi ? "WAIT_NETWORK" : waitCharging ? "WAIT_CHARGING" : "ALLOW"
        check(actual.rawValue == expected, "prefetch truth table \(bits)")
        if foreground { check(actual == .allow, "foreground bypasses optional preparation restrictions \(bits)") }
        if !wifiOnly && !chargingOnly { check(actual == .allow, "unrestricted defaults never add a wait \(bits)") }
    }
}

let fixture = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
let bytes = try Data(contentsOf: fixture), data = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
check((data["schema"] as? Int) == 1, "recognized shared fixture schema")
let options = data["benchmark"] as! [String: Any]
var results: [[String: Any]] = [], benchmark: Input?
for item in data["cases"] as! [[String: Any]] {
    let input = Input(item), expected = item["expected"] as! [String: Any], oldXY = input.xy, oldCenters = input.centers
    let actual = input.evaluate()
    if expected["error"] != nil {
        check(actual.state == .unknown && actual.firstGapMeters.isNaN, "\(input.id) rejects invalid input conservatively")
        results.append(["id": input.id, "error": "INVALID_GEOMETRY"])
    } else {
        check(actual.state.rawValue == expected["state"] as! String, "\(input.id) fixture state")
        near(actual.contiguousMetersAhead, number(expected, "contiguousMetersAhead"), "\(input.id) fixture continuity")
        near(actual.firstGapMeters, expected["firstGapMeters"] is NSNull ? .nan : number(expected, "firstGapMeters"), "\(input.id) fixture gap")
        near(actual.totalMeters, number(expected, "totalMeters"), "\(input.id) fixture total")
        compare(input, actual, reference(input)); results.append(resultJSON(input, actual))
    }
    check(zip(oldXY, input.xy).allSatisfy { pair in pair.0 == pair.1 || pair.0.isNaN && pair.1.isNaN } && zip(oldCenters, input.centers).allSatisfy { pair in pair.0 == pair.1 || pair.0.isNaN && pair.1.isNaN }, "\(input.id) passive coverage does not mutate selected route or tile input")
    if input.id == options["caseId"] as! String { benchmark = input }
}
policyReplay(); let randomScenarios = randomReplay(); check(benchmark != nil, "benchmark fixture exists")
let workload = benchmark!, warmups = Int(number(options, "warmupIterations")), samples = Int(number(options, "sampleIterations"))
for _ in 0..<warmups { _ = workload.evaluate() }
var times: [Double] = [], measured = workload.evaluate()
for _ in 0..<samples {
    let start = DispatchTime.now().uptimeNanoseconds; measured = workload.evaluate()
    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
}
let baselineStart = DispatchTime.now().uptimeNanoseconds, baseline = reference(workload)
let baselineMillis = Double(DispatchTime.now().uptimeNanoseconds - baselineStart) / 1e6
compare(workload, measured, baseline)
check(times.max()! < number(options, "maximumSampleSeconds") * 1000, "generous computer regression deadline")
check(Double(measured.candidateChecks) * number(options, "minimumCandidateReductionFactor") < Double(baseline.candidateChecks), "spatial index avoids all-pairs work")
var cancellationChecks = 0
let cancelled = RouteCoverage.evaluate(routeXY: workload.xy, readyCentersXY: workload.centers, half: 292.0 / 0.38 + 50.0 + workload.inset,
                                      progressMeters: 0, inspectedStartMeters: 0, inspectedEndMeters: workload.end,
                                      shouldCancel: { cancellationChecks += 1; return cancellationChecks >= 3 })
check(cancelled.state == .scanning && cancelled.firstGapMeters.isNaN, "cancelled obsolete analysis cannot publish ready or a false gap")
check(cancellationChecks <= 3, "analysis responds promptly to cancellation")
let timings: [String: Any] = ["scope": "computer_core_processing_not_device_fps", "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
    "warmupIterations": warmups, "sampleMilliseconds": times, "maximumSampleSeconds": number(options, "maximumSampleSeconds"),
    "referenceAllPairsMilliseconds": baselineMillis, "referenceCandidateChecks": baseline.candidateChecks,
    "indexedCandidateChecks": measured.candidateChecks, "peakMemoryBytes": NSNull()]
let report: [String: Any] = ["schema": 1, "platform": "ios", "passed": true, "checks": checks, "fixtureId": data["fixtureId"]!,
    "fixtureFingerprint": fingerprint(bytes), "fixtureBytes": bytes.count, "results": results, "seededScenarios": randomScenarios, "prefetchTruthTableCases": 32,
    "benchmark": timings, "limits": "Timing measures this computer only; packet rendering, BLE, device display FPS and peak device memory are not measured."]
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
print("PASS route-quality: \(checks) checks, \(results.count) shared cases, \(randomScenarios) seeded geometries, 32 prefetch combinations; report \(output.path)")
print("Computer core only: indexed checks \(measured.candidateChecks) vs reference \(baseline.candidateChecks), max sample \(times.max()!) ms (not device FPS)")
