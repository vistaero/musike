using System.Text.Json;

namespace Musike.Core;

public sealed class Preferences
{
    public string Language { get; set; } = "es-ES";
    public string Theme { get; set; } = "system";
    public double Volume { get; set; } = .8;
    public bool Muted { get; set; }
    public bool Video { get; set; }
    public bool Hd { get; set; }
    public bool AutoRadio { get; set; } = true;
    public RepeatMode Repeat { get; set; }
    public List<Track> Queue { get; set; } = [];
    public QueueSnapshot? QueueState { get; set; }
    public int Index { get; set; }
    public double Position { get; set; }
    public int Width { get; set; } = 1280;
    public int Height { get; set; } = 820;
}

public sealed class ProfileStore
{
    public string Root { get; }
    private string SettingsFile => Path.Combine(Root, "preferences.json");
    public ProfileStore(string? root = null) => Root = root ?? Environment.GetEnvironmentVariable("MUSIKE_WINUI_DATA_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusikeWinUI");

    // Copy once into an independent profile; Electron and WinUI must never write the same library.
    public void Initialize(string? legacyRoot = null)
    {
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(Path.Combine(Root, "data"));
        var marker = Path.Combine(Root, "migration-v1.json");
        if (File.Exists(marker)) return;
        var target = Path.Combine(Root, "data", "library.json");
        var legacy = Path.Combine(legacyRoot ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Musike"), "data", "library.json");
        if (!File.Exists(target) && File.Exists(legacy))
        {
            // Validate before copying. Failed migration is surfaced and can be retried, never silently discarded.
            var text = File.ReadAllText(legacy);
            using var data = JsonDocument.Parse(text);
            foreach (var key in new[] { "favorites", "playlists", "history" })
                if (data.RootElement.GetProperty(key).ValueKind != JsonValueKind.Array) throw new JsonException("Invalid Electron library.");
            Directory.CreateDirectory(Path.Combine(Root, "backups"));
            File.Copy(legacy, Path.Combine(Root, "backups", "electron-before-winui.json"), true);
            File.Copy(legacy, target, false);
        }
        File.WriteAllText(marker, JsonSerializer.Serialize(new { migratedAt = DateTimeOffset.UtcNow, sourceFound = File.Exists(legacy) }, Json.Options));
    }
    public Preferences Load()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(SettingsFile), Json.Options) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException) { return new(); }
    }
    public void Save(Preferences value)
    {
        Directory.CreateDirectory(Root);
        var temp = SettingsFile + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, Json.Options));
        File.Move(temp, SettingsFile, true);
    }
}
