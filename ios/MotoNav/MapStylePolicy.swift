import Foundation

/// Content identity is shared with the Android aa build and the round display.
/// Bump a content key whenever encoding/appearance changes so stale styles cannot mix.
enum MapStylePolicy {
    static let original = 0, viceCity = 1, gta5 = 2, minimal = 5, dragonRadar = 11
    static func isValid(_ theme: Int) -> Bool { [original, viceCity, gta5, minimal, dragonRadar].contains(theme) }
    static func normalize(_ theme: Int) -> Int { isValid(theme) ? theme : viceCity }
    static func cacheKey(theme: Int, buildings: Bool) -> String {
        switch normalize(theme) {
        case original: return "amap-original-full-aa1"
        case minimal: return "amap-roads-only-v1"
        case gta5: return "ofm-gta-vector-v4"
        case dragonRadar: return "dragon-radar-v1"
        default: return buildings ? "amap-buildings-v1" : "amap-sdk-v3"
        }
    }
    static func usesBasemap(_ theme: Int) -> Bool { normalize(theme) != dragonRadar }
    static func usesAmapCapture(_ theme: Int) -> Bool { usesBasemap(theme) && normalize(theme) != gta5 }
    static func usesBuildings(_ theme: Int, enabled: Bool) -> Bool { normalize(theme) == viceCity && enabled }
    static func half(_ theme: Int) -> Double { normalize(theme) == gta5 ? 2400 : 1200 }
}
