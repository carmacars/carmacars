// Add-ons (migration 0066): what the catalogue returns for a car, what a booking holds, and the words for a price.
// Money is integer cents from the database; nothing here prices a booking (the quote and the booking do).
import { money } from '@/lib/format';

export interface AddonOption {
  id: string; code: string; name: string; description: string | null; photo_path: string | null;
  pricing_unit: 'per_trip' | 'per_day' | 'per_hour'; unit_price_cents: number; max_days: number | null; cap_cents: number | null;
  min_hours: number | null; hst_applies: boolean; lead_time_hours: number; max_per_booking: number; needs_confirmation: boolean;
  prepaid_fuel: boolean; non_refundable_after_lead: boolean; available: number | null; notice_ok: boolean; add_until?: string;
}
export interface AddonChoice { code: string; quantity: number; hours?: number | null }
export interface BookingAddon {
  id: string; addon_id: string; code: string; name: string; quantity: number; hours: number | null; pricing_unit: string; unit_price_cents: number;
  status: 'pending' | 'confirmed'; added_via: string; after_booking: boolean; paid: boolean; amount_cents: number | null; hst_cents: number | null;
  needs_prep: boolean; needs_confirmation: boolean; prepaid_fuel: boolean; handover_note: string | null; kept_on_cancel?: boolean; line_item_id?: string | null;
}

const num = (n: number) => String(+Number(n).toFixed(2));

/** "$15 a day, up to $75" / "$45 an hour, 3 hours minimum" / "$150" */
export function addonPrice(o: Pick<AddonOption, 'pricing_unit' | 'unit_price_cents' | 'max_days' | 'cap_cents' | 'min_hours'>): string {
  const p = money(o.unit_price_cents);
  if (o.pricing_unit === 'per_day') {
    return [`${p} a day`, o.max_days ? `at most ${o.max_days} days` : '', o.cap_cents !== null && o.cap_cents !== undefined ? `up to ${money(o.cap_cents)} a trip` : ''].filter(Boolean).join(', ');
  }
  if (o.pricing_unit === 'per_hour') {
    return [`${p} an hour`, o.min_hours ? `${num(o.min_hours)} hours minimum` : '', o.cap_cents !== null && o.cap_cents !== undefined ? `up to ${money(o.cap_cents)}` : ''].filter(Boolean).join(', ');
  }
  return `${p} a trip`;
}

/** The notes a renter should read before choosing it. */
export function addonNotes(o: AddonOption, staff = false): string[] {
  const n: string[] = [];
  if (o.lead_time_hours > 0) n.push(`Needs ${o.lead_time_hours} hours’ notice${o.notice_ok || staff ? '' : ': too late for this pickup'}`);
  if (o.needs_confirmation) n.push(staff ? 'Confirm it with the renter' : 'We confirm it before your booking is final');
  if (o.non_refundable_after_lead && o.lead_time_hours > 0) n.push(`Not refunded within ${o.lead_time_hours} hours of pickup`);
  if (o.available !== null && o.available !== undefined) n.push(o.available > 0 ? `${o.available} left for your dates` : 'None left for your dates');
  return n;
}

export const choiceOf = (list: AddonChoice[], code: string) => list.find((c) => c.code === code) ?? null;

/** For a quote or a request: the choices as the database takes them. */
export const addonsPayload = (list: AddonChoice[]) =>
  list.filter((c) => c.quantity > 0).map((c) => ({ code: c.code, quantity: c.quantity, ...(c.hours ? { hours: c.hours } : {}) }));

/** A choice the renter may make now: offered, in stock, with the notice it needs. */
export const selectable = (o: AddonOption, staff = false) => (staff || o.notice_ok) && (o.available === null || o.available === undefined || o.available > 0);
