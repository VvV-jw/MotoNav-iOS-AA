import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message); checks += 1
}
let suite = "motonav-vector-styles-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
defaults.set(true, forKey: MapDefaults.floatingMigrationKey)
defaults.set("retained-test-key", forKey: "key_amap")
defaults.set(true, forKey: "map_buildings")
let keys = (0...13).map { MapStylePolicy.cacheKey(theme: $0, buildings: false) }
check(Set(keys).count == 14, "All fourteen style caches remain distinct")
check(MapStylePolicy.cacheKey(theme: 2, buildings: false) == "ofm-gta-vector-v5-poi28",
      "Existing GTA vector packets retain their content identity")
check(MapStylePolicy.cacheKey(theme: 12, buildings: false) == "ofm-floating-roads-v1",
      "Existing floating vector packets retain their content identity")
check(MapStylePolicy.cacheKey(theme: 13, buildings: false) == "ofm-coast-areas-v1",
      "Coast detail packets have an independent content identity")
for style in 0...13 {
    check(MapStylePolicy.isValid(style) && MapStylePolicy.normalize(style) == style,
          "Every firmware theme is selectable without silently becoming Vice City")
    check(MapStylePolicy.usesBasemap(style), "Every style, including dragon radar, prepares a map")
    check(MapStylePolicy.usesVector(style) == (style != 10),
          "Only satellite photography uses raster data")
    check(MapStylePolicy.usesAmapCapture(style) == (style == 10),
          "Vector road themes do not depend on foreground SDK snapshots")
    check(MapStylePolicy.half(style) == (style == 10 ? 700 : 2400),
          "Coverage matches the real photograph or vector extent")
    check(!MapStylePolicy.usesBuildings(style, enabled: true),
          "The retained building preference cannot create screenshot work for a vector theme")
    defaults.set(style, forKey: "map_theme")
    check(MapDefaults.theme(defaults) == style, "Upgrade retains the selected style")
    check(defaults.string(forKey: "key_amap") == "retained-test-key" &&
          defaults.bool(forKey: "map_buildings"), "Style policy preserves stored credentials and preferences")
    if style != 2 && style != 10 && style != 12 && style != 13 {
        check(keys[style] == "ofm-vector-aa27-style-\(style)",
              "A new vector theme never reads a historical screenshot cache")
    }
}
for invalid in [-1, 14, 99] {
    check(!MapStylePolicy.isValid(invalid) && MapStylePolicy.normalize(invalid) == 1,
          "Unknown theme IDs keep the established safe fallback")
}

let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("gta-vector/fixtures/android-gta-poi28-type1.bin")
let packet = try Data(contentsOf: fixtureURL)
let frame = MapGeo.Frame(refLat: 31, refLng: 121, id: 77)
let node = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
check(GtaVectorCodec.valid(packet, frame: frame.id, cx: 0, cy: 0),
      "Use the real Android-compatible vector packet")
let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("motonav-vector-style-cache-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let cache = RouteMapCache(root: directory)
let raster = MapGeo.encodeRaster(frameId: frame.id, x0: -1200, y0: 1200,
    w: 1200, h: 1200, mmPerPx: 2000, idx: [UInt8](repeating: 1, count: 1200 * 1200))
for style in (0...13).filter({ $0 != 10 }) {
    try cache.store(packet, frame: frame, source: 3, node: node, style: style)
    check(cache.read(frame: frame, source: 3, buildings: false, node: node, style: style) == packet,
          "Every vector palette reloads the same complete road and water geometry")
    check(cache.covering(frame: frame, source: 3, style: style, buildings: false,
        x: 1500, y: 0, kmh: 60)?.packet.data == packet, "Every vector style uses the full 4.8 km map")
    do {
        try cache.store(raster, frame: frame, source: 3, node: node, style: style)
        preconditionFailure("Screenshot bytes were accepted as vector roads")
    } catch { checks += 1 }
    check(cache.read(frame: frame, source: 3, buildings: false, node: node, style: style) == packet,
          "Rejected screenshot leaves the verified vector map intact")
}
let reopened = RouteMapCache(root: directory)
for style in (0...13).filter({ $0 != 10 }) {
    check(reopened.read(frame: frame, source: 3, buildings: false, node: node, style: style) == packet,
          "All vector style caches survive application restart")
}
check(reopened.stats().files == 13, "Each vector theme owns one independent cache entry")

// The photographic encoder is exercised with synthetic pixels, never a map image
// masquerading as satellite imagery. Live SDK imagery still requires the user's key.
var photograph = [UInt32](repeating: 0xff4e815d, count: 400 * 400)
for y in 0..<400 { for x in 0..<400 where x >= 200 {
    photograph[y * 400 + x] = y < 200 ? 0xff538fbd : 0xffc5c3b5
} }
let photo = try SatelliteRaster.encode(frame, cx: 0, cy: 0, half: 700,
    raw: photograph, shouldCancel: { false }).bytes
let bytes = [UInt8](photo)
check(RasterPacket.u16(bytes, 10) == 400 && RasterPacket.u16(bytes, 12) == 400 &&
      RasterPacket.u16(bytes, 14) == (3500 | 0x8000), "Satellite keeps real photo geometry and its palette flag")
check(RasterPacket.i32(bytes, 2) == -700 && RasterPacket.i32(bytes, 6) == 700,
      "Satellite uses its existing 1.4 km photo extent")
check(!GtaVectorCodec.valid(photo, frame: frame.id, cx: 0, cy: 0),
      "Photographic pixels never enter the vector codec")
print("Vector style migration: \(checks) checks passed; 13 vector themes and 1 photographic theme")
