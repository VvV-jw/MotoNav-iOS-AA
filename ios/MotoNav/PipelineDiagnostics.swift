import Foundation
import CoreFoundation

/// Summarizes observed stages independently. End-to-end transfer includes queue
/// time and ACK wait; the six percentiles must never be added into a frame time.
/// Missing or evicted evidence is explicitly unknown, never an estimated FPS.
struct PipelineSummary {
    struct Stage {
        let stage: String, metric: String, label: String, count: Int, status: String
        let p50Ms: Double?, p95Ms: Double?
        var json: [String: Any] {
            ["stage": stage, "metric": metric, "count": count, "status": status,
             "p50Ms": p50Ms.map { $0 as Any } ?? NSNull(), "p95Ms": p95Ms.map { $0 as Any } ?? NSNull()]
        }
        var detail: String {
            guard let p50 = p50Ms, let p95 = p95Ms else { return "样本 \(count)/\(PipelineSummary.minimumSamples)，暂无法判断" }
            return String(format: "样本 %d · 中位 %.0f ms · P95 %.0f ms", count, p50, p95)
        }
    }
    static let minimumSamples = 5
    let stages: [Stage], droppedSamples: Int
    var assessment: String { droppedSamples > 0 || stages.contains { $0.count < Self.minimumSamples } ? "unknown" : "observedTimings" }
    var reason: String { droppedSamples > 0 ? "recordingTruncated" : (assessment == "unknown" ? "insufficientSamples" : "completeObservedStages") }
    var title: String { assessment == "unknown" ? "样本不足，暂无法判断卡顿原因" : "各阶段耗时已汇总" }
    var detail: String {
        if droppedSamples > 0 { return "记录已截断（淘汰 \(droppedSamples) 条）；以下仅为保留片段，无法判断整次运行。" }
        if assessment == "unknown" { return "每阶段至少需要 5 个有效样本；缺少圆屏回报时不会估算帧率。" }
        return "P95 表示 95% 的观测不超过此值。发送至确认包含排队和确认等待，各项不能相加，也不能据此判定唯一原因。"
    }
    var json: [String: Any] {
        ["schema": "motonav.pipeline.summary.v1", "minSamples": Self.minimumSamples,
         "droppedSamples": droppedSamples, "assessment": assessment, "reason": reason,
         "stages": stages.map(\.json)]
    }
    static func evaluate(events: [[String: Any]], droppedSamples: Int) -> PipelineSummary {
        let definitions = [
            ("phonePreparation", "preparationMs", "手机地图准备", "fetch-complete"),
            ("bleQueue", "queueWaitMs", "蓝牙排队", "bulk-write"),
            ("bleTransfer", "transferMs", "发送至确认（含排队）", "bulk-ack"),
            ("bleAck", "ackWaitMs", "末包至确认", "bulk-ack"),
            ("screenFrame", "frameMs", "圆屏每帧绘制", "screen-stats"),
            ("screenPush", "pushMs", "圆屏推送显示", "screen-stats")]
        let dropped = max(0, droppedSamples)
        let stages = definitions.map { definition -> Stage in
            let (name, metric, label, event) = definition
            let values = events.compactMap { row -> Double? in
                guard row["event"] as? String == event, let fields = row["fields"] as? [String: Any],
                      let value = fields[metric] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                      (0...1_000_000_000).contains(value.doubleValue) else { return nil }
                return value.doubleValue
            }.sorted()
            let sufficient = values.count >= minimumSamples
            func percentile(_ p: Double) -> Double? { sufficient ? values[max(0, Int(ceil(Double(values.count) * p)) - 1)] : nil }
            return Stage(stage: name, metric: metric, label: label, count: values.count,
                status: dropped > 0 ? "truncated" : (sufficient ? "sufficient" : "insufficient"),
                p50Ms: percentile(0.50), p95Ms: percentile(0.95))
        }
        return PipelineSummary(stages: stages, droppedSamples: dropped)
    }
}

/// Opt-in, bounded metadata only. This collector never accepts map bytes, locations,
/// notification payloads, credentials, device identifiers or arbitrary error text.
/// Foundation-only so the same production collector is exercised by desktop tests.
final class PipelineDiagnostics: @unchecked Sendable {
    static let shared = PipelineDiagnostics()

    private let lock = NSLock()
    private let exportLock = NSLock()
    private let clock: () -> TimeInterval
    private let capacity: Int
    private let byteLimit: Int
    private var enabled = false
    private var start: TimeInterval = 0
    private var entries: [[String: Any]] = []
    private var sizes: [Int] = []
    private var storedBytes = 0
    private var dropped = 0
    private var session = UUID().uuidString
    private var preparation: [Int: TimeInterval] = [:]
    private struct Capture {
        let key: String
        let number: Int
        let began: TimeInterval
        var baseAt: TimeInterval?
    }
    private var capture: Capture?
    private var captureNumber = 0
    private struct Transfer {
        let id: Int
        let queued: TimeInterval
        var firstWrite: TimeInterval?
        var lastWrite: TimeInterval?
    }
    private var transfers: [Int: Transfer] = [:]

    // An allowlist also prevents accidental future callers from exporting sensitive
    // fields through the existing general-purpose trace API.
    private static let eventStages: [String: String] = [
        "recording-start": "phone", "recording-stop": "phone",
        "preparation-state": "phone", "route-coverage": "phone", "prefetch-policy": "phone",
        "view-coverage": "phone", "movement-cancel": "phone",
        "packet-outside-view": "phone", "base-kept-inflight": "phone",
        "fetch-start": "phone", "fetch-complete": "phone", "fetch-failed": "phone",
        "capture-start": "phone", "tile-start": "phone", "tile-ready": "phone", "tile-failed": "phone",
        "base-ready": "phone", "buildings-ready": "phone",
        "map-send": "phone", "map-ack": "ble", "bulk-queued": "ble",
        "bulk-write": "ble", "bulk-write-response": "ble", "bulk-write-error": "ble",
        "bulk-write-timeout": "ble", "bulk-ack": "ble", "bulk-cancel": "ble",
        "link-ready": "ble", "connection-lost": "ble", "connection-failed": "ble",
        "connection-request": "ble", "connection-restored": "ble", "bluetooth-state": "ble",
        "connection-timeout": "ble", "screen-stats": "screen", "screen-profile": "screen"
    ]
    private static let numericFields: Set<String> = [
        "kmh", "serial", "source", "theme", "type", "id", "seq", "parts", "bytes",
        "attempt", "commandsQueued", "bulkQueued", "maxWrite", "errorCode", "state",
        "retry", "reason", "fps", "frameMs", "pushMs", "mhz", "mapMs", "overlayMs",
        "fast", "baseMs", "cores", "preparationMs", "queueWaitMs", "transferMs", "ackWaitMs",
        "baseLayerMs", "roadsMs", "routeMs", "markersMs", "vignetteMs", "symbolsMs",
        "ringMs", "speedMs", "lanesMs", "badgeMs", "hintsMs",
        "job", "size", "seconds", "components", "pixels", "captureMs", "buildingMs",
        "availableBlocks", "totalBlocks", "coverageState", "coverageChecks"
    ]
    private static let boolFields: Set<String> = [
        "ready", "buildings", "baseReady", "needsCoverage", "nextBlock", "response", "automatic",
        "sentCovered", "confirmedCovered", "wifiOnly", "chargingOnly"
    ]

    init(capacity: Int = 512, byteLimit: Int = 256 * 1024,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = min(1024, max(1, capacity))
        self.byteLimit = min(512 * 1024, max(2048, byteLimit))
        self.clock = clock
    }

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// Every explicit enable starts a fresh session; disabling preserves the final
    /// bounded snapshot for export and stops collecting immediately.
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled != value else { return }
        if value {
            entries.removeAll(keepingCapacity: true); sizes.removeAll(keepingCapacity: true)
            preparation.removeAll(); transfers.removeAll(); capture = nil; captureNumber = 0
            storedBytes = 0; dropped = 0
            session = UUID().uuidString; start = clock(); enabled = true
            append("recording-start", fields: [:], now: start)
        } else {
            append("recording-stop", fields: [:], now: clock())
            enabled = false; preparation.removeAll(); transfers.removeAll(); capture = nil
        }
    }

    func event(_ name: String, _ fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, Self.eventStages[name] != nil else { return }
        let now = clock()
        var safe = Self.sanitize(fields)
        // Capture jobs are internally generated UUIDs. Correlate the one active
        // screenshot lease in memory and export a short numeric job, never a UUID.
        if let key = fields["job"] as? String, UUID(uuidString: key) != nil {
            if name == "capture-start" {
                captureNumber = captureNumber < 1_000_000_000 ? captureNumber + 1 : 1
                capture = Capture(key: key, number: captureNumber, began: now)
            }
            if var active = capture, active.key == key {
                safe["job"] = active.number
                if name == "base-ready" {
                    safe["captureMs"] = Self.milliseconds(now - active.began)
                    active.baseAt = now; capture = active
                } else if name == "buildings-ready" {
                    safe["captureMs"] = Self.milliseconds(now - active.began)
                    if let base = active.baseAt { safe["buildingMs"] = Self.milliseconds(now - base) }
                    capture = nil
                }
            }
        }
        if let serial = Self.integer(safe["serial"]) {
            if name == "fetch-start" {
                // A new request supersedes the old one. Never retain unbounded IDs.
                preparation = [serial: now]
            } else if name == "fetch-complete" || name == "fetch-failed" {
                if let began = preparation.removeValue(forKey: serial) {
                    safe["preparationMs"] = Self.milliseconds(now - began)
                }
            }
        }
        var omitIntermediateWrite = false
        if let type = Self.integer(safe["type"]), (1...4).contains(type),
           let id = Self.integer(safe["id"]), (0...255).contains(id) {
            if name == "bulk-queued" { transfers[type] = Transfer(id: id, queued: now) }
            if var transfer = transfers[type], transfer.id == id {
                if name == "bulk-write" {
                    let firstWrite = transfer.firstWrite == nil
                    if transfer.firstWrite == nil {
                        transfer.firstWrite = now
                        safe["queueWaitMs"] = Self.milliseconds(now - transfer.queued)
                    }
                    transfer.lastWrite = now; transfers[type] = transfer
                    if !firstWrite, let seq = Self.integer(safe["seq"]), let parts = Self.integer(safe["parts"]),
                       parts > 2, seq > 0, seq < parts - 1 { omitIntermediateWrite = true }
                } else if name == "bulk-ack" {
                    safe["transferMs"] = Self.milliseconds(now - transfer.queued)
                    if let written = transfer.lastWrite { safe["ackWaitMs"] = Self.milliseconds(now - written) }
                    transfers.removeValue(forKey: type)
                }
            }
        }
        if ["connection-lost", "connection-failed", "connection-request", "bulk-cancel"].contains(name) {
            if name == "bulk-cancel", let type = Self.integer(safe["type"]) { transfers.removeValue(forKey: type) }
            else { transfers.removeAll() }
        }
        if !omitIntermediateWrite { append(name, fields: safe, now: now) }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, n.doubleValue.isFinite,
              n.doubleValue >= Double(Int.min), n.doubleValue < Double(Int.max) else { return nil }
        return n.intValue
    }

    private static func milliseconds(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (max(0, value) * 1000).rounded(.toNearestOrAwayFromZero)
    }

    private static func sanitize(_ fields: [String: Any]) -> [String: Any] {
        var safe: [String: Any] = [:]
        for (key, value) in fields {
            if numericFields.contains(key), let n = value as? NSNumber,
               CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, abs(n.doubleValue) <= 1_000_000_000 {
                safe[key] = n.doubleValue
            } else if boolFields.contains(key), let b = value as? Bool { safe[key] = b }
        }
        return safe
    }

    private func append(_ name: String, fields: [String: Any], now: TimeInterval) {
        let row: [String: Any] = ["event": name, "stage": Self.eventStages[name] ?? "phone",
                                  "elapsedMs": Self.milliseconds(now - start), "fields": fields]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              data.count <= byteLimit else { dropped += 1; return }
        entries.append(row); sizes.append(data.count); storedBytes += data.count
        while entries.count > capacity || storedBytes > byteLimit {
            entries.removeFirst(); storedBytes -= sizes.removeFirst(); dropped += 1
        }
    }

    /// Only actual S/Q notifications appear as screen samples. Empty sessions and
    /// simulated replay never acquire an invented device FPS or timing result.
    func jsonData(appVersion: String, firmwareVersion: String? = nil) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let screenCount = entries.filter { ($0["event"] as? String) == "screen-stats" }.count
        let profileCount = entries.filter { ($0["event"] as? String) == "screen-profile" }.count
        let report: [String: Any] = [
            "schema": "motonav.pipeline.v1", "session": session, "recording": enabled,
            "appVersion": Self.versionToken(appVersion),
            "firmwareVersion": firmwareVersion.map(Self.versionToken) ?? "unknown",
            "sampleCount": entries.count, "droppedSamples": dropped,
            "limits": ["samples": capacity, "eventBytes": byteLimit],
            "screenSampleCount": screenCount, "screenProfileCount": profileCount,
            "hasScreenMeasurements": screenCount + profileCount > 0,
            "privacy": "No credentials, coordinates, map bytes, device IDs or raw messages.",
            "summary": PipelineSummary.evaluate(events: entries, droppedSamples: dropped).json,
            "events": entries
        ]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }

    func summary() -> PipelineSummary {
        lock.lock(); let snapshot = entries, removed = dropped; lock.unlock()
        return PipelineSummary.evaluate(events: snapshot, droppedSamples: removed)
    }

    private static func versionToken(_ value: String) -> String {
        let value = value.hasPrefix("iOS v") ? String(value.dropFirst(4)) : value
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        guard !value.isEmpty, value.count <= 64, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "unknown" }
        return value
    }

    /// Throws instead of terminating on denied storage/full disk. Export only
    /// writes on explicit user request and retains no more than three reports.
    func export(appVersion: String, firmwareVersion: String? = nil, directory: URL? = nil) throws -> URL {
        exportLock.lock(); defer { exportLock.unlock() }
        let root: URL
        if let directory = directory { root = directory }
        else {
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                .map { $0.appendingPathComponent("diagnostics", isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("motonav-diagnostics", isDirectory: true)
        }
        let data = try jsonData(appVersion: appVersion, firmwareVersion: firmwareVersion)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Do not delete any unrelated user file in a supplied/export directory.
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
        let reports = files.filter { $0.lastPathComponent.hasPrefix("MotoNav-diagnostics-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l == r ? lhs.lastPathComponent > rhs.lastPathComponent : l > r
            }
        // Make room before writing; a deletion failure must not allow repeated
        // exports to bypass the three-file storage bound.
        for old in reports.dropFirst(2) { try FileManager.default.removeItem(at: old) }
        let url = root.appendingPathComponent("MotoNav-diagnostics-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Parse only known numeric firmware statistics. Missing/invalid metrics stay
    /// absent; this does not estimate FPS from phone callbacks or BLE throughput.
    static func screenFields(_ parts: [String]) -> [String: Any]? {
        guard parts.first == "S", parts.count >= 4,
              let fps = Double(parts[1]), fps.isFinite, (0...240).contains(fps),
              let frame = Double(parts[2]), frame.isFinite, (0...60_000).contains(frame),
              let push = Double(parts[3]), push.isFinite, (0...60_000).contains(push) else { return nil }
        var result: [String: Any] = ["fps": fps, "frameMs": frame, "pushMs": push]
        let names = [4: "mhz", 5: "mapMs", 6: "overlayMs", 7: "fast", 8: "baseMs", 9: "cores"]
        for (index, name) in names where parts.indices.contains(index) {
            if let value = Double(parts[index]), value.isFinite, (0...60_000).contains(value) { result[name] = value }
        }
        return result
    }

    /// aa.7 Q values are integer tenths of a millisecond per frame, in the exact
    /// profMark(0...10) order in the firmware. These are not phone-side estimates.
    static func screenProfileFields(_ parts: [String]) -> [String: Any]? {
        guard parts.first == "Q", parts.count >= 12 else { return nil }
        let names = ["baseLayerMs", "roadsMs", "routeMs", "markersMs", "vignetteMs", "symbolsMs",
                     "ringMs", "speedMs", "lanesMs", "badgeMs", "hintsMs"]
        var result: [String: Any] = [:]
        for (index, name) in names.enumerated() {
            guard let tenths = Int(parts[index + 1]), (0...600_000).contains(tenths) else { return nil }
            result[name] = Double(tenths) / 10
        }
        return result
    }
}

/// Compatibility facade used by phone map preparation and BLE stages. Packet
/// recording intentionally observes only length/type; raw wire.bin is never saved.
enum MapPipelineTrace {
    static var isEnabled: Bool { PipelineDiagnostics.shared.isEnabled }
    static func setEnabled(_ value: Bool) { PipelineDiagnostics.shared.setEnabled(value) }
    static func event(_ name: String, _ fields: [String: Any] = [:]) { PipelineDiagnostics.shared.event(name, fields) }
    static func packet(_ bytes: Data, type: Int, id: Int, ready: Bool) {
        event("map-send", ["type": type, "id": id, "bytes": bytes.count, "ready": ready])
    }
    static func export(appVersion: String, firmwareVersion: String? = nil) throws -> URL {
        try PipelineDiagnostics.shared.export(appVersion: appVersion, firmwareVersion: firmwareVersion)
    }
}
