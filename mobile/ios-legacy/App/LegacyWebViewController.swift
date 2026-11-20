import MobileCoreServices
import UIKit
import WebKit

final class LegacyWebViewController: UIViewController, WKNavigationDelegate {
    private let playback = MusikePlayback()
    private let youtube = MusikeYouTube()
    private let audio = MusikeAudio()
    private let bridge = LegacyBridge()
    private let statusView = UIView()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var webView: WKWebView!
    private var startupNavigation: WKNavigation?
    private var startupTimeout: DispatchWorkItem?
    private var startupID = 0
    private var interfaceReady = false

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

        webView = WKWebView(frame: .zero, configuration: configuration)
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
        configureStatusView()
        start()
    }

    private var spanish: Bool { Locale.preferredLanguages.first?.hasPrefix("es") == true }

    private func configureStatusView() {
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.backgroundColor = view.backgroundColor
        view.addSubview(statusView)

        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        retryButton.setTitle(spanish ? "Reintentar" : "Retry", for: .normal)
        retryButton.tintColor = UIColor(red: 195 / 255, green: 236 / 255, blue: 82 / 255, alpha: 1)
        retryButton.addTarget(self, action: #selector(start), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, retryButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusView.addSubview(stack)
        NSLayoutConstraint.activate([
            statusView.topAnchor.constraint(equalTo: webView.topAnchor),
            statusView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            statusView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: statusView.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: statusView.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: statusView.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    @objc private func start() {
        startupTimeout?.cancel()
        startupID += 1
        interfaceReady = false
        statusView.isHidden = false
        retryButton.isHidden = true
        statusLabel.text = spanish ? "Abriendo Musike…" : "Opening Musike…"

        startupNavigation = webView.load(URLRequest(url: LegacyAssets.entryURL))
        let attempt = startupID
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.startupID == attempt else { return }
            self.fail("No se recibió la interfaz / The interface did not render.")
        }
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func fail(_ message: String) {
        startupTimeout?.cancel()
        startupTimeout = nil
        startupNavigation = nil
        startupID += 1
        NSLog("Musike startup: %@", message)
        let title = spanish ? "Musike no pudo iniciarse." : "Musike couldn’t start."
        statusLabel.text = title + "\n\n" + String(message.prefix(420))
        retryButton.isHidden = false
        statusView.isHidden = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let startupNavigation, startupNavigation === navigation else { return }
        self.startupNavigation = nil
        guard let scriptURL = LegacyAssets.root?.appendingPathComponent("assets/legacy-app.js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            fail("assets/legacy-app.js")
            return
        }

        // Evaluate the classic script from the local bundle. This avoids subresource script
        // loading on the custom scheme and exposes parse errors directly to the native host.
        let attempt = startupID
        webView.evaluateJavaScript(Self.startupProbe + "\n" + script + "\n;void 0") { [weak self] _, error in
            guard let self, self.startupID == attempt else { return }
            if let error {
                let exception = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self.fail(exception ?? error.localizedDescription)
            } else {
                self.waitForInterface(attempt)
            }
        }
    }

    private static let startupProbe = """
    window.addEventListener("error", function (event) {
        if (event.message) window.__musikeStartupError = event.message;
    });
    window.addEventListener("unhandledrejection", function (event) {
        if (event.reason) window.__musikeStartupError = String(event.reason);
    });
    """

    private func waitForInterface(_ attempt: Int) {
        guard startupID == attempt else { return }
        webView.evaluateJavaScript("document.querySelector('#root main') ? true : (window.__musikeStartupError || false)") { [weak self] result, error in
            guard let self, self.startupID == attempt else { return }
            if result as? Bool == true {
                self.interfaceReady = true
                self.startupTimeout?.cancel()
                self.startupTimeout = nil
                self.statusView.isHidden = true
                PlaybackDiagnostics.shared.record("web.legacy.ready")
            } else if let message = result as? String {
                self.fail(message)
            } else if let error {
                self.fail(error.localizedDescription)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.waitForInterface(attempt)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let startupNavigation, startupNavigation === navigation { fail(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let startupNavigation, startupNavigation === navigation { fail(error.localizedDescription) }
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
        if interfaceReady { start() }
        else { fail(spanish ? "El proceso de WebKit se cerró." : "The WebKit process exited.") }
    }
}

private final class LegacyAssets: NSObject, WKURLSchemeHandler {
    static let entryURL = URL(string: "musike://localhost/index.html")!
    static var root: URL? { Bundle.main.resourceURL?.appendingPathComponent("public", isDirectory: true) }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "localhost", let root = Self.root,
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
        let types = ["html": "text/html", "css": "text/css", "js": "text/javascript", "woff2": "font/woff2"]
        let encoding = ["html", "css", "js", "json", "svg"].contains(file.pathExtension) ? "utf-8" : nil
        task.didReceive(URLResponse(url: url, mimeType: types[file.pathExtension] ?? mime,
                                    expectedContentLength: data.count, textEncodingName: encoding))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
