import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import { fill, getFacts, getSettings, getTokens } from '@/lib/site';
import { consentTexts, rules } from '@/server/booking-data';
import type { CarOption, WizardCar, WizardProps } from './RequestWizard';
import { toWizardCar, type BookingCarRow } from './wizard-car';

/** 0102: the car list of the form (id, slug, label, from price), one light call instead of the fleet's full rows */
export async function bookingCars(): Promise<CarOption[]> {
  const rows = ((await rpc('booking_cars', {})) ?? []) as unknown as { vehicle_id: string; slug: string; label: string; from_cents: number; year_confirmed: boolean; is_sample: boolean }[];
  return rows.map((r) => ({ slug: r.slug, vehicleId: r.vehicle_id, label: r.label, from: r.from_cents, yearConfirmed: r.year_confirmed, isSample: r.is_sample }));
}

/** 0102: the one car the form opens on, with its prices, options and handover places; null when it is not on the site */
export const bookingCar = cache(async (slug: string): Promise<WizardCar | null> => {
  const r = (await rpc('booking_car', { p_slug: slug })) as unknown as BookingCarRow | null;
  return r ? toWizardCar(r) : null;
});

export async function wizardProps(initialSlug: string | null): Promise<WizardProps> {
  const [options, initialCar, f, t, s, r, c] = await Promise.all([bookingCars(), initialSlug ? bookingCar(initialSlug) : Promise.resolve(null), getFacts(), getTokens(), getSettings(), rules(), consentTexts()]);
  const pick = (k: string) => t[k] ?? '';
  return {
    options, initialCar, initialSlug, rules: r, airports: f.airports,
    tokens: Object.fromEntries(['notice', 'turnaround', 'offerHours', 'hst', 'minAge', 'licence', 'addDrvPct', 'cEarly', 'c2', 'nonRef', 'winter', 'winterCap', 'baby', 'babyCap', 'maxDays', 'brand'].map((k) => [k, pick(k)])) as unknown as WizardProps['tokens'],
    marketingText: c.marketing.text, agreeLine: c.agreeLine(r.minAge), ourAddress: s.street_address ? fill(s.street_address, t) : null
  };
}
