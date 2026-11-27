import SwiftUI
import UIKit
import CryptoKit

// This disposable UIKit renderer never opens Bluetooth or reads app preferences.
final class BleLink {
    static let shared = BleLink()
    func sendImage(slot: Int, w: Int, h: Int, data: Data) {}
}

private enum TextImageRegression {
    static func run() throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks = 0
        var failures = [String]()
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label) }
        }
        func pixel(_ image: TextImage.Img, _ x: Int, _ y: Int) -> UInt8 {
            let byte = image.data[y * ((image.w + 1) / 2) + x / 2]
            return (x & 1) == 0 ? byte >> 4 : byte & 15
        }
        func png(_ image: TextImage.Img) -> Data? {
            var values = [UInt8]()
            values.reserveCapacity(image.w * image.h)
            for y in 0..<image.h { for x in 0..<image.w { values.append(pixel(image, x, y) * 17) } }
            guard let provider = CGDataProvider(data: Data(values) as CFData),
                  let cg = CGImage(width: image.w, height: image.h, bitsPerComponent: 8, bitsPerPixel: 8,
                    bytesPerRow: image.w, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            return UIImage(cgImage: cg, scale: 1, orientation: .up).pngData()
        }
        let samples = [
            ("canonical", "右转进入前方道路"),
            ("short-cn", "进入前方道路"),
            ("long-cn", "进入前方道路" + String(repeating: "朝阳北路辅路继续行驶", count: 12)),
            ("latin", "Turn right onto Main Street / A405 Southbound"),
            ("descenders", "gyp jq ÁÉÈ 进入 400m"),
            ("multiline", "进入前方道路\n继续直行"),
        ]
        var fixtures = [[String: Any]]()
        check(TextImage.navigationRoadFont.pointSize == 20, "Fixed 20 point road font")
        check(TextImage.navigationRoadFont.lineHeight <= 24, "Font line metrics fit the 24 pixel cell")
        check(TextImage.renderNavigationRoad(" \n ", theme: 12) == nil, "Empty instructions clear the slot")
        check(TextImage.renderNavigationRoad(" \n ", theme: 13) == nil, "Empty coast instructions clear the slot")
        var rendered = [String: TextImage.Img]()
        for (name, text) in samples {
            guard let image = TextImage.renderNavigationRoad(text, theme: 12),
                  let layout = TextImage.navigationRoadLayout(text), let imagePNG = png(image)
            else { failures.append("Render failed: \(name)"); continue }
            rendered[name] = image
            let coast = TextImage.renderNavigationRoad(text, theme: 13)
            check(coast?.w == image.w && coast?.h == image.h && coast?.data == image.data,
                  "Coast shares the exact native instruction pixels: \(name)")
            let stride = (image.w + 1) / 2
            check(image.h == 24 && (1...312).contains(image.w), "Native bounded dimensions: \(name)")
            check(image.data.count == stride * 24 && image.data.count <= 3744, "Packed 4 bit wire budget: \(name)")
            check(layout.truncated == (name == "long-cn" || name == "latin"), "Expected truncation: \(name)")
            check(!layout.truncated || layout.text.hasSuffix("…"), "Long text has an ellipsis: \(name)")
            check(!layout.text.contains("\n"), "Instruction occupies one line: \(name)")
            let coverages = Set((0..<image.h).flatMap { y in (0..<image.w).map { x in pixel(image, x, y) } })
            check(coverages.contains(15) && coverages.contains(where: { (1...14).contains($0) }),
                  "Native grayscale antialiasing survives 4 bit packing: \(name)")
            if image.w & 1 != 0 {
                check((0..<24).allSatisfy { image.data[$0 * stride + stride - 1] & 15 == 0 },
                      "Odd row padding remains zero: \(name)")
            }
            let rawName = "road-\(name).bin", pngName = "road-\(name).png"
            try image.data.write(to: directory.appendingPathComponent(rawName), options: .atomic)
            try imagePNG.write(to: directory.appendingPathComponent(pngName), options: .atomic)
            fixtures.append([
                "name": name, "input": text, "renderedText": layout.text, "truncated": layout.truncated,
                "width": image.w, "height": image.h, "stride": stride, "bitsPerPixel": 4,
                "packing": "high nibble is left pixel; row padding is zero",
                "pointSize": 20, "fontWeight": "medium", "raw": rawName, "png": pngName,
                "bytes": image.data.count,
                "sha256": SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined(),
            ])
        }
        if let short = rendered["short-cn"], let long = rendered["long-cn"] {
            check((0..<24).allSatisfy { y in
                (0..<max(1, short.w - 1)).allSatisfy { x in pixel(short, x, y) == pixel(long, x, y) }
            }, "The same Chinese prefix has identical coverage in short and truncated instructions")
        }
        if let first = rendered["canonical"], let repeated = TextImage.renderNavigationRoad(samples[0].1, theme: 12) {
            check(first.w == repeated.w && first.h == repeated.h && first.data == repeated.data,
                  "Repeated distance callbacks keep identical instruction pixels")
        }
        for theme in [0, 1, 2, 5, 11] {
            for text in [samples[0].1, samples[2].1] {
                let original = TextImage.render(text, maxW: 290, size: 26, minSize: 18)
                let selected = TextImage.renderNavigationRoad(text, theme: theme)
                check(original?.w == selected?.w && original?.h == selected?.h && original?.data == selected?.data,
                      "Legacy rendering remains selected for theme \(theme)")
            }
        }
        let result: [String: Any] = [
            "passed": failures.isEmpty, "checks": checks, "failures": failures,
            "method": "Actual production TextImage and UIFont rendered by UIKit in iOS Simulator",
            "syntheticInputs": true, "phoneOrRoundHardwareUsed": false, "fixtures": fixtures,
            "font": TextImage.navigationRoadFont.fontName,
            "fontLineHeight": TextImage.navigationRoadFont.lineHeight,
            "nativeTargetHeight": 24, "maximumWidth": 312,
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("text-image-tests.json"), options: .atomic)
    }
}

@main private struct TextImageRegressionApp: App {
    var body: some Scene {
        WindowGroup {
            Color.black.ignoresSafeArea().task {
                do { try TextImageRegression.run() }
                catch { print("Text image regression export failed: \(error)") }
            }
        }
    }
}
