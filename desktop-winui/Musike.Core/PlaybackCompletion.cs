namespace Musike.Core;

/// <summary>An empty/aborted stream is an error, not permission to consume the rest of the queue.</summary>
public sealed class PlaybackCompletion
{
    private readonly TimeProvider clock;
    private long playingSince;
    private bool playing;
    private double accumulated;
    private double seekCredit;
    public PlaybackCompletion(TimeProvider? clock = null) => this.clock = clock ?? TimeProvider.System;
    public bool Started { get; private set; }
    public double FurthestPosition { get; private set; }
    public double PlayedSeconds => accumulated + (playing ? clock.GetElapsedTime(playingSince).TotalSeconds : 0);
    public void MarkPlaying() => SetPlaying(true);
    public void SetPlaying(bool value)
    {
        if (playing) accumulated += clock.GetElapsedTime(playingSince).TotalSeconds;
        playing = value;
        playingSince = clock.GetTimestamp();
        Started |= value;
    }
    public void Seek(double from, double to)
    {
        if (double.IsFinite(from) && double.IsFinite(to)) seekCredit += to - from;
    }
    public void Observe(double position)
    {
        if (double.IsFinite(position) && position > FurthestPosition) FurthestPosition = position;
    }
    public bool CanAdvance(double duration)
    {
        if (!Started || FurthestPosition < .01 || PlayedSeconds < .01) return false;
        if (!double.IsFinite(duration) || duration <= 0) return true;
        var tolerance = Math.Min(2, Math.Max(.25, duration * .05));
        return FurthestPosition >= duration - tolerance && PlayedSeconds + seekCredit >= duration - tolerance;
    }
}
