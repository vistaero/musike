using System.Text;
using System.Text.RegularExpressions;

namespace Musike.Core;

/// <summary>Local diagnostics only. Credentials and signed stream URLs must not enter the log.</summary>
public static partial class DiagnosticLog
{
    private static readonly object Gate = new();
    private static string? file;
    public static void Initialize(string root)
    {
        lock (Gate) file = Path.Combine(root, "logs", "application.log");
    }
    public static void Write(string area, string message, Exception? error = null)
    {
        lock (Gate)
        {
            if (file is null) return;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                if (File.Exists(file) && new FileInfo(file).Length > 2 * 1024 * 1024) File.Move(file, file + ".previous", true);
                var text = $"{DateTimeOffset.Now:O} [{area}] {message}" + (error is null ? "" : "\n" + error) + "\n";
                text = Urls().Replace(text, "[url]");
                text = Tokens().Replace(text, "[credential]");
                File.AppendAllText(file, text, new UTF8Encoding(false));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* Logging cannot break playback. */ }
        }
    }
    [GeneratedRegex(@"https?://\S+", RegexOptions.IgnoreCase)] private static partial Regex Urls();
    [GeneratedRegex(@"\b[A-Fa-f0-9]{64}\b")] private static partial Regex Tokens();
}
