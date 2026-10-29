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
