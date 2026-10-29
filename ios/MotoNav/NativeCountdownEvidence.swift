import Foundation

/// Evidence from a synchronous, SDK-validated response transaction. These values
/// remain diagnostic until the native colour/direction mapping is verified.
struct NativeCountdownEvidence: Equatable {
    let rawStatus: Int
    let seconds: Int
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
              let pathString = extra["pathID"] as? String, let path = UInt32(pathString) else { return nil }
        let bytes = [UInt8](signals)
        func word(_ offset:Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset+$1]) << (8*$1) }
        }
        var result:[NativeCountdownEvidence] = []
        for offset in stride(from:0,to:bytes.count,by:40) {
            guard word(offset) == path else { return nil }
            let status=Int(Int32(bitPattern:word(offset+4)))
            let remaining=Int(Int32(bitPattern:word(offset+8)))
            guard (-32768...32767).contains(status), (1...999).contains(remaining) else { return nil }
            result.append(.init(rawStatus:status,seconds:remaining))
        }
        return result
    }
}

/// An isolated-build diagnostic snapshot, never a source for navigation or BLE.
/// Explicit fields exclude keys, coordinates, road identifiers and SDK payloads.
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
        guard schema == 1, version == "0.15.18", build == 18, UUID(uuidString: runID) != nil,
              ["idle", "simulation", "gps"].contains(mode), active == (mode != "idle"),
              !active || owner != 0, uptime.isFinite, uptime >= 0,
              Set(counters.keys) == Set(Self.counterNames),
              !colourAndDirectionVerified, !roundDisplayCountdownEnabled else { return false }
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
