// macOS-only read-only analysis of simulator PNGs. Never edits an image.
import Foundation
import CoreGraphics
import ImageIO

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let body = image.cropping(to: CGRect(x: 0, y: CGFloat(image.height)*0.12,
          width: CGFloat(image.width), height: CGFloat(image.height)*0.78)) else { fatalError("Invalid screenshot") }
let size = 64
var rgba = [UInt8](repeating: 0, count: size*size*4)
rgba.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size*4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot inspect screenshot") }
    context.draw(body, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
}
var sum = 0.0, squares = 0.0, dark = 0
for offset in stride(from: 0, to: rgba.count, by: 4) {
    let luminance = (0.2126*Double(rgba[offset])+0.7152*Double(rgba[offset+1])+0.0722*Double(rgba[offset+2]))/255
    sum += luminance; squares += luminance*luminance
    if luminance < 0.3 { dark += 1 }
}
let count = Double(size*size), mean = sum/count
let deviation = sqrt(max(0, squares/count-mean*mean)), darkFraction = Double(dark)/count
let audit: [String: Any] = ["width": image.width, "height": image.height,
    "darkFraction": darkFraction, "bodyLuminanceStdDev": deviation,
    "meaningfulBody": darkFraction > 0.25 && deviation > 0.02,
    "method": "CoreGraphics RGB body sample, excluding status/banner and home-indicator regions"]
let json = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)
