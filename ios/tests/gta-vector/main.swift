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
let expected = try Data(contentsOf: directory.appendingPathComponent("android-gta-poi28-type1.bin"))
let baseline = try Data(contentsOf: directory.appendingPathComponent("android-aa17-type1.bin"))
let features = try MvtTile.decode(raw)
let levels = Set(features.filter { $0.layer == "transportation" }.map { GtaVectorCodec.roadClass($0.tags["class"] ?? "") }.filter { $0 > 0 })
check(levels == Set(1...5), "Fixture includes all five road hierarchies")
let sourcePOI = features.filter { $0.layer == "poi" && $0.type == 1 && GtaVectorCodec.poiClass($0.tags["class"] ?? "", $0.tags["subclass"] ?? "") > 0 }.count
let validPOI: [(String,String,Int)] = [
    ("hospital","hospital",20),("hospital","clinic",20),("police","police",21),
    ("fuel","fuel",22),("bank","bank",23),("atm","atm",23),("railway","station",24),
    ("bar","nightclub",25),("beer","pub",25),("car","car_repair",26),
    ("raceway","raceway",27),("karting","karting",27),("fire_station","fire_station",28),
    ("aerodrome","aerodrome",29),("airport","airport",29),("bus","bus_station",30),
    ("bus","bus_stop",30),("parking","parking",31),("hairdresser","hairdresser",32),
    ("shop","hairdresser",32),("clothing_store","clothes",33),("shop","clothes",33),
    ("shop","tattoo",34),("shop","weapons",35),("cinema","cinema",36),("casino","casino",37),
    ("golf","golf_course",38),("golf","golf",38),("tennis","tennis",39),
    ("harbor","marina",40),("harbor","dock",40),("ferry_terminal","ferry_terminal",40),
    ("helipad","helipad",41),("car_wash","car_wash",42),("theme_park","theme_park",43),
    ("water_park","water_park",43),("lodging","hotel",44),("lodging","motel",44),
    ("lodging","hostel",44),("lodging","guest_house",44),("lodging","bed_and_breakfast",44),
    ("amusement_arcade","amusement_arcade",45),("office","company",46),
    ("office","government",46),("office","coworking",46),("car","car",47),("shop","car",47),
    ("fire_station","",28),("cinema","",36),("weapons","",35)
]
let excludedPOI = [
    ("fuel","charging_station"),("car","car_parts"),("car","taxi"),("hospital","nursing_home"),
    ("railway","subway"),("railway","tram_stop"),("fuel","hospital"),("car",""),("fuel",""),
    ("hospital",""),("railway",""),("bus",""),("golf",""),("shop",""),("office",""),("lodging",""),
    ("clothing_store",""),("harbor",""),("car","garage"),("garage","private"),("parking","garage"),
    ("shop","motorcycle"),("food","restaurant"),("fast_food","fast_food"),("shop","hunting"),
    ("transport","bus_station"),("culture","cinema"),("lodging","dormitory"),("lodging","alpine_hut"),
    ("golf","miniature_golf"),("clothing_store","bag"),("cinema","theatre"),("bus","station"),
    ("railway","bus_station"),("office","car"),("fuel","car"),("car","hairdresser"),
    ("hospital","weapons"),("parking","motorcycle_parking"),("aerodrome","helipad")
]
for (kind,detail,cls) in validPOI { check(GtaVectorCodec.poiClass(kind, detail) == cls, "Specific actual POI symbol") }
check(Set(validPOI.map { $0.2 }) == Set(20...47), "All 28 wire POI classes have precise semantics")
for (kind,detail) in excludedPOI {
    check(GtaVectorCodec.poiClass(kind, detail) == 0, "Ambiguous/unsupported places never receive misleading icons")
}
check(sourcePOI > 0, "Real geographic POI classes, not invented symbols")
for feature in features {
    check(feature.extent > 0, "Positive extent")
    for path in feature.paths { check(path.count >= 2 && path.count % 2 == 0, "Complete geometry pairs") }
}
let lng = 13484.5 / 16384 * 360 - 180
let lat = atan(sinh(.pi * (1 - 2 * 6201.5 / 16384))) * 180 / .pi
let gcj = MapGeo.wgsToGcj(lat, lng)
let frame = MapGeo.Frame(refLat: gcj.lat, refLng: gcj.lng, id: 77)
for (kind, detail, cls) in validPOI {
    let sample = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: [
        .init(z: 14, x: 13484, y: 6201, data: poiTile(kind, detail))
    ])
    check(GtaVectorCodec.valid(sample, frame: 77, cx: 0, cy: 0), "Expanded POI survives wire validation")
    check(packetClasses(sample) == [4, cls], "Synthetic tagged point encoded at its actual coordinate")
    let legacy = GtaVectorCodec.legacyDisplayPacket(sample)
    check(packetClasses(legacy) == (cls <= 26 ? [4, cls] : [4]),
          "AA13 transport keeps roads and only its supported POI classes")
    check(GtaVectorCodec.valid(legacy, frame: 77, cx: 0, cy: 0),
          "AA13-compatible packet retains its valid frame and feature count")
}
let airport = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: [
    .init(z: 14, x: 13484, y: 6201, data: poiTile("international", "", layerName: "aerodrome_label"))
])
check(packetClasses(airport) == [4, 29], "Real aerodrome label point supplies airport without invented center")
let airportLine = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: [
    .init(z: 14, x: 13484, y: 6201, data: poiTile("international", "", layerName: "aerodrome_label", type: 2))
])
check(packetClasses(airportLine) == [4], "Airport label line is not converted to a POI")
for (kind, detail) in excludedPOI {
    let sample = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: [
        .init(z: 14, x: 13484, y: 6201, data: poiTile(kind, detail))
    ])
    check(packetClasses(sample) == [4], "Unsupported point does not create a fake icon")
}
let packet = try GtaVectorCodec.encode(frame, cx: 0, cy: 0, tiles: [.init(z: 14, x: 13484, y: 6201, data: raw)])
check(packet == expected, "Swift output is byte-for-byte compatible with the Android 28-POI codec")
check(geometryOnly(packet) == geometryOnly(baseline), "Road and water geometry remains byte-for-byte unchanged")
let legacyPacket = GtaVectorCodec.legacyDisplayPacket(packet)
check(geometryOnly(legacyPacket) == geometryOnly(baseline), "AA13 compatibility preserves every road and water byte")
check(packetClasses(legacyPacket).allSatisfy { !(27...47).contains($0) },
      "Unadvertised extended POIs cannot make AA13 reject a complete map")
check(GtaVectorCodec.legacyDisplayPacket(legacyPacket) == legacyPacket, "Legacy conversion is idempotent")
check(GtaVectorCodec.legacyDisplayPacket(packet.dropLast()) == packet.dropLast(),
      "Truncated packets are never silently repaired into a different map")
check(MapStylePolicy.cacheKey(theme: 2, buildings: false) == "ofm-gta-vector-v5-poi28", "Old GTA packets cannot hide newly supported POIs")
check(MapStylePolicy.cacheKey(theme: 0, buildings: false) == "amap-original-full-aa1", "Original map cache stays compatible")
check(MapStylePolicy.cacheKey(theme: 1, buildings: false) == "amap-sdk-v3", "SDK map cache stays compatible")
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
for cls in [19, 48, 127] {
    var invalid = airport; invalid[invalid.count - 7] = UInt8(cls)
    check(!GtaVectorCodec.valid(invalid, frame: 77, cx: 0, cy: 0), "Reject unknown POI class")
}
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
func poiTile(_ kind: String, _ detail: String, layerName: String = "poi", type: Int = 1) -> Data {
    let move = varint(9) + varint(4096) + varint(4096)
    let roadLine = move + varint(10) + varint(40) + varint(0)
    let roadFeature = field(18, Data([0, 0])) + varint(24) + varint(2) + field(34, roadLine)
    let road = field(10, Data("transportation".utf8)) + field(18, roadFeature)
        + field(26, Data("class".utf8)) + field(34, field(10, Data("minor".utf8))) + varint(40) + varint(4096)
    let point = field(18, Data([0, 0, 1, 1])) + varint(24) + varint(UInt64(type)) + field(34, type == 1 ? move : roadLine)
    let poi = field(10, Data(layerName.utf8)) + field(18, point)
        + field(26, Data("class".utf8)) + field(26, Data("subclass".utf8))
        + field(34, field(10, Data(kind.utf8))) + field(34, field(10, Data(detail.utf8))) + varint(40) + varint(4096)
    return field(26, road) + field(26, poi)
}
func packetClasses(_ packet: Data) -> [Int] {
    let bytes = Array(packet)
    var result: [Int] = [], at = 12
    while at < bytes.count {
        result.append(Int(bytes[at])); at += 3 + u16(bytes, at + 1) * 4
    }
    return result
}
func geometryOnly(_ packet: Data) -> Data {
    let bytes = Array(packet)
    var body = Data(), count = 0, at = 12
    while at < bytes.count {
        let cls = Int(bytes[at]), end = at + 3 + u16(bytes, at + 1) * 4
        if cls < 20 || cls >= 128 { body.append(contentsOf: bytes[at..<end]); count += 1 }
        at = end
    }
    return Data(bytes.prefix(10)) + Data([UInt8(truncatingIfNeeded: count), UInt8(count >> 8)]) + body
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
var downloadChecks = 0
let pauseDownloads: () throws -> Void = {
    counterLock.lock(); downloadChecks += 1; counterLock.unlock()
    throw MapServiceError.http(status: 429, retryAfter: 90)
}
let unexpectedDownload: (URL) throws -> Data = { _ in
    counterLock.lock(); requests += 1; counterLock.unlock()
    return Data()
}
requests = 0
let pausedCached = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false },
    beforeDownload: pauseDownloads, cacheDirectory: temporary, fetch: unexpectedDownload)
check(pausedCached.bytes == expected && pausedCached.fromCache == ranges.count,
      "Complete raw cache builds while network permission is paused")
check(downloadChecks == 0 && requests == 0, "Complete cache needs neither a network gate nor an HTTP request")
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 24 * 3600)],
                                      ofItemAtPath: temporary.appendingPathComponent("planet.json").path)
let previousServiceDeadline = GtaVectorMaps.serviceRetryAt
let pausedDirectory = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false },
    beforeDownload: pauseDownloads, cacheDirectory: temporary, fetch: unexpectedDownload)
check(pausedDirectory.bytes == expected && pausedDirectory.fromCache == ranges.count,
      "Paused stale-directory refresh retains the complete validated raw cache")
check(downloadChecks == 1 && requests == 0, "Stale-directory permission failure never reaches the provider")
check(GtaVectorMaps.serviceRetryAt == previousServiceDeadline,
      "Local network pause does not install or extend the provider cooldown")
try FileManager.default.setAttributes([.modificationDate: Date()],
                                      ofItemAtPath: temporary.appendingPathComponent("planet.json").path)
let corruptFile = (FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: nil)?.allObjects as? [URL])?.first { $0.lastPathComponent == "14_13484_6201.pbf" }
check(corruptFile != nil, "Validated tile persisted")
try FileManager.default.removeItem(at: corruptFile!)
downloadChecks = 0
do {
    _ = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false },
        beforeDownload: pauseDownloads, cacheDirectory: temporary, fetch: unexpectedDownload)
    preconditionFailure("Missing raw tile bypassed the network pause")
} catch MapServiceError.http(let status, let retryAfter) {
    check(status == 429 && retryAfter == 90, "Missing tile preserves the typed network pause")
}
check(downloadChecks > 0 && requests == 0, "Missing raw tile cannot issue HTTP while network permission is paused")
check(GtaVectorMaps.serviceRetryAt == previousServiceDeadline,
      "Missing-tile permission failure leaves the provider cooldown unchanged")
let restored = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary) { _ in
    counterLock.lock(); requests += 1; counterLock.unlock(); return raw
}
check(restored.bytes == expected && requests == 1 && restored.fromCache == ranges.count - 1,
      "Missing tile recovers after network permission resumes")
try Data([26, 255]).write(to: corruptFile!)
requests = 0
let repaired = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary) { _ in
    counterLock.lock(); requests += 1; counterLock.unlock(); return raw
}
check(repaired.bytes == expected && requests == 1 && repaired.fromCache == ranges.count - 1, "Corrupt cache refetched before use")
let checksBeforeCancellation = downloadChecks
rejects("Cancelled work cannot return a replacement map") {
    _ = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { true },
        beforeDownload: pauseDownloads, cacheDirectory: temporary) { _ in manifest }
}
check(downloadChecks == checksBeforeCancellation, "Cancellation precedes network permission checks")
// A route refresh has one boundary, so overlapping blocks do not re-download
// tiles already refreshed by the same operation. Normal offline use stays intact.
requests = 0
let boundary = Date()
let refreshed = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary, fetch: { url in
    counterLock.lock(); requests += 1; counterLock.unlock()
    if url.path == "/planet" { return manifest }
    return url.path.hasSuffix("/14/13484/6201.pbf") ? raw : Data()
}, forceRefresh: true, refreshAfter: boundary)
check(refreshed.bytes == expected && requests == ranges.count + 1, "Explicit refresh updates the directory and every older tile")
let sharedRefresh = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary,
    fetch: { _ in throw GtaVectorMaps.MapError.download("offline") }, forceRefresh: true, refreshAfter: boundary)
check(sharedRefresh.fromCache == ranges.count && sharedRefresh.bytes == expected, "One refresh boundary reuses freshly updated overlapping tiles")
rejects("A failed explicit refresh cannot silently claim old tiles were updated") {
    _ = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary,
        fetch: { _ in throw GtaVectorMaps.MapError.download("offline") }, forceRefresh: true, refreshAfter: Date().addingTimeInterval(1))
}
let kept = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary) { _ in throw GtaVectorMaps.MapError.download("offline") }
check(kept.bytes == expected, "Failed update preserves the previous usable map")
requests = 0; downloadChecks = 0
do {
    _ = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false },
        beforeDownload: pauseDownloads, cacheDirectory: temporary, fetch: unexpectedDownload,
        forceRefresh: true, refreshAfter: Date().addingTimeInterval(1))
    preconditionFailure("Paused forced refresh claimed old tiles were updated")
} catch MapServiceError.http(let status, let retryAfter) {
    check(status == 429 && retryAfter == 90, "Forced refresh reports the typed network pause")
}
check(downloadChecks == 1 && requests == 0, "Forced refresh cannot bypass network permission")
let preservedAfterPause = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false },
    beforeDownload: pauseDownloads, cacheDirectory: temporary, fetch: unexpectedDownload)
check(preservedAfterPause.bytes == expected && preservedAfterPause.fromCache == ranges.count,
      "Paused forced refresh preserves cached geometry for ordinary map use")
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 24 * 3600)],
                                      ofItemAtPath: temporary.appendingPathComponent("planet.json").path)
do {
    _ = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary) { _ in
        throw MapServiceError.http(status: 401, retryAfter: nil)
    }
    preconditionFailure("Old raw fallback swallowed service authorization failure")
} catch {
    check(MapFailurePolicy.classify(error).category == .configuration, "Typed GTA authorization reaches preparation pause with old raw available")
}
let preservedAfterAuthorization = try GtaVectorMaps.build(frame, cx: 0, cy: 0, shouldCancel: { false }, cacheDirectory: temporary) { _ in
    throw GtaVectorMaps.MapError.download("offline")
}
check(preservedAfterAuthorization.bytes == expected && preservedAfterAuthorization.fromCache == ranges.count,
      "Authorization failure preserves cached roads and valid empty ocean tiles")
if let output = ProcessInfo.processInfo.environment["MOTONAV_TEST_OUTPUT"] {
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try packet.write(to: destination.appendingPathComponent("ios-gta-type1.bin"))
    try legacyPacket.write(to: destination.appendingPathComponent("ios-gta-aa13-type1.bin"))
}
print("PASS GTA iOS vector: \(checks) checks; all five road levels, \(poiCount) POIs, \(packet.count)-byte Android-identical packet; offline and corrupt-cache recovery")
