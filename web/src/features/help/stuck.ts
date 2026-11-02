// The "Stuck?" detector (migration 0510): someone working on a page without getting anywhere. Three signs, each counted from
// the last successful action on the page (a saved form, a done action, a new page):
//   idle:   they have been active (typing, clicking) but nothing succeeded for idleMs (Settings: 3 minutes);
//   errors: `errors` validation errors (Settings: 3);
//   loop:   back and forth between the same two steps or tabs, twice (A, B, A, B).
// It fires once, then stays quiet until the next success. Reading a page without touching it never fires it.
// Pure (no I/O, no DOM): the browser part (StuckHelp.tsx) feeds it events; the unit tests feed it times.

export type StuckTrigger = 'idle' | 'errors' | 'loop';
export interface StuckOptions { idleMs: number; errors: number }

export class StuckDetector {
  private since: number;
  private lastActive = -Infinity;
  private active = false;
  private errs = 0;
  private steps: string[] = [];
  private fired = false;
  private lastErr = -Infinity;
  private o: StuckOptions;

  constructor(o: StuckOptions, now: number) { this.o = o; this.since = now; }

  /** A successful action, or a new page: start over. */
  progress(now: number): void { this.since = now; this.active = false; this.errs = 0; this.steps = []; this.fired = false; }
  /** Typing, clicking, choosing. */
  activity(now: number): void { this.active = true; this.lastActive = now; }
  /** A validation error shown (the same failed attempt reported twice within 0.4 s counts once). */
  error(now: number): void { if (now - this.lastErr >= 400) this.errs++; this.lastErr = now; this.activity(now); }
  /** The step or tab now shown (its address); the same one twice in a row counts once. */
  step(id: string, now: number): void {
    if (this.steps[this.steps.length - 1] === id) return;
    this.steps.push(id);
    if (this.steps.length > 6) this.steps.shift();
    this.activity(now);
  }

  /** The sign that fires now, at most once until the next success. */
  check(now: number): StuckTrigger | null {
    if (this.fired) return null;
    const t = this.trigger(now);
    if (t) this.fired = true;
    return t;
  }

  private trigger(now: number): StuckTrigger | null {
    if (this.errs >= this.o.errors) return 'errors';
    const s = this.steps;
    if (s.length >= 4) {
      const [a, b, c, d] = s.slice(-4);
      if (a === c && b === d && a !== b) return 'loop';
    }
    // active since the last success, still here (active within the window), and nothing has worked for the whole window
    if (this.active && now - this.since >= this.o.idleMs && now - this.lastActive <= this.o.idleMs) return 'idle';
    return null;
  }
}

/** The settings as the browser gets them, with a test override (milliseconds) for the end-to-end tests. */
export function stuckOptions(s: { on?: boolean; idle_minutes?: number; errors?: number } | null, overrideMs?: number | null): (StuckOptions & { on: boolean }) {
  const idle = overrideMs && overrideMs > 0 ? overrideMs : Math.max(1, Math.min(30, s?.idle_minutes ?? 3)) * 60_000;
  return { on: s?.on !== false, idleMs: idle, errors: Math.max(2, Math.min(10, s?.errors ?? 3)) };
}

/** "Bookings" from a document title such as "Bookings | CarmaCars". */
export const pageName = (title: string): string => (title.split(/\s[|·]\s/)[0] ?? '').trim() || 'this page';
