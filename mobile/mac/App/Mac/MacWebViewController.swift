import Foundation
import UIKit
import WebKit

/// Runs the same bundled, headless engine as iOS, without Capacitor's iOS-only binaries.
final class MusikeWebViewController: UIViewController {
    private let playback = MusikePlayback()
    private let youtube = MusikeYouTube()
    private let audio = MusikeAudio()
    private let transport = MacTransport()
    private let assets = MacAssets()
    let nativeEngine = NativeEngine()
    private var engineView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assets, forURLScheme: "capacitor")
        let controller = config.userContentController
        controller.add(playback, name: "musikeMedia")
        controller.add(youtube, name: "musikeResolve")
        controller.add(audio, name: "musikeAudio")
        controller.add(nativeEngine, name: "musikeUI")
        controller.add(PlaybackDiagnostics.shared, name: "musikeDiagnostics")
        controller.add(transport, name: "musikeHTTP")
        controller.addUserScript(WKUserScript(source: MacTransport.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        engineView = WKWebView(frame: view.bounds, configuration: config)
        engineView.isHidden = true
        view.addSubview(engineView)
        nativeEngine.webView = engineView
        playback.attach(engineView)
        youtube.attach(engineView)
        audio.attach(engineView)
        transport.webView = engineView
        engineView.load(URLRequest(url: URL(string: "capacitor://localhost/index.html")!))

    }
}

private final class MacAssets: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "localhost",
              let root = Bundle.main.resourceURL?.appendingPathComponent("public"),
              let path = url.path.removingPercentEncoding,
              !path.split(separator: "/").contains("..") else { task.didFailWithError(URLError(.badURL)); return }
        let file = root.appendingPathComponent(path == "/" ? "index.html" : String(path.dropFirst()))
        guard let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime: String
        switch file.pathExtension { case "html": mime = "text/html"; case "js": mime = "text/javascript"; case "css": mime = "text/css"; case "json": mime = "application/json"; default: mime = "application/octet-stream" }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

private final class MacTransport: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    static let script = """
    (() => {
      let next = 0; const pending = new Map();
      window.__musikeTransport = request => new Promise((resolve, reject) => {
        const id = ++next; pending.set(id, {resolve, reject});
        window.webkit.messageHandlers.musikeHTTP.postMessage({id, request});
      });
      window.__musikeHTTPResponse = (id, result, error) => {
        const entry = pending.get(id); if (!entry) return; pending.delete(id);
        error ? entry.reject(new Error(error)) : entry.resolve(result);
      };
    })();
    """
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["id"] as? Int,
              let raw = body["request"] as? [String: Any], let link = raw["url"] as? String,
              let url = URL(string: link), url.scheme == "https" else { return }
        var request = URLRequest(url: url)
        request.httpMethod = raw["method"] as? String ?? "GET"
        request.httpBody = (raw["body"] as? String)?.data(using: .utf8)
        for (key, value) in raw["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let response = response as? HTTPURLResponse
            let result: [String: Any] = ["status": response?.statusCode ?? 0,
                "headers": (response?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { out, pair in
                    out[String(describing: pair.key)] = String(describing: pair.value)
                }, "body": String(data: data ?? Data(), encoding: .utf8) ?? ""]
            let values: [Any] = [id, result, error?.localizedDescription as Any? ?? NSNull()]
            guard let json = try? JSONSerialization.data(withJSONObject: values), let encoded = String(data: json, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.webView?.evaluateJavaScript("window.__musikeHTTPResponse(...\(encoded))") }
        }.resume()
    }
}
