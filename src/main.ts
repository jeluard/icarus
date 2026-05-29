import { load } from '@tauri-apps/plugin-store';
import { keepScreenOn } from "tauri-plugin-keep-screen-on-api";

const SPLASH_DURATION_MS = 3000;

function setBadge(env: string) {
  const badge = document.createElement('div');
  badge.className = 'badge';
  badge.textContent = env;
  document.querySelector('main')!.appendChild(badge);
}

window.addEventListener("DOMContentLoaded", async () => {
  const store = await load('store.json', { autoSave: false, defaults: {} });
  const network = await store.get<{ value: string }>('network');
  keepScreenOn(true);
  setBadge(network?.value ?? "unknown");

  const splash = document.getElementById("splash")!;
  setTimeout(() => {
    splash.addEventListener('transitionend', () => splash.remove());
    splash.classList.add("hidden");
  }, SPLASH_DURATION_MS);
});


