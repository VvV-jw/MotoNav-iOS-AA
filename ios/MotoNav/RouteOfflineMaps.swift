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
    let refreshStartedAt: Date
    private let cache: RouteMapCache
    private let cacheOwner = UUID()
    private let forceRefresh: Bool
    private let buildPacket: PacketBuilder?
    private let worker = DispatchQueue(label: "motonav.route-offline", qos: .utility)
    private let token = MapWorkToken()
    private var windowToken = MapWorkToken()
    private var jobToken: MapWorkToken?
    private let now: () -> Date
    private let distances: [Double]
    private let foregroundBusy: () -> Bool
    private let onReady: (RouteMapPlan.Node) -> Void
    private let onStatus: (String) -> Void
    private let onProgress: (RouteMapPreparation) -> Void
    private let onCoverage: (RouteCoverage.Result) -> Void
    private let prefetchDecision: () -> PrefetchPolicy.Decision
    private let coverageWorker = DispatchQueue(label: "motonav.route-coverage", qos: .utility)
    private var coverageToken = MapWorkToken()
    private var coverageRouteXY: [Double]? // coverageWorker only
    private var coverageProgress = 0.0, coverageRevision = 0
    private var coverageScanning = true, coverageSignature = ""
    private var cacheNotificationRevisions: [Int: Int] = [:]
    private var pendingCacheNotifications = Set<Int>()
    private var cacheNotificationInFlight = false
    private var ready: [Bool], baseReady: [Bool], freshBase: [Bool], freshDetails: [Bool]
    private var generated: [Date?]
    private var target = 0, busy = false, storageBlocked = false, started = false
    private var memoryBlocked = false, configurationBlocked = false
    private var serviceCooldownUntil: Date?
    private var rangeKm: Int
    private var window: OfflinePreparationPolicy.Window
    private var backoff = OfflinePreparationPolicy.Backoff()
    private var failureMessages: [Int: String] = [:]
    private var failureCategories: [Int: MapFailurePolicy.Category] = [:]
    private var retryAt: Date?
    private var lastError: String?
    private var timer: Timer?
    private var completed = false
    var isMemoryPaused: Bool { memoryBlocked }
    var isConfigurationBlocked: Bool { configurationBlocked }
    var serviceRetryAt: Date? { serviceCooldownUntil.flatMap { $0 > now() ? $0 : nil } }

    init(frame: MapGeo.Frame, plan: RouteMapPlan, source: Int, buildings: Bool, style: Int = 1,
         foregroundBusy: @escaping () -> Bool, onReady: @escaping (RouteMapPlan.Node) -> Void,
         onStatus: @escaping (String) -> Void, onProgress: @escaping (RouteMapPreparation) -> Void = { _ in },
         onCoverage: @escaping (RouteCoverage.Result) -> Void = { _ in },
         prefetchDecision: @escaping () -> PrefetchPolicy.Decision = { .allow },
         forceRefresh: Bool = false, cache: RouteMapCache = .shared, buildPacket: PacketBuilder? = nil,
         rangeKm: Int = 0, now: @escaping () -> Date = Date.init, refreshStartedAt: Date? = nil) {
        self.style = MapStylePolicy.normalize(style)
        self.frame = frame; self.plan = plan; self.source = source; self.cache = cache
        self.buildings = MapStylePolicy.usesBuildings(self.style, enabled: buildings)
        self.foregroundBusy = foregroundBusy; self.onReady = onReady; self.onStatus = onStatus
        self.onProgress = onProgress; self.forceRefresh = forceRefresh; self.buildPacket = buildPacket
        self.onCoverage = onCoverage; self.prefetchDecision = prefetchDecision
        self.now = now; self.refreshStartedAt = refreshStartedAt ?? now()
        let nodeDistances = plan.nodes.map(\.distance)
        distances = nodeDistances
        self.rangeKm = OfflinePreparationPolicy.normalizedRangeKm(rangeKm)
        window = OfflinePreparationPolicy.window(distances: nodeDistances, target: 0, rangeKm: rangeKm)
        ready = [Bool](repeating: false, count: plan.nodes.count); baseReady = ready
        freshBase = ready; freshDetails = ready; generated = [Date?](repeating: nil, count: ready.count)
    }

    /// Worker-only disk lookup.
    func lookup(_ node: RouteMapPlan.Node) -> RouteMapCache.Lookup? {
        let full = cache.lookup(frame: frame, source: source, buildings: buildings, node: node, style: style)
        let simple = buildings ? cache.lookup(frame: frame, source: source, buildings: false, node: node, style: style) : nil
        return displayPacket(full: full, simple: simple)
    }
    private func isFreshForPreparation(_ packet: RouteMapCache.Lookup?) -> Bool {
        guard let packet = packet, !packet.isStale else { return false }
        return !forceRefresh || packet.generatedAt >= refreshStartedAt
    }
    private func displayPacket(full: RouteMapCache.Lookup?, simple: RouteMapCache.Lookup?) -> RouteMapCache.Lookup? {
        if !isFreshForPreparation(full), isFreshForPreparation(simple), let simple = simple { return simple }
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
    /// Main-only notification after a foreground cache store succeeds. Re-read actual stored packets
    /// on the existing worker; never infer completeness from a provider's earlier base callback.
    func noteCachedPacket(_ node: RouteMapPlan.Node) {
        guard !token.isCancelled, let index = plan.nodes.firstIndex(of: node) else { return }
        cacheNotificationRevisions[index, default: 0] += 1
        pendingCacheNotifications.insert(index)
        drainCacheNotifications()
    }
    private struct CachedInspection {
        let index: Int, revision: Int
        let ready: Bool, base: Bool, fresh: Bool, detailed: Bool
        let generated: Date?
    }
    private func drainCacheNotifications() {
        guard started, !token.isCancelled, !memoryBlocked, !cacheNotificationInFlight,
              !pendingCacheNotifications.isEmpty else { return }
        let revisions = pendingCacheNotifications.map { ($0, cacheNotificationRevisions[$0] ?? 0) }
        pendingCacheNotifications.removeAll(); cacheNotificationInFlight = true
        worker.async {
            var inspections: [CachedInspection] = []
            for (index, revision) in revisions {
                if self.token.isCancelled { return }
                let node = self.plan.nodes[index]
                let full = self.cache.lookup(frame: self.frame, source: self.source, buildings: self.buildings,
                    node: node, style: self.style)
                let simple = self.buildings ? self.cache.lookup(frame: self.frame, source: self.source,
                    buildings: false, node: node, style: self.style) : full
                inspections.append(CachedInspection(index: index, revision: revision,
                    ready: full != nil, base: full != nil || simple != nil,
                    fresh: self.isFreshForPreparation(full) || self.isFreshForPreparation(simple),
                    detailed: self.isFreshForPreparation(full),
                    generated: self.displayPacket(full: full, simple: simple)?.generatedAt))
            }
            DispatchQueue.main.async {
                guard !self.token.isCancelled else { return }
                self.cacheNotificationInFlight = false
                var changed = false
                for item in inspections {
                    // A final packet may have arrived while this lookup still read its old base.
                    // Its newer notification stays pending and must be inspected before publishing.
                    guard self.cacheNotificationRevisions[item.index] == item.revision else { continue }
                    self.ready[item.index] = item.ready; self.baseReady[item.index] = item.base
                    self.freshBase[item.index] = item.fresh; self.freshDetails[item.index] = item.detailed
                    self.generated[item.index] = item.generated
                    if item.detailed {
                        self.backoff.succeed(item.index); self.failureMessages.removeValue(forKey: item.index)
                        self.failureCategories.removeValue(forKey: item.index)
                    }
                    changed = true
                }
                self.drainCacheNotifications()
                if changed {
                    self.coverageRevision += 1; self.scheduleCoverage(); self.completed = false
                    if self.memoryBlocked || self.configurationBlocked || self.storageBlocked { self.publishBlocked() }
                    else { self.startTimer(); self.pump() }
                }
            }
        }
    }
    /// Actual along-route progress, separate from the 800 m download lookahead target.
    func updateProgress(_ distance: Double) {
        guard distance.isFinite, !token.isCancelled else { return }
        coverageProgress = min(plan.length, max(0, distance))
        if started { scheduleCoverage() }
    }
    func reevaluatePrefetchPolicy() {
        guard started, !token.isCancelled else { return }
        if prefetchDecision() != .allow { jobToken?.cancel() }
        startTimer(); pump()
    }
    /// Coalesce immutable snapshots. Reading the card or its countdown never performs geometry.
    private func scheduleCoverage() {
        let signature = "\(coverageRevision)|\(window.lower)|\(window.upper)|\(Int(coverageProgress / 25))|\(coverageScanning)"
        guard signature != coverageSignature, !token.isCancelled else { return }
        coverageSignature = signature
        coverageToken.cancel(); let work = MapWorkToken(); coverageToken = work
        let progress = coverageProgress, snapshot = baseReady, current = window
        if coverageScanning { onCoverage(RouteCoverage.scanning(totalMeters: plan.length, progressMeters: progress)); return }
        coverageWorker.async {
            guard !self.token.isCancelled, !work.isCancelled else { return }
            if self.coverageRouteXY == nil { self.coverageRouteXY = self.plan.points.flatMap { [$0.x, $0.y] } }
            var centers: [Double] = []
            for index in current.indexes where snapshot[index] {
                if self.token.isCancelled || work.isCancelled { return }
                centers.append(self.plan.nodes[index].x); centers.append(self.plan.nodes[index].y)
            }
            let result = RouteCoverage.evaluate(routeXY: self.coverageRouteXY ?? [], readyCentersXY: centers,
                half: MapStylePolicy.half(self.style), progressMeters: progress,
                inspectedStartMeters: self.plan.nodes[current.lower].distance,
                inspectedEndMeters: self.plan.nodes[current.upper].distance,
                shouldCancel: { self.token.isCancelled || work.isCancelled })
            DispatchQueue.main.async {
                guard !self.token.isCancelled, !work.isCancelled else { return }
                self.onCoverage(result)
            }
        }
    }
    /// Before start this only selects the initial window; no disk or provider work is scheduled.
    func update(_ index: Int) {
        target = max(0, min(plan.nodes.count - 1, index))
        let next = OfflinePreparationPolicy.window(distances: distances, target: target, rangeKm: rangeKm)
        let changed = !window.hasSameCoverage(as: next)
        window = next
        guard started, !token.isCancelled else { return }
        if changed { loadWindow() } else if !completed { startTimer(); pump() }
    }
    func setRangeKm(_ value: Int) {
        let value = OfflinePreparationPolicy.normalizedRangeKm(value)
        guard rangeKm != value else { return }
        rangeKm = value
        window = OfflinePreparationPolicy.window(distances: distances, target: target, rangeKm: value)
        guard started, !token.isCancelled else { return }
        loadWindow()
    }
    /// Retry a failed block without invalidating successful/fresh maps or bypassing a storage pause.
    func retryFailed() {
        guard started, !token.isCancelled, !storageBlocked, !memoryBlocked, !configurationBlocked,
              serviceRetryAt == nil else { return }
        backoff.retry(window.indexes)
        for index in window.indexes { failureMessages.removeValue(forKey: index); failureCategories.removeValue(forKey: index) }
        retryAt = nil; lastError = nil
        startTimer(); pump()
    }
    func start() {
        guard !started, !token.isCancelled else { return }
        started = true; loadWindow(); drainCacheNotifications()
    }
    private func loadWindow() {
        windowToken.cancel(); jobToken?.cancel()
        let work = MapWorkToken(); windowToken = work
        coverageScanning = true; coverageRevision += 1; scheduleCoverage()
        let inspect = !memoryBlocked && !configurationBlocked
        busy = inspect; retryAt = nil; completed = false
        timer?.invalidate(); timer = nil
        let indexes = window.indexes
        let nodes = indexes.map { plan.nodes[$0] }
        let previousReady = ready, previousBase = baseReady, previousFresh = freshBase
        let previousDetails = freshDetails, previousDates = generated
        if inspect {
            onStatus("沿线离线地图：检查当前准备范围的地图包…")
            publish(.checking, detail: "正在核对当前准备范围的缓存完整性、生成时间与风格")
        } else { publishBlocked() }
        Self.cacheControl.async {
            guard !self.token.isCancelled, !work.isCancelled else { return }
            self.cache.replaceProtection(owner: self.cacheOwner, frame: self.frame, source: self.source,
                nodes: nodes, style: self.style, buildings: self.buildings)
            guard inspect else { return }
            self.worker.async {
                self.loadExisting(indexes: indexes, work: work, previousReady: previousReady,
                    previousBase: previousBase, previousFresh: previousFresh, previousDetails: previousDetails,
                    previousDates: previousDates)
            }
        }
    }
    private func loadExisting(indexes: [Int], work: MapWorkToken, previousReady: [Bool], previousBase: [Bool],
                              previousFresh: [Bool], previousDetails: [Bool], previousDates: [Date?]) {
        var done = previousReady, base = previousBase, fresh = previousFresh, detail = previousDetails, dates = previousDates
        for i in indexes {
            if token.isCancelled || work.isCancelled { return }
            let node = plan.nodes[i]
            let full = cache.lookup(frame: frame, source: source, buildings: buildings, node: node, style: style)
            let simple = buildings ? cache.lookup(frame: frame, source: source, buildings: false, node: node, style: style) : full
            done[i] = full != nil; base[i] = full != nil || simple != nil
            // A valid seven-day packet may still precede this explicit refresh.
            fresh[i] = isFreshForPreparation(full) || isFreshForPreparation(simple)
            detail[i] = isFreshForPreparation(full)
            dates[i] = displayPacket(full: full, simple: simple)?.generatedAt
        }
        DispatchQueue.main.async {
            guard !self.token.isCancelled, !work.isCancelled else { return }
            self.ready = done; self.baseReady = base; self.freshBase = fresh; self.freshDetails = detail
            self.generated = dates; self.busy = false
            self.coverageScanning = false; self.coverageRevision += 1; self.scheduleCoverage()
            for index in indexes where detail[index] {
                self.backoff.succeed(index)
                self.failureMessages.removeValue(forKey: index); self.failureCategories.removeValue(forKey: index)
            }
            self.onReady(self.plan.nodes[self.target])
            if self.storageBlocked {
                self.publish(.storageBlocked, detail: "当前准备范围已切换；清理存储空间后点击继续准备")
            } else { self.startTimer(); self.pump() }
        }
    }
    private func startTimer() {
        guard timer == nil, started, !token.isCancelled, !storageBlocked, !memoryBlocked, !configurationBlocked else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pump() }
    }
    func resumeAfterStorageChange() {
        guard !token.isCancelled else { return }
        let recheck = memoryBlocked || configurationBlocked || windowToken.isCancelled
        memoryBlocked = false; configurationBlocked = false
        storageBlocked = false; lastError = nil; retryAt = nil
        if recheck, started { loadWindow() } else { startTimer(); pump() }
        drainCacheNotifications()
    }
    /// Handles the OS memory-warning signal. Swift cannot catch or recover an actual process OOM.
    /// Invalidate the window as well as the provider job so late callbacks cannot lift this pause.
    func pauseForMemoryPressure() {
        guard !token.isCancelled else { return }
        memoryBlocked = true; completed = false
        lastError = MapServiceError.memoryPressure.localizedDescription
        pauseCurrentWork()
        if started { publishBlocked() }
    }
    private func pauseCurrentWork() {
        windowToken.cancel(); jobToken?.cancel(); jobToken = nil; busy = false
        timer?.invalidate(); timer = nil
    }
    private func publishBlocked() {
        if memoryBlocked {
            publish(.memoryBlocked, detail: "保留已有地图；关闭占用内存的应用后点击继续准备")
        } else if configurationBlocked {
            publish(.configurationBlocked, detail: "已停止后台重试；修正地图 Key 或服务权限后点击继续准备")
        } else if storageBlocked {
            publish(.storageBlocked, detail: "保留已有地图；清理存储空间后点击继续准备")
        }
    }
    private func publish(_ phase: RouteMapPreparation.Phase, detail: String) {
        let indexes = window.indexes
        let blocked = storageBlocked || memoryBlocked || configurationBlocked || phase == .rateLimited
        let error = blocked ? lastError : indexes.compactMap { failureMessages[$0] }.first
        let category: String? = memoryBlocked ? MapFailurePolicy.Category.memory.rawValue :
            (configurationBlocked ? MapFailurePolicy.Category.configuration.rawValue :
            (storageBlocked ? MapFailurePolicy.Category.storage.rawValue :
            (phase == .rateLimited ? MapFailurePolicy.Category.rateLimited.rawValue : indexes.compactMap { failureCategories[$0]?.rawValue }.first)))
        onProgress(RouteMapPreparation(phase: phase, ready: indexes.filter { baseReady[$0] }.count,
            total: indexes.count, detailedReady: indexes.filter { ready[$0] }.count,
            retryAt: phase == .rateLimited ? serviceRetryAt : (phase == .retrying ? retryAt : nil), error: error, detail: detail,
            freshReady: indexes.filter { freshBase[$0] }.count, oldestGeneratedAt: indexes.compactMap { generated[$0] }.min(),
            rangeKm: rangeKm, routeTotal: ready.count, failedCount: backoff.failedCount(in: indexes), failureCategory: category))
    }
    private func pump() {
        if busy, foregroundBusy() || prefetchDecision() != .allow { jobToken?.cancel() }
        guard started, !token.isCancelled, !busy, !storageBlocked, !memoryBlocked, !configurationBlocked,
              !cacheNotificationInFlight, pendingCacheNotifications.isEmpty else { return }
        let indexes = window.indexes, baseCount = window.indexes.filter { baseReady[$0] }.count
        if indexes.allSatisfy({ freshDetails[$0] }) {
            lastError = nil; retryAt = nil; completed = true
            onStatus("当前准备范围地图已完成：\(indexes.count)/\(indexes.count) 块")
            publish(.complete, detail: rangeKm == 0 ? "全程当前风格的沿线地图已保存并在有效期内" : "当前位置前方 \(rangeKm) 公里范围已保存；前进后自动继续准备")
            timer?.invalidate(); timer = nil; return
        }
        if serviceRetryAt != nil {
            publish(.rateLimited, detail: "所有沿线取图等待同一服务冷却；已有离线地图仍可使用")
            return
        }
        serviceCooldownUntil = nil
        guard UIApplication.shared.applicationState == .active else {
            onStatus("当前范围地图：\(baseCount)/\(indexes.count) 块可用；回到前台继续更新")
            publish(.paused, detail: "回到 App 前台继续准备；已保存地图可继续使用"); return
        }
        guard !foregroundBusy() else {
            publish(.paused, detail: "优先准备圆屏当前地图，完成后自动继续沿线准备"); return
        }
        let policy = prefetchDecision()
        guard policy == .allow else {
            publish(.policyPaused, detail: PrefetchPolicy.detail(policy) + "；当前屏地图和导航照常工作"); return
        }
        let selection = OfflinePreparationPolicy.select(window: window, baseReady: baseReady,
            freshBase: freshBase, freshDetails: freshDetails, buildings: buildings, backoff: backoff, at: now())
        retryAt = selection.retryAt
        guard let selected = selection.work else {
            if retryAt != nil { publish(.retrying, detail: "当前范围待更新块均在等待重试；已有地图仍可使用") }
            return
        }
        let i = selected.index
        busy = true
        let node = plan.nodes[i], includeBuildings = selected.includeBuildings
        let refresh = forceRefresh || baseReady[i] && !freshBase[i]
        publish(.preparing, detail: "正在\(baseReady[i] ? "更新" : "准备")第 \(i + 1) 块\(includeBuildings ? "建筑细节" : "地图")")
        onStatus("当前范围地图：\(baseCount)/\(indexes.count) 块可用，正在处理全程第 \(i + 1) 块")
        let job = MapWorkToken(); jobToken = job
        let currentWindow = windowToken
        worker.async {
            let result = Result { () throws -> (packet: Data, generated: Date?) in
                if self.token.isCancelled || currentWindow.isCancelled || job.isCancelled { throw MapProcessingError.cancelled }
                let allowed = DispatchQueue.main.sync { self.prefetchDecision() == .allow && !self.foregroundBusy() }
                if !allowed || self.token.isCancelled || currentWindow.isCancelled || job.isCancelled { throw MapProcessingError.cancelled }
                let packet: Data
                if let builder = self.buildPacket {
                    packet = try builder(self.frame, node, includeBuildings, refresh, self.refreshStartedAt, job)
                } else if self.style == MapStylePolicy.gta5 {
                    packet = try GtaVectorMaps.build(self.frame, cx: node.x, cy: node.y,
                        shouldCancel: { self.token.isCancelled || currentWindow.isCancelled || job.isCancelled },
                        forceRefresh: refresh, refreshAfter: self.refreshStartedAt).bytes
                } else if self.source == MapFeeder.SRC_AMAP {
                    packet = try AmapSdkRaster.build(self.frame, cx: node.x, cy: node.y, includeBuildings: includeBuildings,
                        shouldCancel: { self.token.isCancelled || currentWindow.isCancelled || job.isCancelled }, onBaseReady: { base in
                            guard !self.token.isCancelled, !currentWindow.isCancelled, !job.isCancelled else { return }
                            do {
                                try self.cache.store(base, frame: self.frame, source: self.source, node: node, style: self.style)
                                let generated = self.lookup(node)?.generatedAt
                                DispatchQueue.main.async {
                                    guard !self.token.isCancelled, !currentWindow.isCancelled, !job.isCancelled else { return }
                                    self.baseReady[i] = true; self.freshBase[i] = true; self.generated[i] = generated
                                    self.coverageRevision += 1; self.scheduleCoverage()
                                    self.onReady(node); self.publish(.preparing, detail: "底图已保存，继续准备细节")
                                }
                            } catch { /* The final store reports a permanent storage pause. */ }
                        }, onBuildingStatus: { message in
                            DispatchQueue.main.async {
                                if !self.token.isCancelled, !currentWindow.isCancelled, !job.isCancelled { self.onStatus(message) }
                            }
                        }, style: self.style).bytes
                } else { throw MapProcessingError.invalid("沿线预下载仅支持高德底图") }
                if self.token.isCancelled || currentWindow.isCancelled || job.isCancelled { throw MapProcessingError.cancelled }
                try self.cache.store(packet, frame: self.frame, source: self.source, node: node, style: self.style)
                return (packet, self.lookup(node)?.generatedAt)
            }
            DispatchQueue.main.async {
                guard !self.token.isCancelled, !currentWindow.isCancelled else { return }
                self.busy = false
                self.jobToken = nil
                switch result {
                case .success(let result):
                    let packet = result.packet
                    self.baseReady[i] = true; self.freshBase[i] = true; self.generated[i] = result.generated
                    self.coverageRevision += 1; self.scheduleCoverage()
                    let complete = !self.buildings || RasterPacket.isBuilding(packet)
                    self.ready[i] = self.ready[i] || complete; self.freshDetails[i] = complete
                    if complete || !includeBuildings {
                        self.backoff.succeed(i); self.failureMessages.removeValue(forKey: i); self.failureCategories.removeValue(forKey: i)
                    } else {
                        self.backoff.fail(i, at: self.now()); self.failureMessages[i] = "建筑细节尚未生成，稍后重试"
                        self.failureCategories[i] = .invalidData
                    }
                    self.onReady(node)
                case .failure where job.isCancelled:
                    self.publish(.paused, detail: "优先保障圆屏当前地图，沿线准备稍后继续")
                    return
                case .failure(let error) where Self.isCancellation(error):
                    self.publish(.paused, detail: "地图任务已取消，已保存地图仍可使用")
                    return
                case .failure(let error):
                    let storage = Self.storageFailure(error)
                    self.lastError = storage?.localizedDescription ?? error.localizedDescription
                    if let storage = storage {
                        self.storageBlocked = true; self.timer?.invalidate(); self.timer = nil
                        self.onStatus("沿线准备暂停：\(storage.localizedDescription)")
                        self.publish(.storageBlocked, detail: "保留已有地图；清理空间后点击继续准备，不再反复下载")
                    } else {
                        let failure = MapFailurePolicy.classify(error)
                        self.lastError = failure.message
                        switch failure.action {
                        case .pauseMemory:
                            self.pauseForMemoryPressure(); return
                        case .pauseConfiguration:
                            self.configurationBlocked = true; self.pauseCurrentWork(); self.publishBlocked(); return
                        case .pauseStorage:
                            self.storageBlocked = true; self.timer?.invalidate(); self.timer = nil
                            self.publishBlocked(); return
                        case .cooldown(let seconds):
                            let deadline = self.now().addingTimeInterval(seconds)
                            self.serviceCooldownUntil = max(self.serviceCooldownUntil ?? deadline, deadline)
                        case .cancel:
                            self.publish(.paused, detail: "地图任务已取消，已保存地图仍可使用"); return
                        case .retryBlock:
                            self.backoff.fail(i, at: self.now()); self.failureMessages[i] = failure.message
                            self.failureCategories[i] = failure.category
                        }
                        self.onStatus("更新暂未完成，保留已有地图：\(failure.message)")
                    }
                }
                // A failed block does not hold healthy work behind one global retry timer.
                self.pump()
            }
        }
    }
    func close() {
        token.cancel(); windowToken.cancel(); jobToken?.cancel(); coverageToken.cancel(); timer?.invalidate(); timer = nil
        pendingCacheNotifications.removeAll()
        Self.cacheControl.async { self.cache.clearProtection(owner: self.cacheOwner) }
    }
    private static func isCancellation(_ error: Error) -> Bool {
        if case MapProcessingError.cancelled = error { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
    }
}
