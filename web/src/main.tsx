import "./native/ios-legacy/compat";
import "@fontsource-variable/geist";
import "@fontsource-variable/geist-mono";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, HashRouter, MemoryRouter } from "react-router";
import { registerSW } from "virtual:pwa-register";
import App from "./App";
import { desktop } from "./lib/desktop";
import "./styles.css";
import "./tv/tv.css";
import { installTvMode } from "./tv/tvMode";
import { installIosUI } from "./native/ios-ui";

// The desktop app ships its files locally; a service worker would only risk serving an old version after updates.
if (!desktop) registerSW({ immediate: true });

installIosUI();

// Android TV: spatial D-pad navigation + 10-foot styling (no-op elsewhere).
installTvMode();

function legacyRouter() {
  try {
    // HashRouter initializes browser history before its first render. Some WKWebViews
    // reject that call on a custom local origin.
    window.history.replaceState(window.history.state, "");
    return HashRouter;
  } catch {
    return MemoryRouter;
  }
}

const Router = import.meta.env.MUSIKE_LEGACY_IOS ? legacyRouter() : BrowserRouter;

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Router>
      <App />
    </Router>
  </StrictMode>,
);
