'use server';
import { torontoInstant, validIso, validTime } from '@/lib/dates';
import { dobIso } from '@/features/booking/schema';
import { rentalcoverQuoteId } from '@/server/rentalcover';

// The request form's Protection Plan price (migration 1202): once the renter's name, email and date of birth are in and
// option 3 is chosen, the server asks RentalCover (or reuses a quote for the same renter and dates) and gives back the
// quote's id, which goes with the price check (public.quote_booking prices the plan from it). null: the plan keeps its
// table price, or "priced in your offer". The database checks the car's value and the dates again.
export interface CoverQuoteInput { vehicleId: string; from: string; to: string; tf: string; tt: string; first: string; last: string; email: string; dobY: string; dobM: string; dobD: string }

export async function checkoutCoverQuote(i: CoverQuoteInput): Promise<string | null> {
  const ok = /^[0-9a-f-]{36}$/i.test(i.vehicleId) && validIso(i.from) && validIso(i.to) && validTime(i.tf) && validTime(i.tt)
    && i.first.trim().length > 0 && i.first.length <= 80 && i.last.trim().length > 0 && i.last.length <= 80
    && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(i.email.trim()) && i.email.length <= 200 && /^\d{4}$/.test(i.dobY) && /^\d{1,2}$/.test(i.dobM) && /^\d{1,2}$/.test(i.dobD);
  if (!ok) return null;
  return rentalcoverQuoteId({
    coverage_option: 3, vehicle_id: i.vehicleId, pickup_at: torontoInstant(i.from, i.tf), return_at: torontoInstant(i.to, i.tt),
    renter: { full_name: `${i.first.trim()} ${i.last.trim()}`, email: i.email.trim(), date_of_birth: dobIso(i.dobY, i.dobM, i.dobD) }
  }, 'checkout');
}
