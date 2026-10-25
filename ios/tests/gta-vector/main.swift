import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message); checks += 1
}
func rejects(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); preconditionFailure(message) } catch { checks += 1 }
}
func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let raw = try Data(contentsOf: directory.appendingPathComponent("14_13484_6201.pbf"))
let expected = try Data(contentsOf: directory.appendingPathComponent("android-aa4-type1.bin"))
let features = try MvtTile.decode(raw)
let levels = Set(features.filter { $0.layer == "transportation" }.map { GtaVectorCodec.roadClass($0.tags["class"] ?? "") }.filter { $0 > 0 })
check(levels == Set(1...5), "Fixture includes all five road hierarchies")
let sourcePOI = features.filter { $0.layer == "poi" && GtaVectorCodec.poiClass($0.tags["class"] ?? "") > 0 }.count
check(sourcePOI > 0, "Real geographic POI classes, not invented symbols")
for feature in features {
    check(feature.extent > 0, "Positive extent")
    for path in feature.paths { check(path.count >= 2 && path.count % 2 == 0, "Complete geometry pairs") }
}
let lng = 13484.5 / 16384 * 360 - 180
let lat = atan(sinh(.pi * (1 - 2 * 6201.5 / 16384))) * 180 / .pi
let gcj = MapGeo.wgsToGcj(lat, lng)
let frame = MapGeo.Frame(refLat: gcj.lat, refLng: gcj.lng, id: 77)
let packet = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: [.init(z: 14, x: 13484, y: 6201, data: raw)])
check(packet == expected, "Swift output is byte-for-byte compatible with Android aa.4")
check(GtaVectorCodec.valid(packet, frame: 77, cx: 0, cy: 0), "Complete type-1 map")
check(!GtaVectorCodec.valid(packet, frame: 78, cx: 0, cy: 0), "Reject coordinate-frame mismatch")
check(!GtaVectorCodec.valid(packet, frame: 77, cx: 1, cy: 0), "Reject wrong cache origin")
check(GtaVectorCodec.roundMeters(-0.5) == 0 && GtaVectorCodec.roundMeters(-1.5) == -1 && GtaVectorCodec.roundMeters(0.5) == 1, "Negative ties match Android")
var classes = Set<Int>(), poiCount = 0, position = 12
let bytes = Array(packet)
while position < bytes.count {
    let cls = Int(bytes[position]), count = u16(bytes, position + 1); position += 3
    check(count > 0 && count <= 4000, "Bounded feature geometry")
    if cls <= 5 { classes.insert(cls) }
    if cls >= 20 && cls < 128 { poiCount += 1; check(count == 1, "POI remains a point") }
    position += count * 4
}
check(classes == levels && poiCount > 0, "Complete minor roads and geographic icons survive transport")
for remove in 1..<32 { check(!GtaVectorCodec.valid(packet.dropLast(remove), frame: 77, cx: 0, cy: 0), "Truncated wire packet fails closed") }
var wrongClass = packet; wrongClass[12] = 127
check(!GtaVectorCodec.valid(wrongClass, frame: 77, cx: 0, cy: 0), "Reject unknown wire class")
rejects("Truncated PBF") { _ = try MvtTile.decode(raw.dropLast()) }
rejects("Oversized PBF field") { _ = try MvtTile.decode(Data([26, 255, 255, 255, 127])) }
rejects("Overflowed varint") { _ = try MvtTile.decode(Data([26] + Array(repeating: 255, count: 10))) }
rejects("Zero protobuf field") { _ = try MvtTile.decode(Data([0, 0])) }
rejects("Unsupported protobuf group") { _ = try MvtTile.decode(Data([11])) }
rejects("Empty road map cannot replace current map") { _ = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: []) }
rejects("Invalid input tile coordinate") { _ = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: [.init(z: -1, x: 0, y: 0, data: raw)]) }

func varint(_ input: UInt64) -> Data {
    var value = input, bytes = Data()
    while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
    bytes.append(UInt8(value)); return bytes
}
func field(_ key: UInt64, _ data: Data) -> Data { varint(key) + varint(UInt64(data.count)) + data }
func zigzag(_ value: Int) -> UInt64 { UInt64(bitPattern: (Int64(value) << 1) ^ (Int64(value) >> 63)) }
func line(_ x: Int, _ y: Int) -> Data {
    let geometry = varint(9) + varint(zigzag(x)) + varint(zigzag(y)) + varint(10) + varint(20) + varint(0)
    return field(18, Data([0, 0])) + varint(24) + varint(2) + field(34, geometry)
}
func geometryTile(_ geometry: Data, type: Int = 2, layerName: String = "transportation") -> Data {
    let feature = varint(24) + varint(UInt64(type)) + field(34, geometry)
    return field(26, field(10, Data(layerName.utf8)) + field(18, feature))
}
rejects("LineTo cannot precede MoveTo") { _ = try MvtTile.decode(geometryTile(Data([10, 0, 0]))) }
let overflowGeometry = varint(9) + varint(zigzag(Int(Int32.max))) + varint(0) + varint(10) + varint(2) + varint(0)
rejects("Coordinate deltas cannot overflow Int32") { _ = try MvtTile.decode(geometryTile(overflowGeometry)) }
let polygon = Data([9, 0, 0, 18, 20, 0, 0, 20, 15])
let decodedPolygon = try MvtTile.decode(geometryTile(polygon, type: 3, layerName: "water"))
check(decodedPolygon.first?.paths.first?.count == 8, "ClosePath restores the first point once")
rejects("Repeated ClosePath cannot expand geometry indefinitely") { _ = try MvtTile.decode(geometryTile(polygon + Data([15]), type: 3, layerName: "water")) }
rejects("LineTo cannot continue a closed polygon") { _ = try MvtTile.decode(geometryTile(polygon + Data([10, 0, 0]), type: 3, layerName: "water")) }
var layer = field(10, Data("transportation".utf8))
for i in 0..<7001 { layer += field(18, line(1000 + i % 100 * 10, 1000 + i / 100 * 10)) }
layer += field(26, Data("class".utf8)) + field(34, field(10, Data("minor".utf8))) + varint(40) + varint(4096)
rejects("Oversized complete minor-road network must fail rather than silently dropping roads") {
    _ = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: [.init(z: 14, x: 13484, y: 6201, data: field(26, layer))])
}

let ranges = try GtaVectorMaps.tileCoordinates(frame, cx: 0, cy: 0)
check(!ranges.isEmpty && ranges.count <= 36 && ranges.contains(where: { $0.x == 13484 && $0.y == 6201 }), "Bounded full-coverage z14 range")
rejects("Polar range rejected") { _ = try GtaVectorMaps.tileCoordinates(.init(refLat: 89, refLng: 0, id: 1), cx: 0, cy: 0) }
let template = "https://tiles.openfreemap.org/planet/test/{z}/{x}/{y}.pbf"
let manifest = try JSONSerialization.data(withJSONObject: ["tiles": [template]])
let validatedTemplate = try GtaVectorMaps.tileTemplate(manifest)
check(validatedTemplate == template, "Validated tile directory")
rejects("Reject untrusted tile host") { _ = try GtaVectorMaps.tileTemplate(JSONSerialization.data(withJSONObject: ["tiles": ["https://example.com/planet/{z}/{x}/{y}.pbf"]])) }
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-gta-test-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let counterLock = NSLock()
var requests = 0
let result = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary) { url in
    counterLock.lock(); requests += 1; counterLock.unlock()
    if url.path == "/planet" { return manifest }
    return url.path.hasSuffix("/14/13484/6201.pbf") ? raw : Data()
}
check(result.bytes == expected && result.tiles == ranges.count && result.fromCache == 0, "Fixture injection exercises complete production download and encode path")
check(requests == ranges.count + 1, "One directory plus each required tile")
let offline = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary) { _ in throw GtaVectorMaps.MapError.download("offline") }
check(offline.bytes == expected && offline.fromCache == ranges.count, "All cached tiles remain usable without internet")
let corruptFile = (FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: nil)?.allObjects as? [URL])?.first { $0.lastPathComponent == "14_13484_6201.pbf" }
check(corruptFile != nil, "Validated tile persisted")
try Data([26, 255]).write(to: corruptFile!)
requests = 0
let repaired = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary) { _ in
    counterLock.lock(); requests += 1; counterLock.unlock(); return raw
}
check(repaired.bytes == expected && requests == 1 && repaired.fromCache == ranges.count - 1, "Corrupt cache refetched before use")
rejects("Cancelled work cannot return a replacement map") {
    _ = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { true }, cacheDirectory: temporary) { _ in manifest }
}
if let output = ProcessInfo.processInfo.environment["MOTONAV_TEST_OUTPUT"] {
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try packet.write(to: destination.appendingPathComponent("ios-gta-type1.bin"))
}
print("PASS GTA iOS vector: \(checks) checks; all five road levels, \(poiCount) POIs, \(packet.count)-byte Android-identical packet; offline and corrupt-cache recovery")
