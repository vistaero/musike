import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { build } = require("esbuild");

const files = new Map();
let writeFailure = false;
let readFailure = false;
let downloads = 0;
const missing = () => Object.assign(new Error("File does not exist"), { code: "OS-PLUG-FILE-0008" });

globalThis.__offlineMocks = {
  Capacitor: { getPlatform: () => "ios", convertFileSrc: (url) => `converted:${url}` },
  Directory: { Data: "DATA" },
  Encoding: { UTF8: "utf8" },
  Filesystem: {
    async addListener() {},
    async mkdir() {},
    async getUri({ path }) { return { uri: `file:///${path}` }; },
    async readFile({ path }) {
      if (readFailure) throw Object.assign(new Error("Permission denied"), { code: "OS-PLUG-FILE-0007" });
      if (!files.has(path)) throw missing();
      return { data: files.get(path) };
    },
    async writeFile({ path, data }) {
      if (writeFailure) {
        files.set(path, "{truncated");
        writeFailure = false;
        throw new Error("Interrupted write");
      }
      files.set(path, data);
    },
    async downloadFile({ path }) {
      downloads++;
      await new Promise((resolve) => setTimeout(resolve, 2));
      files.set(path, "audio");
    },
    async rename({ from, to }) {
      if (!files.has(from)) throw missing();
      files.set(to, files.get(from));
      files.delete(from);
    },
    async stat({ path }) {
      if (!files.has(path)) throw missing();
      return { size: files.get(path).length };
    },
    async deleteFile({ path }) { files.delete(path); },
  },
  resolveAudio: async (id) => ({ url: `https://audio.invalid/${id}`, mime: "audio/mp4" }),
};

const bundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/native/offline.ts", import.meta.url))],
  bundle: true,
  platform: "node",
  format: "esm",
  write: false,
  plugins: [{
    name: "mock-native",
    setup(api) {
      api.onResolve({ filter: /^@capacitor\/(core|filesystem)$/ }, (args) => ({ path: args.path, namespace: "mock" }));
      api.onResolve({ filter: /^\.\/streams$/ }, () => ({ path: "streams", namespace: "mock" }));
      api.onLoad({ filter: /.*/, namespace: "mock" }, ({ path }) => ({
        contents: path === "@capacitor/core"
          ? "export const Capacitor = globalThis.__offlineMocks.Capacitor;"
          : path === "@capacitor/filesystem"
            ? "export const { Directory, Encoding, Filesystem } = globalThis.__offlineMocks;"
            : "export const resolveAudio = globalThis.__offlineMocks.resolveAudio;",
        loader: "js",
      }));
    },
  }],
});
const encoded = Buffer.from(bundle.outputFiles[0].text).toString("base64");
let instance = 0;
const loadModule = async () => (await import(`data:text/javascript;base64,${encoded}#${++instance}`)).offline;
const track = (id) => ({ id, title: id, artist: "artist", album: "", duration: 60, kind: "song", thumb: "", art: "" });
const old = { track: track("legacy"), size: 7, at: 1, file: "offline/legacy.m4a" };
files.set("offline/index.json", JSON.stringify({ legacy: old }));
files.set(old.file, "old song");

let offline = await loadModule();
assert.deepEqual(Object.keys(await offline.load()), ["legacy"]);
assert.equal(await offline.src("legacy"), "file:///offline/legacy.m4a");
const [first, second] = await Promise.all([offline.save(track("first"), () => {}), offline.save(track("second"), () => {})]);
assert.deepEqual(Object.keys(await offline.load()).sort(), ["first", "legacy", "second"]);
assert.ok(files.has(first.file) && files.has(second.file));
await offline.save(track("first"), () => {});
assert.equal(downloads, 2);

writeFailure = true;
await assert.rejects(offline.save(track("failed"), () => {}), /Interrupted write/);
assert.deepEqual(Object.keys(await offline.load()).sort(), ["first", "legacy", "second"]);
offline = await loadModule();
assert.deepEqual(Object.keys(await offline.load()).sort(), ["first", "legacy", "second"]);
await Promise.all([offline.remove("legacy"), offline.remove("first")]);
assert.deepEqual(Object.keys(await offline.load()), ["second"]);
assert.ok(!files.has(old.file) && !files.has(first.file));
const saving = offline.save(track("last"), () => {});
const clearing = offline.clear();
await Promise.all([saving, clearing]);
assert.deepEqual(await offline.load(), {});
offline = await loadModule();
assert.deepEqual(await offline.load(), {});

readFailure = true;
offline = await loadModule();
await assert.rejects(offline.load(), /Permission denied/);
readFailure = false;
console.log("Offline storage: legacy migration, concurrency, duplicate saves, interrupted writes, clearing and read errors passed");
