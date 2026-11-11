// Serve the iOS engine from the same origin as the web app, without bundling the web UI into that engine.
import { cpSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = join(root, "dist-ios-server");
const target = join(root, "dist");
mkdirSync(join(target, "assets"), { recursive: true });
cpSync(join(source, "assets"), join(target, "assets"), { recursive: true });
cpSync(join(source, "index.html"), join(target, "ios-engine.html"));
rmSync(source, { recursive: true, force: true });
