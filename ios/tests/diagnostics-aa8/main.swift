import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    guard value() else { fatalError("Diagnostics aa8 check \(checks + 1): \(label)") }; checks += 1
}
func wait(_ label: String, until ready: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !ready(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(ready(), label)
}
final class Locked<T> {
    private let lock = NSLock(); private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
}
let base = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-aa8-\(UUID())")
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }
let now = Date(timeIntervalSince1970: 1_800_000_000)
let checkpoint = PreparationRecoveryCheckpoint(savedAt: now, key: "synthetic-route", points: [.init(lat: 31, lng: 121), .init(lat: 31.01, lng: 121)],
    frameLat: 31, frameLng: 121, frameID: 20, source: 3, style: 1, buildings: false,
    rangeKm: 0, forceRefresh: false, refreshStartedAt: now)
let store = PreparationRecoveryStore(url: base.appendingPathComponent("task.json"), now: { now })
var published = [PreparationRecoveryStore.SaveState]()
store.observeSaveState { state in
    check(Thread.isMainThread, "save UI results arrive on main")
    published.append(state)
}
check(store.saveState == .idle, "initial state passive")
let owner = store.begin(checkpoint)
store.flushForTests()
check(store.saveState == .saved, "atomic durable publication reports saved")
wait("current saved result reaches UI") { published.last == .saved }
check(store.load() == checkpoint, "saved means durable matching task, not queued bytes")
let restarted = PreparationRecoveryStore(url: store.url, now: { now })
var loaded = false
restarted.loadAsync { value in check(value == checkpoint, "passive load returns saved task"); loaded = true }
wait("passive load complete") { loaded }
check(restarted.saveState == .saved, "loaded task has saved status")

var invalid = checkpoint; invalid.points[0] = .init(lat: .nan, lng: 121)
check(store.update(invalid, owner: owner), "current owner update accepted")
store.flushForTests()
check(store.saveState == .notSaved(.invalid), "invalid checkpoint explained")
check(store.load() == nil, "invalid replacement cannot leave recoverable stale bytes")
var large = checkpoint
large.points = Array(repeating: .init(lat: 31, lng: 121), count: PreparationRecoveryCheckpoint.maximumPoints + 1)
_ = store.begin(large); store.flushForTests()
check(store.saveState == .notSaved(.tooLarge), "over 20000 points gets explicit capacity reason")
check(!store.saveState.detail.isEmpty && store.saveState.isFailure, "capacity failure includes actionable passive text")
let newOwner = store.begin(checkpoint)
check(!store.update(large, owner: owner), "stale owner cannot change current save result")
store.flushForTests(); check(store.saveState == .saved, "new valid task can save after failure")
store.clear(owner: owner); store.flushForTests()
check(store.saveState == .saved, "stale clear cannot clear new state")
store.clear(owner: newOwner); store.flushForTests()
check(store.saveState == .idle && store.load() == nil, "explicit discard clears task and save message")
let blocked = base.appendingPathComponent("not-directory")
try Data([1]).write(to: blocked)
let storage = PreparationRecoveryStore(url: blocked.appendingPathComponent("task"), now: { now })
_ = storage.begin(checkpoint); storage.flushForTests()
check(storage.saveState == .notSaved(.storage), "storage failure surfaced without throwing into navigation")
check(storage.pendingWriteCount == 0, "failed storage does not spin or queue retries")

// Main delivery is independently generation-checked: a saved callback waiting on
// main must not overwrite a newer invalid task or a cancellation after disk I/O.
for cancel in [false, true] {
    let race = PreparationRecoveryStore(url: base.appendingPathComponent("queued-\(cancel).json"), now: { now })
    var results = [PreparationRecoveryStore.SaveState]()
    race.observeSaveState { results.append($0) }
    let ticket = race.begin(checkpoint); race.flushForTests()
    if cancel { race.clear(owner: ticket) } else { _ = race.begin(large) }
    race.flushForTests()
    let expected: PreparationRecoveryStore.SaveState = cancel ? .idle : .notSaved(.tooLarge)
    wait("new state reaches UI before old callbacks") { results.last == expected }
    check(!results.contains(.saved), "queued old saved callback cannot repaint newer task")
}
for cancel in [false, true] {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), first = Locked(true)
    let race = PreparationRecoveryStore(url: base.appendingPathComponent("inflight-\(cancel).json"), now: { now }, beforeCommit: {
        if first.get() { first.set(false); entered.signal(); _ = release.wait(timeout: .now() + 5) }
    })
    var results = [PreparationRecoveryStore.SaveState]()
    race.observeSaveState { results.append($0) }
    let ticket = race.begin(checkpoint)
    check(entered.wait(timeout: .now() + 5) == .success, "writer paused before atomic commit")
    check(race.saveState == .saving, "precommit bytes never claimed saved")
    if cancel { race.clear(owner: ticket) } else { _ = race.begin(large) }
    release.signal(); race.flushForTests()
    let expected: PreparationRecoveryStore.SaveState = cancel ? .idle : .notSaved(.tooLarge)
    wait("inflight replacement state delivered") { results.last == expected }
    check(race.load() == nil && !results.contains(.saved), "superseded write cannot resurrect disk or UI state")
}
let boundedEntered = DispatchSemaphore(value: 0), boundedRelease = DispatchSemaphore(value: 0), boundedFirst = Locked(true)
let boundedStore = PreparationRecoveryStore(url: base.appendingPathComponent("bounded.json"), now: { now }, beforeCommit: {
    if boundedFirst.get() { boundedFirst.set(false); boundedEntered.signal(); _ = boundedRelease.wait(timeout: .now() + 5) }
})
var boundedDeliveries = 0
boundedStore.observeSaveState { _ in boundedDeliveries += 1 }
let boundedOwner = boundedStore.begin(checkpoint)
check(boundedEntered.wait(timeout: .now() + 5) == .success, "bounded writer precommit entered")
for _ in 0..<2000 { check(boundedStore.update(checkpoint, owner: boundedOwner), "current coalesced update accepted") }
check(boundedStore.pendingWriteCount == 1 && boundedStore.pendingNotificationCount == 1, "disk and UI retain only one pending snapshot each")
boundedRelease.signal(); boundedStore.flushForTests()
wait("coalesced save reaches main once") { boundedDeliveries == 1 }
check(boundedStore.successfulWriteCount == 1 && boundedStore.saveState == .saved, "2000 replacement snapshots publish only the final durable task")

// One fixture is evaluated by both production Android and Swift summaries. These
// are synthetic unit-test durations, never evidence of real phone/screen FPS.
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
check(fixture["synthetic"] as? Bool == true, "shared fixture explicitly synthetic")
let cases = fixture["cases"] as! [[String: Any]]
var outputs = [[String: Any]]()
for item in cases {
    let id = item["id"] as! String
    let summary = PipelineSummary.evaluate(events: item["events"] as! [[String: Any]], droppedSamples: item["droppedSamples"] as! Int)
    check(summary.reason == item["expectedReason"] as! String, "fixture \(id) reason")
    check(summary.stages.count == 6, "six distinct measured stages")
    for stage in summary.stages {
        if stage.count < 5 { check(stage.p50Ms == nil && stage.p95Ms == nil, "insufficient percentile remains absent") }
        if summary.droppedSamples > 0 { check(stage.status == "truncated", "dropped evidence marks every stage truncated") }
    }
    if id == "complete-seven" {
        check(summary.stages[0].p50Ms == 3 && summary.stages[0].p95Ms == 100, "nearest-rank seven sample p50/p95")
        check(summary.stages[2].p50Ms == 23 && summary.stages[2].p95Ms == 120, "transfer remains inclusive interval")
    }
    if id == "invalid-and-wrong-origin" { check(summary.stages.allSatisfy { $0.count == 0 }, "invalid and wrong-origin metrics never enter result") }
    outputs.append(["id": id, "summary": summary.json])
}
let malicious = PipelineSummary.evaluate(events: [["event": "screen-stats", "fields": ["frameMs": true, "pushMs": Double.infinity]],
    ["event": "fetch-complete", "fields": ["preparationMs": Double.nan]]], droppedSamples: -1)
check(malicious.stages.allSatisfy { $0.count == 0 } && malicious.droppedSamples == 0, "bool nonfinite and negative dropped input rejected")

var tick = 0.0
let collector = PipelineDiagnostics(clock: { tick }); collector.setEnabled(true)
for n in 0..<7 {
    collector.event("fetch-start", ["serial": n]); tick += 0.05
    collector.event("fetch-complete", ["serial": n])
    collector.event("bulk-queued", ["type": 3, "id": n, "parts": 100]); tick += 0.01
    for seq in 0..<100 { collector.event("bulk-write", ["type": 3, "id": n, "seq": seq, "parts": 100]); tick += 0.001 }
    tick += 0.03; collector.event("bulk-ack", ["type": 3, "id": n])
    collector.event("screen-stats", ["fps": 25, "frameMs": 40, "pushMs": 12])
}
let measured = collector.summary()
check(measured.assessment == "observedTimings" && measured.stages.allSatisfy { $0.count == 7 }, "actual collector fields enter summary with all independent stages")
check(measured.droppedSamples == 0 && collector.sampleCount < 60, "intermediate writes coalesced while preserving first last and ACK timings")
check(measured.stages[1].p50Ms == 10 && measured.stages[3].p50Ms == 31, "compression does not change queue and last-write ACK durations")
let json = try JSONSerialization.jsonObject(with: collector.jsonData(appVersion: "0.15.8-aa.8")) as! [String: Any]
check((json["summary"] as? [String: Any])?["schema"] as? String == "motonav.pipeline.summary.v1", "explicit exported report includes automatic summary")
let reportText = String(decoding: try collector.jsonData(appVersion: "1"), as: UTF8.self)
check(!reportText.contains("synthetic-route"), "summary does not inherit private route data")
let bounded = PipelineDiagnostics(capacity: 5); bounded.setEnabled(true)
for _ in 0..<12 { bounded.event("screen-stats", ["frameMs": 20, "pushMs": 5]) }
check(bounded.summary().reason == "recordingTruncated" && bounded.summary().assessment == "unknown", "bounded loss never permits bottleneck attribution")
collector.setEnabled(false); let kept = collector.sampleCount
collector.event("screen-stats", ["frameMs": 1])
check(collector.sampleCount == kept, "disabled diagnostics do not collect")
let output: [String: Any] = ["schema": "motonav.pipeline.summary.parity.v1", "synthetic": true, "cases": outputs]
try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
print("DiagnosticsAA8: \(checks) checks passed; durable save states, stale UI protection, six-stage summary, bounded missing-evidence handling")
