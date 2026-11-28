namespace Musike.Core;

public enum RepeatMode { Off, All, One }
public sealed record QueueEntry(Guid Key, Track Track);
public sealed record QueueSnapshot(List<QueueEntry> Entries, List<QueueEntry>? Original, int Index);

/// <summary>Queue entries have identities independent of video IDs (duplicates are valid).</summary>
public sealed class PlaybackQueue
{
    private List<QueueEntry> entries = [];
    private List<QueueEntry>? original;
    public IReadOnlyList<Track> Tracks => entries.Select(x => x.Track).ToArray();
    public int Index { get; private set; } = -1;
    public Track? Current => Index >= 0 && Index < entries.Count ? entries[Index].Track : null;
    public bool Shuffled => original is not null;
    public RepeatMode Repeat { get; set; }

    public void Replace(IEnumerable<Track> tracks, int start = 0)
    {
        entries = tracks.Select(t => new QueueEntry(Guid.NewGuid(), t)).ToList();
        original = null;
        Index = entries.Count == 0 ? -1 : Math.Clamp(start, 0, entries.Count - 1);
    }
    public bool Jump(int index)
    {
        if (index < 0 || index >= entries.Count) return false;
        Index = index;
        return true;
    }
    public bool Next(bool automatic = false)
    {
        if (Current is null) return false;
        if (automatic && Repeat == RepeatMode.One) return true;
        if (Index + 1 < entries.Count) { Index++; return true; }
        if (Repeat == RepeatMode.All) { Index = 0; return true; }
        return false;
    }
    public bool Previous()
    {
        if (Index > 0) { Index--; return true; }
        if (entries.Count > 0 && Repeat == RepeatMode.All) { Index = entries.Count - 1; return true; }
        return false;
    }
    public void Add(Track track, bool next = false)
    {
        var entry = new QueueEntry(Guid.NewGuid(), track);
        var position = next && Index >= 0 ? Index + 1 : entries.Count;
        entries.Insert(position, entry);
        if (original is not null)
        {
            var current = Index >= 0 ? entries[Index].Key : Guid.Empty;
            var originalIndex = original.FindIndex(e => e.Key == current);
            original.Insert(next && originalIndex >= 0 ? originalIndex + 1 : original.Count, entry);
        }
        if (Index < 0) Index = 0;
    }
    public void Remove(int index)
    {
        if (index < 0 || index >= entries.Count) return;
        var key = entries[index].Key;
        entries.RemoveAt(index);
        original?.RemoveAll(e => e.Key == key);
        if (index < Index) Index--;
        Index = entries.Count == 0 ? -1 : Math.Min(Index, entries.Count - 1);
    }
    public void ClearUpcoming()
    {
        var kept = entries.Take(Index + 1).ToList();
        var keys = kept.Select(e => e.Key).ToHashSet();
        entries = kept;
        original?.RemoveAll(e => !keys.Contains(e.Key));
    }
    public void ToggleShuffle(Random? random = null)
    {
        var current = Index >= 0 ? entries[Index].Key : Guid.Empty;
        if (original is null)
        {
            original = [.. entries];
            var upcoming = entries.Where(e => e.Key != current).ToArray();
            (random ?? Random.Shared).Shuffle(upcoming);
            entries = current == Guid.Empty ? [.. upcoming] : [entries[Index], .. upcoming];
        }
        else { entries = original; original = null; }
        Index = entries.FindIndex(e => e.Key == current);
    }
    public QueueSnapshot Snapshot() => new([.. entries], original is null ? null : [.. original], Index);
    public void Restore(QueueSnapshot snapshot)
    {
        // Recover ordinary playback even if an older/corrupt shuffle snapshot cannot be restored.
        entries = snapshot.Entries.Where(e => e.Track is not null).DistinctBy(e => e.Key).ToList();
        var keys = entries.Select(e => e.Key).ToHashSet();
        original = snapshot.Original is { } saved && saved.Count == keys.Count && saved.Select(e => e.Key).ToHashSet().SetEquals(keys)
            ? saved.Select(e => entries.First(item => item.Key == e.Key)).ToList() : null;
        Index = entries.Count == 0 ? -1 : Math.Clamp(snapshot.Index, 0, entries.Count - 1);
    }
}
