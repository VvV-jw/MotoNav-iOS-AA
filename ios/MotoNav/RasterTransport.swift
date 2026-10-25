import Foundation
import zlib

/// Standard zlib (not Apple's raw-deflate Compression format), matching Android/ESP RZ1.
/// Persistent caches retain the original packet; this envelope is negotiated per connection.
enum RasterTransport {
    static func pack(_ raw: Data, supported: Bool) -> Data {
        guard supported, raw.count >= 1024, raw.count <= RasterPacket.maxBytes,
              RasterPacket.hasPalette(raw), RasterPacket.valid(raw) else { return raw }
        var length = compressBound(uLong(raw.count))
        var compressed = [UInt8](repeating: 0, count: Int(length))
        let status = raw.withUnsafeBytes { input in
            compressed.withUnsafeMutableBufferPointer { output in
                compress2(output.baseAddress, &length, input.bindMemory(to: UInt8.self).baseAddress,
                          uLong(raw.count), Z_BEST_SPEED)
            }
        }
        guard status == Z_OK, Int(length) + 8 < raw.count else { return raw }
        var result = Data([0x52, 0x5a, 0x31, 1])
        let count = UInt32(raw.count)
        for shift in stride(from: 0, through: 24, by: 8) { result.append(UInt8(truncatingIfNeeded: count >> shift)) }
        result.append(contentsOf: compressed.prefix(Int(length)))
        return result
    }
}
