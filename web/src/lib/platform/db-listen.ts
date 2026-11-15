// Release 48 (docs/changes/2026-11-14-r48-instant-send.md): texts, emails and pushes go out within a second or two of
// being queued, whoever queued them. Before, a write through the site asked the database at once (notify-kick.ts), but a
// row the database wrote by itself (a timer, a webhook handled in SQL, a reminder coming due) waited for the minute tick.
//
// On the company's server (scripts/vps-server.mjs) one long-lived Postgres connection LISTENs on the channel the
// database's triggers NOTIFY on (migration 2980: an insert into the text, email or push queue, a notice or an event).
// A notify runs the same kick as a write: debounced (250 ms, so a burst asks once), one at a time (a notify during a
// kick asks once more when it ends). The connection comes back by itself, waiting longer after each failure; each
// (re)connect runs one kick, for anything queued while it was down. The minute tick stays as the safety net.
// The Cloudflare Worker build has no long-lived connection: it keeps the kick after a write and the minute tick.
// No imports: unit tested in Node (db-listen.test.ts).

export const LISTEN_CHANNEL = 'carmacars_send';
export const DEBOUNCE_MS = 250;
export const RETRY_MS = [1000, 2000, 5000, 10_000, 30_000];
export const PING_MS = 60_000;
/** Under a steady stream of notifies the kicks start at most this often (one small database call each). */
export const MIN_GAP_MS = 1000;

export interface Timers { set(f: () => void, ms: number): unknown; clear(t: unknown): void }
const realTimers: Timers = {
  set: (f, ms) => { const t = setTimeout(f, ms); (t as { unref?: () => void }).unref?.(); return t; },
  clear: (t) => clearTimeout(t as ReturnType<typeof setTimeout>)
};

/** What a notify says: the queue table and the row (payload `table:id`); anything else is null. */
export function readPayload(raw: unknown): { table: string; id: string } | null {
  if (typeof raw !== 'string') return null;
  const m = /^([a-z_]{1,63}):([0-9a-f-]{1,64})$/.exec(raw);
  return m ? { table: m[1]!, id: m[2]! } : null;
}

/** Debounced, single flight: `poke()` runs `run` DEBOUNCE_MS later; pokes during a run make exactly one more run after it. */
export function createKicker(run: () => Promise<unknown>, o: { debounceMs?: number; minGapMs?: number; timers?: Timers; now?: () => number } = {}) {
  const timers = o.timers ?? realTimers;
  const wait = o.debounceMs ?? DEBOUNCE_MS;
  const gap = o.minGapMs ?? MIN_GAP_MS;
  const now = o.now ?? Date.now;
  let timer: unknown;
  let running = false;
  let again = false;
  let runs = 0;
  let started = -Infinity;
  const go = async () => {
    timer = undefined;
    if (running) { again = true; return; }
    running = true;
    runs++;
    started = now();
    try { await run(); } catch { /* the minute tick is the safety net */ }
    running = false;
    if (again) { again = false; poke(); }
  };
  const poke = () => {
    if (running) { again = true; return; }
    if (timer === undefined) timer = timers.set(() => { void go(); }, Math.max(wait, started + gap - now()));
  };
  return { poke, runs: () => runs, busy: () => running || timer !== undefined, stop: () => { if (timer !== undefined) timers.clear(timer); timer = undefined; again = false; } };
}

/** One live connection: the listen is done when connect resolves; onClose fires once when it drops. */
export interface ListenConn { ping(): Promise<unknown>; close(): Promise<unknown> }
export type Connect = (h: { onNotify: (payload: string) => void; onClose: () => void }) => Promise<ListenConn>;

export function retryDelay(failures: number): number {
  return RETRY_MS[Math.min(Math.max(failures, 1), RETRY_MS.length) - 1]!;
}

/** Keeps the listen up: reconnects with backoff, pings to find a dead connection, kicks on every notify and every connect. */
export function createListener(o: { connect: Connect; kick: () => void; log?: (m: string) => void; timers?: Timers; pingMs?: number }) {
  const timers = o.timers ?? realTimers;
  const log = o.log ?? (() => undefined);
  let conn: ListenConn | null = null;
  let failures = 0;
  let stopped = false;
  let retry: unknown;
  let ping: unknown;
  let notifies = 0;
  let generation = 0;

  const drop = (why: string, gen: number) => {
    if (gen !== generation) return; // an old connection's late close
    generation++;
    if (ping !== undefined) { timers.clear(ping); ping = undefined; }
    const c = conn; conn = null;
    if (c) c.close().catch(() => undefined);
    if (stopped) return;
    failures++;
    const ms = retryDelay(failures);
    if (failures === 1 || failures % 10 === 0) log(`listen: ${why}; again in ${ms / 1000} s`);
    retry = timers.set(() => { retry = undefined; void open(); }, ms);
  };

  const open = async () => {
    if (stopped) return;
    const gen = generation;
    try {
      const c = await o.connect({
        onNotify: (p) => { if (gen !== generation) return; notifies++; if (readPayload(p)) o.kick(); },
        onClose: () => drop('the connection closed', gen)
      });
      if (stopped || gen !== generation) { c.close().catch(() => undefined); return; }
      conn = c;
      if (failures > 0) log('listen: back');
      failures = 0;
      // whatever was queued while the connection was down
      o.kick();
      const beat = () => {
        ping = timers.set(() => {
          ping = undefined;
          if (!conn || gen !== generation) return;
          conn.ping().then(() => { if (gen === generation) beat(); }, () => drop('the connection stopped answering', gen));
        }, o.pingMs ?? PING_MS);
      };
      beat();
    } catch (e) {
      drop(e instanceof Error ? e.message.slice(0, 120) : 'no connection', gen);
    }
  };

  void open();
  return {
    connected: () => conn !== null,
    notifies: () => notifies,
    stop: async () => {
      stopped = true;
      if (retry !== undefined) timers.clear(retry);
      if (ping !== undefined) timers.clear(ping);
      const c = conn; conn = null; generation++;
      if (c) await c.close().catch(() => undefined);
    }
  };
}

/** The listen is for the company's server only: a direct database address in DATABASE_LISTEN_URL, and the jobs' key. */
export function listenUrl(env: Record<string, unknown>): string | null {
  const u = env.DATABASE_LISTEN_URL;
  if (typeof u !== 'string' || !/^postgres(ql)?:\/\//.test(u.trim()) || env.DB_LISTEN === '0') return null;
  return u.trim();
}
