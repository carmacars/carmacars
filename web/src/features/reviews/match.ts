// Google reviews matched to renters (migration 0138): the reviewer's display name against the renter's name, within a
// window after the return. A clear match (one renter, a strong name match) is matched at once and stops that renter's
// review requests; a weaker or shared one is suggested for staff to confirm. No imports: the Worker's job uses it and
// match.test.ts runs it in plain Node.

export interface GoogleReviewIn { id: string; reviewer_name: string | null; reviewed_at: string }
export interface Candidate { booking_id: string; renter_name: string | null; returned_at: string | null }
export interface MatchOut { id: string; booking_id: string | null; status: 'matched' | 'suggested' | 'unmatched'; score: number }

/** Lower case, no accents, letters only, split into words. */
export function nameTokens(s: string | null | undefined): string[] {
  return String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z\s.'-]/g, ' ')
    .replace(/['.-]/g, ' ').split(/\s+/).filter(Boolean);
}

function lev(a: string, b: string): number {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)] as number[]);
  for (let j = 1; j <= b.length; j++) d[0]![j] = j;
  for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++)
    d[i]![j] = Math.min(d[i - 1]![j]! + 1, d[i]![j - 1]! + 1, d[i - 1]![j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length]![b.length]!;
}
const close = (a: string, b: string) => a === b || (a.length >= 5 && b.length >= 5 && lev(a, b) <= 1);

/** How well a reviewer's display name fits a renter's name, 0 to 1. Full name 1; first and last 0.95; first name and
 *  the last name's initial ("Maya O.") 0.85; a small typo in a name 0.85 to 0.9; the first name alone 0.6. */
export function nameScore(reviewer: string | null, renter: string | null): number {
  const r = nameTokens(reviewer), n = nameTokens(renter);
  if (!r.length || !n.length) return 0;
  if (r.join(' ') === n.join(' ')) return 1;
  const first = n[0]!, last = n[n.length - 1]!;
  const rf = r[0]!, rl = r[r.length - 1]!;
  if (r.length >= 2 && n.length >= 2) {
    if (rf === first && rl === last) return 0.95;
    if (rf === first && rl.length === 1 && rl === last[0]) return 0.85;
    if (close(rf, first) && close(rl, last)) return 0.85;
    // the renter's first name and any of their other names (a middle name used as the last)
    if (rf === first && n.slice(1).includes(rl)) return 0.9;
  }
  if (r.length === 1 && rf === first) return 0.6;
  if (r.length >= 2 && rf === first) return 0.5;
  return 0;
}

/** Each review's match: the best renter returned within `windowDays` before it. */
export function matchReviews(reviews: GoogleReviewIn[], candidates: Candidate[], o: { windowDays: number; autoMatch: boolean }): MatchOut[] {
  const day = 86_400_000;
  return reviews.map((rv): MatchOut => {
    const at = Date.parse(rv.reviewed_at);
    const scored = candidates
      .filter((c) => c.returned_at && Number.isFinite(at) && Date.parse(c.returned_at) <= at && at - Date.parse(c.returned_at) <= o.windowDays * day)
      .map((c) => ({ c, s: nameScore(rv.reviewer_name, c.renter_name) }))
      .filter((x) => x.s >= 0.5)
      .sort((a, b) => b.s - a.s || Date.parse(b.c.returned_at!) - Date.parse(a.c.returned_at!));
    const best = scored[0];
    if (!best) return { id: rv.id, booking_id: null, status: 'unmatched', score: 0 };
    // the same renter on two bookings counts once (the latest return); two different people with the same score do not
    const rivals = scored.filter((x) => x !== best && x.s >= best.s - 0.05 && nameTokens(x.c.renter_name).join(' ') !== nameTokens(best.c.renter_name).join(' '));
    const clear = best.s >= 0.85 && rivals.length === 0;
    return { id: rv.id, booking_id: best.c.booking_id, status: clear && o.autoMatch ? 'matched' : best.s >= 0.6 || clear ? 'suggested' : 'unmatched', score: Math.round(best.s * 1000) / 1000 };
  }).map((m): MatchOut => (m.status === 'unmatched' ? { ...m, booking_id: null } : m));
}
