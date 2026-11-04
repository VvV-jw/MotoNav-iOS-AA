import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label); checks += 1
}
func waitFor(_ label: String, timeout: TimeInterval = 4, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        precondition(Date() < deadline, "Timed out: \(label)")
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}
func drain(for seconds: TimeInterval = 0.06) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.005)))
    }
}

final class Clock {
    private let lock = NSLock()
    private var value = Date()
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); value.addTimeInterval(seconds); lock.unlock()
    }
}
final class Builder {
    struct Request {
        let frame: MapGeo.Frame, node: RouteMapPlan.Node
        let satellite: Bool, buildings: Bool
        let style: Int
    }
    private let lock = NSLock()
    private var recorded: [Request] = []
    var action: ((Int, Request, MapWorkToken) throws -> Data)?
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    func build(_ frame: MapGeo.Frame, _ node: RouteMapPlan.Node, _ satellite: Bool,
               _ buildings: Bool, _ style: Int, _ token: MapWorkToken) throws -> Data {
        let request = Request(frame: frame, node: node, satellite: satellite, buildings: buildings, style: style)
        lock.lock(); recorded.append(request); let index = recorded.count; lock.unlock()
        return try action?(index, request, token) ?? packet(request)
    }
}
func packet(_ request: Builder.Request) -> Data {
    let x = request.node.x, y = request.node.y
    return MapGeo.encodeChunk(frameId: request.frame.id, cx: x, cy: y, half: 2400,
        feats: [.init(cls: 2, poly: false, pts: [x - 500, y, x + 500, y]),
                .init(cls: 4, poly: false, pts: [x, y - 500, x, y + 500])],
        maxBytes: MapFeeder.MAX_BYTES, maxFeat: MapFeeder.MAX_FEAT)
}
func newCache(_ suffix: String, clock: Clock) -> RouteMapCache {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("motonav-cruise-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    directories.append(directory)
    return RouteMapCache(root: directory, minimumFreeBytes: 0, now: { clock.date })
}
func resetBoundaries() {
    BleLink.shared.reset()
    MapPipelineTrace.reset()
    Settings.shared.theme = MapStylePolicy.gta5
    Settings.shared.mapSource = MapFeeder.SRC_AMAP
    Settings.shared.mapOn = true
    Settings.shared.buildings = false
    UIApplication.shared.applicationState = .active
}
func locate(_ feeder: MapFeeder, frame: MapGeo.Frame, x: Double, y: Double = 0,
            bearing: Double = 90, kmh: Int = 60) {
    feeder.onLocation(lat: frame.lat(y), lng: frame.lng(x), bearing: bearing, kmh: kmh)
}
var directories: [URL] = []
defer { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
let reference = MapGeo.Frame(refLat: 31, refLng: 121, id: 1)
let ble = BleLink.shared

// Keep A genuinely pending in the production BLE queue. A newer map B must replace
// it once the car leaves A, even if no application K ever arrives for A.
do {
    resetBoundaries()
    let clock = Clock(), builder = Builder()
    let cache = newCache("handoff", clock: clock)
    let feeder = MapFeeder(cache: cache, now: { clock.date }, buildPacket: builder.build)
    feeder.onNaviStart()
    defer { feeder.onNaviEnd() }
    locate(feeder, frame: reference, x: 0)
    waitFor("first cruise map queued") { ble.maps.count == 1 }
    let old = ble.maps[0]
    check(!feeder.chunkAcked && feeder.readiness.phase == .transferring,
          "Queueing a map cannot claim round-screen receipt")
    check(ble.writer.next()?.id == old.id, "A real ATT queue slot retains map A")
    clock.advance(1)
    locate(feeder, frame: reference, x: 4000)
    waitFor("covering map B supersedes unacknowledged A") { ble.maps.count >= 2 }
    let replacement = ble.maps.last!
    check(replacement.id != old.id, "Coverage recovery assigns B a new transfer identity")
    check(ble.cancellations > 0, "Moving out of A cancels its pending map fragments")
    check(!feeder.chunkAcked, "B still needs its own application acknowledgement")
    check(ble.writer.complete(success: false) == .obsolete,
          "An old outstanding ATT failure cannot resurrect A after replacement")
    ble.deliverAck(old, to: feeder)
    check(!feeder.chunkAcked && feeder.readiness.coverage == .unconfirmed,
          "A delayed K for A cannot confirm B")
    ble.deliverAck(replacement, to: feeder)
    check(feeder.chunkAcked && feeder.readiness.coverage == .covered,
          "Only B's K confirms coverage at the current cruise position")
    let request = builder.requests.last!
    let cached = cache.lookup(frame: request.frame, source: 3, buildings: false, node: request.node, style: 2)
    check(cached?.data == replacement.bytes, "Cruise stores a validated finished packet at its selected node")
    check(GtaVectorCodec.valid(replacement.bytes, frame: request.frame.id,
        cx: GtaVectorCodec.roundMeters(request.node.x), cy: GtaVectorCodec.roundMeters(request.node.y)),
          "The integration replay transfers a protocol-valid GTA vector packet")
}

// Refresh enters through the real controller while an ordinary navigation route
// is queued. Only map fragments may be cancelled, and no reconnect is necessary.
do {
    resetBoundaries()
    let clock = Clock(), builder = Builder()
    let feeder = MapFeeder(cache: newCache("manual", clock: clock), now: { clock.date }, buildPacket: builder.build)
    feeder.onNaviStart()
    defer { feeder.onNaviEnd() }
    locate(feeder, frame: reference, x: 0)
    waitFor("manual test map") { ble.maps.count == 1 }
    let old = ble.maps[0]
    let route = [(lat: reference.lat(0), lng: reference.lng(0)),
                 (lat: reference.lat(0), lng: reference.lng(5000))]
    check(feeder.onRoute(key: "cruise-refresh-route", coords: route, lights: []),
          "Route is encoded through production MapFeeder")
    waitFor("route queue") { ble.transfers.contains { $0.type == MapFeeder.TYPE_ROUTE } }
    let routeTransfer = ble.transfers.first { $0.type == MapFeeder.TYPE_ROUTE }!
    let before = ble.maps.count, cancellations = ble.cancellations
    feeder.refreshCurrentMap()
    waitFor("manual refresh replacement") { ble.maps.count > before }
    let replacement = ble.maps.last!
    check(ble.isReady && ble.cancellations > cancellations, "Manual refresh resets a pending map without reconnecting")
    check(replacement.id != old.id, "Manual refresh cannot reuse the pending transfer identity")
    check(ble.writer.contains(type: MapFeeder.TYPE_ROUTE, id: routeTransfer.id),
          "Map refresh preserves queued navigation-route fragments")
    check(!ble.writer.contains(type: old.type, id: old.id), "Manual refresh removes obsolete map fragments")
    check(!feeder.currentMapMessage.isEmpty, "Manual refresh supplies a visible result or progress message")
    waitFor("manual refresh acknowledged") {
        if !feeder.chunkAcked, let pending = ble.maps.last { ble.deliverAck(pending, to: feeder) }
        return feeder.chunkAcked
    }
    check(feeder.chunkAcked, "Manual refresh can finish with the existing BLE connection")
}

// A network failure must recover from the heartbeat without another location fix.
do {
    resetBoundaries()
    let clock = Clock(), builder = Builder()
    builder.action = { index, request, _ in
        if index == 1 { throw MapServiceError.timeout }
        return packet(request)
    }
    let feeder = MapFeeder(cache: newCache("retry", clock: clock), now: { clock.date }, buildPacket: builder.build)
    feeder.onNaviStart()
    defer { feeder.onNaviEnd() }
    locate(feeder, frame: reference, x: 0)
    waitFor("network failure published") { feeder.readiness.phase == .retrying }
    check(builder.requests.count == 1 && ble.maps.isEmpty, "Failed preparation queues no partial map")
    clock.advance(2)
    feeder.retryPendingTransfers()
    drain()
    check(builder.requests.count == 1, "Heartbeat does not bypass the failed-request backoff")
    clock.advance(1.1)
    feeder.retryPendingTransfers()
    waitFor("heartbeat retries with fresh retained pose") { ble.maps.count == 1 }
    check(builder.requests.count == 2, "Heartbeat re-evaluates cruise fetch after backoff without another GPS callback")
    check(!feeder.chunkAcked, "Successful retry is still pending round-screen confirmation")
    ble.deliverAck(ble.maps[0], to: feeder)
    check(feeder.chunkAcked, "Recovered fetch and application receipt complete independently")
}

// A stale pose must never create a new download after a long pause.
do {
    resetBoundaries()
    let clock = Clock(), builder = Builder()
    builder.action = { _, _, _ in throw MapServiceError.timeout }
    let feeder = MapFeeder(cache: newCache("stale", clock: clock), now: { clock.date }, buildPacket: builder.build)
    feeder.onNaviStart()
    defer { feeder.onNaviEnd() }
    locate(feeder, frame: reference, x: 0)
    waitFor("stale pose failure") { feeder.readiness.phase == .retrying }
    clock.advance(16)
    feeder.retryPendingTransfers()
    drain()
    check(builder.requests.count == 1 && ble.maps.isEmpty, "A pose older than 15 seconds cannot start a heartbeat download")
    feeder.refreshCurrentMap()
    drain()
    check(builder.requests.count == 1, "Manual refresh also refuses a stale current location")
    check(!feeder.currentMapMessage.isEmpty, "Stale-location refresh gives visible feedback")
}

// A blocked provider result may finish after a newer request starts. A cancelled
// old callback must not replace the current position's packet.
do {
    resetBoundaries()
    let clock = Clock(), builder = Builder()
    let gate = DispatchSemaphore(value: 0)
    builder.action = { index, request, _ in
        if index == 1 {
            precondition(gate.wait(timeout: .now() + 3) == .success, "Blocked provider must be released")
        }
        return packet(request)
    }
    let feeder = MapFeeder(cache: newCache("late-provider", clock: clock), now: { clock.date }, buildPacket: builder.build)
    feeder.onNaviStart()
    defer { feeder.onNaviEnd() }
    locate(feeder, frame: reference, x: 0)
    waitFor("provider A started") { builder.requests.count == 1 }
    clock.advance(1)
    // Still inside A's square, but beyond the area that can fill the viewport.
    locate(feeder, frame: reference, x: 2700)
    gate.signal()
    waitFor("provider B queued") { !ble.maps.isEmpty }
    drain()
    check(ble.maps.count == 1, "Late completion of cancelled map A cannot reach the display queue")
    let request = builder.requests.last!
    check(request.node.x > 3000, "Replacement provider work follows the new cruise position")
    check(ble.maps[0].bytes == packet(request), "Only the new position's packet survives provider cancellation")
}

// Reconstruct both the cache and controller as after an app restart. A provider
// that would fail must never run when the finished current-area packet is on disk.
do {
    resetBoundaries()
    let clock = Clock(), firstBuilder = Builder()
    let cache = newCache("offline-reopen", clock: clock), directory = directories.last!
    let first = MapFeeder(cache: cache, now: { clock.date }, buildPacket: firstBuilder.build)
    first.onNaviStart()
    locate(first, frame: reference, x: 0)
    waitFor("persistent cruise packet") { ble.maps.count == 1 }
    let saved = ble.maps[0]
    ble.deliverAck(saved, to: first)
    first.onNaviEnd()
    ble.reset()
    let offlineBuilder = Builder()
    offlineBuilder.action = { _, _, _ in throw MapServiceError.timeout }
    let reopened = RouteMapCache(root: directory, minimumFreeBytes: 0, now: { clock.date })
    let second = MapFeeder(cache: reopened, now: { clock.date }, buildPacket: offlineBuilder.build)
    second.onNaviStart()
    defer { second.onNaviEnd() }
    locate(second, frame: reference, x: 0)
    waitFor("offline cruise packet replayed") { ble.maps.count == 1 }
    check(offlineBuilder.requests.isEmpty, "A reconstructed cruise controller reuses disk cache before a failing provider")
    check(ble.maps[0].bytes == saved.bytes, "Offline reconstruction replays the exact validated finished packet")
    check(!second.chunkAcked, "Restoring a cached map still requires a new screen acknowledgement")
    ble.deliverAck(ble.maps[0], to: second)
    check(second.chunkAcked && second.readiness.coverage == .covered,
          "Cached roads become confirmed only after the current display receives them")
}

// Memory pressure pauses expensive preparation, not delivery of the retained
// packet. Once a lost receipt expires, the normal heartbeat still retries it.
do {
    resetBoundaries()
    let clock = Clock(), builder = Builder()
    let feeder = MapFeeder(cache: newCache("memory-receipt", clock: clock),
        now: { clock.date }, buildPacket: builder.build)
    feeder.onNaviStart()
    defer { feeder.onNaviEnd() }
    locate(feeder, frame: reference, x: 0)
    waitFor("retained packet before memory pause") { ble.maps.count == 1 }
    let first = ble.maps[0]
    feeder.pauseForMemoryPressure()
    ble.expireMapWithoutAck()
    check(feeder.memoryPaused && !feeder.chunkAcked && !ble.bulkPending,
          "Expired BLE receipt leaves an unconfirmed retained packet during memory pause")
    clock.advance(3)
    feeder.retryPendingTransfers()
    waitFor("memory-paused heartbeat retransmission") { ble.maps.count == 2 }
    let retry = ble.maps[1]
    check(retry.id == first.id && retry.bytes == first.bytes,
          "Heartbeat resends the exact retained identity and bytes despite a preparation pause")
    check(builder.requests.count == 1 && feeder.memoryPaused,
          "Retrying a receipt neither rebuilds the map nor clears the memory pause")
    ble.deliverAck(retry, to: feeder)
    check(feeder.chunkAcked && ble.isReady,
          "A paused controller can confirm a retransmitted map without reconnecting")
}

// Slow delivery expands the preparation horizon. At high speed it can extend
// beyond a current block even while the last pose and desired center stay fixed.
for speed in [180, 200] {
    resetBoundaries()
    let clock = Clock(), builder = Builder()
    let feeder = MapFeeder(cache: newCache("fixed-fast-\(speed)", clock: clock),
        now: { clock.date }, buildPacket: builder.build)
    feeder.onNaviStart()
    defer { feeder.onNaviEnd() }
    locate(feeder, frame: reference, x: 0, kmh: speed)
    waitFor("initial high-speed packet") { ble.maps.count == 1 }
    let first = ble.maps[0], request = builder.requests[0]
    clock.advance(40)
    locate(feeder, frame: reference, x: 0, kmh: speed)
    ble.deliverAck(first, to: feeder)
    check(feeder.chunkAcked, "High-speed baseline is acknowledged before heartbeat replay")
    check(MapCoveragePolicy.needsRefresh(x: 0, y: 0, cx: request.node.x, cy: request.node.y,
        bearing: 90, kmh: speed, preparationSeconds: 60, half: 2400),
          "High-speed replay exercises an early-preparation horizon beyond the unchanged map")
    let builds = builder.requests.count, sends = ble.maps.count
    let fetches = MapPipelineTrace.count("fetch-start")
    for _ in 0..<10 {
        clock.advance(1)
        feeder.retryPendingTransfers()
        drain(for: 0.01)
    }
    check(builder.requests.count == builds && MapPipelineTrace.count("fetch-start") == fetches,
          "A fixed \(speed) km/h pose cannot repeatedly prepare the same cruise center")
    check(ble.maps.count == sends && feeder.chunkAcked,
          "A fixed \(speed) km/h pose cannot retransmit an already confirmed same-center map")
}

print("Cruise map recovery: \(checks) checks passed")
