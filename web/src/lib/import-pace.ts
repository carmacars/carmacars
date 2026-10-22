// The pace of the bulk imports (migration 0106; the catalog workflow's web/scripts/catalog/import.mjs and the places
// workflow's web/scripts/places/load.mjs). Before each transaction an import asks the database how busy it is
// (app.db_busy(): client sessions running a statement, sessions waiting on a lock, the longest running statement) and
// times the question; while the site is busy it waits, longer each time, then goes on. Between two transactions it
// always pauses a moment, so the website's own reads get the database between the import's writes (the Micro compute
// has two shared cores). No imports: it runs in the import scripts and in Node for the unit test.

export interface Busy { active?: number; waiting?: number; longest_ms?: number }
export interface PaceOptions {
  /** busy from this many other sessions running a statement */
  maxActive?: number;
  /** busy when the question itself took longer than this (ms) */
  maxProbeMs?: number;
  /** busy from this many sessions waiting on a lock */
  maxWaiting?: number;
  /** busy while another statement has run longer than this (ms) */
  maxLongestMs?: number;
  /** the pause between two transactions (ms) */
  pauseMs?: number;
  /** waits at most this long in all before one transaction, then goes on (the import must end) */
  maxWaitMs?: number;
  now?: () => number;
  sleep?: (ms: number) => Promise<unknown>;
  log?: (line: string) => void;
}
export const PACE = { maxActive: 6, maxProbeMs: 1_500, maxWaiting: 3, maxLongestMs: 10_000, pauseMs: 500, maxWaitMs: 600_000 } as const;

/** Why the database counts as busy now, or null. */
export function busyReason(b: Busy | null, probeMs: number, o: PaceOptions = {}): string | null {
  if (!b) return 'the busy check did not answer';
  if ((b.active ?? 0) >= (o.maxActive ?? PACE.maxActive)) return `${b.active} sessions running a statement`;
  if ((b.waiting ?? 0) >= (o.maxWaiting ?? PACE.maxWaiting)) return `${b.waiting} sessions waiting on a lock`;
  if ((b.longest_ms ?? 0) > (o.maxLongestMs ?? PACE.maxLongestMs)) return `a statement running for ${Math.round((b.longest_ms ?? 0) / 1000)} s`;
  if (probeMs > (o.maxProbeMs ?? PACE.maxProbeMs)) return `the busy check took ${probeMs} ms`;
  return null;
}

/** The wait after the n-th busy answer in a row (from 0): 2, 4, 8, then 15 s. */
export const backoffMs = (n: number) => Math.min(15_000, 2_000 * 2 ** n);

/**
 * Before one transaction: the pause, then the busy check until the database is quiet (or maxWaitMs has gone by).
 * Returns how long it waited beyond the pause and how many busy answers it had.
 */
export async function beforeBatch(probe: () => Promise<Busy | null>, o: PaceOptions = {}): Promise<{ waitedMs: number; busy: number }> {
  const now = o.now ?? Date.now;
  const sleep = o.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  if ((o.pauseMs ?? PACE.pauseMs) > 0) await sleep(o.pauseMs ?? PACE.pauseMs);
  const start = now();
  let busy = 0;
  for (;;) {
    const t0 = now();
    let b: Busy | null = null;
    try { b = await probe(); } catch { b = null; }
    const why = busyReason(b, now() - t0, o);
    if (!why) return { waitedMs: now() - start, busy };
    if (now() - start >= (o.maxWaitMs ?? PACE.maxWaitMs)) {
      o.log?.(`busy (${why}) for ${Math.round((now() - start) / 1000)} s: going on`);
      return { waitedMs: now() - start, busy };
    }
    const ms = backoffMs(busy++);
    o.log?.(`busy (${why}): waiting ${ms / 1000} s`);
    await sleep(ms);
  }
}
