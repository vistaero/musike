using System.Net.Http.Json;
using System.Text.Json;

namespace Musike.Core;

public sealed class MusikeApiException(int status, string message, string? code) : Exception(message)
{
    public int Status { get; } = status;
    public string? Code { get; } = code;
}

/// <summary>The same HTTP contract as web/src/lib/api.ts. Owns no UI or playback state.</summary>
public sealed class MusikeClient : IDisposable
{
    private readonly HttpClient http;
    private readonly string token;
    public string Language { get; set; } = "es-ES";
    public Uri BaseAddress => http.BaseAddress!;

    public MusikeClient(Uri address, string token, HttpMessageHandler? handler = null)
    {
        if (!address.IsLoopback || address.Scheme != "http") throw new ArgumentException("The local engine must use loopback HTTP.");
        this.token = token;
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.BaseAddress = address;
        http.Timeout = TimeSpan.FromMinutes(5);
    }

    public async Task<T> RequestAsync<T>(HttpMethod method, string route, object? body = null, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(method, route);
        request.Headers.Add("x-musike-token", token);
        request.Headers.Add("x-musike-lang", Language);
        if (body is not null) request.Content = JsonContent.Create(body, options: Json.Options);
        using var response = await http.SendAsync(request, ct);
        if (!response.IsSuccessStatusCode)
        {
            var message = $"HTTP {(int)response.StatusCode}";
            string? code = null;
            try
            {
                var error = await response.Content.ReadFromJsonAsync<JsonElement>(Json.Options, ct);
                if (error.TryGetProperty("error", out var text)) message = text.GetString() ?? message;
                if (error.TryGetProperty("code", out var value)) code = value.GetString();
            }
            catch (JsonException) { }
            throw new MusikeApiException((int)response.StatusCode, message, code);
        }
        if (response.StatusCode == System.Net.HttpStatusCode.NoContent) return default!;
        return await response.Content.ReadFromJsonAsync<T>(Json.Options, ct) ?? throw new JsonException("Empty engine response.");
    }

    private async Task<T> FieldAsync<T>(string route, string field, CancellationToken ct = default)
    {
        var json = await RequestAsync<JsonElement>(HttpMethod.Get, route, ct: ct);
        return json.GetProperty(field).Deserialize<T>(Json.Options)!;
    }
    public static string Escape(string value) => Uri.EscapeDataString(value);
    private static string TrackQuery(Track t) => $"title={Escape(t.Title)}&artist={Escape(t.Artist)}&album={Escape(t.Album ?? "")}&duration={t.Duration.ToString(System.Globalization.CultureInfo.InvariantCulture)}";
    public Task<Library> LibraryAsync() => RequestAsync<Library>(HttpMethod.Get, "api/library");
    public Task<List<Track>> SearchAsync(string query, string kind, CancellationToken ct = default) => FieldAsync<List<Track>>($"api/search?q={Escape(query)}&type={Escape(kind)}", "tracks", ct);
    public Task<List<string>> SuggestAsync(string query, CancellationToken ct = default) => FieldAsync<List<string>>($"api/suggest?q={Escape(query)}", "suggestions", ct);
    public Task<List<Track>> RadioAsync(string id, CancellationToken ct = default) => FieldAsync<List<Track>>($"api/radio/{Escape(id)}", "tracks", ct);
    public Task<List<Genre>> GenresAsync(CancellationToken ct = default) => FieldAsync<List<Genre>>("api/genres", "genres", ct);
    public Task<GenrePage> GenreAsync(string id, CancellationToken ct = default) => RequestAsync<GenrePage>(HttpMethod.Get, $"api/genres/{Escape(id)}", ct: ct);
    public Task<JsonElement> GenreArtistsAsync(string id, int offset, CancellationToken ct = default) => RequestAsync<JsonElement>(HttpMethod.Get, $"api/genres/{Escape(id)}/artists?offset={offset}", ct: ct);
    public Task<ArtistPage> ArtistAsync(string id, CancellationToken ct = default) => RequestAsync<ArtistPage>(HttpMethod.Get, $"api/artists/{Escape(id)}", ct: ct);
    public Task<AlbumPage> AlbumAsync(string id, CancellationToken ct = default) => RequestAsync<AlbumPage>(HttpMethod.Get, $"api/albums/{Escape(id)}", ct: ct);
    public Task<List<AlbumCard>> SearchAlbumsAsync(string query, CancellationToken ct = default) => FieldAsync<List<AlbumCard>>($"api/search/albums?q={Escape(query)}", "albums", ct);
    public Task<Track?> VideoForAsync(Track t, CancellationToken ct = default) => FieldAsync<Track?>($"api/video-for/{Escape(t.Id)}?{TrackQuery(t)}", "track", ct);
    public Task<Lyrics?> LyricsAsync(Track t, CancellationToken ct = default) => FieldAsync<Lyrics?>($"api/lyrics/{Escape(t.Id)}?{TrackQuery(t)}", "lyrics", ct);
    public Task<Prepared> PrepareAsync(string id, bool video, CancellationToken ct = default) => RequestAsync<Prepared>(HttpMethod.Post, $"api/prepare/{Escape(id)}?kind={(video ? "video" : "audio")}", ct: ct);
    public Uri StreamUri(string id, bool video, bool hd) => new(BaseAddress, $"api/stream/{Escape(id)}/{(video ? "video" : "audio")}?q={(hd ? "hd" : "sd")}&token={Escape(token)}");
    public async Task<MediaStreamInfo> ProbeStreamAsync(string id, bool video, bool hd, CancellationToken ct = default)
    {
        // Surface the engine's JSON error before handing the stream to Media Foundation, which hides HTTP details.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(5));
        using var request = new HttpRequestMessage(HttpMethod.Get, StreamUri(id, video, hd));
        request.Headers.Add("x-musike-token", token);
        request.Headers.Add("x-musike-lang", Language);
        request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, 1023);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        if (!response.IsSuccessStatusCode)
        {
            var message = $"HTTP {(int)response.StatusCode}";
            string? code = null;
            try
            {
                var error = await response.Content.ReadFromJsonAsync<JsonElement>(Json.Options, deadline.Token);
                if (error.TryGetProperty("error", out var value)) message = value.GetString() ?? message;
                if (error.TryGetProperty("code", out value)) code = value.GetString();
            }
            catch (JsonException) { }
            throw new MusikeApiException((int)response.StatusCode, message, code);
        }
        var mime = response.Content.Headers.ContentType?.MediaType ?? "";
        if (!mime.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) && !mime.StartsWith("video/", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("El servidor no ha devuelto audio o vídeo reproducible.");
        using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
        var prefix = new byte[16];
        if (await stream.ReadAtLeastAsync(prefix, 8, throwOnEndOfStream: false, deadline.Token) < 8)
            throw new InvalidDataException("El servidor ha devuelto un archivo de audio vacío o incompleto.");
        return new MediaStreamInfo(mime, response.Content.Headers.ContentRange?.Length ?? response.Content.Headers.ContentLength);
    }
    public HttpMediaStream CreateMediaStream(string id, bool video, bool hd, MediaStreamInfo info)
    {
        if (info.Length is not > 0) throw new InvalidDataException("No se ha podido consultar el tamaño del audio.");
        var uri = StreamUri(id, video, hd);
        return new HttpMediaStream(info.Length.Value, async (start, count, ct) =>
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(TimeSpan.FromSeconds(30));
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.Add("x-musike-token", token);
            request.Headers.Add("x-musike-lang", Language);
            request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(start, start + count - 1);
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                throw new IOException($"El servidor no ha podido entregar el audio (HTTP {(int)response.StatusCode}).");
            if (response.StatusCode == System.Net.HttpStatusCode.PartialContent)
            {
                if (response.Content.Headers.ContentRange?.From != start)
                    throw new InvalidDataException("El servidor ha devuelto una posición de audio incorrecta.");
            }
            else if (start != 0) throw new InvalidDataException("El servidor no admite el avance y retroceso del audio.");
            var mime = response.Content.Headers.ContentType?.MediaType;
            if (mime is not null && !mime.Equals(info.ContentType, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("El servidor ha cambiado el formato del audio durante la reproducción.");
            using var body = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
            var buffer = new byte[count];
            var read = await body.ReadAtLeastAsync(buffer, count, throwOnEndOfStream: false, deadline.Token).ConfigureAwait(false);
            if (read != count) throw new EndOfStreamException("La conexión ha interrumpido el audio antes de completar la descarga.");
            return buffer;
        });
    }
    public Task<JsonElement> FavoriteAsync(Track t, bool add) => RequestAsync<JsonElement>(add ? HttpMethod.Put : HttpMethod.Delete, $"api/favorites/{Escape(t.Id)}", add ? t : null);
    public Task<JsonElement> AddFavoritesAsync(IEnumerable<Track> tracks) => RequestAsync<JsonElement>(HttpMethod.Post, "api/favorites", new { tracks });
    public Task<JsonElement> HistoryAsync(Track t) => RequestAsync<JsonElement>(HttpMethod.Post, "api/history", t);
    public Task<Playlist> CreatePlaylistAsync(string name, IEnumerable<Track>? tracks = null) => RequestAsync<Playlist>(HttpMethod.Post, "api/playlists", new { name, tracks = tracks ?? [] });
    public Task<Playlist> RenamePlaylistAsync(string id, string name) => RequestAsync<Playlist>(HttpMethod.Patch, $"api/playlists/{Escape(id)}", new { name });
    public Task<JsonElement> DeletePlaylistAsync(string id) => RequestAsync<JsonElement>(HttpMethod.Delete, $"api/playlists/{Escape(id)}");
    public Task<Playlist> AddToPlaylistAsync(string id, IEnumerable<Track> tracks) => RequestAsync<Playlist>(HttpMethod.Post, $"api/playlists/{Escape(id)}/tracks", new { tracks });
    public Task<Playlist> RemoveFromPlaylistAsync(string id, string track) => RequestAsync<Playlist>(HttpMethod.Delete, $"api/playlists/{Escape(id)}/tracks/{Escape(track)}");
    public Task<ImportResult> ImportAsync(JsonElement backup, bool replace) => RequestAsync<ImportResult>(HttpMethod.Post, "api/library/import", new { backup, mode = replace ? "replace" : "merge" });
    public Task<JsonElement> SystemAsync() => RequestAsync<JsonElement>(HttpMethod.Get, "api/system");
    public Task<JsonElement> UpdateAsync(string channel) => RequestAsync<JsonElement>(HttpMethod.Post, "api/system/ytdlp", new { channel });
    public void Dispose() => http.Dispose();
}
