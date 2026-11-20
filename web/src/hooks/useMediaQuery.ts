import { useSyncExternalStore } from "react";

export function useMediaQuery(query: string): boolean {
  return useSyncExternalStore(
    (onChange) => {
      const mql = window.matchMedia(query);
      if (typeof mql.addEventListener !== "function") {
        mql.addListener(onChange);
        return () => mql.removeListener(onChange);
      }
      mql.addEventListener("change", onChange);
      return () => mql.removeEventListener("change", onChange);
    },
    () => window.matchMedia(query).matches,
  );
}

export const MD = "(min-width: 768px)";
export const XL = "(min-width: 1280px)";
