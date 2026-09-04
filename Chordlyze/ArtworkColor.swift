import CoreImage
import SwiftUI
import UIKit

/// Derives a dark "wash" color from album artwork (average color, clamped so
/// white text stays readable). Cached per track id.
@MainActor
final class ArtworkColor: ObservableObject {
    static let shared = ArtworkColor()

    @Published private(set) var colors: [String: Color] = [:]

    func color(for trackID: String) -> Color? { colors[trackID] }

    func load(trackID: String, url: URL?) async {
        guard colors[trackID] == nil, let url else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              let average = Self.averageColor(of: image) else { return }

        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        // Keep the wash dark enough for white text (target luminance ≤ 0.35).
        let clamped = Color(hue: hue, saturation: min(sat, 0.8),
                            brightness: min(max(bri, 0.25), 0.55))
        colors[trackID] = clamped
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    private static func averageColor(of image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci,
                                                 kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}
