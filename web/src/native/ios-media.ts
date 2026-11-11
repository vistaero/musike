import type { SystemMedia } from "../lib/apiTypes";

interface MessageBridge { postMessage(message: unknown): void }
const bridge = (globalThis as { webkit?: { messageHandlers?: { musikeMedia?: MessageBridge } } }).webkit?.messageHandlers?.musikeMedia;
let last = { playing: false, position: 0, at: 0 };

/** Native lock-screen controls are also available when iOS is connected to a Musike server. */
export const iosMedia: SystemMedia | null = bridge ? {
  setTrack(track) {
    last = { playing: last.playing, position: 0, at: Date.now() };
    bridge.postMessage({ type: "track", ...track, position: 0 });
  },
  setState({ playing, position, duration }) {
    const now = Date.now();
    const expected = last.playing ? last.position + (now - last.at) / 1000 : last.position;
    if (playing === last.playing && Math.abs(position - expected) < 2 && now - last.at < 15_000) return;
    last = { playing, position, at: now };
    bridge.postMessage({ type: "state", playing, position, duration: Number.isFinite(duration) ? duration : 0 });
  },
  onAction(handler) {
    (globalThis as { __musikeMediaAction?: (action: string, position?: number) => void }).__musikeMediaAction =
      (action, position) => handler(action as Parameters<typeof handler>[0], position);
  },
} : null;
