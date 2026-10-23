// Warm pages after a deploy (0102). A deploy starts a new page cache (OpenNext's is per build) and a new edge copy (keyed
// by the Worker's version), so every car page was a cold render for its first visitor, a second or more each, and with
// many deploys in a day most visits were. The first cron ticks after a deploy (custom-worker.ts) request home, the fleet
// page and each car page once, through the Worker's own service binding (each request its own invocation with its own
// CPU limit), a few at a time and within a time budget; what is left waits for the next tick. No imports: it runs in the
// Worker entry and in Node for the unit test.

/** The progress of the warm-up in the tag store: the deploy number times 1000 plus the pages done (0 when none). */
export const WARM_KEY = 'carmacars/warm';
/** at most this many pages for one deploy */
export const WARM_MAX = 400;
export const WARM_CONCURRENCY = 4;
/** time for one tick's share, well inside the 30 s a five-minute cron invocation may run */
export const WARM_BUDGET_MS = 15_000;
/** a pause between two requests of one lane, so the database is never hit by a burst */
export const WARM_GAP_MS = 150;

/** 0124: the site's own pages and the hubs crawlers open first (/faq answered a cold crawler in 7.7 s after a deploy) */
export const WARM_SITE = ['/car-rental', '/faq', '/how-it-works', '/requirements', '/delivery', '/guides', '/makes', '/places', '/detailing',
  '/body-shop', '/chauffeur', '/list-your-car', '/contact', '/terms', '/privacy', '/cancellation-policy'];
/** Home, the fleet page, the site's own pages and hubs (0124), then each car page of the fleet (in the fleet's order:
 *  featured first), without repeats. */
export function warmPaths(rows: ReadonlyArray<{ slug?: unknown }>, max = WARM_MAX): string[] {
  const out = ['/', '/cars', ...WARM_SITE];
  for (const r of rows) {
    const s = typeof r.slug === 'string' ? r.slug : '';
    if (/^[a-z0-9][a-z0-9-]{0,119}$/.test(s)) { const p = `/cars/${s}`; if (!out.includes(p)) out.push(p); }
  }
  return out.slice(0, max);
}

/** Where the warm-up of this deploy stands: the pages done so far (0 when the stored progress is another deploy's). */
export function warmDone(stored: number | null, deploy: number): number {
  if (!stored || deploy <= 0) return 0;
  return Math.floor(stored / 1000) === deploy ? stored % 1000 : 0;
}
export const warmValue = (deploy: number, done: number) => deploy * 1000 + Math.min(done, 999);

/** Request the paths from `start`, a few at a time, until all are done or the budget is spent; returns the next start. */
export async function warmBatch(paths: readonly string[], start: number, get: (path: string) => Promise<unknown>,
  o: { concurrency?: number; budgetMs?: number; gapMs?: number; now?: () => number; sleep?: (ms: number) => Promise<unknown> } = {}): Promise<number> {
  const now = o.now ?? Date.now;
  const sleep = o.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const until = now() + (o.budgetMs ?? WARM_BUDGET_MS);
  let next = start;
  let done = start;
  const finished = new Set<number>();
  const lane = async () => {
    while (next < paths.length && now() < until) {
      const i = next++;
      try { await get(paths[i]!); } catch { /* a page that fails is rendered by its first visitor, as before */ }
      finished.add(i);
      while (finished.has(done)) done++;
      if (o.gapMs ?? WARM_GAP_MS) await sleep(o.gapMs ?? WARM_GAP_MS);
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, o.concurrency ?? WARM_CONCURRENCY) }, lane));
  return done;
}
