import Foundation

/// OFM/OSM geometry is transformed to the GCJ-02 metre frame used by navigation.
/// Type-1 wire layout and feature ordering match Android aa.4 and the aa.7 ESP renderer.
enum GtaVectorCodec {
    static let HALF = 2400.0
    static let maximumBytes = 190_000
    static let maximumFeatures = 7000

    struct Tile { let z: Int; let x: Int; let y: Int; let data: Data }
    private struct Part { let cls: Int; let poly: Bool; let points: [Double] }
    enum EncodeError: Error, LocalizedError {
        case invalidCoordinates, emptyRoads, oversizedMap, oversizedPolygon
        var errorDescription: String? {
            switch self {
            case .invalidCoordinates: return "GTA 矢量坐标无效，保留现有地图"
            case .emptyRoads: return "GTA 矢量地图未包含道路，保留现有地图"
            case .oversizedMap: return "GTA 路网数据过大，保留现有地图"
            case .oversizedPolygon: return "GTA 水域边界过长，保留现有地图"
            }
        }
    }

    /// Kotlin/Java roundToInt uses floor(x + 0.5), including negative ties.
    static func roundMeters(_ value: Double) -> Int { Int(floor(value + 0.5)) }

    static func roadClass(_ value: String) -> Int {
        switch value {
        case "motorway": return 1
        case "trunk", "primary": return 2
        case "secondary", "tertiary": return 3
        case "minor": return 4
        case "service", "path", "track", "raceway": return 5
        default: return 0
        }
    }

    // Broad OMT classes need a matching original subclass. An unsupported
    // subclass must never fall back to its broader class or invent a POI.
    static func poiClass(_ value: String, _ subclass: String = "") -> Int {
        if subclass.isEmpty && ["hospital", "fuel", "railway", "car", "bus", "shop", "golf",
                                "clothing_store", "harbor", "lodging", "office"].contains(value) { return 0 }
        let detail = subclass.isEmpty ? value : subclass
        switch detail {
        case "hospital", "clinic": return ["hospital", "clinic"].contains(value) ? 20 : 0
        case "police": return value == "police" ? 21 : 0
        case "fuel": return value == "fuel" ? 22 : 0
        case "bank", "atm": return ["bank", "atm"].contains(value) ? 23 : 0
        case "station", "halt", "railway_station": return ["railway", "railway_station"].contains(value) ? 24 : 0
        case "bar", "pub", "nightclub": return ["bar", "pub", "beer"].contains(value) ? 25 : 0
        case "car_repair": return ["car", "car_repair"].contains(value) ? 26 : 0
        case "raceway", "karting": return value == detail ? 27 : 0
        case "fire_station": return value == detail ? 28 : 0
        case "aerodrome", "airport": return value == detail ? 29 : 0
        case "bus_stop", "bus_station": return ["bus", detail].contains(value) ? 30 : 0
        case "parking": return value == detail ? 31 : 0
        case "hairdresser": return ["shop", detail].contains(value) ? 32 : 0
        case "clothes": return ["clothing_store", "shop", detail].contains(value) ? 33 : 0
        case "tattoo": return ["shop", detail].contains(value) ? 34 : 0
        case "weapons": return ["shop", detail].contains(value) ? 35 : 0
        case "cinema": return value == detail ? 36 : 0
        case "casino": return ["casino", "gambling"].contains(value) ? 37 : 0
        case "golf", "golf_course": return ["golf", "golf_course"].contains(value) ? 38 : 0
        case "tennis": return value == detail ? 39 : 0
        case "marina", "dock": return ["harbor", detail].contains(value) ? 40 : 0
        case "ferry_terminal": return value == detail ? 40 : 0
        case "helipad": return value == detail ? 41 : 0
        case "car_wash": return value == detail ? 42 : 0
        case "theme_park", "water_park", "fairground": return value == detail ? 43 : 0
        case "hotel", "motel", "hostel", "guest_house", "bed_and_breakfast":
            return ["lodging", detail].contains(value) ? 44 : 0
        case "amusement_arcade": return value == detail ? 45 : 0
        case "company", "government", "administrative", "association", "lawyer", "financial", "coworking":
            return value == "office" ? 46 : 0
        case "car": return ["car", "shop"].contains(value) ? 47 : 0
        default: return 0
        }
    }

    static func encode(_ frame: MapGeo.Frame, cx: Double, cy: Double, tiles: [Tile]) throws -> Data {
        guard cx.isFinite, cy.isFinite, abs(cx) < Double(Int32.max) - HALF,
              abs(cy) < Double(Int32.max) - HALF, (0...65535).contains(frame.id) else { throw EncodeError.invalidCoordinates }
        var areas: [Part] = [], holes: [Part] = [], roads: [Part] = [], pois: [Part] = []
        var seen = Set<String>(), poiCells = Set<String>()
        for tile in tiles {
            guard (0...22).contains(tile.z), tile.x >= 0, tile.y >= 0,
                  tile.x < (1 << tile.z), tile.y < (1 << tile.z) else { throw EncodeError.invalidCoordinates }
            let scale = pow(2.0, Double(tile.z))
            for feature in try MvtTile.decode(tile.data) {
                let kind = feature.tags["class"] ?? ""
                let cls: Int
                switch feature.layer {
                case "transportation": cls = roadClass(kind)
                case "water": cls = 11
                case "waterway": cls = 6
                case "poi": cls = feature.type == 1 ? poiClass(kind, feature.tags["subclass"] ?? "") : 0
                case "aerodrome_label": cls = feature.type == 1 ? 29 : 0
                default: cls = 0
                }
                if cls == 0 { continue }
                if cls == 24 && ["subway", "light_rail", "tram"].contains(feature.tags["subclass"] ?? "") { continue }
                for path in feature.paths where !path.isEmpty {
                    var points: [Double] = []; points.reserveCapacity(path.count)
                    for i in stride(from: 0, to: path.count, by: 2) {
                        let lng = (Double(tile.x) + Double(path[i]) / Double(feature.extent)) / scale * 360 - 180
                        let lat = atan(sinh(.pi * (1 - 2 * (Double(tile.y) + Double(path[i + 1]) / Double(feature.extent)) / scale))) * 180 / .pi
                        let gcj = MapGeo.wgsToGcj(lat, lng)
                        let x = frame.x(gcj.lng), y = frame.y(gcj.lat)
                        guard x.isFinite, y.isFinite else { throw EncodeError.invalidCoordinates }
                        points.append(x); points.append(y)
                    }
                    if cls >= 20 {
                        if abs(points[0] - cx) > HALF - 100 || abs(points[1] - cy) > HALF - 100 { continue }
                        let cell = "\(Int(floor(points[0] / 140)))_\(Int(floor(points[1] / 140)))"
                        if poiCells.insert(cell).inserted { pois.append(Part(cls: cls, poly: false, points: Array(points.prefix(2)))) }
                        continue
                    }
                    let poly = feature.layer == "water" && feature.type == 3
                    if poly {
                        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
                        var area = 0.0
                        for i in stride(from: 0, to: points.count, by: 2) {
                            minX = min(minX, points[i]); maxX = max(maxX, points[i]); minY = min(minY, points[i + 1]); maxY = max(maxY, points[i + 1])
                            if i + 3 < path.count { area += Double(path[i]) * Double(path[i + 3]) - Double(path[i + 2]) * Double(path[i + 1]) }
                        }
                        if maxX < cx - HALF || minX > cx + HALF || maxY < cy - HALF || minY > cy + HALF { continue }
                        let part = Part(cls: area < 0 ? 10 : 11, poly: true, points: MapGeo.simplify(points, 1))
                        if area < 0 { holes.append(part) } else { areas.append(part) }
                    } else if points.count >= 4 {
                        for piece in MapGeo.clipLine(points, cx - HALF, cy - HALF, cx + HALF, cy + HALF) {
                            let simplified = MapGeo.simplify(piece, 0.8)
                            let key = "\(cls):" + simplified.map { String(roundMeters($0)) }.joined(separator: ",")
                            if seen.insert(key).inserted { roads.append(Part(cls: cls, poly: false, points: simplified)) }
                        }
                    }
                }
            }
        }
        guard !roads.isEmpty else { throw EncodeError.emptyRoads }
        // Include the original index in ties so Android's stable sort is reproduced.
        roads = roads.enumerated().sorted { $0.element.cls == $1.element.cls ? $0.offset < $1.offset : $0.element.cls > $1.element.cls }.map(\.element)
        pois = pois.enumerated().sorted {
            let a = hypot($0.element.points[0] - cx, $0.element.points[1] - cy)
            let b = hypot($1.element.points[0] - cx, $1.element.points[1] - cy)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        let ox = roundMeters(cx), oy = roundMeters(cy)
        var encoded: [(cls: Int, points: [Int])] = [], bytes = 12
        for part in areas + holes + roads + pois {
            var quantized: [Int] = []
            for i in stride(from: 0, to: part.points.count, by: 2) {
                let x = roundMeters(part.points[i] - Double(ox)), y = roundMeters(part.points[i + 1] - Double(oy))
                guard (-32768...32767).contains(x), (-32768...32767).contains(y) else { throw EncodeError.invalidCoordinates }
                if quantized.count >= 2 && quantized[quantized.count - 2] == x && quantized.last == y { continue }
                quantized.append(x); quantized.append(y)
            }
            if quantized.count < (part.poly ? 6 : part.cls >= 20 ? 2 : 4) { continue }
            var start = 0
            while start < quantized.count {
                let end = min(quantized.count, start + 8000)
                guard !part.poly || end == quantized.count else { throw EncodeError.oversizedPolygon }
                bytes += 3 + (end - start) * 2
                guard encoded.count < maximumFeatures, bytes <= maximumBytes else { throw EncodeError.oversizedMap }
                encoded.append((part.cls | (part.poly ? 128 : 0), Array(quantized[start..<end])))
                if end == quantized.count { break }
                start = end - 2
            }
        }
        var buffer = MapGeo.Buf()
        buffer.u16(frame.id); buffer.i32(ox); buffer.i32(oy); buffer.u16(encoded.count)
        for part in encoded {
            buffer.u8(part.cls); buffer.u16(part.points.count / 2)
            for coordinate in part.points { buffer.u16(coordinate) }
        }
        guard valid(buffer.b, frame: frame.id, cx: ox, cy: oy) else { throw EncodeError.emptyRoads }
        return buffer.b
    }

    /// AA13 rejects an entire map containing a POI above class 26. Retain the
    /// complete cached packet, but send only its supported symbols and geometry.
    static func legacyDisplayPacket(_ data: Data) -> Data {
        guard (19...maximumBytes).contains(data.count) else { return data }
        let bytes = Array(data)
        func u16(_ index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 }
        let count = u16(10)
        guard (1...maximumFeatures).contains(count) else { return data }
        var result = Data(bytes.prefix(12)), position = 12, retained = 0
        for _ in 0..<count {
            guard position + 3 <= bytes.count else { return data }
            let start = position, cls = Int(bytes[position]), points = u16(position + 1)
            guard (1...4000).contains(points), points * 4 <= bytes.count - position - 3 else { return data }
            position += 3 + points * 4
            if !(27...47).contains(cls) {
                result.append(contentsOf: bytes[start..<position]); retained += 1
            }
        }
        guard position == bytes.count, retained != count else { return data }
        result[10] = UInt8(truncatingIfNeeded: retained)
        result[11] = UInt8(truncatingIfNeeded: retained >> 8)
        return result
    }

    static func valid(_ data: Data, frame: Int, cx: Int, cy: Int) -> Bool {
        guard (19...maximumBytes).contains(data.count), (0...65535).contains(frame) else { return false }
        let bytes = Array(data)
        func u16(_ index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 }
        func i32(_ index: Int) -> Int { Int(Int32(bitPattern: UInt32(u16(index)) | UInt32(u16(index + 2)) << 16)) }
        guard u16(0) == frame, i32(2) == cx, i32(6) == cy else { return false }
        let count = u16(10)
        guard (1...maximumFeatures).contains(count) else { return false }
        var position = 12
        for _ in 0..<count {
            guard position + 3 <= bytes.count else { return false }
            let cls = Int(bytes[position]), points = u16(position + 1); position += 3
            guard (1...6).contains(cls) || (20...47).contains(cls) || cls == 138 || cls == 139,
                  (1...4000).contains(points), !(cls < 20 && points < 2), !(cls >= 128 && points < 3),
                  points * 4 <= bytes.count - position else { return false }
            position += points * 4
        }
        return position == bytes.count
    }
}
