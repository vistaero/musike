import type { LibraryStorage } from "../../../server/src/library";

// WebKit persists this origin in the app's own data store. One atomic localStorage
// assignment keeps the previous library if the process is interrupted while saving.
const key = "musike:library";
export const nativeStorage: LibraryStorage = {
  read: async () => localStorage.getItem(key),
  write: async (json) => { localStorage.setItem(key, json); },
};
