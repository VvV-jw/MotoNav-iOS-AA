import Foundation

// Actual production policy/store/worker on synthetic routes. No physical SDK/GPS/BLE soak or FPS claim.
var checks = 0
let scope = "accelerated_scheduler_logic_not_sdk_gps_ble_or_device_fps"
func check(_ value: @autoclosure () -> Bool, _ why: String) {
    checks += 1; guard value() else { fatalError("PreparationStress \(checks): \(why)") }
}
func wait(_ why: String, timeout: TimeInterval = 8, until ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !ready(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(ready(), "Timeout: \(why)")
}
final class Locked<T> {
    private let lock = NSLock(); private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
    func update(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
}
func int(_ object: [String: Any], _ key: String) -> Int { (object[key] as! NSNumber).intValue }
func fingerprint(_ bytes: Data) -> String {
    var value: UInt64 = 0xcbf29ce484222325
    for b in bytes { value = (value ^ UInt64(b)) &* 0x100000001b3 }
    return String(format: "%016llx", value)
}
func timeline(_ fixture: [String: Any], root: URL) throws -> [String: Any] {
    let count = int(fixture, "nodes"), base = Double(int(fixture, "baseMillis")) / 1000
    let distances = (0..<count).map { Double($0 * int(fixture, "nodeSpacingMeters")) }
    var usable = [Bool](repeating: false, count: count), fresh = usable, details = usable
    var range = 5, target = 0, epoch = 1, pendingStatus = 0, backoff = OfflinePreparationPolicy.Backoff()
    var previousWindow = OfflinePreparationPolicy.window(distances: distances, target: 0, rangeKm: range)
    let clock = Locked(Date(timeIntervalSince1970: base)), gate = GtaServiceGate(now: { clock.get() })
    var active = true, wifiOnly = false, chargingOnly = false, wifi = true, charging = true
    var foreground = false, memory = false, configuration = false
    var builds = 0, networkFailures = 0, serviceResponses = 0, serviceWaits = 0, policyWaits = 0
    var restarts = 0, replans = 0, cancels = 0, externalFills = 0
    var trace: [[Any]] = []
    for event in fixture["events"] as! [[String: Any]] {
        let node = int(event, "node"), now = Date(timeIntervalSince1970: base + Double(int(event, "seconds")))
        clock.set(now); target = int(event, "target"); var networkFailure = false
        switch event["operation"] as! String {
        case "unrestrict": wifiOnly = false; chargingOnly = false; wifi = true; charging = true; foreground = false
        case "http429": pendingStatus = 429
        case "http503": pendingStatus = 503
        case "wifi_wait": wifiOnly = true; wifi = false
        case "power_wait": chargingOnly = true; charging = false
        case "conditions_ready": wifi = true; charging = true
        case "restart": backoff = .init(); epoch += 1; restarts += 1
        case "memory_pause": memory = true
        case "configuration_pause": configuration = true
        case "manual_continue": memory = false; configuration = false
        case "network_failure": networkFailure = true
        case "clean_unprotected":
            let window = OfflinePreparationPolicy.window(distances: distances, target: target, rangeKm: range)
            for i in 0..<count where i < window.lower || i > window.upper { usable[i] = false; fresh[i] = false; details[i] = false }
        case "foreground_fill": usable[node] = true; fresh[node] = true; details[node] = true; backoff.succeed(node); externalFills += 1
        case "cancel": active = false; epoch += 1; cancels += 1
        case "resume_task": active = true; backoff = .init(); epoch += 1
        case "range": range = int(event, "rangeKm")
        case "foreground_hold": foreground = true
        case "foreground_release": foreground = false
        case "expire_packet": fresh[node] = false; details[node] = false
        case "retry_window": backoff.retry(previousWindow.indexes)
        case "replan": backoff = .init(); usable = [Bool](repeating: false, count: count); fresh = usable; details = usable; epoch += 1; replans += 1; active = true
        default: break
        }
        let window = OfflinePreparationPolicy.window(distances: distances, target: target, rangeKm: range)
        previousWindow = window
        let rule = PrefetchPolicy.decide(foreground: false, wifiOnly: wifiOnly, chargingOnly: chargingOnly, unmeteredWifi: wifi, charging: charging)
        check(PrefetchPolicy.decide(foreground: true, wifiOnly: wifiOnly, chargingOnly: chargingOnly, unmeteredWifi: wifi, charging: charging) == .allow,
              "foreground always bypasses optional constraints")
        let reason = !active ? "CANCELLED" : memory ? "MEMORY" : configuration ? "CONFIGURATION" : foreground ? "FOREGROUND" :
            rule != .allow ? rule.rawValue : gate.retryAt != nil ? "SERVICE" : "ALLOW"
        var index = -1, stage = 0, retry = 0
        if reason == "SERVICE" { serviceWaits += 1 }
        if reason.hasPrefix("WAIT_") { policyWaits += 1 }
        if reason == "ALLOW" {
            let selected = OfflinePreparationPolicy.select(window: window, baseReady: usable, freshBase: fresh, freshDetails: details,
                                                            buildings: true, backoff: backoff, at: now)
            retry = selected.retryAt.map { Int($0.timeIntervalSince1970 - base) } ?? 0
            if let work = selected.work {
                index = work.index; stage = work.includeBuildings ? 2 : 1
                check(window.indexes.contains(index), "selected work inside current window")
                check(backoff.isEligible(index, at: now), "selected work never bypasses network backoff")
                if pendingStatus != 0 {
                    let response = pendingStatus; pendingStatus = 0
                    do {
                        let _: Int = try gate.fetch { throw MapServiceError.http(status: response, retryAfter: 40) }
                        fatalError("expected HTTP")
                    } catch MapServiceError.http(_, _) {
                        serviceResponses += 1; check(gate.retryAt == now.addingTimeInterval(40), "actual gate applies server retry deadline")
                    }
                } else if networkFailure { backoff.fail(index, at: now); networkFailures += 1 }
                else { usable[index] = true; fresh[index] = true; if stage == 2 { details[index] = true }; backoff.succeed(index); builds += 1 }
            }
        }
        for i in 0..<count { check(!fresh[i] || usable[i], "fresh map implies usable map") }
        trace.append([int(event, "tick"), epoch, range, target, window.lower, window.upper, reason, index, stage, retry,
                      usable.filter { $0 }.count, backoff.failedCount(in: window.indexes), gate.retryAt.map { Int($0.timeIntervalSince1970 - base) } ?? 0])
    }
    check(restarts >= 30 && replans >= 30 && cancels >= 30, "combined cancellation/restart/replan exercised throughout logical session")
    check(serviceResponses >= 30 && serviceWaits > 30 && policyWaits > 30 && networkFailures > 0, "service/network/optional constraints exercised")
    return ["trace": trace, "totals": ["builds": builds, "networkFailures": networkFailures, "serviceResponses": serviceResponses,
            "serviceWaits": serviceWaits, "policyWaits": policyWaits, "restarts": restarts, "replans": replans,
            "cancels": cancels, "foregroundFills": externalFills]]
}
func checkpoint(_ now: Date, range: Int) -> PreparationRecoveryCheckpoint {
    var result = PreparationRecoveryCheckpoint(savedAt: now, key: "synthetic-route", points: [.init(lat: 31.2, lng: 121.4), .init(lat: 31.201, lng: 121.401)],
        frameLat: 31.2, frameLng: 121.4, frameID: 77, source: 3, style: 1, buildings: false, rangeKm: range,
        forceRefresh: true, refreshStartedAt: now.addingTimeInterval(-1))
    result.id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    return result
}
func persistence(_ root: URL, now: Date) throws -> [String: Any] {
    let url = root.appendingPathComponent("map-preparation.json"), store = PreparationRecoveryStore(url: url, now: { now })
    let owner = store.begin(checkpoint(now, range: 5)); var peak = 0
    for i in 0..<5000 {
        check(store.update(checkpoint(now, range: [0, 5, 20, 50][i % 4]), owner: owner), "current owner accepts updates")
        peak = max(peak, store.pendingWriteCount); check(peak <= 1, "pending persistence snapshot bounded")
    }
    store.flushForTests(); check(store.load()?.rangeKm == 50, "latest update persisted after actual write storm")
    let writes = store.successfulWriteCount
    check(writes > 0 && writes <= 5001, "actual successful write count bounded by submissions")
    let restarted = PreparationRecoveryStore(url: url, now: { now })
    check(restarted.load()?.rangeKm == 50, "new store restores latest task from real disk")
    check(restarted.load()?.forceRefresh == true && restarted.load()?.refreshStartedAt == now.addingTimeInterval(-1),
          "unfinished force refresh keeps original cutoff across process/store restart")
    let replacement = store.begin(checkpoint(now, range: 20))
    check(!store.update(checkpoint(now, range: 0), owner: owner), "old owner callback rejected immediately")
    store.flushForTests(); let staleRejected = store.load()?.rangeKm == 20
    check(staleRejected, "old owner cannot overwrite replacement")
    store.clear(); check(!store.update(checkpoint(now, range: 0), owner: replacement), "cancel rejects late old owner")
    store.flushForTests(); let cleared = store.load() == nil
    check(cleared, "cancel invalidates late callback and checkpoint stays absent")
    for replan in [false, true] {
        let prepared = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), prepares = Locked(0)
        let race = PreparationRecoveryStore(url: root.appendingPathComponent("prepared-race-\(replan)"), now: { now }, beforeCommit: {
            prepares.update { $0 += 1 }
            if prepares.get() == 1 {
                prepared.signal()
                guard release.wait(timeout: .now() + 5) == .success else { fatalError("test disk write not released") }
            }
        })
        let staleOwner = race.begin(checkpoint(now, range: 5))
        check(prepared.wait(timeout: .now() + 4) == .success, "real temporary file prepared before cancellation/replan")
        race.clear(); if replan { race.begin(checkpoint(now, range: 20)) }
        check(!race.update(checkpoint(now, range: 0), owner: staleOwner), "late owner rejected while old disk write is blocked")
        release.signal(); race.flushForTests()
        check(replan ? race.load()?.rangeKm == 20 : race.load() == nil, "generation recheck drops already-prepared stale disk snapshot")
    }
    try Data([0, 1, 2]).write(to: url)
    check(restarted.load() == nil && !FileManager.default.fileExists(atPath: url.path), "corrupt restart input is safely removed")
    try Data(repeating: 0, count: PreparationRecoveryStore.maximumBytes + 1).write(to: url)
    check(restarted.load() == nil && !FileManager.default.fileExists(atPath: url.path), "oversized restart input is safely removed before decode")
    return ["updates": 5000, "maximumPendingSnapshots": peak, "successfulWrites": writes,
            "pendingCounterScope": "pending snapshot excludes the one running disk write",
            "staleOwnerRejected": staleRejected, "cancelRemainsCleared": cleared, "restartRestoredLatest": true, "preparedFileRaceCases": 2]
}
func cooldown(_ root: URL, now: Date) throws -> [String: Any] {
    let url = root.appendingPathComponent("gta-cooldown.json"), clock = Locked(now), calls = Locked(0)
    let first = GtaServiceGate(now: { clock.get() }, persistenceURL: url)
    do { let _: Int = try first.fetch { calls.update { $0 += 1 }; throw MapServiceError.http(status: 503, retryAfter: 60) }; fatalError("expected service response") }
    catch MapServiceError.http(_, _) {}
    check(first.retryAt == now.addingTimeInterval(60), "real gate wrote service cooldown before restart")
    let restarted = GtaServiceGate(now: { clock.get() }, persistenceURL: url)
    check(restarted.retryAt == nil, "fresh gate getter reads RAM without disk load")
    do { let _: Int = try restarted.fetch { calls.update { $0 += 1 }; return 1 }; fatalError("expected cold-start gate") }
    catch MapServiceError.http(_, _) {}
    check(calls.get() == 1 && restarted.retryAt == now.addingTimeInterval(60), "cold start cannot issue fetch before saved cooldown")
    clock.set(now.addingTimeInterval(-3600))
    let rollback = GtaServiceGate(now: { clock.get() }, persistenceURL: url)
    do { let _: Int = try rollback.fetch { calls.update { $0 += 1 }; return 1 }; fatalError("expected rollback gate") }
    catch MapServiceError.http(_, _) {}
    let deadline = clock.get().addingTimeInterval(60)
    check(rollback.retryAt == deadline && calls.get() == 1, "one-hour clock rollback preserves bounded service wait")
    let again = GtaServiceGate(now: { clock.get() }, persistenceURL: url)
    do { let _: Int = try again.fetch { calls.update { $0 += 1 }; return 1 }; fatalError("expected repeated rollback gate") }
    catch MapServiceError.http(_, _) {}
    check(again.retryAt == deadline && calls.get() == 1, "same-clock repeated restarts never slide normalized cooldown")
    clock.set(deadline); let result = try again.fetch { calls.update { $0 += 1 }; return 1 }
    check(result == 1 && calls.get() == 2, "normalized service wait expires once")
    return ["restarts": 3, "rollbackSeconds": 3600, "providerCalls": calls.get(), "savedCooldownSeconds": 60, "sameClockStable": true]
}
func barrier() {
    let done = Locked(false); RouteOfflineMaps.cacheControl.async { done.set(true) }
    wait("cache control barrier") { done.get() }
}
func worker(_ root: URL) throws -> [String: Any] {
    let frame = MapGeo.Frame(refLat: 31.2, refLng: 121.4, id: 77), plan = try RouteMapPlan([(x: 0, y: 0), (x: 600, y: 0)])
    let cache = RouteMapCache(root: root.appendingPathComponent("actual-worker"), limitBytes: 5_000_000, minimumFreeBytes: 1_000,
                             availableBytes: { _ in 1_000_000_000 })
    func packet(_ node: RouteMapPlan.Node) -> Data {
        MapGeo.encodeRaster(frameId: frame.id, x0: Int(node.x - 1200), y0: Int(node.y + 1200), w: RasterPacket.size, h: RasterPacket.size,
                            mmPerPx: 2000, idx: [UInt8](repeating: 0, count: RasterPacket.size * RasterPacket.size))
    }
    var peakProtected = 0, maximum = 0
    let late = Locked(0)
    for _ in 0..<8 {
        let entered = Locked(false), release = DispatchSemaphore(value: 0), concurrent = Locked(0), peak = Locked(0), closed = Locked(false)
        let old = RouteOfflineMaps(frame: frame, plan: plan, source: 3, buildings: false, style: MapStylePolicy.minimal,
            foregroundBusy: { false }, onReady: { _ in if closed.get() { late.update { $0 += 1 } } }, onStatus: { _ in }, cache: cache,
            buildPacket: { _, node, _, _, _, _ in
                concurrent.update { $0 += 1 }; peak.update { $0 = max($0, concurrent.get()) }
                entered.set(true); release.wait(); defer { concurrent.update { $0 -= 1 } }; return packet(node)
            })
        old.start(); wait("real slow provider entered") { entered.get() }
        old.pauseForMemoryPressure(); old.resumeAfterStorageChange(); old.resumeAfterStorageChange()
        closed.set(true); old.close(); release.signal(); wait("old provider drains after cancel") { concurrent.get() == 0 }
        maximum = max(maximum, peak.get()); check(peak.get() == 1, "per-owner real provider concurrency bounded to one")
        let rule = Locked(PrefetchPolicy.Decision.both), builds = Locked(0)
        var progress: RouteMapPreparation?
        let current = RouteOfflineMaps(frame: frame, plan: plan, source: 3, buildings: false, style: MapStylePolicy.minimal,
            foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in }, onProgress: { progress = $0 }, prefetchDecision: { rule.get() }, cache: cache,
            buildPacket: { _, node, _, _, _, _ in builds.update { $0 += 1 }; return packet(node) })
        current.start(); wait("new owner respects combined optional restrictions") { progress?.phase == .policyPaused }
        for node in plan.nodes { try cache.store(packet(node), frame: frame, source: 3, node: node, style: MapStylePolicy.minimal); current.noteCachedPacket(node) }
        rule.set(.allow); wait("foreground-filled cache resumes without duplicate provider") { progress?.ready == 2 && progress?.freshReady == 2 }
        barrier(); check(builds.get() == 0, "foreground fill plus policy changes never duplicate provider download")
        old.close(); barrier(); let cleaned = try cache.clearUnprotected()
        check(cleaned.protectedFiles == 2 && cleaned.files == 2, "old owner close/cleanup cannot erase replacement window")
        peakProtected = max(peakProtected, cleaned.protectedFiles)
        current.close(); barrier(); check(cache.stats().protectedFiles == 0, "closed current owner releases protection")
        _ = try cache.clearUnprotected(); check(cache.stats().files == 0, "unprotected cycle data clears cleanly")
    }
    check(late.get() == 0, "closed owners publish no late provider callbacks")
    return ["cycles": 8, "maximumConcurrentPerOwner": maximum, "closedOwnerCallbacks": late.get(), "maximumProtectedFiles": peakProtected,
            "finalProtectedFiles": cache.stats().protectedFiles, "routeNodes": plan.nodes.count, "cacheDiskScans": cache.stats().diskScans]
}
let arguments = CommandLine.arguments
let bytes = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let fixture = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
let output = URL(fileURLWithPath: arguments[2]), root = output.deletingLastPathComponent().appendingPathComponent("preparation-stress-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
var report = try timeline(fixture, root: root)
report["persistence"] = try persistence(root, now: Date(timeIntervalSince1970: Double(int(fixture, "baseMillis")) / 1000))
report["cooldown"] = try cooldown(root, now: Date(timeIntervalSince1970: Double(int(fixture, "baseMillis")) / 1000))
report["worker"] = try worker(root)
report.merge(["schema": 1, "platform": "ios", "passed": true, "scope": scope, "checks": checks,
              "fixtureId": fixture["fixtureId"]!, "fixtureFingerprint": fingerprint(bytes), "fixtureBytes": bytes.count,
              "logicalDurationSeconds": int(fixture, "logicalDurationSeconds"), "eventCount": (fixture["events"] as! [Any]).count]) { _, new in new }
try (JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)).write(to: output, options: .atomic)
print("PASS PreparationStress: \(checks) checks; 1801 scheduler states / 9000 logical seconds, 5000 real persistence updates, 8 real worker cycles; \(output.path)")
