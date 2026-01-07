import { listen } from "@tauri-apps/api/event";
import { load } from '@tauri-apps/plugin-store';
import { keepScreenOn } from "tauri-plugin-keep-screen-on-api";
import { AppEvent } from "./events";

const THROTTLE_MS = 2000;
const SPLASH_DURATION_MS = 3000;

function eventToMessage(event: AppEvent["payload"]): Message | string | null {
  if (event.kind == "downloading_snapshot") {
    return `Downloading snapshot for epoch ${event.epoch}`;
  } else if (event.kind == "snapshots_downloaded") {
    return `All snapshots downloaded`;
  } else if (event.kind == "importing_snapshot") {
    return null;
  } else if (event.kind == "importing_snapshots") {
    return `Importing snapshots`;
  } else if (event.kind == "imported_snapshot") {
    return null;
  } else if (event.kind == "imported_snapshots") {
    return `Imported all snapshots`;
  } else if (event.kind == "starting") {
    return `Initial slot ${event.tip}`;
  } else if (event.kind == "creating_state") {
    return `Creating state from past epochs`;
  } else if (event.kind == "epoch_transition") {
    return `Epoch transition from ${event.from} into ${event.into}`;
  } else if (event.kind == "tip_caught_up") {
    return `Tip caught up at slot ${event.slot}`;
  } else if (event.kind == "tip_syncing") {
    return {
      content: `Tip syncing at slot ${event.slot}`,
      explode: true,
    };
  } else {
    return JSON.stringify(event);
  }
}

function spawnGhost(text: string, box: Element) {
  const ghost = document.createElement('div');
  ghost.className = 'ghost';
  ghost.textContent = text;
  box.appendChild(ghost);
  ghost.addEventListener('animationend', () => ghost.remove());
}

function setBadge(env: string) {
  const badge = document.createElement('div');
  badge.className = 'badge';
  badge.textContent = env;
  document.querySelector('main')!.appendChild(badge);
}

let clearTimer: number | null = null;

function setMessage({ content, explode, ghostContent }: Message) {
  const box = document.querySelector(".box")!;
  const a = box.children[0] as HTMLElement;
  const b = box.children[1] as HTMLElement;

  const incoming = a.classList.contains("active") ? b : a;
  const outgoing = incoming === a ? b : a;

  // Cancel previous animation cleanup
  if (clearTimer !== null) {
    clearTimeout(clearTimer);
    clearTimer = null;
  }

  // Reset state immediately
  outgoing.classList.remove("active", "explode");
  incoming.classList.remove("explode");

  incoming.textContent = content;

  if (explode) incoming.classList.add("explode");
  if (ghostContent) spawnGhost(ghostContent, box);
  incoming.classList.add("active");

  clearTimer = window.setTimeout(() => {
    incoming.classList.remove("explode");
    clearTimer = null;
  }, 550);
}

// Trick to have content centered on all platforms, particularly mobile iOS
function setVh() {
  document.documentElement.style.setProperty('--vh', `${window.innerHeight * 0.01}px`);
}

type Message = {
  content: string;
  explode: boolean;
  ghostContent?: string;
}

function wrapMessage(message: string | Message): Message {
  return typeof message === "string"
    ? { content: message, explode: false }
    : message;
}

setVh();
window.addEventListener('resize', setVh);
window.addEventListener('orientationchange', setVh);

type Callback<T> = (current: T, previous: T | undefined) => void;

/**
 * Creates a leading+trailing throttle by a key extracted from the payload.
 *
 * @param intervalMs Minimum interval between updates for the same key
 * @param getKey Function to extract a key from the payload
 * @param callback Function called with the payload
 */
function throttleByKey<T, K>(
  intervalMs: number,
  getKey: (payload: T) => K,
  callback: Callback<T>
) {
  const lastSeen = new Map<K, number>();
  const lastEmitted = new Map<K, T>();
  const pending = new Map<K, T>();
  const timers = new Map<K, number>();

  return (payload: T) => {
    const key = getKey(payload);
    const now = Date.now();
    const last = lastSeen.get(key) ?? 0;
    const elapsed = now - last;

    const emit = (value: T) => {
      const prev = lastEmitted.get(key);
      lastEmitted.set(key, value);
      lastSeen.set(key, Date.now());
      callback(value, prev);
    };

    if (elapsed >= intervalMs) {
      // Leading edge
      emit(payload);

      if (timers.has(key)) {
        clearTimeout(timers.get(key)!);
        timers.delete(key);
        pending.delete(key);
      }
    } else {
      // Trailing edge
      pending.set(key, payload);

      if (!timers.has(key)) {
        const delay = intervalMs - elapsed;
        const timer = window.setTimeout(() => {
          const latest = pending.get(key)!;
          pending.delete(key);
          timers.delete(key);
          emit(latest);
        }, delay);

        timers.set(key, timer);
      }
    }
  };
}

const handleEvent = throttleByKey<AppEvent["payload"], string>(
  THROTTLE_MS,
  (payload) => payload.kind,
  (payload, previousPayload) => {
    const message = eventToMessage(payload);
    if (message === null) return;
    const wrappedMessage = wrapMessage(message);
    if (payload.kind === "tip_syncing" && previousPayload?.kind === "tip_syncing") {
      const delta = payload.slot - previousPayload.slot;
      wrappedMessage.ghostContent = `⚡ +${delta} slots ⚡`;
    }
    setMessage(wrappedMessage);
  }
);

window.addEventListener("DOMContentLoaded", async () => {
  const store = await load('store.json', { autoSave: false, defaults: {} });
  const network = await store.get<{ value: string }>('network');
  keepScreenOn(true);
  setBadge(network?.value ?? "unknown");

  const splash = document.getElementById("splash")!!;

  setTimeout(() => {
    splash.addEventListener('transitionend', () => splash.remove());
    splash.classList.add("hidden");
  }, SPLASH_DURATION_MS);

  await listen<AppEvent>("amaru", ({ payload }) => {
    handleEvent(payload.payload);
  });

  listen("tauri://focus", () => {
    console.log("Window focused");
  })

});
