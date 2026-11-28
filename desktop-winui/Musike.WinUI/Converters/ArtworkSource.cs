using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Musike.WinUI.Converters;

/// <summary>Empty genre artwork must never reach WinUI's string-to-ImageSource conversion.</summary>
public static class ArtworkSource
{
    public static ImageSource? FromUri(string? text)
    {
        if (string.IsNullOrWhiteSpace(text) ||
            !Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http")) return null;
        try { return new BitmapImage(uri); }
        catch (Exception error) when (error is ArgumentException or UriFormatException or System.Runtime.InteropServices.COMException)
        {
            Musike.Core.DiagnosticLog.Write("artwork", "Artwork URI rejected by Windows; using the placeholder.", error);
            return null;
        }
    }
}
