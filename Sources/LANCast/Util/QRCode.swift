import AppKit
import CoreImage

/// Generates QR-code images for the scan-to-connect feature.
enum QRCode {
    /// Renders `string` as a crisp QR code `NSImage` of roughly `size` points.
    static func image(from string: String, size: CGFloat = 240) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // Medium error correction keeps the code readable even with the LANCast
        // logo space / minor scan noise, while staying reasonably dense.
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, size / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
