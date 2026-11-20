import assert from "node:assert/strict";
import { test } from "node:test";
import { clearHistory, useLibraryStorage } from "../src/library.ts";

test("clearing playback history persists an empty list without changing other library data", async () => {
  const favorite = { id: "favorite01" };
  const played = { id: "played0001" };
  let saved = JSON.stringify({ favorites: [favorite], playlists: [], history: [played] });

  useLibraryStorage({
    read: async () => saved,
    write: async (json) => { saved = json; },
  });

  assert.deepEqual(await clearHistory(), []);
  assert.deepEqual(JSON.parse(saved), { favorites: [favorite], playlists: [], history: [] });
});
