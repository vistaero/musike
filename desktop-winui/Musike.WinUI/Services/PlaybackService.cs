using Microsoft.UI.Dispatching;
using Musike.Core;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace Musike.WinUI.Services;

public sealed class PlaybackService : IDisposable
{
    private readonly MusikeClient api;
    private readonly DispatcherQueue dispatcher;
    private readonly Preferences settings;
    private CancellationTokenSource? load;
    private int generation;
    private bool disposed;
    private double pendingPosition;
    private bool playWhenReady;
    private MediaSource? mediaSource;
    private IRandomAccessStream? mediaStream;
    private HttpMediaStream? httpMediaStream;
    private bool timelineEnabled = true;
    private bool opened;
    private PlaybackCompletion? completion;
    public PlaybackQueue Queue { get; } = new();
    public MediaPlayer? Player { get; private set; }
    public bool IsPlaying => Player?.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;
    public bool Loading { get; private set; }
    public bool WillPlay => Loading && playWhenReady;
    public bool IsVideo { get; private set; }
    public double Position => opened ? Player?.PlaybackSession.Position.TotalSeconds ?? pendingPosition : pendingPosition;
    public double Duration
    {
        get { var duration = Player?.PlaybackSession.NaturalDuration.TotalSeconds ?? 0; return duration > 0 ? duration : Queue.Current?.Duration ?? 0; }
    }
    public event Action? Changed;
    public event Action<MediaPlayer?>? PlayerChanged;
    public event Action<Track>? Started;
    public event Action<string>? Error;

    public PlaybackService(MusikeClient api, DispatcherQueue dispatcher, Preferences settings)
    {
        this.api = api;
        this.dispatcher = dispatcher;
        this.settings = settings;
        Queue.Repeat = settings.Repeat;
        if (settings.QueueState is { Entries: not null } saved) Queue.Restore(saved);
        else Queue.Replace(settings.Queue ?? [], settings.Index);
        pendingPosition = Math.Max(0, settings.Position);
    }
    public async Task PlayAsync(IEnumerable<Track> tracks, int index = 0)
    {
        Queue.Replace(tracks, index);
        await LoadAsync();
    }
    public Task JumpAsync(int index) => Queue.Jump(index) ? LoadAsync() : Task.CompletedTask;
    public async Task LoadAsync(bool autoplay = true, double position = 0)
    {
        if (Queue.Current is not { } track || disposed) return;
        // A failed or cancelled prepare must never leave the previous song attached to the new queue entry.
        Stop();
        load?.Cancel();
        load?.Dispose();
        load = new CancellationTokenSource();
        var ct = load.Token;
        var mine = ++generation;
        pendingPosition = position;
        playWhenReady = autoplay;
        Loading = true;
        Changed?.Invoke();
        try
        {
            DiagnosticLog.Write("playback", $"Preparing id={track.Id}, video={settings.Video}, hd={settings.Hd}");
            var media = track;
            var videoMode = false;
            if (settings.Video)
            {
                if (track.Kind == "video") videoMode = true;
                else if (await api.VideoForAsync(track, ct) is { } video) { media = video; videoMode = true; }
            }
            await api.PrepareAsync(media.Id, videoMode, ct);
            var stream = await api.ProbeStreamAsync(media.Id, videoMode, settings.Hd, ct);
            if (ct.IsCancellationRequested || mine != generation || disposed) return;
            DiagnosticLog.Write("playback", $"Stream id={media.Id}, mime={stream.ContentType}, bytes={stream.Length}");
            var managedStream = api.CreateMediaStream(media.Id, videoMode, settings.Hd, stream);
            httpMediaStream = managedStream;
            await managedStream.PrimeAsync(ct);
            if (ct.IsCancellationRequested || mine != generation || disposed) { managedStream.Dispose(); return; }
            Stream decoderInput = managedStream;
            if (!videoMode && stream.ContentType == "audio/mp4" && await DashAudio.IsFragmentedAsync(managedStream, ct))
            {
                decoderInput = await DashAudio.RemuxAsync(managedStream, api, ct);
                managedStream.Dispose();
                DiagnosticLog.Write("playback", "Fragmented MP4 remuxed for native playback.");
            }
            if (ct.IsCancellationRequested || mine != generation || disposed) { decoderInput.Dispose(); return; }
            var nativeStream = decoderInput.AsRandomAccessStream();
            mediaStream = nativeStream;
            DiagnosticLog.Write("playback", $"Decoder input ready, bytes={nativeStream.Size}.");
            IsVideo = videoMode;
            var next = new MediaPlayer { AutoPlay = false, Volume = Math.Clamp(settings.Volume, 0, 1), IsMuted = settings.Muted };
            Player = next;
            timelineEnabled = true;
            DiagnosticLog.Write("playback", "Native player created.");
            next.CommandManager.IsEnabled = false;
            var controls = next.SystemMediaTransportControls;
            controls.IsEnabled = true;
            controls.IsPlayEnabled = true;
            controls.IsPauseEnabled = true;
            controls.IsNextEnabled = true;
            controls.IsPreviousEnabled = true;
            controls.DisplayUpdater.Type = MediaPlaybackType.Music;
            controls.DisplayUpdater.MusicProperties.Title = track.Title;
            controls.DisplayUpdater.MusicProperties.Artist = track.Artist;
            controls.DisplayUpdater.MusicProperties.AlbumTitle = track.Album ?? "";
            if (Uri.TryCreate(track.Artwork, UriKind.Absolute, out var art) && art.Scheme == "https")
                controls.DisplayUpdater.Thumbnail = RandomAccessStreamReference.CreateFromUri(art);
            controls.DisplayUpdater.Update();
            DiagnosticLog.Write("playback", "Windows media controls configured.");
            controls.ButtonPressed += (sender, e) => DispatchAsync(async () =>
            {
                if (mine != generation || disposed) return;
                await HandleMediaButtonAsync(e.Button);
            });
            controls.PlaybackPositionChangeRequested += (_, e) => Dispatch(() =>
            {
                if (mine == generation && !disposed) Seek(e.RequestedPlaybackPosition.TotalSeconds, "system");
            });
            var recorded = false;
            var ended = false;
            var progress = new PlaybackCompletion();
            completion = progress;
            next.PlaybackSession.PositionChanged += (sender, args) =>
            {
                // Capture the value before dispatch: Windows may reset Position when the UI processes an ended event.
                double observed;
                try { observed = sender.Position.TotalSeconds; }
                catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ObjectDisposedException) { return; }
                Dispatch(() => { if (mine == generation && !disposed) progress.Observe(observed); });
            };
            next.MediaOpened += (_, _) => Dispatch(() =>
            {
                if (mine != generation || disposed) return;
                Loading = false;
                opened = true;
                DiagnosticLog.Write("playback", $"Opened id={media.Id}, duration={next.PlaybackSession.NaturalDuration.TotalSeconds:0.###}, canSeek={next.PlaybackSession.CanSeek}, rate={next.PlaybackSession.PlaybackRate:0.###}");
                if (position > 0) Seek(position, "resume");
                if (playWhenReady) next.Play(); else next.Pause();
                Changed?.Invoke();
            });
            next.MediaFailed += (_, e) => Dispatch(() =>
            {
                if (mine != generation || disposed) return;
                var transportError = managedStream.LastError;
                Fail(transportError?.Message ?? ("No se puede reproducir este archivo. " + e.ErrorMessage), transportError ?? e.ExtendedErrorCode);
            });
            next.MediaEnded += (_, _) => Dispatch(() =>
            {
                if (mine != generation || disposed || ended) return;
                ended = true;
                progress.Observe(next.PlaybackSession.Position.TotalSeconds);
                var duration = next.PlaybackSession.NaturalDuration.TotalSeconds;
                if (duration <= 0) duration = media.Duration;
                DiagnosticLog.Write("playback", $"Ended id={media.Id}, played={progress.Started}, secondsPlayed={progress.PlayedSeconds:0.###}, furthest={progress.FurthestPosition:0.###}, duration={duration:0.###}");
                if (progress.CanAdvance(duration)) _ = NextAsync(automatic: true);
                else
                {
                    Fail(managedStream.LastError?.Message ?? "El flujo de audio terminó antes de completar la canción. Vuelve a intentarlo; la cola se ha detenido para evitar saltos continuos.", managedStream.LastError);
                }
            });
            next.PlaybackSession.PlaybackStateChanged += (sender, args) =>
            {
                MediaPlaybackState state;
                try { state = sender.PlaybackState; }
                catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ObjectDisposedException) { return; }
                Dispatch(() =>
                {
                    if (mine != generation || disposed) return;
                    var playing = state == MediaPlaybackState.Playing;
                    controls.PlaybackStatus = playing ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
                    progress.SetPlaying(playing);
                    if (playing && !recorded) { recorded = true; Started?.Invoke(track); }
                    Changed?.Invoke();
                });
            };
            PlayerChanged?.Invoke(next);
            // Give Media Foundation an opened, seekable stream and the actual MIME type. The reference-based
            // factory can report an immediate end/not-supported result without delivering decoded audio.
            mediaSource = MediaSource.CreateFromStream(nativeStream, stream.ContentType);
            next.Source = mediaSource;
            // Request playback explicitly; MediaOpened applies any pending seek and the latest pause intent.
            if (playWhenReady) next.Play();
            else Loading = false;
            DiagnosticLog.Write("playback", $"Source assigned, playRequested={playWhenReady}.");
            Changed?.Invoke();
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception e)
        {
            if (mine != generation || disposed) return;
            Fail(e.Message, e);
        }
    }
    private void Dispatch(Action action) => dispatcher.TryEnqueue(() =>
    {
        if (disposed) return;
        try { action(); }
        catch (Exception error) { Fail(error.Message, error); }
    });
    private void DispatchAsync(Func<Task> action) => dispatcher.TryEnqueue(async () =>
    {
        if (disposed) return;
        try { await action(); }
        catch (Exception error) { Fail(error.Message, error); }
    });
    private void Fail(string message, Exception? error = null)
    {
        DiagnosticLog.Write("playback-error", message, error);
        Stop();
        Error?.Invoke(message);
    }
    private async Task HandleMediaButtonAsync(SystemMediaTransportControlsButton button)
    {
        switch (button)
        {
            case SystemMediaTransportControlsButton.Play:
                if (Loading) { playWhenReady = true; if (Player?.Source is not null) Player.Play(); Changed?.Invoke(); break; }
                if (Player is null) await LoadAsync(position: pendingPosition); else Player.Play(); break;
            case SystemMediaTransportControlsButton.Pause: playWhenReady = false; Player?.Pause(); Changed?.Invoke(); break;
            case SystemMediaTransportControlsButton.Next: await NextAsync(); break;
            case SystemMediaTransportControlsButton.Previous: await PreviousAsync(); break;
        }
    }
    public async Task ToggleAsync()
    {
        if (Loading)
        {
            playWhenReady = !playWhenReady;
            if (Player?.Source is not null) { if (playWhenReady) Player.Play(); else Player.Pause(); }
            Changed?.Invoke();
            return;
        }
        if (Player is null) { await LoadAsync(position: pendingPosition); return; }
        if (IsPlaying) Player.Pause(); else Player.Play();
    }
    public async Task NextAsync(bool automatic = false)
    {
        if (Queue.Next(automatic)) { await LoadAsync(); return; }
        if (automatic && settings.AutoRadio && Queue.Current is { } track)
        {
            var mine = generation;
            var index = Queue.Index;
            try
            {
                var tracks = await api.RadioAsync(track.Id);
                if (mine != generation || disposed || Queue.Index != index) return;
                var known = Queue.Tracks.Select(t => t.Id).ToHashSet();
                foreach (var t in tracks.Where(t => known.Add(t.Id))) Queue.Add(t);
                if (Queue.Next()) await LoadAsync();
            }
            catch (Exception e) { if (mine == generation && !disposed) Error?.Invoke(e.Message); }
        }
        Changed?.Invoke();
    }
    public Task PreviousAsync()
    {
        if (Position > 3 || !Queue.Previous()) { Seek(0); return Task.CompletedTask; }
        return LoadAsync();
    }
    public void Seek(double seconds, string origin = "user")
    {
        if (Player is not null && Player.PlaybackSession.CanSeek)
        {
            var target = Math.Clamp(double.IsFinite(seconds) ? seconds : 0, 0, Math.Max(0, Duration));
            DiagnosticLog.Write("seek", $"origin={origin}, requested={seconds:0.###}, current={Position:0.###}, duration={Duration:0.###}, rate={Player.PlaybackSession.PlaybackRate:0.###}");
            completion?.Seek(Position, target);
            Player.PlaybackSession.Position = TimeSpan.FromSeconds(target);
        }
    }
    public void SetVolume(double value) { settings.Volume = Math.Clamp(value, 0, 1); if (Player is not null) Player.Volume = settings.Volume; }
    public void UpdateSystemTimeline()
    {
        if (Player is null || Loading || Duration <= 0 || !timelineEnabled) return;
        try
        {
            Player.SystemMediaTransportControls.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
            {
                StartTime = TimeSpan.Zero, EndTime = TimeSpan.FromSeconds(Duration),
                MinSeekTime = TimeSpan.Zero, MaxSeekTime = TimeSpan.FromSeconds(Duration),
                Position = TimeSpan.FromSeconds(Math.Clamp(Position, 0, Duration))
            });
        }
        catch (Exception error)
        {
            timelineEnabled = false;
            DiagnosticLog.Write("media-timeline", "Windows media timeline unavailable; audio playback continues.", error);
        }
    }
    public void ToggleMute() { settings.Muted = !settings.Muted; if (Player is not null) Player.IsMuted = settings.Muted; Changed?.Invoke(); }
    public void Shuffle() { Queue.ToggleShuffle(); Changed?.Invoke(); }
    public void CycleRepeat() { Queue.Repeat = (RepeatMode)(((int)Queue.Repeat + 1) % 3); settings.Repeat = Queue.Repeat; Changed?.Invoke(); }
    public void Add(Track t, bool next = false) { Queue.Add(t, next); Changed?.Invoke(); }
    public async Task RemoveAsync(int index)
    {
        var current = index == Queue.Index;
        Queue.Remove(index);
        if (current)
        {
            if (Queue.Current is not null) await LoadAsync();
            else Stop();
        }
        Changed?.Invoke();
    }
    public void Snapshot()
    {
        settings.Queue = [.. Queue.Tracks];
        settings.QueueState = Queue.Snapshot();
        settings.Index = Queue.Index;
        settings.Position = Position;
    }
    public void Stop()
    {
        ++generation;
        load?.Cancel();
        Loading = false;
        opened = false;
        completion = null;
        IsVideo = false;
        var previous = Player;
        var previousSource = mediaSource;
        var previousStream = mediaStream;
        var previousHttpStream = httpMediaStream;
        Player = null;
        mediaSource = null;
        mediaStream = null;
        httpMediaStream = null;
        // Abort HTTP reads before disposing MediaPlayer, which may wait for a pending decoder read.
        previousHttpStream?.Dispose();
        try { PlayerChanged?.Invoke(null); }
        catch (Exception error) { DiagnosticLog.Write("playback-stop", "Could not detach video renderer.", error); }
        try { previous?.Dispose(); }
        catch (Exception error) { DiagnosticLog.Write("playback-stop", "Could not release player.", error); }
        try { previousSource?.Dispose(); }
        catch (Exception error) { DiagnosticLog.Write("playback-stop", "Could not release media source.", error); }
        try { previousStream?.Dispose(); }
        catch (Exception error) { DiagnosticLog.Write("playback-stop", "Could not release media stream.", error); }
        Changed?.Invoke();
    }
    public void Dispose() { disposed = true; Stop(); load?.Dispose(); }
}
