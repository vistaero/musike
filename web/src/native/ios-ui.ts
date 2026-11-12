import { api, capabilities } from "../lib/api";
import { radioTracks, usePlayer } from "../player/player";
import { useLibrary } from "../stores/library";
import { useAppearance } from "../stores/appearance";
import { useI18n } from "../i18n";
import { useUi } from "../stores/ui";
import type { Track } from "../lib/types";
import { createBackup, readBackup, restoreBackup, summarize } from "../lib/backup";
import { isLang } from "../i18n";
import { playbackDiagnostic } from "./diagnostics";

/** SwiftUI talks to the same stores and backend as the existing app, including its on-device library. */
export function installIosUI() {
  const handler = (globalThis as any).webkit?.messageHandlers?.musikeUI;
  if (!handler) return;
  let lastStatus = "";
  const sendState = () => {
    const p = usePlayer.getState(), l = useLibrary.getState();
    if (p.status !== lastStatus) { lastStatus = p.status; playbackDiagnostic(`player.status.${p.status}`); }
    handler.postMessage({ type: "state", player: {
      queue: p.queue, index: p.index, status: p.status, statusText: p.statusText,
      position: p.position, duration: p.duration, shuffle: p.shuffle, repeat: p.repeat, autoRadio: p.autoRadio,
      currentDisliked: p.dislikedTrackIDs.includes(p.queue[p.index]?.id),
      volume: p.volume, muted: p.muted, errorText: typeof p.statusText === "object" && p.statusText ? p.statusText.error : null,
    }, library: { favorites: l.favorites, history: l.history, playlists: l.playlists, status: l.status },
    appearance: { accent: useAppearance.getState().accent, homeShortcuts: useAppearance.getState().homeShortcuts,
      homeRecent: useAppearance.getState().homeRecent, homeFavorites: useAppearance.getState().homeFavorites, theme: useUi.getState().theme }, lang: useI18n.getState().lang,
      engineSettings: capabilities.engineSettings });
  };
  let scheduled = false;
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => { scheduled = false; sendState(); }, 100);
  };
  usePlayer.subscribe(schedule); useLibrary.subscribe(schedule); useAppearance.subscribe(schedule);
  useI18n.subscribe(schedule); useUi.subscribe(schedule);
  (globalThis as any).musikeNative = {
    async dispatch(request: { id: number; action: string; args?: any }) {
      const { id, action, args = {} } = request;
      try {
        const p = usePlayer.getState(), l = useLibrary.getState();
        let result: unknown = null;
        if (["playList", "playTrack", "toggle", "next", "previous", "jumpTo"].includes(action)) playbackDiagnostic(`command.${action.toLowerCase()}`);
        switch (action) {
          case "state": sendState(); break;
          case "system": result = await api.system(); break;
          case "updateEngine":
            if (args.channel !== "stable" && args.channel !== "nightly") throw new Error("Invalid channel.");
            result = await api.updateYtdlp(args.channel);
            break;
          case "search": result = args.kind === "album" ? await api.searchAlbums(args.query) : await api.search(args.query, args.kind); break;
          case "suggest": result = await api.suggest(args.query); break;
          case "prepare": result = await api.prepare(args.id); break;
          case "recentSearches": {
            try { const value: unknown = JSON.parse(localStorage.getItem("musike:recent-searches") ?? "[]");
              result = Array.isArray(value) ? value.filter((item): item is string => typeof item === "string").slice(0, 8) : [];
            } catch { result = []; }
            break;
          }
          case "recordRecentSearch": {
            let previous: string[] = [];
            try { const value: unknown = JSON.parse(localStorage.getItem("musike:recent-searches") ?? "[]");
              if (Array.isArray(value)) previous = value.filter((item): item is string => typeof item === "string");
            } catch { /* Start a new list if the stored value is invalid. */ }
            const query = String(args.query ?? "").trim();
            const next = query ? [query, ...previous.filter((item) => item.toLowerCase() !== query.toLowerCase())].slice(0, 8) : previous;
            try { localStorage.setItem("musike:recent-searches", JSON.stringify(next)); } catch { /* Storage is optional. */ }
            result = next;
            break;
          }
          case "clearRecentSearches":
            try { localStorage.setItem("musike:recent-searches", "[]"); } catch { /* Storage is optional. */ }
            break;
          case "genres": result = await api.genres(); break;
          case "genre": result = await api.genre(args.id); break;
          case "genreArtists": result = await api.genreArtists(args.id, args.offset); break;
          case "artist": result = await api.artist(args.id); break;
          case "album": result = await api.album(args.id); break;
          case "playList": p.playList(args.tracks as Track[], args.index); break;
          case "playTrack": p.playTrack(args.track as Track); break;
          case "toggle": p.toggle(); break;
          case "next": p.next(); break;
          case "previous": p.prev(); break;
          case "seek": p.seek(args.position); break;
          case "shuffle": p.toggleShuffle(); break;
          case "repeat": p.cycleRepeat(); break;
          case "autoRadio": p.setAutoRadio(args.enabled); break;
          case "startRadio": {
            const track = args.track as Track;
            const related = await radioTracks(track.id);
            p.playList([track, ...related], 0);
            break;
          }
          case "dislike": if (typeof args.id === "string" && args.id) p.toggleDislikedTrack(args.id); break;
          case "volume": p.setVolume(args.value); break;
          case "mute": p.toggleMute(); break;
          case "theme": if (args.value === "dark" || args.value === "light") useUi.getState().setTheme(args.value); break;
          case "language": if (isLang(args.value)) useI18n.getState().setLang(args.value); break;
          case "appearance": useAppearance.getState().set(args.patch); break;
          case "resetAppearance": useAppearance.getState().reset(); useUi.getState().setPanelDocked(true); break;
          case "createBackup": result = await createBackup(); break;
          case "previewBackup": {
            const backup = await readBackup(new File([JSON.stringify(args.backup)], "backup.json"));
            const summary = summarize(backup);
            result = { playlists: summary.playlists, playlistTracks: summary.playlistTracks, favorites: summary.favorites,
              history: summary.history, hasSettings: !!backup.settings };
            break;
          }
          case "restoreBackup": {
            const backup = await readBackup(new File([JSON.stringify(args.backup)], "backup.json"));
            if (args.mode !== "merge" && args.mode !== "replace") throw new Error("Invalid import mode");
            result = await restoreBackup(backup, args.mode, !!args.applySettings);
            break;
          }
          case "playNext": p.playNext(args.track); break;
          case "addToQueue": p.addToQueue(args.track); break;
          case "jumpTo": p.jumpTo(args.index); break;
          case "removeAt": p.removeAt(args.index); break;
          case "clearUpcoming": p.clearUpcoming(); break;
          case "favorite": await l.toggleFavorite(args.track); break;
          case "batchAddFavorites": await api.addFavorites(args.tracks as Track[]); await l.load(); break;
          case "batchAddToPlaylist": await api.addToPlaylist(args.id, args.tracks as Track[]); await l.load(); break;
          case "batchCreatePlaylist": result = await api.createPlaylist(args.name, args.tracks as Track[]); await l.load(); break;
          case "createPlaylist": result = await l.createPlaylist(args.name); break;
          case "renamePlaylist": await l.renamePlaylist(args.id, args.name); break;
          case "deletePlaylist": await l.deletePlaylist(args.id); break;
          case "addToPlaylist": await l.addToPlaylist(args.id, args.track); break;
          case "removeFromPlaylist": await l.removeFromPlaylist(args.id, args.trackId); break;
          default: throw new Error(`Unknown action: ${action}`);
        }
        handler.postMessage({ type: "response", id, result: result ?? null });
      } catch (error) {
        handler.postMessage({ type: "response", id, error: (error as Error).message || String(error) });
      }
    },
  };
  handler.postMessage({ type: "ready" });
  sendState();
}
