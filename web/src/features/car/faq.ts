import { money } from '@/lib/format';
import { rpc } from '@/lib/db/repo';
import { addDays, torontoInstant, torontoToday } from '@/lib/dates';
import type { CarPage } from '@/lib/types';
import type { Tokens } from '@/lib/site';

// The questions every car page answers (prototype car pages), with this car's own numbers from the
// database. The listing's own FAQ (vehicle_listings.faq, written per car) follows these.
export function carFaq(c: CarPage, o: { ydA: number | null; ydB: number | null; ev: boolean }, t: Tokens) {
  const n = `${c.make} ${c.model}`;
  const items = [
    { question: `How much does it cost to rent the ${n}?`, answer: `${money(c.daily_rate_cents)} a day, or ${money(c.weekend_rate_cents)} for a day that starts on a Friday or Saturday. A week is ${money(c.weekly_rate_cents)} and {{maxDays}} days is ${money(c.monthly_rate_cents)}. Trips of 1 to {{weekFromLess1}} days never cost more than the weekly rate. HST and any fees are added on top.` },
    { question: `How much is the deposit for the ${n}?`, answer: `${money(c.deposit_cents)}. It is taken about {{depLead}} before pickup, not when you book. For rentals of {{holdDays}} days or less it is a hold on your card. We release the balance within {{releaseDays}} after you return the car.` },
    { question: 'How many kilometres are included?', answer: `${c.km_allowance_per_day} km for each day of the rental, added together. A 3 day rental includes ${(c.km_allowance_per_day * 3).toLocaleString('en-CA')} km. Extra kilometres cost ${money(c.overage_cents_per_km, { cents: true })} each.` },
    c.allows_18_to_20
      ? { question: `Can a driver aged {{youngA}} rent the ${n}?`, answer: `Yes. Every car accepts drivers {{minAge}} and up with a {{licence}} licence. For this car the young driver fee is ${money(o.ydA)} a day for ages {{youngA}} and ${money(o.ydB)} a day for ages {{youngB}}, with no maximum.` }
      : { question: `Can a young driver rent the ${n}?`, answer: `Drivers aged {{youngB}} can, with a young driver fee of ${money(o.ydB)} a day and no maximum.` },
    { question: `Can you deliver the ${n}?`, answer: `Yes, anywhere, including {{airports}}. Each way costs ${money(c.delivery_fee_cents)} for this car plus the distance from our location, priced in your offer. An airport surcharge may apply.` },
    o.ev
      ? { question: 'How does charging work?', answer: 'Return the car with the same charge it had at pickup. If it comes back lower, recharging costs {{evPer}} for each 10% of battery, plus a {{fuelFee}} service fee.' }
      : { question: 'What is the fuel policy?', answer: 'Return the car with the same fuel it had at pickup. If it comes back lower, we refuel it at the pump price plus {{fuelPct}}, plus a {{fuelFee}} service fee.' },
    { question: `Can I take the ${n} outside Ontario?`, answer: 'The car stays in Ontario unless we agree in writing first. Ask in your request and we will tell you before you pay.' }
  ];
  void t;
  return items;
}

/** This car's per-day driver fees, read from a one-day quote (public.quote_booking), so a per-car
 *  override (vehicle_fee_overrides, not public) shows without exposing the table. */
export async function perDayFees(vehicleId: string): Promise<Record<string, number>> {
  const d = addDays(torontoToday(), 30);
  try {
    const q = (await rpc('quote_booking', { p_vehicle: vehicleId, p_pickup: torontoInstant(d, '10:00'), p_return: torontoInstant(addDays(d, 1), '10:00'),
      p_options: { drivers: [{ role: 'renter', age_band: '18_to_20' }, { role: 'additional', age_band: '21_to_25' }] } })) as unknown as { lines: { charge_type: string; detail: { per_day_cents?: number } }[] };
    const out: Record<string, number> = {};
    for (const l of q.lines) if (typeof l.detail?.per_day_cents === 'number') out[l.charge_type] = l.detail.per_day_cents;
    return out;
  } catch {
    return {};
  }
}
