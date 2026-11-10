/** Fixed, non-identifying playback events for the optional iOS diagnostics bridge. */
export function playbackDiagnostic(event: string) {
  const handler = (globalThis as { webkit?: { messageHandlers?: { musikeDiagnostics?: { postMessage: (value: string) => void } } } })
    .webkit?.messageHandlers?.musikeDiagnostics;
  handler?.postMessage(event);
}
