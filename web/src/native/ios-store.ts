import { createStore, type StateCreator } from "zustand/vanilla";

// SwiftUI observes the store through the bridge; React hooks are unnecessary in the iOS engine.
export function create<T>(initializer: StateCreator<T>) {
  const store = createStore(initializer);
  return Object.assign(<U>(selector: (state: T) => U) => selector(store.getState()), store);
}
