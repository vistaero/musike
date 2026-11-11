import Foundation
import Combine

// Keeps results when the user returns to Search and limits concurrent catalog requests.
final class BatchSearchModel: ObservableObject {
    struct Entry: Identifiable {
        enum Status { case loading, ready, empty, failed }
        let id = UUID()
        let query: String
        var status: Status = .loading
        var options: [Track] = []
        var pick = 0
        var selected = false
        var track: Track? { options.indices.contains(pick) ? options[pick] : nil }
    }
    typealias Lookup = (String, @escaping (Result<[Track], Error>) -> Void) -> Void
    @Published var text = ""
    @Published private(set) var entries: [Entry] = []
    private var waiting: [UUID] = []
    private var running = 0
    private var generation = 0
    private var lookup: Lookup?
    private let maxConcurrent = 3

    static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased(with: Locale(identifier: "pt_BR"))).inserted }
            .prefix(50).map { $0 }
    }
    var pending: Bool { entries.contains { $0.status == .loading } }
    var allSelected: Bool {
        entries.contains { $0.status == .ready } && entries.allSatisfy { $0.status != .ready || $0.selected }
    }
    var selected: [Track] { tracks(selectedOnly: true) }
    var found: [Track] { tracks(selectedOnly: false) }
    private func tracks(selectedOnly: Bool) -> [Track] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard entry.status == .ready, (!selectedOnly || entry.selected), let track = entry.track,
                  seen.insert(track.id).inserted else { return nil }
            return track
        }
    }
    func run(using engine: NativeEngine) {
        start(text) { [weak engine] query, completion in
            guard let engine else { completion(.failure(NSError(domain: "Musike", code: 1))); return }
            engine.request("search", ["query": query, "kind": "song"], completion: completion)
        }
    }
    func start(_ input: String, lookup: @escaping Lookup) {
        let terms = Self.terms(input)
        guard !terms.isEmpty else { return }
        generation += 1
        self.lookup = lookup
        entries = terms.map { Entry(query: $0) }
        waiting = entries.map(\.id)
        running = 0
        pump()
    }
    func retry(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].status == .failed || entries[index].status == .empty else { return }
        entries[index].status = .loading
        waiting.append(id)
        pump()
    }
    func toggle(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].status == .ready else { return }
        entries[index].selected.toggle()
    }
    func selectAll(_ selected: Bool) {
        for index in entries.indices where entries[index].status == .ready { entries[index].selected = selected }
    }
    func choose(_ option: Int, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].options.indices.contains(option) else { return }
        entries[index].pick = option
        entries[index].selected = true
    }
    private func pump() {
        guard let lookup else { return }
        while running < maxConcurrent && !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let entry = entries.first(where: { $0.id == id }) else { continue }
            running += 1
            let requestGeneration = generation
            lookup(entry.query) { [weak self] result in
                guard let self, self.generation == requestGeneration,
                      let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                self.running -= 1
                switch result {
                case .success(let tracks):
                    self.entries[index].options = Array(tracks.prefix(5))
                    self.entries[index].pick = 0
                    self.entries[index].status = tracks.isEmpty ? .empty : .ready
                    self.entries[index].selected = !tracks.isEmpty
                case .failure:
                    self.entries[index].status = .failed
                    self.entries[index].selected = false
                }
                self.pump()
            }
        }
    }
}

