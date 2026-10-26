import Foundation

var checks = 0
func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
func report(_ collector: PipelineDiagnostics) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: collector.jsonData(appVersion: "0.15.2-aa.2")) as! [String: Any]
}
func events(_ collector: PipelineDiagnostics) throws -> [[String: Any]] { try report(collector)["events"] as! [[String: Any]] }
func row(_ collector: PipelineDiagnostics, _ name: String) throws -> [String: Any] {
    try events(collector).last(where: { $0["event"] as? String == name })!
}
func fields(_ collector: PipelineDiagnostics, _ name: String) throws -> [String: Any] {
    try row(collector, name)["fields"] as! [String: Any]
}

var now = 100.0
let collector = PipelineDiagnostics(clock: { now })
collector.event("fetch-start", ["serial": 1])
check(!collector.isEnabled && collector.sampleCount == 0, "Release diagnostics default to disabled")
check(try report(collector)["hasScreenMeasurements"] as? Bool == false, "An unmeasured session reports no screen results")
collector.setEnabled(true)
check(collector.isEnabled && collector.sampleCount == 1, "Explicit opt-in starts a session")
collector.setEnabled(true)
check(collector.sampleCount == 1, "Repeated enabled state does not discard the current recording")
collector.event("fetch-start", ["serial": 1, "latitude": 39.9, "longitude": 116.4,
    "key": "private-amap-key", "url": "https://private.invalid?key=secret", "message": "location"])
now += 0.325
collector.event("fetch-complete", ["serial": 1, "bytes": 2048])
check(try fields(collector, "fetch-complete")["preparationMs"] as? Double == 325, "Preparation duration uses a monotonic clock")
check(try row(collector, "fetch-complete")["stage"] as? String == "phone", "Map preparation is a phone stage")
let sanitized = try fields(collector, "fetch-start")
check(sanitized.count == 1 && sanitized["serial"] as? Double == 1, "Coordinate, credential, URL and raw message fields are rejected")
let before = collector.sampleCount
collector.event("secret-amap-key", ["bytes": 9])
check(collector.sampleCount == before, "Unknown event names cannot leak arbitrary text")
collector.event("view-coverage", ["ready": true, "kmh": Double.nan, "bytes": Double.infinity])
check(try fields(collector, "view-coverage").count == 1, "Nonfinite metrics cannot break JSON export")

let captureJob = UUID().uuidString
collector.event("capture-start", ["job": captureJob, "buildings": true])
collector.event("tile-start", ["job": captureJob, "size": 1200])
now += 0.15
collector.event("tile-ready", ["job": captureJob, "size": 1200, "seconds": 0.15])
now += 0.05
collector.event("base-ready", ["job": captureJob, "bytes": 1440048])
check(try fields(collector, "base-ready")["captureMs"] as? Double == 200, "Capture-to-base time is available separately from BLE")
check(try fields(collector, "tile-ready")["seconds"] as? Double == 0.15, "Existing screenshot wait metric is retained")
check(try fields(collector, "tile-start")["job"] as? Int == 1, "Screenshot jobs export a short numeric correlation ID")
now += 0.6
collector.event("buildings-ready", ["job": captureJob, "components": 32, "pixels": 2000])
check(try fields(collector, "buildings-ready")["buildingMs"] as? Double == 600, "Building enrichment time starts after the usable base")
check(try fields(collector, "buildings-ready")["captureMs"] as? Double == 800, "Full screenshot preparation retains its total time")
check(try fields(collector, "buildings-ready")["components"] as? Double == 32, "Building detail counters remain numerical")
collector.event("tile-failed", ["job": UUID().uuidString, "size": 600, "seconds": 2.5,
    "error": "request failed key=private-amap-key lat=39.9"])
check(try fields(collector, "tile-failed").count == 2, "Screenshot failures retain only size and elapsed duration")
let captureText = String(data: try collector.jsonData(appVersion: "1.0"), encoding: .utf8)!
check(!captureText.contains(captureJob) && !captureText.contains("private-amap-key"), "No job UUID or arbitrary capture error reaches the export")

collector.event("bulk-queued", ["type": 3, "id": 7, "bytes": 2000, "parts": 5])
now += 0.04
collector.event("bulk-write", ["type": 3, "id": 7, "seq": 0])
check(try fields(collector, "bulk-write")["queueWaitMs"] as? Double == 40, "Queue wait is separated from preparation")
now += 0.2
collector.event("bulk-write", ["type": 3, "id": 7, "seq": 4])
now += 0.06
collector.event("bulk-ack", ["type": 3, "id": 7])
check(try fields(collector, "bulk-ack")["transferMs"] as? Double == 300, "Application ACK finishes the matching transfer")
check(try fields(collector, "bulk-ack")["ackWaitMs"] as? Double == 60, "ACK wait follows the last observed fragment")
check(try row(collector, "bulk-ack")["stage"] as? String == "ble", "Transfer timings remain a BLE stage")
collector.event("bulk-queued", ["type": 3, "id": 8, "bytes": 100])
now += 1
collector.event("bulk-ack", ["type": 3, "id": 7])
check(try fields(collector, "bulk-ack")["transferMs"] == nil, "A stale ACK cannot finish the replacement transfer")
collector.event("connection-lost", ["errorCode": 6, "description": "secret peripheral ID"])
collector.event("bulk-ack", ["type": 3, "id": 8])
check(try fields(collector, "bulk-ack")["transferMs"] == nil, "Disconnect clears outstanding timing associations")
collector.event("fetch-start", ["serial": 2])
collector.event("fetch-start", ["serial": 3])
collector.event("fetch-complete", ["serial": 2])
check(try fields(collector, "fetch-complete")["preparationMs"] == nil, "Superseded request does not acquire a false duration")
collector.event("bulk-queued", ["type": 1, "id": 9])
collector.event("bulk-cancel", ["type": 1])
collector.event("bulk-ack", ["type": 1, "id": 9])
check(try fields(collector, "bulk-ack")["transferMs"] == nil, "Style cancellation clears its transfer timer")

let screen = PipelineDiagnostics.screenFields(["S", "13.6", "73.5", "23", "80", "48.2", "2.5", "1", "45", "2"])!
collector.event("screen-stats", screen)
check(try fields(collector, "screen-stats")["fps"] as? Double == 13.6, "Recorded FPS comes from firmware statistics")
check(try row(collector, "screen-stats")["stage"] as? String == "screen", "Screen rendering remains distinct from phone and BLE")
check(screen["mapMs"] as? Double == 48.2 && screen["baseMs"] as? Double == 45, "Map and base-layer rendering timings parse separately")
check(try report(collector)["hasScreenMeasurements"] as? Bool == true, "A real parsed notification marks screen evidence as present")
check(PipelineDiagnostics.screenFields(["S", "NaN", "2", "3"]) == nil, "Malformed FPS is rejected")
check(PipelineDiagnostics.screenFields(["S", "13", "-2", "3"]) == nil, "Negative rendering duration is rejected")
check(PipelineDiagnostics.screenFields(["S", "13", "2"]) == nil, "Truncated statistics are rejected")
check(PipelineDiagnostics.screenFields(["S", "13", "2", "3"])!.count == 3, "Older firmware metrics stay absent rather than invented")
let profile = PipelineDiagnostics.screenProfileFields(["Q", "321", "25", "13", "5", "8", "10", "7", "6", "2", "1", "9"])!
collector.event("screen-profile", profile)
check(profile["baseLayerMs"] as? Double == 32.1 && profile["hintsMs"] as? Double == 0.9, "Firmware Q tenths are converted to milliseconds")
check(profile.count == 11 && profile["lanesMs"] as? Double == 0.2, "All eleven profiling phases preserve firmware order")
check(try row(collector, "screen-profile")["stage"] as? String == "screen", "Profiling records have the screen origin")
check(try report(collector)["screenProfileCount"] as? Int == 1, "Profiling samples are counted separately from FPS samples")
check(PipelineDiagnostics.screenProfileFields(["Q", "1", "2"]) == nil, "Incomplete profiling arrays are rejected")
check(PipelineDiagnostics.screenProfileFields(["Q", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "-1"]) == nil, "Negative profiling measurements are rejected")
check(PipelineDiagnostics.screenProfileFields(["Q", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "0.1"]) == nil, "Profiling rejects unexpected units rather than silently converting")
let prefixed = try JSONSerialization.jsonObject(with: collector.jsonData(appVersion: "iOS v0.15.2-aa.2")) as! [String: Any]
check(prefixed["appVersion"] as? String == "v0.15.2-aa.2", "The display version's fixed iOS prefix exports safely")

collector.setEnabled(false)
let stoppedCount = collector.sampleCount
collector.event("fetch-start", ["serial": 4])
check(collector.sampleCount == stoppedCount, "Disabling stops collection immediately and retains the export")
let stopJSON = try collector.jsonData(appVersion: "key=private", firmwareVersion: "secret URL / query")
let stopText = String(data: stopJSON, encoding: .utf8)!
check(!stopText.contains("private") && !stopText.contains("secret URL"), "Version metadata rejects arbitrary strings")
collector.setEnabled(true)
check(collector.sampleCount == 1, "Starting a new recording discards old session data")
check(try report(collector)["hasScreenMeasurements"] as? Bool == false, "New sessions do not inherit measured FPS")

let bounded = PipelineDiagnostics(capacity: 5, clock: { now })
bounded.setEnabled(true)
for n in 0..<30 { bounded.event("bulk-queued", ["type": 3, "id": n, "bytes": n]) }
check(bounded.sampleCount == 5, "Ring capacity remains bounded")
check(try report(bounded)["droppedSamples"] as? Int == 26, "Dropped oldest samples are reported")
check(try fields(bounded, "bulk-queued")["id"] as? Double == 29, "Latest samples survive the ring limit")
let byteBounded = PipelineDiagnostics(capacity: 1024, byteLimit: 2048)
byteBounded.setEnabled(true)
for _ in 0..<100 { byteBounded.event("screen-stats", screen) }
check(byteBounded.sampleCount < 20, "Byte budget independently bounds a wide record stream")
check(try byteBounded.jsonData(appVersion: "1").count < 8192, "Formatted export stays bounded with a small byte budget")

let concurrent = PipelineDiagnostics(capacity: 64)
concurrent.setEnabled(true)
DispatchQueue.concurrentPerform(iterations: 2000) { n in concurrent.event("bulk-write", ["type": 3, "id": n % 256, "seq": n]) }
check(concurrent.sampleCount == 64, "Concurrent writers retain a consistent bounded ring")
check(try report(concurrent)["droppedSamples"] as? Int == 1937, "Concurrent writes lose only the deliberately evicted records")

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: temporary) }
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
let unrelated = temporary.appendingPathComponent("keep-me.json")
try Data("unrelated".utf8).write(to: unrelated)
var latest: URL!
for _ in 0..<5 { latest = try bounded.export(appVersion: "0.15.2-aa.2", directory: temporary) }
let exported = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
check(exported.filter({ $0.lastPathComponent.hasPrefix("MotoNav-diagnostics-") }).count == 3, "Only three explicitly exported reports are retained")
check(FileManager.default.fileExists(atPath: latest.path), "Latest returned report remains shareable")
check(try Data(contentsOf: unrelated) == Data("unrelated".utf8), "Retention never deletes unrelated user files")
do {
    _ = try bounded.export(appVersion: "1", directory: unrelated)
    preconditionFailure("An unwritable/non-directory destination must fail")
} catch { checks += 1 }
let exportedText = try String(contentsOf: latest, encoding: .utf8)
check(!exportedText.contains("private-amap-key") && !exportedText.contains("latitude") && !exportedText.contains("wire.bin"), "Shareable JSON contains metadata only")

MapPipelineTrace.setEnabled(true)
MapPipelineTrace.packet(Data(repeating: 0x42, count: 1000), type: 3, id: 1, ready: true)
let facadeReport = try report(PipelineDiagnostics.shared)
check(try fields(PipelineDiagnostics.shared, "map-send")["bytes"] as? Double == 1000, "Packet facade records only the byte count")
check(facadeReport["hasScreenMeasurements"] as? Bool == false, "Sending map bytes never fabricates device measurements")
MapPipelineTrace.setEnabled(false)
print("Pipeline diagnostics: \(checks) checks passed")
