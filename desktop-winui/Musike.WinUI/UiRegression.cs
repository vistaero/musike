#if DEBUG
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Musike.Core;

namespace Musike.WinUI;

// Exercises the real MainWindow, its timer and its PlaybackService. No input automation or live server is used.
internal static class UiRegression
{
    internal static async Task RunAsync(App app)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("MUSIKE_WINUI_DATA_DIR")))
                throw new InvalidOperationException("UI regression requires an isolated MUSIKE_WINUI_DATA_DIR.");
            var fixture = Environment.GetEnvironmentVariable("MUSIKE_WINUI_REGRESSION_AUDIO");
            var audio = fixture is not null ? File.ReadAllBytes(fixture) : Wave();
            var mime = fixture is not null ? "audio/mp4" : "audio/wav";
            using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "regression", new Handler(audio, mime));
            var window = new MainWindow(api);
            window.AppWindow.Move(new Windows.Graphics.PointInt32(-32000, -32000));
            window.AppWindow.Show(false);
            var premature = Environment.GetEnvironmentVariable("MUSIKE_WINUI_REGRESSION_PREMATURE") == "1";
            await window.ExerciseRegressionAsync(fixture is not null, premature).WaitAsync(TimeSpan.FromSeconds(15));
            DiagnosticLog.Write("ui-regression", "PASS actual window, blank genre artwork, timer and real-time native audio.");
            Environment.Exit(0);
        }
        catch (Exception error)
        {
            DiagnosticLog.Write("ui-regression", "FAIL", error);
            Environment.Exit(1);
        }
    }
    private static byte[] Wave()
    {
        using var memory = new MemoryStream();
        using var writer = new BinaryWriter(memory);
        var length = 16000 * 2 * 2;
        writer.Write("RIFF"u8); writer.Write(length + 36); writer.Write("WAVEfmt "u8);
        writer.Write(16); writer.Write((short)1); writer.Write((short)1); writer.Write(16000);
        writer.Write(32000); writer.Write((short)2); writer.Write((short)16); writer.Write("data"u8);
        writer.Write(length); writer.Write(new byte[length]);
        return memory.ToArray();
    }
    private sealed class Handler(byte[] audio, string mime) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.Contains("/stream/"))
            {
                await Task.Delay(35, ct);
                var range = request.Headers.Range!.Ranges.Single();
                var start = (int)range.From!.Value;
                var end = (int)Math.Min(range.To!.Value, audio.Length - 1);
                var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(audio[start..(end + 1)]) };
                response.Content.Headers.ContentType = new MediaTypeHeaderValue(mime);
                response.Content.Headers.ContentRange = new ContentRangeHeaderValue(start, end, audio.Length);
                return response;
            }
            object body = path switch
            {
                "/api/library" => Library.Empty,
                "/api/genres" => new { genres = new[] { new Genre("regression", "Genre without artwork") } },
                "/api/history" => new { history = Array.Empty<Track>() },
                _ when path.Contains("/prepare/") => new Prepared("aaaaaaaaaaa", "Native regression", 2, false),
                _ => new { }
            };
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(body, Json.Options)) };
        }
    }
}

public sealed partial class MainWindow
{
    internal async Task ExerciseRegressionAsync(bool longFixture, bool premature)
    {
        if (!await regressionReady.Task) throw new Exception("MainWindow failed to initialize.");
        settings.Volume = 0;
        settings.AutoRadio = false;
        await NavigateAsync("genres");
        Root.UpdateLayout();
        await Task.Delay(250);
        // Reproduce the progress-bar transition between a finished long song and a new short song.
        updating = true;
        SeekSlider.Maximum = 180;
        SeekSlider.Value = 180;
        updating = false;
        var done = new TaskCompletionSource<double>(TaskCreationOptions.RunContinuationsAsynchronously);
        var failure = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var clock = Stopwatch.StartNew();
        playback!.Error += message => { failure.TrySetResult(message); if (!premature) done.TrySetException(new Exception(message)); };
        playback.PlayerChanged += player =>
        {
            if (player is not null)
            {
                player.MediaEnded += (sender, args) => done.TrySetResult(clock.Elapsed.TotalSeconds);
                if (premature) player.MediaOpened += (sender, args) =>
                {
                    // Simulate Windows jumping its clock to the end, without granting explicit seek credit.
                    sender.PlaybackSession.Position = TimeSpan.FromSeconds(sender.PlaybackSession.NaturalDuration.TotalSeconds - .05);
                };
            }
        };
        await playback.PlayAsync(new[] {
            new Track { Id = "aaaaaaaaaaa", Title = "Native regression", Duration = 2 },
            new Track { Id = "bbbbbbbbbbb", Title = "Next regression track", Duration = 2 }
        });
        if (premature)
        {
            await failure.Task.WaitAsync(TimeSpan.FromSeconds(8));
            await Task.Delay(500);
            if (playback.Queue.Index != 0 || playback.Player is not null)
                throw new Exception("A premature native end advanced the queue instead of stopping.");
            DiagnosticLog.Write("ui-regression", "PASS premature native end stopped on the same track.");
            return;
        }
        if (longFixture)
        {
            await Task.Delay(2500);
            if (done.Task.IsFaulted) await done.Task;
            var position = playback.Position;
            DiagnosticLog.Write("ui-regression", $"Long audio: elapsed={clock.Elapsed.TotalSeconds:0.###}, position={position:0.###}, playing={playback.IsPlaying}");
            if (done.Task.IsCompleted || !playback.IsPlaying || position < .5 || position > 4)
                throw new Exception("The real window did not play long AAC audio in real time.");
            // Updating the display, even outside the timer's old 'updating' flag, must never seek.
            SeekSlider.Maximum = playback.Duration;
            SeekSlider.Value = playback.Duration;
            await Task.Delay(300);
            if (done.Task.IsCompleted || playback.Position > 5)
                throw new Exception("A programmatic progress-bar refresh sought to the end.");
            BeginSeek();
            SeekSlider.Value = playback.Duration - .5;
            CommitSeek();
        }
        var elapsed = await done.Task;
        DiagnosticLog.Write("ui-regression", $"Ended after {elapsed:0.###} seconds.");
        if (elapsed < 1.5) throw new Exception("The UI consumed two seconds of audio faster than real time.");
        await Task.Delay(150);
        if (playback.Queue.Index != 1) throw new Exception("A normally completed track did not advance the queue.");
    }
}
#endif
