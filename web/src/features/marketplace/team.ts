// A salesperson's Marketplace day (migration 0510): what to finish, update, take down, renew and post from their own
// Facebook profile, in a light rotation of posts_per_day (their own posts and renewals; spam flags are per account). A car
// is offered only while it has a free copy variant: at most max_live live listings a car across the team (the owner's own
// listing is variant 1), each variant claimed by one person. Pure (no I/O): the unit tests run it in Node.
import { addDays, short } from './plan.ts';
import { variantCount } from './variants.ts';

export interface TeamClaim {
  id: string; vehicle_id: string; car?: string; variant: number; status: 'claimed' | 'live' | 'ended'; poster_id: string; poster: string | null;
  title: string; cover: string; price_line: string | null; url: string | null; claimed_at: string; posted_on: string | null; renewed_on: string | null;
  updated_on?: string | null; expires_at: string; ended_at?: string | null; ended_reason?: string | null;
}
export interface TeamCar { vehicle_id: string; name: string; blocked: boolean; featured: boolean; photos: number; priceLine: string }
export type TeamAction = 'finish' | 'update' | 'remove' | 'renew' | 'post';
export interface TeamItem { vehicle_id: string; name: string; action: TeamAction; reason: string; variant: number; claim?: TeamClaim }
export interface TeamPlan { today: TeamItem[]; left_today: number; mine_live: number; open_cars: number; full_cars: number }

export const TEAM_LABEL: Record<TeamAction, string> = { finish: 'Post it', update: 'Update the price', remove: 'Take down', renew: 'Renew', post: 'Post' };

const active = (c: TeamClaim, nowIso: string) => c.status !== 'ended' && c.expires_at > nowIso;

/** The first free variant of a car for a new listing (2 and up), or null when the car is full. */
export function freeVariant(car: Pick<TeamCar, 'vehicle_id' | 'photos'>, team: TeamClaim[], ownerLive: boolean, maxLive: number, nowIso: string): number | null {
  const mine = team.filter((c) => c.vehicle_id === car.vehicle_id && active(c, nowIso));
  if (mine.length + (ownerLive ? 1 : 0) >= maxLive) return null;
  const top = variantCount(car.photos, maxLive);
  for (let v = 2; v <= top; v++) if (!mine.some((c) => c.variant === v)) return v;
  return null;
}

/**
 * cars: every car with a kit; team: the team's listings; me: the person; ownerLive: the cars with the owner's own listing up;
 * done: my posts and renewals logged today. Edits of a listing already up (update, take down) and finishing a claim are
 * always due; then up to the day's allowance of renewals that are due and new posts (cars with the fewest listings first).
 */
export function teamPlan(cars: TeamCar[], team: TeamClaim[], me: string, ownerLive: Set<string>,
  o: { today: string; now: string; perDay: number; renewDays: number; done: number; maxLive: number }): TeamPlan {
  const byId = new Map(cars.map((c) => [c.vehicle_id, c]));
  const mine = team.filter((c) => c.poster_id === me && active(c, o.now));
  const now: TeamItem[] = [];
  const renew: TeamItem[] = [];
  for (const c of mine) {
    const car = byId.get(c.vehicle_id);
    const name = car?.name ?? c.car ?? 'A car';
    const base = { vehicle_id: c.vehicle_id, name, variant: c.variant, claim: c };
    if (c.status === 'claimed') { now.push({ ...base, action: car?.blocked ? 'remove' : 'finish', reason: car?.blocked ? 'Not taking requests on the site any more: let the claim go' : `You claimed variant ${c.variant}: post it, then paste the listing's address` }); continue; }
    if (!car || car.blocked) { now.push({ ...base, action: 'remove', reason: 'Not taking requests on the site: take the listing down (mark it sold or delete it)' }); continue; }
    if (c.price_line && car.priceLine && c.price_line !== car.priceLine) { now.push({ ...base, action: 'update', reason: 'Its prices changed: edit the price and the description' }); continue; }
    const fresh = [c.renewed_on, c.updated_on, c.posted_on].filter((x): x is string => !!x).sort().pop() ?? o.today;
    if (addDays(fresh, o.renewDays) <= o.today) renew.push({ ...base, action: 'renew', reason: `Up since ${short(fresh)}: renew it to move it back to the top` });
  }
  const order: Record<string, number> = { remove: 0, update: 1, finish: 2 };
  now.sort((a, b) => order[a.action]! - order[b.action]! || a.name.localeCompare(b.name));
  let room = Math.max(0, o.perDay - o.done);
  const today = [...now];
  for (const it of renew.sort((a, b) => a.name.localeCompare(b.name))) { if (room <= 0) break; today.push(it); room--; }
  const live = (id: string) => team.filter((c) => c.vehicle_id === id && active(c, o.now)).length + (ownerLive.has(id) ? 1 : 0);
  let open = 0, full = 0;
  const posts: TeamItem[] = [];
  for (const car of cars) {
    if (car.blocked || mine.some((c) => c.vehicle_id === car.vehicle_id)) continue;
    const v = freeVariant(car, team, ownerLive.has(car.vehicle_id), o.maxLive, o.now);
    if (v === null) { full++; continue; }
    open++;
    const n = live(car.vehicle_id);
    posts.push({ vehicle_id: car.vehicle_id, name: car.name, action: 'post', variant: v, reason: n ? `${n} of ${o.maxLive} listings up: yours is variant ${v}` : `Not on Marketplace yet: yours is variant ${v}` });
  }
  posts.sort((a, b) => live(a.vehicle_id) - live(b.vehicle_id) || Number(byId.get(b.vehicle_id)!.featured) - Number(byId.get(a.vehicle_id)!.featured) || a.name.localeCompare(b.name));
  for (const it of posts) { if (room <= 0) break; today.push(it); room--; }
  return { today, left_today: Math.max(0, o.perDay - o.done), mine_live: mine.filter((c) => c.status === 'live').length, open_cars: open, full_cars: full };
}
