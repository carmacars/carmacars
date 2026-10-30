// Live visitors heartbeat (migration 0103): while the page is visible, the tracker says the visitor is still there
// every interval (45 seconds, an Admin setting sent with the chat settings), so a visitor reading one page stays on
// Live visitors. It stops while the tab is hidden and beats at once when the tab is shown again. Any other send
// (a page view, an event) restarts the wait, so a busy page sends no extra heartbeat. No imports: unit tested in Node.

export const BEAT_DEFAULT_S = 45;
export const BEAT_MIN_S = 15;
export const BEAT_MAX_S = 300;
/** 2026-10-30 (Worker requests): a visible tab nobody touches (a screen left open) stops beating after this long; the
 *  next touch, key or scroll beats at once and starts again. The session then ends on Live visitors as for a closed tab. */
export const BEAT_IDLE_STOP_MS = 15 * 60_000;

/** The interval in milliseconds from the setting in seconds (anything missing or odd: 45 seconds). */
export function beatMs(seconds: unknown): number {
  const n = typeof seconds === 'number' ? seconds : Number(seconds);
  if (!Number.isFinite(n) || n <= 0) return BEAT_DEFAULT_S * 1000;
  return Math.round(Math.min(BEAT_MAX_S, Math.max(BEAT_MIN_S, n))) * 1000;
}

export interface Timers { set(f: () => void, ms: number): unknown; clear(t: unknown): void }
const realTimers: Timers = { set: (f, ms) => setTimeout(f, ms), clear: (t) => clearTimeout(t as ReturnType<typeof setTimeout>) };

export interface Heartbeat {
  /** Start (or restart) the wait for the next beat, when the page is visible. */
  start(): void;
  /** Another send just went out: wait a full interval again. */
  reset(): void;
  stop(): void;
  /** Call on visibilitychange: shown, a beat at once and the wait again; hidden, stop. */
  visibility(): void;
  /** The visitor touched, typed or scrolled: after an idle stop, a beat at once and the wait again. */
  activity(): void;
  running(): boolean;
}

export function createHeartbeat(o: { visible: () => boolean; beat: () => void; intervalMs: () => number; timers?: Timers; now?: () => number; idleStopMs?: number }): Heartbeat {
  const timers = o.timers ?? realTimers;
  const now = o.now ?? (() => Date.now());
  const idleStop = o.idleStopMs ?? BEAT_IDLE_STOP_MS;
  let t: unknown;
  let on = false;
  let lastActive = now();
  let idle = false;
  const stop = () => { if (t !== undefined) { timers.clear(t); t = undefined; } };
  const schedule = () => {
    stop();
    if (!on || !o.visible()) return;
    t = timers.set(() => {
      t = undefined;
      if (now() - lastActive >= idleStop) { idle = true; return; }
      if (on && o.visible()) o.beat();
      schedule();
    }, o.intervalMs());
  };
  return {
    start() { on = true; schedule(); },
    reset() { if (on) schedule(); },
    stop() { on = false; stop(); },
    visibility() {
      if (!on) return;
      if (o.visible()) { lastActive = now(); idle = false; o.beat(); schedule(); } else stop();
    },
    activity() {
      lastActive = now();
      if (!idle) return;
      idle = false;
      if (on && o.visible()) { o.beat(); schedule(); }
    },
    running: () => t !== undefined
  };
}
