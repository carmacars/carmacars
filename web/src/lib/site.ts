import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import type { CarRow, ContentBlock, CookieWording, FaqItem, SiteFacts, SiteSettings, SlotPhoto } from '@/lib/types';
import { hours, list, money, ordinal, pct, plural } from '@/lib/format';

// Everything a public page prints that an admin can change: site settings (0022, 0025), policy
// numbers and fees (0027 site_facts), editable copy (site_content_blocks) and the fleet. Read once
// per render with the anonymous role, exactly what a visitor's browser could read.

export const getSettings = cache(async () => (await rpc('site_settings_public', {})) as unknown as SiteSettings);
export const getFacts = cache(async () => (await rpc('site_facts', {})) as unknown as SiteFacts);
export const getBlocks = cache(async () => (await rpc('site_content', {})) as unknown as ContentBlock[]);
export const getFleet = cache(async () => (await rpc('fleet', { p_filters: {} })) as unknown as CarRow[]);
export const getClasses = cache(async () => (await rpc('vehicle_classes', {})) as unknown as { code: string; label: string }[]);

export async function block(key: string): Promise<ContentBlock | undefined> {
  return (await getBlocks()).find((b) => b.key === key);
}
export async function faqItems(key: string): Promise<FaqItem[]> {
  return ((await block(key))?.data.items as FaqItem[] | undefined) ?? [];
}
export async function listItems<T>(key: string): Promise<T[]> {
  return ((await block(key))?.data.items as T[] | undefined) ?? [];
}
export async function slotPhoto(key: string): Promise<SlotPhoto | null> {
  return ((await block(`photo.${key}`))?.data as unknown as SlotPhoto | undefined) ?? null;
}
export async function cookieWording(): Promise<CookieWording | null> {
  return ((await block('cookies.banner'))?.data as unknown as CookieWording | undefined) ?? null;
}

export { photoUrl } from '@/lib/photo';
export const siteUrl = () => env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');

export type Tokens = Record<string, string>;

/** The {{token}} values for copy, built from the database. A token that is missing throws. */
export const getTokens = cache(async (): Promise<Tokens> => {
  const [s, f, fleet] = await Promise.all([getSettings(), getFacts(), getFleet()]);
  const extra = ((await block('policy.extra'))?.data ?? {}) as { accident_call_hours?: number; owner_reply?: string };
  const carma = (await block('brand.carma_line'))?.body ?? '';
  const fee = (code: string) => f.fees[code];
  const amt = (code: string) => money(fee(code)?.amount_cents ?? null);
  const bands = [...f.young_driver_bands].sort((a, b) => a.from_age - b.from_age);
  const [bandA, bandB] = bands;
  const fullAge = (bands[bands.length - 1]?.to_age ?? 25) + 1;
  const ydA = bandA ? amt(bandA.code) : ''; const ydB = bandB ? amt(bandB.code) : '';
  const dels = fleet.map((c) => c.delivery_fee_cents); const overs = fleet.map((c) => c.overage_cents_per_km); const dailies = fleet.map((c) => c.daily_rate_cents);
  const c = f.cancellation;
  const lic = [...f.accepted_licence_classes].sort((a, b) => b.length - a.length || a.localeCompare(b));
  const late = fee('late_return_fee');
  return {
    brand: s.brand_name, tagline: s.tagline ?? '', carma, city: s.city, region: s.region, serviceArea: s.service_area,
    email: s.public_email ?? '', reply: s.reply_wording ? `We reply ${s.reply_wording}` : '', replyShort: s.reply_wording ?? '',
    hours: s.opening_hours_text ?? '', phone: s.phone_display ?? '', roadside: s.roadside_phone_display ?? '',
    hst: pct(f.hst_bps), maxDays: String(f.max_rental_days), maxDaysLess1: String(f.max_rental_days - 1),
    weekFrom: String(f.weekly_from_days), weekFromLess1: String(f.weekly_from_days - 1),
    minAge: String(f.min_renter_age), fullAge: String(fullAge),
    youngA: bandA ? `${bandA.from_age} to ${bandA.to_age}` : '', youngB: bandB ? `${bandB.from_age} to ${bandB.to_age}` : '',
    licence: list(lic), depTiers: list(f.deposit_tiers_cents.map((x) => money(x))),
    depMin: money(Math.min(...f.deposit_tiers_cents)), depMax: money(Math.max(...f.deposit_tiers_cents)), kmChoices: list(f.km_choices.map(String)),
    depLead: hours(f.take_deposit_lead_minutes), holdDays: String(f.deposit_hold_max_days),
    releaseDays: plural(f.deposit_release_business_days, 'business day'), holdbackDays: plural(f.deposit_holdback_days, 'day'),
    refundDays: plural(f.refund_business_days, 'business day'), notice: hours(f.booking_min_notice_minutes), turnaround: hours(f.turnaround_buffer_minutes),
    ydA, ydB, addDrvPct: pct(fee('additional_driver')?.percent_bps ?? 0),
    winter: amt('winter_tire'), winterCap: money(fee('winter_tire')?.cap_cents ?? null), baby: amt('baby_seat'), babyCap: money(fee('baby_seat')?.cap_cents ?? null),
    nonRef: pct(f.non_refundable_discount_bps), delMin: dels.length ? money(Math.min(...dels)) : '', delMax: dels.length ? money(Math.max(...dels)) : '',
    airports: list(f.airports.map((a) => a.name), 'and'), deductible: money(f.deductible_cents),
    adminClaim: amt('admin_fee_claim'), adminOther: amt('admin_fee_other'),
    overMin: overs.length ? money(Math.min(...overs), { cents: true }) : '', overMax: overs.length ? money(Math.max(...overs), { cents: true }) : '',
    grace: plural(late?.grace_minutes ?? 0, 'minute'), graceShort: `${late?.grace_minutes ?? 0} minute`, lateHr: amt('late_return_fee'),
    fuelPct: pct(fee('fuel')?.percent_bps ?? 0), fuelFee: amt('fuel_service_fee'), evPer: amt('recharging'),
    clean: amt('cleaning'), cleanHeavy: amt('cleaning_heavy'), pet: amt('pet_cleaning'), smoke: amt('smoking'), keyFee: amt('lost_key_fee'),
    tollFee: amt('toll_admin_fee'), ticketFee: amt('ticket_admin_fee'), declined: amt('declined_payment'),
    c1: pct(c.grace_bps), c2: pct(c.early_bps), c3: pct(c.mid_bps), cGrace: String(c.grace_hours), cEarly: String(c.early_hours), cLate: String(c.late_hours),
    offerHours: String(f.offer_expiry_hours), verifyHours: String(f.verification_due_hours_before_pickup),
    callHours: String(extra.accident_call_hours ?? ''), reportHours: String(f.incident_report_hours), hiddenHours: String(f.damage_late_report_hours),
    payoutDay: ordinal(f.payout_day), billDay: ordinal(f.billing_day), noticeDays: String(f.notice_period_days), referralPct: pct(f.kickback_bps),
    ownerReply: extra.owner_reply ?? '', listDays: s.listing_time_promise ?? '', minDaily: dailies.length ? money(Math.min(...dailies)) : ''
  };
});

export function fill(text: string, t: Tokens): string {
  return text.replace(/\{\{(\w+)\}\}/g, (m, k: string) => {
    if (!(k in t)) throw new Error(`Unknown token ${m}`);
    return t[k]!;
  });
}

/** Token filler bound to the current tokens. */
export async function filler() {
  const t = await getTokens();
  return (s: string) => fill(s, t);
}
