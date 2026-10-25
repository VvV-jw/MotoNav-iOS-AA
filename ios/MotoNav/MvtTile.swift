import Foundation

/// Bounded Mapbox Vector Tile reader, shared in behaviour with the Android aa.4 reader.
/// Only geometry needed by the circular GTA map is materialised. A malformed tile
/// fails the whole request so the receiver can retain its last complete basemap.
enum MvtTile {
    struct Feature {
        let layer: String
        let extent: Int
        let type: Int
        let id: UInt64
        let tags: [String: String]
        let paths: [[Int]]
    }

    enum DecodeError: Error { case invalidTile }
    private static let maximumBytes = 4_000_000
    private static let selectedLayers: Set<String> = ["transportation", "water", "waterway", "poi"]

    private struct Reader {
        let data: [UInt8]
        var position = 0
        var ended: Bool { position == data.count }

        init(_ data: [UInt8]) { self.data = data }

        mutating func number() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard position < data.count else { throw DecodeError.invalidTile }
                let byte = data[position]; position += 1
                if shift == 63 && byte > 1 { throw DecodeError.invalidTile }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw DecodeError.invalidTile
        }

        mutating func key() throws -> Int {
            let value = try number()
            guard value >> 3 > 0, value <= UInt64(Int32.max) else { throw DecodeError.invalidTile }
            return Int(value)
        }

        mutating func bytes() throws -> [UInt8] {
            let count = try number()
            guard count <= UInt64(data.count - position) else { throw DecodeError.invalidTile }
            let end = position + Int(count)
            defer { position = end }
            return Array(data[position..<end])
        }

        mutating func skip(_ wire: Int) throws {
            switch wire {
            case 0: _ = try number()
            case 2: _ = try bytes()
            case 1, 5:
                let size = wire == 1 ? 8 : 4
                guard size <= data.count - position else { throw DecodeError.invalidTile }
                position += size
            default: throw DecodeError.invalidTile
            }
        }
    }

    private static func text(_ bytes: [UInt8]) throws -> String {
        guard let value = String(bytes: bytes, encoding: .utf8) else { throw DecodeError.invalidTile }
        return value
    }

    private static func value(_ bytes: [UInt8]) throws -> String {
        var reader = Reader(bytes), result = ""
        while !reader.ended {
            let key = try reader.key(), field = key >> 3, wire = key & 7
            if field == 1 && wire == 2 { result = try text(reader.bytes()) }
            else if (4...7).contains(field) && wire == 0 {
                let number = try reader.number()
                if field == 6 { result = String(Int64(bitPattern: (number >> 1) ^ (0 &- (number & 1)))) }
                else { result = String(number) }
            } else { try reader.skip(wire) }
        }
        return result
    }

    static func decode(_ data: Data) throws -> [Feature] {
        guard data.count <= maximumBytes else { throw DecodeError.invalidTile }
        var reader = Reader(Array(data)), result: [Feature] = [], pointBudget = 1_000_000
        while !reader.ended {
            let key = try reader.key()
            if key == 26 { try layer(reader.bytes(), into: &result, pointBudget: &pointBudget) }
            else { try reader.skip(key & 7) }
        }
        return result
    }

    private static func layer(_ data: [UInt8], into result: inout [Feature], pointBudget: inout Int) throws {
        var reader = Reader(data), name = "", extent = 4096
        var keys: [String] = [], values: [String] = [], features: [[UInt8]] = []
        while !reader.ended {
            let key = try reader.key()
            switch key {
            case 10: name = try text(reader.bytes())
            case 18:
                guard features.count < 50_000 else { throw DecodeError.invalidTile }
                features.append(try reader.bytes())
            case 26: keys.append(try text(reader.bytes()))
            case 34: values.append(try value(reader.bytes()))
            case 40:
                let number = try reader.number()
                guard number > 0 && number <= 65536 else { throw DecodeError.invalidTile }
                extent = Int(number)
            default: try reader.skip(key & 7)
            }
        }
        guard selectedLayers.contains(name) else { return }
        guard result.count + features.count <= 50_000 else { throw DecodeError.invalidTile }
        for bytes in features {
            var feature = Reader(bytes), identifier: UInt64 = 0, type = 0
            var tags: [UInt8]?, geometry: [UInt8]?
            while !feature.ended {
                let key = try feature.key()
                switch key {
                case 8: identifier = try feature.number()
                case 18: tags = try feature.bytes()
                case 24:
                    let number = try feature.number()
                    guard number <= 3 else { throw DecodeError.invalidTile }
                    type = Int(number)
                case 34: geometry = try feature.bytes()
                default: try feature.skip(key & 7)
                }
            }
            var attributes: [String: String] = [:]
            if let tags = tags {
                var tagReader = Reader(tags)
                while !tagReader.ended {
                    let key = try tagReader.number(), index = try tagReader.number()
                    guard key < UInt64(keys.count), index < UInt64(values.count) else { throw DecodeError.invalidTile }
                    attributes[keys[Int(key)]] = values[Int(index)]
                }
            }
            if let geometry = geometry {
                let paths = try paths(geometry, pointBudget: &pointBudget)
                if !paths.isEmpty {
                    result.append(Feature(layer: name, extent: extent, type: type, id: identifier, tags: attributes, paths: paths))
                }
            }
        }
    }

    private static func paths(_ data: [UInt8], pointBudget: inout Int) throws -> [[Int]] {
        var reader = Reader(data), x = 0, y = 0, current: [Int]?, result: [[Int]] = [], closed = false
        while !reader.ended {
            let header = try reader.number(), command = header & 7, count = header >> 3
            guard count > 0 && count <= 1_000_000 else { throw DecodeError.invalidTile }
            if command == 7 {
                guard count == 1, !closed, pointBudget > 0, var path = current, path.count >= 6 else { throw DecodeError.invalidTile }
                pointBudget -= 1; closed = true
                path.append(path[0]); path.append(path[1]); current = path
                continue
            }
            guard command == 1 || command == 2, count <= UInt64(pointBudget) else { throw DecodeError.invalidTile }
            if command == 2 && closed { throw DecodeError.invalidTile }
            for _ in 0..<Int(count) {
                let dx = try reader.number(), dy = try reader.number()
                guard dx <= UInt64(UInt32.max), dy <= UInt64(UInt32.max) else { throw DecodeError.invalidTile }
                let deltaX = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: (dx >> 1) ^ (0 &- (dx & 1)))))
                let deltaY = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: (dy >> 1) ^ (0 &- (dy & 1)))))
                x += deltaX; y += deltaY
                guard x >= Int(Int32.min), x <= Int(Int32.max), y >= Int(Int32.min), y <= Int(Int32.max) else { throw DecodeError.invalidTile }
                pointBudget -= 1
                if command == 1 {
                    if let path = current { result.append(path) }
                    current = []; closed = false
                }
                guard current != nil else { throw DecodeError.invalidTile }
                current!.append(x); current!.append(y)
            }
        }
        if let path = current { result.append(path) }
        return result
    }
}
