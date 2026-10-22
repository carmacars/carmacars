import 'server-only';
import { rpc } from '@/lib/db/repo';
import { fill, getFacts, getFleet, getSettings, getTokens } from '@/lib/site';
import { consentTexts, rules } from '@/server/booking-data';
import type { WizardProps } from './RequestWizard';

export async function wizardProps(initialSlug: string | null): Promise<WizardProps> {
  const [fleet, f, t, s, r, c] = await Promise.all([getFleet(), getFacts(), getTokens(), getSettings(), rules(), consentTexts()]);
  // 0093: only a program owner's car can be collected at the owner's location; a partner's cars (many) are not asked
  const places = await Promise.all(fleet.map((x) => (x.guideline_rates ? Promise.resolve(null) : rpc('handover_places', { p_vehicle: x.vehicle_id }) as unknown as Promise<{ owner_location: boolean } | null>)));
  const pick = (k: string) => t[k] ?? '';
  return {
    cars: fleet.map((x, i) => ({ slug: x.slug, vehicleId: x.vehicle_id, name: `${x.make} ${x.model}`, year: x.year, trim: x.trim, daily: x.daily_rate_cents, weekend: x.weekend_rate_cents, weekly: x.weekly_rate_cents, monthly: x.monthly_rate_cents, multi: x.multi_day_rate_cents ?? null, insuranceIncluded: !!x.insurance_included, noCreditCard: !!x.no_credit_card, delivery: x.delivery_fee_cents, pickup: x.pickup_fee_cents, ownerLocation: !!places[i]?.owner_location, allowsYoung: x.allows_18_to_20, cover: x.cover ? { path: x.cover.path, alt: x.cover.alt } : null })),
    initialSlug, rules: r, airports: f.airports,
    tokens: Object.fromEntries(['notice', 'turnaround', 'offerHours', 'hst', 'minAge', 'licence', 'addDrvPct', 'cEarly', 'c2', 'nonRef', 'winter', 'winterCap', 'baby', 'babyCap', 'maxDays', 'brand'].map((k) => [k, pick(k)])) as unknown as WizardProps['tokens'],
    marketingText: c.marketing.text, agreeLine: c.agreeLine(r.minAge), ourAddress: s.street_address ? fill(s.street_address, t) : null
  };
}
