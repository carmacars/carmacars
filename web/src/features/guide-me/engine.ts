// Guide me (r51, migration 3950): the step engine. A workflow is a declarative step file (flows/*.json): each step names
// the element to point at (a data-guide="..." name, never a CSS class), one short instruction and the condition that says
// the person really did it (the form's or the route's own state). The engine is pure: it reads the page through a Probe,
// so the same rules run in the browser (GuideMe.tsx) and in the unit tests (engine.test.ts).
//
// The rules a person sees:
//   - a step to do advances by itself when its condition turns true; Next stays off until then (Skip is always there);
//   - a step whose condition is already true when it opens shows Done and Next (nothing is passed over unseen), unless
//     it says skipIfDone (getting to a page: already there);
//   - Back opens the step before and holds there (no jump forward again) until Next;
//   - a step with `when` is left out while its condition is false on its loaded page (a part a job does not have).

/** The window event a "Guide me through this" link sends: { flow } */
export const GUIDE_START_EVENT = 'cc:guide-me';

export type Portal = 'admin' | 'va' | 'field';
export type Who = 'admin' | 'cs' | 'sales' | 'fleet' | 'finance' | 'field';

/** An element: a data-guide name ("offer-send"), or [data-guide="x"] spelled out with more (a descendant). */
export type Target = string;
export type Cond =
  | { route: string }
  | { exists: Target }
  | { gone: Target }
  | { filled: Target }
  | { checked: Target }
  | { clicked: Target }
  | { attr: Target; name: string; equals?: string; includes?: string; excludes?: string[] }
  | { all: Cond[] }
  | { any: Cond[] }
  | { not: Cond };

export interface Step {
  id: string;
  /** the element the coach mark points at; none, or not on the page: the card floats in the corner */
  target?: Target;
  /** one short instruction */
  text: string;
  /** what makes the step done; absent: a step to read (Next) */
  done?: Cond;
  /** the step to read is also done by this (Next is on either way) */
  read?: boolean;
  /** already done when it opens: pass it (a page they are already on) */
  skipIfDone?: boolean;
  /** the page the step belongs on (a route pattern); elsewhere the card says where to go */
  on?: string;
  /** the element that says the page has loaded (for `when`) */
  page?: Target;
  /** the step is for this page only when this holds (checked once `page` is there) */
  when?: Cond;
  /** the step is for these portals only */
  only?: Portal[];
  /** where to go when not on `on` (a path, {base} allowed) */
  href?: string;
}

export interface Flow {
  id: string;
  title: string;
  summary: string;
  /** who may run it: an Admin, or a staff member holding one of these functions */
  who: Who[];
  /** where it starts (a path, {base} allowed), or one per portal; the menu opens it there */
  start: string | Partial<Record<Portal, string>>;
  /** the guide chapter it follows (docs/guides/content/<portal>.json): "Read the guide" opens it */
  guide?: { portal: 'admin' | 'va' | 'field'; slug: string };
  steps: Step[];
}

export interface Probe {
  path: string;
  search: string;
  exists(t: Target): boolean;
  value(t: Target): string | null;
  checked(t: Target): boolean;
  attr(t: Target, name: string): string | null;
  /** clicked since the step opened */
  clicked(t: Target): boolean;
}

export interface Run {
  flow: string;
  /** where the run began: /admin or /staff */
  base: string;
  portal: Portal;
  /** the steps of this run (the flow's, filtered for the portal) by id */
  steps: string[];
  index: number;
  /** the step's condition when it opened, and Back's hold */
  openedDone: boolean;
  held: boolean;
  skipped: string[];
  /** a run id from the server, once it has one */
  id?: string | null;
  startedAt: number;
}

export type Outcome = { kind: 'step'; run: Run } | { kind: 'completed'; run: Run };

/** A target as a selector: a bare name is [data-guide="name"]; anything with [ . # or a space is used as written. */
export function selectorOf(t: Target): string {
  return /^[a-z0-9][a-z0-9-]*$/.test(t) ? `[data-guide="${t}"]` : t;
}

/** The base (/admin or /staff) of a path. */
export function baseOf(path: string): '/admin' | '/staff' | null {
  return path.startsWith('/admin') ? '/admin' : path.startsWith('/staff') ? '/staff' : null;
}

/** "{base}/bookings/*?tab=money" against a path and its query: * is one segment, ** the rest; the query must hold. */
export function routeMatches(pattern: string, path: string, search: string, base: string | null): boolean {
  const [p, q] = pattern.split('?') as [string, string | undefined];
  const bases = p.startsWith('{base}') ? (base ? [base] : ['/admin', '/staff']) : [''];
  const ok = bases.some((b) => {
    const want = (b + p.replace('{base}', '')).replace(/\/+$/, '').split('/');
    const have = path.replace(/\/+$/, '').split('/');
    for (let i = 0; i < want.length; i++) {
      if (want[i] === '**') return true;
      if (have[i] === undefined) return false;
      if (want[i] !== '*' && want[i] !== have[i]) return false;
    }
    return want.length === have.length;
  });
  if (!ok || !q) return ok;
  const sp = new URLSearchParams(search);
  return [...new URLSearchParams(q)].every(([k, v]) => sp.get(k) === v);
}

export function evaluate(c: Cond, pr: Probe, base: string | null): boolean {
  if ('route' in c) return routeMatches(c.route, pr.path, pr.search, base);
  if ('exists' in c) return pr.exists(c.exists);
  if ('gone' in c) return !pr.exists(c.gone);
  if ('filled' in c) return (pr.value(c.filled) ?? '').trim() !== '';
  if ('checked' in c) return pr.checked(c.checked);
  if ('clicked' in c) return pr.clicked(c.clicked);
  if ('attr' in c) {
    const v = pr.attr(c.attr, c.name);
    if (v === null) return false;
    const words = v.split(/\s+/).filter(Boolean);
    if (c.equals !== undefined && v !== c.equals) return false;
    if (c.includes !== undefined && !words.includes(c.includes)) return false;
    if (c.excludes && c.excludes.some((x) => words.includes(x))) return false;
    return true;
  }
  if ('all' in c) return c.all.every((x) => evaluate(x, pr, base));
  if ('any' in c) return c.any.some((x) => evaluate(x, pr, base));
  if ('not' in c) return !evaluate(c.not, pr, base);
  return false;
}

/** The flows a person may run: an Admin every flow with "admin"; staff the ones of a function they hold. */
export function flowsFor(flows: Flow[], o: { admin: boolean; functions: readonly string[] }): Flow[] {
  return flows.filter((f) => (o.admin && f.who.includes('admin')) || f.who.some((w) => w !== 'admin' && o.functions.includes(w)));
}

/** The page a flow opens on for this portal and base (/admin or /staff). */
export function startFor(flow: Flow, portal: Portal, base: string): string {
  const s = typeof flow.start === 'string' ? flow.start : flow.start[portal] ?? Object.values(flow.start)[0] ?? '{base}';
  return s.replace('{base}', base);
}

export function stepsFor(flow: Flow, portal: Portal): Step[] {
  return flow.steps.filter((s) => !s.only || s.only.includes(portal));
}

export function startRun(flow: Flow, portal: Portal, base: string, now: number): Run {
  return { flow: flow.id, base, portal, steps: stepsFor(flow, portal).map((s) => s.id), index: 0, openedDone: false, held: false, skipped: [], id: null, startedAt: now };
}

export function currentStep(flow: Flow, run: Run): Step | null {
  const id = run.steps[run.index];
  return flow.steps.find((s) => s.id === id) ?? null;
}

export function onPage(step: Step, pr: Probe, base: string): boolean {
  return !step.on || routeMatches(step.on, pr.path, pr.search, base);
}

export function stepDone(step: Step, pr: Probe, base: string): boolean {
  return !!step.done && evaluate(step.done, pr, base);
}

/** Next is on for a step to read, and for a step that is done. */
export function canNext(step: Step, pr: Probe, base: string): boolean {
  return !step.done || !!step.read || stepDone(step, pr, base);
}

function open(run: Run, index: number, flow: Flow, pr: Probe): Run {
  const r = { ...run, index, held: false, openedDone: false };
  const s = currentStep(flow, r);
  r.openedDone = !!s && stepDone(s, pr, run.base);
  return r;
}

/** One look at the page: the steps left out, passed or done since the last look. Called on every change of the page. */
export function sync(flow: Flow, run: Run, pr: Probe): Outcome {
  let r = run;
  for (let guard = 0; guard < 64; guard++) {
    if (r.index >= r.steps.length) return { kind: 'completed', run: r };
    const s = currentStep(flow, r);
    if (!s) { r = open(r, r.index + 1, flow, pr); continue; }
    if (r.held) return { kind: 'step', run: r };
    const here = onPage(s, pr, r.base);
    // a part this page does not have (checked only once the page is loaded)
    if (s.when && here && (!s.page || pr.exists(s.page)) && !evaluate(s.when, pr, r.base)) { r = open(r, r.index + 1, flow, pr); continue; }
    const done = stepDone(s, pr, r.base);
    if (done && (s.skipIfDone || !r.openedDone)) { r = open(r, r.index + 1, flow, pr); continue; }
    if (!done && r.openedDone) r = { ...r, openedDone: false };
    return { kind: 'step', run: r };
  }
  return { kind: 'step', run: r };
}

export function next(flow: Flow, run: Run, pr: Probe): Outcome {
  const s = currentStep(flow, run);
  if (s && !canNext(s, pr, run.base)) return { kind: 'step', run };
  return sync(flow, open(run, run.index + 1, flow, pr), pr);
}

export function skip(flow: Flow, run: Run, pr: Probe): Outcome {
  const s = currentStep(flow, run);
  const r = s ? { ...run, skipped: [...run.skipped, s.id] } : run;
  return sync(flow, open(r, r.index + 1, flow, pr), pr);
}

export function back(flow: Flow, run: Run, pr: Probe): Run {
  if (run.index <= 0) return run;
  return { ...open(run, run.index - 1, flow, pr), held: true };
}

/** Step X of Y, as the card shows it. */
export function progress(run: Run): { at: number; of: number } {
  return { at: Math.min(run.index + 1, run.steps.length), of: run.steps.length };
}

// ---------------------------------------------------------------- where the card goes
export interface Box { x: number; y: number; w: number; h: number }
export interface Place { x: number; y: number; side: 'below' | 'above' | 'float'; arrowX: number | null }
const overlap = (a: Box, b: Box) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

/** The card beside its target: below it, else above it, inside the screen with a 16px gutter (8px under 360px), never on
 *  an element it must leave free (Report a bug). No target on screen: the bottom corner, clear of those elements. */
export function place(target: Box | null, card: { w: number; h: number }, view: { w: number; h: number }, avoid: Box[] = []): Place {
  const g = view.w < 360 ? 8 : 16;
  const w = Math.min(card.w, view.w - 2 * g);
  const clampX = (x: number) => Math.max(g, Math.min(x, view.w - g - w));
  const free = (b: Box) => !avoid.some((a) => overlap(a, b));
  if (target && target.y + target.h > 0 && target.y < view.h) {
    const x = clampX(target.x + target.w / 2 - w / 2);
    const arrowX = Math.max(14, Math.min(target.x + target.w / 2 - x, w - 14));
    const below = { x, y: target.y + target.h + 12, w, h: card.h };
    const above = { x, y: target.y - 12 - card.h, w, h: card.h };
    const fitsBelow = below.y + card.h <= view.h - g;
    const fitsAbove = above.y >= g;
    if (fitsBelow && free(below)) return { x, y: below.y, side: 'below', arrowX };
    if (fitsAbove && free(above)) return { x, y: above.y, side: 'above', arrowX };
  }
  // the corner: bottom first, then the top; moved off anything it must leave free
  const x = view.w - g - w;
  for (const y of [view.h - g - card.h, g + 56]) {
    const b = { x, y, w, h: card.h };
    if (free(b)) return { x, y, side: 'float', arrowX: null };
  }
  const lowest = Math.max(...avoid.map((a) => a.y + a.h), 0);
  return { x, y: Math.min(lowest + 8, view.h - g - card.h), side: 'float', arrowX: null };
}
