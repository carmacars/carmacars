import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import { getFacts, getSettings, listItems } from '@/lib/site';
import type { CarRow } from '@/lib/types';
import { buildDepth, type DepthCar, type DepthFacts, type DepthPoi, type DepthSpec, type DepthVehicle } from './depth';

// The reads behind the depth sections (release 35, part M): the site's facts once per request, and the sourced page
// data (vehicle_specs, vehicle_maintenance_costs, place_pois, migration 1100) as the server. A read that fails or is
// empty leaves its section out; the page still renders.
const SR = { role: 'service_role' as const };

export const getDepthFacts = cache(async (): Promise<DepthFacts> => {
  const [s, f, cover, fuel] = await Promise.all([getSettings(), getFacts(), listItems<{ title: string }>('home.coverage_options').catch(() => []),
    (rpc('seo_fuel_prices', {}, SR) as unknown as Promise<{ gas_cents: number; premium_extra_cents: number; kwh_cents: number } | null>).catch(() => null)]);
  const fee = (code: string) => f.fees[code];
  return {
    brand: s.brand_name, minAge: f.min_renter_age, licenceClasses: [...f.accepted_licence_classes].filter((c) => c !== 'OTHER').sort((a, b) => b.length - a.length || a.localeCompare(b)),
    otherLicenceReview: f.other_licence_for_review,
    youngBands: [...f.young_driver_bands].map((b) => ({ from: b.from_age, to: b.to_age, feeCents: fee(b.code)?.amount_cents ?? null })),
    depositTiersCents: f.deposit_tiers_cents, tollFeeCents: fee('toll_admin_fee')?.amount_cents ?? null, additionalDriverBps: fee('additional_driver')?.percent_bps ?? null,
    deductibleCents: f.deductible_cents, hstBps: f.hst_bps, maxDays: f.max_rental_days, weekFrom: f.weekly_from_days,
    coverOptions: cover.map((o) => o.title).filter(Boolean), airports: f.airports.map((a) => a.name),
    fees: Object.values(f.fees).filter((x) => x.amount_cents !== null && x.amount_cents > 0).map((x) => ({ label: x.label, unit: x.unit, amountCents: x.amount_cents!, capCents: x.cap_cents })),
    noticeHours: f.booking_min_notice_minutes ? Math.round(f.booking_min_notice_minutes / 60) || null : null,
    cancellation: f.cancellation ? { graceHours: f.cancellation.grace_hours, graceBps: f.cancellation.grace_bps, earlyHours: f.cancellation.early_hours, earlyBps: f.cancellation.early_bps,
      lateHours: f.cancellation.late_hours, midBps: f.cancellation.mid_bps } : null,
    fuel: fuel ? { gasCents: fuel.gas_cents, premiumExtraCents: fuel.premium_extra_cents, kwhCents: fuel.kwh_cents } : null
  };
});

export const getPois = cache(async (lat: number | null, lng: number | null): Promise<DepthPoi[]> => {
  if (lat === null || lng === null) return [];
  try { return (((await rpc('place_pois_near', { p_lat: lat, p_lng: lng, p_km: 5, p_each: 5 }, SR)) ?? []) as unknown as DepthPoi[]); } catch { return []; }
});

export const getSpecs = cache(async (make: string, model: string, year: number | null): Promise<DepthSpec[]> => {
  if (!year) return [];
  try { return (((await rpc('vehicle_specs_for', { p_make: make, p_model: model, p_year: year }, SR)) ?? []) as unknown as DepthSpec[]); } catch { return []; }
});

export const getMaintenance = cache(async (make: string, segment: string | null): Promise<DepthVehicle['maintenance']> => {
  if (!segment) return null;
  try { return ((await rpc('maintenance_cost_for', { p_make: make, p_segment: segment }, SR)) ?? null) as unknown as DepthVehicle['maintenance']; } catch { return null; }
});

/** A fleet car as the depth sections read it. */
export function depthCar(c: CarRow): DepthCar {
  return { name: [c.year, c.make, c.model, c.trim].filter(Boolean).join(' '), path: c.path, dailyCents: c.daily_rate_cents, weeklyCents: c.weekly_rate_cents,
    monthlyCents: c.monthly_rate_cents, depositCents: c.deposit_cents, kmPerDay: c.km_allowance_per_day, seats: c.seats, transmission: c.transmission, fuel: c.fuel,
    className: c.class, isSample: !!c.is_sample };
}

/** The depth text of a vehicle page (model, year, trim and their twins): the specs and maintenance of that model year
 *  (and trim), our matching cars (else the nearest similar ones), the requirements and related links. */
export async function vehicleDepth(o: { path: string; name: string; make: string; model: string; year: number | null; trim?: string | null; segment: string | null;
  inv: { exact: CarRow[]; same_model: CarRow[]; similar: CarRow[] }; l100?: number | null; kwh100?: number | null; related?: Array<{ href: string; label: string }>; compare?: { company: string; versus: boolean } | null }) {
  const [facts, specs, maint] = await Promise.all([getDepthFacts(), getSpecs(o.make, o.model, o.year), getMaintenance(o.make, o.segment)]);
  const mine = specs.filter((r) => !r.trim || !o.trim || r.trim.toLowerCase() === o.trim.toLowerCase());
  return buildDepth({ path: o.path, facts, cars: o.inv.exact.map(depthCar), fallbackCars: [...o.inv.same_model, ...o.inv.similar].map(depthCar),
    vehicle: { name: o.name, specs: mine, l100: o.l100 ?? null, kwh100: o.kwh100 ?? null, maintenance: maint }, compare: o.compare ?? null,
    related: { cars: [...o.inv.exact, ...o.inv.same_model, ...o.inv.similar].slice(0, 8).map((c) => ({ href: c.path, label: `${depthCar(c).name} for rent` })),
      places: o.related ?? [] } });
}
