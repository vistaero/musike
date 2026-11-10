import { api } from "../lib/api";
import { usePlayer } from "../player/player";
import { useLibrary } from "../stores/library";
import { useAppearance } from "../stores/appearance";
import { useI18n } from "../i18n";
import { useUi } from "../stores/ui";
import type { Track } from "../lib/types";

/** SwiftUI talks to the same stores and backend as the existing app, including its on-device library. */
export function installIosUI() {
  const handler = (globalThis as any).webkit?.messageHandlers?.musikeUI;
  if (!handler) return;
  const sendState = () => {
    const p = usePlayer.getState(), l = useLibrary.getState();
    handler.postMessage({ type: "state", player: {
      queue: p.queue, index: p.index, status: p.status, statusText: p.statusText,
      position: p.position, duration: p.duration, shuffle: p.shuffle, repeat: p.repeat, autoRadio: p.autoRadio,
    }, library: { favorites: l.favorites, history: l.history, playlists: l.playlists, status: l.status },
    appearance: { accent: useAppearance.getState().accent, theme: useUi.getState().theme }, lang: useI18n.getState().lang });
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
        switch (action) {
          case "state": sendState(); break;
          case "search": result = args.kind === "album" ? await api.searchAlbums(args.query) : await api.search(args.query, args.kind); break;
          case "genres": result = await api.genres(); break;
          case "genre": result = await api.genre(args.id); break;
          case "genreArtists": result = await api.genreArtists(args.id, args.offset); break;
          case "artist": result = await api.artist(args.id); break;
          case "album": result = await api.album(args.id); break;
          case "playList": p.playList(args.tracks as Track[], args.index); break;
          case "toggle": p.toggle(); break;
          case "next": p.next(); break;
          case "previous": p.prev(); break;
          case "seek": p.seek(args.position); break;
          case "shuffle": p.toggleShuffle(); break;
          case "repeat": p.cycleRepeat(); break;
          case "autoRadio": p.setAutoRadio(args.enabled); break;
          case "playNext": p.playNext(args.track); break;
          case "addToQueue": p.addToQueue(args.track); break;
          case "jumpTo": p.jumpTo(args.index); break;
          case "removeAt": p.removeAt(args.index); break;
          case "clearUpcoming": p.clearUpcoming(); break;
          case "favorite": await l.toggleFavorite(args.track); break;
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
