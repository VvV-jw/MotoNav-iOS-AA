import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cached z14 OpenFreeMap tiles produce full type-1 geometry, without a GPU
/// screenshot or an iOS foreground capture requirement. Call on a worker queue.
enum GtaVectorMaps {
    struct Result { let bytes: Data; let tiles: Int; let fromCache: Int }
    enum MapError: Error, LocalizedError {
        case cancelled, invalidDirectory, invalidRange, download(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "GTA 地图任务已取消"
            case .invalidDirectory: return "GTA 矢量地图目录无效"
            case .invalidRange: return "GTA 矢量地图范围异常"
            case .download(let message): return "GTA 矢量地图下载失败：\(message)"
            }
        }
    }

    private static let lease = NSLock(), statusLock = NSLock()
    private static var status = "GTA 矢量路网等待准备"
    static var state: String { statusLock.lock(); defer { statusLock.unlock() }; return status }
    private static func setState(_ value: String) { statusLock.lock(); status = value; statusLock.unlock() }

    /// Optional cache/fetch arguments let the same production path be exercised
    /// against local fixtures without internet access or an Apple device.
    static func build(_ frame: MapGeo.Frame, cx: Double, cy: Double,
                      shouldCancel: @escaping () -> Bool,
                      cacheDirectory: URL? = nil,
                      fetch: ((URL) throws -> Data)? = nil,
                      forceRefresh: Bool = false, refreshAfter: Date? = nil) throws -> Result {
        func check() throws { if shouldCancel() { throw MapError.cancelled } }
        while !lease.try() { try check(); Thread.sleep(forTimeInterval: 0.1) }
        defer { lease.unlock() }
        try check()
        let manager = FileManager.default
        let directory = try cacheDirectory ?? manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ofm_tiles_v1", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        func load(_ url: URL) throws -> Data {
            try check()
            let bytes = try fetch?(url) ?? download(url, shouldCancel: shouldCancel)
            try check()
            guard bytes.count <= 4_000_000 else { throw MapError.download("瓦片大小异常") }
            return bytes
        }
        let manifest = directory.appendingPathComponent("planet.json")
        let refreshBoundary = refreshAfter ?? Date()
        var template: String?
        if let bytes = boundedFile(manifest, maximumBytes: 1_000_000) { template = try? tileTemplate(bytes) }
        let modified = (try? manager.attributesOfItem(atPath: manifest.path)[.modificationDate]) as? Date ?? .distantPast
        if (forceRefresh && modified < refreshBoundary) || template == nil || Date().timeIntervalSince(modified) > 7 * 24 * 3600 {
            setState("正在读取 GTA 矢量地图目录")
            do {
                let bytes = try load(URL(string: "https://tiles.openfreemap.org/planet")!)
                let fresh = try tileTemplate(bytes)
                try bytes.write(to: manifest, options: .atomic)
                template = fresh
            } catch {
                try check()
                if forceRefresh || template == nil { throw error }
                // A complete, validated older directory and its tiles remain usable offline.
            }
        }
        guard let tileURL = template else { throw MapError.invalidDirectory }
        let tiles = try tileCoordinates(frame, cx: cx, cy: cy)
        let version = directory.appendingPathComponent(templateKey(tileURL), isDirectory: true)
        try manager.createDirectory(at: version, withIntermediateDirectories: true)
        let workers = OperationQueue()
        workers.name = "motonav.gta.tiles"; workers.maxConcurrentOperationCount = 4
        workers.qualityOfService = .userInitiated
        let results = TileResults(count: tiles.count)
        for (index, coordinate) in tiles.enumerated() {
            workers.addOperation {
                do {
                    try check()
                    if results.hasError { return }
                    let file = version.appendingPathComponent("14_\(coordinate.x)_\(coordinate.y).pbf")
                    var cached = false
                    let data: Data
                    let written = (try? manager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date ?? .distantPast
                    if (!forceRefresh || written >= refreshBoundary), let bytes = boundedFile(file, maximumBytes: 4_000_000), (try? MvtTile.decode(bytes)) != nil {
                        cached = true; data = bytes
                    } else {
                        let text = tileURL.replacingOccurrences(of: "{z}", with: "14").replacingOccurrences(of: "{x}", with: String(coordinate.x)).replacingOccurrences(of: "{y}", with: String(coordinate.y))
                        guard let url = URL(string: text) else { throw MapError.invalidDirectory }
                        data = try load(url)
                        _ = try MvtTile.decode(data) // Empty ocean tiles are valid, malformed PBF is not.
                        try check()
                        try data.write(to: file, options: .atomic)
                    }
                    results.store(GtaVectorCodec.Tile(z: 14, x: coordinate.x, y: coordinate.y, data: data), at: index, cached: cached)
                    setState("GTA 矢量瓦片 \(results.completed)/\(tiles.count)，保留圆屏当前路网")
                } catch { results.fail(error) }
            }
        }
        workers.waitUntilAllOperationsAreFinished()
        try check()
        let snapshot = try results.snapshot()
        let bytes = try GtaVectorCodec.encode(frame, cx: cx, cy: cy, tiles: snapshot.tiles)
        try check()
        guard GtaVectorCodec.valid(bytes, frame: frame.id, cx: GtaVectorCodec.roundMeters(cx), cy: GtaVectorCodec.roundMeters(cy)) else { throw GtaVectorCodec.EncodeError.emptyRoads }
        trimTileCache(directory, keeping: Set(tiles.map { version.appendingPathComponent("14_\($0.x)_\($0.y).pbf").path }))
        setState("GTA 完整分级路网已准备：\(bytes.count / 1024) KB，覆盖 4.8 公里")
        return Result(bytes: bytes, tiles: tiles.count, fromCache: snapshot.cached)
    }

    static func tileCoordinates(_ frame: MapGeo.Frame, cx: Double, cy: Double) throws -> [(x: Int, y: Int)] {
        let northwest = MapGeo.gcjToWgs(frame.lat(cy + GtaVectorCodec.HALF + 50), frame.lng(cx - GtaVectorCodec.HALF - 50))
        let southeast = MapGeo.gcjToWgs(frame.lat(cy - GtaVectorCodec.HALF - 50), frame.lng(cx + GtaVectorCodec.HALF + 50))
        guard northwest.lat.isFinite, northwest.lng.isFinite, southeast.lat.isFinite, southeast.lng.isFinite,
              abs(northwest.lat) <= 85, abs(southeast.lat) <= 85,
              abs(northwest.lng) <= 180, abs(southeast.lng) <= 180 else { throw MapError.invalidRange }
        let scale = 16384.0
        func x(_ lng: Double) -> Int { min(16383, max(0, Int(floor((lng + 180) / 360 * scale)))) }
        func y(_ lat: Double) -> Int {
            let radians = lat * .pi / 180
            return min(16383, max(0, Int(floor((1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * scale))))
        }
        let x0 = x(northwest.lng), x1 = x(southeast.lng), y0 = y(northwest.lat), y1 = y(southeast.lat)
        guard x1 >= x0, y1 >= y0, (x1 - x0 + 1) * (y1 - y0 + 1) <= 36 else { throw MapError.invalidRange }
        return (y0...y1).flatMap { row in (x0...x1).map { (x: $0, y: row) } }
    }

    static func tileTemplate(_ data: Data) throws -> String {
        guard data.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let templates = object["tiles"] as? [String], let first = templates.first,
              first.hasPrefix("https://tiles.openfreemap.org/planet/"),
              first.contains("{z}"), first.contains("{x}"), first.contains("{y}"),
              let url = URL(string: first.replacingOccurrences(of: "{z}", with: "14").replacingOccurrences(of: "{x}", with: "0").replacingOccurrences(of: "{y}", with: "0")),
              url.scheme == "https", url.host == "tiles.openfreemap.org", url.user == nil, url.password == nil else { throw MapError.invalidDirectory }
        return first
    }

    /// Directory changes cannot mix old and new planet snapshots in one tile cache.
    private static func templateKey(_ template: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in template.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%016llx", hash)
    }

    private static func boundedFile(_ url: URL, maximumBytes: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumBytes),
              let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
        return data
    }

    /// Full along-route packets live in RouteMapCache. Raw tiles are a bounded,
    /// re-downloadable cache and cannot grow indefinitely across planet updates.
    private static func trimTileCache(_ directory: URL, keeping: Set<String>) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = [], total: Int64 = 0
        for case let file as URL in enumerator where file.pathExtension == "pbf" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0); total += size
            if !keeping.contains(file.path) { files.append((file, size, values.contentModificationDate ?? .distantPast)) }
        }
        let limit: Int64 = 256 * 1024 * 1024
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            if (try? manager.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    private static func download(_ url: URL, shouldCancel: @escaping () -> Bool) throws -> Data {
        let request = BoundedRequest()
        return try request.run(url, shouldCancel: shouldCancel)
    }

    private final class TileResults {
        private let lock = NSLock()
        private var tiles: [GtaVectorCodec.Tile?]
        private var error: Error?
        private var cached = 0
        init(count: Int) { tiles = Array(repeating: nil, count: count) }
        var completed: Int { lock.lock(); defer { lock.unlock() }; return tiles.compactMap { $0 }.count }
        var hasError: Bool { lock.lock(); defer { lock.unlock() }; return error != nil }
        func store(_ tile: GtaVectorCodec.Tile, at index: Int, cached: Bool) {
            lock.lock(); defer { lock.unlock() }
            tiles[index] = tile; if cached { self.cached += 1 }
        }
        func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; if self.error == nil { self.error = error } }
        func snapshot() throws -> (tiles: [GtaVectorCodec.Tile], cached: Int) {
            lock.lock(); defer { lock.unlock() }
            if let error = error { throw error }
            let all = tiles.compactMap { $0 }
            guard all.count == tiles.count else { throw MapError.download("瓦片未完整收到") }
            return (all, cached)
        }
    }

    /// Delegate-level byte limit applies even to chunked or gzip-expanded responses.
    private final class BoundedRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        private let complete = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var bytes = Data(), failure: Error?

        func run(_ url: URL, shouldCancel: @escaping () -> Bool) throws -> Data {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.setValue("MotoNav-iOS/aa1 (OpenFreeMap map cache)", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request); task.resume()
            while complete.wait(timeout: .now() + 0.15) == .timedOut {
                if shouldCancel() { task.cancel(); throw MapError.cancelled }
            }
            if shouldCancel() { throw MapError.cancelled }
            lock.lock(); defer { lock.unlock() }
            if let error = failure { throw error }
            return bytes
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let url = request.url
            completionHandler(url?.scheme == "https" && url?.host == "tiles.openfreemap.org" ? request : nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 4_000_000 else {
                lock.lock(); failure = MapError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"); lock.unlock()
                completionHandler(.cancel); return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard data.count <= 4_000_000 - bytes.count else { failure = MapError.download("瓦片大小异常"); dataTask.cancel(); return }
            bytes.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); if failure == nil { failure = error }; lock.unlock()
            complete.signal()
        }
    }
}
