# Musike for Windows · WinUI 3

Native Windows x64 desktop port. The interface is C#/XAML, using WinUI 3's `NavigationView`, lists, dialogs, file pickers and Mica. Playback uses Windows `MediaPlayer` / `MediaPlayerElement` and System Media Transport Controls. No Electron, Chromium, React or WebView is loaded by this application.

The existing TypeScript server remains a bundled **Node.js sidecar** for YouTube search, stream extraction, lyrics and library persistence. This port does not rewrite the extraction engine in C#. The sidecar listens only on loopback, chooses a free ephemeral port and requires a random per-launch token. API calls send a header; native media URIs carry the token in the query. Closing the host closes the sidecar; losing the stdin pipe also stops it.

## Build and run

Requirements: Windows 10 2004 (build 19041) or later, Windows x64 Node.js 22+ (for preparing the bundle), pnpm 10.14 and the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). NuGet supplies Windows App SDK and Windows SDK build tools; Visual Studio is optional for command-line builds. Mica appears on supported Windows 11 versions.

From the repository root:

```powershell
corepack pnpm --filter @musike/server install --frozen-lockfile
corepack pnpm winui
```

Or use `pnpm winui:build` to compile without starting, and `pnpm winui:publish` for a self-contained distribution at `release/Musike-WinUI-Windows-x64.zip`. Extract **the whole ZIP** and launch `Musike.WinUI.exe`; the DLLs and Backend folder must stay beside it. The recipient does not need .NET, Node or Windows App Runtime installed. This is a portable folder, not an installer or an MSIX. The existing Electron installers and release workflow are preserved.

To edit the interface in Visual Studio, open `Musike.WinUI.sln` and edit `Musike.WinUI/MainWindow.xaml` (and `App.xaml` for application-wide resources). First run `pnpm winui:prepare` to supply the sidecar. Select the WinUI project as the startup project and build for x64, not AnyCPU. Preparation downloads and caches the official Node license when the Windows Node installer has not supplied it. The pinned versions are in the project file. Updating those references requires rebuilding and checking playback.

## Features

| Feature | Native implementation |
| --- | --- |
| Search | Songs, videos, albums, debounced suggestions and list searches (up to 100 lines) |
| Discovery | Genres, paged artists, artist albums/singles, album tracks, related-song radio |
| Library | Favorites, recent history, create/rename/delete playlists, bulk add/remove |
| Playback | Play/pause, seek, volume/mute, previous/next, queue, play next, remove entries, clear upcoming, shuffle, repeat one/all, automatic radio |
| Video | Find the matching music video, SD / HD 720p, native video surface, full-window mode |
| Lyrics | LRCLIB text and timed lyrics, current-line highlighting and click-to-seek |
| Windows | Media keys and system media metadata/artwork, native pickers/dialogs, single instance, theme, remembered window size and playback position |
| Data | One-time Electron library copy, independent profile, portable JSON backup export, merge/replace import with pre-import backup |
| Tools | Background yt-dlp/Deno/FFmpeg preparation, progress, retry, stable/nightly yt-dlp update |

Select tracks with Ctrl/Shift. Double-click a track to play the collection from that point; right-click for track actions. Selecting multiple tracks and choosing Play plays the selection. Playlist actions are in the command bar overflow. Play/pause is Ctrl+P; search is Ctrl+F; previous/next are Ctrl+Left/Right. Escape leaves full-window mode.

The native UI is currently **Spanish**. The catalog/engine language can be changed to any of the five existing server languages. Electron's appearance editor, TV mode, remote web UI, taskbar thumbnail toolbar and localStorage preferences are not migrated to this native interface. The native system media controls replace the thumbnail toolbar. Mobile-only offline downloads are not part of the Windows port. List search takes the first match per line and asks the user to review before saving.

## Data and migration

Default profile: `%APPDATA%\MusikeWinUI`. On first launch, `data/library.json` is copied from `%APPDATA%\Musike\data\library.json`, if present; the original is never modified. A copy is retained at `backups/electron-before-winui.json`. An existing native library is never overwritten. A malformed source fails visibly without marking migration successful. The copy includes favorites, playlists and history; web storage settings and an Electron playback session are not copied.

The `MUSIKE_WINUI_DATA_DIR` environment variable can select a separate test profile. `preferences.json` stores native settings and the current queue; `bin` stores extraction tools, `cache` stores HD media, and `backups` stores import/migration copies. Preferences use a temporary file and atomic replacement. Both applications understand `musike-backup` version 1. Native imports currently restore the library; backup appearance settings remain specific to the original UI.

Local diagnostics are written to `logs/application.log`, rotated at 2 MB. They record stream HTTP status, content type, native open/failure/end events, seek origins and unexpected UI exceptions. Stream URLs and authentication tokens are redacted. Empty genre artwork uses the placeholder without invoking WinUI's empty-string image conversion. Playback uses .NET HTTP for both the initial probe and subsequent authenticated byte ranges, with a seekable cache capped at 2 MB per track. Windows receives the opened stream and the actual MIME type, without opening the HTTP URL itself. Closing/changing a track cancels pending reads. Completion requires both a position near the end and sufficient real playback time, accounting for pause, explicit seeks and resume; a native clock jumping to the end cannot consume the queue. Progress-bar refreshes never seek: pointer/keyboard gestures commit the change explicitly.

WinUI detects fragmented DASH audio in the MP4 header. It uses the private FFmpeg installation to copy the compressed audio into a temporary M4A with a continuous sample index before opening it in MediaPlayer. Preparing these tracks requires downloading their audio first. The temporary file is released when playback closes.

## Validation

Local checks with .NET SDK 11.0.100 targeting .NET 10 / Node 24.22.1: the Windows x64 Debug application builds, the shared server passes TypeScript checking, 23 core tests pass, and 6 Node tests pass (lifecycle, lyrics and stream regression tests). Native tests cover real-time WAV/AAC playback and a 120-second AAC file larger than the range cache, with delayed asynchronous reads. An isolated offscreen MainWindow regression also covers blank genre artwork, its real timer, system media controls, programmatic slider refreshes, explicit seeking and normal queue advancement. The live HTTP integration test cannot complete inside the restricted task environment: loopback sockets fail with `connect EACCES 127.0.0.1`, and external DNS is unavailable. The captured 184-second YouTube DASH source reproduced the immediate end with the original pipeline and passed the real-window playback, seek and queue checks after remuxing. A new online playback session remains unverified; passing these tests does not establish that a particular YouTube source decodes correctly.

```powershell
pnpm winui:test
pnpm winui:test:media
pnpm --dir server exec node --test tests/*.test.mjs
pnpm winui:publish
```

Core tests are a dependency-free .NET executable. They cover duplicate queue entries during shuffle, edits/restoration, repeat boundaries, API payloads/errors/credentials, resume persistence and safe migration. Node tests cover the sidecar lifecycle, authenticated HTTP integration, existing stream retries/ranges and lyrics. `.github/workflows/winui.yml` builds a portable Windows artifact and runs these checks.

`winui:test:media` is an optional Windows test requiring a working native audio device. It serves an inaudible two-second sample through a mock HTTP handler, reads it with the production authenticated range cache, and plays it through `MediaSource.CreateFromStream` / `MediaPlayer`. It does not touch the library or contact YouTube. This hardware-dependent check is separate from the default CI suite.

Use `dotnet run --project desktop-winui/Musike.Media.Tests -- --aac --long` for the long AAC case; `--fixture <path>` also saves the generated sample. `--input <path>` checks an existing failing sample's playback clock for 2.5 seconds without contacting YouTube. To exercise the real UI, build Debug, set `MUSIKE_WINUI_DATA_DIR` to an isolated profile, then launch `Musike.WinUI.exe --ui-regression`; `MUSIKE_WINUI_REGRESSION_AUDIO` can select the generated long AAC fixture. This exits with code 0/1 and records the result in the isolated profile's log.

Manual playback checks after a successful build: search and play a song; seek and change tracks while loading; close/reopen and resume; press hardware media keys; toggle video/HD; open timed lyrics; create/edit/import/export a playlist; start Electron alongside WinUI and confirm their libraries are independent. YouTube/network availability and installed Windows codecs can affect playback. Do not describe source-only checks as a verified GUI run.
