import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Script } from "node:vm";
import { build } from "vite";

for (const [mode, backend] of [["ios", "/src/native/api.ts"], ["ios-server", "/src/lib/api.ts"], ["mac", "/src/native/api.ts"]]) {
  test(`the ${mode} engine excludes the web UI and React`, async () => {
    const root = fileURLToPath(new URL("..", import.meta.url));
    const built = await build({ root, mode, logLevel: "silent", build: { write: false, minify: false } });
    const bundles = Array.isArray(built) ? built : [built];
    const modules = bundles.flatMap((bundle) => bundle.output.flatMap((item) => item.type === "chunk" ? Object.keys(item.modules) : []));
    assert.ok(modules.some((id) => id.endsWith("/src/native/ios-main.ts")), "the iOS entry point must be used");
    assert.ok(modules.some((id) => id.endsWith("/src/native/ios-store.ts")), "the engine must use the headless store adapter");
    assert.ok(modules.some((id) => id.endsWith(backend)), "the expected backend must be used");
    if (mode === "mac") {
      assert.ok(modules.some((id) => id.endsWith("/src/native/mac-storage.ts")), "Mac must use its own persistent storage");
      assert.ok(!modules.some((id) => id.endsWith("/src/native/storage.ts")), "Mac must not use the iOS filesystem plugin");
      assert.ok(modules.some((id) => id.endsWith("/src/lib/offline.ts")), "Mac must use the offline fallback");
      assert.ok(!modules.some((id) => id.endsWith("/src/native/offline.ts")), "Mac cannot use the Capacitor offline plugin");
    }
    if (mode === "ios") {
      assert.ok(modules.some((id) => id.endsWith("/src/native/offline.ts")), "iOS must use native offline storage");
    }
    const oldUI = modules.filter((id) => /\/src\/(views|components)\//.test(id) || /\/node_modules\/(?:\.pnpm\/)?(?:react|react-dom|react-router)(?:@|\/)/.test(id));
    assert.deepEqual(oldUI, [], `the iOS engine should not include web screens or React: ${oldUI.join(", ")}`);
  });
}


test("the legacy iOS bundle exposes a classic entry script for the native startup controller", async () => {
  const root = fileURLToPath(new URL("..", import.meta.url));
  const bundle = await build({ root, mode: "ios-legacy", logLevel: "silent", build: { write: false } });
  const outputs = (Array.isArray(bundle) ? bundle : [bundle]).flatMap((result) => result.output);
  const script = outputs.find((item) => item.type === "chunk" && item.fileName === "assets/legacy-app.js");
  const html = outputs.find((item) => item.type === "asset" && item.fileName === "index.html");
  assert.ok(script, "Xcode's bundled JavaScript entry must exist at its stable path");
  assert.ok(html);
  assert.doesNotThrow(() => new Script(script.code), "WebKit evaluates a classic script, not a module");
  assert.match(String(html.source), /<div id="root"><\/div>/);
  assert.doesNotMatch(String(html.source), /<script[^>]+src=/, "the controller loads the app exactly once");
});
