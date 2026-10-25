// Fleet's car status board (October 25, 2026): each car's state right now from the calendar read, in one word, and
// what happens to it next today. Pure: the page reads the calendar, this sorts the cars into states.
export type CarState = 'late' | 'out_today' | 'back_today' | 'on_rent' | 'blocked' | 'turo' | 'free';

export interface CalEntry { type: string; status: string | null; starts_at: string; ends_at: string | null; blocks: boolean | null; booking_number: string | null; renter?: string | null; reason?: string | null }
export interface CalVehicle { id: string; label: string; plate: string | null; status: string; entries: CalEntry[] }

export interface CarRow { id: string; label: string; plate: string | null; state: CarState; at: string | null; booking: string | null; note: string | null }

export const STATE_WORDS: Record<CarState, string> = {
  late: 'Return late', out_today: 'Goes out today', back_today: 'Back today', on_rent: 'On rent', blocked: 'Blocked', turo: 'On Turo', free: 'Available'
};
const ORDER: CarState[] = ['late', 'out_today', 'back_today', 'on_rent', 'turo', 'blocked', 'free'];

/** The Toronto day of an instant, as YYYY-MM-DD. */
export const torontoDay = (ms: number) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date(ms));

/** Each active car's state now; the most pressing first (late returns, then today's handovers). */
export function carBoard(vehicles: CalVehicle[], now: number): CarRow[] {
  const today = torontoDay(now);
  const rows = vehicles.filter((v) => !['onboarding', 'exited', 'total_loss', 'declined', 'retired'].includes(v.status)).map((v): CarRow => {
    const live = v.entries.filter((e) => e.type === 'booking' && ['confirmed', 'on_rent'].includes(e.status ?? '') && e.blocks !== false);
    const late = live.find((e) => e.status === 'on_rent' && e.ends_at && Date.parse(e.ends_at) < now);
    if (late) return { id: v.id, label: v.label, plate: v.plate, state: 'late', at: late.ends_at, booking: late.booking_number, note: late.renter ?? null };
    const back = live.find((e) => e.status === 'on_rent' && e.ends_at && torontoDay(Date.parse(e.ends_at)) === today);
    if (back) return { id: v.id, label: v.label, plate: v.plate, state: 'back_today', at: back.ends_at, booking: back.booking_number, note: back.renter ?? null };
    const out = live.find((e) => e.status === 'confirmed' && torontoDay(Date.parse(e.starts_at)) === today && Date.parse(e.starts_at) >= now - 6 * 3600_000);
    if (out) return { id: v.id, label: v.label, plate: v.plate, state: 'out_today', at: out.starts_at, booking: out.booking_number, note: out.renter ?? null };
    const covering = (e: CalEntry) => Date.parse(e.starts_at) <= now && (!e.ends_at || Date.parse(e.ends_at) > now);
    const rent = live.find((e) => e.status === 'on_rent' || covering(e));
    if (rent) return { id: v.id, label: v.label, plate: v.plate, state: 'on_rent', at: rent.ends_at, booking: rent.booking_number, note: rent.renter ?? null };
    const turo = v.entries.find((e) => e.type === 'turo_trip' && covering(e));
    if (turo) return { id: v.id, label: v.label, plate: v.plate, state: 'turo', at: turo.ends_at, booking: null, note: null };
    const block = v.entries.find((e) => e.type === 'block' && covering(e));
    if (block) return { id: v.id, label: v.label, plate: v.plate, state: 'blocked', at: block.ends_at, booking: null, note: block.reason ? block.reason.replace(/_/g, ' ') : null };
    if (['cleaning', 'out_of_service'].includes(v.status)) return { id: v.id, label: v.label, plate: v.plate, state: 'blocked', at: null, booking: null, note: v.status.replace(/_/g, ' ') };
    return { id: v.id, label: v.label, plate: v.plate, state: 'free', at: null, booking: null, note: null };
  });
  return rows.sort((a, b) => ORDER.indexOf(a.state) - ORDER.indexOf(b.state) || (a.at ?? '').localeCompare(b.at ?? '') || a.label.localeCompare(b.label));
}

/** How many cars are in each state. */
export function countStates(rows: CarRow[]): Record<CarState, number> {
  const c = Object.fromEntries(ORDER.map((s) => [s, 0])) as Record<CarState, number>;
  for (const r of rows) c[r.state] += 1;
  return c;
}

export { ORDER as CAR_STATES };
