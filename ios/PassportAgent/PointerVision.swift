import CoreGraphics
import Foundation
import ImageIO

struct PointerVision: Sendable {
    struct Point: Sendable { let x: Double; let y: Double }

    static func locate(before: Data, after: Data, expectedShift: Double,
                       near: Point? = nil) -> Point? {
        guard let a = raster(before), let b = raster(after),
              a.width == b.width, a.height == b.height else { return nil }
        let center = near ?? Point(x: 0.5, y: 0.5)
        let reachX = near == nil ? 0.5 : 0.16
        let reachY = near == nil ? 0.5 : 0.12
        let left = max(0, Int((center.x - reachX) * Double(a.width)))
        let right = min(a.width, Int((center.x + reachX) * Double(a.width)))
        let top = max(Int(Double(a.height) * 0.05), Int((center.y - reachY) * Double(a.height)))
        let bottom = min(a.height, Int((center.y + reachY) * Double(a.height)))
        guard left < right, top < bottom else { return nil }

        var count = 0, sumX = 0, sumY = 0
        var minX = right, maxX = left, minY = bottom, maxY = top
        for y in top..<bottom {
            for x in left..<right where abs(Int(a.pixels[y * a.width + x]) - Int(b.pixels[y * b.width + x])) > 30 {
                count += 1; sumX += x; sumY += y
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let area = (right - left) * (bottom - top)
        guard count >= 12, count <= area / 4,
              maxX - minX < Int(Double(a.width) * 0.16),
              maxY - minY < Int(Double(a.height) * 0.08) else { return nil }
        return Point(x: Double(sumX) / Double(count * a.width) - expectedShift / 2,
                     y: Double(sumY) / Double(count * a.height))
    }

    static func meaningfullyChanged(before: Data, after: Data) -> Bool {
        guard let a = raster(before), let b = raster(after),
              a.width == b.width, a.height == b.height else { return false }
        let top = Int(Double(a.height) * 0.06)
        let count = (a.height - top) * a.width
        guard count > 0 else { return false }
        var changed = 0
        var totalDifference = 0
        for y in top..<a.height {
            for x in 0..<a.width {
                let difference = abs(Int(a.pixels[y * a.width + x]) - Int(b.pixels[y * b.width + x]))
                totalDifference += difference
                if difference > 28 { changed += 1 }
            }
        }
        // Ignore cursor blinking and clock/status-bar updates, but notice dialogs,
        // keyboards, navigation and confirmation screens.
        return changed >= max(120, count / 200) || totalDifference / count >= 4
    }

    private struct Raster { let width: Int; let height: Int; let pixels: [UInt8] }

    private static func raster(_ data: Data) -> Raster? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = min(384, image.width)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? Raster(width: width, height: height, pixels: pixels) : nil
    }
}
