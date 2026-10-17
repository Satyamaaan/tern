import Foundation

/// The page the browser shows after Google redirects back to Tern.
enum AuthResultPage {
    static let success = page(
        title: "You're signed in",
        message: "You can close this tab and return to Tern.",
        symbol: "M20 6 9 17l-5-5"
    )

    static func failure(_ message: String) -> String {
        page(title: "Sign-in didn't finish", message: message, symbol: "M18 6 6 18M6 6l12 12")
    }

    private static func page(title: String, message: String, symbol: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Tern — \(escape(title))</title>
        <style>
          :root { color-scheme: light dark; --bg: #f6f6f4; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --ring: rgba(0,0,0,.08); }
          @media (prefers-color-scheme: dark) { :root { --bg: #151516; --card: #1f1f21; --text: #f2f2f2; --muted: #9a9aa0; --ring: rgba(255,255,255,.08); } }
          * { box-sizing: border-box; }
          html, body { height: 100%; margin: 0; }
          body { display: grid; place-items: center; background: var(--bg); color: var(--text);
                 font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
          main { width: min(420px, calc(100% - 48px)); padding: 40px 36px; text-align: center; background: var(--card);
                 border-radius: 20px; box-shadow: 0 0 0 1px var(--ring), 0 20px 50px -20px rgba(0,0,0,.25); }
          .mark { width: 52px; height: 52px; margin: 0 auto 20px; display: grid; place-items: center; border-radius: 50%;
                  background: var(--text); color: var(--card); }
          h1 { margin: 0 0 6px; font-size: 20px; font-weight: 600; letter-spacing: -.01em; }
          p { margin: 0; color: var(--muted); }
        </style>
        </head>
        <body>
        <main>
          <div class="mark"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="\(symbol)"/></svg></div>
          <h1>\(escape(title))</h1>
          <p>\(escape(message))</p>
        </main>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
