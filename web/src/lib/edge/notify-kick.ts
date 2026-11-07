// Instant notifications (r32, docs/changes/2026-11-07-r32-edge-cpu-notify.md). No imports: it runs in the Worker entry
// (custom-worker.ts) and in Node for the unit test.
//
// Before: a write that queued a staff alert, a renter's text or a phone push waited for the database's minute job (the
// in-app notice) and then for the Worker's five-minute tick (the push and the text). Now:
// - a write (any POST that reached the app: a server action, a form, a webhook) asks the database once, after its answer
//   is sent (waitUntil), to turn the waiting events into notices now and say what is due (public.server_notify_kick,
//   migration 0670); the database itself asks the email sender at once when an urgent email waits; the Worker runs the
//   push and text jobs when the database says so;
// - the cron runs every minute: the other jobs keep their five-minute turn (tickPlan), the minute in between only asks
//   the database the same question (one small call, no app loaded when nothing is due).
// Debounced per isolate: a burst of writes asks once, then once more at the end of the burst.

/** POSTs that never queue a notice: the beacon, the jobs themselves, the email sender's callback, health checks */
const NO_KICK = /^\/(api\/(t|jobs\/|email\/send|health)|_next\/|media\/|cdn-cgi\/)/;
export const kickable = (path: string) => !NO_KICK.test(path);
export const KICK_GAP_MS = 2_000;

export interface KickDue { push: boolean; phone: boolean; email: boolean; events: number }

/** The kinds of push this Worker can send (the same rule as cron-gate.ts pushKindsOf). */
function pushKinds(env: Record<string, unknown>): string[] {
  const has = (k: string) => typeof env[k] === 'string' && (env[k] as string).trim() !== '';
  return [...(has('VAPID_PUBLIC_KEY') && has('VAPID_PRIVATE_KEY') ? ['web'] : []), ...(has('FCM_SERVICE_ACCOUNT') ? ['fcm'] : [])];
}

/** Asks the database to process the waiting events and say what is due now; null without a database or on any error. */
export async function askDue(env: Record<string, unknown>, f: typeof fetch = fetch): Promise<KickDue | null> {
  const url = env.NEXT_PUBLIC_SUPABASE_URL, key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (env.DATA_BACKEND !== 'supabase' || typeof url !== 'string' || typeof key !== 'string' || !url || !key) return null;
  try {
    const kinds = pushKinds(env);
    const r = await f(`${url.replace(/\/$/, '')}/rest/v1/rpc/server_notify_kick`, {
      method: 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' },
      body: JSON.stringify({ p_kinds: kinds }), signal: AbortSignal.timeout(8000)
    });
    if (!r.ok) return null;
    const d = (await r.json()) as Partial<Record<keyof KickDue, unknown>> | null;
    if (!d || typeof d !== 'object') return null;
    return { push: kinds.length > 0 && d.push === true, phone: d.phone === true, email: d.email === true, events: Number(d.events) || 0 };
  } catch {
    return null;
  }
}

/** Asks and runs the push and text jobs that are due. */
export async function kickNow(env: Record<string, unknown>, run: (path: string) => Promise<unknown>, f: typeof fetch = fetch): Promise<KickDue | null> {
  const due = await askDue(env, f);
  if (!due) return null;
  const jobs: Promise<unknown>[] = [];
  if (due.push) jobs.push(run('/api/jobs/push').catch(() => undefined));
  if (due.phone) jobs.push(run('/api/jobs/phone').catch(() => undefined));
  await Promise.all(jobs);
  return due;
}

// the isolate's debounce: the last ask, and whether a trailing ask is waiting
let last = 0;
let trailing = false;
/** for the unit test */
export function resetKick() { last = 0; trailing = false; }

/**
 * After a write: ask at once, or (within KICK_GAP_MS of the last ask) once more when the gap is over, so a burst asks
 * twice at most and the burst's last write is never missed.
 */
export function notifyKick(path: string, env: Record<string, unknown>, ctx: { waitUntil(p: Promise<unknown>): void }, run: (path: string) => Promise<unknown>,
  o: { now?: () => number; sleep?: (ms: number) => Promise<unknown>; fetch?: typeof fetch } = {}): 'now' | 'later' | 'skipped' {
  if (!kickable(path)) return 'skipped';
  const now = (o.now ?? Date.now)();
  const wait = last + KICK_GAP_MS - now;
  if (wait <= 0) {
    last = now;
    ctx.waitUntil(kickNow(env, run, o.fetch).catch(() => undefined));
    return 'now';
  }
  if (trailing) return 'skipped';
  trailing = true;
  const sleep = o.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  ctx.waitUntil(sleep(wait).then(() => { trailing = false; last = (o.now ?? Date.now)(); return kickNow(env, run, o.fetch); }).catch(() => { trailing = false; }));
  return 'later';
}

/** The cron runs every minute (wrangler.jsonc): the jobs of the five-minute tick run on minutes 0, 5, 10...; the minutes in
 *  between only ask for the notices due (kickNow). */
export function tickPlan(scheduledTime: number): { full: boolean; minute: number } {
  const minute = new Date(Number.isFinite(scheduledTime) ? scheduledTime : Date.now()).getUTCMinutes();
  return { full: minute % 5 === 0, minute };
}
