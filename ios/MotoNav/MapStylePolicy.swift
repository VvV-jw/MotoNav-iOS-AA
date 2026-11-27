import Foundation

/// Content identity is shared with the Android aa build and the round display.
/// Bump a content key whenever encoding/appearance changes so stale styles cannot mix.
enum MapStylePolicy {
    static let original = 0, viceCity = 1, gta5 = 2, neon = 3, paper = 4, minimal = 5
    static let blueprint = 6, pixel = 7, radar = 8, compass = 9, satellite = 10, dragonRadar = 11, floating = 12, coast = 13
    static func isValid(_ theme: Int) -> Bool { (original...coast).contains(theme) }
    static func normalize(_ theme: Int) -> Int { isValid(theme) ? theme : viceCity }
    static func cacheKey(theme: Int, buildings: Bool) -> String {
        switch normalize(theme) {
        case gta5: return "ofm-gta-vector-v5-poi28"
        case floating: return "ofm-floating-roads-v1"
        case coast: return "ofm-coast-areas-v1"
        case satellite: return "amap-satellite-photo-v1"
        default: return "ofm-vector-aa27-style-\(normalize(theme))"
        }
    }
    static func usesBasemap(_ theme: Int) -> Bool { true }
    static func usesVector(_ theme: Int) -> Bool { normalize(theme) != satellite }
    static func usesNativeRoadText(_ theme: Int) -> Bool { theme == floating || theme == coast }
    static func usesAmapCapture(_ theme: Int) -> Bool { normalize(theme) == satellite }
    static func usesBuildings(_ theme: Int, enabled: Bool) -> Bool { false }
    static func half(_ theme: Int) -> Double { usesVector(theme) ? 2400 : 700 }
}
