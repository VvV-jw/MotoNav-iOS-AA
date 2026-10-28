import SwiftUI
import CoreLocation
import ObjectiveC

/// 版本：跟随 App 版本（见 Config.swift，iOS v0.3 新增）
///
/// 选路线时的小地图预览（高德地图，夜间样式）：
/// 选中的路线粉色粗线、其他路线灰色、导入的高德分享原路线橙色虚线，自动缩放到能看全所有路线。
/// iOS v0.4：目的地红色大头针、途经点紫色大头针。iOS v0.5.2：地图跟着夜间配色切换白天 / 夜间样式。
/// 放在可以上下滑的主界面里，所以地图本身不能拖动，只用来看。
struct RouteMapView: UIViewRepresentable {
    @ObservedObject private var settings = Settings.shared
    let routes: [NaviBridge.RouteOption]
    let selected: Int
    let ghost: [CLLocationCoordinate2D]
    var dest: CLLocationCoordinate2D? = nil
    var vias: [CLLocationCoordinate2D] = []
    var night = true                                // iOS v0.5.2 跟着夜间配色：夜间用深色地图，白天用浅色地图

    func makeCoordinator() -> RouteMapDelegate { RouteMapDelegate() }

    func makeUIView(context: Context) -> MAMapView {
        let m = MAMapView(frame: .zero)
        m.mapType = night ? .standardNight : .standard
        m.showsUserLocation = true
        m.isZoomEnabled = false
        m.isScrollEnabled = false
        m.isRotateEnabled = false
        m.isRotateCameraEnabled = false
        m.showsCompass = false
        m.showsScale = false
        m.delegate = context.coordinator.asDelegate
        return m
    }

    func updateUIView(_ m: MAMapView, context: Context) {
        let type: MAMapType = night ? .standardNight : .standard
        if m.mapType != type { m.mapType = type }
        // 内容没变就不重画
        let key = routes.map { "\($0.id):\($0.coords.count)" }.joined(separator: ",") + "|\(selected)|\(ghost.count)" +
            "|\(dest.map { "\($0.latitude),\($0.longitude)" } ?? "")|" + vias.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";") + "|\(settings.theme)"
        if context.coordinator.key == key { return }
        context.coordinator.key = key
        if let old = m.overlays { m.removeOverlays(old) }
        let oldPins = (m.annotations ?? []).compactMap { $0 as? MAPointAnnotation }
        if !oldPins.isEmpty { m.removeAnnotations(oldPins) }
        var pins: [MAPointAnnotation] = []
        for (i, v) in vias.enumerated() {
            let a = MAPointAnnotation(); a.coordinate = v; a.title = "途经 \(i + 1)"; pins.append(a)
        }
        if let d = dest { let a = MAPointAnnotation(); a.coordinate = d; a.title = "目的地"; pins.append(a) }
        if !pins.isEmpty { m.addAnnotations(pins) }
        var lines: [MAPolyline] = []
        func add(_ coords: [CLLocationCoordinate2D], _ kind: String) {
            if coords.count < 2 { return }
            var c = coords
            if let l = MAPolyline(coordinates: &c, count: UInt(c.count)) { l.title = kind; lines.append(l) }
        }
        add(ghost, "ghost")
        for r in routes where r.id != selected { add(r.coords, "alt") }
        if let s = routes.first(where: { $0.id == selected }) { add(s.coords, "sel") }    // 选中的最后画（在最上面）
        if lines.isEmpty { return }
        m.addOverlays(lines)
        m.showOverlays(lines, edgePadding: UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28), animated: false)
    }
}

/// Explicit map delegate conformance keeps overlay callbacks visible to the SDK.
final class RouteMapDelegate: NSObject, MAMapViewDelegate {
    var key = ""
    var overview: Bool?
    let vehicle = MAPointAnnotation()
    var vehicleBearing = 0.0
    var routeRenderCount = 0
    var lightKey = ""
    var lightPins: [MAPointAnnotation] = []

    var asDelegate: MAMapViewDelegate { self }

    /// Some engine versions finish map setup after SwiftUI first supplies overlays.
    /// Reattach the same geometry once, without rebuilding the route on every GPS tick.
    func mapInitComplete(_ map: MAMapView!) {
        guard let map = map, let overlays = map.overlays, !overlays.isEmpty else { return }
        map.removeOverlays(overlays)
        map.addOverlays(overlays)
    }

    /// 大头针：目的地红色、途经点紫色；自己的位置用地图默认的蓝点
    func mapView(_ m: MAMapView!, viewFor annotation: MAAnnotation!) -> MAAnnotationView! {
        guard let a = annotation as? MAPointAnnotation else { return nil }
        if a === vehicle {
            let id = "motonav.navigation.vehicle"
            let view = m.dequeueReusableAnnotationView(withIdentifier: id) ?? MAAnnotationView(annotation: a, reuseIdentifier: id)
            view?.annotation = a
            view?.image = Self.vehicleImage
            view?.canShowCallout = false
            view?.transform = CGAffineTransform(rotationAngle: (CGFloat(vehicleBearing) - m.rotationDegree) * .pi / 180)
            return view
        }
        if a.title == "红绿灯位置" {
            let id = "motonav.static.traffic-light"
            let view = m.dequeueReusableAnnotationView(withIdentifier: id) ?? MAAnnotationView(annotation: a, reuseIdentifier: id)
            view?.annotation = a; view?.image = Self.lightImage; view?.canShowCallout = true
            return view
        }
        let id = "pin"
        let v = (m.dequeueReusableAnnotationView(withIdentifier: id) as? MAPinAnnotationView) ?? MAPinAnnotationView(annotation: a, reuseIdentifier: id)
        v?.annotation = a
        v?.pinColor = a.title == "目的地" ? .red : .purple
        v?.canShowCallout = false
        return v
    }

    func mapView(_ m: MAMapView!, rendererFor overlay: MAOverlay!) -> MAOverlayRenderer! {
        guard let pl = overlay as? MAPolyline, let r = MAPolylineRenderer(polyline: pl) else { return nil }
        routeRenderCount += 1
        r.lineJoinType = kMALineJoinRound
        r.lineCapType = kMALineCapRound
        switch pl.title {
        case "nav-casing":
            r.strokeColor = UIColor(white: Settings.shared.paletteNight ? 0.08 : 1.0, alpha: 0.98)
            r.lineWidth = 14
        case "sel", "nav":
            r.strokeColor = Settings.shared.theme == 2
                ? UIColor(red: 214.0 / 255, green: 199.0 / 255, blue: 74.0 / 255, alpha: 1)
                : UIColor(red: 0.22, green: 0.48, blue: 0.70, alpha: 1)
            r.lineWidth = pl.title == "nav" ? 9 : 8
        case "ghost":
            r.strokeColor = UIColor(red: 1, green: 0.62, blue: 0.15, alpha: 0.95)
            r.lineWidth = 4
            r.lineDashType = kMALineDashTypeSquare
        default:
            r.strokeColor = UIColor(white: 0.6, alpha: 0.7)
            r.lineWidth = 6
        }
        return r
    }

    private static var vehicleImage: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44)).image { _ in
            let halo = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 38, height: 38))
            UIColor.white.setFill(); halo.fill()
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: 22, y: 5))
            arrow.addLine(to: CGPoint(x: 36, y: 35))
            arrow.addLine(to: CGPoint(x: 22, y: 29))
            arrow.addLine(to: CGPoint(x: 8, y: 35))
            arrow.close()
            (Settings.shared.theme == 2 ? UIColor(red: 214.0/255, green: 199.0/255, blue: 74.0/255, alpha: 1) : UIColor(red: 0.19, green: 0.40, blue: 0.60, alpha: 1)).setFill(); arrow.fill()
            UIColor(white: 0.1, alpha: 0.8).setStroke(); arrow.lineWidth = 1.2; arrow.stroke()
        }
    }

    /// Three neutral lenses identify a junction; they never imply a live lamp phase.
    private static let lightImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 34)).image { _ in
            UIColor(white: 0.13, alpha: 1).setFill()
            let box = UIBezierPath(roundedRect: CGRect(x: 2, y: 1, width: 18, height: 32), cornerRadius: 7)
            box.fill(); UIColor(white: 0.95, alpha: 1).setStroke(); box.lineWidth = 1.4; box.stroke()
            UIColor(white: 0.67, alpha: 1).setFill()
            for y in [6, 14, 22] { UIBezierPath(ovalIn: CGRect(x: 8, y: y, width: 6, height: 6)).fill() }
        }
    }()
}
