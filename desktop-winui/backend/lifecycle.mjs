/** A sidecar is owned by its stdin pipe. EOF also closes it when the native host crashes. */
export function ownLifetime(input, shutdown) {
  let closing = false;
  const close = () => {
    if (closing) return;
    closing = true;
    shutdown();
  };
  let pending = "";
  input.setEncoding("utf8");
  input.on("data", (chunk) => {
    pending += chunk;
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    if (lines.some((line) => line.trim() === "shutdown")) close();
    if (pending.length > 4096) close();
  });
  input.on("end", close);
  input.on("error", close);
  input.resume();
  return close;
}
