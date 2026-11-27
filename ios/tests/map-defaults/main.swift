import Foundation
var checks = 0
func check(_ p: Bool, _ s: String) { precondition(p, s); checks += 1 }
// Isolated suite: do not modify app/device preferences.
let name = "motonav-map-defaults-\(UUID().uuidString)"
let ud = UserDefaults(suiteName: name)!
defer { ud.removePersistentDomain(forName: name) }
check(MapDefaults.buildings(ud), "new installs default buildings ON")
check(ud.integer(forKey: "map_src") == 3, "new installs default AMap")
ud.removePersistentDomain(forName: name)
ud.set(0, forKey: "map_src"); ud.set(false, forKey: "map_buildings")
check(MapDefaults.buildings(ud), "upgrade enables building extraction")
check(ud.integer(forKey: "map_src") == 3, "upgrade no longer stuck on old automatic provider")
check(ud.integer(forKey: "map_src_before_building_default") == 0, "preserve previous selection")
ud.set(1, forKey: "map_src"); ud.set(false, forKey: "map_buildings")
check(!MapDefaults.buildings(ud), "later explicit building OFF preserved")
check(ud.integer(forKey: "map_src") == 1, "later explicit provider preserved")
check(ud.bool(forKey: MapDefaults.migrationKey), "migration runs once")
ud.set("credential-retained", forKey: "key_amap")
ud.set(2, forKey: "map_theme")
check(MapDefaults.theme(ud) == 12, "Requested floating navigation is enabled once for AA25")
check(ud.integer(forKey: "map_theme_before_aa25") == 2, "Keep the previous appearance for reference")
check(ud.string(forKey: "key_amap") == "credential-retained", "Theme migration must preserve the map credential")
ud.set(5, forKey: "map_theme")
check(MapDefaults.theme(ud) == 5, "Later explicit user choice survives restart")
ud.set(13, forKey: "map_theme")
check(MapDefaults.theme(ud) == 13, "Explicit coast selection survives restart without a second migration")
ud.removePersistentDomain(forName: name)
check(MapDefaults.theme(ud) == 12, "A new install starts with floating navigation")
print("AMap defaults: \(checks) checks passed")
