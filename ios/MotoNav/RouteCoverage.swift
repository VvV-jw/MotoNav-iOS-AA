import Foundation

/// Passive full-viewport coverage along the actual polyline, independent of navigation or downloads.
/// Call on a worker queue. No I/O, SDK, locations or route identities are retained by this core.
enum RouteCoverage {
    static let viewportRadius = 292.0 / 0.38 + 50.0
    enum State: String { case scanning = "SCANNING", ready = "READY", gap = "GAP", unknown = "UNKNOWN" }
    struct Result: Equatable {
        let state: State
        let contiguousMetersAhead: Double, firstGapMeters: Double
        let inspectedEndMeters: Double, totalMeters: Double
        var fromMeters: Double = 0
        var candidateChecks: Int = 0
        var progressMeters: Double { fromMeters }
        static func == (a: Result, b: Result) -> Bool {
            a.state == b.state && a.contiguousMetersAhead == b.contiguousMetersAhead &&
                (a.firstGapMeters == b.firstGapMeters || a.firstGapMeters.isNaN && b.firstGapMeters.isNaN) &&
                a.inspectedEndMeters == b.inspectedEndMeters && a.totalMeters == b.totalMeters && a.fromMeters == b.fromMeters
        }
        var title: String {
            switch state {
            case .scanning: return "正在核对沿线可用范围"
            case .ready: return "剩余沿线路网连续可用"
            case .gap: return "已发现待准备路段"
            case .unknown: return "准备范围外尚未核对"
            }
        }
        var detail: String {
            let distance = String(format: "%.1f", contiguousMetersAhead / 1000)
            switch state {
            case .scanning: return "缓存检查完成后显示连续可用距离；不影响开始导航"
            case .ready: return "从核对起点连续可用 \(distance) 公里；仅表示本机地图包覆盖"
            case .gap: return "从核对起点连续可用 \(distance) 公里，之后仍需准备；已有旧图也计入可用"
            case .unknown: return "已核对部分连续可用 \(distance) 公里；范围外未核对，不代表地图缺失"
            }
        }
    }
    static func scanning(totalMeters: Double, progressMeters: Double = 0) -> Result {
        Result(state: .scanning, contiguousMetersAhead: 0, firstGapMeters: .nan,
               inspectedEndMeters: 0, totalMeters: max(0, totalMeters), fromMeters: max(0, min(totalMeters, progressMeters)))
    }
    private struct Cell: Hashable { let x: Int, y: Int }
    private struct Interval { let lo: Double, hi: Double }

    static func evaluate(routeXY: [Double], readyCentersXY: [Double], half: Double,
                         progressMeters: Double, inspectedStartMeters: Double, inspectedEndMeters: Double,
                         shouldCancel: () -> Bool = { false }) -> Result {
        let inset = half - viewportRadius
        guard routeXY.count >= 4, routeXY.count <= 2_000_000, routeXY.count % 2 == 0,
              readyCentersXY.count <= 200_000, readyCentersXY.count % 2 == 0,
              routeXY.allSatisfy({ $0.isFinite && abs($0) < 1e9 }), readyCentersXY.allSatisfy({ $0.isFinite && abs($0) < 1e9 }),
              inset.isFinite, inset >= 1, inset <= 1e7, progressMeters.isFinite else {
            return Result(state: .unknown, contiguousMetersAhead: 0, firstGapMeters: .nan, inspectedEndMeters: 0, totalMeters: 0)
        }
        var cumulative = [Double](repeating: 0, count: routeXY.count / 2)
        for i in 1..<cumulative.count {
            if shouldCancel() { return scanning(totalMeters: 0) }
            cumulative[i] = cumulative[i - 1] + hypot(routeXY[2*i] - routeXY[2*i-2], routeXY[2*i+1] - routeXY[2*i-1])
        }
        let total = cumulative.last ?? 0, start = min(total, max(0, progressMeters))
        var checks = 0
        func result(_ state: State, _ continuous: Double, gap: Double = .nan, end: Double) -> Result {
            Result(state: state, contiguousMetersAhead: max(0, continuous - start), firstGapMeters: gap,
                   inspectedEndMeters: end, totalMeters: total, fromMeters: start, candidateChecks: checks)
        }
        guard inspectedStartMeters.isFinite, inspectedEndMeters.isFinite,
              inspectedStartMeters >= 0, inspectedEndMeters >= inspectedStartMeters else { return scanning(totalMeters: total, progressMeters: start) }
        let end = min(total, inspectedEndMeters)
        guard start + 1e-6 >= inspectedStartMeters, end + 1e-6 >= start else { return result(.unknown, start, end: end) }
        let cellSize = max(1, inset * 2)
        func cell(_ x: Double) -> Int { Int(floor(x / cellSize)) }
        var grid: [Cell: [Int]] = [:]
        for tile in 0..<(readyCentersXY.count / 2) {
            if shouldCancel() { return scanning(totalMeters: total) }
            let x = readyCentersXY[tile * 2], y = readyCentersXY[tile * 2 + 1]
            for cx in cell(x-inset)...cell(x+inset) {
                for cy in cell(y-inset)...cell(y+inset) { grid[Cell(x: cx, y: cy), default: []].append(tile) }
            }
        }
        var intervals: [Interval] = []
        var seen = [Int](repeating: -1, count: readyCentersXY.count / 2)
        func clip(_ ax: Double, _ ay: Double, _ dx: Double, _ dy: Double, _ tx: Double, _ ty: Double) -> (Double, Double)? {
            var lo = 0.0, hi = 1.0
            for (p, q) in [(-dx, ax - tx + inset), (dx, tx + inset - ax), (-dy, ay - ty + inset), (dy, ty + inset - ay)] {
                if abs(p) < 1e-12 { if q < 0 { return nil }; continue }
                let r = q / p
                if p < 0 { lo = max(lo, r) } else { hi = min(hi, r) }
                if lo > hi { return nil }
            }
            return (lo, hi)
        }
        for i in 1..<cumulative.count {
            if shouldCancel() { return scanning(totalMeters: total) }
            let length = cumulative[i] - cumulative[i-1]
            if length <= 0 || cumulative[i] < start || cumulative[i-1] > end { continue }
            let low = max(start, cumulative[i-1]), high = min(end, cumulative[i])
            let fraction0 = (low - cumulative[i-1]) / length, fraction1 = (high - cumulative[i-1]) / length
            let dx = routeXY[i*2] - routeXY[i*2-2], dy = routeXY[i*2+1] - routeXY[i*2-1]
            let ax = routeXY[i*2-2] + dx * fraction0, ay = routeXY[i*2-1] + dy * fraction0
            let bx = routeXY[i*2-2] + dx * fraction1, by = routeXY[i*2-1] + dy * fraction1
            let sx = bx - ax, sy = by - ay
            var cx = cell(ax), cy = cell(ay)
            let ex = cell(bx), ey = cell(by), stepx = sx < 0 ? -1 : 1, stepy = sy < 0 ? -1 : 1
            let deltax = sx == 0 ? Double.infinity : cellSize / abs(sx)
            let deltay = sy == 0 ? Double.infinity : cellSize / abs(sy)
            var nextx = sx == 0 ? Double.infinity : ((Double(cx + (stepx > 0 ? 1 : 0)) * cellSize - ax) / sx)
            var nexty = sy == 0 ? Double.infinity : ((Double(cy + (stepy > 0 ? 1 : 0)) * cellSize - ay) / sy)
            var steps = 0
            while true {
                if shouldCancel() { return scanning(totalMeters: total) }
                for tile in grid[Cell(x: cx, y: cy)] ?? [] where seen[tile] != i {
                    seen[tile] = i
                    checks += 1
                    if checks > 2_000_000 { return scanning(totalMeters: total, progressMeters: start) }
                    if let (lo, hi) = clip(ax, ay, sx, sy, readyCentersXY[tile*2], readyCentersXY[tile*2+1]) {
                        intervals.append(Interval(lo: low + lo * (high-low), hi: low + hi * (high-low)))
                        if intervals.count > 500_000 { return scanning(totalMeters: total, progressMeters: start) }
                    }
                }
                if cx == ex && cy == ey { break }
                // Defensive bound for hostile coordinates; never turn a partial traversal into READY.
                steps += 1
                if steps > 2_000_000 { return scanning(totalMeters: total, progressMeters: start) }
                if nextx < nexty { cx += stepx; nextx += deltax }
                else if nexty < nextx { cy += stepy; nexty += deltay }
                else { cx += stepx; cy += stepy; nextx += deltax; nexty += deltay }
            }
        }
        intervals.sort { $0.lo < $1.lo }
        var continuous = start
        for interval in intervals {
            if shouldCancel() { return scanning(totalMeters: total) }
            if interval.lo > continuous + 1e-6 { break }
            continuous = max(continuous, interval.hi)
            if continuous >= end - 1e-6 { break }
        }
        if continuous < end - 1e-6 { return result(.gap, continuous, gap: continuous, end: end) }
        if end < total - 1e-6 { return result(.unknown, continuous, end: end) }
        // A zero-length remainder still needs an actually usable full viewport at the destination.
        if start >= total - 1e-6 {
            let x = routeXY[routeXY.count-2], y = routeXY[routeXY.count-1]
            let covered = (0..<(readyCentersXY.count/2)).contains { abs(x-readyCentersXY[2*$0]) <= inset && abs(y-readyCentersXY[2*$0+1]) <= inset }
            if !covered { return result(.gap, start, gap: start, end: end) }
        }
        return result(.ready, end, end: end)
    }
}
