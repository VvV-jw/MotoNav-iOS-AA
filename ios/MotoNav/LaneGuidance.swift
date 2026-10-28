import Foundation

/// Encode only provider-supplied lanes understood by the existing circular-screen
/// protocol. Turn geometry or a driving route's lanes cannot create motor lanes.
enum LaneGuidance {
    struct Encoded: Equatable {
        let packet: String
        let count: Int
        let diagnostic: String
    }
    static let clear = "#j"

    static func encode(background: String, selected: String, blankUnsupported: Bool = false) -> Encoded {
        func unavailable(_ reason: String) -> Encoded {
            Encoded(packet: clear, count: 0, diagnostic: reason)
        }
        let back = background.trimmingCharacters(in: .whitespacesAndNewlines)
        let front = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !back.isEmpty else { return unavailable("高德当前未提供车道信息") }
        // Omitting empty fields shifts recommendations into a different lane.
        let bg = back.split(separator: "|", omittingEmptySubsequences: false)
        let fr = front.split(separator: "|", omittingEmptySubsequences: false)
        guard (1...8).contains(bg.count), bg.count == fr.count else {
            return unavailable("车道数据不完整或超出圆屏支持范围，已收起")
        }
        func number(_ value: Substring) -> Int? {
            let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(token) else { return nil }
            return number
        }
        func code(_ number: Int, foreground: Bool) -> Int? {
            if foreground && number == 255 { return 15 }
            switch number {
            case 0...12: return number
            // Widening is decoration; retain the SDK's exact turn directions.
            case 13: return 0
            case 14: return 11
            default: return nil
            }
        }
        var encoded = ""
        var blanks = 0
        for index in bg.indices {
            guard let background = number(bg[index]), let foreground = number(fr[index]) else {
                return unavailable("车道数据格式无效，已收起以免指错车道")
            }
            let b = code(background, foreground: false), f = code(foreground, foreground: true)
            guard let b = b, let f = f else {
                if blankUnsupported {
                    // Keep every physical lane in place. The old one-nibble wire format
                    // cannot represent SDK 16...20 combinations, bus or variable lanes.
                    // New LN0 receivers understand an F background as an empty slot.
                    encoded += "ff"; blanks += 1; continue
                }
                return unavailable("高德车道编码暂不支持，已收起以免指错车道")
            }
            encoded += String(b, radix: 16) + String(f, radix: 16)
        }
        return Encoded(packet: "#j," + encoded, count: bg.count,
            diagnostic: "已收到高德车道 \(bg.count) 条" + (blanks > 0 ? "，\(blanks) 条方向无法准确显示，已保留空位" : ""))
    }

    /// A reconnect may reach an older screen. Never replay LN0 empty slots to it:
    /// older firmware guesses straight for an F background.
    static func compatiblePacket(_ packet: String, blankSupported: Bool) -> String {
        guard !blankSupported, packet.hasPrefix("#j,") else { return packet }
        let payload = Array(packet.dropFirst(3))
        for index in stride(from: 0, to: payload.count, by: 2) where payload[index] == "f" || payload[index] == "F" {
            return clear
        }
        return packet
    }

    static func unavailableForIndependent(bicycle: Bool) -> String {
        bicycle ? "自行车路线未提供车道推荐" : "摩托车路线服务未提供可核对的车道推荐"
    }
}
