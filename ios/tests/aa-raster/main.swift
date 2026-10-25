import Foundation
import zlib

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}
func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); preconditionFailure(message) } catch { checks += 1 }
}
let n = RasterPacket.size
let pixels = (0..<(n*n)).map { UInt8($0 & 15) }
let palette = (0..<16).map { $0 * 4369 }
let packet = MapGeo.encodeRaster(frameId: 77, x0: -1200, y0: 1200, w: n, h: n,
                                mmPerPx: 2000, idx: pixels, pal: palette)
check(packet.count > 480_000 && packet.count <= RasterPacket.maxBytes, "Retain a dense full-detail map exceeding the previous 480 KB cap")
check(RasterPacket.valid(packet), "Full 1200² map is valid without resolution or road deletion")
check(RasterPacket.decode(packet) == pixels, "Every dense map pixel survives RLE")
check(RasterPacket.palette(packet) == palette, "All 16 RGB565 colours survive")
check(RasterPacket.forLegacy(packet) == packet, "A palette packet is never misread as building pixels")
check(!RasterPacket.valid(Data(packet.dropLast())), "Reject incomplete full map")
var trailing = packet; trailing.append(0)
check(!RasterPacket.valid(trailing), "Reject trailing data")
var overflow = packet; overflow.append(contentsOf: [UInt8](repeating: 0, count: RasterPacket.maxBytes))
check(!RasterPacket.valid(overflow), "Bound oversized map allocation")
check(RasterTransport.pack(packet, supported: false) == packet, "Old firmware receives unwrapped bytes")
let wire = RasterTransport.pack(packet, supported: true)
check(wire.count < packet.count / 10, "Lossless compression substantially reduces repeated dense detail")
check(Array(wire.prefix(4)) == [0x52,0x5a,0x31,1], "Exact RZ1 version header")
let wb = [UInt8](wire)
let declared = Int(wb[4]) | Int(wb[5]) << 8 | Int(wb[6]) << 16 | Int(wb[7]) << 24
check(declared == packet.count, "Little-endian uncompressed byte count")
check(wb[8] == 0x78 && ((Int(wb[8]) << 8) | Int(wb[9])) % 31 == 0, "RFC1950 zlib header, not raw deflate")
var restored = [UInt8](repeating: 0, count: declared), length = uLongf(declared)
let status = restored.withUnsafeMutableBufferPointer { destination in
    wire.dropFirst(8).withUnsafeBytes { source in
        uncompress(destination.baseAddress, &length, source.bindMemory(to: UInt8.self).baseAddress, uLong(wire.count-8))
    }
}
check(status == Z_OK && Int(length) == packet.count && Data(restored) == packet, "ESP-compatible zlib restores exact raster including palette")
let base = MapGeo.encodeRaster(frameId: 77, x0: -1200, y0: 1200, w: n, h: n,
                              mmPerPx: 2000, idx: [UInt8](repeating: 1, count: n*n))
check(RasterTransport.pack(base, supported: true) == base, "Do not wrap material packets that firmware does not negotiate for RZ1")
check(RasterTransport.pack(Data(packet.dropLast()), supported: true) == Data(packet.dropLast()), "Never compress a damaged packet")

// Expected palette and index hash generated with Android aa.4 OriginalMapColors.java.
// Exercise a thin diagonal road, antialias greys, park/water and minority label colours.
var raw = [UInt32](repeating: 0, count: n*n)
for y in 0..<n { for x in 0..<n {
    var c: UInt32 = 0xffeeeeee
    if x < 200 { c = 0xffaaccee }
    if y >= 800 { c = 0xff99bb88 }
    let distance = abs(x-y)
    if distance < 12 { c = 0xffffffff }
    else if distance < 20 { let a = UInt32(238+(20-distance)*2); c = 0xff000000 | a << 16 | a << 8 | a }
    if y >= 500 && y < 520 { c = 0xfff4c64e }
    if x > 300 && x < 400 && y % 24 < 2 { let a = UInt32(80+(x%16)*7); c = 0xff000000 | a << 16 | a << 8 | a }
    raw[y*n+x] = c
} }
let q = try MapStyles.original(raw, shouldCancel: { false })
let androidPalette = [63017,61309,40433,44669,48631,63422,65535,27469,35953,44405,31695,33840,40179,42292,21130,23243]
var hash: UInt64 = 0xcbf29ce484222325
for index in q.indices { hash = (hash ^ UInt64(index)) &* 0x100000001b3 }
check(q.palette == androidPalette, "Weighted median-cut palette exactly matches Android")
check(hash == 6992976379912052201, "All 1.44 million quantized indices exactly match Android")
check(q.palette[Int(q.indices[600*n+600])] == 0xffff, "Thin white road remains white")
rejects("Cancellation interrupts expensive quantization") { _ = try MapStyles.original(raw, shouldCancel: { true }) }
rejects("Reject an empty screenshot") { _ = try MapStyles.original([], shouldCancel: { false }) }
let roads = MapStyles.minimal(raw, size: n)
check(roads.allSatisfy { $0 <= 1 }, "Minimal map contains only road/background")
check(roads[300*n+300] == 1 && roads[400*n+100] == 0, "Minimal preserves roads and excludes water")

let frame = MapGeo.Frame(refLat: 31, refLng: 121, id: 77)
let node = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-aa-raster-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: folder) }
let cache = RouteMapCache(root: folder)
try cache.store(packet, frame: frame, source: 3, node: node, style: MapStylePolicy.original)
check(cache.read(frame: frame, source: 3, buildings: false, node: node, style: 0) == packet, "Full dense original map cache roundtrip")
check(cache.read(frame: frame, source: 3, buildings: false, node: node, style: 1) == nil, "Original cache cannot appear as Vice City")
check(cache.read(frame: frame, source: 3, buildings: false, node: node, style: 2) == nil, "Raster cache cannot appear as GTA vector roads")
rejects("Reject a material packet stored as original") { try cache.store(base, frame: frame, source: 3, node: node, style: 0) }
rejects("Reject a palette packet stored as Vice City") { try cache.store(packet, frame: frame, source: 3, node: node, style: 1) }
rejects("Reject a raster packet stored as GTA vectors") { try cache.store(packet, frame: frame, source: 3, node: node, style: 2) }
let keys = [0,1,2,5,11].map { MapStylePolicy.cacheKey(theme: $0, buildings: false) }
check(Set(keys).count == 5, "All five styles have independent cache identities")
check(MapStylePolicy.normalize(99) == 1 && !MapStylePolicy.usesBasemap(11), "Invalid themes and radar policy")
check(!MapStylePolicy.usesAmapCapture(2) && MapStylePolicy.usesAmapCapture(0), "GTA uses vectors and original uses SDK pixels")
check(!MapStylePolicy.usesBuildings(0, enabled: true) && MapStylePolicy.usesBuildings(1, enabled: true), "Only Vice City extracts buildings")
check(MapCoveragePolicy.covers(x: 1000, y: 0, cx: 0, cy: 0, kmh: 120, half: MapStylePolicy.half(2)), "GTA retains the usable larger viewport")
check(!MapCoveragePolicy.covers(x: 1000, y: 0, cx: 0, cy: 0, kmh: 120, half: MapStylePolicy.half(0)), "Raster refreshes before leaving its smaller viewport")
check(!MapCoveragePolicy.needsRefresh(x: 500, y: 0, cx: 0, cy: 0, bearing: 90, kmh: 60, half: 2400), "GTA avoids unnecessary raster-frequency transfers")
check(MapCoveragePolicy.needsRefresh(x: 1600, y: 0, cx: 0, cy: 0, bearing: 90, kmh: 120, half: 2400), "GTA still prepares the next map before running out of coverage")
if let output = ProcessInfo.processInfo.environment["MOTONAV_TEST_OUTPUT"] {
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try packet.write(to: directory.appendingPathComponent("ios-dense-original-raw.bin"))
    try wire.write(to: directory.appendingPathComponent("ios-dense-original-rz1.bin"))
}
print("PASS aa raster: \(checks) checks; dense tile \(packet.count) -> \(wire.count) bytes; Android quantizer parity")
