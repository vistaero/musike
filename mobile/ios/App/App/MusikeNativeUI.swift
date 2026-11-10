import SwiftUI
import WebKit

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
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
}
struct Appearance: Decodable { var accent: String = "#c3ec52"; var theme: String = "dark" }
struct Snapshot: Decodable { var player: PlayerState; var library: LibraryState; var appearance: Appearance; var lang: String }
struct Genre: Decodable, Identifiable { let id: String; let name: String }
struct AlbumCard: Decodable, Identifiable { let id: String; let title: String; let artist: String; let art: String; let thumb: String; let year: String }
struct GenreArtist: Decodable, Identifiable { let id: String; let name: String; let art: String; let thumb: String }
struct GenrePage: Decodable { let name: String; let artists: [GenreArtist]; let hasMoreArtists: Bool; let tracks: [Track] }
struct MoreArtists: Decodable { let artists: [GenreArtist]; let hasMore: Bool }
struct ArtistPage: Decodable { let name: String; let description: String; let tracks: [Track]; let albums: [AlbumCard]; let singles: [AlbumCard] }
struct AlbumPage: Decodable { let title: String; let artist: String; let art: String; let thumb: String; let info: String; let tracks: [Track] }

final class NativeEngine: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var player = PlayerState()
    @Published var library = LibraryState()
    @Published var appearance = Appearance()
    @Published var language = "en"
    @Published var ready = false
    @Published var error: String?
    weak var webView: WKWebView?
    var showClassic: (() -> Void)?
    private var nextID = 0
    private var callbacks: [Int: (Result<Any, Error>) -> Void] = [:]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { ready = true; return }
        if type == "state", let data = try? JSONSerialization.data(withJSONObject: body),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            player = snapshot.player; library = snapshot.library; appearance = snapshot.appearance; language = snapshot.lang
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
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "action": action, "args": args]), let json = String(data: data, encoding: .utf8) else { callbacks.removeValue(forKey: id); return }
        webView.evaluateJavaScript("void window.musikeNative.dispatch(\(json))") { [weak self] _, error in
            if let error { self?.callbacks.removeValue(forKey: id)?(.failure(error)) }
        }
    }
    func request<T: Decodable>(_ action: String, _ args: [String: Any] = [:], completion: @escaping (Result<T, Error>) -> Void) {
        call(action, args) { result in
            completion(result.flatMap { value in Result { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) } })
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
    var body: some View {
        TabView(selection: $tab) {
            NavigationView { HomeScreen(engine: engine, tab: $tab) }.navigationViewStyle(.stack)
                .tabItem { Label(engine.text("Home", "Inicio", "Início"), systemImage: "house.fill") }.tag(0)
            NavigationView { SearchScreen(engine: engine) }.navigationViewStyle(.stack)
                .tabItem { Label(engine.text("Search", "Buscar", "Buscar"), systemImage: "magnifyingglass") }.tag(1)
            NavigationView { LibraryScreen(engine: engine) }.navigationViewStyle(.stack)
                .tabItem { Label(engine.text("Library", "Biblioteca", "Biblioteca"), systemImage: "square.stack.fill") }.tag(2)
        }
        .tint(engine.accent)
        .preferredColorScheme(engine.appearance.theme == "light" ? .light : .dark)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let track = engine.player.current {
                MiniPlayer(engine: engine, track: track, open: { playerOpen = true }).padding(.horizontal, 10).padding(.bottom, 5)
            }
        }
        .sheet(isPresented: $playerOpen) { PlayerScreen(engine: engine) }
        .alert(engine.text("Error", "Error", "Erro"), isPresented: Binding(get: { engine.error != nil }, set: { if !$0 { engine.error = nil } })) {
            Button("OK", role: .cancel) { engine.error = nil }
        } message: { Text(engine.error ?? "") }
    }
}

struct MiniPlayer: View {
    @ObservedObject var engine: NativeEngine
    let track: Track
    var open: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.thumb, size: 48)
            VStack(alignment: .leading, spacing: 3) { Text(track.title).font(.subheadline.bold()).lineLimit(1); Text(track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
            Button { engine.call("toggle") } label: { Image(systemName: engine.player.status == "playing" ? "pause.fill" : "play.fill").font(.title3).frame(width: 42, height: 48) }.accessibilityLabel(engine.player.status == "playing" ? "Pause" : "Play")
            Button { engine.call("next") } label: { Image(systemName: "forward.end.fill").frame(width: 38, height: 48) }.accessibilityLabel("Next")
        }.padding(8).contentShape(Rectangle()).onTapGesture(perform: open).musikeGlass(20)
    }
}

struct HomeScreen: View {
    @ObservedObject var engine: NativeEngine
    @Binding var tab: Int
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(engine.text("Your music, uninterrupted.", "Tu música, sin interrupciones.", "Sua música, sem interrupções.")).font(.subheadline).foregroundColor(.secondary)
                HStack {
                    NavigationLink { CollectionScreen(engine: engine, title: engine.text("Favorites", "Favoritos", "Favoritas"), tracks: engine.library.favorites) } label: { shortcut("heart.fill", engine.text("Favorites", "Favoritos", "Favoritas")) }
                    NavigationLink { CollectionScreen(engine: engine, title: engine.text("Recently played", "Escuchado recientemente", "Ouvidas recentemente"), tracks: engine.library.history) } label: { shortcut("clock.arrow.circlepath", engine.text("Recent", "Recientes", "Recentes")) }
                }.buttonStyle(.plain)
                if !engine.ready || engine.library.status == "loading" { ProgressView().frame(maxWidth: .infinity).padding() }
                else if engine.library.history.isEmpty && engine.library.favorites.isEmpty && engine.library.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(engine.text("Find your next favorite", "Encuentra tu próxima favorita", "Encontre sua próxima favorita")).font(.title2.bold())
                        Text(engine.text("Search for music to start listening.", "Busca música para empezar a escuchar.", "Busque músicas para começar a ouvir.")).foregroundColor(.secondary)
                        Button(engine.text("Search music", "Buscar música", "Buscar música")) { tab = 1 }.buttonStyle(.borderedProminent).tint(engine.accent).foregroundColor(.black)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).musikeGlass()
                }
                if !engine.library.history.isEmpty {
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
                if !engine.library.favorites.isEmpty {
                    Text(engine.text("Your favorites", "Tus favoritos", "Suas favoritas")).font(.title2.bold())
                    TrackList(engine: engine, tracks: Array(engine.library.favorites.prefix(5)))
                }
            }.padding()
        }.navigationTitle("Musike").toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { engine.showClassic?() } label: { Image(systemName: "gearshape") }.accessibilityLabel(engine.text("Settings and more", "Ajustes y más", "Ajustes e mais")) } }
    }
    func shortcut(_ icon: String, _ title: String) -> some View {
        HStack { Image(systemName: icon).foregroundColor(engine.accent); Text(title).font(.subheadline.bold()).lineLimit(1); Spacer(minLength: 0) }.padding().frame(maxWidth: .infinity, minHeight: 65).musikeGlass(16)
    }
}

struct SearchScreen: View {
    @ObservedObject var engine: NativeEngine
    @State private var query = ""
    @State private var kind = "song"
    @State private var tracks: [Track] = []
    @State private var albums: [AlbumCard] = []
    @State private var genres: [Genre] = []
    @State private var loading = false
    @State private var requestID = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Type", selection: $kind) {
                    Text(engine.text("Songs", "Canciones", "Músicas")).tag("song")
                    Text(engine.text("Videos", "Vídeos", "Vídeos")).tag("video")
                    Text(engine.text("Albums", "Álbumes", "Álbuns")).tag("album")
                }.pickerStyle(.segmented)
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(engine.text("Explore genres", "Explorar géneros", "Explorar gêneros")).font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                        ForEach(genres) { genre in NavigationLink { GenreScreen(engine: engine, genre: genre) } label: {
                            Text(genre.name).font(.headline).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading).padding(.horizontal).musikeGlass(16)
                        }.buttonStyle(.plain) }
                    }
                } else if kind == "album" {
                    ForEach(albums) { album in NavigationLink { AlbumScreen(engine: engine, id: album.id) } label: { AlbumRow(album: album) }.buttonStyle(.plain) }
                } else { TrackList(engine: engine, tracks: tracks) }
            }.padding()
        }.navigationTitle(engine.text("Search", "Buscar", "Buscar"))
        .searchable(text: $query, prompt: Text(engine.text("Artists, songs, albums", "Artistas, canciones, álbumes", "Artistas, músicas, álbuns")))
        .onChange(of: query) { _ in search() }.onChange(of: kind) { _ in search() }
        .onAppear { if genres.isEmpty && engine.ready { loadGenres() } }
        .onChange(of: engine.ready) { ready in if ready { loadGenres() } }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { engine.showClassic?() } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel(engine.text("More search options", "Más opciones de búsqueda", "Mais opções de busca")) } }
    }
    func loadGenres() { engine.request("genres") { (result: Result<[Genre], Error>) in if case .success(let value) = result { genres = value } } }
    func search() {
        requestID += 1; let current = requestID
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { tracks = []; albums = []; loading = false; return }
        loading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard current == requestID else { return }
            if kind == "album" {
                engine.request("search", ["query": term, "kind": kind]) { (result: Result<[AlbumCard], Error>) in
                    guard current == requestID else { return }; loading = false
                    switch result { case .success(let items): albums = items; case .failure(let error): engine.error = error.localizedDescription }
                }
            } else {
                engine.request("search", ["query": term, "kind": kind]) { (result: Result<[Track], Error>) in
                    guard current == requestID else { return }; loading = false
                    switch result { case .success(let items): tracks = items; case .failure(let error): engine.error = error.localizedDescription }
                }
            }
        }
    }
}

struct TrackList: View {
    @ObservedObject var engine: NativeEngine
    let tracks: [Track]
    var playlistID: String? = nil
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
                        if !engine.library.playlists.isEmpty { Menu(engine.text("Add to playlist", "Añadir a lista", "Adicionar à playlist")) { ForEach(engine.library.playlists) { playlist in Button(playlist.name) { engine.track("addToPlaylist", track, extra: ["id": playlist.id]) } } } }
                        if let playlistID { Button(role: .destructive) { engine.call("removeFromPlaylist", ["id": playlistID, "trackId": track.id]) } label: { Label(engine.text("Remove from playlist", "Quitar de la lista", "Remover da playlist"), systemImage: "trash") } }
                    } label: { Image(systemName: "ellipsis").frame(width: 40, height: 48).contentShape(Rectangle()) }.accessibilityLabel(engine.text("Track options", "Opciones de la canción", "Opções da música"))
                }.padding(.vertical, 5)
            }
        }
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
        .alert(engine.text("New playlist", "Nueva lista", "Nova playlist"), isPresented: $creating) {
            TextField(engine.text("Name", "Nombre", "Nome"), text: $name)
            Button(engine.text("Create", "Crear", "Criar")) { let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines); if !trimmed.isEmpty { engine.call("createPlaylist", ["name": trimmed]) }; name = "" }
            Button(engine.text("Cancel", "Cancelar", "Cancelar"), role: .cancel) { name = "" }
        }
    }
    func entry(_ icon: String, _ title: String, _ count: Int) -> some View {
        HStack(spacing: 14) { Image(systemName: icon).font(.title2).foregroundColor(engine.accent).frame(width: 60, height: 60).musikeGlass(14)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text("\(count) \(engine.text("tracks", "canciones", "músicas"))").font(.caption).foregroundColor(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }.padding(.vertical, 5)
    }
}

struct CollectionScreen: View {
    @ObservedObject var engine: NativeEngine
    let title: String
    let tracks: [Track]
    var playlistID: String? = nil
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if !tracks.isEmpty { Button { engine.play(tracks) } label: { Label(engine.text("Play", "Reproducir", "Tocar"), systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(engine.accent).foregroundColor(.black) }
            else { Text(engine.text("No tracks yet.", "Todavía no hay canciones.", "Ainda não há músicas.")).foregroundColor(.secondary).padding(.top) }
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
        .alert(engine.text("Rename playlist", "Renombrar lista", "Renomear playlist"), isPresented: $renaming) { TextField(engine.text("Name", "Nombre", "Nome"), text: $name); Button(engine.text("Save", "Guardar", "Salvar")) { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engine.call("renamePlaylist", ["id": id, "name": name]) } }; Button(engine.text("Cancel", "Cancelar", "Cancelar"), role: .cancel) {} }
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
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if loading { ProgressView().frame(maxWidth: .infinity).padding() }
            if let page {
                if !artists.isEmpty { Text(engine.text("Artists", "Artistas", "Artistas")).font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: false) { HStack(alignment: .top, spacing: 14) { ForEach(artists) { artist in NavigationLink { ArtistScreen(engine: engine, id: artist.id) } label: { VStack { Artwork(url: artist.thumb, size: 112); Text(artist.name).font(.caption.bold()).lineLimit(2).frame(width: 112) } }.buttonStyle(.plain) } } }
                    if hasMore { Button(engine.text("Load more", "Cargar más", "Carregar mais")) { more() } }
                }
                Text(engine.text("Songs", "Canciones", "Músicas")).font(.title2.bold()); TrackList(engine: engine, tracks: page.tracks)
            }
        }.padding() }.navigationTitle(genre.name).onAppear { if page == nil { load() } }
    }
    func load() { engine.request("genre", ["id": genre.id]) { (result: Result<GenrePage, Error>) in loading = false; switch result { case .success(let value): page = value; artists = value.artists; hasMore = value.hasMoreArtists; case .failure(let error): engine.error = error.localizedDescription } } }
    func more() { engine.request("genreArtists", ["id": genre.id, "offset": artists.count]) { (result: Result<MoreArtists, Error>) in switch result { case .success(let value): artists.append(contentsOf: value.artists); hasMore = value.hasMore; case .failure(let error): engine.error = error.localizedDescription } } }
}
struct ArtistScreen: View {
    @ObservedObject var engine: NativeEngine
    let id: String
    @State private var page: ArtistPage?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if let page {
                if !page.description.isEmpty { Text(page.description).font(.subheadline).foregroundColor(.secondary).lineLimit(5) }
                Text(engine.text("Songs", "Canciones", "Músicas")).font(.title2.bold()); TrackList(engine: engine, tracks: page.tracks)
                if !page.albums.isEmpty { Text(engine.text("Albums", "Álbumes", "Álbuns")).font(.title2.bold()); ForEach(page.albums) { album in NavigationLink { AlbumScreen(engine: engine, id: album.id) } label: { AlbumRow(album: album) }.buttonStyle(.plain) } }
                if !page.singles.isEmpty { Text("Singles").font(.title2.bold()); ForEach(page.singles) { album in NavigationLink { AlbumScreen(engine: engine, id: album.id) } label: { AlbumRow(album: album) }.buttonStyle(.plain) } }
            } else { ProgressView().frame(maxWidth: .infinity).padding() }
        }.padding() }.navigationTitle(page?.name ?? "").onAppear { if page == nil { engine.request("artist", ["id": id]) { (result: Result<ArtistPage, Error>) in switch result { case .success(let value): page = value; case .failure(let error): engine.error = error.localizedDescription } } } }
    }
}
struct AlbumScreen: View {
    @ObservedObject var engine: NativeEngine
    let id: String
    @State private var page: AlbumPage?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            if let page {
                HStack { Spacer(); Artwork(url: page.art.isEmpty ? page.thumb : page.art, size: 210); Spacer() }.padding(.vertical)
                Text(page.title).font(.title.bold()); Text(page.artist + " · " + page.info).foregroundColor(.secondary)
                Button { engine.play(page.tracks) } label: { Label(engine.text("Play", "Reproducir", "Tocar"), systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(engine.accent).foregroundColor(.black)
                TrackList(engine: engine, tracks: page.tracks)
            } else { ProgressView().frame(maxWidth: .infinity).padding() }
        }.padding() }.navigationTitle(page?.title ?? "").navigationBarTitleDisplayMode(.inline)
        .onAppear { if page == nil { engine.request("album", ["id": id]) { (result: Result<AlbumPage, Error>) in switch result { case .success(let value): page = value; case .failure(let error): engine.error = error.localizedDescription } } } }
    }
}

struct PlayerScreen: View {
    @ObservedObject var engine: NativeEngine
    @Environment(\.presentationMode) private var presentation
    @State private var queueOpen = false
    @State private var seeking = false
    @State private var seekValue: Double = 0
    var body: some View {
        NavigationView { GeometryReader { geometry in
            ScrollView { VStack(spacing: 22) {
                if let track = engine.player.current {
                    Artwork(url: track.art.isEmpty ? track.thumb : track.art, size: min(geometry.size.width - 64, 360)).shadow(radius: 25).padding(.top, 10)
                    HStack { VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.title2.bold()).lineLimit(2); Text(track.artist).foregroundColor(.secondary).lineLimit(1) }; Spacer(); Button { engine.track("favorite", track) } label: { Image(systemName: engine.library.favorites.contains(where: { $0.id == track.id }) ? "heart.fill" : "heart").font(.title2) }.foregroundColor(engine.accent) }
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { seeking ? seekValue : min(engine.player.position, max(engine.player.duration, 1)) }, set: { seekValue = $0 }), in: 0...max(engine.player.duration, 1), onEditingChanged: { editing in seeking = editing; if !editing { engine.call("seek", ["position": seekValue]) } })
                        HStack { Text(time(engine.player.position)); Spacer(); Text(time(engine.player.duration)) }.font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    HStack(spacing: 0) {
                        Button { engine.call("shuffle") } label: { Image(systemName: "shuffle").foregroundColor(engine.player.shuffle ? engine.accent : .secondary).frame(maxWidth: .infinity) }
                        Button { engine.call("previous") } label: { Image(systemName: "backward.end.fill").font(.title).frame(maxWidth: .infinity) }
                        Button { engine.call("toggle") } label: { Image(systemName: engine.player.status == "playing" ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .bold)).frame(width: 76, height: 76).musikeGlass(38) }
                        Button { engine.call("next") } label: { Image(systemName: "forward.end.fill").font(.title).frame(maxWidth: .infinity) }
                        Button { engine.call("repeat") } label: { Image(systemName: engine.player.repeat == "one" ? "repeat.1" : "repeat").foregroundColor(engine.player.repeat == "off" ? .secondary : engine.accent).frame(maxWidth: .infinity) }
                    }.buttonStyle(.plain)
                    if engine.player.status == "loading" { ProgressView(engine.text("Loading…", "Cargando…", "Carregando…")) }
                    if engine.player.status == "error" { Text(engine.text("Playback failed. Try again.", "No se pudo reproducir. Inténtalo de nuevo.", "Não foi possível reproduzir. Tente novamente.")).font(.caption).foregroundColor(.secondary) }
                    Button { queueOpen = true } label: { Label(engine.text("Queue", "Cola", "Fila"), systemImage: "list.bullet") }.padding(.top, 8)
                }
            }.padding(.horizontal, 28).frame(maxWidth: .infinity) }
        }.navigationTitle(engine.text("Now playing", "En reproducción", "Tocando agora")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button { presentation.wrappedValue.dismiss() } label: { Image(systemName: "chevron.down") } } }
        .sheet(isPresented: $queueOpen) { QueueScreen(engine: engine) }
        }.navigationViewStyle(.stack).tint(engine.accent).preferredColorScheme(engine.appearance.theme == "light" ? .light : .dark)
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

/// Keeps the existing runtime alive behind SwiftUI. Its full interface remains available for advanced features.
final class MusikeRootController: UIViewController {
    private let runtime = MusikeWebViewController()
    private var host: UIHostingController<NativeRoot>!
    private let returnButton = UIButton(type: .system)
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(runtime); runtime.view.frame = view.bounds; runtime.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(runtime.view); runtime.didMove(toParent: self)
        host = UIHostingController(rootView: NativeRoot(engine: runtime.nativeEngine))
        addChild(host); host.view.frame = view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(host.view); host.didMove(toParent: self)
        returnButton.setImage(UIImage(systemName: "chevron.left.circle.fill"), for: .normal)
        returnButton.accessibilityLabel = "Return to native interface"
        returnButton.tintColor = .systemBlue
        returnButton.backgroundColor = .systemBackground
        returnButton.layer.cornerRadius = 22
        returnButton.addTarget(self, action: #selector(returnToNative), for: .touchUpInside)
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(returnButton)
        NSLayoutConstraint.activate([returnButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12), returnButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -90), returnButton.widthAnchor.constraint(equalToConstant: 44), returnButton.heightAnchor.constraint(equalToConstant: 44)])
        returnButton.isHidden = true
        runtime.nativeEngine.showClassic = { [weak self] in self?.host.view.isHidden = true; self?.returnButton.isHidden = false }
    }
    @objc private func returnToNative() { host.view.isHidden = false; returnButton.isHidden = true }
}
