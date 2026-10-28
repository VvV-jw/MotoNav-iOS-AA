import Foundation
import Combine
import UIKit

/// 版本：跟随 App 版本（见 Config.swift，iOS v0.2 新增；和安卓版 MapFeeder.kt 一样）
///
/// 小地图数据：
/// - 导航时下载当前位置附近约 2.4 公里见方的地图（高德 SDK 截图底图），
///   快开出这一块时自动下载下一块（向前方偏移，前面的路多下载一些）。
/// - 选了“卫星图”风格时改下高德卫星照片（范围小一些：半边 700 米）。
/// - 导航路线（连同路上的红绿灯位置）单独打包发给圆屏。
/// - iOS v0.3 原路线（导入的高德分享路线）：大块数据类型 4，圆屏画成橙色细线；"#o" 不显示
/// - 每次定位把当前位置、朝向、车速发给圆屏："#p,坐标系,x分米,y分米,朝向,车速"。
/// - 圆屏收齐一份地图/路线后回 "K,类型,编号"；没确认的 8 秒后重发，重连后也全部重发。
/// 状态都在主线程里读写，下载和计算在后台队列里做。
final class MapFeeder: ObservableObject {
    static let shared = MapFeeder()

    private let HALF = 1200.0            // 地图块半边长（米）
    private let REFRESH = 650.0          // 离地图块中心超过这个距离就准备下一块
    private let AHEAD = 450.0            // 新地图块中心往前方偏移
    private let SAT_HALF = 700.0         // 卫星图地图块半边长（米）
    private let SAT_REFRESH = 330.0
    private let SAT_AHEAD = 260.0
    static let MAX_BYTES = 190_000       // 圆屏线条地图缓冲 200KB，留余量
    static let MAX_FEAT = 7000
    private let RESEND = 8.0             // 秒

    static let TYPE_CHUNK = 1
    static let TYPE_ROUTE = 2
    static let TYPE_RASTER = 3
    static let TYPE_GHOST = 4

    static let SRC_AMAP = 3
    static let THEME_SAT = 10

    @Published var status = "（导航时自动下载附近地图）"
    @Published var offlineStatus = "选择路线后，在前台自动准备沿线离线底图"
    @Published var chunkInfo = ""
    @Published var buildingInfo = ""
    @Published var routeInfo = ""
    @Published var chunkAcked = false
    @Published var routeAcked = false
    @Published private(set) var readiness = MapReadinessSnapshot.idle
    @Published private(set) var offlineProgress = RouteMapPreparation.none
    @Published private(set) var routeCoverage = RouteCoverage.scanning(totalMeters: 0)
    @Published private(set) var routeCoverageFromPosition = false
    @Published private(set) var prefetchWiFiOnly = false
    @Published private(set) var prefetchChargingOnly = false
    private let prefetchConditions = PrefetchConditions()
    @Published private(set) var cacheInfo = "缓存状态尚未读取"
    @Published private(set) var cacheBusy = false
    @Published private(set) var cacheMessage = ""
    @Published private(set) var preparationRangeKm = 0
    @Published private(set) var memoryPaused = false
    @Published private(set) var configurationPaused = false
    @Published private(set) var recoverablePreparation: PreparationRecoveryCheckpoint? = nil
    @Published private(set) var preparationSaveState = PreparationRecoveryStore.SaveState.idle
    private let preparationRecovery = PreparationRecoveryStore()
    private var recoveryCheckpoint: PreparationRecoveryCheckpoint?
    private var recoveryOwner: UUID?
    private var preparationOnly = false
    private var foregroundServiceRetryAt = Date.distantPast
    private var memoryWarningObserver: NSObjectProtocol?
    private var readinessState = MapReadinessState()

    private let worker = DispatchQueue(label: "motonav.map", qos: .userInitiated)
    private let wireWorker = DispatchQueue(label: "motonav.map.wire", qos: .userInitiated)
    private(set) var frame: MapGeo.Frame?

    // 当前地图块
    private var chunkCx = 0.0, chunkCy = 0.0
    private var haveChunk = false
    private var fetching = false
    private var fetchingCenter: (x: Double, y: Double)?
    private var fetchingBaseReady = false
    private var lastFetchFail = Date.distantPast
    private var lastBuildingTry = Date.distantPast
    private var chunkId = 0
    private var chunkType = TYPE_CHUNK
    private var chunkBytes: Data?
    private var wireSerial = 0
    private var chunkSat = false
    private var chunkSentAt = Date.distantPast

    // 当前路线
    private var routeKey = ""
    private var routeRevision = 0
    private var routeBuildSerial = 0
    private var routeId = 0
    private var routeBytes: Data?
    private var routeSentAt = Date.distantPast

    // 原路线
    private var ghostCoords: [(lat: Double, lng: Double)]?   // 还没有坐标系时先存着
    private var ghostId = 0
    private var ghostBytes: Data?
    private var ghostAcked = false
    private var ghostSentAt = Date.distantPast

    private var lastBearing: Double?
    private var requestSerial = 0
    private var workToken = MapWorkToken()
    private var offlineMaps: RouteOfflineMaps?
    private var preparedKey = ""
    private var preparedCoords: [(lat: Double, lng: Double)] = []
    private var offlineKey = ""
    private var offlineContentKey = ""
    private var routeProgress = -1.0
    private var pose: (x: Double, y: Double, kmh: Int)?
    private var poseAt = Date.distantPast
    private var chunkBuildingsComplete = false
    private var chunkGeneratedAt: Date?
    private var pendingPreparedNode: (identity: String, node: RouteMapPlan.Node)?
    private var confirmedCenter: (x: Double, y: Double)?
    private var lastCoverageTrace = Date.distantPast
    private var buildingMode: Bool { Settings.shared.theme == 1 && Settings.shared.mapSource == Self.SRC_AMAP && Settings.shared.buildings && BleLink.shared.buildingsSupported }


    private var enabled: Bool { Settings.shared.mapOn }
    private var satMode: Bool { Settings.shared.theme == MapFeeder.THEME_SAT }
    private var gtaMode: Bool { Settings.shared.theme == 2 }
    private var mapHalf: Double { MapStylePolicy.half(Settings.shared.theme) }

    private init() {
        // Avoid initializing Bluetooth/Settings singletons just to present the idle
        // card; restored disabled/radar settings must still be correct at launch.
        let defaults = UserDefaults.standard
        let range = defaults.integer(forKey: "offline_prepare_range_km")
        preparationRangeKm = [0, 5, 20, 50].contains(range) ? range : 0
        prefetchWiFiOnly = defaults.bool(forKey: "offline_prefetch_wifi_only")
        prefetchChargingOnly = defaults.bool(forKey: "offline_prefetch_charging_only")
        let storedStyle = defaults.object(forKey: "map_theme") as? Int ?? 1
        readiness = readinessState.snapshot(enabled: defaults.object(forKey: "map_on") as? Bool ?? true,
            usesBasemap: MapStylePolicy.usesBasemap(storedStyle), connected: false, coverage: .unconfirmed)
        memoryWarningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in self?.pauseForMemoryPressure() }
        prefetchConditions.onChange = { [weak self] in self?.offlineMaps?.reevaluatePrefetchPolicy() }
        prefetchConditions.setEnabled(prefetchWiFiOnly || prefetchChargingOnly)
        // Reading a saved task never starts provider work, navigation or Bluetooth.
        preparationRecovery.observeSaveState { [weak self] value in self?.preparationSaveState = value }
        preparationRecovery.loadAsync { [weak self] value in self?.recoverablePreparation = value }
    }
    func pauseForMemoryPressure() {
        memoryPaused = true
        workToken.cancel(); requestSerial += 1; fetching = false
        AmapCaptureHost.shared.pauseForMemoryPressure()
        offlineMaps?.pauseForMemoryPressure()
        cacheMessage = "系统报告内存紧张，已暂停地图准备；释放内存后可手动继续"
        status = cacheMessage
        readinessState.cancelPreparation(); publishReadiness()
    }
    private var foregroundNetworkBlocked: Bool {
        memoryPaused || configurationPaused || foregroundServiceRetryAt > Date()
    }
    private var networkServiceDeadline: Date {
        max(foregroundServiceRetryAt, offlineMaps?.serviceRetryAt ?? .distantPast,
            gtaMode ? GtaVectorMaps.serviceRetryAt ?? .distantPast : .distantPast)
    }
    /// Called on main immediately before provider work; offline packet reads remain usable.
    private func networkPauseError() -> Error? {
        if memoryPaused || offlineMaps?.isMemoryPaused == true { return MapServiceError.memoryPressure }
        if configurationPaused || offlineMaps?.isConfigurationBlocked == true { return MapServiceError.configuration("配置暂停") }
        let deadline = networkServiceDeadline
        if deadline > Date() { return MapServiceError.http(status: 429, retryAfter: deadline.timeIntervalSinceNow) }
        return nil
    }
    private func closeOfflinePreparation() {
        foregroundServiceRetryAt = max(foregroundServiceRetryAt, offlineMaps?.serviceRetryAt ?? .distantPast)
        memoryPaused = memoryPaused || (offlineMaps?.isMemoryPaused == true)
        configurationPaused = configurationPaused || (offlineMaps?.isConfigurationBlocked == true)
        offlineMaps?.close()
        routeCoverage = RouteCoverage.scanning(totalMeters: 0); routeCoverageFromPosition = false
    }

    /// Preserve prepared offline packets when navigation starts.
    func onNaviStart() {
        routeKey = ""
        routeRevision = 0
        if chunkBytes != nil && !chunkAcked { sendChunk() }
    }
    func onNaviEnd() {
        discardSavedPreparation()
        closeOfflinePreparation(); offlineMaps = nil; offlineKey = ""; pendingPreparedNode = nil
        preparedCoords = []; preparedKey = ""; offlineStatus = "沿线下载已暂停，重新选择路线后继续"
        workToken.cancel(); requestSerial += 1; routeBuildSerial += 1; fetching = false
        wireSerial += 1; BleLink.shared.cancelMapBulk()
        readinessState.cancelPreparation(); readinessState.cancelTransfer()
        offlineProgress = .none; publishReadiness()
    }
    func resetChunk() {
        buildingInfo = ""; lastBuildingTry = .distantPast; pendingPreparedNode = nil
        workToken.cancel(); requestSerial += 1; fetching = false
        haveChunk = false; chunkBytes = nil; chunkAcked = false; confirmedCenter = nil; chunkGeneratedAt = nil
        wireSerial += 1; BleLink.shared.cancelMapBulk(); lastFetchFail = .distantPast
        readinessState.reset(); offlineProgress = .none; publishReadiness()
        closeOfflinePreparation(); offlineMaps = nil; offlineKey = ""; routeProgress = -1
        if preparedCoords.count >= 2 { restartPreparedRoute() }
    }
    func onBuildingCapability() {
        guard Settings.shared.theme == 1 else { return }
        // Keep the raw current packet through disconnect/capability changes. It can
        // still be resent with legacy conversion while a new building pass prepares.
        lastBuildingTry = .distantPast
        if preparedCoords.count >= 2 { restartPreparedRoute() }
    }
    func onRasterCapability() {
        guard chunkType == Self.TYPE_RASTER, chunkBytes != nil else { return }
        // A capability reply can arrive after an uncompressed retry has begun. Use a new
        // ID so the display cannot combine fragments from the two encodings.
        BleLink.shared.cancelMapBulk(); chunkId = (chunkId + 1) & 0xFF
        chunkAcked = false; readinessState.accept(.init(type: chunkType, id: chunkId)); sendChunk()
    }
    /// A disconnected display may reboot. Never show an old ACK as current coverage,
    /// and invalidate asynchronous encoders before a replacement connection starts.
    func onConnectionLost() {
        wireSerial += 1; chunkAcked = false; confirmedCenter = nil
        routeAcked = false; ghostAcked = false
        readinessState.disconnect(); publishReadiness()
    }
    private func publishReadiness() {
        let coverage: MapReadinessSnapshot.Coverage
        if let center = confirmedCenter {
            if let p = pose {
                coverage = MapCoveragePolicy.covers(x: p.x, y: p.y, cx: center.x, cy: center.y,
                    kmh: max(120, p.kmh), half: mapHalf) ? .covered : .uncovered
            } else { coverage = .unknown }
        } else { coverage = .unconfirmed }
        let next = readinessState.snapshot(enabled: enabled, usesBasemap: Settings.shared.theme != 11,
            connected: BleLink.shared.isReady, coverage: coverage)
        if readiness != next { readiness = next }
    }
    private func ensureFrame(lat: Double, lng: Double) -> MapGeo.Frame {
        if let f = frame { return f }
        let la = (lat * 10).rounded() / 10, lo = (lng * 10).rounded() / 10
        let id = ((Int((la * 10).rounded()) * 7919 + Int((lo * 10).rounded()) * 104729) & 0x7FFF) | 1
        let f = MapGeo.Frame(refLat: la, refLng: lo, id: id); frame = f; return f
    }

    func refreshCacheInfo() {
        guard !cacheBusy else { return }
        cacheBusy = true
        RouteOfflineMaps.cacheControl.async {
            let stats = RouteMapCache.shared.stats()
            let raw = RawMapCache.shared.stats()
            DispatchQueue.main.async { self.showCacheStats(stats, raw: raw); self.cacheBusy = false }
        }
    }
    private func showCacheStats(_ stats: RouteMapCache.Stats, raw: RawMapCache.Stats) {
        cacheInfo = "地图缓存合计 \((stats.bytes + raw.bytes) / 1024 / 1024) / \((stats.limit + raw.limit) / 1024 / 1024) MB\n" +
            "成品包 \(stats.bytes / 1024 / 1024) / \(stats.limit / 1024 / 1024) MB（\(stats.files) 块）；GTA 原始瓦片 \(raw.bytes / 1024 / 1024) / \(raw.limit / 1024 / 1024) MB（\(raw.files) 文件）\n" +
            "当前范围保护 \(stats.protectedBytes / 1024 / 1024) MB；正在使用的原始瓦片 \(raw.protectedBytes / 1024 / 1024) MB。SDK 自身缓存另计。"
    }
    func clearUnusedMaps() {
        guard !cacheBusy else { return }
        cacheBusy = true; cacheMessage = "正在清理非当前路线地图…"
        RouteOfflineMaps.cacheControl.async {
            let result = Result { () throws -> (RouteMapCache.Stats, RawMapCache.Stats) in
                let packets = try RouteMapCache.shared.clearUnprotected()
                let raw = try RawMapCache.shared.clearUnprotectedStrict()
                return (packets, raw)
            }
            DispatchQueue.main.async {
                self.cacheBusy = false
                switch result {
                case .success(let values):
                    self.showCacheStats(values.0, raw: values.1); self.cacheMessage = "清理完成，当前范围成品包和正在使用的 GTA 瓦片已保留"
                case .failure(let error): self.cacheMessage = "清理未完成：\(MapFailurePolicy.classify(error).message)"
                }
            }
        }
    }
    func updatePreparedRoute() {
        guard enabled, !satMode, Settings.shared.theme != 11, preparedCoords.count >= 2 else {
            cacheMessage = "请先选择支持沿线准备的路线与地图风格"; return
        }
        cacheMessage = "正在更新沿线地图；更新失败时保留已有地图"
        if preparationOnly, var checkpoint = recoveryCheckpoint {
            checkpoint.forceRefresh = true; checkpoint.refreshStartedAt = Date(); checkpoint.savedAt = Date()
            startPreparedRoute(key: preparedKey, coords: preparedCoords, forceRefresh: true, recovery: checkpoint)
        } else { prepareRoute(key: preparedKey, coords: preparedCoords, forceRefresh: true) }
    }
    func resumeMapPreparation() {
        memoryPaused = false; configurationPaused = false
        offlineMaps?.resumeAfterStorageChange()
        cacheMessage = foregroundServiceRetryAt > Date() ? "地图服务仍在冷却，等待服务端允许后继续" : "已恢复地图准备，保留已有地图"
        refreshCacheInfo()
    }
    func setPreparationRangeKm(_ kilometers: Int) {
        let value = [0, 5, 20, 50].contains(kilometers) ? kilometers : 0
        guard value != preparationRangeKm else { return }
        preparationRangeKm = value
        UserDefaults.standard.set(value, forKey: "offline_prepare_range_km")
        offlineMaps?.setRangeKm(value)
        if var checkpoint = recoveryCheckpoint {
            checkpoint.rangeKm = value; checkpoint.savedAt = Date(); recoveryCheckpoint = checkpoint
            if let owner = recoveryOwner { preparationRecovery.update(checkpoint, owner: owner) }
        }
        cacheMessage = value == 0 ? "准备全程地图" : "准备前方 \(value) 公里，行进后自动向前延伸"
        refreshCacheInfo()
    }
    func setPrefetchWiFiOnly(_ enabled: Bool) {
        prefetchWiFiOnly = enabled
        UserDefaults.standard.set(enabled, forKey: "offline_prefetch_wifi_only")
        updatePrefetchConstraints()
    }
    func setPrefetchChargingOnly(_ enabled: Bool) {
        prefetchChargingOnly = enabled
        UserDefaults.standard.set(enabled, forKey: "offline_prefetch_charging_only")
        updatePrefetchConstraints()
    }
    private func updatePrefetchConstraints() {
        prefetchConditions.setEnabled(prefetchWiFiOnly || prefetchChargingOnly)
        offlineMaps?.reevaluatePrefetchPolicy()
        cacheMessage = "已保存沿线预下载条件；当前屏地图、导航和蓝牙不受此设置限制"
        MapPipelineTrace.event("prefetch-policy", ["wifiOnly": prefetchWiFiOnly, "chargingOnly": prefetchChargingOnly])
    }
    private var prefetchDecision: PrefetchPolicy.Decision {
        PrefetchPolicy.decide(foreground: false, wifiOnly: prefetchWiFiOnly, chargingOnly: prefetchChargingOnly,
                              unmeteredWifi: prefetchConditions.unmeteredWifi, charging: prefetchConditions.charging)
    }
    func retryFailedMapSections() {
        guard let maps = offlineMaps else { cacheMessage = "请先选择路线"; return }
        guard !memoryPaused, !configurationPaused,
              ![.storageBlocked, .memoryBlocked, .configurationBlocked, .rateLimited].contains(offlineProgress.phase),
              foregroundServiceRetryAt <= Date() else {
            cacheMessage = "请先处理暂停原因；重试不会绕过内存、配置、存储暂停或服务冷却"; return
        }
        maps.retryFailed()
        cacheMessage = "已安排重试失败路段，保留已有地图"
    }
    /// Called when selecting a route, before departure, and after a reroute.
    func prepareRoute(key: String, coords: [(lat: Double, lng: Double)], forceRefresh: Bool = false) {
        if preparationOnly { offlineContentKey = "" }
        preparationOnly = false
        startPreparedRoute(key: key, coords: coords, forceRefresh: forceRefresh, recovery: nil)
    }
    private func restartPreparedRoute() {
        let preserved = recoveryCheckpoint.flatMap { value in
            value.matches(source: Settings.shared.mapSource, style: Settings.shared.theme,
                buildingPreference: Settings.shared.buildings) ? value : nil
        }
        startPreparedRoute(key: preparedKey, coords: preparedCoords, forceRefresh: recoveryCheckpoint?.forceRefresh ?? false,
                           recovery: preparationOnly ? preserved : nil, preservedTask: preserved)
    }
    /// Explicit maintenance action. This creates an offline worker only; the saved
    /// frame stays local to that worker and no old pose/route/BLE state is restored.
    func continueSavedPreparation() {
        guard let checkpoint = recoverablePreparation, checkpoint.isValid(at: Date()) else {
            discardSavedPreparation(); cacheMessage = "上次地图准备任务已过期，请重新选择路线"; return
        }
        guard enabled, checkpoint.matches(source: Settings.shared.mapSource, style: Settings.shared.theme, buildingPreference: Settings.shared.buildings) else {
            cacheMessage = "请先切换到上次任务使用的地图风格与建筑设置，再继续；现有设置保持不变"; return
        }
        guard offlineMaps == nil else { cacheMessage = "当前已有地图准备任务，请先完成当前任务"; return }
        preparationOnly = true
        // Range is task-local. It does not silently overwrite the user's defaults.
        startPreparedRoute(key: checkpoint.key, coords: checkpoint.points.map { ($0.lat, $0.lng) },
                           forceRefresh: checkpoint.forceRefresh, recovery: checkpoint)
        recoverablePreparation = nil
        cacheMessage = "已从路线起点重新检查缓存并继续上次准备；未启动导航"
    }
    func discardSavedPreparation() {
        preparationRecovery.clear(); recoverablePreparation = nil
        recoveryCheckpoint = nil; recoveryOwner = nil
    }
    private func startPreparedRoute(key: String, coords: [(lat: Double, lng: Double)], forceRefresh: Bool,
                                    recovery: PreparationRecoveryCheckpoint?, preservedTask: PreparationRecoveryCheckpoint? = nil) {
        guard coords.count >= 2 else { return }
        preparedKey = key; preparedCoords = coords
        let f = recovery.map { MapGeo.Frame(refLat: $0.frameLat, refLng: $0.frameLng, id: $0.frameID) }
            ?? ensureFrame(lat: coords[0].lat, lng: coords[0].lng), src = Settings.shared.mapSource
        let taskState = recovery ?? preservedTask
        let workBuildings = recovery?.buildings ?? buildingMode
        guard enabled, !satMode, Settings.shared.theme != 11 else {
            discardSavedPreparation()
            offlineProgress = .none; publishReadiness(); return
        }
        var hasher = Hasher()
        for c in coords { hasher.combine(c.lat); hasher.combine(c.lng) }
        let contentIdentity = "\(key)|\(hasher.finalize())|\(src)|\(MapStylePolicy.cacheKey(theme: Settings.shared.theme, buildings: workBuildings))"
        if contentIdentity == offlineContentKey, offlineMaps != nil, !forceRefresh { return }
        let identity = "\(contentIdentity)|job-\(UUID().uuidString)"
        offlineContentKey = contentIdentity
        closeOfflinePreparation(); offlineKey = identity; routeProgress = -1; pendingPreparedNode = nil
        workToken.cancel(); requestSerial += 1; fetching = false
        readinessState.cancelPreparation(); publishReadiness()
        do {
            let plan = try RouteMapPlan(coords.map { (x: f.x($0.lng), y: f.y($0.lat)) })
            let refreshBoundary = taskState?.refreshStartedAt ?? Date(), range = taskState?.rangeKm ?? preparationRangeKm
            let checkpoint = PreparationRecoveryCheckpoint(savedAt: Date(), key: String(key.prefix(512)),
                points: coords.map { .init(lat: $0.lat, lng: $0.lng) }, frameLat: f.refLat, frameLng: f.refLng,
                frameID: f.id, source: src, style: Settings.shared.theme, buildings: workBuildings,
                buildingPreference: Settings.shared.buildings,
                rangeKm: range, forceRefresh: forceRefresh, refreshStartedAt: refreshBoundary)
            recoveryCheckpoint = checkpoint; recoveryOwner = preparationRecovery.begin(checkpoint)
            recoverablePreparation = nil
            let maps = RouteOfflineMaps(frame: f, plan: plan, source: src, buildings: workBuildings, style: Settings.shared.theme,
                foregroundBusy: { [weak self] in guard let self = self else { return true }; return self.fetching || self.foregroundNetworkBlocked },
                onReady: { [weak self] node in
                    self?.preparedMapReady(node, identity: identity)
                }, onStatus: { [weak self] status in
                    if let self = self, self.offlineKey == identity, self.offlineStatus != status { self.offlineStatus = status }
                }, onProgress: { [weak self] progress in
                    if let self = self, self.offlineKey == identity, self.offlineProgress != progress {
                        self.offlineProgress = progress
                        if progress.phase == .complete {
                            // Worker .complete means every requested detail is fresh,
                            // unlike isComplete (which also counts usable old maps).
                            if let owner = self.recoveryOwner { self.preparationRecovery.clear(owner: owner); self.recoveryOwner = nil }
                        } else if self.recoveryOwner == nil, var saved = self.recoveryCheckpoint {
                            saved.savedAt = Date(); self.recoveryCheckpoint = saved
                            self.recoveryOwner = self.preparationRecovery.begin(saved)
                        }
                        MapPipelineTrace.event("preparation-state", ["state": Self.preparationPhaseCode(progress.phase),
                            "reason": Self.preparationFailureCode(progress.failureCategory),
                            "availableBlocks": progress.ready, "totalBlocks": progress.total,
                            "seconds": max(0, progress.retryAt?.timeIntervalSinceNow ?? 0)])
                    }
                }, onCoverage: { [weak self] coverage in
                    if let self = self, self.offlineKey == identity, self.routeCoverage != coverage {
                        self.routeCoverage = coverage
                        MapPipelineTrace.event("route-coverage", ["coverageState": [RouteCoverage.State.scanning, .ready, .gap, .unknown].firstIndex(of: coverage.state) ?? 0,
                            "coverageChecks": coverage.candidateChecks])
                    }
                }, prefetchDecision: { [weak self] in self?.prefetchDecision ?? .allow
                }, forceRefresh: forceRefresh, rangeKm: range, refreshStartedAt: refreshBoundary)
            if !preparationOnly, let p = pose, (0...15).contains(Date().timeIntervalSince(poseAt)) {
                let progress = plan.progress(x: p.x, y: p.y, previous: -1)
                let projected = plan.at(progress)
                if hypot(p.x - projected.x, p.y - projected.y) < 400 {
                    routeProgress = progress
                    routeCoverageFromPosition = true; maps.updateProgress(progress)
                    maps.update(plan.target(progress: progress, initial: false))
                }
            }
            offlineMaps = maps; maps.start()
        } catch {
            discardSavedPreparation()
            offlineStatus = "沿线离线地图：\(error.localizedDescription)"
            offlineProgress = RouteMapPreparation(phase: .failed, ready: 0, total: 0, detailedReady: 0,
                retryAt: nil, error: error.localizedDescription, detail: "重新选择路线后重试")
        }
    }
    private static func preparationPhaseCode(_ phase: RouteMapPreparation.Phase) -> Int {
        [RouteMapPreparation.Phase.none, .checking, .preparing, .paused, .policyPaused, .retrying, .complete,
         .failed, .storageBlocked, .memoryBlocked, .configurationBlocked, .rateLimited].firstIndex(of: phase) ?? 0
    }
    private static func preparationFailureCode(_ value: String?) -> Int {
        guard let value = value else { return 0 }
        return (["network", "timeout", "rateLimited", "configuration", "invalidData", "memory", "storage", "cancelled", "unknown"].firstIndex(of: value) ?? 8) + 1
    }
    /// Coalesce notifications while a current-map lookup/capture is in flight. Re-evaluate
    /// the desired display node after that job finishes instead of dropping a newer map.
    private func preparedMapReady(_ node: RouteMapPlan.Node, identity: String) {
        guard !preparationOnly, offlineKey == identity, enabled, !memoryPaused, let maps = offlineMaps, let f = frame else { return }
        let plan = maps.plan
        let progress = pose.map { plan.progress(x: $0.x, y: $0.y, previous: routeProgress) } ?? 0
        let onRoute = plan.at(progress)
        if let p = pose, hypot(p.x - onRoute.x, p.y - onRoute.y) >= 400 { return }
        let wantedIndex = pose.map { plan.displayTarget(progress: progress, x: $0.x, y: $0.y, kmh: $0.kmh) }
            ?? plan.target(progress: progress, initial: true)
        guard plan.nodes[wantedIndex] == node else { return }
        if fetching { pendingPreparedNode = (identity, node); return }
        let sameCenter = haveChunk && abs(chunkCx - node.x) < 1 && abs(chunkCy - node.y) < 1
        let newer = (maps.generationDate(node) ?? .distantPast) > (chunkGeneratedAt ?? .distantPast)
        if gtaMode, haveChunk, let p = pose,
           MapCoveragePolicy.covers(x: p.x, y: p.y, cx: chunkCx, cy: chunkCy,
               kmh: max(120, p.kmh), half: mapHalf, margin: 250), !(sameCenter && newer) { return }
        if sameCenter && !newer {
            if !buildingMode || chunkBuildingsComplete { return }
            if !maps.hasDetailed(node) { return }
        }
        fetchChunk(f, node.x, node.y, node: node)
    }
    private func checkPendingPreparedMap() {
        guard !fetching, let pending = pendingPreparedNode else { return }
        pendingPreparedNode = nil
        preparedMapReady(pending.node, identity: pending.identity)
    }
    func onLocation(lat: Double, lng: Double, bearing: Double, kmh: Int) {
        let f = ensureFrame(lat: lat, lng: lng), x = f.x(lng), y = f.y(lat)
        pose = (x, y, kmh)
        poseAt = Date()
        publishReadiness()
        if enabled, Settings.shared.mapSource == Self.SRC_AMAP, Date().timeIntervalSince(lastCoverageTrace) >= 2 {
            lastCoverageTrace = Date()
            MapPipelineTrace.event("view-coverage", ["kmh": kmh, "ready": BleLink.shared.isReady,
                "sentCovered": haveChunk && MapCoveragePolicy.covers(x: x, y: y, cx: chunkCx, cy: chunkCy, kmh: max(120, kmh), half: mapHalf),
                "confirmedCovered": confirmedCenter.map { MapCoveragePolicy.covers(x: x, y: y, cx: $0.x, cy: $0.y, kmh: max(120, kmh), half: mapHalf) } ?? false])
        }
        var hdg = bearing
        if kmh >= 4 || lastBearing == nil { if kmh >= 4 { lastBearing = bearing } } else { hdg = lastBearing! }
        BleLink.shared.send("#p,\(f.id),\(Int((x * 10).rounded())),\(Int((y * 10).rounded())),\(Int(hdg.rounded())),\(kmh)")
        if ghostCoords != nil && ghostBytes == nil { encodeGhost() }
        if !enabled { return }
        if Settings.shared.theme == 11 { status = "龙珠雷达（无需底图）"; publishReadiness(); checkResend(); return }
        if memoryPaused || offlineMaps?.isMemoryPaused == true { status = "内存紧张，保留已有地图；可在地图维护中继续"; return }
        var node: RouteMapPlan.Node?
        if !preparationOnly, let maps = offlineMaps {
            routeProgress = maps.plan.progress(x: x, y: y, previous: routeProgress)
            let projected = maps.plan.at(routeProgress), index = maps.plan.displayTarget(progress: routeProgress, x: x, y: y, kmh: kmh)
            let candidate = maps.plan.nodes[index]
            if hypot(x - projected.x, y - projected.y) < 400 {
                routeCoverageFromPosition = true; maps.updateProgress(routeProgress)
                maps.update(maps.plan.target(progress: routeProgress, initial: false))
                if MapCoveragePolicy.covers(x: x, y: y, cx: candidate.x, cy: candidate.y, kmh: max(120, kmh), half: mapHalf, margin: 50) { node = candidate }
            }
        }
        let distance = hypot(x - chunkCx, y - chunkCy)
        let refresh = chunkSat ? SAT_REFRESH : (gtaMode ? 1500 : REFRESH)
        let changedNode = (node.map { abs($0.x - chunkCx) >= 1 || abs($0.y - chunkCy) >= 1 } ?? false) && (!gtaMode || distance > refresh)
        let needsCoverage = !satMode && Settings.shared.mapSource == Self.SRC_AMAP && !MapCoveragePolicy.covers(x: x, y: y, cx: chunkCx, cy: chunkCy, kmh: max(120, kmh), half: mapHalf, margin: 50)
        let prepareEarly = !satMode && Settings.shared.mapSource == Self.SRC_AMAP &&
            MapCoveragePolicy.needsRefresh(x: x, y: y, cx: chunkCx, cy: chunkCy, bearing: bearing, kmh: kmh, half: mapHalf)
        // A building pass must yield before movement leaves its base map. Cached bases can switch immediately.
        if fetching, !satMode, Settings.shared.mapSource == Self.SRC_AMAP, let center = fetchingCenter,
           (fetchingBaseReady && (needsCoverage || changedNode) || !MapCoveragePolicy.covers(x: x, y: y, cx: center.x, cy: center.y, kmh: kmh, half: mapHalf)) {
            MapPipelineTrace.event("movement-cancel", ["serial": requestSerial, "baseReady": fetchingBaseReady, "needsCoverage": needsCoverage, "nextBlock": changedNode, "kmh": kmh])
            workToken.cancel(); requestSerial += 1; fetching = false
            readinessState.cancelPreparation(); publishReadiness()
        }
        let retryBuildings = buildingMode && !chunkBuildingsComplete && UIApplication.shared.applicationState == .active && Date().timeIntervalSince(lastBuildingTry) >= 60
        if !fetching && (!haveChunk || distance > refresh || needsCoverage || changedNode || (node == nil && prepareEarly) || retryBuildings) && Date().timeIntervalSince(lastFetchFail) > 15 {
            let a = bearing * .pi / 180, ahead = kmh > 5 ? (satMode ? SAT_AHEAD : MapCoveragePolicy.lookahead(kmh: kmh, half: mapHalf, preferred: gtaMode ? 800 : AHEAD)) : 0
            fetchChunk(f, node?.x ?? (x + sin(a) * ahead), node?.y ?? (y + cos(a) * ahead), node: node)
        }
        checkPendingPreparedMap()
        checkResend()
    }
    private func acceptChunk(_ b: Data, cx: Double, cy: Double, sat: Bool, type: Int, info: String, src: Int, generatedAt: Date) {
        guard enabled, Settings.shared.theme != 11 else { return }
        if let p = pose, !sat, src == Self.SRC_AMAP,
           !MapCoveragePolicy.covers(x: p.x, y: p.y, cx: cx, cy: cy, kmh: p.kmh, half: mapHalf) {
            MapPipelineTrace.event("packet-outside-view", ["buildings": RasterPacket.isBuilding(b)]); return
        }
        let complete = type == Self.TYPE_RASTER && RasterPacket.isBuilding(b)
        let displayBytes = type == Self.TYPE_RASTER && buildingMode && src == Self.SRC_AMAP ? AmapBuildings.carry(b, known: chunkBytes) : b
        if haveChunk, chunkType == type, chunkSat == sat, abs(cx - chunkCx) < 1, abs(cy - chunkCy) < 1,
           displayBytes == chunkBytes {
            // Cached base then screenshot base often encode the exact same map.
            // Keep the transfer ID so the second callback cannot invalidate fragments already received.
            chunkBuildingsComplete = chunkBuildingsComplete || complete
            chunkGeneratedAt = generatedAt
            return
        }
        chunkGeneratedAt = generatedAt
        chunkBytes = displayBytes
        chunkBuildingsComplete = complete
        haveChunk = true; chunkSat = sat; chunkCx = cx; chunkCy = cy
        chunkId = (chunkId + 1) & 0xFF; chunkType = type; chunkAcked = false
        readinessState.accept(.init(type: type, id: chunkId))
        status = complete ? "高德建筑底图已就绪" : "地图已就绪"
        chunkInfo = "地图块 #\(chunkId)：\(info)，\(b.count / 1024) KB" + (buildingMode && !complete ? "（建筑尚未完成，显示普通底图）" : "")
        sendChunk()
    }
    private func fetchChunk(_ f: MapGeo.Frame, _ cx: Double, _ cy: Double, node: RouteMapPlan.Node? = nil) {
        guard !memoryPaused, offlineMaps?.isMemoryPaused != true else { return }
        fetching = true; status = "正在准备附近地图…"; requestSerial += 1
        readinessState.beginPreparation(); publishReadiness()
        fetchingCenter = (cx, cy); fetchingBaseReady = false
        let serial = requestSerial
        MapPipelineTrace.event("fetch-start", ["serial": serial, "buildings": buildingMode, "source": Settings.shared.mapSource])
        workToken.cancel(); let token = MapWorkToken(); workToken = token
        let src = Settings.shared.mapSource, sat = satMode, buildings = buildingMode, style = Settings.shared.theme
        let rasterInfo = style == 0 ? "高德原版完整细节，2 米/像素" : (style == 5 ? "黑白完整道路网，2 米/像素" : "高德无字底图，2 米/像素")
        let maps = offlineMaps
        let foreground = UIApplication.shared.applicationState == .active
        if buildings { lastBuildingTry = Date() }
        worker.async {
            // Disk lookup and packet validation never hold up a location/UI callback.
            if let node = node, let cached = maps?.lookup(node), !token.isCancelled {
                DispatchQueue.main.async {
                    guard serial == self.requestSerial, !token.isCancelled else { return }
                    defer { self.checkPendingPreparedMap() }
                    self.acceptChunk(cached.data, cx: cx, cy: cy, sat: false,
                        type: style == 2 ? Self.TYPE_CHUNK : Self.TYPE_RASTER,
                        info: cached.isStale ? "沿线旧包可用，后台更新中" : "沿线离线包", src: src,
                        generatedAt: cached.generatedAt)
                    self.fetchingBaseReady = true; self.fetching = false
                    if let maps = maps, self.offlineMaps === maps { maps.noteCachedPacket(node) }
                    self.readinessState.finishPreparation(); self.publishReadiness()
                    MapPipelineTrace.event("fetch-complete", ["serial": serial, "bytes": cached.data.count])
                }
                return
            }
            if style != 2 && !foreground {
                DispatchQueue.main.async {
                    guard serial == self.requestSerial, !token.isCancelled else { return }
                    defer { self.checkPendingPreparedMap() }
                    self.fetching = false; self.buildingInfo = "回到前台继续准备地图；已保存底图仍可使用"
                    self.readinessState.waitForForeground(); self.publishReadiness()
                }
                return
            }
            var bytes: Data?, type = Self.TYPE_RASTER, gotSat = false, failure: Error?, info = ""
            var generatedAt = Date.distantPast
            var savedNode: RouteMapPlan.Node?
            do {
                if token.isCancelled { throw MapProcessingError.cancelled }
                if let pause = DispatchQueue.main.sync(execute: { self.networkPauseError() }) { throw pause }
                if sat {
                    bytes = try AmapSdkRaster.build(f,cx: cx,cy: cy,includeBuildings: false,shouldCancel: { token.isCancelled },satellite: true, style: style).bytes
                    gotSat = true; info = "高德卫星图"
                } else if style == 2 {
                    let result = try GtaVectorMaps.build(f, cx: cx, cy: cy, shouldCancel: { token.isCancelled })
                    bytes = result.bytes; type = Self.TYPE_CHUNK
                    info = "GTA5 完整矢量路网，\(result.tiles) 瓦片"
                } else if src == Self.SRC_AMAP {
                    bytes = try AmapSdkRaster.build(f, cx: cx, cy: cy, includeBuildings: buildings, shouldCancel: { token.isCancelled }, onBaseReady: { base in
                        guard !token.isCancelled else { return }
                        let baseGeneratedAt = Date()
                        let stored: Bool
                        if let node = node {
                            do { try RouteMapCache.shared.store(base, frame: f, source: src, node: node, style: style); stored = true }
                            catch { stored = false }
                        } else { stored = false }
                        DispatchQueue.main.async {
                            if serial == self.requestSerial && !token.isCancelled {
                                if stored, let node = node, let maps = maps, self.offlineMaps === maps { maps.noteCachedPacket(node) }
                                self.fetchingBaseReady = true
                                self.acceptChunk(base, cx: cx, cy: cy, sat: false, type: Self.TYPE_RASTER,
                                    info: rasterInfo, src: src, generatedAt: baseGeneratedAt)
                            }
                        }
                    }, onBuildingStatus: { message in
                        DispatchQueue.main.async {
                            if serial == self.requestSerial && !token.isCancelled { self.buildingInfo = message }
                        }
                    }, style: style).bytes
                    info = rasterInfo
                }
                generatedAt = Date()
                if let packet = bytes, let node = node, !sat, !token.isCancelled {
                    do {
                        try RouteMapCache.shared.store(packet, frame: f, source: src, node: node, style: style)
                        savedNode = node
                    } catch { /* Display remains usable; only confirmed cache stores update preparation metadata. */ }
                }
            } catch { failure = error }
            DispatchQueue.main.async {
                guard serial == self.requestSerial, !token.isCancelled else { return }
                defer { self.checkPendingPreparedMap() }
                self.fetching = false
                if let node = savedNode, let maps = maps, self.offlineMaps === maps { maps.noteCachedPacket(node) }
                guard let packet = bytes else {
                    let decision = MapFailurePolicy.classify(failure ?? MapServiceError.invalidData("未取得地图"))
                    let errorText = decision.message
                    switch decision.action {
                    case .pauseMemory: self.pauseForMemoryPressure(); return
                    case .pauseConfiguration: self.configurationPaused = true
                    case .cooldown(let seconds):
                        let saved = self.networkServiceDeadline
                        self.foregroundServiceRetryAt = saved > Date() ? saved : Date().addingTimeInterval(seconds)
                    case .cancel: self.readinessState.cancelPreparation(); self.publishReadiness(); return
                    case .pauseStorage, .retryBlock: break
                    }
                    self.lastFetchFail = Date(); self.status = "地图准备失败，保留已有地图：\(errorText)"
                    MapPipelineTrace.event("fetch-failed", ["serial": serial])
                    self.readinessState.failPreparation(errorText.isEmpty ? "暂时无法取得地图" : errorText,
                        retryAt: max(self.lastFetchFail.addingTimeInterval(15), self.foregroundServiceRetryAt))
                    self.publishReadiness(); return
                }
                MapPipelineTrace.event("fetch-complete", ["serial": serial, "bytes": packet.count])
                self.readinessState.finishPreparation()
                self.acceptChunk(packet, cx: cx, cy: cy, sat: gotSat, type: type, info: info, src: src, generatedAt: generatedAt)
                self.publishReadiness()
            }
        }
    }

    private func sendChunk() {
        guard let b = chunkBytes, enabled, Settings.shared.theme != 11 else { return }
        let identity = MapReadinessState.Packet(type: chunkType, id: chunkId)
        // Do not queue background work against an absent connection or accept its ACK.
        guard BleLink.shared.isReady else {
            _ = readinessState.beginSending(identity, connected: false); publishReadiness(); return
        }
        chunkSentAt = Date()
        let type = chunkType, id = chunkId
        let buildings = BleLink.shared.buildingsSupported, compressed = BleLink.shared.rasterCompressionSupported
        wireSerial += 1; let serial = wireSerial
        wireWorker.async {
            let raw = type == Self.TYPE_RASTER && !buildings && !RasterPacket.hasPalette(b) ? RasterPacket.forLegacy(b) : b
            let wire = type == Self.TYPE_RASTER ? RasterTransport.pack(raw, supported: compressed) : raw
            DispatchQueue.main.async {
                guard serial == self.wireSerial,
                      id == self.chunkId, type == self.chunkType, self.enabled, BleLink.shared.isReady else { return }
                guard self.readinessState.beginSending(identity, connected: true) else { return }
                self.publishReadiness()
                MapPipelineTrace.packet(wire, type: type, id: id, ready: BleLink.shared.isReady)
                BleLink.shared.sendBulk(type: type, id: id, data: wire)
            }
        }
    }

    // MARK: - 路线

    /// 每次收到导航信息时调用，路线变了（新规划 / 偏航重算）就重新发送。
    /// coords、lights 都是高德坐标（纬度, 经度）。还没有坐标系（没定位）时返回 false，稍后再试。
    func onRoute(key: String, coords: [(lat: Double, lng: Double)], lights: [(lat: Double, lng: Double)], revision: Int = 0) -> Bool {
        guard let f = frame else { return false }
        if key == routeKey && revision == routeRevision { return true }
        if coords.count < 2 { return false }
        let changedRoute = key != routeKey
        routeKey = key
        routeRevision = revision
        // Static metadata may arrive after the geometry. Update its route packet
        // without restarting along-route downloads or replacing the selected route.
        if changedRoute { prepareRoute(key: key, coords: coords) }
        routeBuildSerial += 1; let serial = routeBuildSerial
        wireWorker.async {
            var pts = [Double](repeating: 0, count: coords.count * 2)
            for (i, c) in coords.enumerated() { pts[2 * i] = f.x(c.lng); pts[2 * i + 1] = f.y(c.lat) }
            var lp = [Double](repeating: 0, count: lights.count * 2)
            for (i, c) in lights.enumerated() { lp[2 * i] = f.x(c.lng); lp[2 * i + 1] = f.y(c.lat) }
            let b = MapGeo.encodeRoute(frameId: f.id, pts: pts, maxPts: 20000, lights: lp)
            DispatchQueue.main.async {
                guard serial == self.routeBuildSerial else { return }
                self.routeId = (self.routeId + 1) & 0xFF
                self.routeBytes = b
                self.routeAcked = false
                self.routeInfo = "路线 #\(self.routeId)：\(coords.count) 个点、\(lights.count) 个红绿灯 → \(max(1, b.count / 1024)) KB"
                self.sendRoute()
            }
        }
        return true
    }

    private func sendRoute() {
        guard let b = routeBytes, enabled else { return }
        routeSentAt = Date()
        BleLink.shared.sendBulk(type: MapFeeder.TYPE_ROUTE, id: routeId, data: b)
    }

    // MARK: - 原路线

    /// 开始导航时调用：把导入的分享路线发给圆屏画成细线；nil = 不显示
    func setGhost(_ coords: [(lat: Double, lng: Double)]?) {
        ghostCoords = coords
        ghostBytes = nil; ghostAcked = false
        if coords == nil { BleLink.shared.send("#o"); return }
        encodeGhost()
    }

    private func encodeGhost() {
        guard let f = frame, let c = ghostCoords, c.count >= 2 else { return }
        var pts = [Double](repeating: 0, count: c.count * 2)
        for (i, p) in c.enumerated() { pts[2 * i] = f.x(p.lng); pts[2 * i + 1] = f.y(p.lat) }
        ghostBytes = MapGeo.encodeRoute(frameId: f.id, pts: pts, maxPts: 5000)
        ghostId = (ghostId + 1) & 0xFF
        ghostAcked = false
        sendGhost()
    }

    private func sendGhost() {
        guard let b = ghostBytes, enabled else { return }
        ghostSentAt = Date()
        BleLink.shared.sendBulk(type: MapFeeder.TYPE_GHOST, id: ghostId, data: b)
    }

    // MARK: - 确认与重发

    /// 圆屏回复 "K,类型,编号"：这一份收齐了
    func onAck(type: Int, id: Int) {
        if haveChunk, chunkBytes != nil, BleLink.shared.isReady,
           readinessState.acknowledge(.init(type: type, id: id), at: Date()) {
            chunkAcked = true
            confirmedCenter = (chunkCx, chunkCy)
            publishReadiness(); status = readiness.title
            MapPipelineTrace.event("map-ack", ["type": type, "id": id, "buildings": chunkBytes.map(RasterPacket.isBuilding) ?? false])
        }
        if type == MapFeeder.TYPE_ROUTE && id == routeId { routeAcked = true }
        if type == MapFeeder.TYPE_GHOST && id == ghostId { ghostAcked = true }
    }

    /// 蓝牙重新连上 / 小地图重新打开：圆屏可能重启过，全部重发
    func resendAll() {
        chunkAcked = false; routeAcked = false; ghostAcked = false
        confirmedCenter = nil
        readinessState.disconnect()
        // New ID on every reconnection: a delayed K from the previous connection
        // cannot confirm the retained packet before it has actually been resent.
        if chunkBytes != nil {
            chunkId = (chunkId + 1) & 0xFF
            readinessState.accept(.init(type: chunkType, id: chunkId))
        }
        publishReadiness()
        sendChunk(); sendRoute(); sendGhost()
    }

    private func checkResend() {
        let b = BleLink.shared
        if !b.isReady || b.bulkPending { return }
        if chunkBytes != nil && !chunkAcked && Date().timeIntervalSince(chunkSentAt) > 2 { sendChunk() }
        if routeBytes != nil && !routeAcked && Date().timeIntervalSince(routeSentAt) > RESEND { sendRoute() }
        if ghostBytes != nil && !ghostAcked && Date().timeIntervalSince(ghostSentAt) > RESEND { sendGhost() }
    }

    /// 高德坐标 → 小地图平面坐标（米）；还没有坐标系时返回 nil
    func toFrame(_ lat: Double, _ lng: Double) -> (x: Int, y: Int)? {
        guard let f = frame else { return nil }
        return (Int(f.x(lng).rounded()), Int(f.y(lat).rounded()))
    }

    /// iOS v0.6 首页用的一句话状态
    var shortStatus: String {
        readiness.title
    }

    var infoText: String {
        if !enabled { return "小地图已关闭" }
        return "\(readiness.title)\n\(readiness.detail)\n\(chunkInfo)\(chunkAcked ? "（圆屏已确认）" : "")\n\(routeInfo)\(routeAcked ? "（圆屏已确认）" : "")\n\(offlineStatus)"
    }
}
