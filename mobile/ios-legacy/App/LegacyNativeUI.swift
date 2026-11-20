import MobileCoreServices
import UIKit
import WebKit

struct LegacyTrack: Codable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double
    let thumb: String
    let art: String
    let kind: String
}

struct LegacyLibrary: Decodable {
    var favorites: [LegacyTrack] = []
    var history: [LegacyTrack] = []
    var playlists: [LegacyPlaylist] = []
}

struct LegacyPlaylist: Decodable {
    let id: String
    let name: String
    let tracks: [LegacyTrack]
}

struct LegacyPlayer: Decodable {
    var queue: [LegacyTrack] = []
    var index: Int = 0
    var status: String = "idle"
    var position: Double = 0
    var duration: Double = 0
    var shuffle: Bool = false
    var repeatMode: String = "off"
    var autoRadio: Bool = false
    var volume: Double = 0.9
    var muted: Bool = false
    var current: LegacyTrack? { queue.indices.contains(index) ? queue[index] : nil }

    enum CodingKeys: String, CodingKey {
        case queue, index, status, position, duration, shuffle
        case repeatMode = "repeat"
        case autoRadio, volume, muted
    }
}

struct LegacyAppearance: Decodable {
    var accent: String = "#c3ec52"
    var theme: String = "dark"
    var homeShortcuts: Bool = true
    var homeRecent: Bool = true
    var homeFavorites: Bool = true
}

struct LegacySnapshot: Decodable {
    var player: LegacyPlayer
    var library: LegacyLibrary
    var appearance: LegacyAppearance
    var lang: String
    var engineSettings: Bool?
}

final class LegacyNativeEngine: NSObject, WKScriptMessageHandler {
    private static let themePreferenceKey = "app.musike.legacy.theme"
    weak var webView: WKWebView?
    private(set) var player = LegacyPlayer()
    private(set) var library = LegacyLibrary()
    private(set) var appearance = LegacyAppearance()
    private(set) var language = "en"
    private(set) var engineSettings = false
    private(set) var ready = false
    private(set) var hasSnapshot = false
    var stateChanged: (() -> Void)? {
        didSet {
            if let stateChanged = stateChanged { stateObservers.append(stateChanged) }
        }
    }
    private var stateObservers: [() -> Void] = []
    private var callbacks: [Int: (Result<Any, Error>) -> Void] = [:]
    private var nextID = 0

    override init() {
        super.init()
        if let theme = UserDefaults.standard.string(forKey: Self.themePreferenceKey),
           theme == "light" || theme == "dark" {
            appearance.theme = theme
        }
    }

    var accent: UIColor { LegacyNativeEngine.color(hex: appearance.accent) }

    func text(_ en: String, _ es: String, _ pt: String) -> String {
        language.hasPrefix("es") ? es : language.hasPrefix("pt") ? pt : en
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        if type == "theme", let theme = body["value"] as? String {
            setThemeFromPage(theme)
        } else if type == "ready" {
            ready = true
            PlaybackDiagnostics.shared.record("native.legacy.ready")
            DispatchQueue.main.async { self.notifyStateChanged() }
        } else if type == "state",
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  let snapshot = try? JSONDecoder().decode(LegacySnapshot.self, from: data) {
            player = snapshot.player
            library = snapshot.library
            appearance = snapshot.appearance
            rememberTheme(snapshot.appearance.theme)
            language = snapshot.lang
            engineSettings = snapshot.engineSettings ?? false
            hasSnapshot = true
            DispatchQueue.main.async { self.notifyStateChanged() }
        } else if type == "response", let id = body["id"] as? Int,
                  let callback = callbacks.removeValue(forKey: id) {
            if let message = body["error"] as? String {
                callback(.failure(NSError(domain: "Musike", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: message])))
            } else {
                callback(.success(body["result"] ?? NSNull()))
            }
        }
    }

    func call(_ action: String, _ args: [String: Any] = [:],
              completion: ((Result<Any, Error>) -> Void)? = nil) {
        guard ready, let webView = webView else {
            completion?(.failure(NSError(domain: "Musike", code: 2,
                                         userInfo: [NSLocalizedDescriptionKey: "Musike is starting up."])))
            return
        }
        nextID += 1
        let id = nextID
        if let completion = completion { callbacks[id] = completion }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "action": action, "args": args]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("void window.musikeNative.dispatch(\(json))") { [weak self] _, error in
            if let error = error {
                self?.callbacks.removeValue(forKey: id)?(.failure(error))
            }
        }
    }

    func request<T: Decodable>(_ action: String, _ args: [String: Any] = [:],
                               completion: @escaping (Result<T, Error>) -> Void) {
        call(action, args) { result in
            completion(result.flatMap { value in
                Result {
                    let data = try JSONSerialization.data(withJSONObject: value)
                    return try JSONDecoder().decode(T.self, from: data)
                }
            })
        }
    }

    func object(_ tracks: [LegacyTrack]) -> Any {
        guard let data = try? JSONEncoder().encode(tracks),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return object
    }

    private func notifyStateChanged() {
        stateObservers.forEach { $0() }
    }

    func setThemeFromPage(_ theme: String) {
        guard theme == "light" || theme == "dark" else { return }
        let changed = appearance.theme != theme
        appearance.theme = theme
        rememberTheme(theme)
        if changed { DispatchQueue.main.async { self.notifyStateChanged() } }
    }

    private func rememberTheme(_ theme: String) {
        guard theme == "light" || theme == "dark" else { return }
        UserDefaults.standard.set(theme, forKey: Self.themePreferenceKey)
    }

    func beginStartup() {
        ready = false
        hasSnapshot = false
    }

    func play(_ tracks: [LegacyTrack], at index: Int = 0) {
        guard !tracks.isEmpty else { return }
        call("playList", ["tracks": object(tracks), "index": index])
    }

    static func color(hex: String) -> UIColor {
        var value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xc3ec52
        if hex.count == 4 {
            let short = hex.dropFirst()
            var expanded = ""
            for character in short { expanded.append(character); expanded.append(character) }
            value = UInt32(expanded, radix: 16) ?? value
        }
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

final class LegacyArtworkCache {
    static let shared = LegacyArtworkCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for string: String, in imageView: UIImageView) {
        imageView.image = nil
        guard let url = URL(string: string) else { return }
        if let cached = cache.object(forKey: url.absoluteString as NSString) {
            imageView.image = cached
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self, weak imageView] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            self?.cache.setObject(image, forKey: url.absoluteString as NSString)
            DispatchQueue.main.async { imageView?.image = image }
        }.resume()
    }
}

final class LegacyRootController: UITabBarController {
    let engine: LegacyNativeEngine
    private let miniPlayer = LegacyMiniPlayer()

    init(engine: LegacyNativeEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        tabBar.isTranslucent = false
        tabBar.barTintColor = LegacyTheme.background(engine)

        let home = LegacyHomeController(engine: engine)
        let search = LegacySearchController(engine: engine)
        let library = LegacyLibraryController(engine: engine)
        configure(home, title: engine.text("Home", "Inicio", "Início"), imageName: "house")
        configure(search, title: engine.text("Search", "Buscar", "Buscar"), imageName: "magnifyingglass")
        configure(library, title: engine.text("Library", "Biblioteca", "Biblioteca"), imageName: "square.stack")
        viewControllers = [LegacyNavigation(home), LegacyNavigation(search), LegacyNavigation(library)]

        miniPlayer.engine = engine
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(miniPlayer)
        NSLayoutConstraint.activate([
            miniPlayer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            miniPlayer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            miniPlayer.heightAnchor.constraint(equalToConstant: 64),
            miniPlayer.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -6),
        ])
        engine.stateChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    private func configure(_ controller: UIViewController, title: String, imageName: String) {
        controller.title = title
        let image = LegacyTabIcon.image(named: imageName)
        controller.tabBarItem = UITabBarItem(title: title, image: image, selectedImage: image)
    }

    private func refresh() {
        tabBar.tintColor = engine.accent
        tabBar.barTintColor = LegacyTheme.background(engine)
        view.backgroundColor = LegacyTheme.background(engine)
        refreshLocalizedTitles()
        miniPlayer.update()
        miniPlayer.isHidden = engine.player.current == nil
        for controller in viewControllers ?? [] {
            if let navigation = controller as? UINavigationController,
               let top = navigation.topViewController {
                LegacyTheme.apply(to: navigation, engine: engine)
                LegacyTheme.apply(to: top, engine: engine)
                (top as? UITableViewController)?.tableView.reloadData()
            }
        }
        if let presented = presentedViewController {
            LegacyTheme.apply(to: presented, engine: engine)
            (presented as? UINavigationController)?.topViewController.map {
                LegacyTheme.apply(to: $0, engine: engine)
                ($0 as? UITableViewController)?.tableView.reloadData()
            }
        }
    }

    private func refreshLocalizedTitles() {
        let titles = [engine.text("Home", "Inicio", "Início"),
                      engine.text("Search", "Buscar", "Buscar"),
                      engine.text("Library", "Biblioteca", "Biblioteca")]
        for (index, controller) in (viewControllers ?? []).enumerated() {
            guard index < titles.count,
                  let navigation = controller as? UINavigationController,
                  let root = navigation.viewControllers.first else { continue }
            navigation.tabBarItem.title = titles[index]
            root.tabBarItem.title = titles[index]
            if navigation.viewControllers.count == 1 { root.title = titles[index] }
            if let home = root as? LegacyHomeController { home.updateLocalization() }
            if let search = root as? LegacySearchController { search.updateLocalization() }
        }
    }
}

private func LegacyNavigation(_ root: UIViewController) -> UINavigationController {
    let navigation = UINavigationController(rootViewController: root)
    navigation.navigationBar.isTranslucent = false
    navigation.navigationBar.barTintColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
    navigation.navigationBar.tintColor = UIColor(red: 195 / 255, green: 236 / 255, blue: 82 / 255, alpha: 1)
    navigation.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
    return navigation
}

private enum LegacyTabIcon {
    static func image(named name: String) -> UIImage {
        let size = CGSize(width: 26, height: 26)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }

        let path = UIBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch name {
        case "house":
            path.move(to: CGPoint(x: 3, y: 12))
            path.addLine(to: CGPoint(x: 13, y: 3))
            path.addLine(to: CGPoint(x: 23, y: 12))
            path.move(to: CGPoint(x: 6, y: 10))
            path.addLine(to: CGPoint(x: 6, y: 23))
            path.addLine(to: CGPoint(x: 20, y: 23))
            path.addLine(to: CGPoint(x: 20, y: 10))
            path.move(to: CGPoint(x: 11, y: 23))
            path.addLine(to: CGPoint(x: 11, y: 16))
            path.addLine(to: CGPoint(x: 15, y: 16))
            path.addLine(to: CGPoint(x: 15, y: 23))
        case "magnifyingglass":
            path.append(UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 15, height: 15)))
            path.move(to: CGPoint(x: 15, y: 15))
            path.addLine(to: CGPoint(x: 23, y: 23))
        case "clock":
            path.append(UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 20, height: 20)))
            path.move(to: CGPoint(x: 13, y: 7))
            path.addLine(to: CGPoint(x: 13, y: 13))
            path.addLine(to: CGPoint(x: 17, y: 16))
        default:
            path.move(to: CGPoint(x: 5, y: 7))
            path.addLine(to: CGPoint(x: 19, y: 7))
            path.addLine(to: CGPoint(x: 19, y: 20))
            path.addLine(to: CGPoint(x: 5, y: 20))
            path.close()
            path.move(to: CGPoint(x: 8, y: 4))
            path.addLine(to: CGPoint(x: 22, y: 4))
            path.addLine(to: CGPoint(x: 22, y: 17))
            path.move(to: CGPoint(x: 2, y: 10))
            path.addLine(to: CGPoint(x: 2, y: 23))
            path.addLine(to: CGPoint(x: 16, y: 23))
        }
        if name == "heart" {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26),
                .foregroundColor: UIColor.black,
            ]
            let glyph = "♥" as NSString
            let glyphSize = glyph.size(withAttributes: attributes)
            glyph.draw(at: CGPoint(x: (size.width - glyphSize.width) / 2,
                                   y: (size.height - glyphSize.height) / 2 - 1),
                      withAttributes: attributes)
        } else {
            UIColor.black.setStroke()
            path.stroke()
        }
        return UIGraphicsGetImageFromCurrentImageContext()?.withRenderingMode(.alwaysTemplate) ?? UIImage()
    }
}

private enum LegacyTheme {
    static func background(_ engine: LegacyNativeEngine) -> UIColor {
        engine.appearance.theme == "light" ? UIColor(white: 0.96, alpha: 1) :
            UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
    }

    static func foreground(_ engine: LegacyNativeEngine) -> UIColor {
        engine.appearance.theme == "light" ? UIColor(white: 0.08, alpha: 1) : .white
    }

    static func secondary(_ engine: LegacyNativeEngine) -> UIColor {
        engine.appearance.theme == "light" ? UIColor(white: 0.38, alpha: 1) : .lightGray
    }

    static func surface(_ engine: LegacyNativeEngine) -> UIColor {
        engine.appearance.theme == "light" ? UIColor.white : UIColor(white: 0.12, alpha: 1)
    }

    static func apply(to controller: UIViewController, engine: LegacyNativeEngine) {
        let dark = engine.appearance.theme != "light"
        controller.view.backgroundColor = background(engine)
        if let navigation = controller as? UINavigationController {
            navigation.view.backgroundColor = background(engine)
            navigation.navigationBar.barTintColor = background(engine)
            navigation.navigationBar.backgroundColor = background(engine)
            navigation.navigationBar.tintColor = engine.accent
            navigation.navigationBar.titleTextAttributes = [.foregroundColor: foreground(engine)]
            navigation.navigationBar.barStyle = dark ? .black : .default
            let barImage = solidImage(background(engine))
            navigation.navigationBar.setBackgroundImage(barImage, for: .default)
            navigation.navigationBar.shadowImage = solidImage(background(engine))
        }
        if let table = controller as? UITableViewController {
            table.tableView.backgroundColor = background(engine)
        }
        apply(to: controller.view, engine: engine)
    }

    static func apply(to view: UIView, engine: LegacyNativeEngine) {
        let dark = engine.appearance.theme != "light"
        if let label = view as? UILabel {
            if label.textColor.isEqual(UIColor.white) || label.textColor.isEqual(UIColor(white: 0.08, alpha: 1)) {
                label.textColor = foreground(engine)
            } else if label.textColor.isEqual(UIColor.lightGray) ||
                        label.textColor.isEqual(UIColor(white: 0.38, alpha: 1)) {
                label.textColor = secondary(engine)
            }
        }
        if let field = view as? UITextField {
            field.textColor = foreground(engine)
            field.backgroundColor = surface(engine)
            field.attributedPlaceholder = NSAttributedString(
                string: field.placeholder ?? "",
                attributes: [.foregroundColor: secondary(engine)])
        }
        if let searchBar = view as? UISearchBar {
            searchBar.barStyle = dark ? .black : .default
            searchBar.searchBarStyle = .prominent
            searchBar.barTintColor = background(engine)
            searchBar.backgroundColor = background(engine)
            searchBar.tintColor = engine.accent
        }
        if let segmented = view as? UISegmentedControl { segmented.tintColor = engine.accent }
        if let slider = view as? UISlider { slider.tintColor = engine.accent }
        for child in view.subviews { apply(to: child, engine: engine) }
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 1, height: 1), false, 0)
        color.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image.resizableImage(withCapInsets: .zero)
    }
}

private final class LegacyMiniPlayer: UIView {
    weak var engine: LegacyNativeEngine?
    private let artwork = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.16, alpha: 0.98)
        layer.cornerRadius = 14
        clipsToBounds = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(openPlayer))
        addGestureRecognizer(tap)

        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 8
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.textColor = .white
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = .lightGray
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
        playButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        [artwork, titleLabel, artistLabel, playButton].forEach(addSubview)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            artwork.widthAnchor.constraint(equalToConstant: 48),
            artwork.heightAnchor.constraint(equalToConstant: 48),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: artwork.topAnchor, constant: 5),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            playButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update() {
        guard let engine = engine, let track = engine.player.current else { return }
        backgroundColor = LegacyTheme.surface(engine)
        titleLabel.text = track.title
        artistLabel.text = track.artist
        titleLabel.textColor = LegacyTheme.foreground(engine)
        artistLabel.textColor = LegacyTheme.secondary(engine)
        playButton.setTitle(engine.player.status == "playing" ? "II" : ">", for: .normal)
        playButton.tintColor = engine.accent
        LegacyArtworkCache.shared.image(for: track.thumb, in: artwork)
    }

    @objc private func toggle() { engine?.call("toggle") }
    @objc private func openPlayer() {
        guard let engine = engine, let presenter = viewController else { return }
        presenter.present(LegacyNavigation(LegacyPlayerController(engine: engine)), animated: true)
    }
}

private extension UIView {
    var viewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}

private final class LegacyTrackCell: UITableViewCell {
    static let reuseID = "LegacyTrackCell"
    let artwork = UIImageView()
    let titleLabel = UILabel()
    let artistLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 7
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 15)
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.textColor = .lightGray
        artistLabel.font = .systemFont(ofSize: 13)
        let stack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(artwork)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            artwork.widthAnchor.constraint(equalToConstant: 52),
            artwork.heightAnchor.constraint(equalToConstant: 52),
            artwork.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        accessoryType = .disclosureIndicator
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(track: LegacyTrack, dark: Bool) {
        titleLabel.text = track.title
        artistLabel.text = track.artist
        titleLabel.textColor = dark ? .white : UIColor(white: 0.08, alpha: 1)
        artistLabel.textColor = dark ? .lightGray : UIColor(white: 0.38, alpha: 1)
        LegacyArtworkCache.shared.image(for: track.thumb, in: artwork)
    }
}

final class LegacyHomeController: UITableViewController {
    private let engine: LegacyNativeEngine

    init(engine: LegacyNativeEngine) {
        self.engine = engine
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: engine.text("Settings", "Ajustes", "Ajustes"),
                                                            style: .plain, target: self,
                                                            action: #selector(openSettings))
        tableView.backgroundColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        tableView.separatorStyle = .none
        tableView.register(LegacyTrackCell.self, forCellReuseIdentifier: LegacyTrackCell.reuseID)
    }

    func updateLocalization() {
        title = engine.text("Home", "Inicio", "Início")
        navigationItem.rightBarButtonItem?.title = engine.text("Settings", "Ajustes", "Ajustes")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return engine.appearance.homeShortcuts ? 2 + min(engine.library.playlists.count, 6) : 0
        case 1: return engine.appearance.homeFavorites ? min(engine.library.favorites.count, 5) : 0
        default: return engine.appearance.homeRecent ? min(engine.library.history.count, 10) : 0
        }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return engine.appearance.homeShortcuts ? engine.text("Shortcuts", "Accesos directos", "Atalhos") : nil
        case 1: return engine.appearance.homeFavorites ? engine.text("Your favorites", "Tus favoritos", "Suas favoritas") : nil
        default: return engine.appearance.homeRecent ? engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente") : nil
        }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            let names = [engine.text("Favorites", "Favoritos", "Favoritas"),
                         engine.text("Recent", "Recientes", "Recentes")]
            if indexPath.row < 2 {
                cell.textLabel?.text = names[indexPath.row]
                cell.imageView?.image = LegacyTabIcon.image(named: indexPath.row == 0 ? "heart" : "clock")
            } else {
                cell.textLabel?.text = engine.library.playlists[indexPath.row - 2].name
                cell.detailTextLabel?.text = engine.text("Playlist", "Lista de reproducción", "Playlist")
                cell.imageView?.image = LegacyTabIcon.image(named: "library")
            }
            cell.backgroundColor = LegacyTheme.surface(engine)
            cell.textLabel?.textColor = LegacyTheme.foreground(engine)
            cell.detailTextLabel?.textColor = LegacyTheme.secondary(engine)
            cell.imageView?.tintColor = engine.accent
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: LegacyTrackCell.reuseID, for: indexPath) as! LegacyTrackCell
        let track = indexPath.section == 1 ? engine.library.favorites[indexPath.row] : engine.library.history[indexPath.row]
        cell.configure(track: track, dark: engine.appearance.theme != "light")
        return cell
    }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 68 }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                navigationController?.pushViewController(LegacyPlaylistController(engine: engine,
                    title: engine.text("Favorites", "Favoritos", "Favoritas"), tracks: engine.library.favorites), animated: true)
            } else if indexPath.row == 1 {
                navigationController?.pushViewController(LegacyPlaylistController(engine: engine,
                    title: engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente"), tracks: engine.library.history), animated: true)
            } else {
                let playlist = engine.library.playlists[indexPath.row - 2]
                navigationController?.pushViewController(LegacyPlaylistController(engine: engine, playlist: playlist), animated: true)
            }
        } else {
            let tracks = indexPath.section == 1 ? engine.library.favorites : engine.library.history
            engine.play(tracks, at: indexPath.row)
        }
    }

    @objc private func openSettings() {
        present(LegacyNavigation(LegacySettingsController(engine: engine)), animated: true)
    }
}

private extension LegacyRootController {
    func refreshIfNeeded() { refresh() }
}

final class LegacySearchController: UITableViewController, UISearchResultsUpdating, UISearchControllerDelegate {
    private let engine: LegacyNativeEngine
    private var tracks: [LegacyTrack] = []
    private var timer: Timer?
    private var requestID = 0
    private let search = UISearchController(searchResultsController: nil)

    init(engine: LegacyNativeEngine) {
        self.engine = engine
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        tableView.separatorStyle = .none
        tableView.register(LegacyTrackCell.self, forCellReuseIdentifier: LegacyTrackCell.reuseID)
        search.searchResultsUpdater = self
        search.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.tintColor = engine.accent
        search.searchBar.placeholder = engine.text("Artists, songs or albums",
                                                  "Artistas, canciones o álbumes",
                                                  "Artistas, músicas ou álbuns")
        if #available(iOS 11.0, *) {
            navigationItem.searchController = search
            navigationItem.hidesSearchBarWhenScrolling = false
        } else {
            tableView.tableHeaderView = search.searchBar
        }
        definesPresentationContext = true
        LegacyTheme.apply(to: search.searchBar, engine: engine)
        LegacyTheme.apply(to: self, engine: engine)
    }

    func updateLocalization() {
        title = engine.text("Search", "Buscar", "Buscar")
        search.searchBar.placeholder = engine.text("Artists, songs or albums",
                                                   "Artistas, canciones o álbumes",
                                                   "Artistas, músicas ou álbuns")
        updateCancelButtonTitle()
        LegacyTheme.apply(to: search.searchBar, engine: engine)
    }

    func didPresentSearchController(_ searchController: UISearchController) {
        DispatchQueue.main.async { [weak self] in self?.updateCancelButtonTitle() }
    }

    private func updateCancelButtonTitle() {
        let title = engine.text("Cancel", "Cancelar", "Cancelar")
        func updateButtons(in view: UIView) {
            if let button = view as? UIButton,
               let currentTitle = button.title(for: .normal),
               !currentTitle.isEmpty {
                button.setTitle(title, for: .normal)
            }
            view.subviews.forEach(updateButtons)
        }
        updateButtons(in: search.searchBar)
    }

    func updateSearchResults(for searchController: UISearchController) {
        timer?.invalidate()
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            tracks = []
            tableView.reloadData()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            self?.search(text)
        }
    }

    private func search(_ text: String) {
        requestID += 1
        let id = requestID
        engine.request("search", ["query": text, "kind": "song"]) { [weak self] (result: Result<[LegacyTrack], Error>) in
            guard let self = self, id == self.requestID else { return }
            if case .success(let tracks) = result {
                self.tracks = tracks
                self.tableView.reloadData()
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tracks.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LegacyTrackCell.reuseID, for: indexPath) as! LegacyTrackCell
        cell.configure(track: tracks[indexPath.row], dark: engine.appearance.theme != "light")
        return cell
    }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 68 }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        engine.play(tracks, at: indexPath.row)
    }
}

final class LegacyLibraryController: UITableViewController {
    private let engine: LegacyNativeEngine

    init(engine: LegacyNativeEngine) {
        self.engine = engine
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        tableView.separatorStyle = .none
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "LibraryCell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self,
                                                            action: #selector(createPlaylist))
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? engine.library.playlists.count : (engine.library.favorites.isEmpty ? 0 : 1)
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? engine.text("Playlists", "Listas", "Playlists")
                      : engine.text("Favorites", "Favoritos", "Favoritas")
    }
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView()
        header.backgroundColor = LegacyTheme.background(engine)
        let icon = UIImageView(image: LegacyTabIcon.image(named: section == 0 ? "library" : "heart"))
        icon.contentMode = .scaleAspectFit
        icon.tintColor = engine.accent
        icon.frame = CGRect(x: 13, y: 8, width: 30, height: 30)
        let label = UILabel(frame: CGRect(x: 52, y: 0, width: tableView.bounds.width - 68, height: 46))
        label.text = self.tableView(tableView, titleForHeaderInSection: section)?.uppercased()
        label.textColor = LegacyTheme.secondary(engine)
        label.font = .systemFont(ofSize: 13)
        header.addSubview(icon)
        header.addSubview(label)
        return header
    }
    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 46 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LibraryCell", for: indexPath)
        cell.backgroundColor = .clear
        cell.textLabel?.textColor = LegacyTheme.foreground(engine)
        cell.backgroundColor = LegacyTheme.surface(engine)
        if indexPath.section == 0 {
            cell.textLabel?.text = engine.library.playlists[indexPath.row].name
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.textLabel?.text = "\(engine.library.favorites.count) \(engine.text("tracks", "canciones", "músicas"))"
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let playlist = engine.library.playlists[indexPath.row]
            navigationController?.pushViewController(LegacyPlaylistController(engine: engine, playlist: playlist), animated: true)
        } else {
            navigationController?.pushViewController(LegacyPlaylistController(engine: engine, title: engine.text("Favorites", "Favoritos", "Favoritas"),
                                                                               tracks: engine.library.favorites), animated: true)
        }
    }

    @objc private func createPlaylist() {
        let alert = UIAlertController(title: engine.text("New playlist", "Nueva lista", "Nova playlist"),
                                      message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = self.engine.text("Playlist name", "Nombre de la lista", "Nome da playlist")
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: engine.text("Cancel", "Cancelar", "Cancelar"), style: .cancel))
        alert.addAction(UIAlertAction(title: engine.text("Create", "Crear", "Criar"), style: .default) { [weak self, weak alert] _ in
            guard let self = self,
                  let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            self.engine.call("createPlaylist", ["name": name]) { [weak self] result in
                if case .failure(let error) = result {
                    DispatchQueue.main.async { self?.showError(error) }
                }
            }
        })
        present(alert, animated: true)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: engine.text("Error", "Error", "Erro"),
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class LegacyPlaylistController: UITableViewController {
    private let engine: LegacyNativeEngine
    private let tracks: [LegacyTrack]

    convenience init(engine: LegacyNativeEngine, playlist: LegacyPlaylist) {
        self.init(engine: engine, title: playlist.name, tracks: playlist.tracks)
    }

    init(engine: LegacyNativeEngine, title: String, tracks: [LegacyTrack]) {
        self.engine = engine
        self.tracks = tracks
        super.init(style: .plain)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        tableView.separatorStyle = .none
        tableView.register(LegacyTrackCell.self, forCellReuseIdentifier: LegacyTrackCell.reuseID)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tracks.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LegacyTrackCell.reuseID, for: indexPath) as! LegacyTrackCell
        cell.configure(track: tracks[indexPath.row], dark: engine.appearance.theme != "light")
        return cell
    }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 68 }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        engine.play(tracks, at: indexPath.row)
    }
}

private struct LegacySystemInfo: Decodable {
    struct Ytdlp: Decodable {
        let path: String?
        let version: String?
        let channel: String
        let updateAvailable: Bool
    }
    struct Job: Decodable {
        let status: String
        let message: String
        let log: [String]
    }
    let ytdlp: Ytdlp
    let deno: String?
    let ffmpeg: String?
    let canInstall: Bool
    let job: Job?
}

private struct LegacyBackupPreview: Decodable {
    let playlists: Int
    let playlistTracks: Int
    let favorites: Int
    let history: Int
    let hasSettings: Bool
}

final class LegacySettingsController: UITableViewController, UIDocumentPickerDelegate {
    private enum Section: Int, CaseIterable {
        case appearance, home, language, playbackEngine, diagnostics, data
    }
    private let engine: LegacyNativeEngine
    private let colors = ["#c3ec52", "#34d399", "#22d3ee", "#60a5fa",
                          "#a78bfa", "#f472b6", "#fb7c5c", "#fbbf24"]
    private var system: LegacySystemInfo?
    private var channel = "stable"
    private var busy = false
    private var settingsVisible = false

    private var sections: [Section] {
        var result: [Section] = [.appearance, .home, .language]
        if engine.engineSettings { result.append(.playbackEngine) }
        result.append(contentsOf: [.diagnostics, .data])
        return result
    }

    init(engine: LegacyNativeEngine) {
        self.engine = engine
        super.init(style: .grouped)
        title = engine.text("Settings", "Ajustes", "Ajustes")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.separatorStyle = .singleLine
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: engine.text("Done", "Listo", "Concluído"),
                                                            style: .done, target: self, action: #selector(done))
        engine.stateChanged = { [weak self] in
            guard let self = self else { return }
            self.updateLocalization()
            self.applyTheme()
            self.tableView.reloadData()
        }
        applyTheme()
        settingsVisible = true
        if engine.engineSettings { loadSystem() }
    }

    func updateLocalization() {
        title = engine.text("Settings", "Ajustes", "Ajustes")
        navigationItem.rightBarButtonItem?.title = engine.text("Done", "Listo", "Concluído")
    }

    private func applyTheme() {
        LegacyTheme.apply(to: self, engine: engine)
        if let navigation = navigationController {
            LegacyTheme.apply(to: navigation, engine: engine)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settingsVisible = true
        applyTheme()
        if engine.engineSettings && system == nil { loadSystem() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        settingsVisible = false
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .appearance: return engine.text("Appearance", "Apariencia", "Aparência")
        case .home: return engine.text("Home", "Inicio", "Início")
        case .language: return engine.text("Language", "Idioma", "Idioma")
        case .playbackEngine: return engine.text("Playback engine", "Motor de reproducción", "Motor de reprodução")
        case .diagnostics: return engine.text("Playback diagnostics", "Diagnóstico de reproducción", "Diagnóstico de reprodução")
        case .data: return engine.text("Your data", "Tus datos", "Seus dados")
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .appearance: return 3
        case .home: return 4
        case .language, .diagnostics, .data: return 1 + (sections[section] == .diagnostics || sections[section] == .data ? 1 : 0)
        case .playbackEngine: return system == nil ? 1 : 3
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch sections[indexPath.section] {
        case .appearance where indexPath.row == 1: return 58
        case .appearance, .language: return 64
        case .playbackEngine where indexPath.row == 1: return 64
        case .diagnostics where indexPath.row == 1: return 64
        default: return 54
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = sections[indexPath.section]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = LegacyTheme.surface(engine)
        cell.contentView.backgroundColor = LegacyTheme.surface(engine)
        cell.textLabel?.textColor = LegacyTheme.foreground(engine)
        cell.detailTextLabel?.textColor = LegacyTheme.secondary(engine)
        cell.selectionStyle = .none

        switch section {
        case .appearance:
            if indexPath.row == 0 {
                addSegment([engine.text("Dark", "Oscuro", "Escuro"), engine.text("Light", "Claro", "Claro")],
                           selected: engine.appearance.theme == "light" ? 1 : 0, identifier: "theme", to: cell)
            } else if indexPath.row == 1 {
                addAccentColors(to: cell)
            } else {
                cell.textLabel?.text = engine.text("Custom accent color", "Color de acento personalizada", "Cor de destaque personalizada")
                cell.detailTextLabel?.text = engine.appearance.accent
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }
        case .home:
            if indexPath.row < 3 {
                let keys = ["homeShortcuts", "homeRecent", "homeFavorites"]
                let titles = [engine.text("Shortcuts", "Accesos directos", "Atalhos"),
                              engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente"),
                              engine.text("Your favorites", "Tus favoritos", "Suas favoritas")]
                let values = [engine.appearance.homeShortcuts, engine.appearance.homeRecent, engine.appearance.homeFavorites]
                cell.textLabel?.text = titles[indexPath.row]
                let toggle = UISwitch()
                toggle.isOn = values[indexPath.row]
                toggle.onTintColor = engine.accent
                toggle.accessibilityIdentifier = keys[indexPath.row]
                toggle.addTarget(self, action: #selector(settingToggled(_:)), for: .valueChanged)
                cell.accessoryView = toggle
            } else {
                cell.textLabel?.text = engine.text("Reset appearance", "Restablecer apariencia", "Redefinir aparência")
                cell.textLabel?.textColor = engine.accent
                cell.selectionStyle = .default
            }
        case .language:
            addSegment(["English", "Español", "Português"],
                       selected: engine.language.hasPrefix("es") ? 1 : engine.language.hasPrefix("pt") ? 2 : 0,
                       identifier: "language", to: cell)
        case .playbackEngine:
            if system == nil {
                cell.textLabel?.text = busy
                    ? engine.text("Loading engine status…", "Consultando el motor…", "Consultando o motor…")
                    : engine.text("Load engine status", "Consultar estado del motor", "Consultar estado do motor")
                if busy {
                        let spinner = UIActivityIndicatorView(style: .gray)
                        spinner.startAnimating()
                        cell.accessoryView = spinner
                } else {
                    cell.accessoryType = .disclosureIndicator
                }
                cell.selectionStyle = .default
            } else if indexPath.row == 0, let system = system {
                cell.textLabel?.text = "yt-dlp · \(system.ytdlp.version ?? engine.text("Not installed", "No instalado", "Não instalado"))"
                cell.detailTextLabel?.text = "Deno: \(system.deno == nil ? "—" : "✓") · FFmpeg: \(system.ffmpeg == nil ? "—" : "✓")"
            } else if indexPath.row == 1 {
                addSegment([engine.text("Stable", "Estable", "Estável"), "Nightly"],
                           selected: channel == "nightly" ? 1 : 0, identifier: "channel", to: cell)
            } else if let system = system {
                cell.textLabel?.text = system.ytdlp.path == nil
                    ? engine.text("Install yt-dlp", "Instalar yt-dlp", "Instalar yt-dlp")
                    : engine.text("Check for updates", "Buscar actualizaciones", "Buscar atualizações")
                cell.detailTextLabel?.text = system.job?.message
                cell.textLabel?.textColor = engine.accent
                cell.selectionStyle = .default
                if busy || system.job?.status == "running" {
                    let spinner = UIActivityIndicatorView(style: .gray)
                    spinner.startAnimating()
                    cell.accessoryView = spinner
                }
            }
        case .diagnostics:
            cell.textLabel?.text = indexPath.row == 0
                ? engine.text("Share playback log", "Compartir registro de reproducción", "Compartilhar registro de reprodução")
                : engine.text("Clear playback log", "Borrar registro de reproducción", "Apagar registro de reprodução")
            if indexPath.row == 1 {
                cell.detailTextLabel?.text = engine.text(
                    "Also clears Recently played.",
                    "También borra Escuchado recientemente.",
                    "Também limpa Tocadas recentemente.")
            }
            cell.textLabel?.textColor = indexPath.row == 0 ? engine.accent : UIColor(red: 0.9, green: 0.25, blue: 0.25, alpha: 1)
            cell.selectionStyle = .default
        case .data:
            cell.textLabel?.text = indexPath.row == 0
                ? engine.text("Export backup", "Exportar copia", "Exportar backup")
                : engine.text("Import backup", "Importar copia", "Importar backup")
            cell.detailTextLabel?.text = indexPath.row == 0
                ? engine.text("Save playlists, favorites and settings.", "Guarda listas, favoritos y ajustes.", "Salve playlists, favoritas e ajustes.")
                : engine.text("Restore a backup from a file.", "Restaura una copia desde un archivo.", "Restaure um backup de um arquivo.")
            cell.textLabel?.textColor = engine.accent
            cell.selectionStyle = .default
            if busy {
                let spinner = UIActivityIndicatorView(style: .gray)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .appearance where indexPath.row == 2:
            chooseCustomAccent()
        case .home where indexPath.row == 3:
            engine.call("resetAppearance") { [weak self] result in self?.showFailure(result) }
        case .playbackEngine:
            if system == nil { loadSystem() }
            else if indexPath.row == 2 { updateEngine() }
        case .diagnostics:
            if indexPath.row == 0 { shareDiagnostics() } else { confirmClearDiagnostics() }
        case .data:
            if indexPath.row == 0 { exportBackup() } else { importBackup() }
        default: break
        }
    }

    private func addSegment(_ titles: [String], selected: Int, identifier: String, to cell: UITableViewCell) {
        let segment = UISegmentedControl(items: titles)
        segment.selectedSegmentIndex = selected
        segment.tintColor = engine.accent
        segment.accessibilityIdentifier = identifier
        segment.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        segment.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(segment)
        NSLayoutConstraint.activate([
            segment.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 14),
            segment.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -14),
            segment.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
        ])
    }

    private func addAccentColors(to cell: UITableViewCell) {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, hex) in colors.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.backgroundColor = LegacyNativeEngine.color(hex: hex)
            button.layer.cornerRadius = 13
            button.layer.borderWidth = engine.appearance.accent.lowercased() == hex ? 3 : 0
            button.layer.borderColor = LegacyTheme.foreground(engine).cgColor
            button.widthAnchor.constraint(equalToConstant: 27).isActive = true
            button.heightAnchor.constraint(equalToConstant: 27).isActive = true
            button.addTarget(self, action: #selector(accentSelected(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -15),
            stack.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
        ])
    }

    private func chooseCustomAccent() {
        let alert = UIAlertController(title: engine.text("Custom accent color", "Color de acento personalizada", "Cor de destaque personalizada"),
                                      message: engine.text("Enter a six-digit hex color.", "Introduce un color hexadecimal de seis dígitos.", "Digite uma cor hexadecimal de seis dígitos."),
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.engine.appearance.accent
            field.placeholder = "#RRGGBB"
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: engine.text("Cancel", "Cancelar", "Cancelar"), style: .cancel))
        alert.addAction(UIAlertAction(title: engine.text("Apply", "Aplicar", "Aplicar"), style: .default) { [weak self, weak alert] _ in
            guard let self = self,
                  let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard hex.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                self.showError(NSError(domain: "Musike", code: 5,
                                       userInfo: [NSLocalizedDescriptionKey: self.engine.text("Enter a valid #RRGGBB color.", "Introduce un color #RRGGBB válido.", "Digite uma cor #RRGGBB válida.")]))
                return
            }
            self.send("appearance", ["patch": ["accent": "#\(hex)"]])
        })
        present(alert, animated: true)
    }

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        switch sender.accessibilityIdentifier {
        case "theme":
            send("theme", ["value": sender.selectedSegmentIndex == 0 ? "dark" : "light"])
        case "language":
            let values = ["en", "es-ES", "pt-BR"]
            send("language", ["value": values[sender.selectedSegmentIndex]])
        case "channel":
            channel = sender.selectedSegmentIndex == 0 ? "stable" : "nightly"
        default: break
        }
    }

    @objc private func settingToggled(_ sender: UISwitch) {
        guard let key = sender.accessibilityIdentifier else { return }
        send("appearance", ["patch": [key: sender.isOn]])
    }

    @objc private func accentSelected(_ sender: UIButton) {
        guard colors.indices.contains(sender.tag) else { return }
        send("appearance", ["patch": ["accent": colors[sender.tag]]])
    }

    private func send(_ action: String, _ arguments: [String: Any]) {
        engine.call(action, arguments) { [weak self] result in self?.showFailure(result) }
    }

    private func showFailure(_ result: Result<Any, Error>) {
        if case .failure(let error) = result { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: engine.text("Error", "Error", "Erro"),
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func loadSystem() {
        guard !busy else { return }
        busy = true
        tableView.reloadData()
        engine.request("system") { [weak self] (result: Result<LegacySystemInfo, Error>) in
            guard let self = self else { return }
            self.busy = false
            switch result {
            case .success(let value):
                if self.system == nil { self.channel = value.ytdlp.channel }
                self.system = value
                self.tableView.reloadData()
                if value.job?.status == "running" && self.settingsVisible {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.loadSystem() }
                }
            case .failure(let error): self.showError(error)
            }
        }
    }

    private func updateEngine() {
        guard !busy else { return }
        busy = true
        tableView.reloadData()
        engine.call("updateEngine", ["channel": channel]) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            switch result {
            case .success: self.loadSystem()
            case .failure(let error): self.showError(error)
            }
        }
    }

    private func exportBackup() {
        guard !busy else { return }
        busy = true
        tableView.reloadData()
        engine.call("createBackup") { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            do {
                let backup = try result.get()
                let data = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("musike-backup-\(formatter.string(from: Date())).musike.json")
                try data.write(to: url, options: .atomic)
                self.share(url)
            } catch { self.showError(error) }
            self.tableView.reloadData()
        }
    }

    private func importBackup() {
        let picker = UIDocumentPickerViewController(documentTypes: [kUTTypeJSON as String], in: .import)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            busy = true
            tableView.reloadData()
            engine.request("previewBackup", ["backup": backup]) { [weak self] (result: Result<LegacyBackupPreview, Error>) in
                guard let self = self else { return }
                self.busy = false
                self.tableView.reloadData()
                switch result {
                case .success(let preview): self.chooseImport(url: url, backup: backup, preview: preview)
                case .failure(let error): self.showError(error)
                }
            }
        } catch { showError(error) }
    }

    private func chooseImport(url: URL, backup: Any, preview: LegacyBackupPreview) {
        let summary = "\(preview.playlists) \(engine.text("playlists", "listas", "playlists")) · " +
            "\(preview.playlistTracks) \(engine.text("tracks", "canciones", "músicas"))\n" +
            "\(preview.favorites) \(engine.text("favorites", "favoritos", "favoritas")) · " +
            "\(preview.history) \(engine.text("recent tracks", "recientes", "recentes"))"
        let alert = UIAlertController(title: url.lastPathComponent, message: summary, preferredStyle: .actionSheet)
        let merge = engine.text("Merge", "Combinar", "Mesclar")
        let replace = engine.text("Replace library", "Reemplazar biblioteca", "Substituir biblioteca")
        alert.addAction(UIAlertAction(title: merge, style: .default) { [weak self] _ in
            self?.restore(backup, mode: "merge", applySettings: true)
        })
        if preview.hasSettings {
            alert.addAction(UIAlertAction(title: engine.text("Merge without settings", "Combinar sin ajustes", "Mesclar sem ajustes"), style: .default) { [weak self] _ in
                self?.restore(backup, mode: "merge", applySettings: false)
            })
        }
        alert.addAction(UIAlertAction(title: replace, style: .destructive) { [weak self] _ in
            self?.restore(backup, mode: "replace", applySettings: true)
        })
        if preview.hasSettings {
            alert.addAction(UIAlertAction(title: engine.text("Replace without settings", "Reemplazar sin ajustes", "Substituir sem ajustes"), style: .destructive) { [weak self] _ in
                self?.restore(backup, mode: "replace", applySettings: false)
            })
        }
        alert.addAction(UIAlertAction(title: engine.text("Cancel", "Cancelar", "Cancelar"), style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(alert, animated: true)
    }

    private func restore(_ backup: Any, mode: String, applySettings: Bool) {
        busy = true
        tableView.reloadData()
        engine.call("restoreBackup", ["backup": backup, "mode": mode, "applySettings": applySettings]) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            self.tableView.reloadData()
            switch result {
            case .success:
                let alert = UIAlertController(title: self.engine.text("Backup", "Copia de seguridad", "Backup"),
                                              message: self.engine.text("Backup imported.", "Copia importada.", "Backup importado."),
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            case .failure(let error): self.showError(error)
            }
        }
    }

    private func shareDiagnostics() {
        PlaybackDiagnostics.shared.export { [weak self] result in
            switch result {
            case .success(let url): self?.share(url)
            case .failure(let error): self?.showError(error)
            }
        }
    }

    private func confirmClearDiagnostics() {
        let alert = UIAlertController(title: engine.text(
            "Clear playback log and Recently played?",
            "¿Borrar el registro y Escuchado recientemente?",
            "Limpar o registro e Tocadas recentemente?"),
                                      message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: engine.text("Cancel", "Cancelar", "Cancelar"), style: .cancel))
        alert.addAction(UIAlertAction(title: engine.text("Clear", "Borrar", "Apagar"), style: .destructive) { _ in
            self.engine.call("clearHistory") { [weak self] historyResult in
                guard let self = self else { return }
                if case .failure(let error) = historyResult {
                    self.showError(error)
                    return
                }
                PlaybackDiagnostics.shared.clear { [weak self] logResult in
                    guard let self = self else { return }
                    switch logResult {
                    case .success:
                        let notice = UIAlertController(
                            title: self.engine.text(
                                "Playback log and history cleared.",
                                "Registro e historial de reproducción borrados.",
                                "Registro e histórico de reprodução apagados."),
                            message: nil,
                            preferredStyle: .alert)
                        notice.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(notice, animated: true)
                    case .failure(let error):
                        self.showError(error)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    private func share(_ url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(activity, animated: true)
    }

    @objc private func done() { dismiss(animated: true) }
}

final class LegacyPlayerController: UIViewController {
    private let engine: LegacyNativeEngine
    private let artwork = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let positionLabel = UILabel()
    private let durationLabel = UILabel()
    private let slider = UISlider()
    private var seeking = false

    init(engine: LegacyNativeEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        title = engine.text("Now playing", "Reproduciendo", "Tocando agora")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: engine.text("Done", "Listo", "Concluído"),
                                                           style: .done, target: self,
                                                           action: #selector(done))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: engine.text("Queue", "Cola", "Fila"),
                                                            style: .plain, target: self,
                                                            action: #selector(queue))
        configureViews()
        engine.stateChanged = { [weak self] in self?.update() }
        update()
    }

    private func configureViews() {
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 18
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textAlignment = .center
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 22)
        titleLabel.numberOfLines = 2
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.textAlignment = .center
        artistLabel.textColor = .lightGray
        artistLabel.font = .systemFont(ofSize: 16)
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.textColor = .lightGray
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.textColor = .lightGray
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.tintColor = engine.accent
        slider.addTarget(self, action: #selector(beginSeek), for: .touchDown)
        slider.addTarget(self, action: #selector(endSeek), for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(self, action: #selector(seekMoving), for: .valueChanged)

        let previous = makeButton(title: "‹", action: #selector(previousTrack))
        let toggle = makeButton(title: ">", action: #selector(toggle))
        toggle.tag = 10
        let next = makeButton(title: "›", action: #selector(nextTrack))
        let controls = UIStackView(arrangedSubviews: [previous, toggle, next])
        controls.axis = .horizontal
        controls.distribution = .equalSpacing
        controls.translatesAutoresizingMaskIntoConstraints = false

        [artwork, titleLabel, artistLabel, positionLabel, slider, durationLabel, controls].forEach(view.addSubview)
        let width = view.widthAnchor
        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            artwork.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            artwork.widthAnchor.constraint(equalTo: width, multiplier: 0.72),
            artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor),
            titleLabel.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            slider.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 24),
            slider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            slider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            positionLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),
            positionLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            durationLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),
            durationLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            controls.topAnchor.constraint(equalTo: positionLabel.bottomAnchor, constant: 24),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 52),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -52),
            controls.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 34)
        button.tintColor = engine.accent
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func update() {
        guard let track = engine.player.current else { return }
        LegacyTheme.apply(to: self, engine: engine)
        if let navigation = navigationController {
            LegacyTheme.apply(to: navigation, engine: engine)
        }
        titleLabel.text = track.title
        artistLabel.text = track.artist
        titleLabel.textColor = LegacyTheme.foreground(engine)
        artistLabel.textColor = LegacyTheme.secondary(engine)
        positionLabel.textColor = LegacyTheme.secondary(engine)
        durationLabel.textColor = LegacyTheme.secondary(engine)
        slider.tintColor = engine.accent
        LegacyArtworkCache.shared.image(for: track.art.isEmpty ? track.thumb : track.art, in: artwork)
        if !seeking {
            slider.maximumValue = Float(max(engine.player.duration, 1))
            slider.value = Float(engine.player.position)
        }
        positionLabel.text = time(engine.player.position)
        durationLabel.text = time(engine.player.duration)
        if let controls = view.subviews.compactMap({ $0 as? UIStackView }).first,
           let button = controls.arrangedSubviews.compactMap({ $0 as? UIButton }).first(where: { $0.tag == 10 }) {
            button.setTitle(engine.player.status == "playing" ? "Ⅱ" : ">", for: .normal)
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }

    @objc private func beginSeek() { seeking = true }
    @objc private func seekMoving() { positionLabel.text = time(Double(slider.value)) }
    @objc private func endSeek() {
        seeking = false
        engine.call("seek", ["position": Double(slider.value)])
    }
    @objc private func previousTrack() { engine.call("previous") }
    @objc private func toggle() { engine.call("toggle") }
    @objc private func nextTrack() { engine.call("next") }
    @objc private func done() { dismiss(animated: true) }
    @objc private func queue() {
        navigationController?.pushViewController(LegacyQueueController(engine: engine), animated: true)
    }
}

final class LegacyQueueController: UITableViewController {
    private let engine: LegacyNativeEngine

    init(engine: LegacyNativeEngine) {
        self.engine = engine
        super.init(style: .plain)
        title = engine.text("Queue", "Cola", "Fila")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor(red: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
        tableView.separatorStyle = .none
        tableView.register(LegacyTrackCell.self, forCellReuseIdentifier: LegacyTrackCell.reuseID)
        engine.stateChanged = { [weak self] in self?.tableView.reloadData() }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { engine.player.queue.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LegacyTrackCell.reuseID, for: indexPath) as! LegacyTrackCell
        let track = engine.player.queue[indexPath.row]
        cell.configure(track: track, dark: engine.appearance.theme != "light")
        cell.accessoryType = indexPath.row == engine.player.index ? .checkmark : .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 68 }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        engine.call("jumpTo", ["index": indexPath.row])
    }
}
