import assert from "node:assert/strict";
import test from "node:test";

test("the iOS player starts and reports playback events without an EventTarget constructor", async (t) => {
  const TestEventTarget = globalThis.EventTarget;
  t.mock.method(globalThis, "EventTarget", function () { throw new TypeError("Illegal constructor"); });
  globalThis.document = { createDocumentFragment: () => new TestEventTarget() };
  t.after(() => { delete globalThis.document; });
  const commands = [];
  globalThis.webkit = { messageHandlers: { musikeAudio: { postMessage: (message) => commands.push(message.cmd) } } };
  const { createAudio } = await import("../src/lib/audio.ts");
  const audio = createAudio();
  const events = [];
  audio.addEventListener("waiting", () => events.push("waiting"));
  audio.addEventListener("playing", () => events.push("playing"));
  const removed = () => events.push("removed listener");
  audio.addEventListener("playing", removed);
  audio.removeEventListener("playing", removed);

  audio.src = "https://example.invalid/audio";
  await audio.play();
  assert.deepEqual(events, [], "a play request alone does not mean playback started");
  globalThis.__musikeAudioEvent("waiting", {});
  globalThis.__musikeAudioEvent("ready", { duration: 120 });
  globalThis.__musikeAudioEvent("playing", {});
  assert.deepEqual(events, ["waiting", "playing"]);

  audio.pause();
  globalThis.__musikeAudioEvent("waiting", {});
  assert.deepEqual(events, ["waiting", "playing"], "a late buffering event does not resume a paused player");
  assert.deepEqual(commands, ["load", "play", "pause"]);

  globalThis.location = new URL("https://musike.example/search");
  audio.src = "/api/stream/example/audio";
  assert.equal(audio.src, "https://musike.example/api/stream/example/audio", "server stream paths become absolute for AVPlayer");
});
