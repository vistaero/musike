import SwiftUI
import UniformTypeIdentifiers

enum MacNowPlayingAction {
    case song(Track)
    case album(Track)
    case playlist(String, Track)
    case information(Track)
    case newPlaylist(Track)
    case export(Track)
    case paste
}

struct MacMiniPlayer: View {
    static let height: CGFloat = 42

    @ObservedObject var engine: NativeEngine
    let track: Track
    let openPlayer: () -> Void
    let onAction: (MacNowPlayingAction) -> Void
    var toolbarHovered: Bool? = nil
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var collection = MacMusicLibrary.shared
    @State private var hovering = false
    @State private var seekPreview: Double?
    @State private var seekTask: Task<Void, Never>?

    private var favorite: Bool { engine.library.favorites.contains { $0.id == track.id } }
    private var localURL: URL? { collection.localURL(track.id) }
    private var duration: Double {
        let value = engine.player.duration > 0 ? engine.player.duration : track.duration
        return value.isFinite ? max(0, value) : 0
    }
    private var position: Double { min(duration, max(0, seekPreview ?? engine.player.position)) }
    private var subtitle: String {
        [track.artist, track.album ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
    }
    private var pointerInside: Bool { toolbarHovered ?? hovering }
    private var showingTimes: Bool { pointerInside || seekPreview != nil }

    var body: some View {
        Group {
            if toolbarHovered == nil {
                card.onHover { hovering = $0 }
            } else {
                card
            }
        }
        .onDisappear { seekTask?.cancel() }
    }

    private var card: some View {
        HStack(spacing: 0) {
            Button(action: openPlayer) { MacArtwork(track: track, size: Self.height, cornerRadius: 0) }
                .buttonStyle(.plain)
                .accessibilityLabel(engine.text("Open player", "Abrir reproductor", "Abrir reprodutor"))
            ZStack(alignment: .bottom) {
                metadata
                    .padding(.bottom, 3)
                progress
            }
        }
        .frame(height: Self.height)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.035))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.09)).allowsHitTesting(false) }
        .contentShape(Rectangle())
    }

    private var metadata: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    Color.clear.frame(width: 16, height: 15).accessibilityHidden(true)
                    Button(action: openPlayer) {
                        Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }.buttonStyle(.plain)
                    options
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 41)

            HStack {
                Text(macTime(position))
                Spacer(minLength: 0)
                Text("−" + macTime(duration - position))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 21)
            .opacity(showingTimes ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Button { engine.track("favorite", track) } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(favorite ? engine.accent : Color.secondary)
                    .frame(width: 24, height: 21)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite
                ? engine.text("Remove from Favorites", "Eliminar de favoritos", "Remover das favoritas")
                : engine.text("Add to Favorites", "Añadir a favoritos", "Adicionar às favoritas"))
        }
    }

    private var progress: some View {
        GeometryReader { geometry in
            let fraction = duration > 0 ? position / duration : 0
            let end = geometry.size.width * fraction
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.primary.opacity(0.14)).frame(height: 3)
                Rectangle().fill(.primary.opacity(0.45)).frame(width: end, height: 3)
                if showingTimes && duration > 0 {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(.primary.opacity(0.65))
                        .frame(width: 4, height: 7)
                        .offset(x: min(max(0, end - 2), max(0, geometry.size.width - 4)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard duration > 0, geometry.size.width > 0 else { return }
                    seekTask?.cancel()
                    seekPreview = duration * min(1, max(0, value.location.x / geometry.size.width))
                }
                .onEnded { value in
                    guard duration > 0, geometry.size.width > 0 else { return }
                    seek(to: duration * min(1, max(0, value.location.x / geometry.size.width)))
                }
            )
        }
        .frame(height: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(engine.text("Playback position", "Posición de reproducción", "Posição da reprodução"))
        .accessibilityValue(macTime(position) + " / " + macTime(duration))
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            switch direction {
            case .increment: seek(to: min(duration, position + 5))
            case .decrement: seek(to: max(0, position - 5))
            @unknown default: break
            }
        }
    }

    private func seek(to position: Double) {
        seekTask?.cancel()
        seekPreview = position
        engine.call("seek", ["position": position])
        // Keep the preview while the engine sends its next playback snapshot.
        seekTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { seekPreview = nil }
        }
    }

    private var options: some View {
        MacTrackMenuButton(
            tint: UIColor(engine.accent),
            label: engine.text("Track options", "Opciones de la canción", "Opções da música"),
            makeItems: menuItems
        )
        .frame(width: 16, height: 15)
        .opacity(pointerInside ? 1 : 0)
    }

    private func menuItems() -> [UIMenuElement] {
        let file = localURL
        let playlists = engine.library.playlists
        let memberships = playlists.filter { $0.tracks.contains { $0.id == track.id } }
        let hasAlbum = collection.contains(track.id) &&
            (track.album?.isEmpty == false || collection.albumInfo[track.id]?.isEmpty == false)
        let playlistTitle = engine.text("Add to Playlist", "Añadir a playlist", "Adicionar à playlist")
        let newPlaylist = action(engine.text("New Playlist…", "Nueva playlist…", "Nova playlist…")) {
            onAction(.newPlaylist(track))
        }
        let addToPlaylists = section(playlists.map { playlist in
            action(playlist.name, enabled: !memberships.contains { $0.id == playlist.id }) {
                call("addToPlaylist", ["id": playlist.id, "track": engine.object(track)])
            }
        })
        let exportTitle = engine.text("Add to Device", "Añadir a dispositivo", "Adicionar a dispositivo")
        let export = submenu(exportTitle, items: file == nil ? [] : [
            action(engine.text("Choose Destination…", "Elegir destino…", "Escolher destino…")) {
                onAction(.export(track))
            }
        ])
        let favoriteTitle = favorite
            ? engine.text("Remove from Favorites", "Eliminar de favoritos", "Remover das favoritas")
            : engine.text("Add to Favorites", "Añadir a favoritos", "Adicionar às favoritas")
        let dislikeTitle = engine.player.currentDisliked == true
            ? engine.text("Undo Dislike", "Deshacer «No me gusta»", "Desfazer «Não gosto»")
            : engine.text("Dislike", "No me gusta", "Não gosto")

        return [
            section([UIMenu(title: playlistTitle, children: [newPlaylist, addToPlaylists]), export]),
            section([
                action(engine.text("Create Station", "Crear emisora", "Criar estação"), enabled: file == nil) {
                    call("startRadio", ["track": engine.object(track)])
                }
            ]),
            section([
                action(engine.text("Get Info", "Obtener información", "Obter informações")) { onAction(.information(track)) },
                action(favoriteTitle) { call("favorite", ["track": engine.object(track)]) },
                action(dislikeTitle) { call("dislike", ["id": track.id]) }
            ]),
            section([
                action(engine.text("Go to Current Song", "Ir a la canción actual", "Ir à música atual")) { onAction(.song(track)) },
                action(engine.text("Show Album in Library", "Mostrar álbum en la biblioteca", "Mostrar álbum na biblioteca"), enabled: hasAlbum) {
                    onAction(.album(track))
                },
                action(engine.text("Show in iTunes Store", "Mostrar en iTunes Store", "Mostrar na iTunes Store")) {
                    Task { await showInStore() }
                },
                submenu(engine.text("Show in Playlist", "Mostrar en playlist", "Mostrar na playlist"), items: memberships.map { playlist in
                    action(playlist.name) { onAction(.playlist(playlist.id, track)) }
                })
            ]),
            section([
                action(engine.text("Copy", "Copiar", "Copiar")) { MacTrackClipboard.copy(track, file: file) },
                action(engine.text("Paste", "Pegar", "Colar"), enabled: MacTrackClipboard.hasTrack) { onAction(.paste) },
                action(engine.text("Show in Finder", "Mostrar en el Finder", "Mostrar no Finder"), enabled: file != nil) {
                    guard let file else { return }
                    Task {
                        do { try await MacTrackFile.reveal(file) }
                        catch { engine.error = error.localizedDescription }
                    }
                }
            ])
        ]
    }

    private func action(_ title: String, enabled: Bool = true, perform: @escaping () -> Void) -> UIAction {
        UIAction(title: title, attributes: enabled ? [] : .disabled) { _ in perform() }
    }

    private func section(_ items: [UIMenuElement]) -> UIMenu {
        UIMenu(options: .displayInline, children: items)
    }

    private func submenu(_ title: String, items: [UIMenuElement]) -> UIMenuElement {
        guard !items.isEmpty else { return action(title, enabled: false) {} }
        return UIMenu(title: title, children: items)
    }

    private func call(_ action: String, _ args: [String: Any]) {
        engine.call(action, args) { result in
            if case .failure(let error) = result { engine.error = error.localizedDescription }
        }
    }

    @MainActor private func showInStore() async {
        do {
            guard let url = try await MacStoreSearch.trackURL(for: track) else {
                engine.error = engine.text("This song was not found in the iTunes Store.", "No se ha encontrado esta canción en iTunes Store.", "Esta música não foi encontrada na iTunes Store.")
                return
            }
            if !(await UIApplication.shared.open(url)) {
                engine.error = engine.text("Could not open the iTunes Store.", "No se ha podido abrir iTunes Store.", "Não foi possível abrir a iTunes Store.")
            }
        } catch {
            engine.error = error.localizedDescription
        }
    }
}

private struct MacTrackMenuButton: UIViewRepresentable {
    let tint: UIColor
    let label: String
    let makeItems: () -> [UIMenuElement]

    final class Coordinator {
        var makeItems: () -> [UIMenuElement] = { [] }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)), for: .normal)
        let items = UIDeferredMenuElement.uncached { [weak coordinator = context.coordinator] completion in
            completion(coordinator?.makeItems() ?? [])
        }
        button.menu = UIMenu(children: [items])
        button.showsMenuAsPrimaryAction = true
        if #available(iOS 16.0, *) { button.preferredMenuElementOrder = .fixed }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.makeItems = makeItems
        button.tintColor = tint
        button.accessibilityLabel = label
    }
}

struct MacTrackInformation: View {
    @ObservedObject var engine: NativeEngine
    let track: Track
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                MacArtwork(track: track, size: 120).frame(maxWidth: .infinity)
                informationRow(label: engine.text("Title", "Título", "Título"), value: track.title)
                informationRow(label: engine.text("Artist", "Artista", "Artista"), value: track.artist)
                if let album = track.album, !album.isEmpty {
                    informationRow(label: engine.text("Album", "Álbum", "Álbum"), value: album)
                }
                informationRow(label: engine.text("Duration", "Duración", "Duração"), value: macTime(track.duration))
                if let file = MacMusicLibrary.shared.localURL(track.id) {
                    informationRow(label: engine.text("Format", "Formato", "Formato"), value: file.pathExtension.uppercased())
                }
            }
            .navigationTitle(engine.text("Song Information", "Información de la canción", "Informações da música"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }.navigationViewStyle(.stack)
    }

    private func informationRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

enum MacTrackClipboard {
    private static let type = "app.musike.track"

    static func copy(_ track: Track, file: URL?) {
        guard let data = try? JSONEncoder().encode(track) else { return }
        var item: [String: Any] = [type: data, UTType.utf8PlainText.identifier: track.title]
        if let file { item[UTType.fileURL.identifier] = file }
        else if let url = URL(string: "https://www.youtube.com/watch?v=\(track.id)") { item[UTType.url.identifier] = url }
        UIPasteboard.general.items = [item]
    }

    static var hasTrack: Bool { UIPasteboard.general.contains(pasteboardTypes: [type]) }

    static func readTrack() -> Track? {
        guard let data = UIPasteboard.general.data(forPasteboardType: type), data.count < 64_000 else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }
}

enum MacTrackFile {
    static func reveal(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let executable = "/usr/bin/open"
            let path = url.withUnsafeFileSystemRepresentation { $0.flatMap { strdup($0) } }
            let arguments = [strdup(executable), strdup("-R"), path]
            defer { arguments.forEach { free($0) } }
            guard arguments.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
            var argv = arguments + [nil]
            var pid: pid_t = 0
            let result = posix_spawn(&pid, executable, nil, nil, &argv, environ)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 {
                if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            guard status == 0 else { throw CocoaError(.fileReadUnknown) }
        }.value
    }

    static func export(_ source: URL, title: String, to folder: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let name = String(title.prefix(60)).components(separatedBy: CharacterSet(charactersIn: "/:").union(.controlCharacters))
                .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            let destination = folder.appendingPathComponent(name.isEmpty ? source.deletingPathExtension().lastPathComponent : name)
                .appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }
}

private enum MacStoreSearch {
    private struct Match: Decodable {
        let artistName: String
        let trackName: String
        let collectionName: String?
        let trackViewUrl: URL
    }

    private struct Response: Decodable { let results: [Match] }

    static func trackURL(for track: Track) async throws -> URL? {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "itunes.apple.com"
        endpoint.path = "/search"
        endpoint.queryItems = [
            URLQueryItem(name: "term", value: [track.title, track.artist].joined(separator: " ")),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: Locale.current.regionCode ?? "US"),
            URLQueryItem(name: "limit", value: "20")
        ]
        guard let url = endpoint.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let artist = normalized(track.artist)
        let artists = tokens(artist)
        let collaboration = track.artist.rangeOfCharacter(from: CharacterSet(charactersIn: ",&/")) != nil
        let title = normalized(track.title)
        let matches = try JSONDecoder().decode(Response.self, from: data).results.filter { result in
            let candidate = normalized(result.artistName)
            return normalized(result.trackName) == title &&
                (artist.isEmpty || candidate == artist || (collaboration && artists.isSubset(of: tokens(candidate))))
        }
        if let album = track.album, let match = matches.first(where: { normalized($0.collectionName ?? "") == normalized(album) }) {
            return match.trackViewUrl
        }
        return matches.first?.trackViewUrl
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(_ value: String) -> Set<String> {
        Set(value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
}
