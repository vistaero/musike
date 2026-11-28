using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Musike.Core;
using Musike.WinUI.Services;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;

namespace Musike.WinUI;

public sealed partial class MainWindow : Window
{
    private readonly ProfileStore profile = new();
    private readonly BackendHost backend = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Preferences settings;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(300) };
    private MusikeClient? api;
    private PlaybackService? playback;
    private Library library = Library.Empty;
    private List<Track> displayed = [];
    private Lyrics? lyrics;
    private string? lyricsId;
    private int lyricsRequest;
    private Playlist? playlist;
    private string view = "home";
    private CancellationTokenSource? pageRequest;
    private CancellationTokenSource? suggestions;
    private bool ready, updating, canClose, closing;
    private int busyCount, ticks;
    private string? currentArtwork;
    private GenrePage? genrePage;
    private bool moreArtistsLoading;
    private Windows.Media.Playback.MediaPlayer? seekPlayer;
#if DEBUG
    private readonly MusikeClient? regressionApi;
    private readonly TaskCompletionSource<bool> regressionReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal MainWindow(MusikeClient regressionApi) : this() => this.regressionApi = regressionApi;
#endif

    public MainWindow()
    {
        settings = profile.Load();
        InitializeComponent();
        // ValueChanged also fires when the timer changes Value or Maximum. Only an explicit
        // pointer/keyboard gesture may seek; refreshing the progress bar must never move the audio.
        SeekSlider.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(Seek_PointerPressed), true);
        SeekSlider.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(Seek_PointerFinished), true);
        SeekSlider.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler(Seek_PointerFinished), true);
        SeekSlider.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(Seek_KeyDown), true);
        SeekSlider.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler(Seek_KeyUp), true);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            AppWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
            AppWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        }
        AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Clamp(settings.Width, 850, 3840), Math.Clamp(settings.Height, 640, 2160)));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 850;
            presenter.PreferredMinimumHeight = 640;
        }
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "icon.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);
        ApplyTheme();
        Root.Loaded += Root_Loaded;
        AppWindow.Closing += Window_Closing;
        timer.Tick += Timer_Tick;
        backend.Status += text => DispatcherQueue.TryEnqueue(() => { if (!closing) { EngineStatus.Text = text; if (!ready) PageSubtitle.Text = text; } });
        backend.Failed += text => DispatcherQueue.TryEnqueue(() => { if (!closing) { playback?.Stop(); ShowError(text); } });
        AddShortcuts();
    }
    private async void Root_Loaded(object sender, RoutedEventArgs e)
    {
        Root.Loaded -= Root_Loaded;
        await GuardAsync(async () =>
        {
            profile.Initialize();
#if DEBUG
            if (regressionApi is not null) api = regressionApi;
            else
#endif
            {
                var address = await backend.StartAsync(profile, lifetime.Token);
                if (closing) return;
                api = new MusikeClient(address, backend.Token) { Language = settings.Language };
            }
            playback = new PlaybackService(api, DispatcherQueue, settings);
            playback.Changed += UpdatePlayer;
            // Audio playback must not depend on the lifetime of the hidden video renderer.
            playback.PlayerChanged += player => VideoSurface.SetMediaPlayer(playback.IsVideo ? player! : null!);
            playback.Error += ShowError;
            playback.Started += Playback_Started;
            library = await api.LibraryAsync();
            if (closing) return;
            ready = true;
            updating = true;
            VolumeSlider.Value = Math.Clamp(settings.Volume * 100, 0, 100);
            VideoToggle.IsOn = settings.Video;
            HdToggle.IsOn = settings.Hd;
            AutoRadioToggle.IsOn = settings.AutoRadio;
            ThemePicker.SelectedItem = ThemePicker.Items.Cast<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == settings.Theme) ?? ThemePicker.Items[0];
            LanguagePicker.SelectedItem = LanguagePicker.Items.Cast<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == settings.Language) ?? LanguagePicker.Items[0];
            Navigation.SelectedItem = Navigation.MenuItems.OfType<NavigationViewItem>().First();
            updating = false;
            await NavigateAsync("home");
            UpdatePlayer();
            timer.Start();
        });
#if DEBUG
        regressionReady.TrySetResult(ready);
#endif
    }
    private async void Window_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (canClose) return;
        args.Cancel = true;
        if (closing) return;
        closing = true;
        lifetime.Cancel();
        pageRequest?.Cancel();
        suggestions?.Cancel();
        timer.Stop();
        try { SaveState(); }
        catch (Exception e)
        {
            var dialog = Dialog("No se han podido guardar las preferencias", new TextBlock { Text = e.Message, TextWrapping = TextWrapping.Wrap });
            await dialog.ShowAsync();
        }
        playback?.Dispose();
        api?.Dispose();
        await backend.DisposeAsync();
        canClose = true;
        Close();
    }
    private void SaveState()
    {
        playback?.Snapshot();
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
        {
            settings.Width = AppWindow.Size.Width;
            settings.Height = AppWindow.Size.Height;
        }
        profile.Save(settings);
    }
    private async Task GuardAsync(Func<Task> action)
    {
        if (closing) return;
        busyCount++;
        Busy.Visibility = Visibility.Visible;
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (!closing) ShowError(e.Message); }
        finally { if (--busyCount == 0) Busy.Visibility = Visibility.Collapsed; }
    }
    private void ShowError(string message)
    {
        DiagnosticLog.Write("ui-error", message);
        Notice.Severity = InfoBarSeverity.Error;
        Notice.Title = "Musike";
        Notice.Message = message;
        Notice.IsOpen = true;
    }
    private void Inform(string message)
    {
        Notice.Severity = InfoBarSeverity.Informational;
        Notice.Title = "";
        Notice.Message = message;
        Notice.IsOpen = true;
    }
    private CancellationToken BeginPage(string route, string title, string subtitle = "")
    {
        pageRequest?.Cancel();
        pageRequest?.Dispose();
        pageRequest = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        view = route;
        playlist = null;
        genrePage = null;
        PageTitle.Text = title;
        PageSubtitle.Text = subtitle;
        Notice.IsOpen = false;
        CollectionPanel.Visibility = Visibility.Visible;
        foreach (var panel in new UIElement[] { NowPlayingPanel, LyricsPanel, BatchPanel, SettingsPanel }) panel.Visibility = Visibility.Collapsed;
        ShowTracks([]);
        ShowCards([]);
        RenameButton.IsEnabled = DeleteButton.IsEnabled = false;
        RemoveButton.IsEnabled = route is "favorites" or "queue";
        return pageRequest.Token;
    }
    private void ShowTracks(IEnumerable<Track> tracks)
    {
        displayed = tracks.ToList();
        Tracks.ItemsSource = displayed;
        EmptyText.Visibility = displayed.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Results.SelectedItem = TracksTab;
    }
    private void ShowCards(IEnumerable<BrowseCard> cards, bool select = false)
    {
        var list = cards.ToList();
        Cards.ItemsSource = list;
        CardsTab.Visibility = list.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (select && list.Count > 0) Results.SelectedItem = CardsTab;
    }
    private async void Navigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!ready || updating) return;
        var route = args.IsSettingsSelected ? "settings" : (args.SelectedItem as NavigationViewItem)?.Tag as string;
        if (route is not null) await GuardAsync(() => NavigateAsync(route));
    }
    private async Task NavigateAsync(string route)
    {
        if (api is null || playback is null) return;
        var title = route switch
        {
            "home" => "Tu música, sin interrupciones.", "search" => "Buscar música", "genres" => "Explorar géneros",
            "favorites" => "Favoritos", "history" => "Escuchado recientemente", "playlists" => "Listas de reproducción",
            "queue" => "Cola de reproducción", "playing" => "Reproduciendo", "lyrics" => "Letras",
            "batch" => "Buscar una lista", "settings" => "Ajustes", _ => "Musike"
        };
        var ct = BeginPage(route, title);
        switch (route)
        {
            case "home":
            case "favorites":
            case "history":
            case "playlists":
                var fresh = await api.LibraryAsync();
                ct.ThrowIfCancellationRequested();
                library = fresh;
                ShowTracks(route == "favorites" ? library.Favorites : route == "playlists" ? [] : library.History);
                if (route is "home" or "playlists")
                    ShowCards(library.Playlists.Select(p => new BrowseCard(p.Id, p.Name, $"{p.Tracks.Count} canciones", p.Tracks.FirstOrDefault()?.Artwork ?? "", "playlist")), route == "playlists");
                PageSubtitle.Text = route == "home" ? "Tus últimas canciones y tus listas, siempre a mano." : $"{displayed.Count} canciones · {library.Playlists.Count} listas";
                break;
            case "genres":
                var genres = await api.GenresAsync(ct);
                ct.ThrowIfCancellationRequested();
                ShowCards(genres.Select(g => new BrowseCard(g.Id, g.Name, "Género", "", "genre")), true);
                break;
            case "search": SearchBox.Focus(FocusState.Programmatic); break;
            case "queue": ShowTracks(QueueRows()); PageSubtitle.Text = "Haz doble clic para saltar a una canción."; break;
            case "playing":
                CollectionPanel.Visibility = Visibility.Collapsed;
                NowPlayingPanel.Visibility = Visibility.Visible;
                UpdatePlayer();
                break;
            case "lyrics":
                CollectionPanel.Visibility = Visibility.Collapsed;
                LyricsPanel.Visibility = Visibility.Visible;
                await LoadLyricsAsync(ct);
                break;
            case "batch": CollectionPanel.Visibility = Visibility.Collapsed; BatchPanel.Visibility = Visibility.Visible; break;
            case "settings":
                CollectionPanel.Visibility = Visibility.Collapsed;
                SettingsPanel.Visibility = Visibility.Visible;
                await RefreshSystemAsync();
                break;
        }
    }
    private async void Search_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        var query = args.ChosenSuggestion as string ?? args.QueryText;
        if (!ready || string.IsNullOrWhiteSpace(query)) return;
        await GuardAsync(() => SearchAsync(query));
    }
    private async Task SearchAsync(string query)
    {
        var ct = BeginPage("search", query.Trim(), "Resultados de búsqueda");
        if (SearchKind.SelectedIndex == 2)
        {
            var albums = await api!.SearchAlbumsAsync(query, ct);
            ct.ThrowIfCancellationRequested();
            ShowCards(albums.Select(AlbumCard), true);
            PageSubtitle.Text = $"{albums.Count} álbumes";
        }
        else
        {
            var tracks = await api!.SearchAsync(query, SearchKind.SelectedIndex == 1 ? "video" : "song", ct);
            ct.ThrowIfCancellationRequested();
            ShowTracks(tracks);
            PageSubtitle.Text = $"{tracks.Count} resultados";
        }
    }
    private async void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (!ready || args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        suggestions?.Cancel();
        suggestions?.Dispose();
        suggestions = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var ct = suggestions.Token;
        if (sender.Text.Trim().Length < 2) { sender.ItemsSource = null; return; }
        try
        {
            await Task.Delay(250, ct);
            var values = await api!.SuggestAsync(sender.Text, ct);
            if (!ct.IsCancellationRequested) sender.ItemsSource = values;
        }
        catch (Exception e) when (e is OperationCanceledException or HttpRequestException or MusikeApiException) { }
    }
    private static BrowseCard AlbumCard(AlbumCard a) => new(a.Id, a.Title, $"{a.Artist} · {a.Year}", a.Thumb, "album");
    private async void Cards_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not BrowseCard card) return;
        if (card.Kind == "more")
        {
            await GuardAsync(LoadMoreArtistsAsync);
            return;
        }
        await GuardAsync(() => OpenCardAsync(card));
    }
    private async Task OpenCardAsync(BrowseCard card)
    {
        var ct = BeginPage(card.Kind, card.Label, card.Caption);
        switch (card.Kind)
        {
            case "playlist":
                library = await api!.LibraryAsync();
                ct.ThrowIfCancellationRequested();
                playlist = library.Playlists.FirstOrDefault(p => p.Id == card.Id) ?? throw new InvalidOperationException("Esta lista ya no existe.");
                RenameButton.IsEnabled = DeleteButton.IsEnabled = RemoveButton.IsEnabled = true;
                ShowTracks(playlist.Tracks);
                break;
            case "genre":
                var genre = await api!.GenreAsync(card.Id, ct);
                ct.ThrowIfCancellationRequested();
                genrePage = genre;
                ShowTracks(genre.Tracks);
                ShowGenreArtists();
                break;
            case "artist":
                var artist = await api!.ArtistAsync(card.Id, ct);
                ct.ThrowIfCancellationRequested();
                PageSubtitle.Text = artist.Description;
                ShowTracks(artist.Tracks);
                ShowCards(artist.Albums.Concat(artist.Singles).Select(AlbumCard));
                break;
            case "album":
                var album = await api!.AlbumAsync(card.Id, ct);
                ct.ThrowIfCancellationRequested();
                PageSubtitle.Text = $"{album.Artist} · {album.Kind} · {album.Info}";
                ShowTracks(album.Tracks);
                if (album.ArtistId is not null) ShowCards(new[] { new BrowseCard(album.ArtistId, album.Artist, "Artista", album.Thumb, "artist") });
                break;
        }
    }
    private async Task LoadMoreArtistsAsync()
    {
        if (genrePage is not { HasMoreArtists: true } current || moreArtistsLoading) return;
        moreArtistsLoading = true;
        var ct = pageRequest!.Token;
        try
        {
            var result = await api!.GenreArtistsAsync(current.Id, current.Artists.Count, ct);
            ct.ThrowIfCancellationRequested();
            var artists = result.GetProperty("artists").Deserialize<List<GenreArtist>>(Json.Options) ?? [];
            genrePage = current with { Artists = [.. current.Artists, .. artists], HasMoreArtists = result.GetProperty("hasMore").GetBoolean() };
            ShowGenreArtists();
        }
        finally { moreArtistsLoading = false; }
    }
    private void ShowGenreArtists()
    {
        if (genrePage is null) return;
        var cards = genrePage.Artists.Select(a => new BrowseCard(a.Id, a.Name, string.Join(", ", a.Hits.Take(2)), a.Thumb, "artist")).ToList();
        if (genrePage.HasMoreArtists) cards.Add(new(genrePage.Id, "Cargar más artistas", "", "", "more"));
        ShowCards(cards);
    }
    private List<Track> SelectedTracks() => Tracks.SelectedItems.Cast<Track>().ToList();
    private List<Track> QueueRows() => playback!.Queue.Snapshot().Entries.Select(e => e.Track with { RowKey = e.Key }).ToList();
    private async void Tracks_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => await GuardAsync(PlaySelectionAsync);
    private void Tracks_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        for (var element = e.OriginalSource as DependencyObject; element is not null && element != Tracks;
            element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element))
        {
            if (element is not ListViewItem row) continue;
            if (Tracks.IndexFromContainer(row) >= 0 && row.Content is Track track && !Tracks.SelectedItems.Contains(track))
                Tracks.SelectedItem = track;
            break;
        }
    }
    private async void Play_Click(object sender, RoutedEventArgs e) => await GuardAsync(PlaySelectionAsync);
    private async Task PlaySelectionAsync()
    {
        if (playback is null || displayed.Count == 0) return;
        var selected = SelectedTracks();
        if (view == "queue") { await playback.JumpAsync(Math.Max(0, Tracks.SelectedIndex)); return; }
        if (selected.Count > 1) await playback.PlayAsync(selected);
        else await playback.PlayAsync(displayed, Math.Max(0, Tracks.SelectedIndex));
    }
    private void Enqueue_Click(object sender, RoutedEventArgs e)
    {
        var selected = SelectedTracks();
        foreach (var track in selected.Count > 0 ? selected : displayed) playback?.Add(track);
        Inform("Canciones añadidas a la cola.");
    }
    private void PlayNext_Click(object sender, RoutedEventArgs e)
    {
        foreach (var track in SelectedTracks().AsEnumerable().Reverse()) playback?.Add(track, true);
    }
    private async void Radio_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        if (SelectedTracks().FirstOrDefault() is not { } track) return;
        var radio = await api!.RadioAsync(track.Id, lifetime.Token);
        await playback!.PlayAsync(new[] { track }.Concat(radio.Where(t => t.Id != track.Id)));
        await NavigateAsync("queue");
    });
    private async void ArtistSearch_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        if (SelectedTracks().FirstOrDefault() is not { } track) return;
        SearchBox.Text = track.Artist;
        SearchKind.SelectedIndex = 2;
        await SearchAsync(track.Artist);
    });
    private async void OpenYouTube_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        if (SelectedTracks().FirstOrDefault() is { } track) await Launcher.LaunchUriAsync(new Uri("https://www.youtube.com/watch?v=" + MusikeClient.Escape(track.Id)));
    });
    private async void FavoriteSelection_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        var selected = SelectedTracks();
        if (selected.Count == 0) { Inform("Selecciona las canciones que quieres añadir."); return; }
        await api!.AddFavoritesAsync(selected);
        library = await api.LibraryAsync();
        UpdatePlayer();
        Inform("Añadidas a favoritos.");
    });
    private async void ToggleFavoriteSelection_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        foreach (var track in SelectedTracks()) await api!.FavoriteAsync(track, !library.Favorites.Any(t => t.Id == track.Id));
        await RefreshLibraryViewAsync();
    });
    private async void Favorite_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        if (playback?.Queue.Current is not { } track) return;
        await api!.FavoriteAsync(track, !library.Favorites.Any(t => t.Id == track.Id));
        await RefreshLibraryViewAsync();
    });
    private async Task RefreshLibraryViewAsync()
    {
        library = await api!.LibraryAsync();
        UpdatePlayer();
        if (view == "favorites") ShowTracks(library.Favorites);
        if (view == "playlist" && playlist is not null)
        {
            playlist = library.Playlists.FirstOrDefault(p => p.Id == playlist.Id);
            ShowTracks(playlist?.Tracks ?? []);
        }
    }
    private ContentDialog Dialog(string title, object content, string? primary = null) => new()
    {
        XamlRoot = Root.XamlRoot, Title = title, Content = content,
        CloseButtonText = "Cancelar", PrimaryButtonText = primary ?? "", DefaultButton = primary is null ? ContentDialogButton.Close : ContentDialogButton.Primary,
        RequestedTheme = Root.ActualTheme
    };
    private async Task<string?> AskNameAsync(string title, string value = "")
    {
        var input = new TextBox { Text = value, MaxLength = 120, PlaceholderText = "Nombre de la lista" };
        var dialog = Dialog(title, input, "Guardar");
        dialog.PrimaryButtonClick += (sender, e) => { if (string.IsNullOrWhiteSpace(input.Text)) e.Cancel = true; };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? input.Text.Trim() : null;
    }
    private async void NewPlaylist_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        if (api is null) return;
        var tracks = SelectedTracks();
        if (await AskNameAsync("Nueva lista de reproducción") is not { } name) return;
        var created = await api.CreatePlaylistAsync(name, tracks);
        await OpenCardAsync(new(created.Id, created.Name, "", "", "playlist"));
    });
    private async void RenamePlaylist_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        if (playlist is not { } current || await AskNameAsync("Renombrar lista", current.Name) is not { } name) return;
        playlist = await api!.RenamePlaylistAsync(current.Id, name);
        PageTitle.Text = playlist.Name;
    });
    private async void DeletePlaylist_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        if (playlist is not { } current) return;
        if (await Dialog("Eliminar lista", $"¿Eliminar «{current.Name}»?", "Eliminar").ShowAsync() != ContentDialogResult.Primary) return;
        await api!.DeletePlaylistAsync(current.Id);
        await NavigateAsync("playlists");
    });
    private async void AddToPlaylist_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        var selected = SelectedTracks();
        if (selected.Count == 0) { Inform("Selecciona primero las canciones."); return; }
        library = await api!.LibraryAsync();
        if (library.Playlists.Count == 0)
        {
            if (await AskNameAsync("Crear lista con la selección") is { } name) await api.CreatePlaylistAsync(name, selected);
            return;
        }
        var picker = new ComboBox { ItemsSource = library.Playlists, DisplayMemberPath = "Name", SelectedIndex = 0, MinWidth = 280 };
        if (await Dialog("Añadir a lista", picker, "Añadir").ShowAsync() == ContentDialogResult.Primary && picker.SelectedItem is Playlist target)
            await api.AddToPlaylistAsync(target.Id, selected);
        await RefreshLibraryViewAsync();
    });
    private async void RemoveSelection_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        var selected = SelectedTracks();
        if (view == "queue")
        {
            var indices = Tracks.SelectedItems.Cast<object>().Select(x => Tracks.Items.IndexOf(x)).OrderDescending().ToArray();
            foreach (var index in indices) await playback!.RemoveAsync(index);
        }
        else if (playlist is { } current) foreach (var t in selected) await api!.RemoveFromPlaylistAsync(current.Id, t.Id);
        else if (view == "favorites") foreach (var t in selected) await api!.FavoriteAsync(t, false);
        await RefreshLibraryViewAsync();
    });
    private void ClearUpcoming_Click(object sender, RoutedEventArgs e) { playback?.Queue.ClearUpcoming(); if (view == "queue") ShowTracks(QueueRows()); }
    private async void Toggle_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => playback?.ToggleAsync() ?? Task.CompletedTask);
    private async void Previous_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => playback?.PreviousAsync() ?? Task.CompletedTask);
    private async void Next_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => playback?.NextAsync() ?? Task.CompletedTask);
    private void Shuffle_Click(object sender, RoutedEventArgs e) => playback?.Shuffle();
    private void Repeat_Click(object sender, RoutedEventArgs e) => playback?.CycleRepeat();
    private void Mute_Click(object sender, RoutedEventArgs e) => playback?.ToggleMute();
    private void Volume_ValueChanged(object sender, RangeBaseValueChangedEventArgs e) { if (ready && !updating) playback?.SetVolume(e.NewValue / 100); }
    private void BeginSeek()
    {
        if (ready && playback is { Loading: false, Player: not null }) seekPlayer = playback.Player;
    }
    private void CommitSeek()
    {
        var player = seekPlayer;
        seekPlayer = null;
        if (player is not null && playback?.Player == player && !playback.Loading)
            playback.Seek(SeekSlider.Value, "progress-bar");
    }
    private void Seek_PointerPressed(object sender, PointerRoutedEventArgs e) => BeginSeek();
    private void Seek_PointerFinished(object sender, PointerRoutedEventArgs e) => CommitSeek();
    private static bool IsSeekKey(VirtualKey key) => key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down
        or VirtualKey.Home or VirtualKey.End or VirtualKey.PageUp or VirtualKey.PageDown;
    private void Seek_KeyDown(object sender, KeyRoutedEventArgs e) { if (IsSeekKey(e.Key)) BeginSeek(); }
    private void Seek_KeyUp(object sender, KeyRoutedEventArgs e) { if (IsSeekKey(e.Key)) CommitSeek(); }
    private void UpdatePlayer()
    {
        if (playback is null || closing) return;
        var track = playback.Queue.Current;
        TrackTitle.Text = track?.Title ?? "Elige una canción";
        TrackArtist.Text = playback.Loading ? "Preparando reproducción…" : track?.Artist ?? "Musike";
        PlayIcon.Symbol = playback.IsPlaying || playback.WillPlay ? Symbol.Pause : Symbol.Play;
        ShuffleButton.IsChecked = playback.Queue.Shuffled;
        RepeatButton.Content = playback.Queue.Repeat == RepeatMode.One ? "↻ 1" : "↻";
        RepeatButton.Opacity = playback.Queue.Repeat == RepeatMode.Off ? .5 : 1;
        ToolTipService.SetToolTip(RepeatButton, "Repetir: " + playback.Queue.Repeat);
        MuteButton.Opacity = settings.Muted ? .4 : 1;
        FavoriteButton.Opacity = track is not null && library.Favorites.Any(t => t.Id == track.Id) ? 1 : .4;
        FavoriteButton.IsEnabled = track is not null;
        SeekSlider.IsEnabled = playback.Player is not null && !playback.Loading;
        if (track?.Artwork != currentArtwork)
        {
            currentArtwork = track?.Artwork;
            var image = Converters.ArtworkSource.FromUri(currentArtwork);
            SmallArtwork.Source = image;
            LargeArtwork.Source = image;
        }
        VideoSurface.Visibility = playback.IsVideo ? Visibility.Visible : Visibility.Collapsed;
        LargeArtwork.Visibility = playback.IsVideo ? Visibility.Collapsed : Visibility.Visible;
        if (view == "queue")
        {
            var values = QueueRows();
            if (!displayed.SequenceEqual(values)) ShowTracks(values);
        }
        if (view == "playing")
        {
            PageTitle.Text = track?.Title ?? "Reproduciendo";
            PageSubtitle.Text = settings.Video && !playback.IsVideo && track is not null ? "No se ha encontrado videoclip; se reproduce el audio." : track?.Artist ?? "Elige una canción para empezar.";
        }
        if (view == "lyrics" && track is not null && track.Id != lyricsId)
            _ = GuardAsync(() => LoadLyricsAsync(pageRequest!.Token));
    }
    private void Timer_Tick(object? sender, object e)
    {
        if (playback is null || closing) return;
        updating = true;
        if (seekPlayer is not null && playback.Player != seekPlayer) seekPlayer = null;
        if (seekPlayer is null)
        {
            SeekSlider.Maximum = Math.Max(1, playback.Duration);
            SeekSlider.Value = Math.Clamp(playback.Position, 0, SeekSlider.Maximum);
        }
        PositionText.Text = FormatTime(playback.Position);
        TotalDurationText.Text = FormatTime(playback.Duration);
        updating = false;
        if (ticks % 3 == 0) playback.UpdateSystemTimeline();
        if (view == "lyrics" && lyrics is { Synced: true } && lyricsId == playback.Queue.Current?.Id)
        {
            var line = lyrics.Lines.LastOrDefault(l => l.Time <= playback.Position);
            if (line is not null && !Equals(LyricLines.SelectedItem, line))
            {
                LyricLines.SelectedItem = line;
                LyricLines.ScrollIntoView(line);
            }
        }
        if (++ticks % 50 == 0)
        {
            try { SaveState(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { ShowError("No se han podido guardar las preferencias: " + error.Message); }
        }
    }
    private static string FormatTime(double value) => TimeSpan.FromSeconds(Math.Max(0, double.IsFinite(value) ? value : 0)).ToString(value >= 3600 ? @"h\:mm\:ss" : @"m\:ss");
    private async void Playback_Started(Track track) => await GuardAsync(async () =>
    {
        await api!.HistoryAsync(track);
        library = await api.LibraryAsync();
        if (view is "home" or "history") ShowTracks(library.History);
        if (view == "lyrics" && lyricsId != track.Id) await LoadLyricsAsync(pageRequest!.Token);
    });
    private async Task LoadLyricsAsync(CancellationToken ct)
    {
        lyrics = null;
        LyricLines.ItemsSource = null;
        LyricsMessage.Text = "Elige una canción para ver su letra.";
        if (playback?.Queue.Current is not { } track) return;
        lyricsId = track.Id;
        var request = ++lyricsRequest;
        LyricsMessage.Text = "Buscando letra…";
        var result = await api!.LyricsAsync(track, ct);
        if (ct.IsCancellationRequested || request != lyricsRequest || view != "lyrics" || playback.Queue.Current?.Id != track.Id) return;
        lyrics = result;
        lyricsId = track.Id;
        LyricLines.ItemsSource = lyrics?.Lines;
        LyricsMessage.Text = result is null ? "Letra no disponible." : result.Instrumental ? "Esta canción es instrumental." : "";
        PageSubtitle.Text = $"{track.Artist} · {result?.Source ?? "LRCLIB"}";
    }
    private void Lyrics_ItemClick(object sender, ItemClickEventArgs e) { if (lyrics?.Synced == true && e.ClickedItem is LyricLine line) playback?.Seek(line.Time); }
    private async void Video_Toggled(object sender, RoutedEventArgs e)
    {
        if (!ready || updating) return;
        settings.Video = VideoToggle.IsOn;
        settings.Hd = HdToggle.IsOn;
        if (playback?.Queue.Current is not null) await GuardAsync(() => playback.LoadAsync(playback.IsPlaying, playback.Position));
    }
    private void Fullscreen_Click(object sender, RoutedEventArgs e)
    {
        var fullscreen = AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;
        AppWindow.SetPresenter(fullscreen ? AppWindowPresenterKind.Overlapped : AppWindowPresenterKind.FullScreen);
        Root.RowDefinitions[0].Height = new GridLength(fullscreen ? 40 : 0);
    }
    private void ApplyTheme() => Root.RequestedTheme = settings.Theme switch { "dark" => ElementTheme.Dark, "light" => ElementTheme.Light, _ => ElementTheme.Default };
    private void Theme_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || updating) return;
        settings.Theme = (ThemePicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "system";
        ApplyTheme();
    }
    private void Language_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || updating) return;
        settings.Language = (LanguagePicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "es-ES";
        api!.Language = settings.Language;
    }
    private void AutoRadio_Toggled(object sender, RoutedEventArgs e) { if (ready && !updating) settings.AutoRadio = AutoRadioToggle.IsOn; }
    private async Task RefreshSystemAsync()
    {
        var system = await api!.SystemAsync();
        if (view != "settings") return;
        var ytdlp = system.GetProperty("ytdlp");
        EngineStatus.Text = $"yt-dlp: {ytdlp.GetProperty("version").GetString() ?? "sin instalar"}\nDeno: {system.GetProperty("deno").GetString() ?? "sin instalar"}\nFFmpeg: {system.GetProperty("ffmpeg").GetString() ?? "sin instalar"}";
        if (system.TryGetProperty("job", out var job) && job.ValueKind == JsonValueKind.Object) EngineStatus.Text += "\n" + job.GetProperty("message").GetString();
    }
    private async void UpdateEngine_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        ((Button)sender).IsEnabled = false;
        try
        {
            await api!.UpdateAsync(ChannelPicker.SelectedIndex == 1 ? "nightly" : "stable");
            for (var attempt = 0; attempt < 300; attempt++)
            {
                await Task.Delay(1000, lifetime.Token);
                var info = await api.SystemAsync();
                if (view == "settings") await RefreshSystemAsync();
                if (info.GetProperty("job").GetProperty("status").GetString() != "running") break;
            }
        }
        finally { ((Button)sender).IsEnabled = true; }
    });
    private async void RetryTools_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        await api!.RequestAsync<JsonElement>(HttpMethod.Post, "api/native/tools");
        await RefreshSystemAsync();
    });
    private async void OpenData_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () => await Launcher.LaunchFolderAsync(await StorageFolder.GetFolderFromPathAsync(profile.Root)));
    private async void Export_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        var current = await api!.LibraryAsync();
        var picker = new FileSavePicker { SuggestedFileName = $"musike-backup-{DateTime.Now:yyyy-MM-dd}.musike" };
        picker.FileTypeChoices.Add("Copia de Musike", [".json"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSaveFileAsync() is not { } file) return;
        var backup = new { format = "musike-backup", version = 1, exportedAt = DateTimeOffset.UtcNow, app = "Musike WinUI 1.5.1", library = current,
            settings = new { theme = settings.Theme, lang = settings.Language, volume = settings.Volume, preferVideo = settings.Video, quality = settings.Hd ? "hd" : "sd", autoRadio = settings.AutoRadio } };
        await FileIO.WriteTextAsync(file, JsonSerializer.Serialize(backup, Json.Options));
        Inform("Copia de seguridad exportada.");
    });
    private async void Import_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".json");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFileAsync() is not { } file) return;
        var properties = await file.GetBasicPropertiesAsync();
        if (properties.Size > 25 * 1024 * 1024) throw new InvalidOperationException("La copia supera el límite de 25 MB.");
        using var backup = JsonDocument.Parse(await FileIO.ReadTextAsync(file));
        var choice = Dialog("Importar biblioteca", "Combinar conserva tus listas actuales. Reemplazar las sustituye por las de la copia.", "Combinar");
        choice.SecondaryButtonText = "Reemplazar";
        var result = await choice.ShowAsync();
        if (result == ContentDialogResult.None) return;
        var before = await api!.LibraryAsync();
        var backups = Path.Combine(profile.Root, "backups");
        Directory.CreateDirectory(backups);
        await File.WriteAllTextAsync(Path.Combine(backups, $"before-import-{DateTime.UtcNow:yyyyMMdd-HHmmssfff}.musike.json"), JsonSerializer.Serialize(new { format = "musike-backup", version = 1, library = before }, Json.Options));
        var imported = await api.ImportAsync(backup.RootElement, result == ContentDialogResult.Secondary);
        await RefreshLibraryViewAsync();
        Inform($"Importadas: {imported.PlaylistsAdded} listas, {imported.TracksAdded} canciones, {imported.FavoritesAdded} favoritos.");
    });
    private async void BatchSearch_Click(object sender, RoutedEventArgs e) => await GuardAsync(async () =>
    {
        var lines = BatchInput.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Take(100).ToArray();
        if (lines.Length == 0) return;
        var ct = BeginPage("batch-results", "Resultados de la lista");
        var found = new List<Track>();
        var missing = new List<string>();
        foreach (var line in lines)
        {
            ct.ThrowIfCancellationRequested();
            PageSubtitle.Text = $"Buscando {found.Count + missing.Count + 1} de {lines.Length}…";
            var matches = await api!.SearchAsync(line, "song", ct);
            if (matches.FirstOrDefault() is { } match) found.Add(match); else missing.Add(line);
        }
        ct.ThrowIfCancellationRequested();
        ShowTracks(found);
        PageSubtitle.Text = $"{found.Count} encontradas · {missing.Count} sin resultados. Revisa la selección antes de guardarla.";
        if (missing.Count > 0) Inform("Sin resultados: " + string.Join("; ", missing));
    });
    private void AddShortcuts()
    {
        void Add(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
        {
            var shortcut = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            shortcut.Invoked += (sender, e) => { if (ready) { action(); e.Handled = true; } };
            Root.KeyboardAccelerators.Add(shortcut);
        }
        Add(VirtualKey.F, VirtualKeyModifiers.Control, () => SearchBox.Focus(FocusState.Programmatic));
        Add(VirtualKey.P, VirtualKeyModifiers.Control, () => _ = GuardAsync(() => playback!.ToggleAsync()));
        Add(VirtualKey.Right, VirtualKeyModifiers.Control, () => _ = GuardAsync(() => playback!.NextAsync()));
        Add(VirtualKey.Left, VirtualKeyModifiers.Control, () => _ = GuardAsync(() => playback!.PreviousAsync()));
        Add(VirtualKey.Escape, VirtualKeyModifiers.None, () =>
        {
            if (AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen)
            {
                AppWindow.SetPresenter(AppWindowPresenterKind.Overlapped);
                Root.RowDefinitions[0].Height = new GridLength(40);
            }
        });
    }
}
