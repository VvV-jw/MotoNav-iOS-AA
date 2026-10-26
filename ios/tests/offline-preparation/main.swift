import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() {
        FileHandle.standardError.write(Data("FAIL offline-preparation after \(checks) checks: \(message)\n".utf8))
        fatalError(message)
    }
    checks += 1
}
func wait(_ message: String, timeout: TimeInterval = 5, until ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !ready(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(ready(), "Timed out: \(message)")
}
func runFor(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
}

/// The worker reads these values while main advances time/storage or inspects recorded calls.
final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
}
struct BuildCall {
    let node: RouteMapPlan.Node
    let buildings: Bool
    let force: Bool
    let after: Date
}

let frame = MapGeo.Frame(refLat: 31.2, refLng: 121.4, id: 77)
let plan = try RouteMapPlan([(x: 0, y: 0), (x: 50, y: 0)])
let alternate = try RouteMapPlan([(x: 3_000, y: 0), (x: 3_050, y: 0)])
let timestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
let base = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-offline-preparation-\(UUID())")
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

func packet(_ node: RouteMapPlan.Node, material: UInt8 = 1) -> Data {
    MapGeo.encodeRaster(frameId: frame.id, x0: Int(node.x - 1200), y0: Int(node.y + 1200),
                        w: RasterPacket.size, h: RasterPacket.size, mmPerPx: 2000,
                        idx: [UInt8](repeating: material, count: RasterPacket.size * RasterPacket.size))
}
var packets: [Double: Data] = [:]
for node in plan.nodes + alternate.nodes { packets[node.x] = packet(node) }
check(packets.values.allSatisfy(RasterPacket.valid), "Injected packets pass actual raster validation")

func makeCache(_ name: String, clock: Locked<Date> = Locked(timestamp),
               free: Locked<Int64> = Locked(1_000_000_000)) -> RouteMapCache {
    RouteMapCache(root: base.appendingPathComponent(name), limitBytes: 2_000_000,
                  minimumFreeBytes: 1_000, maxAge: 7 * 24 * 3600,
                  now: { clock.get() }, availableBytes: { _ in free.get() })
}
func seed(_ cache: RouteMapCache, nodes: [RouteMapPlan.Node] = plan.nodes) throws {
    for node in nodes {
        try cache.store(packets[node.x]!, frame: frame, source: MapFeeder.SRC_AMAP, node: node, style: 1)
    }
}
func builder(_ calls: Locked<[BuildCall]>) -> RouteOfflineMaps.PacketBuilder {
    { _, node, buildings, force, after, token in
        calls.update { $0.append(BuildCall(node: node, buildings: buildings, force: force, after: after)) }
        if token.isCancelled { throw MapProcessingError.cancelled }
        return packets[node.x]!
    }
}
func drainControl() {
    let done = Locked(false)
    RouteOfflineMaps.cacheControl.async { done.set(true) }
    wait("cache-control protection operations") { done.get() }
}

// Fresh existing maps complete without scheduling provider/GPU work.
do {
    let cache = makeCache("fresh")
    try seed(cache)
    let calls = Locked<[BuildCall]>([])
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache, buildPacket: builder(calls))
    route.start()
    wait("fresh route completion") { progress.last?.phase == .complete }
    check(calls.get().isEmpty, "Fresh cache does not invoke the packet builder")
    check(progress.last?.ready == plan.nodes.count && progress.last?.freshReady == plan.nodes.count,
          "Fresh completion reports available and fresh counts separately")
    check(plan.nodes.allSatisfy(route.hasDetailed), "Existing valid packets are ready for display")
    route.close(); drainControl()
}

// Stale cache remains usable during preparation. Every stale node requests provider refresh.
do {
    let old = timestamp.addingTimeInterval(-8 * 24 * 3600)
    let clock = Locked(old)
    let cache = makeCache("stale", clock: clock)
    try seed(cache)
    clock.set(timestamp)
    check(plan.nodes.allSatisfy { cache.lookup(frame: frame, source: MapFeeder.SRC_AMAP,
        buildings: false, node: $0)?.isStale == true }, "Eight-day packets remain readable but stale")
    let calls = Locked<[BuildCall]>([])
    var foregroundBusy = true
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { foregroundBusy }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache, buildPacket: builder(calls))
    route.start()
    wait("stale route paused for foreground map") { progress.last?.phase == .paused }
    check(progress.last?.ready == plan.nodes.count && progress.last?.freshReady == 0,
          "Old maps count as usable while needing an update")
    check(progress.last?.oldestGeneratedAt == old, "Preparation exposes old local generation time")
    check(plan.nodes.allSatisfy(route.hasDetailed), "Stale maps remain available for display")
    check(plan.nodes.allSatisfy { route.generationDate($0) == old }, "Per-node dates are retained")
    check(calls.get().isEmpty, "Foreground map priority pauses background generation")
    foregroundBusy = false
    wait("stale route refreshed", timeout: 5) { progress.last?.phase == .complete }
    check(calls.get().count == plan.nodes.count, "Each stale node is rebuilt once")
    check(calls.get().allSatisfy { $0.force && !$0.buildings }, "Stale base nodes force source refresh")
    check(calls.get().allSatisfy { $0.after == route.refreshStartedAt }, "Every source refresh uses the preparation's shared cutoff")
    check(plan.nodes.allSatisfy { cache.lookup(frame: frame, source: MapFeeder.SRC_AMAP,
        buildings: false, node: $0)?.isStale == false }, "Updated cache is fresh after replacement")
    route.close(); drainControl()
}

// The newer plain map must win over an older detailed packet in both bytes and generation.
do {
    let old = timestamp.addingTimeInterval(-8 * 24 * 3600)
    let clock = Locked(old)
    let cache = makeCache("fresh-base-stale-details", clock: clock)
    for node in plan.nodes {
        let details = MapGeo.encodeRaster(frameId: frame.id, x0: Int(node.x - 1200), y0: Int(node.y + 1200),
            w: RasterPacket.size, h: RasterPacket.size, mmPerPx: 2000 | RasterPacket.flag,
            idx: [UInt8](repeating: 4, count: RasterPacket.size * RasterPacket.size))
        try cache.store(details, frame: frame, source: MapFeeder.SRC_AMAP, node: node, style: 1)
    }
    clock.set(timestamp)
    try seed(cache)
    let calls = Locked<[BuildCall]>([])
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: true,
        foregroundBusy: { true }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache, buildPacket: builder(calls))
    route.start()
    wait("fresh base selected over stale details") { progress.last?.phase == .paused }
    check(plan.nodes.allSatisfy { route.generationDate($0) == timestamp },
        "Display generation uses fresh selected base rather than the oldest stale layer")
    check(plan.nodes.allSatisfy { route.lookup($0)?.data == packets[$0.x]! },
        "Cache selection displays actual newer plain bytes")
    check(progress.last?.freshReady == plan.nodes.count && progress.last?.oldestGeneratedAt == timestamp,
        "Progress dates describe selected usable maps")
    check(calls.get().isEmpty, "Selection checks need no provider call")
    route.close(); drainControl()
}

// A new plain packet wins during explicit refresh even when old details are still seven-day fresh.
do {
    let old = timestamp.addingTimeInterval(-60)
    let clock = Locked(old)
    let cache = makeCache("force-new-base-old-fresh-details", clock: clock)
    for node in plan.nodes {
        let details = MapGeo.encodeRaster(frameId: frame.id, x0: Int(node.x - 1200), y0: Int(node.y + 1200),
            w: RasterPacket.size, h: RasterPacket.size, mmPerPx: 2000 | RasterPacket.flag,
            idx: [UInt8](repeating: 4, count: RasterPacket.size * RasterPacket.size))
        try cache.store(details, frame: frame, source: MapFeeder.SRC_AMAP, node: node)
    }
    clock.set(timestamp); try seed(cache)
    check(plan.nodes.allSatisfy { cache.lookup(frame: frame, source: MapFeeder.SRC_AMAP,
        buildings: true, node: $0)?.isStale == false }, "Old detailed packets have not expired under the ordinary seven-day rule")
    var progress: [RouteMapPreparation] = []
    let calls = Locked<[BuildCall]>([])
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: true,
        foregroundBusy: { true }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, forceRefresh: true, cache: cache,
        buildPacket: builder(calls), now: { timestamp })
    route.start()
    wait("current refresh base preferred over prior unexpired details") { progress.last?.phase == .paused }
    check(plan.nodes.allSatisfy { route.lookup($0)?.data == packets[$0.x]! },
          "Prior full packets do not hide bases generated in the current explicit refresh")
    check(plan.nodes.allSatisfy { route.generationDate($0) == timestamp },
          "The selected map's generation time follows the new base bytes")
    check(progress.last?.freshReady == plan.nodes.count && progress.last?.oldestGeneratedAt == timestamp,
          "Window freshness and generation use the same explicit-refresh cutoff as displayed packets")
    check(progress.last?.phase != .complete && calls.get().isEmpty,
          "Prior details remain usable without being counted as current-refresh completion")
    route.close(); drainControl()
}

// Manual refresh invalidates freshness even if valid packets were generated just now.
do {
    let cache = makeCache("forced")
    try seed(cache)
    let calls = Locked<[BuildCall]>([])
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, forceRefresh: true, cache: cache, buildPacket: builder(calls))
    route.start()
    wait("manual refresh completion") { progress.last?.phase == .complete }
    check(calls.get().count == plan.nodes.count, "Manual refresh rebuilds fresh nodes too")
    check(calls.get().allSatisfy { $0.force }, "Manual refresh bypasses the upstream source cache")
    check(progress.contains { $0.ready == plan.nodes.count && $0.freshReady == 0 },
          "Existing maps remain usable while a forced refresh begins")
    route.close(); drainControl()
}

// A permanent storage failure stops the timer/build loop, then explicit resume completes the route.
do {
    let free = Locked<Int64>(0)
    let cache = makeCache("storage", free: free)
    let calls = Locked<[BuildCall]>([])
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache, buildPacket: builder(calls))
    route.start()
    wait("storage block reported") { progress.last?.phase == .storageBlocked }
    check(calls.get().count == 1, "A failed store builds only the first packet")
    check(progress.last?.retryAt == nil, "Permanent storage pause does not advertise automatic retries")
    check(progress.last?.error != nil, "Storage failure explains why preparation paused")
    check(cache.stats().files == 0, "A failed store leaves no partial cached packet")
    let progressCount = progress.count
    runFor(1.25) // Cross at least two 0.5 s production timer intervals.
    check(calls.get().count == 1, "Permanent storage failure does not repeat downloads/builds")
    check(progress.count == progressCount, "The storage pause stops repeated timer publications")
    route.retryFailed()
    runFor(0.1)
    check(calls.get().count == 1 && progress.count == progressCount,
          "One-click failed-block retry cannot bypass a storage pause")
    free.set(1_000_000_000)
    route.resumeAfterStorageChange()
    wait("preparation resumed after storage cleanup") { progress.last?.phase == .complete }
    check(calls.get().count == 1 + plan.nodes.count, "Resume retries the failed packet and continues remaining nodes")
    check(progress.last?.error == nil, "Successful resume clears the prior storage error")
    check(cache.stats().files == plan.nodes.count, "Resume saves every required packet")
    route.close(); drainControl()
}

// OS/provider caches can fail before the final map store, including wrapped filesystem errors.
let nativeStorageFailures: [Error] = [
    NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
    NSError(domain: NSPOSIXErrorDomain, code: 28),
    NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotCreateFile,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)])
]
for (index, failure) in nativeStorageFailures.enumerated() {
    let cache = makeCache("native-storage-\(index)")
    let calls = Locked(0), fail = Locked(true)
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache,
        buildPacket: { _, node, _, _, _, _ in
            calls.update { $0 += 1 }
            if fail.get() { throw failure }
            return packets[node.x]!
        })
    route.start()
    wait("native disk-full pause \(index)") { progress.last?.phase == .storageBlocked }
    check(calls.get() == 1 && progress.last?.retryAt == nil,
        "Native storage failure stops automatic source retries")
    check(progress.last?.error?.contains("存储空间不足") == true,
        "Wrapped storage failure exposes a useful disk-space explanation")
    let count = progress.count
    runFor(1.1)
    check(calls.get() == 1 && progress.count == count, "Native storage pause invalidates the retry timer")
    fail.set(false); route.resumeAfterStorageChange()
    wait("native storage resume \(index)") { progress.last?.phase == .complete }
    check(cache.stats().files == plan.nodes.count, "Explicit resume retries OS/provider storage failure")
    route.close(); drainControl()
}

// A cancelled worker and late close cannot erase a newer route's protection or publish stale work.
do {
    let cache = makeCache("route-owner")
    try seed(cache, nodes: alternate.nodes)
    let started = Locked(false), released = Locked(false), finished = Locked(false)
    let release = DispatchSemaphore(value: 0)
    var oldProgress: [RouteMapPreparation] = []
    let oldRoute = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { oldProgress.append($0) }, cache: cache,
        buildPacket: { _, node, _, _, _, token in
            started.set(true)
            guard release.wait(timeout: .now() + 5) == .success else {
                finished.set(true)
                throw MapProcessingError.invalid("Test did not release the cancelled worker")
            }
            released.set(true)
            defer { finished.set(true) }
            if token.isCancelled { throw MapProcessingError.cancelled }
            return packets[node.x]!
        })
    oldRoute.start()
    wait("old route worker started") { started.get() }
    let calls = Locked<[BuildCall]>([])
    var newProgress: [RouteMapPreparation] = []
    let newRoute = RouteOfflineMaps(frame: frame, plan: alternate, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { newProgress.append($0) }, cache: cache, buildPacket: builder(calls))
    newRoute.start()
    wait("replacement route ready") { newProgress.last?.phase == .complete }
    check(cache.stats().protectedFiles == alternate.nodes.count, "The replacement owns its complete map protection")
    oldRoute.close()
    let countAtClose = oldProgress.count
    drainControl()
    release.signal()
    wait("cancelled old worker exits") { released.get() && finished.get() }
    runFor(0.05) // Give the production completion callback one main-queue turn.
    check(oldProgress.count == countAtClose, "Cancelled worker cannot publish old progress")
    check(cache.stats().protectedFiles == alternate.nodes.count, "Late old-owner close cannot clear newer protection")
    let cleared = try cache.clearUnprotected()
    check(cleared.files == alternate.nodes.count && cleared.protectedFiles == alternate.nodes.count,
          "Cache cleanup preserves all maps owned by the replacement route")
    check(alternate.nodes.allSatisfy { cache.read(frame: frame, source: MapFeeder.SRC_AMAP,
        buildings: false, node: $0) != nil }, "New route packets remain readable after old cancellation and cleanup")
    check(plan.nodes.allSatisfy { cache.read(frame: frame, source: MapFeeder.SRC_AMAP,
        buildings: false, node: $0) == nil }, "Cancelled old builder never commits an obsolete packet")
    check(calls.get().isEmpty, "Replacement route reuses its own valid cache")
    newRoute.close(); drainControl()
    check(cache.stats().protectedFiles == 0, "Closing the actual owner releases protection")
}

// A finite window starts at the current route position, then rolls without redoing healthy maps.
do {
    let longPlan = try RouteMapPlan([(x: 0, y: 0), (x: 60_000, y: 0)])
    let cache = makeCache("rolling-window")
    let calls = Locked<[Double]>([])
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: longPlan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache,
        buildPacket: { _, node, _, _, _, _ in
            calls.update { $0.append(node.distance) }
            return packet(node)
        }, rangeKm: 5)
    route.update(10)
    runFor(0.05)
    check(calls.get().isEmpty && progress.isEmpty, "Selecting the current target before start schedules no provider or progress work")
    route.start()
    wait("initial finite route window", timeout: 12) { progress.last?.phase == .complete }
    check(calls.get() == (Array(10...19) + [8, 9]).map { Double($0) * 600 },
          "The production worker prepares only its forward-first current window")
    check(progress.last?.total == 12 && progress.last?.ready == 12 && progress.last?.routeTotal == 101,
          "Preparation counts describe the window separately from the full route")
    check(progress.last?.rangeKm == 5 && progress.last?.title.contains("前方 5 公里") == true,
          "A finite completed range never claims the entire route is complete")
    check(cache.stats().files == 12 && cache.stats().protectedFiles == 12, "Only the twelve required packets are built and protected")
    check(cache.read(frame: frame, source: MapFeeder.SRC_AMAP, buildings: false, node: longPlan.nodes[50]) == nil,
          "Distant unselected blocks are not downloaded")
    route.update(11)
    wait("rolling finite route window", timeout: 12) { progress.last?.phase == .complete }
    check(calls.get().count == 13 && calls.get().last == 12_000,
          "Advancing one node prepares only the newly entered forward packet")
    check(cache.stats().files == 13 && cache.stats().protectedFiles == 12,
          "Rolling updates protection while retaining the old rear packet on disk")
    check(cache.read(frame: frame, source: MapFeeder.SRC_AMAP, buildings: false, node: longPlan.nodes[8]) != nil,
          "Changing the window never proactively deletes previously saved maps")
    let beforeRangeChange = calls.get().count
    route.setRangeKm(20); route.setRangeKm(5)
    wait("rapid range changes settle to final window", timeout: 12) { progress.last?.phase == .complete }
    drainControl()
    check(calls.get().count == beforeRangeChange && progress.last?.rangeKm == 5 && progress.last?.total == 12,
          "Cancelled range inspections cannot download obsolete work or overwrite final counts")
    check(cache.stats().protectedFiles == 12, "The latest selected window owns protection after rapid changes")
    let retained = try cache.clearUnprotected()
    check(retained.files == 12 && retained.protectedFiles == 12,
          "Cleaning unused maps preserves exactly the current window")
    route.close(); drainControl()
}

// Individual failures back off without stopping later healthy blocks, and explicit retry is selective.
do {
    let cache = makeCache("independent-failure")
    let clock = Locked(timestamp), maySucceed = Locked(false)
    let calls = Locked<[Double]>([])
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache,
        buildPacket: { _, node, _, _, _, _ in
            calls.update { $0.append(node.distance) }
            if node == plan.nodes[0], !maySucceed.get() { throw MapProcessingError.invalid("Injected unavailable block") }
            return packets[node.x]!
        }, now: { clock.get() })
    route.start()
    wait("healthy work passes a failed first block") { progress.last?.phase == .retrying && progress.last?.ready == 1 }
    check(calls.get() == [0, 50], "A first-block error does not prevent the second block from being built")
    check(progress.last?.failedCount == 1 && progress.last?.retryAt == timestamp.addingTimeInterval(15),
          "The retry state counts failed blocks and exposes their earliest deadline")
    clock.set(timestamp.addingTimeInterval(14))
    route.update(0)
    check(calls.get().count == 2, "An individual block does not retry before its deadline")
    clock.set(timestamp.addingTimeInterval(15))
    route.update(0)
    wait("second failed attempt doubles its backoff") {
        progress.last?.phase == .retrying && progress.last?.retryAt == timestamp.addingTimeInterval(45)
    }
    check(calls.get() == [0, 50, 0] && progress.last?.ready == 1,
          "Automatic retry touches only the failed block and preserves the healthy one")
    maySucceed.set(true)
    route.retryFailed()
    wait("one-click retry completes failed block") { progress.last?.phase == .complete }
    check(calls.get() == [0, 50, 0, 0], "Explicit retry skips waiting while retaining the already fresh packet")
    check(progress.last?.failedCount == 0 && progress.last?.error == nil,
          "A successful failed-block retry clears its failure count and error")
    route.retryFailed()
    runFor(0.05)
    check(calls.get().count == 4, "Retrying an already healthy window does not invalidate freshness")
    route.close(); drainControl()
}

// Provider cancellation is not a failed block and has no exponential retry penalty.
do {
    let cache = makeCache("cancel-is-not-failure")
    let calls = Locked(0)
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: plan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache,
        buildPacket: { _, node, _, _, _, _ in
            calls.update { $0 += 1 }
            if calls.get() == 1 { throw MapProcessingError.cancelled }
            return packets[node.x]!
        })
    route.start()
    wait("provider cancellation pauses without a failure") { progress.last?.phase == .paused }
    check(progress.last?.failedCount == 0 && progress.last?.retryAt == nil && progress.last?.error == nil,
          "Cancelled work creates no failed-block status or retry deadline")
    route.update(0)
    wait("cancelled block can immediately resume") { progress.last?.phase == .complete }
    check(calls.get() == 3, "Cancelled work retries immediately then continues to the healthy next block")
    route.close(); drainControl()
}

// Building enrichment is gated by fresh bases in the selected window, not the entire route.
do {
    let longPlan = try RouteMapPlan([(x: 0, y: 0), (x: 60_000, y: 0)])
    let cache = makeCache("window-buildings")
    for index in 8...19 {
        let node = longPlan.nodes[index]
        try cache.store(packet(node), frame: frame, source: MapFeeder.SRC_AMAP, node: node)
    }
    let calls = Locked<[BuildCall]>([])
    var progress: [RouteMapPreparation] = []
    let route = RouteOfflineMaps(frame: frame, plan: longPlan, source: MapFeeder.SRC_AMAP, buildings: true,
        foregroundBusy: { false }, onReady: { _ in }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache,
        buildPacket: { _, node, buildings, force, after, _ in
            calls.update { $0.append(BuildCall(node: node, buildings: buildings, force: force, after: after)) }
            return MapGeo.encodeRaster(frameId: frame.id, x0: Int(node.x - 1200), y0: Int(node.y + 1200),
                w: RasterPacket.size, h: RasterPacket.size, mmPerPx: 2000 | RasterPacket.flag,
                idx: [UInt8](repeating: 4, count: RasterPacket.size * RasterPacket.size))
        }, rangeKm: 5)
    route.update(10); route.start()
    wait("finite window building details", timeout: 12) { progress.last?.phase == .complete }
    check(calls.get().count == 12 && calls.get().allSatisfy { $0.buildings },
          "Prepared window bases allow every building job despite unprepared distant route blocks")
    check(progress.last?.detailedReady == 12 && progress.last?.routeTotal == 101,
          "Window detail completion reports its actual scope")
    route.close(); drainControl()
}

// A late non-cooperative builder cannot commit or report a packet after its window is replaced.
do {
    let longPlan = try RouteMapPlan([(x: 0, y: 0), (x: 60_000, y: 0)])
    let cache = makeCache("cancel-window")
    for index in 28...39 {
        let node = longPlan.nodes[index]
        try cache.store(packet(node), frame: frame, source: MapFeeder.SRC_AMAP, node: node)
    }
    let entered = Locked(false), left = Locked(false), cancelled = Locked(false)
    let release = DispatchSemaphore(value: 0)
    var progress: [RouteMapPreparation] = [], notifications: [Double] = []
    let route = RouteOfflineMaps(frame: frame, plan: longPlan, source: MapFeeder.SRC_AMAP, buildings: false,
        foregroundBusy: { false }, onReady: { notifications.append($0.distance) }, onStatus: { _ in },
        onProgress: { progress.append($0) }, cache: cache,
        buildPacket: { _, node, _, _, _, token in
            entered.set(true)
            guard release.wait(timeout: .now() + 10) == .success else { throw MapProcessingError.invalid("Window test did not release builder") }
            cancelled.set(token.isCancelled); left.set(true)
            return packet(node) // Deliberately ignore cancellation inside the injected provider.
        }, rangeKm: 5)
    route.update(10); route.start()
    wait("old window builder entered") { entered.get() }
    route.update(30)
    wait("new window protection replaces old while provider exits") { cache.stats().protectedFiles == 12 }
    notifications.removeAll()
    release.signal()
    wait("replacement window loads its cache", timeout: 12) { left.get() && progress.last?.phase == .complete }
    check(cancelled.get(), "Changing the rolling window cancels the obsolete provider token")
    check(!notifications.contains(6_000), "The obsolete builder cannot publish readiness for its old target")
    check(cache.read(frame: frame, source: MapFeeder.SRC_AMAP, buildings: false, node: longPlan.nodes[10]) == nil,
          "The worker rejects obsolete returned bytes before storing them")
    check(cache.stats().files == 12 && cache.stats().protectedFiles == 12 && progress.last?.total == 12,
          "Late work cannot change the new window's cached packets, protection or progress")
    route.close(); drainControl()
}

print("Offline preparation replay: \(checks) checks passed (computer scheduling/cache checks; no device FPS measurement)")
