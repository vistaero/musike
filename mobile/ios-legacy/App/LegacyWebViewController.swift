import MobileCoreServices
import UIKit
import WebKit

final class LegacyWebViewController: UIViewController, WKNavigationDelegate {
    private let playback = MusikePlayback()
    private let youtube = MusikeYouTube()
    private let audio = MusikeAudio()
    private let bridge = LegacyBridge()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        PlaybackDiagnostics.shared.sessionStarted()

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.setURLSchemeHandler(LegacyAssets(), forURLScheme: "musike")
        let controller = configuration.userContentController
        controller.add(playback, name: "musikeMedia")
        controller.add(youtube, name: "musikeResolve")
        controller.add(audio, name: "musikeAudio")
        controller.add(bridge, name: "musikeLegacy")
        controller.add(PlaybackDiagnostics.shared, name: "musikeDiagnostics")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.scrollView.backgroundColor = view.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        playback.attach(webView)
        youtube.attach(webView)
        audio.attach(webView)
        bridge.webView = webView
        bridge.presenter = self
        webView.load(URLRequest(url: URL(string: "musike://localhost/index.html")!))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "musike", url.host == "localhost" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, url.scheme == "https" {
                UIApplication.shared.open(url)
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

private final class LegacyAssets: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "localhost",
              let root = Bundle.main.resourceURL?.appendingPathComponent("public", isDirectory: true),
              !url.path.split(separator: "/").contains("..") else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let file = root.appendingPathComponent(String(url.path.dropFirst()), isDirectory: false)
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, file.pathExtension as CFString, nil)?.takeRetainedValue()
        let mime = uti.flatMap { UTTypeCopyPreferredTagWithClass($0, kUTTagClassMIMEType)?.takeRetainedValue() as String? }
        let types = ["js": "text/javascript", "woff2": "font/woff2"]
        task.didReceive(URLResponse(url: url, mimeType: types[file.pathExtension] ?? mime,
                                    expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
