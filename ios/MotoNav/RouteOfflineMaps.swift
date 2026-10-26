import Foundation
import UIKit

/// Download one packet at a time; foreground requests take priority between packets.
/// Lifecycle/control state lives on main; worker cancellation is synchronized.
final class MapWorkToken {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class RouteOfflineMaps {
    let style: Int
    let frame: MapGeo.Frame, plan: RouteMapPlan, source: Int, buildings: Bool
    private let worker = DispatchQueue(label: "motonav.route-offline", qos: .utility)
    private let token = MapWorkToken()
    private var jobToken: MapWorkToken?
    private let foregroundBusy: () -> Bool
    private let onReady: (RouteMapPlan.Node) -> Void
    private let onStatus: (String) -> Void
    private let onProgress: (RouteMapPreparation) -> Void
    private var ready: [Bool], baseReady: [Bool]
    private var target = 0, busy = false
    private var retryAt = Date.distantPast
    private var lastError: String?
    private var timer: Timer?
    init(frame: MapGeo.Frame, plan: RouteMapPlan, source: Int, buildings: Bool, style: Int = 1,
         foregroundBusy: @escaping () -> Bool, onReady: @escaping (RouteMapPlan.Node) -> Void,
         onStatus: @escaping (String) -> Void, onProgress: @escaping (RouteMapPreparation) -> Void = { _ in }) {
        self.style = MapStylePolicy.normalize(style)
        self.frame = frame; self.plan = plan; self.source = source
        self.buildings = MapStylePolicy.usesBuildings(self.style, enabled: buildings)
        self.foregroundBusy = foregroundBusy; self.onReady = onReady; self.onStatus = onStatus
        self.onProgress = onProgress
        ready = [Bool](repeating: false, count: plan.nodes.count); baseReady = ready
    }
    func read(_ node: RouteMapPlan.Node) -> Data? {
        RouteMapCache.shared.read(frame: frame, source: source, buildings: buildings, node: node, style: style)
            ?? (buildings ? RouteMapCache.shared.read(frame: frame, source: source, buildings: false, node: node, style: style) : nil)
    }
    func update(_ index: Int) { target = max(0, min(plan.nodes.count - 1, index)) }
    func start() {
        busy = true; onStatus("沿线离线地图：检查已有地图包…")
        publish(.checking, detail: "正在核对已保存地图的完整性与风格")
        worker.async {
            var done = [Bool](repeating: false, count: self.plan.nodes.count), base = done
            for (i, node) in self.plan.nodes.enumerated() {
                if self.token.isCancelled { return }
                done[i] = RouteMapCache.shared.read(frame: self.frame, source: self.source, buildings: self.buildings, node: node, style: self.style) != nil
                base[i] = done[i] || RouteMapCache.shared.read(frame: self.frame, source: self.source, buildings: false, node: node, style: self.style) != nil
            }
            DispatchQueue.main.async {
                guard !self.token.isCancelled else { return }
                self.ready = done; self.baseReady = base; self.busy = false
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pump() }
                self.onReady(self.plan.nodes[self.target]); self.pump()
            }
        }
    }
    private func publish(_ phase: RouteMapPreparation.Phase, detail: String) {
        onProgress(RouteMapPreparation(phase: phase, ready: baseReady.filter { $0 }.count,
            total: ready.count, detailedReady: ready.filter { $0 }.count,
            retryAt: phase == .retrying ? retryAt : nil, error: lastError, detail: detail))
    }
    private func pump() {
        if busy, foregroundBusy() { jobToken?.cancel() }
        guard !token.isCancelled, !busy else { return }
        let count = ready.filter { $0 }.count, baseCount = baseReady.filter { $0 }.count
        if count == ready.count {
            onStatus("沿线底图已全部离线：\(count)/\(ready.count) 块\(style == MapStylePolicy.gta5 ? "（完整矢量路网）" : "（2 米/像素）")")
            lastError = nil; publish(.complete, detail: "当前风格的沿线地图均已保存")
            timer?.invalidate(); timer = nil; return
        }
        guard UIApplication.shared.applicationState == .active else {
            onStatus("沿线离线地图：\(baseCount)/\(ready.count) 块可用；回到 App 前台继续下载")
            publish(.paused, detail: "回到 App 前台继续准备；已保存地图可继续使用"); return
        }
        guard !foregroundBusy() else {
            publish(.paused, detail: "正在优先准备圆屏当前地图；完成后自动继续沿线准备"); return
        }
        guard Date() >= retryAt else {
            publish(.retrying, detail: "保留已保存地图，稍后自动重试"); return
        }
        let indexes = Array(target..<ready.count) + Array(0..<target)
        guard let i = indexes.first(where: { !baseReady[$0] }) ?? indexes.first(where: { !ready[$0] }) else { return }
        busy = true
        let node = plan.nodes[i]
        let includeBuildings = buildings && baseCount == baseReady.count
        lastError = nil
        publish(.preparing, detail: "正在准备第 \(i + 1) 块\(includeBuildings ? "的建筑细节" : "地图")")
        onStatus("沿线离线地图：\(baseCount)/\(ready.count) 块可用，下载第 \(i + 1) 块\(includeBuildings ? "（补齐建筑）" : "（普通底图优先）")")
        let job = MapWorkToken(); jobToken = job
        worker.async {
            let result = Result { () throws -> Data in
                if self.token.isCancelled { throw MapProcessingError.cancelled }
                let packet: Data
                if self.style == MapStylePolicy.gta5 {
                    packet = try GtaVectorMaps.build(self.frame, cx: node.x, cy: node.y,
                        shouldCancel: { self.token.isCancelled || job.isCancelled }).bytes
                } else if self.source == MapFeeder.SRC_AMAP {
                    packet = try AmapSdkRaster.build(self.frame, cx: node.x, cy: node.y, includeBuildings: includeBuildings,
                        shouldCancel: { self.token.isCancelled || job.isCancelled }, onBaseReady: { base in
                            guard !self.token.isCancelled else { return }
                            do {
                                try RouteMapCache.shared.store(base, frame: self.frame, source: self.source, node: node, style: self.style)
                                DispatchQueue.main.async {
                                    if !self.token.isCancelled {
                                        self.baseReady[i] = true; self.onReady(node)
                                        self.publish(.preparing, detail: "第 \(i + 1) 块底图已保存，继续准备细节")
                                    }
                                }
                            } catch { /* The final store reports storage errors in onStatus. */ }
                        }, onBuildingStatus: { message in
                            DispatchQueue.main.async { if !self.token.isCancelled { self.onStatus(message) } }
                        }, style: self.style).bytes
                } else {
                    throw MapProcessingError.invalid("沿线预下载仅支持高德底图")
                }
                if self.token.isCancelled { throw MapProcessingError.cancelled }
                try RouteMapCache.shared.store(packet, frame: self.frame, source: self.source, node: node, style: self.style)
                return packet
            }
            DispatchQueue.main.async {
                guard !self.token.isCancelled else { return }
                self.busy = false
                switch result {
                case .success(let packet):
                    self.baseReady[i] = true
                    self.ready[i] = !self.buildings || RasterPacket.isBuilding(packet)
                    self.retryAt = self.ready[i] || !includeBuildings ? .distantPast : Date().addingTimeInterval(15)
                    self.onReady(node)
                    if !self.ready[i] && includeBuildings {
                        self.onStatus("沿线普通底图已保存；建筑未完成，稍后重试")
                        self.lastError = "建筑细节尚未完成"
                        self.publish(.retrying, detail: "沿线普通底图已保存，稍后补齐建筑细节")
                    } else {
                        self.publish(self.ready.allSatisfy { $0 } ? .complete : .preparing,
                            detail: self.ready.allSatisfy { $0 } ? "当前风格的沿线地图均已保存" : "继续准备下一块沿线地图")
                    }
                case .failure(MapProcessingError.cancelled):
                    self.retryAt = .distantPast
                    self.publish(.paused, detail: "优先保障圆屏当前地图，沿线准备稍后继续")
                case .failure(let error):
                    self.retryAt = Date().addingTimeInterval(15)
                    self.onStatus("沿线离线地图：\(error.localizedDescription)，保留已保存地图")
                    self.lastError = error.localizedDescription
                    self.publish(.retrying, detail: "已保存地图仍可用，15 秒后自动重试")
                }
            }
        }
    }
    func close() { token.cancel(); jobToken?.cancel(); timer?.invalidate(); timer = nil }
}
