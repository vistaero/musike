// The iOS interface is SwiftUI. Keep only the shared catalog, library and player running in Capacitor.
import { installIosUI } from "./ios-ui";
import { useLibrary } from "../stores/library";
import { useOffline } from "../stores/offline";

installIosUI();
void useLibrary.getState().load();
void useOffline.getState().init();
