import Foundation

// Small stand-ins let these tests exercise the production model without the app or a live service.
struct Track: Equatable { let id: String }
final class NativeEngine {
    func request(_ action: String, _ args: [String: Any], completion: @escaping (Result<[Track], Error>) -> Void) {}
}

final class FakeSearch {
    typealias Completion = (Result<[Track], Error>) -> Void
    var calls: [String] = []
    var pending: [String: Completion] = [:]
    var maximum = 0
    func lookup(_ query: String, _ completion: @escaping Completion) {
        calls.append(query)
        pending[query] = completion
        maximum = max(maximum, pending.count)
    }
    func finish(_ query: String, _ result: Result<[Track], Error>) {
        guard let completion = pending.removeValue(forKey: query) else { fatalError("Missing request: \(query)") }
        completion(result)
    }
}

@main struct BatchSearchChecks {
    static func main() {
        expect(SearchUtilities.youtubeID("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=2") == "dQw4w9WgXcQ", "accept YouTube watch links")
        expect(SearchUtilities.youtubeID("https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ", "accept short YouTube links")
        expect(SearchUtilities.youtubeID("https://music.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ", "accept Shorts links")
        expect(SearchUtilities.youtubeID("https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ") == nil, "reject unrelated hosts")
        expect(SearchUtilities.youtubeID("https://youtu.be/too-short") == nil, "reject invalid identifiers")
        expect(BatchSearchModel.terms(" A, b\n a, ,B, C ") == ["A", "b", "C"], "trim and deduplicate input")
        expect(BatchSearchModel.terms((0..<60).map(String.init).joined(separator: ",")).count == 50, "limit input to 50 terms")

        let model = BatchSearchModel(), search = FakeSearch()
        model.start("first, second, third, fourth", lookup: search.lookup)
        expect(search.calls == ["first", "second", "third"], "start at most three requests")
        search.finish("second", .failure(NSError(domain: "test", code: 1)))
        expect(search.calls == ["first", "second", "third", "fourth"] && search.maximum == 3, "start next after a failure")
        search.finish("third", .success([Track(id: "shared")]))
        search.finish("first", .success([Track(id: "shared"), Track(id: "alternate")]))
        search.finish("fourth", .success([]))
        expect(model.found.map(\.id) == ["shared"], "remove duplicate matches")
        let first = model.entries[0].id
        model.choose(1, for: first)
        expect(model.selected.map(\.id) == ["alternate", "shared"], "choose a different match")
        model.selectAll(false)
        expect(model.selected.isEmpty && !model.allSelected, "deselect all")
        model.selectAll(true)
        expect(model.allSelected && model.selected.count == 2, "select all found matches")
        let failed = model.entries[1].id
        model.retry(failed)
        search.finish("second", .success([Track(id: "retried")]))
        expect(model.entries[1].track?.id == "retried" && model.entries[1].selected, "retry a failed term")
        let empty = model.entries[3].id
        model.retry(empty)
        search.finish("fourth", .success([Track(id: "found")]))
        expect(model.entries[3].track?.id == "found", "retry an empty result")

        model.start("old", lookup: search.lookup)
        model.start("new", lookup: search.lookup)
        search.finish("old", .success([Track(id: "stale")]))
        expect(model.entries[0].query == "new" && model.entries[0].status == .loading, "ignore results from an older run")
        search.finish("new", .success([Track(id: "fresh")]))
        expect(model.selected.map(\.id) == ["fresh"], "keep the current run's results")
        print("Batch search checks passed")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
