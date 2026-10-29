// Disposable simulator-only adapters. No network, GPS, BLE or navigation SDK runs.
// All displayed controls come from unmodified production View source files.
#if MOTONAV_SCREENSHOTS
import SwiftUI
import CoreLocation
import WebKit

final class BleLink: ObservableObject {
    static let shared = BleLink()
    @Published var isReady = false
    @Published var status = "测试场景：未连接圆屏"
    var statAt = Date.distantPast, screenFps = "", screenStats = "等待圆屏实测", screenMHz = -1, screenFast = -1
    var mediaHIDSupported = false, mediaHIDReady = false, mediaHIDMode = false, mediaAMSControls = 0
    var mediaSongInfo = "", mediaLyricsActive = false, mediaLyricsSupported = false, mediaLyricsStatus = ""
    var buildingsSupported = false, sentCount = 0, lastSent = "", bulkKB = 0
    func connect() { status = "测试适配器：不连接真实设备" }
    func disconnect() { isReady = false }
    func setScreenMHz(_ value: Int) { screenMHz = value }
    func setScreenFast(_ value: Bool) { screenFast = value ? 1 : 0 }
    func retryBuildingCapability() {}
    func cancelMapBulk() {}
    func send(_ value: String) {}
    func clearWeather() {}
    func sendImage(slot: Int, w: Int, h: Int, data: Data) {}
}

final class SearchService: ObservableObject {
    struct Place: Identifiable { var id = UUID(); var name: String; var address: String; var lat: Double; var lng: Double }
    static let shared = SearchService()
    @Published var results: [Place] = []
    @Published var status = ""
    func clear() { results = []; status = "" }
    func search(_ query: String) { status = "合成搜索结果 · 服务边界已禁用"; results = [.init(name:"测试目的地",address:"合成搜索样本",lat:30.01,lng:120.02)] }
    func queryChanged(_ query: String) {}
    func rebuildAPI() {}
}
final class History: ObservableObject {
    static let shared = History()
    @Published var places: [SearchService.Place] = []
    func add(_ place: SearchService.Place) { places.append(place) }
    func clear() { places = [] }
}
final class LocationService: ObservableObject {
    static let shared = LocationService()
    @Published var location: CLLocation?
    @Published var authorization = CLAuthorizationStatus.notDetermined
    @Published var locationError = ""
    func start() {}
    func readiness(at: Date) -> LocationReadiness.Result {
        LocationReadiness.evaluate(permission: .unknown, fixAge: nil, accuracy: nil, validCoordinate: false, fullAccuracy: false)
    }
}
final class AMapServices {
    static let instance = AMapServices(); var apiKey = ""
    static func shared() -> AMapServices { instance }
}
enum AmapShare {
    struct Route {
        let startName: String, startLat: Double, startLng: Double
        let endName: String, endLat: Double, endLng: Double
        let pts: [(lat: Double, lng: Double)]
        let kind: String, total: Double, distance: Int, timeS: Int
        let restored: Bool
    }
    static func findUrl(_ text: String?) -> String? { nil }
    static func load(_ text: String) throws -> Route { throw URLError(.notConnectedToInternet) }
}
final class MusicBridge {
    static let shared = MusicBridge()
    func authorize() {}; func syncMode() {}; func refresh(force: Bool) {}; func syncLyrics(force: Bool) {}
}
final class Speech { static let shared = Speech(); func test() {}; func stopNow() {} }

final class NaviBridge: ObservableObject {
    static let shared = NaviBridge()
    struct RouteOption: Identifiable {
        let id: Int; let label: String; let timeS: Int; let length: Int; let lights: Int; let toll: Int
    }
    @Published var navigating = false
    @Published var cruising = false
    @Published var calculating = false
    @Published var travelMode: JourneyMode = .drive
    @Published var recoveryBusy = false
    @Published var pendingRecovery: NavigationRecoveryCheckpoint?
    @Published var recoveryStatus = ""
    @Published var routeOptions: [RouteOption] = []
    @Published var selectedRouteID = 0
    @Published var planFailed = false
    @Published var routeReady = false
    @Published var info = "选择目的地后规划路线"
    @Published var uiRoad = ""
    @Published var uiDir = "直行"
    @Published var uiDist = 300
    @Published var uiSpeed = 0
    @Published var uiLightDist = -1
    @Published var uiRemainM = 0
    @Published var uiRemainS = 0
    @Published var uiSuggestMin = 0
    @Published var showArrived = false
    @Published var emulating = false
    @Published var emuPaused = false
    @Published var emuSpeed = 60
    @Published var editingVias = false
    @Published var startCount = 0
    @Published var stopCount = 0
    @Published var vias: [MotorPoint] = []
    private let viaDraftLease = RouteDraftLease()
    private var owner: UInt64 = 1
    var shareRoute: AmapShare.Route?, shareMatch = ""
    var journeyDestination: JourneyPoint? { .init(name: "测试目的地", lat: 30.01, lng: 120.02) }
    var canSkipVia: Bool { navigating && !vias.isEmpty && shareRoute == nil }
    var nextViaName: String { vias.first?.name ?? "" }
    var navigationOwner: UInt64? { navigating ? owner : nil }
    var destCoord = CLLocationCoordinate2D(latitude: 30.0, longitude: 120.0)
    var lastLocation: CLLocation?, laneRaw = "", camRaw = "", cruiseRaw = "", extraInfo = ""
    var countdownRaw = "原生读秒实验：截图替身，不是真实灯相"
    func myPosition() -> (lat: Double, lng: Double)? { nil }
    func restorePendingRecovery() -> Bool { false }
    func preparePendingIndependentRecovery() async -> Bool { false }
    func discardPendingRecovery() { pendingRecovery = nil }
    func cancelRecoveryAttempt() {}; func clearPlan() {}; func clearVias() { vias = [] }
    func addVia(name: String, lat: Double, lng: Double) { vias.append(.init(lat: lat, lng: lng, name: name)) }
    func beginViaEditing() -> RoutePlanningGeneration.Ticket? {
        guard !navigating, !WebMotorSession.shared.running, shareRoute == nil else { return nil }
        editingVias = true; return viaDraftLease.begin()
    }
    func cancelViaEditing(ticket: RoutePlanningGeneration.Ticket?) {
        guard let ticket = ticket, viaDraftLease.cancel(ticket) else { return }
        editingVias = false
    }
    func applyVias(_ points: [JourneyPoint], ticket: RoutePlanningGeneration.Ticket?) {
        guard let ticket = ticket, editingVias, !navigating, shareRoute == nil,
              points.count <= JourneyMode.drive.maximumVias, points.allSatisfy(\.isValid) else { return }
        viaDraftLease.apply(ticket) {
            editingVias = false
            vias = points.map { .init(lat: $0.lat, lng: $0.lng, name: $0.name) }
        }
    }
    func planJourney(_ journey: SavedJourney) -> Bool { false }
    func explainDriveSkip() {}
    func plan(toLat: Double, lng: Double, share: AmapShare.Route? = nil, name: String, mode: JourneyMode = .drive) { travelMode = mode }
    func replan() {}; func replanForPreferenceChange() {}; func select(routeID: Int) { selectedRouteID = routeID }
    func applyVehicleAndReplan() -> Bool { travelMode == .motorcycle }
    func start(emulate: Bool) { startCount += 1; owner &+= 1; navigating = true }
    func stop() { stopCount += 1; navigating = false }
    @discardableResult func stop(ifOwner expected: UInt64?) -> Bool {
        guard JourneyConfirmation.matches(expected, current: navigationOwner, active: navigating) else { return false }
        stop(); return true
    }
    func stopCruise() { cruising = false }; func startCruise() -> String? { "测试场景不启动巡航" }
    func rebuildManager() {}; func acceptSuggest() {}; func clearSuggest() {}
    func toggleEmuPause() { emuPaused.toggle() }; func cycleEmuSpeed() { emuSpeed = 100 }
    static func distM(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double { hypot(c-a, d-b)*111_000 }
    static func distText(_ value: Int) -> String { value >= 1000 ? String(format: "%.1f 公里", Double(value)/1000) : "\(value) 米" }
    static func durText(_ value: Int) -> String { "\(max(1, value/60)) 分钟" }
}

struct MotorPoint { let lat: Double; let lng: Double; var name = ""; var id = "" }
struct MotorRequest { var start: MotorPoint; let end: MotorPoint; var vias: [MotorPoint] = []; var bicycle = false; var originSource: RouteOriginSource = .selectedPlace }
struct MotorRoute: Identifiable {
    let id = UUID(); let request: MotorRequest; let seconds: Int; let totalMeters: Int
    static func sample(bicycle: Bool = false) -> MotorRoute {
        .init(request: .init(start: .init(lat: 30, lng: 120, name: "测试起点"), end: .init(lat: 30.01, lng: 120.02, name: "测试目的地"), bicycle: bicycle), seconds: bicycle ? 1800 : 1200, totalMeters: 12000)
    }
}
enum MotorRoutes {
    static func load(_ request: MotorRequest) async throws -> [MotorRoute] { throw URLError(.notConnectedToInternet) }
    static func fromShare(_ route: AmapShare.Route) -> MotorRoute { .sample() }
}
final class WebMotorSession: ObservableObject {
    static let shared = WebMotorSession()
    @Published var recalculationNotice = IndependentRecalculationNotice()
    @Published var running = false
    @Published var arrived = false
    @Published var overview = true
    @Published var simulation = false
    @Published var paused = false
    @Published var speed = 60
    @Published var bearing: Double = 0
    @Published var remaining = 12000
    @Published var remainingSeconds = 1200
    @Published var turnMetres = 300
    @Published var instruction = "沿测试道路直行"
    @Published var status = "合成路线 · 非真实导航"
    @Published var turnDirection = "S"
    @Published var route: MotorRoute?
    @Published var skipBusy = false
    @Published var skipStatus = ""
    private var owner = UUID()
    var position: MotorPoint?
    var canSkipVia: Bool { running && !simulation && !skipBusy && !(route?.request.vias.isEmpty ?? true) }
    var nextViaName: String? { route?.request.vias.first?.name }
    var navigationOwner: UUID? { running ? owner : nil }
    var skipIntent: JourneySkipIntent? {
        guard nextViaName != nil, let route = route else { return nil }
        return .init(session: owner, route: route.id, cursor: 0)
    }
    var candidateAvailability: RouteSessionAvailability {
        .init(independentNavigation: running, driveNavigation: NaviBridge.shared.navigating,
              cruising: NaviBridge.shared.cruising, drivePlanning: NaviBridge.shared.calculating,
              recovering: NaviBridge.shared.recoveryBusy, independentPlanning: RoutePlanningGeneration.shared.isBusy)
    }
    func installImportedPlan(_ route: MotorRoute, source: AmapShare.Route) -> Bool { self.route = route; return true }
    func selectCandidate(_ route: MotorRoute) -> Bool { self.route = route; return true }
    func start(_ route: MotorRoute, simulate: Bool) { owner = UUID(); self.route = route; simulation = simulate; running = true }
    func stop() { running = false }
    @discardableResult func stop(ifOwner expected: UUID?) -> Bool {
        guard JourneyConfirmation.matches(expected, current: navigationOwner, active: running) else { return false }
        stop(); return true
    }
    func skipNextVia(expected: JourneySkipIntent?) {
        guard JourneyConfirmation.matches(expected, current: skipIntent, active: running) else { return }
        skipStatus = "测试服务边界已禁用，原导航保留"
    }
}
final class WebRouteMetadata: ObservableObject {
    static let shared = WebRouteMetadata()
    @Published var status = "合成样本，不代表真实路线或红绿灯状态"
    @Published var lightDistance: Int?
    @Published var lightCount: Int?
    @Published var trafficLightStatus = ""
}
final class MotorBrowser: ObservableObject { var web = WKWebView(); @Published var status = "测试场景未加载登录网页" }
struct MotorBrowserView: View { let browser: MotorBrowser; var body: some View { SDKBoundaryView(title: "登录网页边界未加载") } }
struct MotorMap: View { let route: MotorRoute; let position: MotorPoint?; let overview: Bool; var bearing: Double = 0; var body: some View { SDKBoundaryView(title: "SDK 地图替身 · 合成路线样本") } }
struct WebMotorView: View {
    var mode: IndependentMode = .motorcycle
    var initialDestination: MotorPoint? = nil
    @ObservedObject var guide = WebMotorSession.shared
    var body: some View { Group { if guide.running || guide.arrived { IndependentNavigationView() } else { IndependentPlannerView(mode: mode, initialDestination: initialDestination) } }.preferredColorScheme(.dark) }
}
struct RouteMapView: View {
    let routes: [NaviBridge.RouteOption]; let selected: Int; let ghost: [CLLocationCoordinate2D]
    let dest: CLLocationCoordinate2D; let vias: [CLLocationCoordinate2D]; let night: Bool
    var body: some View { SDKBoundaryView(title: "高德路线地图边界未加载") }
}
struct SDKBoundaryView: View {
    let title: String
    var body: some View { ZStack { Color(white: 0.12); VStack(spacing: 12) { Image(systemName: "map").font(.largeTitle); Text(title); Text("正式页面控件 · 测试服务适配器\n不展示虚构路网或实测帧率").font(.caption) }.multilineTextAlignment(.center).foregroundColor(.gray).padding() } }
}

@objc enum AMapNaviViewShowMode: Int { case overview, carPositionLocked }
@objc enum AMapNaviViewMapModeType: Int { case night, day }
@objc protocol AMapNaviDriveViewDelegate: NSObjectProtocol {}
class AMapNaviDriveView: UIView {
    weak var delegate: AMapNaviDriveViewDelegate?
    var showMode = AMapNaviViewShowMode.overview
    var mapShowTraffic = true
    var showTrafficLights = true
    var showTrafficLightView = true
    var mapViewModeType = AMapNaviViewMapModeType.day
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = UIColor(white: 0.12, alpha: 1)
        let label = UILabel(); label.text = "高德导航 SDK 边界未加载\n\n下方为正式导航控制组件\n不代表真实导航画面"; label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .gray
        addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
final class AMapNaviDriveManager {
    static let shared = AMapNaviDriveManager()
    static func sharedInstance() -> AMapNaviDriveManager { shared }
    func addDataRepresentative(_ view: AMapNaviDriveView) {}; func removeDataRepresentative(_ view: AMapNaviDriveView) {}
}

final class MapFeeder: ObservableObject {
    static let shared = MapFeeder(), SRC_AMAP = 3
    @Published var shortStatus = "未导航"
    @Published var offlineStatus = "尚未选择路线"
    @Published var buildingInfo = ""
    @Published var infoText = "测试服务适配器"
    @Published var cacheInfo = "成品包 12 MB / 512 MB · GTA 瓦片 8 MB / 256 MB"
    @Published var cacheMessage = ""
    @Published var cacheBusy = false
    @Published var memoryPaused = false
    @Published var configurationPaused = false
    @Published var recoverablePreparation: PreparationRecoveryCheckpoint?
    @Published var preparationSaveState = PreparationRecoveryStore.SaveState.idle
    @Published var preparationRangeKm = 0
    @Published var prefetchWiFiOnly = false
    @Published var prefetchChargingOnly = false
    @Published var offlineProgress = RouteMapPreparation.none
    @Published var routeCoverage = RouteCoverage.scanning(totalMeters: 0)
    @Published var routeCoverageFromPosition = false
    @Published var readiness = MapReadinessSnapshot.idle
    var continueCount = 0, discardCount = 0
    func resetChunk() {}; func resendAll() {}; func refreshCacheInfo() {}
    func setPreparationRangeKm(_ value: Int) { preparationRangeKm = value }
    func setPrefetchWiFiOnly(_ value: Bool) { prefetchWiFiOnly = value }
    func setPrefetchChargingOnly(_ value: Bool) { prefetchChargingOnly = value }
    func continueSavedPreparation() {
        guard let saved = recoverablePreparation else { return }
        continueCount += 1
        if !saved.matches(source: Self.SRC_AMAP, style: Settings.shared.theme, buildingPreference: Settings.shared.buildings) {
            cacheMessage = "地图风格或建筑设置已改变，请恢复原设置后继续"; return
        }
        recoverablePreparation = nil; cacheMessage = "测试任务已交接，未启动导航"
    }
    func discardSavedPreparation() { discardCount += 1; recoverablePreparation = nil; cacheMessage = "已放弃上次任务" }
    func updatePreparedRoute() {}; func retryFailedMapSections() {}; func clearUnusedMaps() {}; func resumeMapPreparation() {}
}
#endif
