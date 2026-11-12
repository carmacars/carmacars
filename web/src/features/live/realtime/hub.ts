// Live updates (release 41, migration 2500): the portals' screens show a change made elsewhere within about two seconds,
// without a reload. A screen watches "topics": opaque names the server hands out for what the signed-in person may read
// (server_live_topics: a staff area such as bookings or leads, one booking, the person's own alerts, a renter's or an
// owner's bookings). The database bumps a topic whenever a row behind it changes (app.live_bump) and, when Supabase
// Realtime runs, broadcasts the bump on a channel of that name. The hub listens on that channel when it can and checks the
// topics' versions with one small database read (live_poll, straight to the database API, never the Worker):
//   - every 2 seconds while the tab is visible and Realtime is not joined,
//   - every 60 seconds as a safety net while Realtime is joined,
//   - never while the tab is hidden; at once when it is shown again.
// A failed read waits longer each time (up to 30 seconds). Bumps that arrive together are told once. No data travels
// this way: a change only tells the screen to read again (router.refresh, which keeps what is typed in forms).
// No imports: unit tested in Node (hub.test.ts).

export const POLL_MS = 2000;
export const SAFETY_MS = 60_000;
export const BACKOFF_MAX_MS = 30_000;
/** Bumps closer together than this are told once. */
export const COALESCE_MS = 250;
/** At most this many topics in one read (live_poll refuses more). */
export const MAX_TOPICS = 24;

export interface Timers { set(f: () => void, ms: number): unknown; clear(t: unknown): void }
const realTimers: Timers = { set: (f, ms) => setTimeout(f, ms), clear: (t) => clearTimeout(t as ReturnType<typeof setTimeout>) };

/** A Realtime connection the hub drives: it joins the topics it is given and says when every one of them is joined. */
export interface LiveSocket { set(topics: string[]): void; close(): void }
export type SocketFactory = (onBump: (topic: string) => void, onJoined: (joined: boolean) => void) => LiveSocket | null;

export interface LiveDeps {
  /** The versions of the topics (a missing or null topic has had no change lately). */
  poll(topics: string[]): Promise<Record<string, string | null | undefined> | null>;
  visible(): boolean;
  socket?: SocketFactory;
  timers?: Timers;
}

export interface LiveHub {
  /** Watch the topics; the callback runs once for any number of their changes close together. Returns the unsubscribe. */
  subscribe(topics: string[], cb: () => void): () => void;
  /** Call on visibilitychange. */
  visibility(): void;
  /** For tests and the status dot: 'realtime' while joined, 'polling' while reading every 2 s, 'idle' otherwise. */
  mode(): 'realtime' | 'polling' | 'idle';
  close(): void;
}

/** Topic names are the server's opaque tokens: lowercase letters and digits, 8 to 64 characters. */
export const validTopic = (t: unknown): t is string => typeof t === 'string' && /^[a-z0-9]{8,64}$/.test(t);

/** The interval to the next read: Realtime joined, the safety net; after failures, a longer wait each time. */
export function nextDelay(joined: boolean, failures: number): number {
  if (failures > 0) return Math.min(BACKOFF_MAX_MS, POLL_MS * 2 ** Math.min(failures, 5));
  return joined ? SAFETY_MS : POLL_MS;
}

export function createLiveHub(d: LiveDeps): LiveHub {
  const timers = d.timers ?? realTimers;
  const subs = new Map<string, Set<() => void>>();
  // the last version seen of each topic; a topic not in the map has not been read yet (its first read is the start)
  const seen = new Map<string, string>();
  let timer: unknown;
  let flushTimer: unknown;
  const pending = new Set<() => void>();
  let failures = 0;
  let joined = false;
  let inFlight = false;
  let again = false;
  let closed = false;
  let socket: LiveSocket | null | undefined;

  const topics = () => [...subs.keys()].slice(0, MAX_TOPICS);
  const stopTimer = () => { if (timer !== undefined) { timers.clear(timer); timer = undefined; } };

  const flush = () => {
    flushTimer = undefined;
    const cbs = [...pending];
    pending.clear();
    for (const cb of cbs) { try { cb(); } catch { /* one screen's error never stops the others */ } }
  };
  const tell = (topic: string) => {
    const s = subs.get(topic);
    if (!s) return;
    for (const cb of s) pending.add(cb);
    if (flushTimer === undefined) flushTimer = timers.set(flush, COALESCE_MS);
  };

  const schedule = (ms?: number) => {
    stopTimer();
    if (closed || !subs.size || !d.visible()) return;
    timer = timers.set(() => { timer = undefined; void read(); }, ms ?? nextDelay(joined, failures));
  };

  const read = async () => {
    if (closed || !subs.size) return;
    if (inFlight) { again = true; return; }
    inFlight = true;
    const list = topics();
    let r: Record<string, string | null | undefined> | null = null;
    try { r = await d.poll(list); } catch { r = null; }
    inFlight = false;
    if (closed) return;
    if (!r) failures++;
    else {
      failures = 0;
      for (const t of list) {
        if (!subs.has(t)) continue;
        const v = r[t] ?? '';
        const before = seen.get(t);
        seen.set(t, v);
        if (before !== undefined && before !== v) tell(t);
      }
    }
    if (again) { again = false; schedule(0); } else schedule();
  };

  const connect = () => {
    if (socket !== undefined || !d.socket) return;
    socket = d.socket(
      (topic) => {
        if (!subs.has(topic)) return;
        // the next read takes the new version as its start, so the same change is not told twice
        seen.delete(topic);
        tell(topic);
      },
      (j) => { if (j !== joined) { joined = j; schedule(j ? undefined : 0); } }
    );
    socket?.set(topics());
  };

  return {
    subscribe(list, cb) {
      const added: string[] = [];
      for (const t of new Set(list.filter(validTopic))) {
        let s = subs.get(t);
        if (!s) { s = new Set(); subs.set(t, s); added.push(t); }
        s.add(cb);
      }
      if (added.length) {
        connect();
        socket?.set(topics());
        // a new topic is read at once, so its start is known before the first change
        if (d.visible()) schedule(0);
      }
      return () => {
        let removed = false;
        for (const t of list) {
          const s = subs.get(t);
          if (!s) continue;
          s.delete(cb);
          if (!s.size) { subs.delete(t); seen.delete(t); removed = true; }
        }
        pending.delete(cb);
        if (removed) socket?.set(topics());
        if (!subs.size) stopTimer();
      };
    },
    visibility() {
      // shown again: read at once (and tell what changed while hidden); hidden: no reads at all
      if (d.visible()) schedule(0); else stopTimer();
    },
    mode() { return !subs.size ? 'idle' : joined ? 'realtime' : d.visible() ? 'polling' : 'idle'; },
    close() {
      closed = true;
      stopTimer();
      if (flushTimer !== undefined) { timers.clear(flushTimer); flushTimer = undefined; }
      socket?.close();
      subs.clear();
    }
  };
}
