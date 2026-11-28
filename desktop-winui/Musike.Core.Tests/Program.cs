using System.Net;
using System.Text.Json;
using Musike.Core;

var passed = 0;
void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
async Task Test(string name, Func<Task> action) { await action(); Console.WriteLine("PASS " + name); passed++; }
Task Sync(Action action) { action(); return Task.CompletedTask; }
Track Track(string id) => new() { Id = id, Title = id, Artist = "Artist", Duration = 185, Kind = "song" };
var a = Track("aaaaaaaaaaa"); var b = Track("bbbbbbbbbbb"); var c = Track("ccccccccccc");

await Test("Explicit Next escapes repeat-one; automatic completion repeats", () => Sync(() =>
{
    var q = new PlaybackQueue { Repeat = RepeatMode.One };
    q.Replace([a, b]);
    Check(q.Next(true) && q.Index == 0, "Automatic next must repeat current.");
    Check(q.Next() && q.Current == b, "Manual next must advance.");
    Check(!q.Next(), "Repeat one must not wrap manual next.");
}));
await Test("Shuffle restores the exact duplicate entry and preserves mutations", () => Sync(() =>
{
    var first = a with { Title = "first" }; var second = a with { Title = "second" };
    var q = new PlaybackQueue();
    q.Replace([first, b, second, c], 2);
    q.ToggleShuffle(new Random(7));
    Check(q.Index == 0 && q.Current == second, "Shuffle changed the current duplicate.");
    q.Add(b with { Title = "inserted" }, next: true);
    var remove = q.Tracks.ToList().FindIndex(x => x == first);
    q.Remove(remove);
    q.ToggleShuffle();
    Check(q.Current == second && q.Index == 1, "Unshuffle lost the current entry.");
    Check(q.Tracks.Select(x => x.Title).SequenceEqual(new[] { b.Title, "second", "inserted", c.Title }), "Edits were lost when restoring order.");
}));
await Test("Restart restores shuffled order and the exact duplicate entry", () => Sync(() =>
{
    var q = new PlaybackQueue(); q.Replace([a, a with { Title = "duplicate" }, b, c], 1);
    q.ToggleShuffle(new Random(3)); q.Add(c with { Title = "new" }, true);
    var persisted = JsonSerializer.Deserialize<QueueSnapshot>(JsonSerializer.Serialize(q.Snapshot(), Json.Options), Json.Options)!;
    var restored = new PlaybackQueue(); restored.Restore(persisted);
    Check(restored.Shuffled && restored.Current?.Title == "duplicate", "Shuffle state did not survive restart.");
    Check(restored.Tracks.SequenceEqual(q.Tracks), "Restored shuffle changed order.");
    restored.ToggleShuffle();
    Check(restored.Index == 1 && restored.Tracks.Select(t => t.Title).SequenceEqual(new[] { a.Title, "duplicate", "new", b.Title, c.Title }), "Unshuffle after restart lost edits or duplicate identity.");
}));
await Test("Removing the current and earlier entries keeps the queue valid", () => Sync(() =>
{
    var q = new PlaybackQueue(); q.Replace([a, b, c], 1);
    q.Remove(0); Check(q.Current == b && q.Index == 0, "Earlier removal changed playback.");
    q.Remove(0); Check(q.Current == c, "Removing current should select its successor.");
    q.Remove(0); Check(q.Current is null && q.Index == -1 && !q.Next(), "Empty queue has a current item.");
    q.Add(a, true); Check(q.Current == a, "Adding into an empty queue failed.");
}));
await Test("Clear upcoming while shuffled also clears the restored order", () => Sync(() =>
{
    var q = new PlaybackQueue(); q.Replace([a, b, c], 1); q.ToggleShuffle(new Random(1));
    q.ClearUpcoming(); q.ToggleShuffle();
    Check(q.Tracks.Count == 1 && q.Current == b, "Unshuffle resurrected cleared items.");
}));
await Test("Repeat-all wraps in both directions; empty and invalid jumps are safe", () => Sync(() =>
{
    var q = new PlaybackQueue { Repeat = RepeatMode.All }; q.Replace([a, b], 1);
    Check(q.Next() && q.Current == a, "Next did not wrap.");
    Check(q.Previous() && q.Current == b, "Previous did not wrap.");
    Check(!q.Jump(99) && q.Current == b, "Invalid jump changed index.");
    q.Replace([]); q.ToggleShuffle(); q.ToggleShuffle(); Check(q.Current is null, "Empty shuffle failed.");
}));
await Test("An empty or prematurely ended stream cannot consume the playback queue", () => Sync(() =>
{
    var clock = new TestClock();
    var progress = new PlaybackCompletion(clock);
    Check(!progress.CanAdvance(282), "An ended event without playback advanced the queue.");
    progress.MarkPlaying(); progress.Observe(0);
    Check(!progress.CanAdvance(282), "An empty stream advanced the queue.");
    progress.Observe(.05);
    Check(!progress.CanAdvance(282), "A truncated stream advanced the queue.");
    progress.Observe(281.9);
    clock.Advance(281.9);
    Check(progress.CanAdvance(282), "A completed track did not advance.");
    progress.Observe(double.NaN); progress.Observe(-1);
    Check(progress.CanAdvance(282), "Invalid timing corrupted completion state.");
    var unknown = new PlaybackCompletion(clock); unknown.MarkPlaying(); unknown.Observe(20); clock.Advance(20);
    Check(unknown.CanAdvance(0), "A played stream with unknown duration could not finish.");
}));
await Test("A native clock jump to the end cannot skip a song without real playback time", () => Sync(() =>
{
    var clock = new TestClock();
    var progress = new PlaybackCompletion(clock);
    progress.MarkPlaying(); clock.Advance(.3); progress.Observe(180);
    Check(!progress.CanAdvance(180), "A three-minute track completed in 300 ms.");
    progress.SetPlaying(false); clock.Advance(1000);
    Check(!progress.CanAdvance(180), "Paused time counted as playback.");
    progress.SetPlaying(true); clock.Advance(179.7);
    Check(progress.CanAdvance(180), "Actual playback time was lost across a pause.");
}));
await Test("Explicit seeks and resumed positions are accounted for when completing a track", () => Sync(() =>
{
    var clock = new TestClock();
    var progress = new PlaybackCompletion(clock);
    progress.Seek(0, 170); progress.MarkPlaying(); clock.Advance(10); progress.Observe(180);
    Check(progress.CanAdvance(180), "Resuming near the end required replaying the whole song.");
    var seeking = new PlaybackCompletion(clock); seeking.MarkPlaying(); clock.Advance(10);
    seeking.Seek(10, 179); clock.Advance(1); seeking.Observe(180);
    Check(seeking.CanAdvance(180), "An explicit forward seek could not finish normally.");
}));
await Test("Media preflight uses a bounded authenticated range and exposes the actual content type", async () =>
{
    using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "secret", new FakeHandler(request =>
    {
        Check(request.Headers.Range?.ToString() == "bytes=0-1023", "Preflight did not bound its range.");
        Check(request.Headers.GetValues("x-musike-token").Single() == "secret" && request.RequestUri!.Query.Contains("token=secret"), "Native stream credentials are missing.");
        var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(new byte[16]) };
        response.Content.Headers.ContentType = new("audio/mp4");
        response.Content.Headers.ContentRange = new(0, 15, 12000000);
        return Task.FromResult(response);
    }));
    var stream = await api.ProbeStreamAsync(a.Id, false, false);
    Check(stream.ContentType == "audio/mp4" && stream.Length == 12000000, "Media metadata was inferred from the route instead of the response.");
});
await Test("Seekable HTTP media crosses chunks, seeks backwards and returns the correct EOF", async () =>
{
    var bytes = Enumerable.Range(0, 900000).Select(i => (byte)(i % 251)).ToArray();
    var fetched = new List<long>();
    using var stream = new HttpMediaStream(bytes.Length, (start, count, ct) =>
    {
        fetched.Add(start);
        return Task.FromResult(bytes.AsSpan((int)start, count).ToArray());
    });
    await stream.PrimeAsync();
    var buffer = new byte[600000];
    Check(await stream.ReadAsync(buffer) == buffer.Length && buffer.SequenceEqual(bytes.Take(buffer.Length)), "Cross-chunk read was corrupted.");
    stream.Seek(-20, SeekOrigin.End);
    var tail = new byte[30];
    Check(stream.Read(tail, 0, tail.Length) == 20 && tail.Take(20).SequenceEqual(bytes.TakeLast(20)), "Tail seek did not preserve byte offsets.");
    Check(stream.Read(tail, 0, tail.Length) == 0, "EOF must return zero.");
    var requests = fetched.Count;
    stream.Position = 100;
    Check(await stream.ReadAsync(tail) == tail.Length && tail.SequenceEqual(bytes.Skip(100).Take(tail.Length)), "Backward seek returned incorrect audio.");
    Check(fetched.Count == requests, "A cached seek made an unnecessary request.");
});
await Test("Closing a media source cancels an in-flight decoder read", async () =>
{
    var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    using var stream = new HttpMediaStream(100, async (start, count, ct) =>
    {
        entered.TrySetResult();
        await Task.Delay(Timeout.InfiniteTimeSpan, ct);
        return [];
    });
    var read = stream.ReadAsync(new byte[10]).AsTask();
    await entered.Task;
    stream.Dispose();
    try { await read.WaitAsync(TimeSpan.FromSeconds(2)); throw new Exception("Closing the source left the decoder waiting."); }
    catch (OperationCanceledException) { }
});
await Test("HTTP media reads keep authentication and never accept a wrong byte position", async () =>
{
    using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "secret", new FakeHandler(request =>
    {
        Check(request.Headers.GetValues("x-musike-token").Single() == "secret", "Range read lost credentials.");
        var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(new byte[32]) };
        response.Content.Headers.ContentType = new("audio/mp4");
        response.Content.Headers.ContentRange = new(1, 32, 33);
        return Task.FromResult(response);
    }));
    using var stream = api.CreateMediaStream(a.Id, false, false, new("audio/mp4", 33));
    try { var received = await stream.ReadAsync(new byte[10]); throw new Exception($"Accepted {received} audio bytes from a mismatched range."); }
    catch (InvalidDataException) { }
    Check(stream.LastError is InvalidDataException, "The decoder's real network error was lost.");
});
await Test("Truncated media chunks report an error instead of fabricating EOF", async () =>
{
    using var stream = new HttpMediaStream(100, (start, count, ct) => Task.FromResult(new byte[3]));
    try { var received = await stream.ReadAsync(new byte[10]); throw new Exception($"Truncated media silently returned {received} bytes."); }
    catch (EndOfStreamException) { }
});
await Test("Empty audio and HTML/JSON success responses are rejected before native playback", async () =>
{
    foreach (var mime in new[] { "audio/mp4", "application/json", "text/html" })
    {
        using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "secret", new FakeHandler(request =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(mime == "audio/mp4" ? [] : new byte[16]) };
            response.Content.Headers.ContentType = new(mime);
            return Task.FromResult(response);
        }));
        try { await api.ProbeStreamAsync(a.Id, false, false); throw new Exception("Invalid media was accepted: " + mime); }
        catch (InvalidDataException) { }
    }
});
await Test("Stream HTTP errors preserve the engine's message instead of silently skipping", async () =>
{
    using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "secret", new FakeHandler(request => Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
    { Content = new StringContent("{\"error\":\"YouTube rejected this stream\",\"code\":\"maybe_outdated\"}") })));
    try { await api.ProbeStreamAsync(a.Id, false, false); throw new Exception("Expected stream error."); }
    catch (MusikeApiException error) { Check(error.Status == 502 && error.Code == "maybe_outdated" && error.Message == "YouTube rejected this stream", "Stream error details were lost."); }
});
await Test("Diagnostic logs redact stream URLs and capability tokens", () => Sync(() =>
{
    var temp = Path.Combine(Path.GetTempPath(), "musike-core-test-" + Guid.NewGuid());
    try
    {
        DiagnosticLog.Initialize(temp);
        var token = new string('a', 64);
        DiagnosticLog.Write("test", "GET http://127.0.0.1:4000/api/stream/audio?token=" + token + " standalone=" + token);
        var log = File.ReadAllText(Path.Combine(temp, "logs", "application.log"));
        Check(!log.Contains(token) && !log.Contains("http://"), "Sensitive stream credentials entered the log.");
    }
    finally { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
}));
await Test("API calls encode searches, send credentials and use the server contract", async () =>
{
    var requests = new List<(string Method, string Uri, string Body)>();
    using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "secret", new FakeHandler(async request =>
    {
        Check(request.Headers.GetValues("x-musike-token").Single() == "secret", "Missing capability header.");
        Check(request.Headers.GetValues("x-musike-lang").Single() == "es-ES", "Missing language header.");
        var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync();
        requests.Add((request.Method.Method, request.RequestUri!.AbsoluteUri, body));
        var json = request.Method == HttpMethod.Get ? "{\"tracks\":[]}" : "{\"id\":\"p\",\"name\":\"test\",\"createdAt\":0,\"updatedAt\":0,\"tracks\":[]}";
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json) };
    }));
    await api.SearchAsync("猫 & rock?", "song");
    Check(requests[0].Uri.Contains("%26") && requests[0].Uri.Contains("%3F"), "Search leaked query separators.");
    await api.CreatePlaylistAsync("test", [a]);
    Check(requests[1].Method == "POST" && requests[1].Uri.EndsWith("/api/playlists"), "Wrong playlist route.");
    using var payload = JsonDocument.Parse(requests[1].Body);
    Check(payload.RootElement.GetProperty("tracks")[0].GetProperty("id").GetString() == a.Id, "Track payload incompatible.");
    var stream = api.StreamUri(a.Id, true, true);
    Check(stream.Query.Contains("q=hd") && stream.Query.Contains("token=secret"), "Media Foundation URI lacks authentication.");
});
await Test("HTTP failures keep the engine's actionable error code", async () =>
{
    using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "secret", new FakeHandler(request => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
    { Content = new StringContent("{\"error\":\"Install yt-dlp\",\"code\":\"tool_missing\"}") })));
    try { await api.LibraryAsync(); throw new Exception("Expected API failure."); }
    catch (MusikeApiException e) { Check(e.Status == 503 && e.Code == "tool_missing" && e.Message == "Install yt-dlp", "Lost engine error details."); }
});
await Test("204 playlist deletion does not try to decode JSON", async () =>
{
    using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "secret", new FakeHandler(request => Task.FromResult(new HttpResponseMessage(HttpStatusCode.NoContent))));
    await api.DeletePlaylistAsync("playlist-id");
});
await Test("Client rejects remote engines", () => Sync(() =>
{
    try { using var api = new MusikeClient(new Uri("https://example.com/"), "secret"); throw new Exception("Accepted a remote engine."); }
    catch (ArgumentException) { }
}));
await Test("Migration copies once, makes a backup, and never touches Electron", () => Sync(() =>
{
    var temp = Path.Combine(Path.GetTempPath(), "musike-core-test-" + Guid.NewGuid());
    try
    {
        var legacy = Path.Combine(temp, "electron"); var native = Path.Combine(temp, "winui");
        Directory.CreateDirectory(Path.Combine(legacy, "data"));
        var source = Path.Combine(legacy, "data", "library.json");
        var content = JsonSerializer.Serialize(new Library([a], [], []), Json.Options);
        File.WriteAllText(source, content);
        var store = new ProfileStore(native); store.Initialize(legacy);
        var target = Path.Combine(native, "data", "library.json");
        Check(File.ReadAllText(target) == content, "Library was not copied.");
        Check(File.Exists(Path.Combine(native, "backups", "electron-before-winui.json")), "Migration backup missing.");
        File.WriteAllText(target, "native-changes"); store.Initialize(legacy);
        Check(File.ReadAllText(target) == "native-changes" && File.ReadAllText(source) == content, "Migration overwrote an existing library.");
        store.Save(new Preferences { Queue = [a, b], Index = 1, Position = 123, Volume = .4 });
        var saved = store.Load(); Check(saved.Queue[1].Id == b.Id && saved.Position == 123 && saved.Volume == .4, "Resume state did not round-trip.");
    }
    finally { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
}));
await Test("Invalid legacy data is surfaced without marking migration complete", () => Sync(() =>
{
    var temp = Path.Combine(Path.GetTempPath(), "musike-core-test-" + Guid.NewGuid());
    try
    {
        var legacy = Path.Combine(temp, "electron"); var native = Path.Combine(temp, "winui");
        Directory.CreateDirectory(Path.Combine(legacy, "data"));
        File.WriteAllText(Path.Combine(legacy, "data", "library.json"), "not json");
        try { new ProfileStore(native).Initialize(legacy); throw new Exception("Invalid library was silently accepted."); }
        catch (JsonException) { }
        Check(!File.Exists(Path.Combine(native, "migration-v1.json")), "Failed migration was marked successful.");
    }
    finally { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
}));
Console.WriteLine($"{passed} tests passed.");

sealed class FakeHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
}

sealed class TestClock : TimeProvider
{
    private long timestamp;
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public override long GetTimestamp() => timestamp;
    public void Advance(double seconds) => timestamp += TimeSpan.FromSeconds(seconds).Ticks;
}
