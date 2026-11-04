import Foundation

// The map controller, geometry, disk cache and BLE queue stay in production code.
// These boundaries replace iOS services and unrelated along-route prefetch work.
final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    static let didReceiveMemoryWarningNotification = Notification.Name("test.memory-warning")
    var applicationState = State.active
}

final class Settings {
    static let shared = Settings()
    var theme = MapStylePolicy.gta5
    var mapSource = MapFeeder.SRC_AMAP
    var mapOn = true
    var buildings = false
}

final class BleLink {
    struct Transfer {
        let type: Int, id: Int
        let bytes: Data
    }
    static let shared = BleLink()
    var isReady = true
    var buildingsSupported = false
    var rasterCompressionSupported = false
    var mapBytesPerSecond: Double? = 10_000
    private(set) var transfers: [Transfer] = []
    private(set) var commands: [String] = []
    private(set) var cancellations = 0
    var writer = BleBulkWriteQueue()
    private var receipt: BleMapReceipt.Identity?
    var bulkPending: Bool { writer.hasData || receipt != nil }
    var maps: [Transfer] { transfers.filter { $0.type == 1 || $0.type == 3 } }

    func send(_ message: String) { commands.append(message) }
    func sendBulk(type: Int, id: Int, data: Data) {
        guard isReady else { return }
        if (type == 1 || type == 3) && bulkPending(type: type, id: id) { return }
        transfers.append(.init(type: type, id: id, bytes: data))
        var packet = Data(repeating: 0, count: 15)
        packet[0] = 77; packet[1] = UInt8(type); packet[2] = UInt8(id)
        packet[3] = 1
        packet.append(data)
        writer.replace(type: type, id: id, packets: [packet], prioritize: type == 2)
        if type == 1 || type == 3 { receipt = .init(type: type, id: id) }
    }
    func cancelMapBulk() {
        cancellations += 1
        writer.cancel(types: [1, 3])
        receipt = nil
    }
    func bulkPending(type: Int, id: Int) -> Bool {
        writer.contains(type: type, id: id) || receipt == .init(type: type, id: id)
    }
    func mapPayloadRemaining(type: Int, id: Int) -> Int {
        writer.payloadRemaining(type: type, id: id)
    }
    func mapTailWasIssued(type: Int, id: Int) -> Bool { false }
    func deliverAck(_ transfer: Transfer, to feeder: MapFeeder) {
        writer.acknowledge(type: transfer.type, id: transfer.id)
        if receipt == .init(type: transfer.type, id: transfer.id) { receipt = nil }
        feeder.onAck(type: transfer.type, id: transfer.id)
    }
    func expireMapWithoutAck() {
        if writer.inFlight != nil { _ = writer.complete(success: true) }
        while writer.canStart {
            _ = writer.next()
            _ = writer.complete(success: true)
        }
        receipt = nil
    }
    func reset() {
        isReady = true; buildingsSupported = false; rasterCompressionSupported = false
        mapBytesPerSecond = 10_000
        transfers.removeAll(); commands.removeAll(); cancellations = 0
        writer.reset(); receipt = nil
    }
}

final class AmapCaptureHost {
    static let shared = AmapCaptureHost()
    func pauseForMemoryPressure() {}
}

enum AmapSdkRaster {
    struct Packet { let bytes: Data }
    static func build(_ frame: MapGeo.Frame, cx: Double, cy: Double, includeBuildings: Bool,
                      shouldCancel: () -> Bool, satellite: Bool = false,
                      onBaseReady: (Data) -> Void = { _ in },
                      onBuildingStatus: (String) -> Void = { _ in }, style: Int) throws -> Packet {
        preconditionFailure("Cruise replay must use the injected builder")
    }
}

final class PrefetchConditions {
    var onChange: (() -> Void)?
    var unmeteredWifi = true
    var charging = true
    func setEnabled(_ enabled: Bool) {}
}

final class MapWorkToken {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class RouteOfflineMaps {
    static let cacheControl = DispatchQueue(label: "test.route-cache")
    let plan: RouteMapPlan
    var serviceRetryAt: Date? { nil }
    var isMemoryPaused: Bool { false }
    var isConfigurationBlocked: Bool { false }
    init(frame: MapGeo.Frame, plan: RouteMapPlan, source: Int, buildings: Bool, style: Int,
         foregroundBusy: @escaping () -> Bool, onReady: @escaping (RouteMapPlan.Node) -> Void,
         onStatus: @escaping (String) -> Void, onProgress: @escaping (RouteMapPreparation) -> Void,
         onCoverage: @escaping (RouteCoverage.Result) -> Void,
         prefetchDecision: @escaping () -> PrefetchPolicy.Decision,
         forceRefresh: Bool, rangeKm: Int, refreshStartedAt: Date) {
        self.plan = plan
    }
    func lookup(_ node: RouteMapPlan.Node) -> RouteMapCache.Lookup? { nil }
    func generationDate(_ node: RouteMapPlan.Node) -> Date? { nil }
    func hasDetailed(_ node: RouteMapPlan.Node) -> Bool { false }
    func noteCachedPacket(_ node: RouteMapPlan.Node) {}
    func updateProgress(_ distance: Double) {}
    func update(_ index: Int) {}
    func setRangeKm(_ value: Int) {}
    func reevaluatePrefetchPolicy() {}
    func resumeAfterStorageChange() {}
    func pauseForMemoryPressure() {}
    func retryFailed() {}
    func start() {}
    func close() {}
}

struct PreparationRecoveryCheckpoint {
    struct Point { let lat: Double, lng: Double }
    var savedAt: Date
    let key: String
    let points: [Point]
    let frameLat: Double, frameLng: Double, frameID: Int
    let source: Int, style: Int
    let buildings: Bool, buildingPreference: Bool
    var rangeKm: Int
    var forceRefresh: Bool
    var refreshStartedAt: Date
    func isValid(at now: Date) -> Bool { true }
    func matches(source: Int, style: Int, buildingPreference: Bool) -> Bool {
        self.source == source && self.style == style && self.buildingPreference == buildingPreference
    }
}

final class PreparationRecoveryStore {
    enum SaveState { case idle }
    func observeSaveState(_ callback: (SaveState) -> Void) { callback(.idle) }
    func loadAsync(_ callback: (PreparationRecoveryCheckpoint?) -> Void) { callback(nil) }
    func begin(_ checkpoint: PreparationRecoveryCheckpoint) -> UUID { UUID() }
    @discardableResult func update(_ checkpoint: PreparationRecoveryCheckpoint, owner: UUID) -> Bool { true }
    func clear(owner: UUID? = nil) {}
}

enum MapPipelineTrace {
    private static let lock = NSLock()
    private static var events: [String] = []
    static func event(_ name: String, _ fields: [String: Any] = [:]) {
        lock.lock(); events.append(name); lock.unlock()
    }
    static func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return events.filter { $0 == name }.count
    }
    static func reset() { lock.lock(); events.removeAll(); lock.unlock() }
    static func packet(_ data: Data, type: Int, id: Int, ready: Bool) {}
}
