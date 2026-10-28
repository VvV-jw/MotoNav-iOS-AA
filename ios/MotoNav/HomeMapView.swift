import SwiftUI
import CoreLocation

/// Home coordinates are GCJ-02, matching search results and the route planner.
/// CoreLocation's WGS-84 fixes are converted once here, never in the map delegate.
struct HomeMapView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var location = LocationService.shared
    let destination: SearchService.Place?
    let centerRequest: UUID
    let choosePoint: (SearchService.Place) -> Void

    private var current: CLLocationCoordinate2D? {
        guard let fix = location.location,
              NavigationRecoveryCheckpoint.acceptsFix(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude,
                  accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp) else { return nil }
        let point = MapGeo.wgsToGcj(fix.coordinate.latitude, fix.coordinate.longitude)
        return .init(latitude: point.lat, longitude: point.lng)
    }

    var body: some View {
        Group {
            if settings.keysMissing {
                ZStack {
                    AppPalette.background
                    VStack(spacing: 12) {
                        Image(systemName: "map").font(.system(size: 38, weight: .light))
                        Text("设置地图 Key 后显示地图").font(.headline)
                        Text("可在下方地图 Key 入口配置；已有收藏、行程和导入入口仍可查看。")
                            .font(.caption).multilineTextAlignment(.center)
                    }.foregroundColor(AppPalette.secondary).padding(28)
                }
            } else {
                #if MOTONAV_SCREENSHOTS
                SDKBoundaryView(title: "首页地图 SDK 替身 · 不代表真实路网")
                #else
                HomeMapSurface(current: current, destination: destination, centerRequest: centerRequest,
                    night: settings.paletteNight, choosePoint: choosePoint)
                #endif
            }
        }
    }
}

#if !MOTONAV_SCREENSHOTS
private struct HomeMapSurface: UIViewRepresentable {
    let current: CLLocationCoordinate2D?
    let destination: SearchService.Place?
    let centerRequest: UUID
    let night: Bool
    let choosePoint: (SearchService.Place) -> Void

    func makeCoordinator() -> HomeMapDelegate { HomeMapDelegate(choosePoint: choosePoint) }
    func makeUIView(context: Context) -> MAMapView {
        let map = MAMapView(frame: .zero)
        map.delegate = context.coordinator.asDelegate
        map.showsCompass = false
        map.showsScale = true
        map.isRotateCameraEnabled = false
        map.setZoomLevel(15, animated: false)
        return map
    }
    func updateUIView(_ map: MAMapView, context: Context) {
        let delegate = context.coordinator
        delegate.choosePoint = choosePoint
        let type: MAMapType = night ? .standardNight : .standard
        if map.mapType != type { map.mapType = type }
        let destinationKey = destination.map { "\($0.lat),\($0.lng)" } ?? ""
        let pinsKey = "\(current?.latitude ?? 0),\(current?.longitude ?? 0)|\(destinationKey)"
        if pinsKey != delegate.pinsKey {
            delegate.pinsKey = pinsKey
            if let old = map.annotations { map.removeAnnotations(old) }
            var pins: [MAPointAnnotation] = []
            if let current = current {
                let pin = MAPointAnnotation(); pin.coordinate = current; pin.title = "我的位置"; pins.append(pin)
            }
            if let destination = destination {
                let pin = MAPointAnnotation()
                pin.coordinate = .init(latitude: destination.lat, longitude: destination.lng)
                pin.title = destination.name; pins.append(pin)
            }
            if !pins.isEmpty { map.addAnnotations(pins) }
        }
        // Do not fight a user panning the map on every GPS fix.
        if destinationKey != delegate.destinationKey, let destination = destination {
            map.setCenter(.init(latitude: destination.lat, longitude: destination.lng), animated: true)
        } else if delegate.centerRequest != centerRequest || (!delegate.centeredOnFix && current != nil) {
            if let current = current { map.setCenter(current, animated: delegate.centeredOnFix); delegate.centeredOnFix = true }
        }
        delegate.destinationKey = destinationKey
        delegate.centerRequest = centerRequest
    }
}

private final class HomeMapDelegate: NSObject, MAMapViewDelegate {
    var choosePoint: (SearchService.Place) -> Void
    var pinsKey = "", destinationKey = ""
    var centerRequest: UUID?
    var centeredOnFix = false
    init(choosePoint: @escaping (SearchService.Place) -> Void) { self.choosePoint = choosePoint }
    var asDelegate: MAMapViewDelegate { self }
    func mapView(_ map: MAMapView!, didLongPressedAt coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        choosePoint(.init(name: "地图选点", address: "长按选择的位置", lat: coordinate.latitude, lng: coordinate.longitude))
    }
    func mapView(_ map: MAMapView!, viewFor annotation: MAAnnotation!) -> MAAnnotationView! {
        guard let pin = annotation as? MAPointAnnotation else { return nil }
        let id = "home-place"
        let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MAPinAnnotationView)
            ?? MAPinAnnotationView(annotation: pin, reuseIdentifier: id)
        view?.annotation = pin
        view?.pinColor = pin.title == "我的位置" ? .purple : .red
        view?.canShowCallout = true
        return view
    }
}
#endif
