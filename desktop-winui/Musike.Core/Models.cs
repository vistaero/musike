using System.Text.Json;
using System.Text.Json.Serialization;

namespace Musike.Core;

public sealed record Track
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public string Artist { get; init; } = "";
    public string? Album { get; init; }
    public double Duration { get; init; }
    public string Thumb { get; init; } = "";
    public string Art { get; init; } = "";
    public string Kind { get; init; } = "song";
    // Native queue rows need distinct identities even when the same track appears more than once.
    [JsonIgnore] public Guid RowKey { get; init; }
    [JsonIgnore] public string DurationText => TimeSpan.FromSeconds(Math.Max(0, Duration)).ToString(Duration >= 3600 ? @"h\:mm\:ss" : @"m\:ss");
    [JsonIgnore] public string Artwork => string.IsNullOrEmpty(Art) ? Thumb : Art;
}

public sealed record Playlist(string Id, string Name, long CreatedAt, long UpdatedAt, List<Track> Tracks);
public sealed record Library(List<Track> Favorites, List<Playlist> Playlists, List<Track> History)
{
    public static Library Empty => new([], [], []);
}
public sealed record Genre(string Id, string Name);
public sealed record BrowseCard(string Id, string Label, string Caption, string Artwork, string Kind);
public sealed record GenreArtist(string Id, string Name, string Thumb, string Art, List<string> Hits);
public sealed record GenrePage(string Id, string Name, List<GenreArtist> Artists, bool HasMoreArtists, List<Track> Tracks);
public sealed record ArtistPage(string Id, string Name, string Description, string Banner, List<Track> Tracks, List<AlbumCard> Albums, List<AlbumCard> Singles);
public sealed record AlbumCard(string Id, string Title, string Artist, string Year, string Thumb, string Art);
public sealed record AlbumPage(string Id, string Title, string Artist, string? ArtistId, string Kind, string Info, string Thumb, string Art, List<Track> Tracks);
public sealed record LyricLine(double Time, string Text);
public sealed record Lyrics(bool Synced, bool Instrumental, List<LyricLine> Lines, double? SourceDuration, string Source);
public sealed record ImportResult(int PlaylistsAdded, int PlaylistsMerged, int TracksAdded, int FavoritesAdded);
public sealed record Prepared(string Id, string Title, double Duration, bool HasSdVideo);
public sealed record MediaStreamInfo(string ContentType, long? Length);

public static class Json
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = true };
}
