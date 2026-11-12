import { create } from "zustand";
import { getT } from "../i18n";
import { capabilities } from "../lib/api";
import type { OfflineEntry } from "../lib/apiTypes";
import { offline as device } from "../lib/offline";
import type { Track } from "../lib/types";
import { toast } from "./ui";

/**
 * What is saved on the device, and the queue that saves more.
 *
 * One track at a time: yt-dlp and the download itself already use the connection and the CPU, so a playlist fills
 * up in order instead of all at once. Progress is per track, and the caller sees the list grow as each one lands.
 */

interface OfflineState {
  /** True once the saved list has been read from disk, so "not saved" can be trusted. */
  ready: boolean;
  entries: Record<string, OfflineEntry>;
  /** The track being saved right now (0–1 progress), if any. */
  active: { id: string; title: string; progress: number } | null;
  /** Tracks waiting their turn. */
  waiting: Track[];
  init: () => Promise<void>;
  /** Saves tracks (a playlist, a selection, one song), skipping the ones already saved. */
  save: (tracks: Track[]) => Promise<void>;
  remove: (id: string) => Promise<void>;
  /** Removes several at once (a playlist's worth), with a single notice. */
  removeMany: (ids: string[]) => Promise<void>;
  clear: () => Promise<void>;
  isSaved: (id: string) => boolean;
  bytes: () => number;
}

/** Whether the native build supports offline downloads on this device. */
export const offlineUi = () => capabilities.offline;

let working = false;

async function pump() {
  if (working) return;
  working = true;
  let saved = 0;
  let failed = 0;
  let lastName = "";
  try {
    for (;;) {
      const next = useOffline.getState().waiting[0];
      if (!next) break;
      const id = next.id;
      useOffline.setState((s) => ({
        waiting: s.waiting.slice(1),
        active: { id, title: next.title, progress: 0 },
      }));
      try {
        const entry = await device.save(next, (progress) =>
          useOffline.setState((s) => (s.active?.id === id ? { active: { ...s.active, progress } } : {})),
        );
        useOffline.setState((s) => ({ entries: { ...s.entries, [id]: entry } }));
        saved += 1;
        lastName = next.title;
      } catch {
        failed += 1;
      }
      useOffline.setState({ active: null });
    }
  } finally {
    working = false;
  }
  const t = getT().offline;
  if (failed) toast(t.failed(failed), "error");
  else if (saved === 1) toast(t.savedOne(lastName));
  else if (saved > 1) toast(t.savedMany(saved));
}

export const useOffline = create<OfflineState>((set, get) => ({
  ready: false,
  entries: {},
  active: null,
  waiting: [],

  init: async () => {
    if (!device.supported) return set({ ready: true });
    try {
      set({ entries: await device.load(), ready: true });
    } catch {
      set({ ready: true });
    }
  },

  save: async (tracks) => {
    if (!device.supported) return;
    const { entries, waiting, active } = get();
    const queued = new Set(waiting.map((t) => t.id));
    if (active) queued.add(active.id);
    const fresh = tracks.filter((track) => {
      if (entries[track.id] || queued.has(track.id)) return false;
      queued.add(track.id);
      return true;
    });
    if (!fresh.length) return toast(getT().offline.alreadySaved);
    set({ waiting: [...waiting, ...fresh] });
    void pump();
  },

  remove: async (id) => {
    try {
      await device.remove(id);
      set({ entries: await device.load() });
      toast(getT().offline.removed);
    } catch {
      toast(getT().offline.removeFailed, "error");
    }
  },

  removeMany: async (ids) => {
    const results = await Promise.allSettled(ids.map((id) => device.remove(id)));
    set({ entries: await device.load() });
    if (results.some((result) => result.status === "rejected")) {
      toast(getT().offline.removeFailed, "error");
    } else {
      toast(getT().offline.removedAll);
    }
  },

  clear: async () => {
    set({ waiting: [] });
    try {
      await device.clear();
      set({ entries: await device.load() });
      toast(getT().offline.removedAll);
    } catch {
      toast(getT().offline.removeFailed, "error");
    }
  },

  isSaved: (id) => get().entries[id] !== undefined,

  bytes: () => Object.values(get().entries).reduce((sum, e) => sum + (e.size || 0), 0),
}));
