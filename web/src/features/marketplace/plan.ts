// The Marketplace posting schedule (migration 0410): what is due today and in the next days, in a light rotation of
// program_settings.marketplace_posts_per_day new posts and renewals a day (4 by default: 3 to 5 a day avoids spam flags).
// Price updates and take-downs are edits of a listing already up: they are always due at once and do not count.
// Pure (no I/O): the unit tests run it in Node.

export type MpAction = 'update' | 'remove' | 'post' | 'renew';
export interface MpPosting { vehicle_id: string; status: string; posted_on: string; updated_on?: string | null; renewed_on?: string | null; needs_update: boolean; update_reason?: string | null; url?: string | null }
export interface MpCar { vehicle_id: string; name: string; blocked: boolean; partner: boolean; featured: boolean }
export interface MpItem { vehicle_id: string; name: string; action: MpAction; reason: string; due: string }
export interface MpDay { date: string; items: MpItem[] }
export interface MpPlan { today: MpItem[]; later: MpDay[]; left_today: number; live: number; waiting: number }

export function addDays(iso: string, n: number): string {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
/** Oct 22 */
export const short = (iso: string) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
const lastFresh = (p: MpPosting) => [p.renewed_on, p.updated_on, p.posted_on].filter((x): x is string => !!x).sort().pop()!;

/**
 * cars: every car with a kit; postings: the live Marketplace ads; done: posts and renewals already logged today.
 * Returns today's list (updates and take-downs, then up to the day's allowance of new posts and renewals) and the next
 * `horizon` days of the rotation.
 */
export function marketplacePlan(cars: MpCar[], postings: MpPosting[], o: { today: string; perDay: number; renewDays: number; done: number; horizon?: number }): MpPlan {
  const live = new Map(postings.filter((p) => p.status === 'live').map((p) => [p.vehicle_id, p]));
  const byId = new Map(cars.map((c) => [c.vehicle_id, c]));
  const now: MpItem[] = [];
  const posts: MpItem[] = [];
  const renewals: MpItem[] = [];
  for (const p of live.values()) {
    const c = byId.get(p.vehicle_id);
    const name = c?.name ?? 'A car';
    if (!c || c.blocked) { now.push({ vehicle_id: p.vehicle_id, name, action: 'remove', reason: 'Not taking requests on the site: take the listing down (mark it sold or delete it)', due: o.today }); continue; }
    if (p.needs_update) { now.push({ vehicle_id: p.vehicle_id, name, action: 'update', reason: p.update_reason || 'Its prices changed: edit the price and the description', due: o.today }); continue; }
    renewals.push({ vehicle_id: p.vehicle_id, name, action: 'renew', reason: `Up since ${short(lastFresh(p))}: renew it to move it back to the top`, due: addDays(lastFresh(p), o.renewDays) });
  }
  const rank = (c: MpCar) => (c.partner ? 2 : 0) + (c.featured ? 0 : 1);
  for (const c of [...cars].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name))) {
    if (c.blocked || live.has(c.vehicle_id)) continue;
    posts.push({ vehicle_id: c.vehicle_id, name: c.name, action: 'post', reason: c.partner ? 'Not on Marketplace yet (a partner\'s car)' : 'Not on Marketplace yet', due: o.today });
  }
  renewals.sort((a, b) => a.due.localeCompare(b.due) || a.name.localeCompare(b.name));

  // the rotation: each day takes new posts first (a car not listed brings no messages), then the renewals due by then
  const perDay = Math.max(1, o.perDay);
  const horizon = o.horizon ?? 7;
  const waitingPosts = posts.slice();
  const waitingRenew = renewals.slice();
  const days: MpDay[] = [];
  for (let k = 0; k <= horizon; k++) {
    const date = addDays(o.today, k);
    let room = k === 0 ? Math.max(0, perDay - o.done) : perDay;
    const items: MpItem[] = [];
    while (room > 0 && waitingPosts.length) {
      const it = waitingPosts.shift()!;
      items.push({ ...it, due: date });
      waitingRenew.push({ ...it, action: 'renew', reason: `Renew ${o.renewDays} days after posting`, due: addDays(date, o.renewDays) });
      room--;
    }
    waitingRenew.sort((a, b) => a.due.localeCompare(b.due) || a.name.localeCompare(b.name));
    while (room > 0 && waitingRenew.length && waitingRenew[0]!.due <= date) {
      const it = waitingRenew.shift()!;
      items.push({ ...it, reason: it.due < date ? `${it.reason} (due ${short(it.due)})` : it.reason, due: date });
      waitingRenew.push({ ...it, reason: 'Renew again', due: addDays(date, o.renewDays) });
      waitingRenew.sort((a, b) => a.due.localeCompare(b.due) || a.name.localeCompare(b.name));
      room--;
    }
    days.push({ date, items });
  }
  return {
    today: [...now.sort((a, b) => (a.action === b.action ? a.name.localeCompare(b.name) : a.action === 'update' ? -1 : 1)), ...days[0]!.items],
    later: days.slice(1).filter((d) => d.items.length),
    left_today: Math.max(0, perDay - o.done),
    live: live.size,
    waiting: posts.length
  };
}

export const ACTION_LABEL: Record<MpAction, string> = { update: 'Update the price', remove: 'Take down', post: 'Post', renew: 'Renew' };
