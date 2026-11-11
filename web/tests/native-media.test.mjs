import assert from "node:assert/strict";
import test from "node:test";

test("the iOS media bridge reports metadata and handles remote controls", async () => {
  const messages = [];
  globalThis.webkit = { messageHandlers: { musikeMedia: { postMessage: (message) => messages.push(message) } } };
  const { iosMedia } = await import("../src/native/ios-media.ts");
  assert.ok(iosMedia);
  iosMedia.setTrack({ title: "Song", artist: "Artist", album: "Album", artwork: "" });
  iosMedia.setState({ playing: true, position: 12, duration: 100 });
  assert.equal(messages[0].type, "track");
  assert.equal(messages[0].title, "Song");
  assert.deepEqual(messages[1], { type: "state", playing: true, position: 12, duration: 100 });
  const actions = [];
  iosMedia.onAction((action, position) => actions.push([action, position]));
  globalThis.__musikeMediaAction("seek", 30);
  globalThis.__musikeMediaAction("pause");
  assert.deepEqual(actions, [["seek", 30], ["pause", undefined]]);
});
