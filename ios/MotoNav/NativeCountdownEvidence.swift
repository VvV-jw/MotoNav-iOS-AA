import Foundation

/// Evidence from a synchronous, SDK-validated response transaction. These values
/// remain diagnostic unless the response also carries a direction that is already
/// in the round-display protocol's standard domain. Unknown SDK enum values are
/// deliberately not coerced into a display direction or colour.
struct NativeCountdownEvidence: Equatable {
    let rawStatus: Int
    let seconds: Int
    let pathID: UInt32
    let rawDirection: Int?
    let rawColor: Int?
    let rawFlag: Int?
    let rawCountDown: Int?

    init(rawStatus: Int, seconds: Int, pathID: UInt32 = 0,
         rawDirection: Int? = nil, rawColor: Int? = nil,
         rawFlag: Int? = nil, rawCountDown: Int? = nil) {
        self.rawStatus = rawStatus
        self.seconds = seconds
        self.pathID = pathID
        self.rawDirection = rawDirection
        self.rawColor = rawColor
        self.rawFlag = rawFlag
        self.rawCountDown = rawCountDown
    }

    /// The only direction values that are safe to put on the wire.  The iOS
    /// SDK's other `exitDir` values have not been proven to use the Android
    /// camera enum, so they are a hard no-output gate.
    var standardDirection: Int? {
        guard let rawDirection = rawDirection else { return nil }
        return [1, 2, 4].contains(rawDirection) ? rawDirection : nil
    }

    /// The native record status is emitted by the SDK's normalized signal
    /// vector.  Preserve unknown values for diagnostics, but never reinterpret
    /// them as red/green on the round display.
    var standardStatus: Int? {
        [-1, 1, 4].contains(rawStatus) ? rawStatus : nil
    }

    var wireSafe: Bool {
        standardDirection != nil && standardStatus != nil && (1...999).contains(seconds)
    }

    static func decode(body: Data, signals: Data, owner: UInt64, currentOwner: UInt64,
                       capturedAt: Double, now: Double) -> [NativeCountdownEvidence]? {
        guard owner != 0, owner == currentOwner, capturedAt.isFinite, now.isFinite,
              capturedAt >= 0, now >= capturedAt, now-capturedAt < 3,
              (2...262144).contains(body.count), !signals.isEmpty,
              signals.count % 40 == 0, signals.count <= 32*40,
              let response = (try? JSONSerialization.jsonObject(with:body)) as? [String:Any],
              let intersections = response["data"] as? [[String:Any]], !intersections.isEmpty,
              let ext = response["extend"] as? String, let extBytes = ext.data(using:.utf8),
              let extra = (try? JSONSerialization.jsonObject(with:extBytes)) as? [String:Any],
              let path = pathID(extra["pathID"]), path > 0 else { return nil }
        let metadata = bodyMetadata(intersections)
        // The provider's normalized vector has no documented per-element
        // identity with the JSON `lightInfos` array.  Only the one-light case
        // is safe to correlate today; leave all directions unknown for a
        // multi-light response instead of guessing by array position.
        let alignedMetadata = metadata.count == 1 && signals.count == 40 ? metadata : []
        let bytes = [UInt8](signals)
        func word(_ offset:Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset+$1]) << (8*$1) }
        }
        var result:[NativeCountdownEvidence] = []
        for (index, offset) in stride(from:0,to:bytes.count,by:40).enumerated() {
            guard word(offset) == path else { return nil }
            let status=Int(Int32(bitPattern:word(offset+4)))
            let remaining=Int(Int32(bitPattern:word(offset+8)))
            guard (-32768...32767).contains(status), (1...999).contains(remaining) else { return nil }
            let item = alignedMetadata.indices.contains(index) ? alignedMetadata[index] : nil
            result.append(.init(rawStatus:status, seconds:remaining, pathID:path,
                                rawDirection:item?.direction, rawColor:item?.color,
                                rawFlag:item?.flag, rawCountDown:item?.countDown))
        }
        return result
    }

    private struct BodyLightMetadata {
        let direction: Int?
        let color: Int?
        let flag: Int?
        let countDown: Int?
    }

    private static func pathID(_ value: Any?) -> UInt32? {
        if let n = value as? NSNumber, n.int64Value >= 0 {
            return UInt32(exactly: n.int64Value)
        }
        if let s = value as? String, let n = UInt64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return UInt32(exactly: n)
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func bodyMetadata(_ intersections: [[String:Any]]) -> [BodyLightMetadata] {
        var result: [BodyLightMetadata] = []
        for intersection in intersections {
            guard let infos = intersection["lightInfos"] as? [[String:Any]] else { continue }
            for info in infos {
                let statuses = (info["status"] as? [Any])?.compactMap { $0 as? [String:Any] } ?? []
                // Keep only fields whose names were observed in the native
                // parser.  The colour/flag values remain diagnostics until the
                // SDK enum is verified against real traffic-light captures.
                let current = statuses.first(where: {
                    guard let count = intValue($0["countDown"]) else { return false }
                    return count > 0
                }) ?? statuses.first
                result.append(.init(direction: intValue(info["exitDir"]),
                                    color: intValue(current?["color"]),
                                    flag: intValue(current?["flag"]),
                                    countDown: intValue(current?["countDown"])))
            }
        }
        return result
    }
}

/// The route-direction gate mirrors Android's `TrafficSignalPolicy` without
/// importing any SDK-specific enum.  A zero result means "do not emit".
enum NativeCountdownRoutePolicy {
    static func desiredMovement(turn: String, turnMetres: Int, lightMetres: Int) -> Int {
        guard turnMetres >= 0, (0...300).contains(lightMetres) else { return 0 }
        let movement: Int
        switch turn {
        case "S": movement = 4
        case "L", "SL": movement = 1
        case "R", "SR": movement = 2
        default: movement = 0
        }
        guard movement != 0 else { return 0 }
        let gap = turnMetres - lightMetres
        if abs(gap) <= 45 { return movement }
        return gap > 80 ? 4 : 0
    }
}

/// A short-lived, monotonic snapshot of validated native signal records.
///
/// The store intentionally exposes plain leases instead of depending on
/// `TrafficSignalWire.swift`, so the isolated decoder test can remain a
/// Foundation-only build. `NaviBridge` turns these leases into the existing
/// Android-compatible `#TL/#TLS` writer packets.
struct NativeCountdownSignalLease: Equatable {
    let status: Int
    let dir: Int
    let wait: Int
    let show: Int
    let remainingMs: Int64
    let expiresAtMs: Int64
}

final class NativeCountdownSignalStore {
    static let ttlMs: Int64 = 3_000
    private struct State {
        let status: Int
        let dir: Int
        let deadlineMs: Int64
    }
    private var states: [Int: State] = [:]
    private var acceptedAtMs: Int64 = -1

    var hasState: Bool { !states.isEmpty }

    func clear() {
        states.removeAll(keepingCapacity: true)
        acceptedAtMs = -1
    }

    @discardableResult
    func accept(_ evidence: [NativeCountdownEvidence], atMs: Int64) -> Bool {
        guard !evidence.isEmpty, evidence.count <= 4, atMs >= 0 else {
            clear()
            return false
        }
        guard states.isEmpty || atMs >= acceptedAtMs else {
            clear()
            return false
        }
        var next: [Int: State] = [:]
        for item in evidence {
            guard item.wireSafe, let dir = item.standardDirection,
                  let status = item.standardStatus,
                  !next.keys.contains(dir) else {
                clear()
                return false
            }
            let proposed = atMs + Int64(item.seconds) * 1_000
            guard proposed > atMs, proposed - atMs <= 999_000 else {
                clear()
                return false
            }
            let deadline: Int64
            if let old = states[dir], old.status == status,
               abs(proposed - old.deadlineMs) <= 1_800 {
                // Avoid extending a countdown on every 200 ms callback just
                // because the SDK reports rounded whole seconds.
                deadline = old.deadlineMs
            } else {
                deadline = proposed
            }
            next[dir] = State(status: status, dir: dir, deadlineMs: deadline)
        }
        states = next
        acceptedAtMs = atMs
        return true
    }

    func snapshot(nowMs: Int64) -> [NativeCountdownSignalLease]? {
        guard !states.isEmpty, nowMs >= acceptedAtMs,
              nowMs - acceptedAtMs < Self.ttlMs else {
            if !states.isEmpty { clear() }
            return nil
        }
        let expires = acceptedAtMs + Self.ttlMs
        let order = [1, 4, 2, 0]
        return order.compactMap { dir in
            guard let state = states[dir], expires > nowMs else { return nil }
            return NativeCountdownSignalLease(status: state.status, dir: state.dir,
                                              wait: 0, show: 0,
                                              remainingMs: max(0, state.deadlineMs - nowMs),
                                              expiresAtMs: expires)
        }
    }
}

/// A bounded diagnostic snapshot. It contains only counters and the last
/// normalized sample; raw SDK bytes, keys, coordinates and route identifiers
/// never leave the process.
struct NativeCountdownDiagnostics: Codable, Equatable {
    static let counterNames = ["parses", "events", "captures", "clears", "rejected",
                               "parseReturnedTrue", "parseReturnedFalse", "parseExceptions", "enabled", "epoch"]
    let schema: Int
    let version: String
    let build: Int
    let runID: String
    let active: Bool
    let mode: String
    let owner: UInt64
    let uptime: Double
    let counters: [String: UInt64]
    let decoderAccepted: UInt64
    let decoderRejected: UInt64
    let lastRawStatus: Int?
    let lastRawSeconds: Int?
    let sampleUptime: Double?
    let colourAndDirectionVerified: Bool
    let roundDisplayCountdownEnabled: Bool

    var isValid: Bool {
        guard schema == 1, version == "0.15.19", build == 19, UUID(uuidString: runID) != nil,
              ["idle", "simulation", "gps"].contains(mode), active == (mode != "idle"),
              !active || owner != 0, uptime.isFinite, uptime >= 0,
              Set(counters.keys) == Set(Self.counterNames) else { return false }
        if colourAndDirectionVerified && (!active || mode != "gps") { return false }
        if roundDisplayCountdownEnabled && !colourAndDirectionVerified { return false }
        if let status=lastRawStatus, let seconds=lastRawSeconds, let at=sampleUptime {
            return (-32768...32767).contains(status) && (1...999).contains(seconds)
                && at.isFinite && at >= 0 && at <= uptime
        }
        return lastRawStatus == nil && lastRawSeconds == nil && sampleUptime == nil
    }

    func encoded() -> Data? {
        guard isValid else { return nil }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        guard let result=try? encoder.encode(self), result.count <= 8192 else { return nil }
        return result
    }
}
