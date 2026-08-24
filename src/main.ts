import { load } from '@tauri-apps/plugin-store';
import { keepScreenOn } from "tauri-plugin-keep-screen-on-api";

const SPLASH_DURATION_MS = 3000;
const DASHBOARD_STARTUP_TIMEOUT_MS = 30_000;
const DASHBOARD_RETRY_INTERVAL_MS = 250;
const REQUEST_TIMEOUT_MS = 2_000;
const DASHBOARD_ORIGIN = "http://127.0.0.1:8081";
const DASHBOARD_WS_URL = "ws://127.0.0.1:8081/ws";
const DASHBOARD_URL = `${DASHBOARD_ORIGIN}/amaru-dashboard/#ws=${encodeURIComponent(DASHBOARD_WS_URL)}`;

const delay = (duration: number) => new Promise((resolve) => setTimeout(resolve, duration));

async function isAvailable(url: string): Promise<boolean> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const response = await fetch(url, { cache: "no-store", signal: controller.signal });
    return response.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

async function waitForDashboard(): Promise<void> {
  const deadline = Date.now() + DASHBOARD_STARTUP_TIMEOUT_MS;

  while (Date.now() < deadline) {
    if (
      await isAvailable(`${DASHBOARD_ORIGIN}/health`) &&
      await isAvailable(DASHBOARD_URL)
    ) {
      return;
    }
    await delay(DASHBOARD_RETRY_INTERVAL_MS);
  }

  throw new Error("dashboard did not become available within 30 seconds");
}

function setBadge(env: string) {
  const badge = document.createElement('div');
  badge.className = 'badge';
  badge.textContent = env;
  document.querySelector('main')!.appendChild(badge);
}

window.addEventListener("DOMContentLoaded", async () => {
  const splash = document.getElementById("splash")!;
  const status = document.getElementById("startup-status")!;
  const dashboard = document.getElementById("dashboard") as HTMLIFrameElement;

  try {
    const store = await load("store.json", { autoSave: false, defaults: {} });
    const network = await store.get<{ value: string }>("network");
    setBadge(network?.value ?? "unknown");
  } catch (error) {
    console.error("Failed to load application settings", error);
    setBadge("unknown");
  }

  void keepScreenOn(true).catch((error) => console.error("Failed to keep screen on", error));

  try {
    await Promise.all([delay(SPLASH_DURATION_MS), waitForDashboard()]);
    await new Promise<void>((resolve) => {
      dashboard.addEventListener("load", () => resolve(), { once: true });
      dashboard.src = DASHBOARD_URL;
    });

    splash.addEventListener('transitionend', () => splash.remove());
    splash.classList.add("hidden");
  } catch (error) {
    console.error("Failed to start dashboard", error);
    status.textContent = "Dashboard unavailable. Check the device logs and retry.";
    status.classList.add("error");
  }
});
