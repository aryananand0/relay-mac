import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The page shown on the Mac (http://localhost:8765/pair) with a QR code the
/// iPhone camera can scan. Only served to this Mac itself, never to the network.
enum PairingPage {
    static func html(url: String, code: String) -> Data {
        let qr = qrPNG(url).map { "data:image/png;base64,\($0.base64EncodedString())" } ?? ""
        let spacedCode = code.enumerated().map { $0.offset == 4 ? " \($0.element)" : "\($0.element)" }.joined()
        return Data("""
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Pair your iPhone with Relay</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #000;
                 color: #e9e2d6; font: 16px/1.5 ui-rounded, "SF Pro Rounded", system-ui, sans-serif; }
          main { width: min(420px, 100% - 32px); text-align: center; }
          h1 { margin: 0 0 6px; font-size: 30px; font-weight: 600; letter-spacing: -0.01em; }
          p { margin: 0; color: #a39a8c; }
          .qr { margin: 28px auto 22px; width: 260px; height: 260px; padding: 16px; border-radius: 28px;
                background: #e9e2d6; }
          .qr img { width: 100%; height: 100%; image-rendering: pixelated; display: block; }
          ol { margin: 0 auto 26px; padding: 0; max-width: 340px; text-align: left; color: #c9c0b2;
               list-style-position: inside; }
          li { margin: 4px 0; }
          .code { font-size: 26px; font-weight: 600; letter-spacing: 0.12em; color: #d9a55b; }
          .url { margin-top: 10px; font-size: 13px; color: #6f675c; word-break: break-all; }
        </style></head><body><main>
          <h1>Pair your iPhone</h1>
          <p>Your iPhone needs to be on the same Wi-Fi as this Mac.</p>
          <div class="qr"><img alt="QR code that opens Relay on your iPhone" src="\(qr)"></div>
          <ol>
            <li>Point your iPhone camera at the code and tap the link.</li>
            <li>In Safari, tap Share, then Add to Home Screen.</li>
            <li>Open Relay from your Home Screen.</li>
          </ol>
          <p>If Relay asks for a pairing code, enter</p>
          <div class="code">\(spacedCode)</div>
          <div class="url">\(url)</div>
        </main></body></html>
        """.utf8)
    }

    private static func qrPNG(_ text: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
