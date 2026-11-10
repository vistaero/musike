import assert from "node:assert/strict";
import test from "node:test";

test("the iOS player reports buffering and only starts after native playback begins", async () => {
  const commands = [];
  globalThis.webkit = { messageHandlers: { musikeAudio: { postMessage: (message) => commands.push(message.cmd) } } };
  const { createAudio } = await import("../src/lib/audio.ts");
  const audio = createAudio();
  const events = [];
  audio.addEventListener("waiting", () => events.push("waiting"));
  audio.addEventListener("playing", () => events.push("playing"));

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
});
