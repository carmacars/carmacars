// R51 (5300, REQ-130): what the quiz page sees while a quiz is open, sent with each submit. The database turns it into
// reasons (app.academy_integrity_reasons) and voids the attempt on any of them. Best effort and honest about limits: a page
// cannot stop an AI agent that controls the browser; these signals make most of them detectable.
//   automation    navigator.webdriver, markers that browser drivers inject, a devtools protocol probe
//   untrusted     clicks, keys and changes not made by a person (isTrusted false: scripts and form-filling tools)
//   jumps         a mouse press with no movement to it first (a pointer that teleports, as agents click)
//   pastes/copies blocked, and counted
//   leaves        the page lost focus or was hidden (another tab or app)
//   gaps_ms       the time between the first picks of each question (the database compares it with its floor)
// No imports: the unit tests run it with fake events.

export const HONEST_NOTE = 'Answer yourself. Using AI tools, browser agents or computer-use software on this test is not allowed and breaks your agreement; CarmaCars may take legal action.';

export interface IntegrityReport { webdriver: boolean; cdp: boolean; markers: string[]; untrusted: number; jumps: number; pastes: number; copies: number; leaves: number; gaps_ms: number[] }

/** Global names that browser drivers and automation tools leave on the page (chromedriver, Selenium, Playwright, Puppeteer, PhantomJS, Nightmare). */
const WINDOW_MARKERS = ['__playwright__binding__', '__pwInitScripts', '__puppeteer_evaluation_script__', 'callPhantom', '_phantom', '__nightmare', 'domAutomation',
  'domAutomationController', '__webdriver_evaluate', '__selenium_unwrapped', '__driver_evaluate', '__webdriver_script_fn', '__fxdriver_unwrapped', '__lastWatirAlert', '_Selenium_IDE_Recorder', '_selenium'] as const;
const DOC_MARKER = /^\$?cdc_|^\$wdc_|^__(webdriver|selenium|driver|fxdriver)_/;

type Win = Record<string, unknown> & { navigator?: { webdriver?: boolean } };
type Doc = { documentElement?: { getAttribute?: (n: string) => string | null } } & Record<string, unknown>;

/** The automation markers on this window and document (names only). */
export function markersOf(win: Win, doc: Doc | null): string[] {
  const out: string[] = [];
  for (const k of WINDOW_MARKERS) { try { if (k in win) out.push(k); } catch { /* a guarded property */ } }
  if (doc) {
    try { for (const k of Object.keys(doc)) if (DOC_MARKER.test(k)) out.push(k); } catch { /* none */ }
    try { if (doc.documentElement?.getAttribute?.('webdriver') !== null && doc.documentElement?.getAttribute?.('webdriver') !== undefined) out.push('webdriver attribute'); } catch { /* none */ }
  }
  return [...new Set(out)].slice(0, 10);
}

/** A devtools protocol client with the Runtime domain on reads the stack of a logged error to preview it; a person's
 *  browser does not. True when that read happened. (DevTools open has the same effect: also not allowed during a test.) */
export function cdpProbe(log: (e: unknown) => void): boolean {
  let read = false;
  try {
    const e = new Error('');
    Object.defineProperty(e, 'stack', { configurable: false, enumerable: false, get() { read = true; return ''; } });
    log(e);
  } catch { /* none */ }
  return read;
}

/** The running count of one open quiz. Feed it the page's events; report() is what the submit sends. */
export class IntegrityWatch {
  private untrusted = 0; private jumps = 0; private pastes = 0; private copies = 0; private leaves = 0;
  private moves = 0; private away = false; private last: number; private picked = new Set<string>(); private gaps: number[] = [];
  private readonly env: { webdriver: boolean; markers: string[]; cdp: boolean };
  constructor(env: { webdriver: boolean; markers: string[]; cdp: boolean }, startedAt: number) { this.env = env; this.last = startedAt; }
  /** any input event on the quiz (click, change, key, pointer) */
  input(e: { isTrusted: boolean }) { if (!e.isTrusted) this.untrusted++; }
  pointerMove(e: { pointerType?: string }) { if (e.pointerType === 'mouse') this.moves++; }
  /** a mouse press: fewer than 3 moves since the last press means the pointer jumped there */
  pointerDown(e: { pointerType?: string; isTrusted: boolean }) {
    this.input(e);
    if (e.pointerType !== 'mouse') return;
    if (this.moves < 3) this.jumps++;
    this.moves = 0;
  }
  paste() { this.pastes++; }
  copy() { this.copies++; }
  /** the page lost focus or was hidden; counted once until it is back */
  leave() { if (!this.away) { this.away = true; this.leaves++; } }
  back() { this.away = false; }
  /** the first pick of a question: the time since the one before (or since the quiz was shown) */
  pick(question: string, at: number) {
    if (this.picked.has(question)) return;
    this.picked.add(question);
    this.gaps.push(Math.max(0, Math.round(at - this.last)));
    this.last = at;
  }
  report(): IntegrityReport {
    return { webdriver: this.env.webdriver, cdp: this.env.cdp, markers: this.env.markers, untrusted: this.untrusted, jumps: this.jumps, pastes: this.pastes,
      copies: this.copies, leaves: this.leaves, gaps_ms: this.gaps.slice(0, 200) };
  }
}
