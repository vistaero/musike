import Network
import UIKit
import WebKit
#if !MUSIKE_LEGACY
import Combine
#endif

/// A bounded local trace containing playback events and error codes, never track names or stream URLs.
final class PlaybackDiagnostics: NSObject, WKScriptMessageHandler {
    static let shared = PlaybackDiagnostics()
    #if !MUSIKE_LEGACY
    @Published private(set) var networkUnavailable = false
    #endif
    private let queue = DispatchQueue(label: "app.musike.playback-diagnostics")
    private let pathMonitor = NWPathMonitor()
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("playback-diagnostics.log")
    private var lines: [String]?
    private let limit = 600
    private override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.record(Self.describe(path))
            #if !MUSIKE_LEGACY
            let unavailable = path.status != .satisfied
            DispatchQueue.main.async { self?.networkUnavailable = unavailable }
            #endif
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
        let constrained: Bool
        if #available(iOS 13.0, *) { constrained = path.isConstrained }
        else { constrained = false }
        return "network.path type=\(connection) state=\(state) expensive=\(path.isExpensive) constrained=\(constrained)"
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

#if !MUSIKE_LEGACY
extension PlaybackDiagnostics: ObservableObject {}
#endif
