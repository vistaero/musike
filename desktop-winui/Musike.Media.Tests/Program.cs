using Musike.Core;
using Windows.Media.Core;
using Windows.Media.Playback;
using System.Net;
using System.Net.Http.Headers;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage.Streams;

// A real decoder test, independent of YouTube, networking, profile data, and a visible window.
// Silence keeps the test inaudible while the native audio clock must actually advance.
using var memory = new MemoryStream();
var sampleSeconds = args.Contains("--long") ? 120 : 2;
using (var writer = new BinaryWriter(memory, System.Text.Encoding.UTF8, leaveOpen: true))
{
    var dataLength = 16000 * 2 * sampleSeconds;
    writer.Write("RIFF"u8); writer.Write(dataLength + 36); writer.Write("WAVEfmt "u8);
    writer.Write(16); writer.Write((short)1); writer.Write((short)1);
    writer.Write(16000); writer.Write(32000); writer.Write((short)2); writer.Write((short)16);
    writer.Write("data"u8); writer.Write(dataLength); writer.Write(new byte[dataLength]);
}
memory.Position = 0;
var bytes = memory.ToArray();
var mime = "audio/wav";
var inputIndex = Array.IndexOf(args, "--input");
if (inputIndex >= 0)
{
    var path = args[inputIndex + 1];
    bytes = File.ReadAllBytes(path);
    mime = Path.GetExtension(path).ToLowerInvariant() switch { ".webm" => "audio/webm", ".wav" => "audio/wav", ".mp3" => "audio/mpeg", _ => "audio/mp4" };
}
else if (args.Contains("--aac"))
{
    using var input = memory.AsRandomAccessStream();
    using var encoded = new InMemoryRandomAccessStream();
    var encoder = new MediaTranscoder { HardwareAccelerationEnabled = false };
    var prepared = await encoder.PrepareStreamTranscodeAsync(input, encoded, MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High));
    if (!prepared.CanTranscode) throw new Exception("AAC fixture cannot be encoded: " + prepared.FailureReason);
    await prepared.TranscodeAsync();
    encoded.Seek(0);
    using var reader = new DataReader(encoded.GetInputStreamAt(0));
    bytes = new byte[checked((int)encoded.Size)];
    await reader.LoadAsync((uint)bytes.Length);
    reader.ReadBytes(bytes);
    mime = "audio/mp4";
    Console.WriteLine($"AAC fixture generated: {bytes.Length} bytes.");
}
using var api = new MusikeClient(new Uri("http://127.0.0.1:1234/"), "test-token", new AudioHandler(bytes, mime));
var info = await api.ProbeStreamAsync("aaaaaaaaaaa", false, false);
using var managed = api.CreateMediaStream("aaaaaaaaaaa", false, false, info);
await managed.PrimeAsync();
using var stream = managed.AsRandomAccessStream();
using var source = MediaSource.CreateFromStream(stream, info.ContentType);
var fixtureIndex = Array.IndexOf(args, "--fixture");
if (fixtureIndex >= 0) File.WriteAllBytes(args[fixtureIndex + 1], bytes);
using var player = new MediaPlayer { AutoPlay = false, Volume = inputIndex >= 0 ? 0 : 1 };
player.CommandManager.IsEnabled = false;
var ended = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
var clock = new System.Diagnostics.Stopwatch();
var completion = new PlaybackCompletion();
player.PlaybackSession.PlaybackStateChanged += (sender, args) =>
{
    if (sender.PlaybackState == MediaPlaybackState.Playing) completion.MarkPlaying();
};
player.PlaybackSession.PositionChanged += (sender, args) => completion.Observe(sender.Position.TotalSeconds);
player.MediaFailed += (sender, args) => ended.TrySetException(new Exception(args.Error + ": " + args.ErrorMessage, args.ExtendedErrorCode));
player.MediaEnded += (sender, args) =>
{
    completion.Observe(sender.PlaybackSession.Position.TotalSeconds);
    var duration = sender.PlaybackSession.NaturalDuration.TotalSeconds;
    Console.WriteLine($"Native end: duration={duration:0.###}, elapsed={clock.Elapsed.TotalSeconds:0.###}, position={completion.FurthestPosition:0.###}");
    ended.TrySetResult(Math.Abs(duration - sampleSeconds) <= .1 && completion.CanAdvance(duration) && clock.Elapsed.TotalSeconds >= sampleSeconds * .75);
};
player.Source = source;
clock.Start();
player.Play();
try
{
    if (sampleSeconds > 2 || inputIndex >= 0)
    {
        await Task.Delay(2500);
        var position = player.PlaybackSession.Position.TotalSeconds;
        Console.WriteLine($"Long sample: elapsed={clock.Elapsed.TotalSeconds:0.###}, position={position:0.###}, bytes={bytes.Length}");
        if (ended.Task.IsCompleted || position < .5 || position > 4) throw new Exception("Long compressed audio did not follow real-time playback.");
        Console.WriteLine("PASS Long sample is playing in real time.");
        return 0;
    }
    if (!await ended.Task.WaitAsync(TimeSpan.FromSeconds(15))) throw new Exception("The native decoder ended without completing the two-second audio sample.");
    Console.WriteLine("PASS Authenticated HTTP ranges -> .NET seekable cache -> native MediaPlayer -> complete audio.");
    return 0;
}
catch (Exception error) { Console.Error.WriteLine(error); return 1; }

sealed class AudioHandler(byte[] bytes, string mime) : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        // The production server completes reads asynchronously; synchronous byte fixtures hide adapter races.
        await Task.Delay(35, ct);
        if (request.Headers.GetValues("x-musike-token").Single() != "test-token") throw new Exception("Missing stream authentication.");
        var range = request.Headers.Range!.Ranges.Single();
        var start = (int)range.From!.Value;
        var end = (int)Math.Min(range.To!.Value, bytes.Length - 1);
        var response = new HttpResponseMessage(HttpStatusCode.PartialContent)
        {
            Content = new ByteArrayContent(bytes[start..(end + 1)])
        };
        response.Content.Headers.ContentType = new MediaTypeHeaderValue(mime);
        response.Content.Headers.ContentRange = new ContentRangeHeaderValue(start, end, bytes.Length);
        return response;
    }
}
