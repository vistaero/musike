import { Capacitor } from "@capacitor/core";
import { Directory, Encoding, Filesystem } from "@capacitor/filesystem";
import type { OfflineApi, OfflineEntry } from "../lib/apiTypes";
import type { Track } from "../lib/types";
import { resolveAudio } from "./streams";

const DIR = "offline";
const LEGACY_INDEX = `${DIR}/index.json`;
const INDEXES = [`${DIR}/index-a.json`, `${DIR}/index-b.json`] as const;
const where = { directory: Directory.Data } as const;
const UA =
  "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36";

interface Index {
  generation: number;
  entries: Record<string, OfflineEntry>;
}

let entries: Record<string, OfflineEntry> | null = null;
let generation = 0;
let reading: Promise<Record<string, OfflineEntry>> | null = null;
let pendingMutation: Promise<void> = Promise.resolve();
const localSrc = new Map<string, string>();
const watchers = new Map<string, (fraction: number) => void>();
let listening = false;

function listen() {
  if (listening) return;
  listening = true;
  void Filesystem.addListener("progress", ({ url, bytes, contentLength }) => {
    watchers.get(url)?.(contentLength > 0 ? Math.min(1, bytes / contentLength) : 0);
  });
}

async function ensureDir() {
  try {
    await Filesystem.mkdir({ path: DIR, ...where, recursive: true });
  } catch (error) {
    if ((error as { code?: string }).code !== "OS-PLUG-FILE-0010") throw error;
  }
}

function url(file: string): Promise<string> {
  return Filesystem.getUri({ path: file, ...where }).then(({ uri }) =>
    Capacitor.getPlatform() === "ios" ? uri : Capacitor.convertFileSrc(uri),
  );
}

async function readJson(path: string): Promise<unknown> {
  let data: string | Blob;
  try {
    ({ data } = await Filesystem.readFile({ path, ...where, encoding: Encoding.UTF8 }));
  } catch (error) {
    if ((error as { code?: string }).code === "OS-PLUG-FILE-0008") return null;
    throw error;
  }
  try {
    return JSON.parse(typeof data === "string" ? data : await data.text()) as unknown;
  } catch {
    return null;
  }
}

function isRecord(value: unknown): value is Record<string, OfflineEntry> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

async function read(): Promise<Record<string, OfflineEntry>> {
  const candidates = await Promise.all(INDEXES.map(readJson));
  const valid = candidates.filter((value): value is Index => {
    if (!value || typeof value !== "object") return false;
    const index = value as Partial<Index>;
    return Number.isSafeInteger(index.generation) && (index.generation ?? 0) > 0 && isRecord(index.entries);
  });
  valid.sort((a, b) => b.generation - a.generation);
  if (valid[0]) {
    generation = valid[0].generation;
    return valid[0].entries;
  }
  const legacy = await readJson(LEGACY_INDEX);
  return isRecord(legacy) ? legacy : {};
}

/** Alternate index files so an interrupted write leaves the previous generation readable. */
async function write(record: Record<string, OfflineEntry>) {
  await ensureDir();
  const next = generation + 1;
  await Filesystem.writeFile({
    path: INDEXES[next % 2],
    data: JSON.stringify({ generation: next, entries: record } satisfies Index),
    ...where,
    encoding: Encoding.UTF8,
  });
  generation = next;
}

function load(): Promise<Record<string, OfflineEntry>> {
  if (entries) return Promise.resolve(entries);
  reading ??= read()
    .then(async (record) => {
      await Promise.all(
        Object.entries(record).map(([id, entry]) =>
          url(entry.file)
            .then((src) => localSrc.set(id, src))
            .catch(() => {}),
        ),
      );
      entries = record;
      return record;
    })
    .finally(() => {
      reading = null;
    });
  return reading;
}

/** Serializing mutations prevents downloads and removals from overwriting each other's index updates. */
function mutate<T>(work: () => Promise<T>): Promise<T> {
  const result = pendingMutation.then(work);
  pendingMutation = result.then(() => {}, () => {});
  return result;
}

export const offline: OfflineApi = {
  supported: true,
  load,
  entry: async (id) => (await load())[id] ?? null,

  save: (track: Track, onProgress: (fraction: number) => void) =>
    mutate(async () => {
      const known = await load();
      if (known[track.id]) return known[track.id];

      listen();
      await ensureDir();
      const resolved = await resolveAudio(track.id);
      const extension = resolved.mime.includes("mp4") ? "m4a" : "webm";
      const file = `${DIR}/${track.id}-${Date.now()}-${Math.random().toString(36).slice(2)}.${extension}`;
      const partial = `${file}.part`;
      watchers.set(resolved.url, onProgress);
      try {
        await Filesystem.downloadFile({
          url: resolved.url,
          path: partial,
          ...where,
          progress: true,
          headers: { "User-Agent": UA },
        });
        await Filesystem.rename({ from: partial, to: file, ...where, toDirectory: Directory.Data });
        const { size } = await Filesystem.stat({ path: file, ...where });
        const src = await url(file);
        const entry: OfflineEntry = { track, size: Number(size) || 0, at: Date.now(), file };
        const record = { ...known, [track.id]: entry };
        await write(record);
        entries = record;
        localSrc.set(track.id, src);
        return entry;
      } catch (error) {
        await Filesystem.deleteFile({ path: partial, ...where }).catch(() => {});
        await Filesystem.deleteFile({ path: file, ...where }).catch(() => {});
        throw error;
      } finally {
        watchers.delete(resolved.url);
      }
    }),

  remove: (id) =>
    mutate(async () => {
      const record = { ...(await load()) };
      const entry = record[id];
      if (!entry) return;
      delete record[id];
      await write(record);
      entries = record;
      localSrc.delete(id);
      await Filesystem.deleteFile({ path: entry.file, ...where }).catch(() => {});
    }),

  clear: () =>
    mutate(async () => {
      const record = await load();
      await write({});
      entries = {};
      localSrc.clear();
      await Promise.all(Object.values(record).map((entry) =>
        Filesystem.deleteFile({ path: entry.file, ...where }).catch(() => {}),
      ));
    }),

  src: async (id) => {
    await load();
    return localSrc.get(id) ?? null;
  },
};
