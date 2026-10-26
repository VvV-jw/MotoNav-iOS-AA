import Foundation

/// A restart checkpoint contains an itinerary only. Location, guidance, selected SDK
/// route IDs, simulation progress and countdowns must always be obtained afresh.
struct NavigationRecoveryCheckpoint: Codable, Equatable {
    enum Mode: String, Codable { case drive, motorcycle, bicycle }
    struct Point: Codable, Equatable {
        let name: String
        let lat: Double
        let lng: Double
        var isValid: Bool {
            lat.isFinite && lng.isFinite && abs(lat) <= 90 && abs(lng) <= 180 && name.utf8.count <= 2048
        }
    }
    struct Road: Codable, Equatable {
        let name: String
        let length: Int
        let points: [Point]
    }
    struct ImportedRoute: Codable, Equatable {
        let start: Point
        let end: Point
        let points: [Point]
        let roads: [Road]
        let distance: Int
        let seconds: Int
        let lights: Int
        let restored: Bool
        let kind: String

        var isValid: Bool {
            guard start.isValid, end.isValid, (2...150_000).contains(points.count),
                  points.allSatisfy(\.isValid), roads.count <= 10_000,
                  distance >= 0, distance <= 10_000_000, seconds >= 0, seconds <= 10_000_000,
                  lights >= 0, lights <= 100_000, kind.utf8.count <= 128 else { return false }
            var roadPoints = 0
            for road in roads {
                roadPoints += road.points.count
                guard roadPoints <= 300_000, road.name.utf8.count <= 2048,
                      road.length >= 0, road.length <= 10_000_000, road.points.allSatisfy(\.isValid) else { return false }
            }
            return true
        }
    }

    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    let version: Int
    let id: UUID
    let savedAt: Date
    let mode: Mode
    let destination: Point
    let vias: [Point]
    let avoidHighway: Bool
    let importedRoute: ImportedRoute?

    init(mode: Mode, destination: Point, vias: [Point] = [], avoidHighway: Bool,
         importedRoute: ImportedRoute? = nil, savedAt: Date = Date(), id: UUID = UUID()) {
        version = 1
        self.id = id; self.savedAt = savedAt; self.mode = mode; self.destination = destination
        self.vias = vias; self.avoidHighway = avoidHighway; self.importedRoute = importedRoute
    }

    func isValid(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        guard version == 1, age.isFinite, age >= -300, age <= Self.maximumAge,
              destination.isValid, vias.count <= (mode == .drive ? 3 : 16), vias.allSatisfy(\.isValid),
              mode != .bicycle || vias.isEmpty else { return false }
        if let imported = importedRoute {
            guard vias.isEmpty, imported.isValid,
                  imported.end.lat == destination.lat, imported.end.lng == destination.lng else { return false }
        }
        return true
    }

    /// Recovery cannot use an old SDK-matched position or a synthetic simulation fix.
    static func acceptsFix(lat: Double, lng: Double, accuracy: Double, timestamp: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return Point(name: "", lat: lat, lng: lng).isValid && accuracy.isFinite && accuracy >= 0 && accuracy <= 100
            && age.isFinite && age >= -2 && age <= 15
    }
}

/// Atomic local persistence. Invalid, oversized and expired checkpoints are removed;
/// an unreadable file is never allowed to prevent a normal application launch.
final class NavigationRecoveryStore {
    static let maximumBytes = 24 * 1024 * 1024
    let url: URL
    init(url: URL = NavigationRecoveryStore.defaultURL) { self.url = url }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MotoNav", isDirectory: true).appendingPathComponent("navigation-session.json")
    }

    func load(now: Date = Date()) -> NavigationRecoveryCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber, size.intValue <= Self.maximumBytes else { clear(); return nil }
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(NavigationRecoveryCheckpoint.self, from: data)
            guard value.isValid(now: now) else { clear(); return nil }
            return value
        } catch { clear(); return nil }
    }

    @discardableResult func save(_ value: NavigationRecoveryCheckpoint, now: Date = Date()) -> Bool {
        guard value.isValid(now: now), let data = try? JSONEncoder().encode(value), data.count <= Self.maximumBytes else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var localURL = url
            try? localURL.setResourceValues(values)
            return true
        } catch { return false }
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Recovery network work is independent of SDK delegate generations. Both gates
/// are closed when the user changes/ends a trip; all access is on the main queue.
final class NavigationRecoveryGate {
    struct Ticket: Equatable {
        fileprivate let generation: UInt64
        fileprivate let checkpointID: UUID
    }
    private var generation: UInt64 = 0
    func invalidate() { generation &+= 1 }
    func begin(_ checkpointID: UUID) -> Ticket {
        invalidate()
        return Ticket(generation: generation, checkpointID: checkpointID)
    }
    func isCurrent(_ ticket: Ticket) -> Bool { generation == ticket.generation }
    func accepts(_ ticket: Ticket, pendingID: UUID?) -> Bool { isCurrent(ticket) && pendingID == ticket.checkpointID }
}
