import Foundation

/// A route window and retry decisions contain no SDK, disk or timer work.
enum OfflinePreparationPolicy {
    static let rangesKm = [0, 5, 20, 50]
    static func normalizedRangeKm(_ value: Int) -> Int { rangesKm.contains(value) ? value : 0 }

    struct Window: Equatable {
        let lower: Int, upper: Int, target: Int, rangeKm: Int
        var indexes: [Int] { upper >= lower ? Array(lower...upper) : [] }
        var priority: [Int] {
            guard upper >= lower else { return [] }
            return Array(target...upper) + Array(lower..<target)
        }
        func hasSameCoverage(as other: Window) -> Bool { lower == other.lower && upper == other.upper }
    }

    static func window(distances: [Double], target: Int, rangeKm: Int) -> Window {
        let range = normalizedRangeKm(rangeKm)
        guard !distances.isEmpty else { return Window(lower: 0, upper: -1, target: 0, rangeKm: range) }
        let target = min(distances.count - 1, max(0, target))
        guard range > 0 else { return Window(lower: 0, upper: distances.count - 1, target: target, rangeKm: 0) }
        let end = distances[target] + Double(range) * 1000
        let upper = (target..<distances.count).first { distances[$0] >= end } ?? distances.count - 1
        return Window(lower: max(0, target - 2), upper: upper, target: target, rangeKm: range)
    }

    struct Failure: Equatable {
        let attempts: Int
        let retryAt: Date
    }
    struct Backoff {
        private(set) var failures: [Int: Failure] = [:]
        static func delay(attempt: Int) -> TimeInterval {
            let seconds: [TimeInterval] = [15, 30, 60, 120, 240, 300]
            return seconds[min(seconds.count - 1, max(0, attempt - 1))]
        }
        mutating func fail(_ index: Int, at date: Date) {
            let attempts = min(6, (failures[index]?.attempts ?? 0) + 1)
            failures[index] = Failure(attempts: attempts, retryAt: date.addingTimeInterval(Self.delay(attempt: attempts)))
        }
        mutating func succeed(_ index: Int) { failures.removeValue(forKey: index) }
        /// Explicit retry only resets the selected window, retaining other route failures.
        mutating func retry(_ indexes: [Int]) { for index in indexes { failures.removeValue(forKey: index) } }
        func isEligible(_ index: Int, at date: Date) -> Bool { (failures[index]?.retryAt ?? .distantPast) <= date }
        func failedCount(in indexes: [Int]) -> Int { indexes.reduce(0) { $0 + (failures[$1] == nil ? 0 : 1) } }
    }
    struct Work: Equatable {
        let index: Int
        let includeBuildings: Bool
    }
    struct Selection {
        let work: Work?
        /// Set only when every pending block in the current stage is backing off.
        let retryAt: Date?
    }
    static func select(window: Window, baseReady: [Bool], freshBase: [Bool], freshDetails: [Bool],
                       buildings: Bool, backoff: Backoff, at date: Date) -> Selection {
        let indexes = window.priority
        func value(_ flags: [Bool], _ index: Int) -> Bool { flags.indices.contains(index) && flags[index] }
        let basePending = indexes.filter { !value(freshBase, $0) }
        let pending = basePending.isEmpty ? indexes.filter { !value(freshDetails, $0) } : basePending
        let eligible = pending.filter { backoff.isEligible($0, at: date) }
        let next = eligible.first { !value(baseReady, $0) } ?? eligible.first
        if let index = next {
            return Selection(work: Work(index: index, includeBuildings: buildings && basePending.isEmpty), retryAt: nil)
        }
        return Selection(work: nil, retryAt: pending.compactMap { backoff.failures[$0]?.retryAt }.min())
    }
}
