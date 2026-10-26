import Foundation

// Only the platform/provider boundary is replaced. RouteOfflineMaps, timers, workers,
// cancellation, map packet validation and the disk cache all use production code.
#if !canImport(UIKit)
final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
#endif

enum MapFeeder { static let SRC_AMAP = 3 }

enum AmapSdkRaster {
    struct Packet { let bytes: Data }
    static func build(_ frame: MapGeo.Frame, cx: Double, cy: Double, includeBuildings: Bool,
                      shouldCancel: () -> Bool, onBaseReady: (Data) -> Void,
                      onBuildingStatus: (String) -> Void, style: Int) throws -> Packet {
        preconditionFailure("Offline replay must inject a packet builder; no GPU/network SDK calls are allowed")
    }
}
