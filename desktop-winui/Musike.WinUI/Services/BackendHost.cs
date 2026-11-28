using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Musike.Core;

namespace Musike.WinUI.Services;

public sealed class BackendHost : IAsyncDisposable
{
    private Process? process;
    private readonly StringBuilder errors = new();
    public event Action<string>? Status;
    public event Action<string>? Failed;
    public string Token { get; } = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
    private bool stopping;
    public async Task<Uri> StartAsync(ProfileStore profile, CancellationToken ct)
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "Backend");
        var executable = Path.Combine(folder, "node.exe");
        var script = Path.Combine(folder, "server.mjs");
        if (!File.Exists(executable) || !File.Exists(script)) throw new FileNotFoundException("Falta el motor de Musike. Ejecuta pnpm winui:prepare y recompila.");
        var start = new ProcessStartInfo(executable)
        {
            WorkingDirectory = folder, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        start.ArgumentList.Add(script);
        start.Environment["MUSIKE_WINUI_TOKEN"] = Token;
        start.Environment["MUSIKE_DATA_DIR"] = Path.Combine(profile.Root, "data");
        start.Environment["MUSIKE_CACHE_DIR"] = Path.Combine(profile.Root, "cache");
        start.Environment["MUSIKE_BIN_DIR"] = Path.Combine(profile.Root, "bin");
        start.Environment["MUSIKE_WEB_DIST"] = Path.Combine(folder, "no-web");
        var ready = new TaskCompletionSource<Uri>(TaskCreationOptions.RunContinuationsAsynchronously);
        process = new Process { StartInfo = start, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            try
            {
                using var json = JsonDocument.Parse(e.Data);
                var root = json.RootElement;
                if (!root.TryGetProperty("type", out var type)) return;
                switch (type.GetString())
                {
                    case "ready":
                        var port = root.GetProperty("port").GetInt32();
                        if (port is > 0 and <= 65535) ready.TrySetResult(new Uri($"http://127.0.0.1:{port}/"));
                        break;
                    case "warning":
                        var warning = root.GetProperty("message").GetString() ?? "";
                        DiagnosticLog.Write("engine-warning", warning);
                        Status?.Invoke(warning);
                        break;
                    case "stream-response": DiagnosticLog.Write("engine-stream", root.ToString()); break;
                    case "downloads":
                        var active = root.GetProperty("downloads").EnumerateObject().Where(x => x.Value.GetProperty("status").GetString() is "downloading" or "extracting").Select(x => x.Name).ToArray();
                        Status?.Invoke(active.Length > 0 ? "Preparando " + string.Join(", ", active) + "…" : "Motor preparado");
                        break;
                }
            }
            catch (JsonException) { /* Dependency logs are not protocol messages. */ }
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            DiagnosticLog.Write("engine", e.Data);
            lock (errors) { if (errors.Length > 12000) errors.Remove(0, 6000); errors.AppendLine(e.Data); }
        };
        process.Exited += (_, _) =>
        {
            string message;
            lock (errors) message = "El motor de Musike se ha cerrado. " + errors;
            ready.TrySetException(new InvalidOperationException(message));
            if (!stopping) Failed?.Invoke(message);
        };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        try { return await ready.Task.WaitAsync(TimeSpan.FromSeconds(45), ct); }
        catch { await DisposeAsync(); throw; }
    }
    public async ValueTask DisposeAsync()
    {
        stopping = true;
        var child = process;
        process = null;
        if (child is null) return;
        try
        {
            if (!child.HasExited)
            {
                await child.StandardInput.WriteLineAsync("shutdown");
                child.StandardInput.Close();
                await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(4));
            }
        }
        catch (Exception e) when (e is TimeoutException or IOException or InvalidOperationException)
        {
            if (!child.HasExited) child.Kill(entireProcessTree: true);
        }
        finally { child.Dispose(); }
    }
}
