import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { test } from "node:test";
import { build } from "esbuild";

test("private native engine authenticates API/media, binds an ephemeral port and preserves public mode", async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), "musike-native-test-"));
  const env = { MUSIKE_DATA_DIR: path.join(temp, "data"), MUSIKE_CACHE_DIR: path.join(temp, "cache"), MUSIKE_WEB_DIST: path.join(temp, "no-web") };
  const before = Object.fromEntries(Object.keys(env).map(key => [key, process.env[key]]));
  Object.assign(process.env, env);
  let privateServer, publicServer;
  try {
    const outfile = path.join(temp, "server.mjs");
    await build({
      entryPoints: [fileURLToPath(new URL("../src/app.ts", import.meta.url))], outfile,
      bundle: true, platform: "node", format: "esm", target: "node22",
      banner: { js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" },
    });
    const { startServer } = await import(pathToFileURL(outfile).href);
    const token = "test-secret-".repeat(4);
    privateServer = await startServer({ host: "127.0.0.1", port: 0, requestToken: token });
    assert.ok(privateServer.port > 0, "port 0 must be resolved to the actual listening port");
    const base = `http://127.0.0.1:${privateServer.port}`;
    const get = (route, credential) => fetch(base + route, credential ? { headers: { "x-musike-token": credential } } : undefined);
    assert.equal((await get("/api/health")).status, 401);
    assert.equal((await get("/api/health", "wrong")).status, 401);
    assert.equal((await get(`/api/health?token=${token}`)).status, 401, "query credentials are restricted to media routes");
    const health = await get("/api/health", token);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { ok: true });
    assert.equal((await get("/api/stream/aaaaaaaaaaa/audio")).status, 401);
    const empty = await get("/api/library", token);
    assert.deepEqual(await empty.json(), { favorites: [], playlists: [], history: [] });
    const created = await fetch(base + "/api/playlists", {
      method: "POST", headers: { "x-musike-token": token, "content-type": "application/json" }, body: JSON.stringify({ name: "Native test", tracks: [] }),
    });
    assert.equal(created.status, 200);
    assert.equal((await created.json()).name, "Native test");
    await privateServer.close(); privateServer = null;
    publicServer = await startServer({ host: "127.0.0.1", port: 0 });
    assert.equal((await fetch(`http://127.0.0.1:${publicServer.port}/api/health`)).status, 200, "existing Electron/web clients must stay compatible");
    const lib = await fetch(`http://127.0.0.1:${publicServer.port}/api/library`);
    assert.equal((await lib.json()).playlists[0].name, "Native test");
  } finally {
    await privateServer?.close(); await publicServer?.close();
    for (const [key, value] of Object.entries(before)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    // mkdtemp returns an absolute child of the OS temporary directory.
    if (path.dirname(temp) !== path.resolve(os.tmpdir())) throw new Error("Unexpected temporary directory");
    await rm(temp, { recursive: true, force: true });
  }
});
