import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError("Preparation recovery \(checks + 1): \(message)") }; checks += 1
}
func wait(_ message: String, until ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !ready(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(ready(), message)
}
final class Locked<T> {
    private let lock = NSLock(); private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
    func edit(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
}
let now = Date(timeIntervalSince1970: 1_800_000_000), clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
let base = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-preparation-recovery-\(UUID())")
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }
let file = base.appendingPathComponent("task.json")
let checkpoint = PreparationRecoveryCheckpoint(savedAt: now, key: "synthetic-route", points: [.init(lat: 31.2, lng: 121.4), .init(lat: 31.2004, lng: 121.4)],
    frameLat: 31.2, frameLng: 121.4, frameID: 77, source: 3, style: 1, buildings: false,
    rangeKm: 0, forceRefresh: true, refreshStartedAt: now.addingTimeInterval(-100))
check(checkpoint.isValid(at: now), "valid preparation checkpoint")
check(checkpoint.matches(source: 3, style: 1, buildingPreference: false), "same style/config accepted")
check(!checkpoint.matches(source: 3, style: 2, buildingPreference: false), "style mismatch cannot silently change settings")
var noCapability = checkpoint; noCapability.buildingPreference = true
check(noCapability.matches(source: 3, style: 1, buildingPreference: true) && !noCapability.buildings,
      "saved user preference true/effective buildings false restores after capability changes")
var withCapability = noCapability; withCapability.buildings = true
check(withCapability.matches(source: 3, style: 1, buildingPreference: true) && withCapability.buildings,
      "saved building work restores without requiring display capability at launch")
check(!noCapability.matches(source: 3, style: 1, buildingPreference: false), "changed user building preference remains an explicit mismatch")
let store = PreparationRecoveryStore(url: file, now: { clock.get() })
let owner = store.begin(checkpoint); store.flushForTests()
check(store.load() == checkpoint, "atomic checkpoint roundtrip")
let restarted = PreparationRecoveryStore(url: file, now: { clock.get() })
check(restarted.load() == checkpoint, "process restart reuses saved request")
check(store.pendingWriteCount == 0 && store.successfulWriteCount == 1, "drained bounded writer")
let encoded = try JSONEncoder().encode(checkpoint), text = String(decoding: encoded, as: UTF8.self)
for field in ["latitudeFix", "routeProgress", "heading", "guidance", "ack", "speed", "simulation"] {
    check(!text.contains("\"\(field)\""), "checkpoint omits live navigation field \(field)")
}
var invalid = checkpoint
invalid.savedAt = now.addingTimeInterval(301); check(!invalid.isValid(at: now), "future checkpoint rejected")
invalid = checkpoint; invalid.savedAt = now.addingTimeInterval(-PreparationRecoveryCheckpoint.maximumAge - 1)
check(!invalid.isValid(at: now), "old checkpoint rejected")
invalid = checkpoint; invalid.refreshStartedAt = now.addingTimeInterval(301)
check(!invalid.isValid(at: now), "future force cutoff rejected")
invalid = checkpoint; invalid.frameID = 32768; check(!invalid.isValid(at: now), "frame bound")
invalid = checkpoint; invalid.points[0] = .init(lat: .nan, lng: 1)
check(!invalid.isValid(at: now), "nonfinite coordinate rejected")
invalid = checkpoint; invalid.points = [.init(lat: 31, lng: 121)]
check(!invalid.isValid(at: now), "short route rejected")
invalid = checkpoint; invalid.points = [PreparationRecoveryCheckpoint.Point](repeating: .init(lat: 31, lng: 121), count: 20_001)
check(!invalid.isValid(at: now), "point bound")
invalid = checkpoint; invalid.style = 11; check(!invalid.isValid(at: now), "radar has no persisted map task")
invalid = checkpoint; invalid.source = 0; check(!invalid.isValid(at: now), "unsupported provider rejected")
invalid = checkpoint; invalid.key = String(repeating: "x", count: 513)
check(!invalid.isValid(at: now), "bounded task label")
invalid = checkpoint; invalid.rangeKm = 10; check(!invalid.isValid(at: now), "range enum bound")
store.clear(owner: owner); store.flushForTests()
check(store.load() == nil, "discard clears durable task")
check(!store.update(checkpoint, owner: owner), "late cancelled callback rejected")
var newer = checkpoint; newer.key = "replacement-route"
let replacement = store.begin(newer)
check(!store.update(checkpoint, owner: owner), "old owner cannot replace new route")
store.clear(owner: owner); store.flushForTests()
check(store.load() == newer, "old owner cannot cancel replacement")
check(store.update(newer, owner: replacement), "new owner update accepted"); store.flushForTests()
try Data("{broken".utf8).write(to: file)
check(store.load() == nil && !FileManager.default.fileExists(atPath: file.path), "corrupt state discarded")
try Data(repeating: 32, count: PreparationRecoveryStore.maximumBytes + 1).write(to: file)
check(store.load() == nil, "oversized state bounded before decode")
try JSONEncoder().encode(invalid).write(to: file)
check(store.load() == nil, "decoded invalid checkpoint discarded")

// Pause after temporary bytes are prepared. Cancel/new tasks invalidate the owner
// before the short atomic publication step, so old work cannot resurrect state.
for replace in [false, true] {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), first = Locked(true)
    let raceURL = base.appendingPathComponent("race-\(replace).json")
    let race = PreparationRecoveryStore(url: raceURL, now: { clock.get() }, beforeCommit: {
        if first.get() { first.set(false); entered.signal(); _ = release.wait(timeout: .now() + 5) }
    })
    let ticket = race.begin(checkpoint)
    check(entered.wait(timeout: .now() + 5) == .success, "writer reached prepared temporary file")
    if replace { _ = race.begin(newer) } else { race.clear(owner: ticket) }
    check(!race.update(checkpoint, owner: ticket), "late update rejected before publication")
    release.signal(); race.flushForTests()
    check(race.load() == (replace ? newer : nil), "cancel/replacement wins prepared old write")
    check(race.successfulWriteCount == (replace ? 1 : 0), "superseded bytes never published")
}
let blockedURL = base.appendingPathComponent("not-a-directory")
try Data([1]).write(to: blockedURL)
let blocked = PreparationRecoveryStore(url: blockedURL.appendingPathComponent("task"), now: { clock.get() })
_ = blocked.begin(checkpoint); blocked.flushForTests()
check(blocked.load() == nil && blocked.pendingWriteCount == 0, "storage failure drains without navigation dependency")

// Loading state is passive. Only creating/starting the production worker requests
// data, and its force cutoff survives process restart instead of resetting to now.
let frame = MapGeo.Frame(refLat: checkpoint.frameLat, refLng: checkpoint.frameLng, id: checkpoint.frameID)
let plan = try RouteMapPlan(checkpoint.points.map { (frame.x($0.lng), frame.y($0.lat)) })
let cacheClock = Locked(now.addingTimeInterval(-50))
let cache = RouteMapCache(root: base.appendingPathComponent("packets"), limitBytes: 2_000_000,
    minimumFreeBytes: 0, maxAge: 7 * 24 * 3600, now: { cacheClock.get() }, availableBytes: { _ in 1_000_000_000 })
func packet(_ node: RouteMapPlan.Node) -> Data {
    MapGeo.encodeRaster(frameId: frame.id, x0: Int(node.x - 1200), y0: Int(node.y + 1200),
        w: RasterPacket.size, h: RasterPacket.size, mmPerPx: 2000,
        idx: [UInt8](repeating: 1, count: RasterPacket.size * RasterPacket.size))
}
for node in plan.nodes { try cache.store(packet(node), frame: frame, source: 3, node: node, style: 1) }
cacheClock.set(now)
let calls = Locked(0), phases = Locked([RouteMapPreparation.Phase]())
let prepared = RouteOfflineMaps(frame: frame, plan: plan, source: 3, buildings: false, style: 1,
    foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
    onProgress: { value in phases.edit { $0.append(value.phase) } }, forceRefresh: true, cache: cache,
    buildPacket: { _, node, _, _, _, _ in calls.edit { $0 += 1 }; return packet(node) },
    now: { clock.get() }, refreshStartedAt: checkpoint.refreshStartedAt)
check(calls.get() == 0, "constructing restored work is passive before explicit start")
prepared.start(); wait("restored force task recognizes work since original cutoff") { phases.get().contains(.complete) }
check(calls.get() == 0, "packets newer than original force cutoff are not regenerated")
check(prepared.refreshStartedAt == checkpoint.refreshStartedAt, "worker preserves original refresh boundary")
prepared.close()
let oldCache = RouteMapCache(root: base.appendingPathComponent("old-packets"), limitBytes: 2_000_000,
    minimumFreeBytes: 0, maxAge: 7 * 24 * 3600, now: { cacheClock.get() }, availableBytes: { _ in 1_000_000_000 })
cacheClock.set(now.addingTimeInterval(-200))
for node in plan.nodes { try oldCache.store(packet(node), frame: frame, source: 3, node: node, style: 1) }
cacheClock.set(now)
let after = Locked([Date]()), finished = Locked(false)
let refresh = RouteOfflineMaps(frame: frame, plan: plan, source: 3, buildings: false, style: 1,
    foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
    onProgress: { if $0.phase == .complete { finished.set(true) } }, forceRefresh: true, cache: oldCache,
    buildPacket: { _, node, _, force, boundary, _ in
        if !force { fatalError("Restored provider request lost force flag") }
        after.edit { $0.append(boundary) }; return packet(node)
    }, now: { clock.get() }, refreshStartedAt: checkpoint.refreshStartedAt)
refresh.start(); wait("old usable maps are refreshed before complete") { finished.get() }
check(after.get().count == plan.nodes.count && after.get().allSatisfy { $0 == checkpoint.refreshStartedAt }, "every force request keeps saved cutoff")
refresh.close()

// Provider cooldown is independent of map-task lifecycle and loaded before fetch.
let cooldownURL = base.appendingPathComponent("cooldown.json"), requests = Locked(0)
func request(_ gate: GtaServiceGate) -> TimeInterval? {
    do { let _: Int = try gate.fetch { requests.edit { $0 += 1 }; return 1 }; return nil }
    catch MapServiceError.http(_, let seconds) { return seconds }
    catch { fatalError("Unexpected cooldown failure \(error)") }
}
let firstGate = GtaServiceGate(now: { clock.get() }, persistenceURL: cooldownURL)
do { let _: Int = try firstGate.fetch { throw MapServiceError.http(status: 503, retryAfter: 120) } }
catch { }
clock.set(now.addingTimeInterval(30))
let secondGate = GtaServiceGate(now: { clock.get() }, persistenceURL: cooldownURL)
check(request(secondGate) == 90 && requests.get() == 0, "restart gate blocks before underlying provider")
let rolledBack = now.addingTimeInterval(-10000); clock.set(rolledBack)
let rollbackGate = GtaServiceGate(now: { clock.get() }, persistenceURL: cooldownURL)
check(request(rollbackGate) == 120, "large clock rollback preserves bounded cooldown")
clock.set(rolledBack.addingTimeInterval(10))
let repeatedGate = GtaServiceGate(now: { clock.get() }, persistenceURL: cooldownURL)
check(request(repeatedGate) == 110, "repeated restart does not slide rollback anchor")
clock.set(rolledBack.addingTimeInterval(120))
check(request(GtaServiceGate(now: { clock.get() }, persistenceURL: cooldownURL)) == nil && requests.get() == 1, "expiry resumes exactly once")
let capped = GtaServiceGate(now: { clock.get() }, persistenceURL: cooldownURL)
do { let _: Int = try capped.fetch { throw MapServiceError.http(status: 429, retryAfter: 20 * 24 * 3600) } } catch { }
check(capped.retryAt == clock.get().addingTimeInterval(GtaServiceGate.maximumCooldown), "corrupt/huge server duration bounded to seven days")
try Data(repeating: 1, count: 4097).write(to: cooldownURL)
check(request(GtaServiceGate(now: { clock.get() }, persistenceURL: cooldownURL)) == nil, "oversized cooldown cannot freeze app")
let slowEntered = DispatchSemaphore(value: 0), slowRelease = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
let slow = GtaServiceGate(now: { clock.get() }, persistenceURL: base.appendingPathComponent("slow-gate"), beforePersistence: {
    slowEntered.signal(); _ = slowRelease.wait(timeout: .now() + 5)
})
DispatchQueue.global().async { _ = request(slow); done.signal() }
check(slowEntered.wait(timeout: .now() + 5) == .success, "slow disk boundary entered")
let read = DispatchSemaphore(value: 0)
DispatchQueue.global().async { _ = slow.retryAt; read.signal() }
check(read.wait(timeout: .now() + 1) == .success, "UI deadline reader does not wait for disk lock")
slowRelease.signal(); check(done.wait(timeout: .now() + 5) == .success, "provider releases after disk finishes")
print("PreparationRecovery: \(checks) checks passed; passive restore, bounded atomic store, cancelled writers, saved force cutoff, durable provider gate")
