import SwiftUI
import AVKit
import UniformTypeIdentifiers

private enum MacPage: Equatable {
    case recent, songs, artists, albums, favorites, search
    case playlist(String), artist(String), album(String)
    case currentSong(Track)
}

private struct MacSongReveal: Equatable {
    let trackID: String
    private let request = UUID()
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
    @State private var playlistSeed: Track?
    @State private var trackInformation: Track?
    @State private var exportTrack: Track?
    @State private var revealSong: MacSongReveal?
    @State private var catalog = MacCatalog()
    @State private var selectedArtist: String?
    @State private var nativeToolbarInstalled = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if nativeToolbarInstalled {
                    MacLibrarySplitView(
                        sidebar: sidebar,
                        detail: libraryContent(windowWidth: geometry.size.width)
                    )
                } else {
                    HStack(spacing: 0) {
                        sidebar.frame(width: macSidebarWidth)
                            .background(.ultraThinMaterial)
                        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1)
                        VStack(spacing: 0) {
                            MacPlaybackBar(engine: engine, queueShown: $queueShown, playerShown: $playerShown,
                                           compact: geometry.size.width < 840, onAction: nowPlayingAction)
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                            libraryContent(windowWidth: geometry.size.width)
                        }
                    }
                    .background(Color(uiColor: .systemBackground))
                }
            }
            .overlay(alignment: .topLeading) {
                if #available(iOS 16.4, *) {
                    MacToolbarInstaller(engine: engine, queueShown: $queueShown, playerShown: $playerShown,
                                        installed: $nativeToolbarInstalled, windowWidth: geometry.size.width, onAction: nowPlayingAction)
                        .frame(width: 0, height: 0)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(engine.accent)
        .onReceive(collection.$tracks) { catalog = MacCatalog($0, albumInfo: collection.albumInfo) }
        .onReceive(engine.$library) { collection.migrateLegacy($0) }
        .sheet(isPresented: $settingsShown) { SettingsScreen(engine: engine) }
        .sheet(isPresented: $playerShown) { PlayerScreen(engine: engine) }
        .sheet(item: $trackInformation) { track in MacTrackInformation(engine: engine, track: track) }
        .sheet(isPresented: $createShown) {
            PlaylistNameSheet(engine: engine, name: $playlistName, title: engine.text("New playlist", "Nueva lista", "Nova playlist"), action: engine.text("Create", "Crear", "Criar")) { name in
                if let track = playlistSeed {
                    playlistAction("batchCreatePlaylist", ["name": name, "tracks": engine.object([track])])
                } else {
                    playlistAction("createPlaylist", ["name": name])
                }
                playlistName = ""
                playlistSeed = nil
            }
        }
        .fileImporter(isPresented: $importShown, allowedContentTypes: exportTrack == nil ? [.audio] : [.folder],
                      allowsMultipleSelection: exportTrack == nil, onCompletion: handleFileSelection)
        .alert(engine.text("Error", "Error", "Erro"), isPresented: Binding(get: { engine.error != nil || collection.error != nil }, set: { if !$0 { engine.error = nil; collection.error = nil } })) {
            Button("OK", role: .cancel) { engine.error = nil; collection.error = nil }
        } message: { Text(collection.error ?? engine.error ?? "") }
    }

    private func libraryContent(windowWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                pageHeader
                pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if queueShown {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                MacQueuePanel(engine: engine, showHistory: $queueHistory)
                    .frame(width: min(300, max(230, windowWidth * 0.25)))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .tint(engine.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacSidebarSearchField(
                title: engine.text("Search", "Buscar", "Buscar"),
                query: $search,
                isSearchPage: page == .search,
                activateSearch: { page = .search }
            )
            .padding(.horizontal, 12)
            .padding(.top, nativeToolbarInstalled ? 16 : 54)
            .padding(.bottom, 14)
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
                        Button { playlistSeed = nil; createShown = true } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                            .accessibilityLabel(engine.text("New playlist", "Nueva lista", "Nova playlist"))
                    }.padding(.trailing, 11)
                    ForEach(engine.library.playlists) { playlist in
                        sidebarItem(.playlist(playlist.id), "music.note.list", playlist.name)
                    }
                }.padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            if collection.importing { ProgressView().controlSize(.small).padding(.horizontal, 14).padding(.bottom, 4) }
            Button { exportTrack = nil; importShown = true } label: {
                Label(engine.text("Import music", "Importar música", "Importar música"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.plain).disabled(collection.importing)
            Button { settingsShown = true } label: {
                Label(engine.text("Settings", "Ajustes", "Ajustes"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.plain).padding(.bottom, 8)
        }
        .font(.system(size: 13))
        .tint(engine.accent)
    }
    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
    }
    private func sidebarItem(_ item: MacPage, _ icon: String, _ title: String) -> some View {
        Button { page = item; filter = ""; selectedArtist = nil; revealSong = nil } label: {
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
        case .currentSong: return engine.text("Current Song", "Canción actual", "Música atual")
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
            MacSongsView(engine: engine, tracks: catalog.tracks.filter(matches), collection: collection, reveal: revealSong)
        case .currentSong(let track):
            MacSongsView(engine: engine, tracks: [track].filter(matches), collection: collection)
        case .favorites:
            MacSongsView(engine: engine, tracks: engine.library.favorites.filter(matches), collection: collection)
        case .albums:
            MacAlbumsView(engine: engine, albums: catalog.albums.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter) }, select: { page = .album($0.id) })
        case .artists:
            MacArtistsView(engine: engine, artists: catalog.artists.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, selected: $selectedArtist, tracks: catalog.tracks, collection: collection)
        case .playlist(let id):
            if let playlist = engine.library.playlists.first(where: { $0.id == id }) {
                MacPlaylistView(engine: engine, playlist: playlist, collection: collection, filter: filter,
                                reveal: revealSong, deleted: { page = .songs })
            } else { MacEmptyView(engine: engine, text: engine.text("Playlist not found.", "No se encuentra la lista.", "Playlist não encontrada.")) }
        case .artist(let name):
            MacSongsView(engine: engine, tracks: catalog.tracks.filter { $0.artist == name && matches($0) }, collection: collection)
        case .album(let id):
            if let album = catalog.albums.first(where: { $0.id == id }) {
                MacAlbumDetail(engine: engine, album: album, collection: collection)
            } else { MacEmptyView(engine: engine, text: engine.text("Album not found.", "No se encuentra el álbum.", "Álbum não encontrado.")) }
        }
    }

    private func nowPlayingAction(_ action: MacNowPlayingAction) {
        switch action {
        case .song(let track):
            showSong(track)
        case .album(let track):
            let albums = catalog.albums.filter { album in album.tracks.contains { $0.id == track.id } }
            if let album = albums.first(where: { $0.title == track.album }) ?? albums.first {
                filter = ""
                page = .album(album.id)
            }
        case .playlist(let id, let track):
            filter = ""
            page = .playlist(id)
            revealSong = MacSongReveal(trackID: track.id)
        case .information(let track):
            trackInformation = track
        case .newPlaylist(let track):
            playlistSeed = track
            createShown = true
        case .export(let track):
            exportTrack = track
            importShown = true
        case .paste:
            guard let track = MacTrackClipboard.readTrack() else {
                engine.error = engine.text("Copy a song in Musike first.", "Copia primero una canción en Musike.", "Copie primeiro uma música no Musike.")
                return
            }
            collection.add([track])
            guard let savedTrack = collection.tracks.first(where: { $0.id == track.id }) else { return }
            if case .playlist(let id) = page {
                playlistAction("addToPlaylist", ["id": id, "track": engine.object(savedTrack)])
            } else {
                showSong(savedTrack)
            }
        }
    }

    private func showSong(_ track: Track) {
        filter = ""
        page = collection.contains(track.id) ? .songs : .currentSong(track)
        revealSong = MacSongReveal(trackID: track.id)
    }

    private func playlistAction(_ action: String, _ args: [String: Any]) {
        engine.call(action, args) { result in
            if case .failure(let error) = result { engine.error = error.localizedDescription }
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        let track = exportTrack
        exportTrack = nil
        switch result {
        case .success(let urls):
            guard let track else { collection.importFiles(urls); return }
            guard let source = collection.localURL(track.id), let folder = urls.first else { return }
            Task {
                do { try await MacTrackFile.export(source, title: track.title, to: folder) }
                catch { collection.error = error.localizedDescription }
            }
        case .failure(let error):
            collection.error = error.localizedDescription
        }
    }
}

private let macSidebarWidth: CGFloat = 200

private struct MacSidebarSearchField: View {
    let title: String
    @Binding var query: String
    let isSearchPage: Bool
    let activateSearch: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(title, text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
        }
        .padding(7)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .onChange(of: isFocused) { focused in
            if focused { activateSearch() }
        }
        .onChange(of: isSearchPage) { active in
            if !active { isFocused = false }
        }
    }
}

private struct MacLibrarySplitView<Sidebar: View, Detail: View>: UIViewControllerRepresentable {
    var sidebar: Sidebar
    var detail: Detail

    func makeCoordinator() -> Coordinator {
        Coordinator(sidebar: sidebar, detail: detail)
    }

    func makeUIViewController(context: Context) -> UISplitViewController {
        let split = UISplitViewController(style: .doubleColumn)
        split.primaryBackgroundStyle = .sidebar
        split.preferredSplitBehavior = .tile
        split.preferredDisplayMode = .oneBesideSecondary
        split.minimumPrimaryColumnWidth = macSidebarWidth
        split.maximumPrimaryColumnWidth = macSidebarWidth
        split.preferredPrimaryColumnWidth = macSidebarWidth
        split.presentsWithGesture = false
        split.displayModeButtonVisibility = .never
        split.view.backgroundColor = .clear
        split.setViewController(navigationController(for: context.coordinator.sidebar), for: .primary)
        split.setViewController(navigationController(for: context.coordinator.detail), for: .secondary)
        return split
    }

    func updateUIViewController(_ split: UISplitViewController, context: Context) {
        context.coordinator.sidebar.rootView = sidebar
        context.coordinator.detail.rootView = detail
    }

    private func navigationController(for host: UIViewController) -> UINavigationController {
        host.view.backgroundColor = .clear
        let navigation = UINavigationController(rootViewController: host)
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.view.backgroundColor = .clear
        return navigation
    }

    final class Coordinator {
        let sidebar: UIHostingController<Sidebar>
        let detail: UIHostingController<Detail>

        init(sidebar: Sidebar, detail: Detail) {
            self.sidebar = UIHostingController(rootView: sidebar)
            self.detail = UIHostingController(rootView: detail)
        }
    }
}

@available(iOS 16.4, *)
private struct MacToolbarInstaller: UIViewRepresentable {
    @ObservedObject var engine: NativeEngine
    @Binding var queueShown: Bool
    @Binding var playerShown: Bool
    @Binding var installed: Bool
    let windowWidth: CGFloat
    let onAction: (MacNowPlayingAction) -> Void

    func makeUIView(context: Context) -> MacToolbarAnchor {
        MacToolbarAnchor(engine: engine, queueShown: $queueShown, playerShown: $playerShown,
                         installed: $installed, onAction: onAction)
    }
    func updateUIView(_ view: MacToolbarAnchor, context: Context) { view.updateWidth(windowWidth) }
}

private enum MacPlaybackSection: String, CaseIterable {
    case transport, track, output

    var identifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("app.musike.playback." + rawValue)
    }

    func width(for windowWidth: CGFloat) -> CGFloat {
        let compact = windowWidth < 840
        switch self {
        case .transport: return compact ? 126 : 166
        case .output: return compact ? 174 : 200
        case .track:
            let available = windowWidth - macSidebarWidth
                - Self.transport.width(for: windowWidth) - Self.output.width(for: windowWidth) - 72
            let preferred = min(420, max(140, (windowWidth - macSidebarWidth) * 0.4))
            return min(preferred, max(140, available))
        }
    }
}

@available(iOS 16.4, *)
private final class MacToolbarAnchor: UIView, NSToolbarDelegate {
    private let engine: NativeEngine
    private let queueShown: Binding<Bool>
    private let playerShown: Binding<Bool>
    private let installed: Binding<Bool>
    private let onAction: (MacNowPlayingAction) -> Void
    private let trackState = MacToolbarTrackState()
    private var toolbar: NSToolbar?
    private var hosts: [MacPlaybackSection: UIHostingController<MacPlaybackBar>] = [:]
    private var widths: [MacPlaybackSection: NSLayoutConstraint] = [:]
    private var lastWidth: CGFloat = 760

    init(engine: NativeEngine, queueShown: Binding<Bool>, playerShown: Binding<Bool>, installed: Binding<Bool>,
         onAction: @escaping (MacNowPlayingAction) -> Void) {
        self.engine = engine
        self.queueShown = queueShown
        self.playerShown = playerShown
        self.installed = installed
        self.onAction = onAction
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard toolbar == nil, let titlebar = window?.windowScene?.titlebar else { return }
        let toolbar = NSToolbar(identifier: "app.musike.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        titlebar.titleVisibility = .hidden
        titlebar.toolbarStyle = .unified
        titlebar.toolbar = toolbar
        self.toolbar = toolbar
        DispatchQueue.main.async { self.installed.wrappedValue = true }
    }

    func updateWidth(_ width: CGFloat) {
        guard width > 0, abs(width - lastWidth) > 1 else { return }
        let compactChanged = (lastWidth < 840) != (width < 840)
        lastWidth = width
        for (section, host) in hosts {
            widths[section]?.constant = section.width(for: width)
            if compactChanged { host.rootView = controls(for: section) }
            host.view.invalidateIntrinsicContentSize()
        }
    }

    private func controls(for section: MacPlaybackSection) -> MacPlaybackBar {
        MacPlaybackBar(engine: engine, queueShown: queueShown, playerShown: playerShown,
                       compact: lastWidth < 840, section: section, onAction: onAction, trackState: trackState)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Leave actual AppKit toolbar space between the three interactive groups.
        [.primarySidebarTrackingSeparatorItemIdentifier, MacPlaybackSection.transport.identifier,
         .flexibleSpace, MacPlaybackSection.track.identifier, .flexibleSpace, MacPlaybackSection.output.identifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = MacPlaybackSection.allCases.first(where: { $0.identifier == identifier }) else {
            return nil
        }
        let host = UIHostingController(rootView: controls(for: section))
        // The hosting view is already inside the title bar.
        host.safeAreaRegions = []
        let content: UIView = host.view
        content.backgroundColor = .clear
        let itemView: UIView = section == .track ? MacToolbarTrackView(content: content, state: trackState) : content
        itemView.translatesAutoresizingMaskIntoConstraints = false
        let width = itemView.widthAnchor.constraint(equalToConstant: section.width(for: lastWidth))
        let height = section == .track ? MacMiniPlayer.height : 50
        NSLayoutConstraint.activate([width, itemView.heightAnchor.constraint(equalToConstant: height)])
        if flag {
            widths[section] = width
            hosts[section] = host
        }
        return NSUIViewToolbarItem(itemIdentifier: identifier, uiView: itemView)
    }
}

private final class MacToolbarTrackState: ObservableObject {
    @Published private(set) var isInside = false
    @Published private(set) var bottomInset: CGFloat = 0

    func setInside(_ inside: Bool) {
        if isInside != inside { isInside = inside }
    }

    func setBottomInset(_ inset: CGFloat) {
        if bottomInset != inset { bottomInset = inset }
    }
}

private final class MacToolbarTrackView: UIView {
    private let state: MacToolbarTrackState

    init(content: UIView, state: MacToolbarTrackState) {
        self.state = state
        super.init(frame: .zero)
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Track the whole toolbar item, including the space between SwiftUI controls.
        let pointer = UIHoverGestureRecognizer(target: self, action: #selector(pointerMoved(_:)))
        pointer.cancelsTouchesInView = false
        addGestureRecognizer(pointer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { state.setInside(false) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window, window.bounds.height > 0 else { return }
        // AppKit may draw a UIKit toolbar item outside its window's mouse-event area.
        let visibleBounds = convert(window.bounds, from: window)
        let inset = max(0, bounds.maxY - visibleBounds.maxY)
        if inset != state.bottomInset {
            DispatchQueue.main.async { [weak self] in self?.state.setBottomInset(inset) }
        }
    }

    @objc private func pointerMoved(_ pointer: UIHoverGestureRecognizer) {
        let tracking = pointer.state == .began || pointer.state == .changed
        state.setInside(tracking && bounds.contains(pointer.location(in: self)))
    }
}

private struct MacPlaybackBar: View {
    @ObservedObject var engine: NativeEngine
    @Binding var queueShown: Bool
    @Binding var playerShown: Bool
    let compact: Bool
    var section: MacPlaybackSection?
    let onAction: (MacNowPlayingAction) -> Void
    @ObservedObject var trackState = MacToolbarTrackState()
    @State private var volumePreview: Double?
    @State private var adjustingVolume = false
    @State private var volumeRevision = 0
    private var volume: Double { engine.player.muted ? 0 : engine.player.volume }
    var body: some View {
        Group {
            switch section {
            case .transport: transport
            case .track: nowPlaying
            case .output: output
            case nil:
                HStack(spacing: compact ? 9 : 14) {
                    transport
                    Spacer(minLength: 4)
                    nowPlaying.frame(maxWidth: 420)
                    Spacer(minLength: 4)
                    output
                }
                .padding(.horizontal, compact ? 12 : 18)
                .padding(.vertical, 6)
                .frame(minHeight: 58)
            }
        }
        .frame(maxWidth: .infinity)
        .tint(engine.accent)
    }

    private var transport: some View {
        HStack(spacing: compact ? 1 : 6) {
            control("shuffle", "shuffle", active: engine.player.shuffle)
            control("backward.end.fill", "previous")
            control(engine.player.status == "playing" ? "pause.fill" : "play.fill", "toggle", size: 18)
            control("forward.end.fill", "next")
            control(engine.player.repeat == "one" ? "repeat.1" : "repeat", "repeat", active: engine.player.repeat != "off")
        }
    }

    private var output: some View {
        HStack(spacing: compact ? 9 : 12) {
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
    }

    private func control(_ symbol: String, _ action: String, active: Bool = false, size: CGFloat = 13) -> some View {
        MacTransportButton(symbol: symbol, size: size, tint: active ? UIColor(engine.accent) : .label, label: action) {
            engine.call(action)
        }
            .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
            .disabled(engine.player.current == nil && action != "shuffle" && action != "repeat")
    }
    @ViewBuilder private var nowPlaying: some View {
        if let track = engine.player.current {
            MacMiniPlayer(engine: engine, track: track, openPlayer: { playerShown = true }, onAction: onAction,
                          toolbarHovered: section == .track ? trackState.isInside : nil,
                          toolbarBottomInset: section == .track ? trackState.bottomInset : 0)
                .id(track.id)
        } else {
            ZStack(alignment: .leading) {
                Text("Musike").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Image(systemName: "music.note").foregroundStyle(.secondary)
                    .frame(width: MacMiniPlayer.height, height: MacMiniPlayer.height).background(Color.primary.opacity(0.1))
                    .accessibilityHidden(true)
            }
            .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 3))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

private struct MacTransportButton: UIViewRepresentable {
    let symbol: String
    let size: CGFloat
    let tint: UIColor
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> TransportButton {
        let button = TransportButton(type: .custom)
        button.layer.cornerRadius = 6
        let pointer = UIHoverGestureRecognizer(target: button, action: #selector(TransportButton.pointerMoved(_:)))
        pointer.cancelsTouchesInView = false
        button.addGestureRecognizer(pointer)
        button.addAction(UIAction { [weak button] _ in button?.performAction?() }, for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: TransportButton, context: Context) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
        button.tintColor = tint
        button.isEnabled = isEnabled
        button.accessibilityLabel = label
        button.performAction = action
    }

    final class TransportButton: UIButton {
        var performAction: (() -> Void)?
        private var pointerInside = false

        override var isEnabled: Bool { didSet { updateHighlight() } }
        override var isHighlighted: Bool { didSet { updateHighlight() } }

        @objc func pointerMoved(_ pointer: UIHoverGestureRecognizer) {
            let tracking = pointer.state == .began || pointer.state == .changed
            pointerInside = tracking && bounds.contains(pointer.location(in: self))
            updateHighlight()
        }

        private func updateHighlight() {
            let opacity = isHighlighted ? 0.15 : (pointerInside ? 0.085 : 0)
            backgroundColor = isEnabled ? UIColor.label.withAlphaComponent(opacity) : .clear
        }
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

struct MacArtwork: View {
    let track: Track
    let size: CGFloat
    var cornerRadius: CGFloat = 5
    var body: some View {
        Group {
            if let image = MacMusicLibrary.shared.artwork(track.id) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = URL(string: track.art.isEmpty ? track.thumb : track.art), !url.absoluteString.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }.frame(width: size, height: size).clipped().cornerRadius(cornerRadius)
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
    var reveal: MacSongReveal? = nil
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
                ScrollViewReader { scroll in
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
                                .background(engine.player.current?.id == track.id || reveal?.trackID == track.id ? engine.accent.opacity(0.18) : (index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04)))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { engine.play(tracks, at: index) }
                                .contextMenu { menu(track) }
                                .id(index)
                            }
                        }
                    }
                    .task(id: reveal) {
                        guard let reveal, let index = tracks.firstIndex(where: { $0.id == reveal.trackID }) else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        scroll.scrollTo(index, anchor: .center)
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
    let reveal: MacSongReveal?
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
            MacSongsView(engine: engine, tracks: tracks, collection: collection, playlistID: playlist.id, reveal: reveal)
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
func macTime(_ value: Double) -> String {
    guard value.isFinite && value >= 0 else { return "0:00" }
    let seconds = Int(value); return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
