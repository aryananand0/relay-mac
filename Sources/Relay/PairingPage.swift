import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The page shown on the Mac (http://localhost:8765/pair) with two QR codes: one to set the
/// iPhone up for HTTPS (once), one that opens Relay securely and pairs it. Only served to this
/// Mac itself, never to the network.
enum PairingPage {
    static func html(setupURL: String, appURL: String, code: String, fingerprint: String) -> Data {
        let setupQR = qrDataURI(setupURL), appQR = qrDataURI(appURL)
        let spacedCode = escape(Pairing.spaced(code))
        return Data("""
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Pair your iPhone with Relay</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #000;
                 color: #e9e2d6; font: 15px/1.5 ui-rounded, "SF Pro Rounded", system-ui, sans-serif; }
          main { width: min(820px, 100% - 32px); padding: 32px 0; }
          header { text-align: center; margin-bottom: 28px; }
          .logo { display: block; width: 56px; height: 56px; margin: 0 auto 14px; border-radius: 13px; }
          h1 { margin: 0 0 4px; font-size: 28px; font-weight: 600; }
          header p { margin: 0; color: #a39a8c; }
          .steps { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
          .step { padding: 22px; border-radius: 22px; background: #15130f; box-shadow: inset 0 0 0 1px rgba(233,226,214,.08); }
          .step h2 { margin: 0 0 4px; font-size: 18px; }
          .step .n { color: #d9a55b; margin-right: 6px; }
          .step p, .step li { color: #c9c0b2; }
          .step p { margin: 0 0 12px; }
          .qr { width: 190px; height: 190px; margin: 14px auto; padding: 12px; border-radius: 20px; background: #e9e2d6; }
          .qr img { width: 100%; height: 100%; image-rendering: pixelated; display: block; }
          ol { margin: 0; padding-left: 20px; } li { margin: 3px 0; }
          .code { font-size: 22px; font-weight: 600; letter-spacing: .12em; color: #d9a55b; text-align: center; }
          .small { font-size: 12.5px; color: #8c8477; word-break: break-all; }
          .fp { font: 12px ui-monospace, Menlo, monospace; color: #a39a8c; word-break: break-all; margin-top: 6px; }
          @media (max-width: 720px) { .steps { grid-template-columns: 1fr; } }
        </style></head><body><main>
          <header>
            <img class="logo" src="logo.svg" alt="">
            <h1>Pair your iPhone</h1>
            <p>Your iPhone needs to be on the same Wi‑Fi as this Mac.</p>
          </header>
          <div class="steps">
            <section class="step">
              <h2><span class="n">1</span>Trust this Mac (once)</h2>
              <p>Relay uses HTTPS. Your iPhone needs this Mac's certificate first.</p>
              <ol>
                <li><strong>Easiest:</strong> choose <em>Send Certificate to iPhone…</em> from the Relay icon in the menu bar and pick your iPhone in AirDrop.<br>
                    <span class="small">Or scan this code and tap “Get the certificate”:</span></li>
              </ol>
              <div class="qr"><img alt="QR code that opens Relay's setup page on your iPhone" src="\(setupQR)"></div>
              <ol start="2">
                <li>On the iPhone: Settings › Profile Downloaded › Install.</li>
                <li>Settings › General › About › Certificate Trust Settings › turn on <em>Relay Local CA</em>.</li>
              </ol>
              <p class="small" style="margin-top:12px">To make sure it's the right certificate, its SHA‑256 fingerprint (Settings › General › VPN &amp; Device Management › Relay Local CA › More Details) should be:</p>
              <div class="fp">\(escape(fingerprint))</div>
            </section>
            <section class="step">
              <h2><span class="n">2</span>Open Relay</h2>
              <p>Scan this code, then in Safari tap Share › Add to Home Screen. The icon pairs itself.</p>
              <div class="qr"><img alt="QR code that opens Relay securely on your iPhone and pairs it" src="\(appQR)"></div>
              <p style="text-align:center">If Relay asks for a pairing code, enter</p>
              <div class="code">\(spacedCode)</div>
              <p class="small" style="text-align:center; margin-top:10px">\(escape(appURL.components(separatedBy: "#").first ?? appURL))</p>
            </section>
          </div>
        </main></body></html>
        """.utf8)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func qrDataURI(_ text: String) -> String {
        qrPNG(text).map { "data:image/png;base64,\($0.base64EncodedString())" } ?? ""
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
