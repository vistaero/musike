import AVFoundation
import Combine
import Foundation
import UIKit

/// A Mac's own collection. Imported audio is copied into application support;
/// local source records remain available to playlists even after removing a song
/// from the collection. The original file is never moved or modified.
@MainActor
final class MacMusicLibrary: ObservableObject {
    static let shared = MacMusicLibrary()
    struct LocalFile: Codable {
        let filename: String
        let artwork: String?
    }
    struct AlbumInfo: Codable, Equatable {
        let id: String
        let title: String
        let artist: String
        let position: Int?
    }
    private struct Contents: Codable {
        var tracks: [Track] = []
        var localFiles: [String: LocalFile] = [:]
        var albumInfo: [String: [AlbumInfo]] = [:]
        var migratedLegacy = false
        enum CodingKeys: String, CodingKey { case tracks, localFiles, albumInfo, migratedLegacy }
        init(tracks: [Track] = [], localFiles: [String: LocalFile] = [:], albumInfo: [String: [AlbumInfo]] = [:], migratedLegacy: Bool = false) {
            self.tracks = tracks; self.localFiles = localFiles; self.albumInfo = albumInfo; self.migratedLegacy = migratedLegacy
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
            localFiles = try c.decodeIfPresent([String: LocalFile].self, forKey: .localFiles) ?? [:]
            albumInfo = try c.decodeIfPresent([String: [AlbumInfo]].self, forKey: .albumInfo) ?? [:]
            migratedLegacy = try c.decodeIfPresent(Bool.self, forKey: .migratedLegacy) ?? false
        }
    }
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var importing = false
    @Published var error: String?
    private var localFiles: [String: LocalFile] = [:]
    private(set) var albumInfo: [String: [AlbumInfo]] = [:]
    private var migratedLegacy = false
    private var damagedLibrary = false
    private let artworkCache = NSCache<NSString, UIImage>()
    private let directory: URL
    private var indexFile: URL { directory.appendingPathComponent("library.json") }

    private init() {
        directory = MacInstanceLock.applicationDirectory
        if FileManager.default.fileExists(atPath: indexFile.path) {
            do {
                let saved = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: indexFile))
                tracks = saved.tracks
                localFiles = saved.localFiles
                albumInfo = saved.albumInfo
                migratedLegacy = saved.migratedLegacy
            } catch {
                damagedLibrary = true
                self.error = "The Musike Native library could not be read. Its files have been left untouched."
            }
        }
    }
    private func canWrite() -> Bool {
        guard !damagedLibrary else {
            error = "The Musike Native library could not be read. Its files have been left untouched."
            return false
        }
        return true
    }
    func contains(_ id: String) -> Bool { tracks.contains { $0.id == id } }
    func localURL(_ id: String) -> URL? {
        guard let entry = localFiles[id] else { return nil }
        return directory.appendingPathComponent(entry.filename)
    }
    func artwork(_ id: String) -> UIImage? {
        guard let file = localFiles[id]?.artwork else { return nil }
        if let cached = artworkCache.object(forKey: id as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(file).path) else { return nil }
        artworkCache.setObject(image, forKey: id as NSString)
        return image
    }
    func add(_ items: [Track]) {
        guard canWrite() else { return }
        var ids = Set(tracks.map(\.id))
        let added = items.compactMap(Self.sanitize).filter { ids.insert($0.id).inserted }
        guard !added.isEmpty else { return }
        tracks.insert(contentsOf: added, at: 0)
        persist()
    }
    func addAlbum(id: String, title: String, artist: String, tracks items: [Track]) {
        guard canWrite() else { return }
        for (position, track) in items.enumerated() {
            let info = AlbumInfo(id: id, title: title, artist: artist, position: position)
            var existing = albumInfo[track.id] ?? []
            existing.removeAll { $0.id == id }
            existing.append(info)
            albumInfo[track.id] = existing
        }
        let previous = tracks.count
        add(items)
        if tracks.count == previous { tracks = Array(tracks); persist() }
    }
    func remove(_ id: String) {
        guard canWrite() else { return }
        tracks.removeAll { $0.id == id }
        // Keep the copied file if a favorite, playlist or queue still refers to it.
        persist()
    }
    func migrateLegacy(_ library: LibraryState) {
        guard library.status == "ready", !migratedLegacy, canWrite() else { return }
        migratedLegacy = true
        add(library.favorites + library.playlists.flatMap(\.tracks))
        persist()
    }
    var onlineTracks: [Track] { tracks.filter { localFiles[$0.id] == nil } }
    var onlineAlbumInfo: [String: [AlbumInfo]] { albumInfo.filter { localFiles[$0.key] == nil } }
    func restoreOnline(_ restored: [Track], albums: [String: [AlbumInfo]], replace: Bool) {
        guard canWrite() else { return }
        if replace { tracks = tracks.filter { localFiles[$0.id] != nil } }
        if replace { albumInfo = albumInfo.filter { localFiles[$0.key] != nil } }
        let clean = restored.compactMap(Self.sanitize).filter { localFiles[$0.id] == nil }
        let validIDs = Set(clean.map(\.id))
        let safeAlbums = albums.filter { validIDs.contains($0.key) }.mapValues { entries in
            entries.filter { $0.id.range(of: "^MPRE[\\w-]{6,60}$", options: .regularExpression) != nil }
                .map { AlbumInfo(id: $0.id, title: String($0.title.prefix(300)), artist: String($0.artist.prefix(300)), position: $0.position) }
        }
        albumInfo.merge(safeAlbums) { old, new in old + new.filter { info in !old.contains(where: { $0.id == info.id }) } }
        add(clean)
        tracks = Array(tracks)
        persist()
    }
    private static func sanitize(_ track: Track) -> Track? {
        guard track.id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        func safeURL(_ value: String) -> String { value.hasPrefix("https://") ? String(value.prefix(500)) : "" }
        return Track(id: track.id, title: String(track.title.prefix(300)), artist: String(track.artist.prefix(300)),
                     album: track.album.map { String($0.prefix(300)) }, duration: track.duration.isFinite ? max(0, track.duration) : 0,
                     thumb: safeURL(track.thumb), art: safeURL(track.art), kind: track.kind == "video" ? "video" : "song")
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Contents(tracks: tracks, localFiles: localFiles, albumInfo: albumInfo, migratedLegacy: migratedLegacy))
            try data.write(to: indexFile, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) {
        guard !importing, !urls.isEmpty, canWrite() else { return }
        importing = true
        Task {
            var failures: [String] = []
            for url in urls {
                do { try await importFile(url) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            importing = false
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    private func importFile(_ source: URL) async throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var id: String
        repeat { id = "L_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9) }
        while localFiles[id] != nil || tracks.contains(where: { $0.id == id })
        let extensionName = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let filename = "\(id).\(extensionName)"
        let destination = directory.appendingPathComponent(filename)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
        do {
            let asset = AVURLAsset(url: destination)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { throw NSError(domain: "Musike", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio track found."]) }
            let length = try await asset.load(.duration).seconds
            let metadata = try await asset.load(.commonMetadata)
            var title = source.deletingPathExtension().lastPathComponent
            var artist = ""
            var album: String?
            var artworkFile: String?
            for item in metadata {
                switch item.commonKey?.rawValue {
                case AVMetadataKey.commonKeyTitle.rawValue: title = (try? await item.load(.stringValue)) ?? title
                case AVMetadataKey.commonKeyArtist.rawValue: artist = (try? await item.load(.stringValue)) ?? artist
                case AVMetadataKey.commonKeyAlbumName.rawValue: album = try? await item.load(.stringValue)
                case AVMetadataKey.commonKeyArtwork.rawValue:
                    if let data = try? await item.load(.dataValue), let image = UIImage(data: data) {
                        let name = "\(id).jpg"
                        let scale = min(1, 600 / max(image.size.width, image.size.height))
                        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
                        let thumbnail = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                        if let jpeg = thumbnail.jpegData(compressionQuality: 0.8) {
                            try? jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
                            artworkFile = name
                        }
                    }
                default: break
                }
            }
            let track = Track(id: id, title: title, artist: artist, album: album,
                              duration: length.isFinite ? max(0, length) : 0, thumb: "", art: "", kind: "song")
            localFiles[id] = LocalFile(filename: filename, artwork: artworkFile)
            tracks.insert(track, at: 0)
            persist()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
