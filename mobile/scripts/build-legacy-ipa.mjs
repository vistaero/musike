import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const mobile = join(dirname(fileURLToPath(import.meta.url)), "..");
const root = join(mobile, "..");
const app = join(mobile, "ios-legacy");
const work = join(app, "build");
const { version } = JSON.parse(readFileSync(join(mobile, "package.json"), "utf8"));
const [major, minor, patch] = version.split(".").map((part) => Number.parseInt(part, 10) || 0);
const build = String(major * 10000 + minor * 100 + patch);
const developer = process.env.DEVELOPER_DIR || "/Applications/Xcode 15.app/Contents/Developer";

// Run the requested Xcode's executable on Sequoia, without changing xcode-select.
const env = { ...process.env, DEVELOPER_DIR: developer };

function run(cmd, args, cwd = app) {
  const result = spawnSync(cmd, args, { cwd, env, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

run("pnpm", ["--filter", "@musike/web", "build:ios-legacy"], root);
const publicDir = join(app, "App", "public");
rmSync(publicDir, { recursive: true, force: true });
cpSync(join(root, "web", "dist-ios-legacy"), publicDir, { recursive: true });

// iOS 12 accepts standalone icons and launch images. Reuse the artwork from the iOS target.
const images = join(app, "App", "LegacyImages");
mkdirSync(images, { recursive: true });
const catalog = join(mobile, "ios", "App", "App", "Assets.xcassets");
const icon = join(catalog, "AppIcon.appiconset", "AppIcon-512@2x.png");
const splash = join(catalog, "Splash.imageset", "splash-2732x2732.png");

for (const [name, size] of [
  ["MusikeIcon60@2x", 120], ["MusikeIcon60@3x", 180], ["MusikeIcon76", 76], ["MusikeIcon76@2x", 152],
]) {
  run("/usr/bin/sips", ["-z", String(size), String(size), icon, "--out", join(images, name + ".png")]);
}
for (const [name, width, height] of [
  ["Launch-568@2x", 640, 1136], ["Launch-667@2x", 750, 1334], ["Launch-736@3x", 1242, 2208],
  ["Launch-812@3x", 1125, 2436], ["Launch-896@2x", 828, 1792], ["Launch-896@3x", 1242, 2688],
  ["Launch-iPad", 768, 1024], ["Launch-iPad@2x", 1536, 2048],
]) {
  const target = join(images, name + ".png");
  run("/usr/bin/sips", ["-Z", String(width), splash, "--out", target]);
  run("/usr/bin/sips", ["-p", String(height), String(width), "--padColor", "0B0C0F", target]);
}

if (process.argv.includes("--prepare")) process.exit(0);

const archive = join(work, "Musike.xcarchive");
run(join(developer, "usr", "bin", "xcodebuild"), [
  "-project", "MusikeLegacy.xcodeproj", "-scheme", "Musike",
  "-configuration", "Release", "-destination", "generic/platform=iOS",
  "-derivedDataPath", join(work, "DerivedData"), "-archivePath", archive,
  "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
  `MARKETING_VERSION=${version}`, `CURRENT_PROJECT_VERSION=${build}`, "archive",
]);

const bundle = join(archive, "Products", "Applications", "Musike.app");
if (!existsSync(bundle)) throw new Error(`Missing archived bundle at ${bundle}`);
const staging = join(work, "ipa");
rmSync(staging, { recursive: true, force: true });
mkdirSync(join(staging, "Payload"), { recursive: true });
cpSync(bundle, join(staging, "Payload", "Musike.app"), { recursive: true });
const target = join(root, "release", `Musike-Setup-${version}-iOS12.ipa`);
mkdirSync(dirname(target), { recursive: true });
rmSync(target, { force: true });
run("/usr/bin/zip", ["-qry", target, "Payload"], staging);
rmSync(staging, { recursive: true, force: true });
console.log(target);
