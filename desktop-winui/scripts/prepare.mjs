import { createRequire } from "node:module";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
if (process.platform !== "win32" || process.arch !== "x64" || Number(process.versions.node.split(".")[0]) < 22)
  throw new Error("Prepare the package with Windows x64 Node.js 22 or later.");
const requireServer = createRequire(path.join(root, "server", "package.json"));
const { build } = requireServer("esbuild");
const out = path.join(root, "desktop-winui", "Musike.WinUI", "Backend");
await mkdir(out, { recursive: true });
const result = await build({
  entryPoints: [path.join(root, "desktop-winui", "backend", "main.ts")],
  outfile: path.join(out, "server.mjs"),
  bundle: true, platform: "node", format: "esm", target: "node22",
  banner: { js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" },
  logLevel: "warning",
  absWorkingDir: root,
  metafile: true,
});
// Ship the runtime used to build. No global Node installation is needed on the recipient's PC.
await copyFile(process.execPath, path.join(out, "node.exe"));
await copyFile(path.join(root, "LICENSE"), path.join(out, "Musike-LICENSE.txt"));
// Full dependency notices must travel with the portable distribution.
const notices = ["Musike native host includes Node.js and the existing Musike server dependencies."];
const nodeLicense = await readFile(path.join(path.dirname(process.execPath), "LICENSE"), "utf8").catch(async () => {
  // The Windows MSI omits this file; official ZIP distributions include it. Cache for offline rebuilds.
  const cached = path.join(out, `Node-${process.version}-LICENSE.txt`);
  try { return await readFile(cached, "utf8"); } catch (error) { if (error.code !== "ENOENT") throw error; }
  const response = await fetch(`https://raw.githubusercontent.com/nodejs/node/${process.version}/LICENSE`);
  if (!response.ok) throw new Error(`Could not retrieve the Node.js license: HTTP ${response.status}`);
  const text = await response.text();
  await writeFile(cached, text);
  return text;
});
await writeFile(path.join(out, "Node-LICENSE.txt"), nodeLicense);
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  if (!input.includes("node_modules")) continue;
  let folder = path.dirname(path.resolve(root, input));
  while (folder !== path.dirname(folder)) {
    try {
      const pkg = JSON.parse(await readFile(path.join(folder, "package.json"), "utf8"));
      if (pkg.name) { packages.set(folder, pkg); break; }
    } catch (error) { if (error.code !== "ENOENT") throw error; }
    folder = path.dirname(folder);
  }
}
for (const [folder, pkg] of [...packages].sort(([a], [b]) => a.localeCompare(b))) {
  notices.push(`\n${pkg.name} ${pkg.version} — ${pkg.license ?? "see package"}`);
  for (const filename of ["LICENSE", "LICENSE.md", "LICENSE.txt"]) {
    try { notices.push(await readFile(path.join(folder, filename), "utf8")); break; } catch (e) { if (e.code !== "ENOENT") throw e; }
  }
}
await writeFile(path.join(out, "THIRD-PARTY-NOTICES.txt"), notices.join("\n"));
console.log("WinUI sidecar prepared (no Electron or web build).");
