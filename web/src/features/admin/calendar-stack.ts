// The master calendar's bar layout (0284). No imports: unit tested in Node. A car's row has two lanes: the top for what
// takes the car (a blocking booking that is confirmed, on rent or done, and blocks), the lower for the rest (requests,
// offers, non-blocking bookings, placeholders). Bars that overlap in a lane go one under the other instead of on top of
// each other, so two requests or a request and a placeholder for the same days are both readable.
export interface Bar { type: string; id: string; status: string | null; blocks: boolean | null; starts_at: string; ends_at: string | null; placeholder?: boolean }

/** One bar's height and gap, in pixels. */
export const BAR = 23;
export const keyOf = (e: Pick<Bar, 'type' | 'id'>) => `${e.type}${e.id}`;
export const lane = (e: Bar): 'top' | 'low' =>
  e.type === 'block' || (!e.placeholder && ['confirmed', 'on_rent', 'returned', 'closed'].includes(e.status ?? '') && e.blocks !== false) ? 'top' : 'low';

export interface Stack { at: Map<string, number>; top: number; low: number }
/** Each bar's row within its lane (first free row, earliest first), and how many rows each lane needs (at least 1). */
export function stack(entries: Bar[], end: number): Stack {
  const at = new Map<string, number>(), rows = { top: [] as number[], low: [] as number[] };
  const bars = entries.filter((e) => e.type === 'booking' || e.type === 'block')
    .map((e) => ({ e, s: new Date(e.starts_at).getTime(), f: e.ends_at ? new Date(e.ends_at).getTime() : end }))
    .sort((a, b) => a.s - b.s || b.f - a.f);
  for (const b of bars) {
    const r = rows[lane(b.e)];
    let i = r.findIndex((busy) => busy <= b.s);
    if (i < 0) { i = r.length; r.push(b.f); } else r[i] = b.f;
    at.set(keyOf(b.e), i);
  }
  return { at, top: Math.max(1, rows.top.length), low: Math.max(1, rows.low.length) };
}
/** A bar's distance from the top of the car's row. */
export const topOf = (e: Bar, st: Stack) => 4 + BAR * ((lane(e) === 'top' ? 0 : st.top) + (st.at.get(keyOf(e)) ?? 0));
/** The row's height: two bars and the strips under them, taller when bars stack. */
export const rowHeight = (st: Stack) => Math.max(52, 6 + BAR * (st.top + st.low));
