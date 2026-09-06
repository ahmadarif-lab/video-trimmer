import AppKit
import AVFoundation

func generateThumbnails(url: URL, duration: Double, count: Int) async -> [NSImage] {
    guard duration > 0, count > 0 else { return [] }
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 240, height: 240)

    return await Task.detached(priority: .userInitiated) { () -> [NSImage] in
        var images: [NSImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                images.append(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            } else {
                images.append(NSImage())
            }
        }
        return images
    }.value
}
