import UIKit
import WebKit

final class LegacyBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var presenter: UIViewController?
    private let session = URLSession(configuration: .ephemeral)
    private let files = FileManager.default
    private let fileQueue = DispatchQueue(label: "app.musike.legacy-files")
    private var downloadProgress: [Int: NSKeyValueObservation] = [:]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url,
              url.scheme == "musike", url.host == "localhost",
              let body = message.body as? [String: Any], let id = body["id"] as? Int,
              let method = body["method"] as? String, let options = body["options"] as? [String: Any] else { return }

        do {
            switch method {
            case "http": try http(options, id: id)
            case "downloadFile": try download(options, id: id)
            case "share": try share(options, id: id)
            default:
                fileQueue.async {
                    do { self.complete(id, result: try self.fileOperation(method, options)) }
                    catch { self.complete(id, error: error) }
                }
            }
        } catch {
            complete(id, error: error)
        }
    }

    private func request(_ options: [String: Any]) throws -> URLRequest {
        guard let link = options["url"] as? String, let url = URL(string: link),
              url.scheme == "https", url.host != nil else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = options["method"] as? String ?? "GET"
        request.httpBody = (options["data"] as? String)?.data(using: .utf8)
        for (name, value) in options["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func http(_ options: [String: Any], id: Int) throws {
        try session.dataTask(with: request(options)) { [weak self] data, response, error in
            if let error { self?.complete(id, error: error); return }
            guard let response = response as? HTTPURLResponse else {
                self?.complete(id, error: URLError(.badServerResponse))
                return
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { values, pair in
                values[String(describing: pair.key)] = String(describing: pair.value)
            }
            self?.complete(id, result: [
                "status": response.statusCode,
                "headers": headers,
                "data": String(decoding: data ?? Data(), as: UTF8.self),
            ])
        }.resume()
    }

    private func download(_ options: [String: Any], id: Int) throws {
        let destination = try file(options)
        let request = try request(options)
        let task = session.downloadTask(with: request) { [weak self] source, response, error in
            guard let self else { return }
            DispatchQueue.main.async { self.downloadProgress.removeValue(forKey: id) }
            do {
                if let error { throw error }
                guard let source, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                try self.fileQueue.sync { try self.files.moveItem(at: source, to: destination) }
                self.complete(id, result: ["path": destination.absoluteString])
            } catch {
                self.complete(id, error: error)
            }
        }
        if options["progress"] as? Bool == true, let url = request.url?.absoluteString {
            downloadProgress[id] = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
                self?.evaluate("__musikeLegacyProgress", arguments: [[
                    "url": url,
                    "bytes": progress.completedUnitCount,
                    "contentLength": progress.totalUnitCount,
                ]])
            }
        }
        task.resume()
    }

    private func file(_ options: [String: Any], path key: String = "path", directory directoryKey: String = "directory") throws -> URL {
        guard let path = options[key] as? String, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), !path.isEmpty else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let location: FileManager.SearchPathDirectory
        switch options[directoryKey] as? String {
        case "DATA": location = .applicationSupportDirectory
        case "CACHE": location = .cachesDirectory
        default: throw CocoaError(.fileReadInvalidFileName)
        }
        let root = try files.url(for: location, in: .userDomainMask, appropriateFor: nil, create: true)
        return root.appendingPathComponent(path)
    }

    private func fileOperation(_ method: String, _ options: [String: Any]) throws -> Any {
        if method == "rename" {
            let source = try file(options, path: "from")
            let destination = try file(options, path: "to", directory: "toDirectory")
            try files.moveItem(at: source, to: destination)
            return [:] as [String: Any]
        }
        let url = try file(options)
        switch method {
        case "readFile":
            guard files.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            return ["data": try String(contentsOf: url, encoding: .utf8)]
        case "writeFile":
            guard let data = options["data"] as? String else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, atomically: true, encoding: .utf8)
            return ["uri": url.absoluteString]
        case "deleteFile":
            try files.removeItem(at: url)
        case "mkdir":
            try files.createDirectory(at: url, withIntermediateDirectories: options["recursive"] as? Bool ?? false)
        case "getUri":
            return ["uri": url.absoluteString]
        case "stat":
            let attributes = try files.attributesOfItem(atPath: url.path)
            return ["size": attributes[.size] as? NSNumber ?? 0]
        default:
            throw CocoaError(.featureUnsupported)
        }
        return [:] as [String: Any]
    }

    private func share(_ options: [String: Any], id: Int) throws {
        guard let presenter, presenter.presentedViewController == nil else { throw CocoaError(.featureUnsupported) }
        let items: [Any] = (options["files"] as? [String] ?? []).compactMap { item -> URL? in
            guard let url = URL(string: item), url.isFileURL,
                  let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  url.deletingLastPathComponent().standardizedFileURL.path == caches.standardizedFileURL.path else { return nil }
            return url
        }
        guard !items.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        sheet.completionWithItemsHandler = { [weak self] activity, _, _, error in
            self?.complete(id, result: ["activityType": activity?.rawValue ?? ""], error: error)
        }
        presenter.present(sheet, animated: true)
    }

    private func complete(_ id: Int, result: Any = NSNull(), error: Error? = nil) {
        if let error {
            let nsError = error as NSError
            var failure = ["message": nsError.localizedDescription]
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                failure["code"] = "OS-PLUG-FILE-0008"
            }
            evaluate("__musikeLegacyReply", arguments: [id, ["error": failure]])
        } else {
            evaluate("__musikeLegacyReply", arguments: [id, ["result": result]])
        }
    }

    private func evaluate(_ function: String, arguments: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("void (window.\(function) && window.\(function).apply(null, \(json)))")
        }
    }
}
