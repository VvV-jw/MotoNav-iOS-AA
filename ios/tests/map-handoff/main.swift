import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label); checks += 1
}
let bend = try RouteMapPlan([(0, 0), (1200, 0), (1200, 12000)])
let current = bend.at(1100)
let short = bend.preparationTarget(progress: 1100, kmh: 120, preparationSeconds: 8)
let long = bend.preparationTarget(progress: 1100, kmh: 120, preparationSeconds: 40)
check(bend.nodes[long].distance > bend.nodes[short].distance, "Slow measured preparation expands the future route budget")
check(bend.nodes[long].y > 0, "Future preparation follows the bend rather than the old heading")
check(!MapCoveragePolicy.covers(x: current.x, y: current.y, cx: bend.nodes[long].x,
    cy: bend.nodes[long].y, kmh: 120), "Prepared future map cannot yet replace the confirmed screen")
check(bend.preparationTarget(progress: 1100, kmh: 120, preparationSeconds: 40, half: 2400) >= long,
    "GTA keeps its actual 2400m half extent")
let highway = try RouteMapPlan([(0, 0), (12000, 0)])
check(MapCoveragePolicy.remainingSeconds(x: 0, y: 0, cx: 0, cy: 0, kmh: 120, bearing: 90,
    half: 2400, plan: highway, progress: 0) >
    MapCoveragePolicy.remainingSeconds(x: 0, y: 0, cx: 0, cy: 0, kmh: 120, bearing: 90,
        half: 1200, plan: highway, progress: 0), "Coverage deadlines use the selected map extent")
check(!MapDeliveryPolicy.roofsFit(kmh: 60, wireBytes: 1000, rate: nil, coverageSeconds: 60, nextBaseWireBytes: 100),
    "Unknown radio throughput reserves moving-screen roads")
check(MapDeliveryPolicy.roofsFit(kmh: 0, wireBytes: 100000, rate: nil, coverageSeconds: 60, nextBaseWireBytes: 100),
    "Stopped navigation may receive optional detail after base confirmation")
check(MapDeliveryPolicy.roofsFit(kmh: 60, wireBytes: 600, rate: 100, coverageSeconds: 10, nextBaseWireBytes: 200),
    "Measured wire budget includes the next compact road map")
check(!MapDeliveryPolicy.roofsFit(kmh: 60, wireBytes: 600, rate: 100, coverageSeconds: 7, nextBaseWireBytes: 200),
    "Departure can revoke a formerly safe roof budget")

let frame = MapGeo.Frame(refLat: 31, refLng: 121, id: 77)
let size = RasterPacket.size
var pixels = [UInt8](repeating: 0, count: size * size)
for i in stride(from: 0, to: pixels.count, by: 11) { pixels[i] = 4 }
let detail = MapGeo.encodeRaster(frameId: frame.id, x0: -1200, y0: 1200, w: size, h: size,
    mmPerPx: 2000 | 0x4000, idx: pixels)
let base = MapDeliveryPolicy.compactBase(detail)
check(RasterPacket.valid(base) && !RasterPacket.isBuilding(base), "Compact road packet remains a valid normal raster")
check(base.count < detail.count, "Stripping roofs actually reduces encoded wire input")
let compressed = RasterTransport.pack(base, supported: true)
check(compressed.count <= base.count, "Budget can use the smaller compressed payload actually transmitted")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-handoff-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let cache = RouteMapCache(root: directory)
let node = RouteMapPlan.Node(x: 0, y: 0, distance: 0)
try cache.store(detail, frame: frame, source: 3, node: node, style: 1)
let reopened = RouteMapCache(root: directory)
check(reopened.covering(frame: frame, source: 3, style: 1, buildings: true, x: 100, y: 0, kmh: 60)?.packet.data == detail,
    "Reopened index finds a nearby building-only cached map after changed route centres")
check(reopened.covering(frame: frame, source: 3, style: 1, buildings: true, x: 1000, y: 0, kmh: 120) == nil,
    "Nearby lookup refuses an incomplete viewport")
check(reopened.covering(frame: frame, source: 3, style: 2, buildings: false, x: 0, y: 0, kmh: 60) == nil,
    "Nearby lookup cannot mix raster and GTA style packets")
check(reopened.stats().diskScans == 1, "Near-cache lookup reuses the recovered index")
print("Map handoff: \(checks) checks passed")
