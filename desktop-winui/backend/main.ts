import { startServer } from "../../server/src/app.js";
import { ensureComponent, downloads } from "../../server/src/bootstrap.js";
import { ownLifetime } from "./lifecycle.mjs";

// The native host sets every path before Node imports server/config.ts.
const token = process.env.MUSIKE_WINUI_TOKEN;
if (!token || token.length < 32) throw new Error("Missing native host capability.");
const send = (message: unknown) => process.stdout.write(JSON.stringify(message) + "\n");
const server = await startServer({ host: "127.0.0.1", port: 0, requestToken: token,
  onStreamResponse: (response) => send({ type: "stream-response", ...response }) });
const shutdown = ownLifetime(process.stdin, () => {
  void server.close().finally(() => process.exit(0));
  setTimeout(() => process.exit(0), 2500).unref();
});
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
send({ type: "ready", port: server.port });

const progress = setInterval(() => send({ type: "downloads", downloads: downloads("es-ES") }), 1000);
progress.unref();
// Search and the local library are usable while the optional tools install. Failures have a retry in Settings.
void Promise.allSettled([ensureComponent("yt-dlp"), ensureComponent("deno"), ensureComponent("ffmpeg")]).then((results) => {
  clearInterval(progress);
  send({ type: "downloads", downloads: downloads("es-ES") });
  for (const result of results) if (result.status === "rejected") send({ type: "warning", message: String(result.reason) });
});
