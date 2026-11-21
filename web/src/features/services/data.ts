import 'server-only';
import { cache } from 'react';
import { rpc, sharedRead } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { getFacts, getSettings } from '@/lib/site';
import type { TrackerProduct } from '@/features/tracker-product/data';
import type { ServiceFacts } from './catalog';
import { monthlyShort, priceShort, toPrices } from '@/features/trackers/pages';

// The numbers on the service cards (release 48, migration 3232), in one read (public.service_facts: the tracker product,
// the lowest chauffeur rate, the add-ons with their prices, the landing pages that exist), kept for five minutes per
// server like the site's other shared reads, with the last good answer when the database is busy. The rest comes from
// the settings every page already reads. A read that fails leaves the numbers out; the cards still link.
export interface PublicAddon { code: string; name: string; description: string | null; photo_path: string | null; price_cents: number | null; pricing_unit: string; cap_cents: number | null; lead_time_hours: number; max_per_booking: number }
interface Raw { tracker: TrackerProduct | null; chauffeur_from_cents: number | null; addons: PublicAddon[]; landing: string[] }
const EMPTY: Raw = { tracker: null, chauffeur_from_cents: null, addons: [], landing: [] };

const load = async () => ((await rpc('service_facts', {}, { role: 'service_role' })) ?? EMPTY) as unknown as Raw;
const raw = cache(async (): Promise<Raw> => {
  try { return env().DATA_BACKEND === 'local' ? await load() : ((await sharedRead('service_facts', load)) as Raw); } catch { return EMPTY; }
});
export const getAddons = cache(async (): Promise<PublicAddon[]> => (await raw()).addons ?? []);

export const getServiceFacts = cache(async (): Promise<ServiceFacts> => {
  const [s, f, r] = await Promise.all([getSettings(), getFacts().catch(() => null), raw()]);
  const t = r.tracker;
  return {
    brand: s.brand_name, city: s.city,
    trackerOn: Boolean(t), trackerPrice: t ? `${priceShort({ prices: toPrices(t.prices), available: Boolean(t.available) })}; ${monthlyShort({ tiers: t.tiers ?? [] })}` : null, trackerAvailable: Boolean(t?.available), trackerNote: t?.launch_note ?? 'Shipping soon',
    deliveryFromCents: f?.delivery_min_cents ?? null, chauffeurFromCents: r.chauffeur_from_cents ?? null,
    minAge: f?.min_renter_age ?? null, licence: f?.accepted_licence_classes?.length ? [...f.accepted_licence_classes].sort((a, b) => b.length - a.length).join(' or ') : null,
    airports: (f?.airports ?? []).map((a) => ({ code: a.code, name: a.name })), coverageOptions: 3,
    addons: (r.addons ?? []).map((a) => ({ code: a.code, name: a.name, price_cents: a.price_cents, pricing_unit: a.pricing_unit })),
    landing: new Set(r.landing ?? [])
  };
});
/** Whether the tracker product is on (its pages exist): the footer links it only then. False when the read fails. */
export const trackerOn = cache(async (): Promise<boolean> => Boolean((await raw()).tracker));
