import SwiftUI
import AVKit
import UniformTypeIdentifiers

private enum MacPage: Equatable {
    case recent, songs, artists, albums, favorites, search
    case playlist(String), artist(String), album(String)
}

private struct MacAlbum: Identifiable {
    let id: String
    let title: String
    let artist: String
    let remoteId: String?
    let tracks: [Track]
    var cover: Track { tracks[0] }
}
private struct MacRecentItem: Identifiable {
    let id: String
    let track: Track
    let album: MacAlbum?
}

private struct MacCatalog {
    var tracks: [Track] = []
    var albums: [MacAlbum] = []
    var artists: [String] = []
    var recent: [MacRecentItem] = []
    init(_ tracks: [Track] = [], albumInfo: [String: [MacMusicLibrary.AlbumInfo]] = [:]) {
        self.tracks = tracks
        var groups: [String: [Track]] = [:]
        var names = Set<String>()
        for track in tracks {
            if !track.artist.isEmpty { names.insert(track.artist) }
            let info = albumInfo[track.id] ?? []
            if !info.isEmpty {
                for album in info { groups["online:\(album.id)", default: []].append(track) }
            } else if let album = track.album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                groups["\(album.lowercased())\u{1f}\(track.artist.lowercased())", default: []].append(track)
            }
        }
        albums = groups.map { key, value in
            let info = albumInfo[value[0].id]?.first { "online:\($0.id)" == key }
            let sorted = info == nil ? value : value.sorted { left, right in
                let first = albumInfo[left.id]?.first { "online:\($0.id)" == key }?.position ?? Int.max
                let second = albumInfo[right.id]?.first { "online:\($0.id)" == key }?.position ?? Int.max
                return first < second
            }
            return MacAlbum(id: key, title: info?.title ?? value[0].album ?? "", artist: info?.artist ?? value[0].artist, remoteId: info?.id, tracks: sorted)
        }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        artists = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var albumByTrack: [String: MacAlbum] = [:]
        for album in albums { for track in album.tracks where albumByTrack[track.id] == nil { albumByTrack[track.id] = album } }
        var seen = Set<String>()
        recent = tracks.compactMap { track in
            let album = albumByTrack[track.id]
            let id = album.map { "album:\($0.id)" } ?? "track:\(track.id)"
            return seen.insert(id).inserted ? MacRecentItem(id: id, track: track, album: album) : nil
        }
    }
}

struct MacRootView: View {
    @ObservedObject var engine: NativeEngine
    @ObservedObject private var collection = MacMusicLibrary.shared
    @State private var page: MacPage = .recent
    @State private var search = ""
    @State private var filter = ""
    @State private var filterShown = false
    @State private var queueShown = false
    @State private var queueHistory = false
    @State private var settingsShown = false
    @State private var playerShown = false
    @State private var importShown = false
    @State private var createShown = false
    @State private var playlistName = ""
    @State private var catalog = MacCatalog()
    @State private var selectedArtist: String?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar.frame(width: geometry.size.width < 820 ? 185 : 218)
                Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1)
                VStack(spacing: 0) {
                    MacPlaybackBar(engine: engine, queueShown: $queueShown, playerShown: $playerShown,
                                   compact: geometry.size.width < 840)
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            pageHeader
                            pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if queueShown {
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                            MacQueuePanel(engine: engine, showHistory: $queueHistory)
                                .frame(width: min(300, max(230, geometry.size.width * 0.25)))
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(engine.accent)
        .preferredColorScheme(engine.appearance.theme == "light" ? .light : .dark)
        .onReceive(collection.$tracks) { catalog = MacCatalog($0, albumInfo: collection.albumInfo) }
        .onReceive(engine.$library) { collection.migrateLegacy($0) }
        .sheet(isPresented: $settingsShown) { SettingsScreen(engine: engine) }
        .sheet(isPresented: $playerShown) { PlayerScreen(engine: engine) }
        .sheet(isPresented: $createShown) {
            PlaylistNameSheet(engine: engine, name: $playlistName, title: engine.text("New playlist", "Nueva lista", "Nova playlist"), action: engine.text("Create", "Crear", "Criar")) { name in
                engine.call("createPlaylist", ["name": name]); playlistName = ""
            }
        }
        .fileImporter(isPresented: $importShown, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): collection.importFiles(urls); case .failure(let error): collection.error = error.localizedDescription }
        }
        .alert(engine.text("Error", "Error", "Erro"), isPresented: Binding(get: { engine.error != nil || collection.error != nil }, set: { if !$0 { engine.error = nil; collection.error = nil } })) {
            Button("OK", role: .cancel) { engine.error = nil; collection.error = nil }
        } message: { Text(collection.error ?? engine.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(engine.text("Search", "Buscar", "Buscar"), text: $search, onEditingChanged: { active in if active { page = .search } })
                    .textFieldStyle(.plain)
                    .onChange(of: search) { value in if !value.isEmpty { page = .search } }
            }.padding(7).background(Color.primary.opacity(0.08)).cornerRadius(7).padding(.horizontal, 12).padding(.top, 54).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarHeading(engine.text("Library", "Biblioteca", "Biblioteca"))
                    sidebarItem(.recent, "clock.arrow.circlepath", engine.text("Recently added", "Añadido recientemente", "Adicionado recentemente"))
                    sidebarItem(.artists, "music.mic", engine.text("Artists", "Artistas", "Artistas"))
                    sidebarItem(.albums, "square.stack", engine.text("Albums", "Álbumes", "Álbuns"))
                    sidebarItem(.songs, "music.note", engine.text("Songs", "Canciones", "Músicas"))
                    sidebarItem(.favorites, "heart", engine.text("Favorites", "Favoritos", "Favoritas"))
                    HStack {
                        sidebarHeading(engine.text("Playlists", "Listas", "Playlists"))
                        Spacer()
                        Button { createShown = true } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                            .accessibilityLabel(engine.text("New playlist", "Nueva lista", "Nova playlist"))
                    }.padding(.trailing, 11)
                    ForEach(engine.library.playlists) { playlist in
                        sidebarItem(.playlist(playlist.id), "music.note.list", playlist.name)
                    }
                }.padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            if collection.importing { ProgressView().controlSize(.small).padding(.horizontal, 14).padding(.bottom, 4) }
            Button { importShown = true } label: {
                Label(engine.text("Import music", "Importar música", "Importar música"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.plain).disabled(collection.importing)
            Button { settingsShown = true } label: {
                Label(engine.text("Settings", "Ajustes", "Ajustes"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.plain).padding(.bottom, 8)
        }
        .font(.system(size: 13))
        .background(.ultraThinMaterial)
    }
    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
    }
    private func sidebarItem(_ item: MacPage, _ icon: String, _ title: String) -> some View {
        Button { page = item; filter = ""; selectedArtist = nil } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(engine.accent).frame(width: 18)
                Text(title).lineLimit(1); Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                .background(page == item ? Color.primary.opacity(0.15) : Color.clear).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    private var pageHeader: some View {
        ZStack {
            Text(pageTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack {
                if isDetail { Button { page = previousPage } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain) }
                Spacer()
                if page != .search {
                    if filterShown {
                        TextField(engine.text("Filter", "Filtrar", "Filtrar"), text: $filter)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                    }
                    Button { filterShown.toggle(); if !filterShown { filter = "" } } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain)
                        .accessibilityLabel(engine.text("Filter", "Filtrar", "Filtrar"))
                }
            }.padding(.horizontal, 16)
        }.frame(height: 38).background(Color.primary.opacity(0.025))
    }
    private var pageTitle: String {
        switch page {
        case .recent: return engine.text("Recently added", "Añadido recientemente", "Adicionado recentemente")
        case .songs: return engine.text("Songs", "Canciones", "Músicas")
        case .artists: return engine.text("Artists", "Artistas", "Artistas")
        case .albums: return engine.text("Albums", "Álbumes", "Álbuns")
        case .favorites: return engine.text("Favorites", "Favoritos", "Favoritas")
        case .search: return engine.text("Search", "Buscar", "Buscar")
        case .playlist(let id): return engine.library.playlists.first(where: { $0.id == id })?.name ?? ""
        case .artist(let name): return name
        case .album(let id): return catalog.albums.first(where: { $0.id == id })?.title ?? ""
        }
    }
    private var isDetail: Bool { if case .album = page { return true }; if case .artist = page { return true }; return false }
    private var previousPage: MacPage { if case .artist = page { return .artists }; return .albums }
    private func matches(_ track: Track) -> Bool {
        filter.isEmpty || [track.title, track.artist, track.album ?? ""].contains { $0.localizedCaseInsensitiveContains(filter) }
    }
    @ViewBuilder private var pageContent: some View {
        switch page {
        case .search:
            NavigationView { SearchScreen(engine: engine, externalQuery: search, onQueryChange: { if search != $0 { search = $0 } }) }.navigationViewStyle(.stack)
        case .recent:
            MacRecentView(engine: engine, items: catalog.recent.filter { matches($0.track) || (!filter.isEmpty && ($0.album?.title.localizedCaseInsensitiveContains(filter) ?? false)) }, select: { item in
                if let album = item.album { page = .album(album.id) } else { engine.play([item.track]) }
            })
        case .songs:
            MacSongsView(engine: engine, tracks: catalog.tracks.filter(matches), collection: collection)
        case .favorites:
            MacSongsView(engine: engine, tracks: engine.library.favorites.filter(matches), collection: collection)
        case .albums:
            MacAlbumsView(engine: engine, albums: catalog.albums.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter) }, select: { page = .album($0.id) })
        case .artists:
            MacArtistsView(engine: engine, artists: catalog.artists.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, selected: $selectedArtist, tracks: catalog.tracks, collection: collection)
        case .playlist(let id):
            if let playlist = engine.library.playlists.first(where: { $0.id == id }) {
                MacPlaylistView(engine: engine, playlist: playlist, collection: collection, filter: filter, deleted: { page = .songs })
            } else { MacEmptyView(engine: engine, text: engine.text("Playlist not found.", "No se encuentra la lista.", "Playlist não encontrada.")) }
        case .artist(let name):
            MacSongsView(engine: engine, tracks: catalog.tracks.filter { $0.artist == name && matches($0) }, collection: collection)
        case .album(let id):
            if let album = catalog.albums.first(where: { $0.id == id }) {
                MacAlbumDetail(engine: engine, album: album, collection: collection)
            } else { MacEmptyView(engine: engine, text: engine.text("Album not found.", "No se encuentra el álbum.", "Álbum não encontrado.")) }
        }
    }
}

private struct MacPlaybackBar: View {
    @ObservedObject var engine: NativeEngine
    @Binding var queueShown: Bool
    @Binding var playerShown: Bool
    let compact: Bool
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @State private var volumePreview: Double?
    @State private var adjustingVolume = false
    @State private var volumeRevision = 0
    private var volume: Double { engine.player.muted ? 0 : engine.player.volume }
    var body: some View {
        HStack(spacing: compact ? 9 : 14) {
            HStack(spacing: compact ? 10 : 14) {
                control("shuffle", "shuffle", active: engine.player.shuffle)
                control("backward.end.fill", "previous")
                control(engine.player.status == "playing" ? "pause.fill" : "play.fill", "toggle", size: 18)
                control("forward.end.fill", "next")
                control(engine.player.repeat == "one" ? "repeat.1" : "repeat", "repeat", active: engine.player.repeat != "off")
            }.frame(minWidth: compact ? 130 : 160)
            Spacer(minLength: 4)
            nowPlaying.frame(maxWidth: 380)
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                Button { volumeRevision += 1; volumePreview = nil; engine.call("mute") } label: { Image(systemName: engine.player.muted ? "speaker.slash.fill" : "speaker.fill") }.buttonStyle(.plain)
                Slider(value: Binding(get: { volumePreview ?? volume }, set: { value in
                    volumePreview = value; volumeRevision += 1; engine.call("volume", ["value": value])
                }), in: 0...1, onEditingChanged: { editing in
                    adjustingVolume = editing
                    if !editing, let value = volumePreview {
                        volumeRevision += 1; let revision = volumeRevision
                        engine.call("volume", ["value": value]) { _ in
                            engine.call("state") { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    if revision == volumeRevision && !adjustingVolume { volumePreview = nil }
                                }
                            }
                        }
                    }
                }).frame(width: compact ? 76 : 92)
                Image(systemName: "speaker.wave.2.fill")
            }.font(.caption).foregroundColor(.secondary)
            MacRoutePicker().frame(width: 25, height: 25)
                .accessibilityLabel(engine.text("Audio output", "Salida de audio", "Saída de áudio"))
            Button { queueShown.toggle() } label: { Image(systemName: "list.bullet") }
                .buttonStyle(.plain).foregroundColor(queueShown ? engine.accent : .secondary)
                .accessibilityLabel(engine.text("Queue", "Cola", "Fila"))
        }
        .padding(.horizontal, compact ? 12 : 18)
        .padding(.vertical, 6)
        .frame(minHeight: 58)
        .background(Color.primary.opacity(0.045))
    }
    private func control(_ symbol: String, _ action: String, active: Bool = false, size: CGFloat = 13) -> some View {
        Button { engine.call(action) } label: { Image(systemName: symbol).font(.system(size: size, weight: .semibold)) }
            .buttonStyle(.plain).foregroundColor(active ? engine.accent : .primary)
            .disabled(engine.player.current == nil && action != "shuffle" && action != "repeat")
            .accessibilityLabel(action)
    }
    private var nowPlaying: some View {
        HStack(spacing: 8) {
            if let track = engine.player.current {
                Button { playerShown = true } label: { MacArtwork(track: track, size: 40) }.buttonStyle(.plain)
                VStack(spacing: 0) {
                    Button { playerShown = true } label: {
                        VStack(spacing: 1) {
                            Text(track.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(track.artist).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                    Slider(value: Binding(get: { seeking ? seekValue : min(engine.player.position, max(engine.player.duration, 1)) }, set: { seekValue = $0 }),
                           in: 0...max(engine.player.duration, 1), onEditingChanged: { editing in
                        seeking = editing; if !editing { engine.call("seek", ["position": seekValue]) }
                    }).controlSize(.mini)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button { engine.track("favorite", track) } label: {
                    Image(systemName: engine.library.favorites.contains(where: { $0.id == track.id }) ? "heart.fill" : "heart")
                        .foregroundColor(engine.library.favorites.contains(where: { $0.id == track.id }) ? engine.accent : .secondary)
                }.buttonStyle(.plain)
            } else {
                Image(systemName: "music.note").foregroundColor(.secondary).frame(width: 40, height: 40).background(Color.primary.opacity(0.1))
                Spacer(); Text("Musike").font(.subheadline.weight(.semibold)).foregroundColor(.secondary); Spacer()
            }
        }
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .frame(minHeight: 44)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(5)
    }
}

private struct MacRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .secondaryLabel
        return picker
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private struct MacArtwork: View {
    let track: Track
    let size: CGFloat
    var body: some View {
        Group {
            if let image = MacMusicLibrary.shared.artwork(track.id) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = URL(string: track.art.isEmpty ? track.thumb : track.art), !url.absoluteString.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }.frame(width: size, height: size).clipped().cornerRadius(5)
    }
    private var placeholder: some View { ZStack { Color.gray.opacity(0.45); Image(systemName: "music.note").font(.system(size: size * 0.38)).foregroundColor(.white.opacity(0.35)) } }
}

private struct MacEmptyView: View {
    @ObservedObject var engine: NativeEngine
    let text: String
    var body: some View { VStack(spacing: 12) { Image(systemName: "music.note.list").font(.largeTitle).foregroundColor(.secondary); Text(text).foregroundColor(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding() }
}

private struct MacRecentView: View {
    @ObservedObject var engine: NativeEngine
    let items: [MacRecentItem]
    let select: (MacRecentItem) -> Void
    var body: some View {
        if items.isEmpty { MacEmptyView(engine: engine, text: engine.text("Add music to your library to see it here.", "Añade música a tu biblioteca para verla aquí.", "Adicione músicas à sua biblioteca para vê-las aqui.")) }
        else {
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                Text(engine.text("Recently added", "Añadido recientemente", "Adicionado recentemente")).font(.title3.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)], alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        Button { select(item) } label: { MacCoverCard(track: item.track, subtitle: item.album?.artist ?? item.track.artist, title: item.album?.title) }.buttonStyle(.plain)
                    }
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}
private struct MacCoverCard: View {
    let track: Track
    let subtitle: String
    var title: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in MacArtwork(track: track, size: geo.size.width) }.aspectRatio(1, contentMode: .fit)
            Text(title ?? track.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct MacAlbumsView: View {
    @ObservedObject var engine: NativeEngine
    let albums: [MacAlbum]
    let select: (MacAlbum) -> Void
    var body: some View {
        if albums.isEmpty { MacEmptyView(engine: engine, text: engine.text("Add albums from search or import music to build your library.", "Añade álbumes desde Buscar o importa música para crear tu biblioteca.", "Adicione álbuns na busca ou importe músicas para criar sua biblioteca.")) }
        else {
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)], alignment: .leading, spacing: 20) {
                ForEach(albums) { album in Button { select(album) } label: { MacCoverCard(track: album.cover, subtitle: album.artist, title: album.title) }.buttonStyle(.plain) }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

private struct MacSongsView: View {
    @ObservedObject var engine: NativeEngine
    let tracks: [Track]
    @ObservedObject var collection: MacMusicLibrary
    var playlistID: String? = nil
    @State private var addToPlaylist: Track?
    var body: some View {
        if tracks.isEmpty { MacEmptyView(engine: engine, text: engine.text("No songs here yet. Import music or add songs from search.", "Todavía no hay canciones. Importa música o añádela desde Buscar.", "Ainda não há músicas. Importe músicas ou adicione pela busca.")) }
        else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("#").frame(width: 36)
                    Text(engine.text("Title", "Título", "Título")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(engine.text("Artist", "Artista", "Artista")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(engine.text("Album", "Álbum", "Álbum")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(engine.text("Time", "Duración", "Duração")).frame(width: 60)
                    Spacer().frame(width: 32)
                }.font(.system(size: 11)).foregroundColor(.secondary).padding(.vertical, 5).background(Color.primary.opacity(0.045))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            HStack(spacing: 0) {
                                Text("\(index + 1)").foregroundColor(.secondary).frame(width: 36)
                                Text(track.title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                Text(track.artist).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                Text(track.album ?? "").foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                Text(macTime(track.duration)).foregroundColor(.secondary).frame(width: 60)
                                Menu { menu(track) } label: { Image(systemName: "ellipsis").frame(width: 32, height: 27) }.menuStyle(.borderlessButton)
                            }
                            .font(.system(size: 12)).padding(.vertical, 3)
                            .background(engine.player.current?.id == track.id ? engine.accent.opacity(0.18) : (index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04)))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { engine.play(tracks, at: index) }
                            .contextMenu { menu(track) }
                        }
                    }
                }
            }
            .sheet(item: $addToPlaylist) { track in BatchPlaylistPicker(engine: engine, tracks: [track], didAdd: {}) }
        }
    }
    @ViewBuilder private func menu(_ track: Track) -> some View {
        Button(engine.text("Play", "Reproducir", "Tocar")) { if let index = tracks.firstIndex(where: { $0.id == track.id }) { engine.play(tracks, at: index) } }
        Button(engine.text("Play next", "Reproducir a continuación", "Tocar a seguir")) { engine.track("playNext", track) }
        Button(engine.text("Add to queue", "Añadir a la cola", "Adicionar à fila")) { engine.track("addToQueue", track) }
        Button(engine.text("Add to playlist", "Añadir a lista", "Adicionar à playlist")) { addToPlaylist = track }
        Button(engine.library.favorites.contains(where: { $0.id == track.id }) ? engine.text("Remove favorite", "Quitar de favoritos", "Remover favorita") : engine.text("Add favorite", "Añadir a favoritos", "Adicionar às favoritas")) { engine.track("favorite", track) }
        if !collection.contains(track.id) { Button(engine.text("Add to library", "Añadir a la biblioteca", "Adicionar à biblioteca")) { collection.add([track]) } }
        if let playlistID { Button(engine.text("Remove from playlist", "Quitar de la lista", "Remover da playlist"), role: .destructive) { engine.call("removeFromPlaylist", ["id": playlistID, "trackId": track.id]) } }
        if collection.contains(track.id) { Button(engine.text("Remove from library", "Quitar de la biblioteca", "Remover da biblioteca"), role: .destructive) { collection.remove(track.id) } }
    }
}

private struct MacArtistsView: View {
    @ObservedObject var engine: NativeEngine
    let artists: [String]
    @Binding var selected: String?
    let tracks: [Track]
    @ObservedObject var collection: MacMusicLibrary
    var body: some View {
        if artists.isEmpty { MacEmptyView(engine: engine, text: engine.text("Artists in your library appear here.", "Los artistas de tu biblioteca aparecerán aquí.", "Os artistas da sua biblioteca aparecerão aqui.")) }
        else {
            HStack(spacing: 0) {
                ScrollView { LazyVStack(spacing: 0) {
                    ForEach(artists, id: \.self) { artist in
                        Button { selected = artist } label: {
                            HStack(spacing: 10) { Image(systemName: "music.mic").frame(width: 32, height: 32).background(Color.gray.opacity(0.35)).clipShape(Circle()); Text(artist).lineLimit(1); Spacer() }
                                .padding(8).contentShape(Rectangle())
                                .background(selected == artist ? Color.primary.opacity(0.14) : Color.clear)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                } }.frame(width: 215)
                Divider()
                if let selected { VStack(alignment: .leading, spacing: 10) {
                    Text(selected).font(.title2.bold()).padding(.horizontal, 18).padding(.top, 18)
                    MacSongsView(engine: engine, tracks: tracks.filter { $0.artist == selected }, collection: collection)
                } } else { MacEmptyView(engine: engine, text: engine.text("Choose an artist.", "Selecciona un artista.", "Selecione um artista.")) }
            }
        }
    }
}

private struct MacAlbumDetail: View {
    @ObservedObject var engine: NativeEngine
    let album: MacAlbum
    @ObservedObject var collection: MacMusicLibrary
    @State private var fullAlbum = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 24) {
                MacArtwork(track: album.cover, size: 190)
                VStack(alignment: .leading, spacing: 8) {
                    Text(album.title).font(.title.bold())
                    Text(album.artist).font(.title3).foregroundColor(engine.accent)
                    Spacer(minLength: 10)
                    HStack {
                        Button { engine.play(album.tracks) } label: { Label(engine.text("Play", "Reproducir", "Tocar"), systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                        Button { engine.play(album.tracks.shuffled()) } label: { Label(engine.text("Shuffle", "Aleatorio", "Aleatório"), systemImage: "shuffle") }.buttonStyle(.bordered)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 190).padding(24)
            MacSongsView(engine: engine, tracks: album.tracks, collection: collection)
            if album.remoteId != nil {
                Button(engine.text("Show full album", "Mostrar álbum completo", "Mostrar álbum completo")) { fullAlbum = true }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .sheet(isPresented: $fullAlbum) {
            if let id = album.remoteId { NavigationView { AlbumScreen(engine: engine, id: id) }.navigationViewStyle(.stack) }
        }
    }
}
private struct MacPlaylistView: View {
    @ObservedObject var engine: NativeEngine
    let playlist: Playlist
    @ObservedObject var collection: MacMusicLibrary
    let filter: String
    let deleted: () -> Void
    @State private var rename = false
    @State private var deleting = false
    @State private var name = ""
    private var tracks: [Track] { filter.isEmpty ? playlist.tracks : playlist.tracks.filter { $0.title.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { engine.play(tracks) } label: { Label(engine.text("Play", "Reproducir", "Tocar"), systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(tracks.isEmpty)
                Button { engine.play(tracks.shuffled()) } label: { Image(systemName: "shuffle") }.buttonStyle(.bordered).disabled(tracks.isEmpty)
                Spacer()
                Menu {
                    Button(engine.text("Rename", "Renombrar", "Renomear")) { name = playlist.name; rename = true }
                    Button(engine.text("Delete", "Eliminar", "Excluir"), role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(16)
            MacSongsView(engine: engine, tracks: tracks, collection: collection, playlistID: playlist.id)
        }
        .sheet(isPresented: $rename) {
            PlaylistNameSheet(engine: engine, name: $name, title: engine.text("Rename playlist", "Renombrar lista", "Renomear playlist"), action: engine.text("Save", "Guardar", "Salvar")) { value in engine.call("renamePlaylist", ["id": playlist.id, "name": value]) }
        }
        .alert(engine.text("Delete playlist?", "¿Eliminar lista?", "Excluir playlist?"), isPresented: $deleting) {
            Button(engine.text("Delete", "Eliminar", "Excluir"), role: .destructive) { engine.call("deletePlaylist", ["id": playlist.id]); deleted() }
            Button(engine.text("Cancel", "Cancelar", "Cancelar"), role: .cancel) {}
        }
    }
}
private struct MacQueuePanel: View {
    @ObservedObject var engine: NativeEngine
    @Binding var showHistory: Bool
    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $showHistory) {
                Text(engine.text("Up next", "A continuación", "A seguir")).tag(false)
                Text(engine.text("History", "Historial", "Histórico")).tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.top, 14)
            if showHistory {
                if engine.library.history.isEmpty { Spacer(); Text(engine.text("No history yet.", "Todavía no hay historial.", "Ainda não há histórico.")).foregroundColor(.secondary); Spacer() }
                else { ScrollView { LazyVStack(spacing: 0) {
                    ForEach(Array(engine.library.history.enumerated()), id: \.offset) { _, track in
                        Button { engine.play([track]) } label: { row(track) }.buttonStyle(.plain); Divider()
                    }
                }.padding(.horizontal, 12) } }
            } else {
                let upcoming = Array(engine.player.queue.enumerated()).filter { $0.offset > engine.player.index }
                if upcoming.isEmpty { Spacer(); Text(engine.text("No upcoming songs.", "No hay canciones pendientes.", "Não há músicas pendentes.")).foregroundColor(.secondary); Spacer() }
                else { ScrollView { LazyVStack(spacing: 0) {
                    ForEach(upcoming, id: \.offset) { index, track in
                        HStack {
                            Button { engine.call("jumpTo", ["index": index]) } label: { row(track) }.buttonStyle(.plain)
                            Button { engine.call("removeAt", ["index": index]) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }; Divider()
                    }
                }.padding(.horizontal, 12) } }
                Toggle(engine.text("Autoplay radio", "Radio automática", "Rádio automática"), isOn: Binding(get: { engine.player.autoRadio }, set: { engine.call("autoRadio", ["enabled": $0]) })).padding(12)
            }
        }.font(.system(size: 12)).background(.ultraThinMaterial)
    }
    private func row(_ track: Track) -> some View {
        HStack(spacing: 9) {
            MacArtwork(track: track, size: 38)
            VStack(alignment: .leading, spacing: 2) { Text(track.title).lineLimit(1); Text(track.artist).foregroundColor(.secondary).lineLimit(1) }
            Spacer(minLength: 2); Text(macTime(track.duration)).foregroundColor(.secondary)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}
private func macTime(_ value: Double) -> String {
    guard value.isFinite && value >= 0 else { return "0:00" }
    let seconds = Int(value); return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
