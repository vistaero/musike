import MobileCoreServices
import UIKit
import WebKit

final class LegacyWebViewController: UIViewController, WKNavigationDelegate {
    private let playback = MusikePlayback()
    private let youtube = MusikeYouTube()
    private let audio = MusikeAudio()
    private let bridge = LegacyBridge()
    private let nativeEngine = LegacyNativeEngine()
    private var nativeRoot: LegacyRootController?
    private let statusView = UIView()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let loadingSkeleton = LegacyLoadingSkeletonView()
    private var webView: WKWebView!
    private var startupNavigation: WKNavigation?
    private var startupTimeout: DispatchWorkItem?
    private var startupID = 0
    private var interfaceReady = false

    override var preferredStatusBarStyle: UIStatusBarStyle {
        nativeEngine.appearance.theme == "light" ? .default : .lightContent
    }

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
        controller.add(nativeEngine, name: "musikeUI")
        controller.add(PlaybackDiagnostics.shared, name: "musikeDiagnostics")
        controller.addUserScript(WKUserScript(
            source: Self.savedThemeProbe,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.scrollView.backgroundColor = view.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
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
        nativeEngine.webView = webView
        nativeEngine.stateChanged = { [weak self] in
            guard let self else { return }
            self.applyLoadingTheme()
            guard self.nativeEngine.ready, self.nativeEngine.hasSnapshot else { return }
            self.startupTimeout?.cancel()
            self.startupTimeout = nil
            self.statusView.isHidden = true
            self.interfaceReady = true
            self.setNeedsStatusBarAppearanceUpdate()
        }
        let root = LegacyRootController(engine: nativeEngine)
        nativeRoot = root
        addChild(root)
        root.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root.view)
        NSLayoutConstraint.activate([
            root.view.topAnchor.constraint(equalTo: view.topAnchor),
            root.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            root.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        root.didMove(toParent: self)
        configureStatusView()
        start()
    }

    private var spanish: Bool { Locale.preferredLanguages.first?.hasPrefix("es") == true }

    private func configureStatusView() {
        statusView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusView)
        loadingSkeleton.translatesAutoresizingMaskIntoConstraints = false
        statusView.addSubview(loadingSkeleton)
        NSLayoutConstraint.activate([
            loadingSkeleton.topAnchor.constraint(equalTo: statusView.topAnchor),
            loadingSkeleton.bottomAnchor.constraint(equalTo: statusView.bottomAnchor),
            loadingSkeleton.leadingAnchor.constraint(equalTo: statusView.leadingAnchor),
            loadingSkeleton.trailingAnchor.constraint(equalTo: statusView.trailingAnchor),
        ])

        statusLabel.isHidden = true
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        retryButton.setTitle(engineText("Retry", "Reintentar", "Tentar novamente"), for: .normal)
        retryButton.isHidden = true
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
        applyLoadingTheme()
    }

    @objc private func start() {
        startupTimeout?.cancel()
        startupID += 1
        nativeEngine.beginStartup()
        interfaceReady = false
        statusView.isHidden = false
        loadingSkeleton.isHidden = false
        statusLabel.isHidden = true
        retryButton.isHidden = true
        statusLabel.text = nil
        applyLoadingTheme()

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
        loadingSkeleton.isHidden = true
        statusLabel.isHidden = false
        retryButton.isHidden = false
        statusView.isHidden = false
    }

    private func engineText(_ en: String, _ es: String, _ pt: String) -> String {
        let language = Locale.preferredLanguages.first ?? "en"
        return language.hasPrefix("es") ? es : language.hasPrefix("pt") ? pt : en
    }

    private func applyLoadingTheme() {
        let light = nativeEngine.appearance.theme == "light"
        statusView.backgroundColor = light
            ? UIColor(white: 0.96, alpha: 1)
            : UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        statusLabel.textColor = light ? UIColor(white: 0.08, alpha: 1) : .white
        retryButton.tintColor = nativeEngine.accent
        loadingSkeleton.applyTheme(light: light)
        setNeedsStatusBarAppearanceUpdate()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let startupNavigation, startupNavigation === navigation else { return }
        self.startupNavigation = nil
        guard let scriptURL = LegacyAssets.root?.appendingPathComponent("assets/legacy-app.js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            fail("assets/legacy-app.js")
            return
        }

        let attempt = startupID
        webView.evaluateJavaScript("document.documentElement.dataset.theme") { [weak self] theme, _ in
            guard let self, self.startupID == attempt else { return }
            if let theme = theme as? String {
                self.nativeEngine.setThemeFromPage(theme)
            }
            self.runLegacyScript(script, attempt: attempt)
        }
    }

    private func runLegacyScript(_ script: String, attempt: Int) {
        // Evaluate the classic script from the local bundle. This avoids subresource script
        // loading on the custom scheme and exposes parse errors directly to the native host.
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

    private static let savedThemeProbe = """
    try {
        var theme = localStorage.getItem("musike:theme");
        if (theme === "light" || theme === "dark") {
            document.documentElement.dataset.theme = theme;
            window.webkit.messageHandlers.musikeUI.postMessage({ type: "theme", value: theme });
        }
    } catch (error) {}
    """

    private func waitForInterface(_ attempt: Int) {
        guard startupID == attempt else { return }
        webView.evaluateJavaScript("window.musikeNative ? true : (window.__musikeStartupError || false)") { [weak self] result, error in
            guard let self, self.startupID == attempt else { return }
            if result as? Bool == true {
                return
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

private final class LegacyLoadingSkeletonView: UIView {
    private let navigationBar = UIView()
    private let content = UIStackView()
    private let miniPlayer = UIView()
    private let tabBar = UIStackView()
    private var placeholders: [UIView] = []
    private var surfaces: [UIView] = []
    private var separators: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(light: Bool) {
        let background = light ? UIColor(white: 0.96, alpha: 1) :
            UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        let surface = light ? UIColor.white : UIColor(white: 0.12, alpha: 1)
        let placeholder = light ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.2, alpha: 1)
        backgroundColor = background
        navigationBar.backgroundColor = background
        miniPlayer.backgroundColor = surface
        tabBar.backgroundColor = background
        surfaces.forEach { $0.backgroundColor = surface }
        placeholders.forEach { $0.backgroundColor = placeholder }
        separators.forEach { $0.backgroundColor = light ? UIColor(white: 0.84, alpha: 1) : UIColor(white: 0.24, alpha: 1) }
    }

    private func build() {
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(navigationBar)
        let navigationTitle = block(width: 54, height: 22, radius: 7)
        let settings = block(width: 48, height: 16, radius: 6)
        navigationBar.addSubview(navigationTitle)
        navigationBar.addSubview(settings)

        content.axis = .vertical
        content.spacing = 0
        content.alignment = .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let shortcuts = UIStackView()
        shortcuts.axis = .vertical
        shortcuts.translatesAutoresizingMaskIntoConstraints = false
        shortcuts.addArrangedSubview(makeShortcutRow())
        shortcuts.addArrangedSubview(makeShortcutRow())

        content.addArrangedSubview(sectionHeader(width: 148, height: 44))
        content.addArrangedSubview(shortcuts)
        content.addArrangedSubview(sectionHeader(width: 104, height: 64))
        content.addArrangedSubview(sectionHeader(width: 184, height: 64))

        buildMiniPlayer()
        buildTabBar()
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navigationBar.heightAnchor.constraint(equalToConstant: 44),
            navigationTitle.centerXAnchor.constraint(equalTo: navigationBar.centerXAnchor),
            navigationTitle.centerYAnchor.constraint(equalTo: navigationBar.centerYAnchor),
            settings.trailingAnchor.constraint(equalTo: navigationBar.trailingAnchor, constant: -24),
            settings.centerYAnchor.constraint(equalTo: navigationBar.centerYAnchor),
            content.topAnchor.constraint(equalTo: navigationBar.bottomAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: miniPlayer.topAnchor, constant: -12),
            miniPlayer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            miniPlayer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            miniPlayer.heightAnchor.constraint(equalToConstant: 64),
            miniPlayer.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -8),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    private func sectionHeader(width: CGFloat, height: CGFloat) -> UIView {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = block(width: width, height: 12, radius: 6)
        header.addSubview(title)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: height),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func makeShortcutRow() -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let icon = block(width: 26, height: 26, radius: 13)
        let title = block(width: 116, height: 18, radius: 6)
        let chevron = block(width: 8, height: 14, radius: 4)
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 68).isActive = true
        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(chevron)
        row.addSubview(separator)
        surfaces.append(row)
        separators.append(separator)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 58),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 58),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        return row
    }

    private func buildMiniPlayer() {
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        miniPlayer.layer.cornerRadius = 13
        addSubview(miniPlayer)
        surfaces.append(miniPlayer)
        let art = block(width: 48, height: 48, radius: 8)
        let title = block(width: 112, height: 12, radius: 5)
        let subtitle = block(width: 82, height: 10, radius: 5)
        let play = block(width: 20, height: 20, radius: 10)
        [art, title, subtitle, play].forEach(miniPlayer.addSubview)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: miniPlayer.leadingAnchor, constant: 8),
            art.centerYAnchor.constraint(equalTo: miniPlayer.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: art.topAnchor, constant: 11),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            play.trailingAnchor.constraint(equalTo: miniPlayer.trailingAnchor, constant: -24),
            play.centerYAnchor.constraint(equalTo: miniPlayer.centerYAnchor),
        ])
    }

    private func buildTabBar() {
        tabBar.axis = .horizontal
        tabBar.distribution = .fillEqually
        tabBar.alignment = .center
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)
        for _ in 0..<3 {
            let item = UIStackView()
            item.axis = .vertical
            item.alignment = .center
            item.spacing = 5
            item.addArrangedSubview(block(width: 24, height: 24, radius: 12))
            item.addArrangedSubview(block(width: 36, height: 6, radius: 3))
            tabBar.addArrangedSubview(item)
        }
    }

    private func block(width: CGFloat, height: CGFloat, radius: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = radius
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        placeholders.append(view)
        return view
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
