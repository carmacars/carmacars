// How often a staff screen asks the server again (0320; docs/changes/2026-11-06-owner-todo-usage-noise.md). Every ask
// is a Worker invocation and a database read: a live chat inbox open all day at 5 seconds was 17,000 a day for one
// person. A screen asks at its own pace while someone is using it, and at most once a minute once nobody has touched
// it for two minutes (a wall screen, a tab left open); any touch brings the pace back at once. Hidden tabs never ask.

/** Nobody touched the page for this long: idle. */
export const IDLE_AFTER_MS = 120_000;
/** The slowest an idle screen asks. */
export const IDLE_EVERY_MS = 60_000;

/** Whether a tick that runs every `baseMs` should ask now. Pure. */
export function pollDue(now: number, lastRun: number, lastActive: number, baseMs: number): boolean {
  const idle = now - lastActive >= IDLE_AFTER_MS;
  const every = idle ? Math.max(baseMs, IDLE_EVERY_MS) : baseMs;
  return now - lastRun >= every - 250;
}

let lastActive = Date.now();
let listening = false;
function listen() {
  if (listening || typeof window === 'undefined') return;
  listening = true;
  const touch = () => { lastActive = Date.now(); };
  for (const e of ['pointerdown', 'keydown', 'wheel', 'touchstart', 'focus']) window.addEventListener(e, touch, { passive: true, capture: true });
}

/** A gate for a setInterval tick: true when the screen is visible and the pace says it is time. */
export function poller(baseMs: number): () => boolean {
  listen();
  let lastRun = Date.now();
  return () => {
    if (typeof document !== 'undefined' && document.visibilityState !== 'visible') return false;
    const now = Date.now();
    if (!pollDue(now, lastRun, lastActive, baseMs)) return false;
    lastRun = now;
    return true;
  };
}
