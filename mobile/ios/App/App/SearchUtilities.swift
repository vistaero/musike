import Foundation

enum SearchUtilities {
    static func youtubeID(_ text: String) -> String? {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        let candidate: String?
        if host == "youtu.be" { candidate = url.path.split(separator: "/").first.map(String.init) }
        else if let value = url.queryItems?.first(where: { $0.name == "v" })?.value { candidate = value }
        else {
            let parts = url.path.split(separator: "/")
            candidate = parts.count > 1 && parts[0] == "shorts" ? String(parts[1]) : nil
        }
        guard let candidate, candidate.count >= 11 else { return nil }
        let id = String(candidate.prefix(11))
        return id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil ? id : nil
    }
}
