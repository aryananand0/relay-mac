import Foundation

/// The page a phone sees over plain HTTP (port 8765) before it trusts Relay's certificate:
/// how to install it, and a check that notices when HTTPS works and offers to open Relay.
/// Old Home Screen icons (from before HTTPS) land here too. It contains nothing secret.
enum SetupPage {
    static func html(appPort: UInt16) -> Data {
        Data("""
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Set up Relay</title>
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="theme-color" content="#000000">
        <link rel="apple-touch-icon" href="icon.png">
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; background: #000; color: #e9e2d6; font: 16px/1.5 ui-rounded, "SF Pro Rounded", -apple-system, system-ui, sans-serif;
                 padding: calc(env(safe-area-inset-top) + 28px) 20px calc(env(safe-area-inset-bottom) + 28px); }
          main { max-width: 420px; margin: 0 auto; }
          .logo { display: block; width: 64px; height: 64px; margin: 0 auto 16px; border-radius: 15px; }
          h1 { margin: 0 0 6px; font-size: 26px; font-weight: 600; text-align: center; }
          .lead { margin: 0 0 24px; color: #a39a8c; text-align: center; }
          ol { margin: 0; padding: 0; list-style: none; counter-reset: step; }
          li { position: relative; margin: 0 0 12px; padding: 16px 16px 16px 52px; border-radius: 18px; background: #15130f;
               box-shadow: inset 0 0 0 1px rgba(233,226,214,.08); counter-increment: step; color: #c9c0b2; }
          li::before { content: counter(step); position: absolute; left: 16px; top: 15px; width: 24px; height: 24px; border-radius: 12px;
                       background: #2a261f; color: #d9a55b; font-weight: 600; font-size: 14px; display: grid; place-items: center; }
          li strong { color: #e9e2d6; }
          .button { display: block; margin-top: 12px; padding: 13px; border-radius: 14px; background: #e9e2d6; color: #000;
                    font-weight: 600; text-align: center; text-decoration: none; }
          .status { margin-top: 22px; padding: 16px; border-radius: 18px; text-align: center; color: #a39a8c; background: #15130f; }
          .status.ready { color: #1a1206; background: #d9a55b; }
          .status.ready a { color: #1a1206; font-weight: 600; }
          .note { margin-top: 18px; font-size: 13px; color: #6f675c; text-align: center; }
          details { margin-top: 10px; }
          summary { color: #d9a55b; cursor: pointer; }
          details p { margin: 8px 0 0; font-size: 14px; }
          .warn { color: #f2b7aa; }
          .dot { display: inline-block; width: 7px; height: 7px; margin-right: 8px; border-radius: 4px; background: #4f493f;
                 animation: breathe 1.4s ease-in-out infinite; vertical-align: middle; }
          @keyframes breathe { 50% { opacity: .25; } }
        </style></head><body><main>
          <img class="logo" src="logo.svg" alt="">
          <h1>Set up Relay</h1>
          <p class="lead">Relay connects over HTTPS. Your iPhone needs to trust this Mac once.</p>
          <ol>
            <li><strong>Send the certificate from your Mac.</strong> Click the Relay icon in the Mac's menu bar, choose <em>Send Certificate to iPhone…</em>, and pick this iPhone in AirDrop. AirDrop sends it directly, so nobody on the network can swap it.
              <details><summary>Can't use AirDrop?</summary>
                <p>You can download it here instead, but on a network you don't control, someone could hand you a different certificate. <span class="warn">Before step 3, make sure it's genuine:</span> in Settings › General › VPN &amp; Device Management › Relay Local CA › More Details, the SHA‑256 fingerprint must match the one on your Mac's pairing page (Relay menu › Show Pairing Code…).</p>
                <a class="button" href="Relay.mobileconfig">Download the certificate</a>
              </details></li>
            <li><strong>Install it.</strong> Open Settings, tap <em>Profile Downloaded</em> near the top, then Install.</li>
            <li><strong>Trust it.</strong> Settings › General › About › Certificate Trust Settings › turn on <em>Relay Local CA</em>.</li>
            <li><strong>Open Relay</strong> by scanning the second QR code on your Mac (Relay menu › <em>Show Pairing Code…</em>), then Share › Add to Home Screen.</li>
          </ol>
          <div id="status" class="status"><span class="dot"></span>Waiting for your iPhone to trust this Mac…</div>
          <p class="note">The certificate is only trusted for devices on your own network (.local names and private addresses). Already had Relay on your Home Screen? Add it again from the secure page; you can delete the old icon.</p>
        </main>
        <script>
          // When the HTTPS page answers, the certificate is trusted.
          const app = "https://" + location.hostname + ":\(appPort)/";
          const status = document.getElementById("status");
          async function check() {
            try {
              await fetch(app + "ping", { mode: "no-cors", cache: "no-store" });
              status.className = "status ready";
              status.innerHTML = 'Your iPhone trusts this Mac. <a href="' + app + '">Open Relay</a>';
            } catch { setTimeout(check, 2000); }
          }
          check();
        </script>
        </body></html>
        """.utf8)
    }
}
