import postcss from "postcss";
import type { Plugin } from "vite";

const LAYERS = ["properties", "theme", "base", "components", "utilities"];

function legacyCss(code: string): string {
  const root = postcss.parse(code);
  const layers = new Map(LAYERS.map((name) => [name, postcss.root()]));
  root.walkAtRules("layer", (layer) => {
    const destination = layers.get(layer.params);
    if (destination && layer.nodes) destination.append(layer.nodes);
    layer.remove();
  });
  root.prepend(...LAYERS.flatMap((name) => layers.get(name)!.nodes));

  root.walkRules((rule) => {
    const group = rule.selector.match(/^(.*):is\(:where\(([^)]+)\)([^)]+)\)$/);
    if (group) rule.selector = group[2] + group[3]!.replace("*", group[1]!);
    const wide = rule.selector.match(/^(.*):where\((html.*) \*\)$/);
    if (wide) rule.selector = wide[2] + " " + wide[1];
    // Tailwind's preflight and descendant utilities. Expand lists separately so one
    // unsupported selector doesn't invalidate the whole selector list on WebKit 12.
    const input = rule.selector.match(/^input:where\(([^)]+)\)$/);
    if (input) rule.selector = input[1]!.split(",").map((selector) => "input" + selector).join(",");
    rule.selector = rule.selector
      .replace(/:where\((\[title\]|\[hidden[^)]+\])\)/g, "$1")
      .replace(/^:where\((select:-webkit-any\([^)]*\))\)/, "$1")
      .replace(/^:where\((\.divide-[^)]*\))\)/, "$1")
      .replace(/^\[hidden\]:where\((:not\([^)]*\))\)/, "[hidden]$1");
    if (rule.selector.includes(":where(") || rule.selector.includes(":is(")) rule.remove();
  });

  root.walkDecls((declaration) => {
    const { prop, value } = declaration;
    const hex = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(value);
    if (prop.startsWith("--") && hex) {
      const color = hex[1]!.length === 3 ? hex[1]!.replace(/./g, "$&$&") : hex[1]!;
      const rgb = color.match(/../g)!.map((channel) => Number.parseInt(channel, 16)).join(",");
      declaration.cloneAfter({ prop: `--legacy-${prop.slice(2)}-rgb`, value: rgb });
    }
    const rewritten = value
      .replace(/color-mix\(in oklab,\s*var\(--([\w-]+)\)\s+([\d.]+)%,\s*transparent\)/g,
        (_, name: string, alpha: string) => `rgba(var(--legacy-${name}-rgb),${Number(alpha) / 100})`)
      .replace(/(\d+(?:\.\d+)?)dvh\b/g, "$1vh")
      .replace(/rgb\((\d+) (\d+) (\d+)\s*\/\s*([.\d]+)\)/g, "rgba($1,$2,$3,$4)");
    if (rewritten !== value) declaration.value = rewritten;
  });
  return root.toString();
}

export function legacyWebKit(): Plugin {
  return {
    name: "musike-legacy-webkit",
    enforce: "post",
    transformIndexHtml: {
      order: "post",
      handler: (html) => html
        .replace(/<script type="module" crossorigin /, "<script defer ")
        .replace('<link rel="stylesheet" crossorigin ', '<link rel="stylesheet" '),
    },
    generateBundle: {
      order: "post",
      handler(_options, output) {
        for (const file of Object.values(output)) {
          if (file.type === "asset" && file.fileName.endsWith(".css") && typeof file.source === "string") {
            file.source = legacyCss(file.source);
          }
        }
      },
    },
  };
}
