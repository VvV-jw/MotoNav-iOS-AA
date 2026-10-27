import Foundation

/// Bounded atomic persistence. Publish new in-memory contents only after the
/// replacement file is written, so a failed rename/delete remains reviewable.
final class JourneyStore {
    static let maximumCount = 30
    static let maximumBytes = 128 * 1024
    let url: URL
    private let write: (Data, URL) throws -> Void
    init(url: URL = JourneyStore.defaultURL, write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url; self.write = write
    }
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MotoNav", isDirectory: true).appendingPathComponent("journeys-v1.json")
    }
    func load() throws -> [SavedJourney] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes else { throw Failure("常用行程文件过大，未载入") }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw Failure("常用行程文件过大，未载入") }
        let entries = try JSONDecoder().decode([SavedJourney].self, from: data)
        try validate(entries)
        return entries
    }
    func save(_ entries: [SavedJourney]) throws {
        try validate(entries)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        guard data.count <= Self.maximumBytes else { throw Failure("常用行程文件过大，未保存") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(data, url)
    }
    private func validate(_ entries: [SavedJourney]) throws {
        guard entries.count <= Self.maximumCount, entries.allSatisfy(\.isValid), Set(entries.map(\.id)).count == entries.count else {
            throw Failure("常用行程数据无效；最多保存30条，名称最多80字，请检查坐标与途经点数量")
        }
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
