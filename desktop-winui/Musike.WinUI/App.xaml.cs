using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Musike.Core;

namespace Musike.WinUI;

public partial class App : Application
{
    private Window? window;
    private Mutex? instance;
    public App()
    {
        DiagnosticLog.Initialize(new ProfileStore().Root);
        UnhandledException += (sender, args) => DiagnosticLog.Write("unhandled-ui", args.Message, args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (sender, args) => DiagnosticLog.Write("unhandled-process", "Process exception", args.ExceptionObject as Exception);
        InitializeComponent();
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
#if DEBUG
        if (Environment.GetCommandLineArgs().Contains("--ui-regression"))
        {
            _ = UiRegression.RunAsync(this);
            return;
        }
#endif
        instance = new Mutex(true, @"Local\Musike.WinUI.Desktop", out var first);
        if (!first)
        {
            var existing = FindWindow(null, "Musike · WinUI");
            if (existing != IntPtr.Zero) { ShowWindow(existing, 9); SetForegroundWindow(existing); }
            Exit();
            return;
        }
        window = new MainWindow();
        window.Activate();
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string? className, string title);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
}
