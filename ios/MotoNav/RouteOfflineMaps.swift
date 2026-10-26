import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class MapWorkToken {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Main owns control state. Disk work and protection changes always run off main.
final class RouteOfflineMaps {
    static let cacheControl = DispatchQueue(label: "motonav.cache.control", qos: .utility)
    typealias PacketBuilder = (MapGeo.Frame, RouteMapPlan.Node, Bool, Bool, Date, MapWorkToken) throws -> Data
    let style: Int
    let frame: MapGeo.Frame, plan: RouteMapPlan, source: Int, buildings: Bool
    let refreshStartedAt = Date()
    private let cache: RouteMapCache
    private let cacheOwner = UUID()
    private let forceRefresh: Bool
    private let buildPacket: PacketBuilder?
    private let worker = DispatchQueue(label: "motonav.route-offline", qos: .utility)
    private let token = MapWorkToken()
    private var jobToken: MapWorkToken?
    private let foregroundBusy: () -> Bool
    private let onReady: (RouteMapPlan.Node) -> Void
    private let onStatus: (String) -> Void
    private let onProgress: (RouteMapPreparation) -> Void
    private var ready: [Bool], baseReady: [Bool], freshBase: [Bool], freshDetails: [Bool]
    private var generated: [Date?]
    private var target = 0, busy = false, storageBlocked = false
    private var retryAt = Date.distantPast
    private var lastError: String?
    private var timer: Timer?

    init(frame: MapGeo.Frame, plan: RouteMapPlan, source: Int, buildings: Bool, style: Int = 1,
         foregroundBusy: @escaping () -> Bool, onReady: @escaping (RouteMapPlan.Node) -> Void,
         onStatus: @escaping (String) -> Void, onProgress: @escaping (RouteMapPreparation) -> Void = { _ in },
         forceRefresh: Bool = false, cache: RouteMapCache = .shared, buildPacket: PacketBuilder? = nil) {
        self.style = MapStylePolicy.normalize(style)
        self.frame = frame; self.plan = plan; self.source = source; self.cache = cache
        self.buildings = MapStylePolicy.usesBuildings(self.style, enabled: buildings)
        self.foregroundBusy = foregroundBusy; self.onReady = onReady; self.onStatus = onStatus
        self.onProgress = onProgress; self.forceRefresh = forceRefresh; self.buildPacket = buildPacket
        ready = [Bool](repeating: false, count: plan.nodes.count); baseReady = ready
        freshBase = ready; freshDetails = ready; generated = [Date?](repeating: nil, count: ready.count)
    }

    /// Worker-only disk lookup.
    func lookup(_ node: RouteMapPlan.Node) -> RouteMapCache.Lookup? {
        let full = cache.lookup(frame: frame, source: source, buildings: buildings, node: node, style: style)
        let simple = buildings ? cache.lookup(frame: frame, source: source, buildings: false, node: node, style: style) : nil
        return Self.displayPacket(full: full, simple: simple)
    }
    private static func displayPacket(full: RouteMapCache.Lookup?, simple: RouteMapCache.Lookup?) -> RouteMapCache.Lookup? {
        if full?.isStale == true, let simple = simple, !simple.isStale { return simple }
        return full ?? simple
    }
    /// Provider/OS caches can run out of storage before the final RouteMapCache store.
    /// Preserve the typed pause even when a URL or SDK error wraps the filesystem error.
    private static func storageFailure(_ error: Error, depth: Int = 0) -> RouteMapCache.CacheError? {
        guard depth < 12 else { return nil }
        if let cache = error as? RouteMapCache.CacheError, cache.isStorageBlocked { return cache }
        let value = error as NSError
        if (value.domain == NSCocoaErrorDomain && value.code == NSFileWriteOutOfSpaceError) ||
           (value.domain == NSPOSIXErrorDomain && value.code == 28) { return .storageFull }
        if let cause = value.userInfo[NSUnderlyingErrorKey] as? Error,
           let result = storageFailure(cause, depth: depth + 1) { return result }
        if let causes = value.userInfo["NSMultipleUnderlyingErrors"] as? [Error] {
            for cause in causes { if let result = storageFailure(cause, depth: depth + 1) { return result } }
        }
        return nil
    }
    func hasDetailed(_ node: RouteMapPlan.Node) -> Bool {
        guard let index = plan.nodes.firstIndex(of: node) else { return false }
        return ready[index]
    }
    func generationDate(_ node: RouteMapPlan.Node) -> Date? {
        guard let index = plan.nodes.firstIndex(of: node) else { return nil }
        return generated[index]
    }
    func update(_ index: Int) { target = max(0, min(plan.nodes.count - 1, index)) }
    func start() {
        busy = true; onStatus("沿线离线地图：检查已有地图包…")
        publish(.checking, detail: "正在核对缓存完整性、生成时间与风格")
        Self.cacheControl.async {
            guard !self.token.isCancelled else { return }
            self.cache.replaceProtection(owner: self.cacheOwner, frame: self.frame, source: self.source,
                nodes: self.plan.nodes, style: self.style, buildings: self.buildings)
            self.worker.async { self.loadExisting() }
        }
    }
    private func loadExisting() {
        var done = ready, base = baseReady, fresh = freshBase, detail = freshDetails, dates = generated
        for (i, node) in plan.nodes.enumerated() {
            if token.isCancelled { return }
            let full = cache.lookup(frame: frame, source: source, buildings: buildings, node: node, style: style)
            let simple = buildings ? cache.lookup(frame: frame, source: source, buildings: false, node: node, style: style) : full
            done[i] = full != nil; base[i] = full != nil || simple != nil
            fresh[i] = !forceRefresh && ((full?.isStale == false) || (simple?.isStale == false))
            detail[i] = !forceRefresh && full?.isStale == false
            dates[i] = Self.displayPacket(full: full, simple: simple)?.generatedAt
        }
        DispatchQueue.main.async {
            guard !self.token.isCancelled else { return }
            self.ready = done; self.baseReady = base; self.freshBase = fresh; self.freshDetails = detail
            self.generated = dates; self.busy = false
            self.startTimer(); self.onReady(self.plan.nodes[self.target]); self.pump()
        }
    }
    private func startTimer() {
        guard timer == nil, !token.isCancelled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pump() }
    }
    func resumeAfterStorageChange() {
        guard !token.isCancelled else { return }
        storageBlocked = false; lastError = nil; retryAt = .distantPast
        startTimer(); pump()
    }
    private func publish(_ phase: RouteMapPreparation.Phase, detail: String) {
        onProgress(RouteMapPreparation(phase: phase, ready: baseReady.filter { $0 }.count,
            total: ready.count, detailedReady: ready.filter { $0 }.count,
            retryAt: phase == .retrying ? retryAt : nil, error: lastError, detail: detail,
            freshReady: freshBase.filter { $0 }.count, oldestGeneratedAt: generated.compactMap { $0 }.min()))
    }
    private func pump() {
        if busy, foregroundBusy() { jobToken?.cancel() }
        guard !token.isCancelled, !busy, !storageBlocked else { return }
        let baseCount = baseReady.filter { $0 }.count
        if freshDetails.allSatisfy({ $0 }) {
            lastError = nil; onStatus("沿线地图已准备完成：\(ready.count)/\(ready.count) 块")
            publish(.complete, detail: "当前风格的沿线地图已保存并在有效期内")
            timer?.invalidate(); timer = nil; return
        }
        guard UIApplication.shared.applicationState == .active else {
            onStatus("沿线地图：\(baseCount)/\(ready.count) 块可用；回到前台继续更新")
            publish(.paused, detail: "回到 App 前台继续准备；已保存地图可继续使用"); return
        }
        guard !foregroundBusy() else {
            publish(.paused, detail: "优先准备圆屏当前地图，完成后自动继续沿线准备"); return
        }
        guard Date() >= retryAt else {
            publish(.retrying, detail: "保留已有地图，稍后自动重试更新"); return
        }
        let indexes = Array(target..<ready.count) + Array(0..<target)
        guard let i = indexes.first(where: { !baseReady[$0] })
            ?? indexes.first(where: { !freshBase[$0] })
            ?? indexes.first(where: { !freshDetails[$0] }) else { return }
        busy = true
        let node = plan.nodes[i], includeBuildings = buildings && freshBase.allSatisfy({ $0 })
        let refresh = forceRefresh || baseReady[i] && !freshBase[i]
        lastError = nil
        publish(.preparing, detail: "正在\(baseReady[i] ? "更新" : "准备")第 \(i + 1) 块\(includeBuildings ? "建筑细节" : "地图")")
        onStatus("沿线地图：\(baseCount)/\(ready.count) 块可用，正在处理第 \(i + 1) 块")
        let job = MapWorkToken(); jobToken = job
        worker.async {
            let result = Result { () throws -> (packet: Data, generated: Date?) in
                if self.token.isCancelled || job.isCancelled { throw MapProcessingError.cancelled }
                let packet: Data
                if let builder = self.buildPacket {
                    packet = try builder(self.frame, node, includeBuildings, refresh, self.refreshStartedAt, job)
                } else if self.style == MapStylePolicy.gta5 {
                    packet = try GtaVectorMaps.build(self.frame, cx: node.x, cy: node.y,
                        shouldCancel: { self.token.isCancelled || job.isCancelled },
                        forceRefresh: refresh, refreshAfter: self.refreshStartedAt).bytes
                } else if self.source == MapFeeder.SRC_AMAP {
                    packet = try AmapSdkRaster.build(self.frame, cx: node.x, cy: node.y, includeBuildings: includeBuildings,
                        shouldCancel: { self.token.isCancelled || job.isCancelled }, onBaseReady: { base in
                            guard !self.token.isCancelled, !job.isCancelled else { return }
                            do {
                                try self.cache.store(base, frame: self.frame, source: self.source, node: node, style: self.style)
                                let generated = self.lookup(node)?.generatedAt
                                DispatchQueue.main.async {
                                    guard !self.token.isCancelled else { return }
                                    self.baseReady[i] = true; self.freshBase[i] = true; self.generated[i] = generated
                                    self.onReady(node); self.publish(.preparing, detail: "底图已保存，继续准备细节")
                                }
                            } catch { /* The final store reports a permanent storage pause. */ }
                        }, onBuildingStatus: { message in
                            DispatchQueue.main.async { if !self.token.isCancelled { self.onStatus(message) } }
                        }, style: self.style).bytes
                } else { throw MapProcessingError.invalid("沿线预下载仅支持高德底图") }
                if self.token.isCancelled || job.isCancelled { throw MapProcessingError.cancelled }
                try self.cache.store(packet, frame: self.frame, source: self.source, node: node, style: self.style)
                return (packet, self.lookup(node)?.generatedAt)
            }
            DispatchQueue.main.async {
                guard !self.token.isCancelled else { return }
                self.busy = false
                switch result {
                case .success(let result):
                    let packet = result.packet
                    self.baseReady[i] = true; self.freshBase[i] = true; self.generated[i] = result.generated
                    let complete = !self.buildings || RasterPacket.isBuilding(packet)
                    self.ready[i] = self.ready[i] || complete; self.freshDetails[i] = complete
                    self.retryAt = complete || !includeBuildings ? .distantPast : Date().addingTimeInterval(15)
                    self.onReady(node)
                    self.publish(complete && self.freshDetails.allSatisfy({ $0 }) ? .complete : .preparing,
                        detail: complete ? "地图已更新，继续准备其余沿线地图" : "底图已保存，稍后补齐建筑细节")
                case .failure where job.isCancelled:
                    self.retryAt = .distantPast
                    self.publish(.paused, detail: "优先保障圆屏当前地图，沿线准备稍后继续")
                case .failure(let error):
                    let storage = Self.storageFailure(error)
                    self.lastError = storage?.localizedDescription ?? error.localizedDescription
                    if let storage = storage {
                        self.storageBlocked = true; self.timer?.invalidate(); self.timer = nil
                        self.onStatus("沿线准备暂停：\(storage.localizedDescription)")
                        self.publish(.storageBlocked, detail: "保留已有地图；清理空间后点击继续准备，不再反复下载")
                    } else {
                        self.retryAt = Date().addingTimeInterval(15)
                        self.onStatus("更新失败，保留已有地图：\(error.localizedDescription)")
                        self.publish(.retrying, detail: "已有地图仍可使用，15 秒后自动重试")
                    }
                }
            }
        }
    }
    func close() {
        token.cancel(); jobToken?.cancel(); timer?.invalidate(); timer = nil
        Self.cacheControl.async { self.cache.clearProtection(owner: self.cacheOwner) }
    }
}
