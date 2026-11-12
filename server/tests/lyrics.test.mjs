import assert from "node:assert/strict";
import { test } from "node:test";
import { lyricsFor, parseLrc } from "../src/lyrics.ts";

test("parses and orders repeated LRC timestamps", () => {
  assert.deepEqual(parseLrc("[00:03.50] First\n[00:01.00][00:02.00] Again"), [
    { time: 1, text: "Again" },
    { time: 2, text: "Again" },
    { time: 3.5, text: "First" },
  ]);
});

test("retries failed lookups and shares successful requests", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    if (calls === 1) throw new Error("connection lost");
    return new Response(
      JSON.stringify({ syncedLyrics: "[00:01.00] One\n[00:02.00] Two", duration: 120 }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };
  try {
    const track = { id: "retry-test", title: "Song", artist: "Artist", duration: 120 };
    await assert.rejects(lyricsFor(track), /connection lost/);
    const [first, second] = await Promise.all([lyricsFor(track), lyricsFor(track)]);
    assert.equal(calls, 2);
    assert.equal(first.synced, true);
    assert.deepEqual(first, second);
    await lyricsFor(track);
    assert.equal(calls, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
