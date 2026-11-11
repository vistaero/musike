import SwiftUI
import Combine
import Network
import WebKit
import UniformTypeIdentifiers

/// A bounded local trace containing playback events and error codes, never track names or stream URLs.
final class PlaybackDiagnostics: NSObject, WKScriptMessageHandler, ObservableObject {
    static let shared = PlaybackDiagnostics()
    @Published private(set) var networkUnavailable = false
    private let queue = DispatchQueue(label: "app.musike.playback-diagnostics")
    private let pathMonitor = NWPathMonitor()
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("playback-diagnostics.log")
    private var lines: [String]?
    private let limit = 600
    private override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.record(Self.describe(path))
            let unavailable = path.status != .satisfied
            DispatchQueue.main.async { self?.networkUnavailable = unavailable }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.musike.network-diagnostics"))
    }

    private static func describe(_ path: NWPath) -> String {
        let connection: String
        if path.usesInterfaceType(.wifi) { connection = "wifi" }
        else if path.usesInterfaceType(.cellular) { connection = "cellular" }
        else if path.usesInterfaceType(.wiredEthernet) { connection = "wired" }
        else { connection = "other" }
        let state = path.status == .satisfied ? "satisfied" : path.status == .requiresConnection ? "requires-connection" : "unsatisfied"
        return "network.path type=\(connection) state=\(state) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
    }

    private func readLines() -> [String] {
        if let lines { return lines }
        let data = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let restored = data.split(separator: "\n").map(String.init).suffix(limit)
        lines = Array(restored)
        return lines ?? []
    }
    private func persist(_ entries: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (entries.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    func record(_ message: String) {
        queue.async {
            var entries = self.readLines()
            entries.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
            if entries.count > self.limit { entries.removeFirst(entries.count - self.limit) }
            self.lines = entries
            try? self.persist(entries)
        }
    }
    static func errorCode(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "none" }
        let domain = error.domain.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil ? error.domain : "other"
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " underlying=\($0.code)" } ?? ""
        return "domain=\(domain) code=\(error.code)\(underlying)"
    }
    func sessionStarted() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        record("session.start app=\(version) build=\(build) ios=\(UIDevice.current.systemVersion)")
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let event = message.body as? String, event.count <= 80,
              event.range(of: "^[a-z0-9_.-]+$", options: .regularExpression) != nil else { return }
        record("web.\(event)")
    }
    func clear(completion: @escaping () -> Void) {
        queue.async {
            self.lines = []
            try? self.persist([])
            self.record("diagnostics.cleared")
            self.record(Self.describe(self.pathMonitor.currentPath))
            DispatchQueue.main.async(execute: completion)
        }
    }
    func export(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                var entries = self.readLines()
                entries.append("\(ISO8601DateFormatter().string(from: Date())) diagnostics.export")
                if entries.count > self.limit { entries.removeFirst(entries.count - self.limit) }
                self.lines = entries
                try? self.persist(entries)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("musike-playback-diagnostics.log")
                try (entries.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

struct Track: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double
    let thumb: String
    let art: String
    let kind: String
}
struct Playlist: Codable, Identifiable {
    let id: String
    let name: String
    let tracks: [Track]
}
struct LibraryState: Decodable {
    var favorites: [Track] = []
    var history: [Track] = []
    var playlists: [Playlist] = []
    var status: String = "idle"
}
struct PlayerState: Decodable {
    var queue: [Track] = []
    var index: Int = 0
    var status: String = "idle"
    var position: Double = 0
    var duration: Double = 0
    var shuffle: Bool = false
    var `repeat`: String = "off"
    var autoRadio: Bool = false
    var volume: Double = 0.9
    var muted: Bool = false
    var errorText: String? = nil
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
}
struct Appearance: Decodable {
    var accent: String = "#c3ec52"
    var theme: String = "dark"
    var homeShortcuts: Bool = true
    var homeRecent: Bool = true
    var homeFavorites: Bool = true
}
struct Snapshot: Decodable { var player: PlayerState; var library: LibraryState; var appearance: Appearance; var lang: String; var engineSettings: Bool? }
struct Genre: Decodable, Identifiable { let id: String; let name: String }
struct AlbumCard: Decodable, Identifiable { let id: String; let title: String; let artist: String; let art: String; let thumb: String; let year: String }
struct GenreArtist: Decodable, Identifiable { let id: String; let name: String; let art: String; let thumb: String; let hits: [String] }
struct GenrePage: Decodable { let name: String; let artists: [GenreArtist]; let hasMoreArtists: Bool; let tracks: [Track] }
struct MoreArtists: Decodable { let artists: [GenreArtist]; let hasMore: Bool }
struct ArtistPage: Decodable { let name: String; let description: String; let tracks: [Track]; let albums: [AlbumCard]; let singles: [AlbumCard] }
struct AlbumPage: Decodable { let title: String; let artist: String; let artistId: String?; let kind: String; let art: String; let thumb: String; let info: String; let tracks: [Track] }

final class NativeEngine: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var player = PlayerState()
    @Published var library = LibraryState()
    @Published var appearance = Appearance()
    @Published var language = "en"
    @Published var engineSettings = false
    @Published var ready = false
    @Published var error: String?
    weak var webView: WKWebView?
    private var nextID = 0
    private var callbacks: [Int: (Result<Any, Error>) -> Void] = [:]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { PlaybackDiagnostics.shared.record("web.bridge.ready"); ready = true; return }
        if type == "state", let data = try? JSONSerialization.data(withJSONObject: body),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            player = snapshot.player; library = snapshot.library; appearance = snapshot.appearance; language = snapshot.lang; engineSettings = snapshot.engineSettings ?? false
        } else if type == "response", let id = body["id"] as? Int, let callback = callbacks.removeValue(forKey: id) {
            if let message = body["error"] as? String { callback(.failure(NSError(domain: "Musike", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))) }
            else { callback(.success(body["result"] ?? NSNull())) }
        }
    }
    func call(_ action: String, _ args: [String: Any] = [:], completion: ((Result<Any, Error>) -> Void)? = nil) {
        guard ready, let webView else { completion?(.failure(NSError(domain: "Musike", code: 2, userInfo: [NSLocalizedDescriptionKey: "Musike is starting up."]))); return }
        nextID += 1
        let id = nextID
        if let completion { callbacks[id] = completion }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "action": action, "args": args]), let json = String(data: data, encoding: .utf8) else {
            callbacks.removeValue(forKey: id)?(.failure(NSError(domain: "Musike", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid request data."])))
            return
        }
        webView.evaluateJavaScript("void window.musikeNative.dispatch(\(json))") { [weak self] _, error in
            if let error { self?.callbacks.removeValue(forKey: id)?(.failure(error)) }
        }
    }
    func request<T: Decodable>(_ action: String, _ args: [String: Any] = [:], completion: @escaping (Result<T, Error>) -> Void) {
        call(action, args) { result in
            completion(result.flatMap { value in Result {
                guard JSONSerialization.isValidJSONObject(value) else {
                    throw NSError(domain: "Musike", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid response data."])
                }
                return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
            } })
        }
    }
    func object<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? [:] }
    func play(_ tracks: [Track], at index: Int = 0) { guard !tracks.isEmpty else { return }; call("playList", ["tracks": object(tracks), "index": index]) }
    func track(_ action: String, _ track: Track, extra: [String: Any] = [:]) { var args = extra; args["track"] = object(track); call(action, args) }
    func text(_ en: String, _ es: String, _ pt: String) -> String { language.hasPrefix("es") ? es : language.hasPrefix("pt") ? pt : en }
    var accent: Color { Color(hex: appearance.accent) }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0xc3ec52
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 20
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
        else { content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius)) }
    }
}
extension View { func musikeGlass(_ radius: CGFloat = 20) -> some View { modifier(GlassSurface(radius: radius)) } }

struct Artwork: View {
    var url: String
    var size: CGFloat = 56
    var body: some View {
        AsyncImage(url: URL(string: url)) { image in image.resizable().scaledToFill() } placeholder: {
            ZStack { Color.secondary.opacity(0.15); Image(systemName: "music.note").foregroundColor(.secondary) }
        }.frame(width: size, height: size).clipped().cornerRadius(size * 0.16)
    }
}

struct NativeRoot: View {
    @ObservedObject var engine: NativeEngine
    @State private var tab = 0
    @State private var playerOpen = false
    @ViewBuilder var body: some View {
        Group {
        if #available(iOS 26.1, *) {
            tabs.tabViewBottomAccessory(isEnabled: engine.player.current != nil) {
                if let track = engine.player.current { MiniPlayer(engine: engine, track: track, open: { playerOpen = true }, accessory: true) }
            }.modifier(RootPresentation(engine: engine, playerOpen: $playerOpen))
        } else if #available(iOS 26.0, *) {
            tabs.tabViewBottomAccessory {
                if let track = engine.player.current { MiniPlayer(engine: engine, track: track, open: { playerOpen = true }, accessory: true) }
            }.modifier(RootPresentation(engine: engine, playerOpen: $playerOpen))
        } else {
            tabs.modifier(RootPresentation(engine: engine, playerOpen: $playerOpen))
        }
        }.preferredColorScheme(engine.appearance.theme == "light" ? .light : .dark).tint(engine.accent)
    }
    var tabs: some View {
        TabView(selection: $tab) {
            tabContent { HomeScreen(engine: engine, tab: $tab) }
                .tabItem { Label(engine.text("Home", "Inicio", "Início"), systemImage: "house.fill") }.tag(0)
            tabContent { SearchScreen(engine: engine) }
                .tabItem { Label(engine.text("Search", "Buscar", "Buscar"), systemImage: "magnifyingglass") }.tag(1)
            tabContent { LibraryScreen(engine: engine) }
                .tabItem { Label(engine.text("Library", "Biblioteca", "Biblioteca"), systemImage: "square.stack.fill") }.tag(2)
        }
    }
    @ViewBuilder func tabContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            NavigationView { content() }.navigationViewStyle(.stack)
        } else {
            NavigationView { content() }.navigationViewStyle(.stack)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let track = engine.player.current {
                        MiniPlayer(engine: engine, track: track, open: { playerOpen = true }).padding(.horizontal, 10).padding(.bottom, 5)
                    }
                }
        }
    }
}

struct RootPresentation: ViewModifier {
    @ObservedObject var engine: NativeEngine
    @Binding var playerOpen: Bool
    func body(content: Content) -> some View {
        content.sheet(isPresented: $playerOpen) { PlayerScreen(engine: engine) }
            .alert(engine.text("Error", "Error", "Erro"), isPresented: Binding(get: { engine.error != nil }, set: { if !$0 { engine.error = nil } })) {
                Button("OK", role: .cancel) { engine.error = nil }
            } message: { Text(engine.error ?? "") }
    }

}

struct MiniPlayer: View {
    @ObservedObject var engine: NativeEngine
    @ObservedObject private var diagnostics = PlaybackDiagnostics.shared
    let track: Track
    var open: () -> Void
    var accessory = false
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.thumb, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.subheadline.bold()).lineLimit(1)
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { engine.call("toggle") } label: {
                if engine.player.status == "loading" { ProgressView().frame(width: 42, height: 48) }
                else { Image(systemName: engine.player.status == "playing" ? "pause.fill" : "play.fill").font(.title3).frame(width: 42, height: 48) }
            }.accessibilityLabel(engine.player.status == "playing" ? engine.text("Pause", "Pausar", "Pausar") : engine.text("Play", "Reproducir", "Tocar"))
            Button { engine.call("next") } label: { Image(systemName: "forward.end.fill").frame(width: 38, height: 48) }.accessibilityLabel(engine.text("Next", "Siguiente", "Próxima"))
        }.foregroundColor(.primary).padding(accessory ? 4 : 8).contentShape(Rectangle()).onTapGesture(perform: open)
            .modifier(MiniPlayerSurface(accessory: accessory))
    }
    private var subtitle: String {
        if (engine.player.status == "loading" || engine.player.status == "error") && diagnostics.networkUnavailable {
            return engine.text("No network connection", "Sin conexión de red", "Sem conexão de rede")
        }
        if engine.player.status == "loading" { return engine.text("Loading…", "Cargando…", "Carregando…") }
        if engine.player.status == "error" { return engine.text("Playback failed", "Error de reproducción", "Erro de reprodução") }
        return track.artist
    }
}

struct MiniPlayerSurface: ViewModifier {
    var accessory: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if accessory { content } else { content.musikeGlass(20) }
    }
}

struct NativeSystemJob: Decodable { let status: String; let message: String; let log: [String] }
struct NativeSystemInfo: Decodable {
    struct Ytdlp: Decodable { let path: String?; let version: String?; let channel: String; let updateAvailable: Bool }
    let ytdlp: Ytdlp
    let deno: String?
    let ffmpeg: String?
    let canInstall: Bool
    let job: NativeSystemJob?
}

struct BackupPreview: Decodable {
    let playlists: Int
    let playlistTracks: Int
    let favorites: Int
    let history: Int
    let hasSettings: Bool
}
struct ShareFile: Identifiable { let id = UUID(); let url: URL }
struct NativeShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SettingsScreen: View {
    @ObservedObject var engine: NativeEngine
    @Environment(\.presentationMode) private var presentation
    @State private var customColor = Color(hex: "#c3ec52")
    @State private var importing = false
    @State private var pendingBackup: Any?
    @State private var backupName = ""
    @State private var preview: BackupPreview?
    @State private var importMode = "merge"
    @State private var applySettings = true
    @State private var confirmReplace = false
    @State private var busy = false
    @State private var shareFile: ShareFile?
    @State private var notice: String?
    @State private var system: NativeSystemInfo?
    @State private var systemBusy = false
    @State private var channel = "stable"
    @State private var settingsVisible = false
    private let colors = ["#c3ec52", "#34d399", "#22d3ee", "#60a5fa", "#a78bfa", "#f472b6", "#fb7c5c", "#fbbf24"]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(engine.text("Appearance", "Apariencia", "Aparência"))) {
                    Picker(engine.text("Theme", "Tema", "Tema"), selection: Binding(get: { engine.appearance.theme }, set: { engine.call("theme", ["value": $0]) })) {
                        Text(engine.text("Dark", "Oscuro", "Escuro")).tag("dark")
                        Text(engine.text("Light", "Claro", "Claro")).tag("light")
                    }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(engine.text("Accent color", "Color de acento", "Cor de destaque"))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 10)], alignment: .leading, spacing: 12) {
                            ForEach(colors, id: \.self) { hex in
                                Button { setColor(hex) } label: {
                                    ZStack { Circle().fill(Color(hex: hex)); if engine.appearance.accent.lowercased() == hex { Image(systemName: "checkmark").font(.caption.bold()).foregroundColor(.black) } }
                                        .frame(width: 34, height: 34)
                                }.buttonStyle(.plain).accessibilityLabel(hex)
                            }
                        }
                        ColorPicker(engine.text("Custom color", "Color personalizado", "Cor personalizada"), selection: $customColor, supportsOpacity: false)
                            .onChange(of: customColor) { color in
                                let uiColor = UIColor(color); var red: CGFloat = 0; var green: CGFloat = 0; var blue: CGFloat = 0; var alpha: CGFloat = 0
                                if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                                    setColor(String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())))
                                }
                            }
                    }.padding(.vertical, 4)
                }
                Section(header: Text(engine.text("Language", "Idioma", "Idioma"))) {
                    Picker(engine.text("Language", "Idioma", "Idioma"), selection: Binding(get: { engine.language }, set: { engine.call("language", ["value": $0]) })) {
                        Text("English").tag("en"); Text("Español").tag("es-ES"); Text("Português (Brasil)").tag("pt-BR")
                    }
                }
                Section(header: Text(engine.text("Home", "Inicio", "Início"))) {
                    Toggle(engine.text("Shortcuts", "Accesos directos", "Atalhos"), isOn: setting("homeShortcuts", engine.appearance.homeShortcuts))
                    Toggle(engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente"), isOn: setting("homeRecent", engine.appearance.homeRecent))
                    Toggle(engine.text("Your favorites", "Tus favoritos", "Suas favoritas"), isOn: setting("homeFavorites", engine.appearance.homeFavorites))
                    Button(engine.text("Reset appearance", "Restablecer apariencia", "Redefinir aparência")) { engine.call("resetAppearance") }
                }
                if engine.engineSettings {
                    Section(header: Text(engine.text("Playback engine", "Motor de reproducción", "Motor de reprodução"))) {
                        if let system {
                            Text("yt-dlp · \(system.ytdlp.version ?? engine.text("Not installed", "No instalado", "Não instalado"))")
                            Picker(engine.text("Channel", "Canal", "Canal"), selection: $channel) {
                                Text(engine.text("Stable", "Estable", "Estável")).tag("stable")
                                Text("Nightly").tag("nightly")
                            }.pickerStyle(.segmented)
                            if let job = system.job {
                                Text(job.message).font(.caption).foregroundColor(.secondary)
                                if !job.log.isEmpty { Text(job.log.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                            Button(system.ytdlp.path == nil ? engine.text("Install", "Instalar", "Instalar") : engine.text("Check for updates", "Buscar actualizaciones", "Buscar atualizações")) { updateEngine() }
                                .disabled(systemBusy || system.job?.status == "running" || (system.ytdlp.path == nil && !system.canInstall))
                            Text("Deno: \(system.deno == nil ? "—" : "✓") · FFmpeg: \(system.ffmpeg == nil ? "—" : "✓")").font(.caption).foregroundColor(.secondary)
                        } else if systemBusy { ProgressView() }
                        else { Button(engine.text("Load engine status", "Consultar estado del motor", "Consultar estado do motor")) { loadSystem() } }
                    }
                }
                Section(header: Text(engine.text("Playback diagnostics", "Diagnóstico de reproducción", "Diagnóstico de reprodução")), footer: Text(engine.text("The log contains connection type, playback events and error codes, but no song names or stream links.", "El registro contiene el tipo de conexión, eventos y códigos de error, sin nombres de canciones ni enlaces de reproducción.", "O registro contém o tipo de conexão, eventos e códigos de erro, sem nomes de músicas ou links de reprodução."))) {
                    Button {
                        PlaybackDiagnostics.shared.export { result in
                            switch result {
                            case .success(let url): shareFile = ShareFile(url: url)
                            case .failure(let error): engine.error = error.localizedDescription
                            }
                        }
                    } label: { Label(engine.text("Share playback log", "Compartir registro de reproducción", "Compartilhar registro de reprodução"), systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) {
                        PlaybackDiagnostics.shared.clear { notice = engine.text("Playback log cleared.", "Registro de reproducción borrado.", "Registro de reprodução apagado.") }
                    } label: { Label(engine.text("Clear playback log", "Borrar registro de reproducción", "Apagar registro de reprodução"), systemImage: "trash") }
                }
                Section(header: Text(engine.text("Your data", "Tus datos", "Seus dados")), footer: Text(engine.text("Move your library between Musike installations.", "Lleva tu biblioteca a otra instalación de Musike.", "Transfira sua biblioteca para outra instalação do Musike."))) {
                    Button { exportBackup() } label: { Label(engine.text("Export backup", "Exportar copia", "Exportar backup"), systemImage: "square.and.arrow.up") }.disabled(busy)
                    Button { importing = true } label: { Label(engine.text("Import backup", "Importar copia", "Importar backup"), systemImage: "square.and.arrow.down") }.disabled(busy)
                    if busy { ProgressView() }
                    if let preview {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(backupName).font(.headline).lineLimit(1)
                            Text("\(preview.playlists) \(engine.text("playlists", "listas", "playlists")) · \(preview.playlistTracks) \(engine.text("tracks", "canciones", "músicas"))")
                            Text("\(preview.favorites) \(engine.text("favorites", "favoritos", "favoritas")) · \(preview.history) \(engine.text("recent tracks", "recientes", "recentes"))")
                        }.font(.subheadline).foregroundColor(.secondary)
                        Picker(engine.text("Import mode", "Modo de importación", "Modo de importação"), selection: $importMode) {
                            Text(engine.text("Merge", "Combinar", "Mesclar")).tag("merge")
                            Text(engine.text("Replace", "Reemplazar", "Substituir")).tag("replace")
                        }.pickerStyle(.segmented)
                        if preview.hasSettings { Toggle(engine.text("Apply saved settings", "Aplicar ajustes guardados", "Aplicar ajustes salvos"), isOn: $applySettings) }
                        Text(importMode == "replace" ? engine.text("Replaces the current library with this backup.", "Sustituye la biblioteca actual por esta copia.", "Substitui a biblioteca atual por este backup.") : engine.text("Adds the backup to your current library.", "Añade la copia a tu biblioteca actual.", "Adiciona o backup à sua biblioteca atual.")).font(.caption).foregroundColor(.secondary)
                        Button(importMode == "replace" ? engine.text("Replace library", "Reemplazar biblioteca", "Substituir biblioteca") : engine.text("Import", "Importar", "Importar")) {
                            if importMode == "replace" { confirmReplace = true } else { restoreBackup() }
                        }.disabled(busy)
                        Button(engine.text("Cancel", "Cancelar", "Cancelar"), role: .cancel) { pendingBackup = nil; self.preview = nil }
                    }
                }
            }
            .navigationTitle(engine.text("Settings", "Ajustes", "Ajustes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(engine.text("Done", "Listo", "Concluído")) { presentation.wrappedValue.dismiss() } } }
            .onAppear { settingsVisible = true; customColor = Color(hex: engine.appearance.accent); if engine.engineSettings { loadSystem() } }
            .onDisappear { settingsVisible = false }
            .onChange(of: engine.engineSettings) { enabled in if enabled && settingsVisible { loadSystem() } }
            .onChange(of: engine.appearance.accent) { customColor = Color(hex: $0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): previewBackup(url)
                case .failure(let error): engine.error = error.localizedDescription
                }
            }
            .sheet(item: $shareFile) { NativeShareSheet(url: $0.url) }
            .alert(engine.text("Replace your library?", "¿Reemplazar tu biblioteca?", "Substituir sua biblioteca?"), isPresented: $confirmReplace) {
                Button(engine.text("Replace", "Reemplazar", "Substituir"), role: .destructive) { restoreBackup() }
                Button(engine.text("Cancel", "Cancelar", "Cancelar"), role: .cancel) {}
            } message: { Text(engine.text("Your current library will be replaced by the backup.", "La biblioteca actual será sustituida por la copia.", "Sua biblioteca atual será substituída pelo backup.")) }
            .alert(engine.text("Error", "Error", "Erro"), isPresented: Binding(get: { engine.error != nil }, set: { if !$0 { engine.error = nil } })) { Button("OK", role: .cancel) { engine.error = nil } } message: { Text(engine.error ?? "") }
            .alert(engine.text("Backup", "Copia de seguridad", "Backup"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK", role: .cancel) { notice = nil } } message: { Text(notice ?? "") }
        }.navigationViewStyle(.stack).tint(engine.accent).preferredColorScheme(engine.appearance.theme == "light" ? .light : .dark)
    }
    private func loadSystem() {
        guard !systemBusy else { return }
        systemBusy = true
        engine.request("system") { (result: Result<NativeSystemInfo, Error>) in
            systemBusy = false
            switch result {
            case .success(let value):
                if system == nil { channel = value.ytdlp.channel }
                system = value
                if value.job?.status == "running" && settingsVisible {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if settingsVisible { loadSystem() } }
                }
            case .failure(let failure): engine.error = failure.localizedDescription
            }
        }
    }
    private func updateEngine() {
        systemBusy = true
        engine.call("updateEngine", ["channel": channel]) { result in
            systemBusy = false
            switch result { case .success: loadSystem(); case .failure(let failure): engine.error = failure.localizedDescription }
        }
    }
    func setting(_ key: String, _ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { engine.call("appearance", ["patch": [key: $0]]) })
    }
    func setColor(_ hex: String) {
        guard hex.lowercased() != engine.appearance.accent.lowercased() else { return }
        engine.call("appearance", ["patch": ["accent": hex]])
    }
    func exportBackup() {
        busy = true
        engine.call("createBackup") { result in
            busy = false
            do {
                let data = try JSONSerialization.data(withJSONObject: result.get(), options: [.prettyPrinted, .sortedKeys])
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("musike-backup-\(formatter.string(from: Date())).musike.json")
                try data.write(to: url, options: .atomic)
                shareFile = ShareFile(url: url)
            } catch { engine.error = error.localizedDescription }
        }
    }
    func previewBackup(_ url: URL) {
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let backup = try JSONSerialization.jsonObject(with: data)
            busy = true
            engine.request("previewBackup", ["backup": backup]) { (result: Result<BackupPreview, Error>) in
                busy = false
                switch result {
                case .success(let value): pendingBackup = backup; backupName = url.lastPathComponent; preview = value; importMode = "merge"; applySettings = true
                case .failure(let error): engine.error = error.localizedDescription
                }
            }
        } catch { engine.error = error.localizedDescription }
    }
    func restoreBackup() {
        guard let backup = pendingBackup else { return }
        busy = true
        engine.call("restoreBackup", ["backup": backup, "mode": importMode, "applySettings": applySettings]) { result in
            busy = false
            switch result {
            case .success: pendingBackup = nil; preview = nil; notice = engine.text("Backup imported.", "Copia importada.", "Backup importado.")
            case .failure(let error): engine.error = error.localizedDescription
            }
        }
    }
}

struct HomeScreen: View {
    @ObservedObject var engine: NativeEngine
    @Binding var tab: Int
    @State private var settingsOpen = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(engine.text("Your music, uninterrupted.", "Tu música, sin interrupciones.", "Sua música, sem interrupções.")).font(.subheadline).foregroundColor(.secondary)
                if engine.appearance.homeShortcuts {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        NavigationLink { CollectionScreen(engine: engine, title: engine.text("Favorites", "Favoritos", "Favoritas"), tracks: engine.library.favorites) } label: { shortcut("heart.fill", engine.text("Favorites", "Favoritos", "Favoritas")) }
                        NavigationLink { CollectionScreen(engine: engine, title: engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente"), tracks: engine.library.history) } label: { shortcut("clock.arrow.circlepath", engine.text("Recent", "Recientes", "Recentes")) }
                        ForEach(Array(engine.library.playlists.prefix(6))) { playlist in
                            NavigationLink { PlaylistScreen(engine: engine, id: playlist.id) } label: { shortcut("music.note.list", playlist.name) }
                        }
                    }.buttonStyle(.plain)
                }
                if !engine.ready || engine.library.status == "loading" { ProgressView().frame(maxWidth: .infinity).padding() }
                else if engine.library.history.isEmpty && engine.library.favorites.isEmpty && engine.library.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(engine.text("Find your next favorite", "Encuentra tu próxima favorita", "Encontre sua próxima favorita")).font(.title2.bold())
                        Text(engine.text("Search for music to start listening.", "Busca música para empezar a escuchar.", "Busque músicas para começar a ouvir.")).foregroundColor(.secondary)
                        Button(engine.text("Search music", "Buscar música", "Buscar música")) { tab = 1 }.buttonStyle(.borderedProminent).tint(engine.accent).foregroundColor(.black)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).musikeGlass()
                }
                if engine.appearance.homeRecent && !engine.library.history.isEmpty {
                    Text(engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente")).font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: false) { HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(engine.library.history.prefix(16).enumerated()), id: \.element.id) { index, track in
                            Button { engine.play(engine.library.history, at: index) } label: { VStack(alignment: .leading, spacing: 6) {
                                Artwork(url: track.art.isEmpty ? track.thumb : track.art, size: 140)
                                Text(track.title).font(.subheadline.bold()).lineLimit(1); Text(track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }.frame(width: 140, alignment: .leading) }.buttonStyle(.plain)
                        }
                    } }
                }
                if engine.appearance.homeFavorites && !engine.library.favorites.isEmpty {
                    Text(engine.text("Your favorites", "Tus favoritos", "Suas favoritas")).font(.title2.bold())
                    TrackList(engine: engine, tracks: Array(engine.library.favorites.prefix(5)))
                }
            }.padding()
        }.navigationTitle("Musike").toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { settingsOpen = true } label: { Image(systemName: "gearshape") }.accessibilityLabel(engine.text("Settings", "Ajustes", "Ajustes")) } }
        .sheet(isPresented: $settingsOpen) { SettingsScreen(engine: engine) }
    }
    func shortcut(_ icon: String, _ title: String) -> some View {
        HStack { Image(systemName: icon).foregroundColor(engine.accent); Text(title).font(.subheadline.bold()).lineLimit(1); Spacer(minLength: 0) }.padding().frame(maxWidth: .infinity, minHeight: 65).musikeGlass(16)
    }
}

struct PreparedTrack: Decodable { let id: String; let title: String; let duration: Double }

struct SearchScreen: View {
    @ObservedObject var engine: NativeEngine
    @State private var query = ""
    @State private var kind = "song"
    @State private var tracks: [Track] = []
    @State private var albums: [AlbumCard] = []
    @State private var genres: [Genre] = []
    @State private var genresError: String?
    @State private var suggestions: [String] = []
    @State private var recent: [String] = []
    @State private var linkTrack: Track?
    @State private var error: String?
    @State private var loading = false
    @State private var searched = false
    @State private var requestID = 0
    @StateObject private var batch = BatchSearchModel()
    private var linkID: String? { SearchUtilities.youtubeID(query) }
    private var terms: [String] { BatchSearchModel.terms(query) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if linkID == nil {
                    Picker(engine.text("Type", "Tipo", "Tipo"), selection: $kind) {
                        Text(engine.text("Songs", "Canciones", "Músicas")).tag("song")
                        Text(engine.text("Videos", "Vídeos", "Vídeos")).tag("video")
                        Text(engine.text("Albums", "Álbumes", "Álbuns")).tag("album")
                    }.pickerStyle(.segmented)
                }
                HStack {
                    NavigationLink {
                        BatchSearchScreen(engine: engine, model: batch)
                    } label: {
                        Label(engine.text("Search a list", "Buscar una lista", "Buscar lista"), systemImage: "list.bullet.rectangle")
                    }.buttonStyle(.bordered).accessibilityIdentifier("search-list")
                    Spacer()
                }
                if linkID == nil && query.contains(",") && terms.count > 1 {
                    NavigationLink {
                        BatchSearchScreen(engine: engine, model: batch, initialText: query)
                    } label: {
                        Label(engine.text("Search each song separately", "Buscar cada canción por separado", "Buscar cada música separadamente"), systemImage: "list.bullet")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(12).musikeGlass(14)
                    }.buttonStyle(.plain)
                }
                if !suggestions.isEmpty && linkID == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { query = suggestion }.buttonStyle(.bordered)
                        } }
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                else if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(.subheadline).foregroundColor(.secondary)
                        Button(engine.text("Retry", "Reintentar", "Tentar novamente")) { search() }.buttonStyle(.bordered)
                    }
                } else if let linkTrack {
                    Button { engine.track("playTrack", linkTrack) } label: {
                        HStack(spacing: 12) {
                            Artwork(url: linkTrack.thumb, size: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(engine.text("YouTube link", "Enlace de YouTube", "Link do YouTube")).font(.caption).foregroundColor(engine.accent)
                                Text(linkTrack.title).font(.headline).lineLimit(2)
                            }
                            Spacer(); Image(systemName: "play.circle.fill").font(.title2)
                        }.padding(12).musikeGlass(16)
                    }.buttonStyle(.plain)
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !recent.isEmpty {
                        HStack {
                            Text(engine.text("Recent searches", "Búsquedas recientes", "Buscas recentes")).font(.title3.bold())
                            Spacer()
                            Button(engine.text("Clear", "Borrar", "Limpar")) { clearRecent() }.font(.caption)
                        }
                        ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(recent, id: \.self) { term in Button(term) { query = term }.buttonStyle(.bordered) } } }
                    }
                    Text(engine.text("Explore genres", "Explorar géneros", "Explorar gêneros")).font(.title2.bold())
                    if let genresError {
                        Text(genresError).font(.caption).foregroundColor(.secondary)
                        Button(engine.text("Retry", "Reintentar", "Tentar novamente")) { loadGenres() }.buttonStyle(.bordered)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                        ForEach(genres) { genre in NavigationLink { GenreScreen(engine: engine, genre: genre) } label: {
                            Text(genre.name).font(.headline).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading).padding(.horizontal).musikeGlass(16)
                        }.buttonStyle(.plain) }
                    }
                } else if kind == "album" {
                    ForEach(albums) { album in NavigationLink { AlbumScreen(engine: engine, id: album.id) } label: { AlbumRow(album: album) }.buttonStyle(.plain) }
                    if searched && albums.isEmpty { noResults }
                } else {
                    TrackList(engine: engine, tracks: tracks)
                    if searched && tracks.isEmpty { noResults }
                }
            }.padding()
        }.navigationTitle(engine.text("Search", "Buscar", "Buscar"))
        .searchable(text: $query, prompt: Text(engine.text("Artists, songs, albums or a YouTube link", "Artistas, canciones, álbumes o enlace de YouTube", "Artistas, músicas, álbuns ou link do YouTube")))
        .onChange(of: query) { _ in search(); suggest() }.onChange(of: kind) { _ in search() }
        .onAppear { if engine.ready { loadGenres(); loadRecent() } }
        .onChange(of: engine.ready) { ready in if ready { loadGenres(); loadRecent(); if !query.isEmpty { search(); suggest() } } }
        .onChange(of: engine.language) { _ in
            genres = []; genresError = nil
            if engine.ready { loadGenres(); if !query.isEmpty { search(); suggest() } }
        }
    }
    private var noResults: some View { Text(engine.text("No results found.", "No se han encontrado resultados.", "Nenhum resultado encontrado.")).foregroundColor(.secondary).padding(.top) }
    func loadGenres() {
        guard genres.isEmpty else { return }
        genresError = nil
        engine.request("genres") { (result: Result<[Genre], Error>) in
            switch result { case .success(let value): genres = value; case .failure(let failure): genresError = failure.localizedDescription }
        }
    }
    func loadRecent() { engine.request("recentSearches") { (result: Result<[String], Error>) in if case .success(let value) = result { recent = value } } }
    func clearRecent() { recent = []; engine.call("clearRecentSearches") }
    func remember(_ text: String) { engine.request("recordRecentSearch", ["query": text]) { (result: Result<[String], Error>) in if case .success(let value) = result { recent = value } } }
    func suggest() {
        let current = requestID
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, linkID == nil, engine.ready else { suggestions = []; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            guard current == requestID else { return }
            engine.request("suggest", ["query": text]) { (result: Result<[String], Error>) in
                guard current == requestID else { return }
                if case .success(let values) = result { suggestions = Array(values.filter { $0.lowercased() != text.lowercased() }.prefix(6)) }
            }
        }
    }
    func search() {
        requestID += 1; let current = requestID
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks = []; albums = []; linkTrack = nil; error = nil; searched = false
        guard !text.isEmpty else { loading = false; return }
        guard engine.ready else { loading = false; return }
        loading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            guard current == requestID else { return }
            if let id = SearchUtilities.youtubeID(text) {
                engine.request("prepare", ["id": id]) { (result: Result<PreparedTrack, Error>) in
                    guard current == requestID else { return }; loading = false
                    switch result {
                    case .success(let value): linkTrack = Track(id: value.id, title: value.title, artist: engine.text("YouTube link", "Enlace de YouTube", "Link do YouTube"), album: nil, duration: value.duration, thumb: "https://i.ytimg.com/vi/\(value.id)/mqdefault.jpg", art: "https://i.ytimg.com/vi/\(value.id)/hq720.jpg", kind: "video")
                    case .failure(let failure): error = failure.localizedDescription
                    }
                }
            } else if kind == "album" {
                engine.request("search", ["query": text, "kind": kind]) { (result: Result<[AlbumCard], Error>) in
                    guard current == requestID else { return }; loading = false; searched = true
                    switch result { case .success(let items): albums = items; remember(text); case .failure(let failure): error = failure.localizedDescription }
                }
            } else {
                engine.request("search", ["query": text, "kind": kind]) { (result: Result<[Track], Error>) in
                    guard current == requestID else { return }; loading = false; searched = true
                    switch result { case .success(let items): tracks = items; remember(text); case .failure(let failure): error = failure.localizedDescription }
                }
            }
        }
    }
}

struct ClearTextEditorBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, *) { content.scrollContentBackground(.hidden) }
        else { content }
    }
}

struct BatchSearchScreen: View {
    @ObservedObject var engine: NativeEngine
    @ObservedObject var model: BatchSearchModel
    var initialText: String? = nil
    @State private var consumedInitial = false
    @State private var playlistOpen = false
    @State private var busy = false
    @State private var notice: String?
    @FocusState private var editing: Bool
    private var terms: [String] { BatchSearchModel.terms(model.text) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(engine.text("Write songs separated by commas or one per line. You can include the artist.", "Escribe las canciones separadas por comas o una por línea. Puedes añadir el artista.", "Escreva as músicas separadas por vírgula ou uma por linha. Você pode incluir o artista."))
                    .font(.subheadline).foregroundColor(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.text).modifier(ClearTextEditorBackground()).frame(minHeight: 120).focused($editing).padding(4)
                    if model.text.isEmpty {
                        Text(engine.text("E.g. Bohemian Rhapsody, Hotel California", "Por ejemplo: Bohemian Rhapsody, Hotel California", "Ex.: Evidências, Trem-Bala"))
                            .foregroundColor(.secondary).padding(12).allowsHitTesting(false)
                    }
                }.background(Color(.secondarySystemBackground)).cornerRadius(16)
                HStack {
                    Text(terms.count == 50 ? engine.text("Up to 50 songs", "Hasta 50 canciones", "Até 50 músicas") : "\(terms.count) \(engine.text("songs", "canciones", "músicas"))")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button {
                        editing = false
                        model.run(using: engine)
                    } label: { Label(engine.text("Search", "Buscar", "Buscar"), systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).tint(engine.accent).foregroundColor(.black)
                        .disabled(terms.isEmpty || !engine.ready)
                }
                if model.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(engine.text("Many songs at once", "Varias canciones a la vez", "Várias músicas de uma vez")).font(.title2.bold())
                        Text(engine.text("Review the matches, choose alternatives and play or save the selection.", "Revisa los resultados, elige alternativas y reproduce o guarda la selección.", "Confira os resultados, escolha alternativas e toque ou salve a seleção.")).foregroundColor(.secondary)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).musikeGlass()
                } else {
                    selectionControls
                    LazyVStack(spacing: 8) {
                        ForEach(model.entries) { entry in BatchEntryRow(engine: engine, model: model, entry: entry) }
                    }
                }
            }.padding()
        }
        .navigationTitle(engine.text("Search a list", "Buscar una lista", "Buscar lista"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !consumedInitial, let initialText, !initialText.isEmpty {
                consumedInitial = true; model.text = initialText; model.run(using: engine)
            }
        }
        .sheet(isPresented: $playlistOpen) {
            BatchPlaylistPicker(engine: engine, tracks: model.selected) {
                notice = engine.text("Added to playlist.", "Añadido a la lista.", "Adicionado à playlist.")
            }
        }
        .alert(engine.text("Search a list", "Buscar una lista", "Buscar lista"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }
    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.selectAll(!model.allSelected) } label: {
                    Label(model.allSelected ? engine.text("Deselect all", "Deseleccionar todo", "Desmarcar todas") : engine.text("Select all", "Seleccionar todo", "Selecionar todas"), systemImage: model.allSelected ? "checkmark.square.fill" : "square")
                }.disabled(model.found.isEmpty)
                Spacer()
                if model.pending { ProgressView().controlSize(.small) }
                Text("\(model.selected.count) / \(model.entries.count)").font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button { engine.play(model.selected.isEmpty ? model.found : model.selected) } label: { Label(engine.text("Play", "Reproducir", "Tocar"), systemImage: "play.fill") }
                    .disabled(model.found.isEmpty)
                Button { addFavorites() } label: { Image(systemName: "heart") }
                    .accessibilityLabel(engine.text("Add to favorites", "Añadir a favoritos", "Adicionar às favoritas"))
                    .disabled(model.selected.isEmpty || busy)
                Button { playlistOpen = true } label: { Image(systemName: "text.badge.plus") }
                    .accessibilityLabel(engine.text("Add to playlist", "Añadir a una lista", "Adicionar à playlist"))
                    .disabled(model.selected.isEmpty || busy)
                Spacer()
            }.buttonStyle(.bordered)
        }
    }
    private func addFavorites() {
        busy = true
        engine.call("batchAddFavorites", ["tracks": engine.object(model.selected)]) { result in
            busy = false
            switch result {
            case .success: notice = engine.text("Added to favorites.", "Añadido a favoritos.", "Adicionado às favoritas.")
            case .failure(let error): notice = error.localizedDescription
            }
        }
    }
}

struct BatchEntryRow: View {
    @ObservedObject var engine: NativeEngine
    @ObservedObject var model: BatchSearchModel
    let entry: BatchSearchModel.Entry
    var body: some View {
        HStack(spacing: 10) {
            if entry.status == .loading {
                ProgressView().frame(width: 38, height: 52)
                Text(entry.query).foregroundColor(.secondary).lineLimit(2)
                Spacer()
            } else if let track = entry.track, entry.status == .ready {
                Button { model.toggle(entry.id) } label: { Image(systemName: entry.selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundColor(entry.selected ? engine.accent : .secondary) }
                    .accessibilityLabel(engine.text("Select", "Seleccionar", "Selecionar") + " " + track.title)
                Button { engine.track("playTrack", track) } label: { Artwork(url: track.thumb, size: 48) }.buttonStyle(.plain)
                Button { model.toggle(entry.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.subheadline.bold()).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        Text(entry.query).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                if entry.options.count > 1 {
                    Menu {
                        ForEach(Array(entry.options.enumerated()), id: \.offset) { index, option in
                            Button { model.choose(index, for: entry.id) } label: {
                                if index == entry.pick { Label("\(option.title) · \(option.artist)", systemImage: "checkmark") }
                                else { Text("\(option.title) · \(option.artist)") }
                            }
                        }
                    } label: { Image(systemName: "arrow.triangle.2.circlepath").frame(width: 40, height: 44) }
                        .accessibilityLabel(engine.text("Choose another result", "Elegir otro resultado", "Escolher outro resultado"))
                }
            } else {
                Image(systemName: "exclamationmark.circle").foregroundColor(.secondary).frame(width: 38, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.query).font(.subheadline.bold()).lineLimit(2)
                    Text(entry.status == .empty ? engine.text("Nothing found", "No se ha encontrado nada", "Nada encontrado") : engine.text("Search failed", "La búsqueda ha fallado", "A busca falhou"))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(engine.text("Retry", "Reintentar", "Tentar novamente")) { model.retry(entry.id) }.buttonStyle(.bordered)
            }
        }.padding(.vertical, 4)
    }
}

struct BatchPlaylistPicker: View {
    @ObservedObject var engine: NativeEngine
    let tracks: [Track]
    var didAdd: () -> Void
    @Environment(\.presentationMode) private var presentation
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(engine.text("New playlist", "Nueva lista", "Nova playlist"))) {
                    TextField(engine.text("Name", "Nombre", "Nome"), text: $name)
                    Button(engine.text("Create and add", "Crear y añadir", "Criar e adicionar")) {
                        perform("batchCreatePlaylist", ["name": name.trimmingCharacters(in: .whitespacesAndNewlines)])
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
                if !engine.library.playlists.isEmpty {
                    Section(header: Text(engine.text("Playlists", "Listas", "Playlists"))) {
                        ForEach(engine.library.playlists) { playlist in
                            Button(playlist.name) { perform("batchAddToPlaylist", ["id": playlist.id]) }.disabled(busy)
                        }
                    }
                }
                if busy { ProgressView() }
            }.navigationTitle(engine.text("Add to playlist", "Añadir a una lista", "Adicionar à playlist"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(engine.text("Cancel", "Cancelar", "Cancelar")) { presentation.wrappedValue.dismiss() } } }
                .alert(engine.text("Error", "Error", "Erro"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }.navigationViewStyle(.stack).tint(engine.accent).preferredColorScheme(engine.appearance.theme == "light" ? .light : .dark)
    }
    private func perform(_ action: String, _ args: [String: Any]) {
        busy = true
        var params = args; params["tracks"] = engine.object(tracks)
        engine.call(action, params) { result in
            busy = false
            switch result {
            case .success: presentation.wrappedValue.dismiss(); didAdd()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

struct TrackList: View {
    @ObservedObject var engine: NativeEngine
    let tracks: [Track]
    var playlistID: String? = nil
    @State private var playlistTrack: Track?
    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                HStack(spacing: 12) {
                    Button { engine.play(tracks, at: index) } label: {
                        HStack(spacing: 12) {
                            Artwork(url: track.thumb, size: 52)
                            VStack(alignment: .leading, spacing: 4) { Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1); Text(track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Menu {
                        Button { engine.track("favorite", track) } label: { Label(engine.library.favorites.contains(where: { $0.id == track.id }) ? engine.text("Remove favorite", "Quitar de favoritos", "Remover favorita") : engine.text("Add favorite", "Añadir a favoritos", "Adicionar às favoritas"), systemImage: "heart") }
                        Button { engine.track("playNext", track) } label: { Label(engine.text("Play next", "Reproducir a continuación", "Tocar a seguir"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                        Button { engine.track("addToQueue", track) } label: { Label(engine.text("Add to queue", "Añadir a la cola", "Adicionar à fila"), systemImage: "text.badge.plus") }
                        Button { playlistTrack = track } label: { Label(engine.text("Add to playlist", "Añadir a lista", "Adicionar à playlist"), systemImage: "text.badge.plus") }
                        Button {
                            engine.call("startRadio", ["track": engine.object(track)]) { result in
                                if case .failure(let failure) = result { engine.error = failure.localizedDescription }
                            }
                        } label: { Label(engine.text("Start radio", "Iniciar radio", "Iniciar rádio"), systemImage: "dot.radiowaves.left.and.right") }
                        if let url = URL(string: "https://www.youtube.com/watch?v=\(track.id)") {
                            Link(destination: url) { Label(engine.text("Open on YouTube", "Abrir en YouTube", "Abrir no YouTube"), systemImage: "arrow.up.right.square") }
                        }
                        if let playlistID { Button(role: .destructive) { engine.call("removeFromPlaylist", ["id": playlistID, "trackId": track.id]) } label: { Label(engine.text("Remove from playlist", "Quitar de la lista", "Remover da playlist"), systemImage: "trash") } }
                    } label: { Image(systemName: "ellipsis").frame(width: 40, height: 48).contentShape(Rectangle()) }.accessibilityLabel(engine.text("Track options", "Opciones de la canción", "Opções da música"))
                }.padding(.vertical, 5)
            }
        }.sheet(item: $playlistTrack) { track in BatchPlaylistPicker(engine: engine, tracks: [track], didAdd: {}) }
    }
}

struct LibraryScreen: View {
    @ObservedObject var engine: NativeEngine
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        ScrollView { VStack(spacing: 6) {
            NavigationLink { CollectionScreen(engine: engine, title: engine.text("Favorites", "Favoritos", "Favoritas"), tracks: engine.library.favorites) } label: { entry("heart.fill", engine.text("Favorites", "Favoritos", "Favoritas"), engine.library.favorites.count) }
            NavigationLink { CollectionScreen(engine: engine, title: engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente"), tracks: engine.library.history) } label: { entry("clock.arrow.circlepath", engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente"), engine.library.history.count) }
            ForEach(engine.library.playlists) { playlist in
                NavigationLink { PlaylistScreen(engine: engine, id: playlist.id) } label: { entry("music.note.list", playlist.name, playlist.tracks.count) }
            }
        }.buttonStyle(.plain).padding() }.navigationTitle(engine.text("Library", "Biblioteca", "Biblioteca"))
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel(engine.text("New playlist", "Nueva lista", "Nova playlist")) } }
        .sheet(isPresented: $creating) {
            PlaylistNameSheet(engine: engine, name: $name, title: engine.text("New playlist", "Nueva lista", "Nova playlist"), action: engine.text("Create", "Crear", "Criar")) { value in
                engine.call("createPlaylist", ["name": value]); name = ""
            }
        }
    }
    func entry(_ icon: String, _ title: String, _ count: Int) -> some View {
        HStack(spacing: 14) { Image(systemName: icon).font(.title2).foregroundColor(engine.accent).frame(width: 60, height: 60).musikeGlass(14)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text("\(count) \(engine.text("tracks", "canciones", "músicas"))").font(.caption).foregroundColor(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }.padding(.vertical, 5)
    }
}

struct PlaylistNameSheet: View {
    @ObservedObject var engine: NativeEngine
    @Binding var name: String
    let title: String
    let action: String
    var onSave: (String) -> Void
    @Environment(\.presentationMode) private var presentation
    var body: some View {
        NavigationView {
            Form { TextField(engine.text("Name", "Nombre", "Nome"), text: $name) }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button(engine.text("Cancel", "Cancelar", "Cancelar")) { presentation.wrappedValue.dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action) { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); onSave(value); presentation.wrappedValue.dismiss() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.navigationViewStyle(.stack).tint(engine.accent)
    }
}

struct CollectionScreen: View {
    @ObservedObject var engine: NativeEngine
    let title: String
    let tracks: [Track]
    var playlistID: String? = nil
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if !tracks.isEmpty {
                HStack {
                    Button { engine.play(tracks) } label: { Label(engine.text("Play", "Reproducir", "Tocar"), systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(engine.accent).foregroundColor(.black)
                    Button { engine.play(tracks.shuffled()) } label: { Image(systemName: "shuffle") }.buttonStyle(.bordered)
                        .accessibilityLabel(engine.text("Shuffle", "Reproducción aleatoria", "Aleatório"))
                }
            } else { Text(engine.text("No tracks yet.", "Todavía no hay canciones.", "Ainda não há músicas.")).foregroundColor(.secondary).padding(.top) }
            TrackList(engine: engine, tracks: tracks, playlistID: playlistID)
        }.padding() }.navigationTitle(title)
    }
}
struct PlaylistScreen: View {
    @ObservedObject var engine: NativeEngine
    let id: String
    @Environment(\.presentationMode) private var presentation
    @State private var deleting = false
    @State private var renaming = false
    @State private var name = ""
    var body: some View {
        Group { if let playlist = engine.library.playlists.first(where: { $0.id == id }) {
            CollectionScreen(engine: engine, title: playlist.name, tracks: playlist.tracks, playlistID: id)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Menu { Button(engine.text("Rename", "Renombrar", "Renomear")) { name = playlist.name; renaming = true }; Button(engine.text("Delete", "Eliminar", "Excluir"), role: .destructive) { deleting = true } } label: { Image(systemName: "ellipsis.circle") } } }
        } else { EmptyView() } }
        .sheet(isPresented: $renaming) {
            PlaylistNameSheet(engine: engine, name: $name, title: engine.text("Rename playlist", "Renombrar lista", "Renomear playlist"), action: engine.text("Save", "Guardar", "Salvar")) { value in
                engine.call("renamePlaylist", ["id": id, "name": value])
            }
        }
        .alert(engine.text("Delete playlist?", "¿Eliminar lista?", "Excluir playlist?"), isPresented: $deleting) { Button(engine.text("Delete", "Eliminar", "Excluir"), role: .destructive) { engine.call("deletePlaylist", ["id": id]); presentation.wrappedValue.dismiss() }; Button(engine.text("Cancel", "Cancelar", "Cancelar"), role: .cancel) {} }
    }
}

struct AlbumRow: View {
    let album: AlbumCard
    var body: some View { HStack(spacing: 12) { Artwork(url: album.thumb, size: 58); VStack(alignment: .leading, spacing: 4) { Text(album.title).font(.headline).lineLimit(1); Text([album.artist, album.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundColor(.secondary).lineLimit(1) }; Spacer() }.padding(.vertical, 4) }
}
struct GenreScreen: View {
    @ObservedObject var engine: NativeEngine
    let genre: Genre
    @State private var page: GenrePage?
    @State private var artists: [GenreArtist] = []
    @State private var hasMore = false
    @State private var loading = true
    @State private var loadingMore = false
    @State private var loadError: String?
    @State private var loadRevision = 0
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if loading { ProgressView().frame(maxWidth: .infinity).padding() }
            if let loadError {
                Text(loadError).font(.caption).foregroundColor(.secondary)
                Button(engine.text("Retry", "Reintentar", "Tentar novamente")) { if page == nil { load() } else { more() } }.buttonStyle(.bordered)
            }
            if let page {
                if !artists.isEmpty { Text(engine.text("Artists", "Artistas", "Artistas")).font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: false) { HStack(alignment: .top, spacing: 14) { ForEach(artists) { artist in NavigationLink { ArtistScreen(engine: engine, id: artist.id) } label: { VStack(alignment: .leading, spacing: 4) { Artwork(url: artist.art.isEmpty ? artist.thumb : artist.art, size: 112); Text(artist.name).font(.caption.bold()).lineLimit(2); Text(artist.hits.joined(separator: " · ")).font(.caption2).foregroundColor(.secondary).lineLimit(2) }.frame(width: 112, alignment: .leading) }.buttonStyle(.plain) } } }
                    if hasMore { Button(engine.text("Load more", "Cargar más", "Carregar mais")) { more() }.disabled(loadingMore) }
                }
                Text(engine.text("Songs", "Canciones", "Músicas")).font(.title2.bold())
                if page.tracks.isEmpty { Text(engine.text("No tracks found.", "No hay canciones.", "Nenhuma música encontrada.")).foregroundColor(.secondary) }
                else { SelectableTracks(engine: engine, tracks: page.tracks) }
            }
        }.padding() }.navigationTitle(page?.name ?? genre.name).onAppear { if page == nil { load() } }
        .onChange(of: engine.language) { _ in page = nil; artists = []; hasMore = false; load() }
    }
    func load() {
        loadRevision += 1; let revision = loadRevision
        loading = true; loadingMore = false; loadError = nil
        engine.request("genre", ["id": genre.id]) { (result: Result<GenrePage, Error>) in
            guard revision == loadRevision else { return }
            loading = false
            switch result { case .success(let value): page = value; artists = value.artists; hasMore = value.hasMoreArtists; case .failure(let failure): loadError = failure.localizedDescription }
        }
    }
    func more() {
        guard !loadingMore else { return }
        loadingMore = true; loadError = nil
        let revision = loadRevision
        engine.request("genreArtists", ["id": genre.id, "offset": artists.count]) { (result: Result<MoreArtists, Error>) in
            guard revision == loadRevision else { return }
            loadingMore = false
            switch result {
            case .success(let value):
                var known = Set(artists.map(\.id))
                artists.append(contentsOf: value.artists.filter { known.insert($0.id).inserted }); hasMore = value.hasMore
            case .failure(let failure): loadError = failure.localizedDescription
            }
        }
    }
}
struct ArtistScreen: View {
    @ObservedObject var engine: NativeEngine
    let id: String
    @State private var page: ArtistPage?
    @State private var loadError: String?
    @State private var loadRevision = 0
    @State private var fullBio = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if let page {
                if !page.description.isEmpty {
                    Text(page.description).font(.subheadline).foregroundColor(.secondary).lineLimit(fullBio ? nil : 5)
                    Button(fullBio ? engine.text("Show less", "Mostrar menos", "Mostrar menos") : engine.text("Read more", "Leer más", "Ler mais")) { fullBio.toggle() }.font(.caption)
                }
                Text(engine.text("Songs", "Canciones", "Músicas")).font(.title2.bold())
                if page.tracks.isEmpty { Text(engine.text("No tracks found.", "No hay canciones.", "Nenhuma música encontrada.")).foregroundColor(.secondary) }
                else { SelectableTracks(engine: engine, tracks: page.tracks) }
                if !page.albums.isEmpty { Text(engine.text("Albums", "Álbumes", "Álbuns")).font(.title2.bold()); ForEach(page.albums) { album in NavigationLink { AlbumScreen(engine: engine, id: album.id) } label: { AlbumRow(album: album) }.buttonStyle(.plain) } }
                if !page.singles.isEmpty { Text("Singles").font(.title2.bold()); ForEach(page.singles) { album in NavigationLink { AlbumScreen(engine: engine, id: album.id) } label: { AlbumRow(album: album) }.buttonStyle(.plain) } }
            } else if let loadError {
                Text(loadError).foregroundColor(.secondary)
                Button(engine.text("Retry", "Reintentar", "Tentar novamente")) { load() }.buttonStyle(.bordered)
            } else { ProgressView().frame(maxWidth: .infinity).padding() }
        }.padding() }.navigationTitle(page?.name ?? "").onAppear { if page == nil { load() } }
        .onChange(of: engine.language) { _ in page = nil; load() }
    }
    private func load() {
        loadRevision += 1; let revision = loadRevision
        loadError = nil
        engine.request("artist", ["id": id]) { (result: Result<ArtistPage, Error>) in
            guard revision == loadRevision else { return }
            switch result { case .success(let value): page = value; case .failure(let failure): loadError = failure.localizedDescription }
        }
    }
}
struct AlbumScreen: View {
    @ObservedObject var engine: NativeEngine
    let id: String
    @State private var page: AlbumPage?
    @State private var loadError: String?
    @State private var loadRevision = 0
    @State private var saving = false
    @State private var savedPlaylist: String?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if let page {
                HStack { Spacer(); Artwork(url: page.art.isEmpty ? page.thumb : page.art, size: 210); Spacer() }.padding(.vertical)
                Text(page.title).font(.title.bold())
                if let artistId = page.artistId, !page.artist.isEmpty {
                    NavigationLink(page.artist) { ArtistScreen(engine: engine, id: artistId) }.font(.headline)
                } else { Text(page.artist).font(.headline) }
                Text([page.kind, page.info].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundColor(.secondary)
                if !page.tracks.isEmpty {
                    HStack {
                        Button { engine.play(page.tracks) } label: { Label(engine.text("Play", "Reproducir", "Tocar"), systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(engine.accent).foregroundColor(.black)
                        Button { engine.play(page.tracks.shuffled()) } label: { Image(systemName: "shuffle") }.buttonStyle(.bordered)
                            .accessibilityLabel(engine.text("Shuffle album", "Reproducir álbum aleatoriamente", "Tocar álbum aleatoriamente"))
                        if let savedPlaylist {
                            NavigationLink { PlaylistScreen(engine: engine, id: savedPlaylist) } label: { Image(systemName: "checkmark") }.buttonStyle(.bordered)
                                .accessibilityLabel(engine.text("Open saved playlist", "Abrir lista guardada", "Abrir playlist salva"))
                        } else {
                            Button { save(page) } label: { Image(systemName: "text.badge.plus") }.buttonStyle(.bordered).disabled(saving)
                                .accessibilityLabel(engine.text("Save as playlist", "Guardar como lista", "Salvar como playlist"))
                        }
                    }
                    SelectableTracks(engine: engine, tracks: page.tracks)
                } else { Text(engine.text("No tracks found.", "No hay canciones.", "Nenhuma música encontrada.")).foregroundColor(.secondary) }
            } else if let loadError {
                Text(loadError).foregroundColor(.secondary)
                Button(engine.text("Retry", "Reintentar", "Tentar novamente")) { load() }.buttonStyle(.bordered)
            } else { ProgressView().frame(maxWidth: .infinity).padding() }
        }.padding() }.navigationTitle(page?.title ?? "").navigationBarTitleDisplayMode(.inline)
        .onAppear { if page == nil { load() } }
        .onChange(of: engine.language) { _ in page = nil; load() }
    }
    private func load() {
        loadRevision += 1; let revision = loadRevision
        loadError = nil
        engine.request("album", ["id": id]) { (result: Result<AlbumPage, Error>) in
            guard revision == loadRevision else { return }
            switch result { case .success(let value): page = value; case .failure(let failure): loadError = failure.localizedDescription }
        }
    }
    private func save(_ album: AlbumPage) {
        saving = true
        let name = album.artist.isEmpty ? album.title : "\(album.title) · \(album.artist)"
        engine.request("batchCreatePlaylist", ["name": name, "tracks": engine.object(album.tracks)]) { (result: Result<Playlist, Error>) in
            saving = false
            switch result { case .success(let playlist): savedPlaylist = playlist.id; case .failure(let failure): engine.error = failure.localizedDescription }
        }
    }
}

struct SelectableTracks: View {
    @ObservedObject var engine: NativeEngine
    let tracks: [Track]
    @State private var selected = Set<String>()
    @State private var playlistOpen = false
    @State private var busy = false
    @State private var notice: String?
    private var chosen: [Track] { tracks.filter { selected.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if selected.count == Set(tracks.map(\.id)).count { selected.removeAll() }
                    else { selected = Set(tracks.map(\.id)) }
                } label: { Label(engine.text("Select all", "Seleccionar todo", "Selecionar todas"), systemImage: "checkmark.circle") }
                Spacer()
                Text("\(chosen.count) / \(tracks.count)").font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button { engine.play(chosen.isEmpty ? tracks : chosen) } label: { Label(engine.text("Play", "Reproducir", "Tocar"), systemImage: "play.fill") }
                Button { addFavorites() } label: { Image(systemName: "heart") }.disabled(chosen.isEmpty || busy)
                    .accessibilityLabel(engine.text("Add to favorites", "Añadir a favoritos", "Adicionar às favoritas"))
                Button { playlistOpen = true } label: { Image(systemName: "text.badge.plus") }.disabled(chosen.isEmpty || busy)
                    .accessibilityLabel(engine.text("Add to playlist", "Añadir a una lista", "Adicionar à playlist"))
            }.buttonStyle(.bordered)
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                HStack(spacing: 10) {
                    Button { if !selected.insert(track.id).inserted { selected.remove(track.id) } } label: {
                        Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle").foregroundColor(selected.contains(track.id) ? engine.accent : .secondary)
                    }.accessibilityLabel(engine.text("Select", "Seleccionar", "Selecionar") + " " + track.title)
                    Button { engine.play(tracks, at: index) } label: { Artwork(url: track.thumb, size: 48) }.buttonStyle(.plain)
                    Button { if !selected.insert(track.id).inserted { selected.remove(track.id) } } label: {
                        VStack(alignment: .leading, spacing: 3) { Text(track.title).font(.subheadline.bold()).lineLimit(1); Text(track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }.padding(.vertical, 4)
            }
        }
        .sheet(isPresented: $playlistOpen) { BatchPlaylistPicker(engine: engine, tracks: chosen) { notice = engine.text("Added to playlist.", "Añadido a la lista.", "Adicionado à playlist.") } }
        .alert(engine.text("Selection", "Selección", "Seleção"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK", role: .cancel) { notice = nil } } message: { Text(notice ?? "") }
    }
    private func addFavorites() {
        busy = true
        engine.call("batchAddFavorites", ["tracks": engine.object(chosen)]) { result in
            busy = false
            switch result { case .success: notice = engine.text("Added to favorites.", "Añadido a favoritos.", "Adicionado às favoritas."); case .failure(let failure): notice = failure.localizedDescription }
        }
    }
}

struct PlayerScreen: View {
    @ObservedObject var engine: NativeEngine
    @ObservedObject private var diagnostics = PlaybackDiagnostics.shared
    @Environment(\.presentationMode) private var presentation
    @State private var queueOpen = false
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @State private var volumePreview: Double?
    @State private var adjustingVolume = false
    @State private var volumeRevision = 0
    @State private var slowLoading = false
    @State private var loadingRevision = 0
    var body: some View {
        NavigationView { GeometryReader { geometry in
            ScrollView { VStack(spacing: 22) {
                if let track = engine.player.current {
                    Artwork(url: track.art.isEmpty ? track.thumb : track.art, size: min(geometry.size.width - 64, 360)).shadow(radius: 25).padding(.top, 10)
                    HStack { VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.title2.bold()).lineLimit(2); Text(track.artist).foregroundColor(.secondary).lineLimit(1) }; Spacer(); Button { engine.track("favorite", track) } label: { Image(systemName: engine.library.favorites.contains(where: { $0.id == track.id }) ? "heart.fill" : "heart").font(.title2) }.foregroundColor(engine.accent) }
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { seeking ? seekValue : min(engine.player.position, max(engine.player.duration, 1)) }, set: { seekValue = $0 }), in: 0...max(engine.player.duration, 1), onEditingChanged: { editing in seeking = editing; if !editing { engine.call("seek", ["position": seekValue]) } })
                        HStack { Text(time(seeking ? seekValue : engine.player.position)); Spacer(); Text(time(engine.player.duration)) }.font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    HStack(spacing: 0) {
                        Button { engine.call("shuffle") } label: { Image(systemName: "shuffle").foregroundColor(engine.player.shuffle ? engine.accent : .secondary).frame(maxWidth: .infinity) }
                        Button { engine.call("previous") } label: { Image(systemName: "backward.end.fill").font(.title).frame(maxWidth: .infinity) }
                        Button { engine.call("toggle") } label: { Image(systemName: engine.player.status == "playing" ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .bold)).frame(width: 76, height: 76).musikeGlass(38) }
                        Button { engine.call("next") } label: { Image(systemName: "forward.end.fill").font(.title).frame(maxWidth: .infinity) }
                        Button { engine.call("repeat") } label: { Image(systemName: engine.player.repeat == "one" ? "repeat.1" : "repeat").foregroundColor(engine.player.repeat == "off" ? .secondary : engine.accent).frame(maxWidth: .infinity) }
                    }.buttonStyle(.plain)
                    if engine.player.status == "loading" {
                        ProgressView(engine.text("Loading…", "Cargando…", "Carregando…"))
                        if diagnostics.networkUnavailable {
                            Text(engine.text("No network connection. Check your Wi-Fi or mobile data.", "Sin conexión de red. Comprueba el Wi-Fi o los datos móviles.", "Sem conexão de rede. Verifique o Wi-Fi ou os dados móveis."))
                                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                        } else if slowLoading {
                            Text(engine.text("Loading is taking longer than expected. Check your connection or try another network.", "La carga está tardando más de lo esperado. Comprueba la conexión o prueba otra red.", "O carregamento está demorando mais que o esperado. Verifique a conexão ou tente outra rede."))
                                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    if engine.player.status == "error" {
                        Text(diagnostics.networkUnavailable
                             ? engine.text("No network connection. Check your Wi-Fi or mobile data.", "Sin conexión de red. Comprueba el Wi-Fi o los datos móviles.", "Sem conexão de rede. Verifique o Wi-Fi ou os dados móveis.")
                             : (engine.player.errorText ?? engine.text("Playback failed. Check your connection or try again.", "No se pudo reproducir. Comprueba la conexión o inténtalo de nuevo.", "Não foi possível reproduzir. Verifique a conexão ou tente novamente.")))
                            .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button(engine.text("Retry", "Reintentar", "Tentar novamente")) { engine.call("toggle") }
                    }
                    HStack(spacing: 14) {
                        Button {
                            volumeRevision += 1
                            volumePreview = nil
                            engine.call("mute")
                        } label: { Image(systemName: engine.player.muted ? "speaker.slash.fill" : "speaker.fill") }
                            .accessibilityLabel(engine.player.muted ? engine.text("Unmute", "Activar sonido", "Ativar som") : engine.text("Mute", "Silenciar", "Silenciar"))
                        Slider(value: Binding(get: { volumePreview ?? currentVolume }, set: setVolume), in: 0...1, onEditingChanged: { editing in
                            adjustingVolume = editing
                            if editing {
                                volumeRevision += 1
                                if volumePreview == nil { volumePreview = currentVolume }
                            } else if let value = volumePreview {
                                volumeRevision += 1
                                commitVolume(value, revision: volumeRevision)
                            }
                        })
                            .accessibilityLabel(engine.text("Volume", "Volumen", "Volume"))
                        Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button {
                            engine.call("startRadio", ["track": engine.object(track)]) { result in
                                if case .failure(let error) = result { engine.error = error.localizedDescription }
                            }
                        } label: { Label(engine.text("Start radio", "Iniciar radio", "Iniciar rádio"), systemImage: "dot.radiowaves.left.and.right") }
                        Button { queueOpen = true } label: { Label(engine.text("Queue", "Cola", "Fila"), systemImage: "list.bullet") }
                    }.buttonStyle(.bordered)
                    if engine.player.queue.indices.contains(engine.player.index + 1) {
                        let next = engine.player.queue[engine.player.index + 1]
                        HStack(spacing: 12) {
                            Artwork(url: next.thumb, size: 45)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(engine.text("Up next", "A continuación", "A seguir")).font(.caption).foregroundColor(.secondary)
                                Text(next.title).font(.subheadline.bold()).lineLimit(1)
                                Text(next.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }; Spacer()
                        }.padding(12).musikeGlass(16)
                    }
                }
            }.padding(.horizontal, 28).frame(maxWidth: .infinity) }
        }.navigationTitle(engine.text("Now playing", "En reproducción", "Tocando agora")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button { presentation.wrappedValue.dismiss() } label: { Image(systemName: "chevron.down") } } }
        .sheet(isPresented: $queueOpen) { QueueScreen(engine: engine) }
        .onAppear { updateLoadingNotice(engine.player.status) }
        .onChange(of: engine.player.status) { updateLoadingNotice($0) }
        .alert(engine.text("Error", "Error", "Erro"), isPresented: Binding(get: { engine.error != nil }, set: { if !$0 { engine.error = nil } })) {
            Button("OK", role: .cancel) { engine.error = nil }
        } message: { Text(engine.error ?? "") }
        }.navigationViewStyle(.stack).tint(engine.accent).preferredColorScheme(engine.appearance.theme == "light" ? .light : .dark)
    }
    private func updateLoadingNotice(_ status: String) {
        loadingRevision += 1
        let revision = loadingRevision
        slowLoading = false
        guard status == "loading" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if revision == loadingRevision && engine.player.status == "loading" { slowLoading = true }
        }
    }

    private var currentVolume: Double { engine.player.muted ? 0 : engine.player.volume }

    private func setVolume(_ value: Double) {
        volumePreview = value
        volumeRevision += 1
        if adjustingVolume {
            engine.call("volume", ["value": value])
        } else {
            // Accessibility adjustments can change the value without starting a drag.
            commitVolume(value, revision: volumeRevision)
        }
    }

    private func commitVolume(_ value: Double, revision: Int) {
        engine.call("volume", ["value": value]) { result in
            guard revision == volumeRevision, !adjustingVolume else { return }
            if case .failure(let error) = result {
                volumePreview = nil
                engine.error = error.localizedDescription
                return
            }
            // Wait for a fresh player snapshot before handing the slider back to the shared state.
            engine.call("state") { result in
                guard revision == volumeRevision, !adjustingVolume else { return }
                volumePreview = nil
                if case .failure(let error) = result { engine.error = error.localizedDescription }
            }
        }
    }

    func time(_ value: Double) -> String { guard value.isFinite && value >= 0 else { return "0:00" }; let seconds = Int(value); return String(format: "%d:%02d", seconds / 60, seconds % 60) }
}
struct QueueScreen: View {
    @ObservedObject var engine: NativeEngine
    @Environment(\.presentationMode) private var presentation
    var body: some View {
        NavigationView { List {
            Toggle(engine.text("Autoplay radio", "Radio automática", "Rádio automática"), isOn: Binding(get: { engine.player.autoRadio }, set: { engine.call("autoRadio", ["enabled": $0]) }))
            ForEach(Array(engine.player.queue.enumerated()), id: \.offset) { index, track in
                HStack { Button { engine.call("jumpTo", ["index": index]) } label: { HStack { Artwork(url: track.thumb, size: 45); VStack(alignment: .leading) { Text(track.title).lineLimit(1); Text(track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1) }; Spacer(); if index == engine.player.index { Image(systemName: "waveform").foregroundColor(engine.accent) } } }.buttonStyle(.plain)
                    Button(role: .destructive) { engine.call("removeAt", ["index": index]) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
        }.navigationTitle(engine.text("Queue", "Cola", "Fila"))
        .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(engine.text("Done", "Listo", "Concluído")) { presentation.wrappedValue.dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { Button(engine.text("Clear", "Vaciar", "Limpar")) { engine.call("clearUpcoming") } } }
        }.navigationViewStyle(.stack).tint(engine.accent)
    }
}

/// Hosts the bundled catalog, library and player engine behind the native interface.
final class MusikeRootController: UIViewController {
    private let runtime = MusikeWebViewController()
    private var host: UIHostingController<NativeRoot>!
    private var appearanceObserver: AnyCancellable?
    override func viewDidLoad() {
        super.viewDidLoad()
        PlaybackDiagnostics.shared.sessionStarted()
        addChild(runtime); runtime.view.frame = view.bounds; runtime.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(runtime.view); runtime.didMove(toParent: self)
        host = UIHostingController(rootView: NativeRoot(engine: runtime.nativeEngine))
        addChild(host); host.view.frame = view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(host.view); host.didMove(toParent: self)
        appearanceObserver = runtime.nativeEngine.$appearance.map(\.theme).removeDuplicates().sink { [weak self] theme in
            self?.host.overrideUserInterfaceStyle = theme == "light" ? .light : .dark
        }
    }
}
