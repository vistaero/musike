import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "vite";

for (const [mode, backend] of [["ios", "/src/native/api.ts"], ["ios-server", "/src/lib/api.ts"]]) {
  test(`the ${mode} engine excludes the web UI and React`, async () => {
    const root = fileURLToPath(new URL("..", import.meta.url));
    const built = await build({ root, mode, logLevel: "silent", build: { write: false, minify: false } });
    const bundles = Array.isArray(built) ? built : [built];
    const modules = bundles.flatMap((bundle) => bundle.output.flatMap((item) => item.type === "chunk" ? Object.keys(item.modules) : []));
    assert.ok(modules.some((id) => id.endsWith("/src/native/ios-main.ts")), "the iOS entry point must be used");
    assert.ok(modules.some((id) => id.endsWith("/src/native/ios-store.ts")), "the engine must use the headless store adapter");
    assert.ok(modules.some((id) => id.endsWith(backend)), "the expected backend must be used");
    const oldUI = modules.filter((id) => /\/src\/(views|components)\//.test(id) || /\/node_modules\/(?:\.pnpm\/)?(?:react|react-dom|react-router)(?:@|\/)/.test(id));
    assert.deepEqual(oldUI, [], `the iOS engine should not include web screens or React: ${oldUI.join(", ")}`);
  });
}
