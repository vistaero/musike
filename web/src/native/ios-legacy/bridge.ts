type BridgeResult = { result?: unknown; error?: { message: string; code?: string } };
type Progress = { url: string; bytes: number; contentLength: number };
type LegacyWindow = Window & {
  __musikeLegacyReply?: (id: number, response: BridgeResult) => void;
  __musikeLegacyProgress?: (event: Progress) => void;
  webkit?: { messageHandlers?: { musikeLegacy?: { postMessage: (message: unknown) => void } } };
};

const host = window as LegacyWindow;
const pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
const progress = new Set<(event: Progress) => void>();
let nextId = 0;

host.__musikeLegacyReply = (id, { result, error }) => {
  const entry = pending.get(id);
  if (!entry) return;
  pending.delete(id);
  if (error) entry.reject(Object.assign(new Error(error.message), { code: error.code }));
  else entry.resolve(result);
};
host.__musikeLegacyProgress = (event) => progress.forEach((listener) => listener(event));

function call<T>(method: string, options: object): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const bridge = host.webkit?.messageHandlers?.musikeLegacy;
    if (!bridge) { reject(new Error("Musike's iOS bridge is unavailable.")); return; }
    const id = ++nextId;
    pending.set(id, { resolve: (value) => resolve(value as T), reject });
    try { bridge.postMessage({ id, method, options }); }
    catch (error) { pending.delete(id); reject(error); }
  });
}

export const Capacitor = { getPlatform: () => "ios", isNativePlatform: () => true, convertFileSrc: (path: string) => path };
export const CapacitorHttp = {
  request: (options: object) => call<{ status: number; headers: Record<string, string>; data: string }>("http", options),
};

// Music playback uses the existing iOS message handlers. The Android plugin is never invoked.
export const registerPlugin = () => ({});
export const Directory = { Data: "DATA", Cache: "CACHE" } as const;
export const Encoding = { UTF8: "utf8" } as const;
export const Filesystem = {
  readFile: (options: object) => call<{ data: string }>("readFile", options),
  writeFile: (options: object) => call<{ uri: string }>("writeFile", options),
  deleteFile: (options: object) => call("deleteFile", options),
  rename: (options: object) => call("rename", options),
  mkdir: (options: object) => call("mkdir", options),
  getUri: (options: object) => call<{ uri: string }>("getUri", options),
  stat: (options: object) => call<{ size: number }>("stat", options),
  downloadFile: (options: object) => call("downloadFile", options),
  async addListener(_name: string, listener: (event: Progress) => void) {
    progress.add(listener);
    return { remove: async () => { progress.delete(listener); } };
  },
};
export const Share = { share: (options: object) => call("share", options) };
