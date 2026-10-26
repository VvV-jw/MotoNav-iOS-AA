import Foundation
import Network
import UIKit

/// Monitoring is optional and is enabled only while an optional prefetch constraint is selected.
/// Values are published on main; unavailable state conservatively waits only for opted-in work.
final class PrefetchConditions {
    private var monitor: NWPathMonitor?
    private var batteryObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "motonav.prefetch.conditions", qos: .utility)
    private var generation = 0
    private(set) var unmeteredWifi = false
    private(set) var charging = false
    var onChange: (() -> Void)?

    func setEnabled(_ enabled: Bool) {
        guard enabled != (monitor != nil) else { return }
        generation += 1
        if !enabled {
            monitor?.cancel(); monitor = nil
            if let observer = batteryObserver { NotificationCenter.default.removeObserver(observer) }
            batteryObserver = nil
            UIDevice.current.isBatteryMonitoringEnabled = false
            unmeteredWifi = false; charging = false
            return
        }
        let current = generation
        UIDevice.current.isBatteryMonitoringEnabled = true
        updatePower()
        batteryObserver = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.updatePower() }
        let path = NWPathMonitor(); monitor = path
        path.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied && path.usesInterfaceType(.wifi) && !path.isExpensive && !path.isConstrained
            DispatchQueue.main.async {
                guard let self = self, self.generation == current, self.monitor != nil else { return }
                if self.unmeteredWifi != usable { self.unmeteredWifi = usable; self.onChange?() }
            }
        }
        path.start(queue: queue)
    }
    private func updatePower() {
        let state = UIDevice.current.batteryState
        let plugged = state == .charging || state == .full
        if charging != plugged { charging = plugged; onChange?() }
    }
    deinit {
        monitor?.cancel()
        if let observer = batteryObserver { NotificationCenter.default.removeObserver(observer) }
    }
}
