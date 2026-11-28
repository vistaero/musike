using System.Buffers.Binary;
using System.Diagnostics;
using System.Text.Json;
using Musike.Core;

namespace Musike.WinUI.Services;

internal static class DashAudio
{
    public static async Task<bool> IsFragmentedAsync(Stream source, CancellationToken ct)
    {
        var header = new byte[(int)Math.Min(65536, source.Length)];
        await source.ReadExactlyAsync(header, ct);
        source.Position = 0;
        return ContainsFragments(header);
    }

    private static bool ContainsFragments(ReadOnlySpan<byte> boxes)
    {
        while (boxes.Length >= 8)
        {
            var size = BinaryPrimitives.ReadUInt32BigEndian(boxes);
            var type = boxes.Slice(4, 4);
            if (type.SequenceEqual("moof"u8) || type.SequenceEqual("mvex"u8)) return true;
            if (size < 8 || size > boxes.Length) break;
            var payload = boxes.Slice(8, (int)size - 8);
            if (type.SequenceEqual("moov"u8) && ContainsFragmentsInMovie(payload)) return true;
            if (type.SequenceEqual("ftyp"u8))
                for (var i = 0; i + 4 <= payload.Length; i += 4)
                    if (i != 4 && payload.Slice(i, 4).SequenceEqual("dash"u8)) return true;
            boxes = boxes[(int)size..];
        }
        return false;
    }

    private static bool ContainsFragmentsInMovie(ReadOnlySpan<byte> children)
    {
        while (children.Length >= 8)
        {
            var size = BinaryPrimitives.ReadUInt32BigEndian(children);
            if (size < 8 || size > children.Length) return false;
            if (children.Slice(4, 4).SequenceEqual("mvex"u8)) return true;
            children = children[(int)size..];
        }
        return false;
    }

    public static async Task<FileStream> RemuxAsync(Stream source, MusikeClient api, CancellationToken ct)
    {
        var bin = Path.Combine(new ProfileStore().Root, "bin");
        var ffmpeg = Path.Combine(bin, "ffmpeg", "ffmpeg.exe");
        if (!File.Exists(ffmpeg) && !File.Exists(Path.Combine(bin, "ffmpeg.exe")))
            await api.RequestAsync<JsonElement>(HttpMethod.Post, "api/native/tools", ct: ct);
        if (!File.Exists(ffmpeg)) ffmpeg = Path.Combine(bin, "ffmpeg.exe");
        var output = Path.Combine(Path.GetTempPath(), $"musike-{Guid.NewGuid():N}.m4a");
        var start = new ProcessStartInfo(ffmpeg)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardError = true
        };
        foreach (var arg in new[] { "-nostdin", "-v", "error", "-protocol_whitelist", "pipe", "-f", "mov", "-i", "pipe:0",
            "-map", "0:a:0", "-c:a", "copy", "-f", "mp4", "-n", output }) start.ArgumentList.Add(arg);
        using var process = Process.Start(start) ?? throw new IOException("No se ha podido iniciar FFmpeg.");
        try
        {
            var errors = process.StandardError.ReadToEndAsync();
            await using (var input = process.StandardInput.BaseStream)
                await source.CopyToAsync(input, ct);
            await process.WaitForExitAsync(ct);
            if (process.ExitCode != 0) throw new IOException("No se ha podido preparar el audio. " + await errors);
            return new FileStream(output, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete,
                65536, FileOptions.Asynchronous | FileOptions.DeleteOnClose);
        }
        catch
        {
            if (!process.HasExited) { process.Kill(); await process.WaitForExitAsync(); }
            File.Delete(output);
            throw;
        }
    }
}
