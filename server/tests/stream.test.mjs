import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

test("retries a rejected direct audio URL with yt-dlp and preserves the byte range", async () => {
  const resolutions = [];
  const invalidations = [];
  globalThis.__streamTest = {
    resolveStreams: async (id, kind, ytdlpOnly) => {
      resolutions.push({ id, kind, ytdlpOnly });
      return { audio: { url: ytdlpOnly ? "https://audio.invalid/retry" : "https://audio.invalid/direct", headers: {}, mime: "audio/mp4" } };
    },
    invalidate: (id, kind) => invalidations.push({ id, kind }),
  };
  const result = await build({
    entryPoints: [fileURLToPath(new URL("../src/stream.ts", import.meta.url))],
    bundle: true,
    platform: "node",
    format: "esm",
    write: false,
    plugins: [{
      name: "mock-resolver",
      setup(api) {
        api.onResolve({ filter: /^\.\/ytdlp\.js$/ }, () => ({ path: "resolver", namespace: "mock" }));
        api.onLoad({ filter: /.*/, namespace: "mock" }, () => ({
          contents: "export const { resolveStreams, invalidate } = globalThis.__streamTest;",
          loader: "js",
        }));
      },
    }],
  });
  const source = Buffer.from(result.outputFiles[0].text).toString("base64");
  const { proxyStream } = await import(`data:text/javascript;base64,${source}`);
  const originalFetch = globalThis.fetch;
  const requested = [];
  globalThis.fetch = async (url, options) => {
    requested.push({ url, range: options.headers.Range });
    return requested.length === 1
      ? new Response("denied", { status: 403 })
      : new Response("abc", { status: 206, headers: { "content-range": "bytes 10-12/100" } });
  };
  const headers = {};
  const raw = new EventEmitter();
  raw.writableFinished = true;
  const reply = {
    raw,
    code(status) { this.status = status; return this; },
    header(name, value) { headers[name] = value; return this; },
    send(body) { return body; },
  };
  try {
    const body = await proxyStream({ headers: { range: "bytes=10-12" } }, reply, "track", "audio");
    const chunks = [];
    for await (const chunk of body) chunks.push(chunk);
    assert.equal(Buffer.concat(chunks).toString(), "abc");
    assert.deepEqual(resolutions, [
      { id: "track", kind: "audio", ytdlpOnly: false },
      { id: "track", kind: "audio", ytdlpOnly: true },
    ]);
    assert.deepEqual(invalidations, [{ id: "track", kind: "audio" }]);
    assert.deepEqual(requested.map((request) => request.range), ["bytes=10-12", "bytes=10-12"]);
    assert.equal(reply.status, 206);
    assert.equal(headers["content-range"], "bytes 10-12/100");
  } finally {
    globalThis.fetch = originalFetch;
    delete globalThis.__streamTest;
  }
});
