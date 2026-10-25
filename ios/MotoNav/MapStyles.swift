import Foundation

enum MapStyles {
    static func original(_ raw: [UInt32]) -> (indices: [UInt8], palette: [Int]) {
        // Convenience for deterministic tools/tests; capture workers use the cancellable form.
        (try? original(raw, shouldCancel: { false })) ?? ([], [Int](repeating: 0, count: 16))
    }
    /// Weighted median-cut of the actual SDK image, including its antialias shades.
    /// Taking only the 16 most frequent colours can erase thin roads, labels and rare edge shades.
    /// Keep all 1200² samples and match Android OriginalMapColors' deterministic bucket order.
    static func original(_ raw: [UInt32], shouldCancel: () -> Bool) throws -> (indices: [UInt8], palette: [Int]) {
        guard !raw.isEmpty else { throw MapProcessingError.invalid("高德原版底图没有像素") }
        func check() throws { if shouldCancel() { throw MapProcessingError.cancelled } }
        func key(_ c: UInt32) -> Int { Int((c >> 19) & 31) << 10 | Int((c >> 11) & 31) << 5 | Int((c >> 3) & 31) }
        func component(_ k: Int, _ axis: Int) -> Int { (k >> (10 - axis * 5)) & 31 }
        var histogram = [Int](repeating: 0, count: 32768)
        for i in raw.indices { if i & 16383 == 0 { try check() }; histogram[key(raw[i])] += 1 }
        struct Box {
            let keys: [Int], axis: Int, range: Int, total: Int
            var score: Double { keys.count > 1 ? Double(range) * sqrt(Double(total)) : -1 }
        }
        func box(_ keys: [Int]) -> Box {
            var axis = 0, range = 0
            for a in 0..<3 {
                var lo = 31, hi = 0
                for k in keys { let v = component(k, a); lo = min(lo, v); hi = max(hi, v) }
                if hi - lo > range { axis = a; range = hi - lo }
            }
            return Box(keys: keys, axis: axis, range: range, total: keys.reduce(0) { $0 + histogram[$1] })
        }
        var boxes = [box(histogram.indices.filter { histogram[$0] > 0 })]
        while boxes.count < 16 {
            try check()
            var bestIndex = 0
            for i in boxes.indices where boxes[i].score > boxes[bestIndex].score { bestIndex = i }
            let best = boxes[bestIndex]
            if best.keys.count < 2 { break }
            // The explicit original-index tie break gives Java's stable sort on every Swift version.
            let sorted = best.keys.enumerated().sorted {
                let a = component($0.element, best.axis), b = component($1.element, best.axis)
                return a == b ? $0.offset < $1.offset : a < b
            }.map(\.element)
            var cumulative = 0, cut = 1
            for i in 0..<(sorted.count - 1) {
                cumulative += histogram[sorted[i]]; cut = i + 1
                if cumulative >= best.total / 2 { break }
            }
            boxes.remove(at: bestIndex)
            boxes.append(box(Array(sorted[..<cut]))); boxes.append(box(Array(sorted[cut...])))
        }
        var palette = [Int](repeating: 0, count: 16), lookup = [UInt8](repeating: 0, count: 32768)
        for (i, box) in boxes.enumerated() {
            var r = 0, g = 0, b = 0
            for k in box.keys {
                let count = histogram[k]
                r += component(k, 0) * count; g += component(k, 1) * count; b += component(k, 2) * count
                lookup[k] = UInt8(i)
            }
            let rr = (r + box.total / 2) / box.total, gg = (g + box.total / 2) / box.total, bb = (b + box.total / 2) / box.total
            palette[i] = rr << 11 | ((gg << 1 | gg >> 4) << 5) | bb
        }
        for i in boxes.count..<16 { palette[i] = palette[0] }
        var indices = [UInt8](repeating: 0, count: raw.count)
        for i in raw.indices { if i & 16383 == 0 { try check() }; indices[i] = lookup[key(raw[i])] }
        try check()
        return (indices, palette)
    }
    static func minimal(_ raw: [UInt32], size: Int) -> [UInt8] {
        let mask: [UInt8] = raw.map { c in
            let r = Int((c >> 16) & 255), g = Int((c >> 8) & 255), b = Int(c & 255)
            return (r >= 254 && g >= 254 && b >= 254) || (r >= 200 && g >= 125 && g <= 245 && b+25 < g && r >= g && r-b >= 45) ? 1 : 0
        }
        return MapGeo.cleanRaster(mask, w: size, h: size).map { $0 == 1 ? 1 : 0 }
    }
}
