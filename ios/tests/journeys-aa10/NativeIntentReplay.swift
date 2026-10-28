import Foundation

// Adapters expose only the production methods' boundaries. In particular there
// is no plan() API here which could silently replace an existing itinerary.
enum SearchService {
    struct Place: Equatable { let name: String; let address: String; let lat: Double; let lng: Double }
}
final class WebMotorSession {
    static let shared = WebMotorSession()
    var running = false
}
final class NativeIntentSearchAdapter {
    var clearCount = 0
    func clear() { clearCount += 1 }
}
final class NativeIntentNaviAdapter {
    var travelMode: JourneyMode = .drive
    var routeReady = true // An existing candidate must remain paired with its UI.
    var recoveryStatus = "手机定位尚未就绪"
    var acceptJourney = false, acceptRecovery = false
    var recoveryMode: JourneyMode = .motorcycle
    var journeyCalls = 0, recoveryCalls = 0
    func planJourney(_ journey: SavedJourney) -> Bool {
        journeyCalls += 1
        if acceptJourney { travelMode = journey.mode }
        return acceptJourney
    }
    func restorePendingRecovery() -> Bool {
        recoveryCalls += 1
        if acceptRecovery { travelMode = recoveryMode }
        return acceptRecovery
    }
}
final class NativeHomeIntentHarness {
    let navi = NativeIntentNaviAdapter()
    let search = NativeIntentSearchAdapter()
    var homeTravelMode = 2, homePanelExpanded = false, page = 0
    var dest: SearchService.Place? = .init(name: "原驾车目的地", address: "", lat: 30, lng: 120)
    var query = "原驾车目的地", addingVia = true, shareStatus = ""
    var keyMissing = false, keyPrompts = 0, cancelImportCount = 0
    func needAmapKey() -> Bool { if keyMissing { keyPrompts += 1 }; return keyMissing }
    func cancelPendingImport() { cancelImportCount += 1 }
}
final class NativeVehicleIntentHarness {
    var travelMode: JourneyMode = .motorcycle
    var destLat = 30.0
    var navigating = false, cruising = false, calculating = false
    var recoveryBusy = false, editingVias = false
    var recoverySDKVehicleOverride: String? = "recovered-vehicle"
    var vias = ["补给站", "观景点"], shareRoute: String? = "original-shared-polyline"
    var replanCount = 0
    var submittedMode: JourneyMode?, submittedVias: [String]?, submittedShare: String?
    var submittedOverride: String?
    func replan() {
        replanCount += 1
        submittedMode = travelMode; submittedVias = vias; submittedShare = shareRoute
        submittedOverride = recoverySDKVehicleOverride
    }
}

func runNativeIntentRegression() -> Int {
    var checks = 0
    func verify(_ ok: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(ok(), message)
    }
    let point = JourneyPoint(name: "新摩托目的地", lat: 30.3, lng: 120.3)
    let journey = SavedJourney(name: "测试摩托行程", mode: .motorcycle, destination: point, vias: [], avoidHighway: true)
    let home = NativeHomeIntentHarness()
    let oldDestination = home.dest, oldQuery = home.query
    home.useSavedJourney(journey)
    verify(home.navi.journeyCalls == 1, "saved selection requests its SDK owner exactly once")
    verify(home.homeTravelMode == 2 && home.navi.travelMode == .drive, "rejected motorcycle selection cannot relabel an old driving candidate")
    verify(home.dest == oldDestination && home.query == oldQuery && home.addingVia, "rejected saved journey keeps the original displayed destination and edit context")
    verify(home.navi.routeReady && home.search.clearCount == 0, "rejection does not silently replace the retained candidate or its search")
    verify(home.shareStatus.contains("尚未切换") && home.shareStatus.contains(home.navi.recoveryStatus), "rejection clearly explains why selection was not installed")
    home.navi.acceptJourney = true
    home.useSavedJourney(journey)
    verify(home.homeTravelMode == 0 && home.navi.travelMode == .motorcycle, "accepted SDK mode and selected UI mode publish together")
    verify(home.dest?.name == point.name && home.query == point.name && !home.addingVia, "accepted saved itinerary publishes its actual destination")
    verify(home.search.clearCount == 1 && home.shareStatus.isEmpty, "successful installation clears obsolete search/error state once")
    let withoutKey = NativeHomeIntentHarness(); withoutKey.keyMissing = true
    withoutKey.useSavedJourney(journey)
    verify(withoutKey.navi.journeyCalls == 0 && withoutKey.homeTravelMode == 2, "missing key cannot mutate the old mode before opening setup")
    verify(withoutKey.dest == oldDestination && withoutKey.keyPrompts == 1 && !withoutKey.shareStatus.isEmpty, "missing-key rejection preserves the selected route and reports the issue")
    var bicycle = journey; bicycle.mode = .bicycle
    let unsupported = NativeHomeIntentHarness(); unsupported.useSavedJourney(bicycle)
    verify(unsupported.navi.journeyCalls == 0 && unsupported.dest == oldDestination && unsupported.homeTravelMode == 2, "unsupported bicycle cannot overwrite the current SDK selection")

    let checkpoint = NavigationRecoveryCheckpoint(mode: .motorcycle,
        destination: .init(name: point.name, lat: point.lat, lng: point.lng), avoidHighway: true,
        engine: .nativeSDK, motorcycleVehicle: .init(plate: "测试A12345", cc: 150))
    let recovery = NativeHomeIntentHarness()
    recovery.restoreRoute(checkpoint)
    verify(recovery.homeTravelMode == 2 && recovery.dest == oldDestination && recovery.query == oldQuery, "failed recovery cannot publish a different UI mode or destination")
    verify(recovery.shareStatus == recovery.navi.recoveryStatus, "failed recovery gives a visible reason")
    recovery.navi.acceptRecovery = true; recovery.restoreRoute(checkpoint)
    verify(recovery.homeTravelMode == 0 && recovery.navi.travelMode == .motorcycle && recovery.dest?.name == point.name, "accepted native recovery publishes the same SDK mode and destination")
    verify(recovery.search.clearCount == 1 && recovery.shareStatus.isEmpty, "successful recovery clears the prior rejection")
    let independent = NavigationRecoveryCheckpoint(mode: .motorcycle,
        destination: checkpoint.destination, avoidHighway: true, engine: .independent)
    let legacy = NativeHomeIntentHarness(); legacy.restoreRoute(independent)
    verify(legacy.navi.recoveryCalls == 0 && legacy.homeTravelMode == 2 && legacy.dest == oldDestination, "old independent checkpoint does not become a different SDK route")

    RoutePlanningGeneration.shared.invalidate(); WebMotorSession.shared.running = false
    defer { RoutePlanningGeneration.shared.invalidate(); WebMotorSession.shared.running = false }
    let vehicle = NativeVehicleIntentHarness()
    verify(vehicle.applyVehicleAndReplan(), "explicit vehicle edit is accepted for an idle motor plan")
    verify(vehicle.replanCount == 1 && vehicle.submittedMode == .motorcycle, "vehicle edit issues exactly one calculation in its original SDK mode")
    verify(vehicle.vias == ["补给站", "观景点"] && vehicle.submittedVias == vehicle.vias, "vehicle edit retains ordered stops")
    verify(vehicle.shareRoute == "original-shared-polyline" && vehicle.submittedShare == vehicle.shareRoute, "vehicle edit retains imported route geometry")
    verify(vehicle.recoverySDKVehicleOverride == nil && vehicle.submittedOverride == nil, "explicit apply releases the recovery override before calculation reads current user facts")
    verify(vehicle.destLat == 30, "vehicle facts do not replace the destination")
    for blocked in 0..<10 {
        let candidate = NativeVehicleIntentHarness()
        switch blocked {
        case 0: candidate.travelMode = .drive
        case 1: candidate.destLat = .nan
        case 2: candidate.navigating = true
        case 3: candidate.cruising = true
        case 4: candidate.calculating = true
        case 5: candidate.recoveryBusy = true
        case 6: candidate.editingVias = true
        case 7: WebMotorSession.shared.running = true
        case 8: _ = RoutePlanningGeneration.shared.begin()
        default: candidate.travelMode = .bicycle
        }
        verify(!candidate.applyVehicleAndReplan() && candidate.replanCount == 0, "ineligible or active session cannot apply vehicle facts: \(blocked)")
        verify(candidate.recoverySDKVehicleOverride == "recovered-vehicle" && candidate.vias.count == 2 && candidate.shareRoute != nil,
            "rejected apply leaves its original snapshot and itinerary intact: \(blocked)")
        RoutePlanningGeneration.shared.invalidate(); WebMotorSession.shared.running = false
    }
    print("native-intent production replay: \(checks) checks passed")
    return checks
}
