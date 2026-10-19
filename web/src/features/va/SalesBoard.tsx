import Link from 'next/link';
import type { ReactNode } from 'react';
import { pct } from '@/lib/format';
import { $, Badge, Card, Filters, Table, Tiles, d, t } from '@/features/admin/ui';
import { Commissions, pctBps, type CommissionRow, type StaffCommissions } from '@/features/sales/Commissions';

// Sales tracking (migration 0057): one staff member's quotes, offers, rentals added, bookings confirmed, conversion and
// booked revenue by week or month, the follow-ups due and each deal. The same board is My sales in the assistant portal
// (every staff function since 0058) and Admin > People > Staff > a staff member > Sales, with the commissions (0058).
export interface SalesFigures { quotes: number; rentals_added: number; offers_sent: number; deals: number; won: number; conversion_bps: number | null; confirmed: number; cancelled: number; revenue_cents: number }
export interface SalesPeriod extends SalesFigures { start: string; end: string; label: string; current: boolean }
export interface SalesDeal {
  booking_number: string; status: string; source: string; renter: string | null; vehicle: string; pickup_at: string; return_at: string;
  credited: boolean; how: 'quote' | 'offer' | 'manual_rental' | 'admin' | 'referral' | null; sourced?: boolean; choice?: 'sourced' | 'for_carmacars' | null; claimed?: boolean; custom_price?: boolean;
  commission?: { status: string; amount_cents: number; rate_bps: number } | null; credited_to: string | null; created_by_me: boolean; offers_by_me: number;
  at: string; confirmed_at: string | null; offer_expires_at: string | null; rental_cents: number; revenue_cents: number; va_can_open: boolean;
}
export interface SalesFollowUp { booking_number: string; status: string; renter: string | null; vehicle: string; pickup_at: string; step: string; due_at: string | null }
export interface StaffSales {
  staff: { id: string; name: string; function: string | null; admin: boolean; commission_bps?: number | null };
  period: 'week' | 'month'; today: string; periods: SalesPeriod[]; follow_ups: SalesFollowUp[]; deals: SalesDeal[]; commissions: StaffCommissions;
}

const late = (iso: string | null) => iso !== null && Date.parse(iso) < Date.now();
export const conversion = (bps: number | null | undefined) => (bps === null || bps === undefined ? 'no deals' : pct(bps));

/** How a deal reached this person, in words. */
export function creditWords(x: SalesDeal, own: boolean): string {
  if (!x.credited) {
    const theirs = x.credited_to ? `credited to ${x.credited_to}` : 'credited to nobody';
    return x.created_by_me ? `Your quote, ${theirs}` : x.offers_by_me ? `You sent an offer, ${theirs}` : theirs;
  }
  const you = own ? 'Your' : 'Their';
  const tag = x.sourced ? ', sourced' : x.claimed ? ', claimed as sourced (an Admin decides)' : x.choice === 'for_carmacars' ? ', entered for CarmaCars' : '';
  return base(x, own, you) + tag;
}
function base(x: SalesDeal, own: boolean, you: string): string {
  switch (x.how) {
    case 'quote': return `${you} quote`;
    case 'manual_rental': return own ? 'Rental you added' : 'Rental they added';
    case 'offer': return own ? 'Your offer (first offer sent)' : 'Their offer (first offer sent)';
    case 'admin': return 'Given by an Admin';
    case 'referral': return own ? 'Your referral link' : 'Their referral link';
    default: return '';
  }
}

export function SalesBoard({ s, base: path, sp, own, bookingHref, dealAction, commissionAction }: {
  s: StaffSales; base: string; sp: Record<string, string | undefined>; own: boolean;
  /** Where a booking number links to (null: shown as text, for one this person may not open). */
  bookingHref: (x: { booking_number: string; va_can_open?: boolean }) => string | null;
  /** An Admin's action on a deal (reassign). */
  dealAction?: (x: SalesDeal) => ReactNode;
  /** An Admin's action on a commission (reverse). */
  commissionAction?: (r: CommissionRow) => ReactNode;
}) {
  const now = s.periods[0];
  const unit = s.period === 'week' ? 'this week' : 'this month';
  const num = (n: string) => { const h = bookingHref({ booking_number: n, va_can_open: s.deals.find((x) => x.booking_number === n)?.va_can_open ?? true }); return h ? <Link prefetch={false} className="link" href={h}>{n}</Link> : <span>{n}</span>; };
  return (
    <>
 <Commissions c={s.commissions} own={own} rowAction={commissionAction} />
      <Filters base={path} name="period" value={s.period} sp={sp} options={[['week', 'By week'], ['month', 'By month']]} />
      {now && <div data-testid="sales-tiles"><Tiles items={[
        { k: `Quotes created ${unit}`, v: now.quotes },
        { k: `Offers sent ${unit}`, v: now.offers_sent },
        { k: `Rentals added ${unit}`, v: now.rentals_added },
        { k: `Bookings confirmed ${unit}`, v: now.confirmed, sub: now.cancelled ? `${now.cancelled} cancelled since` : undefined },
        { k: 'Conversion', v: conversion(now.conversion_bps), sub: `${now.won} of ${now.deals} deals confirmed` },
        { k: `Booked revenue ${unit}`, v: $(now.revenue_cents), sub: 'rental charge before tax' },
        { k: 'Follow-ups due', v: s.follow_ups.length, warn: s.follow_ups.some((f) => late(f.due_at)) }
      ]} /></div>}
      <Card title={s.period === 'week' ? 'By week' : 'By month'} testId="sales-periods">
        <Table<SalesPeriod & Record<string, unknown>> caption={s.period === 'week' ? 'Sales by week' : 'Sales by month'} rows={s.periods as Array<SalesPeriod & Record<string, unknown>>} rowKey={(r) => r.start} cols={[
          { key: 'label', label: s.period === 'week' ? 'Week' : 'Month', render: (r) => r.current ? <b>{r.label}</b> : r.label },
          { key: 'quotes', label: 'Quotes created', num: true }, { key: 'offers_sent', label: 'Offers sent', num: true },
          { key: 'rentals_added', label: 'Rentals added', num: true }, { key: 'confirmed', label: 'Bookings confirmed', num: true },
          { key: 'conversion_bps', label: 'Conversion', num: true, render: (r) => conversion(r.conversion_bps) },
          { key: 'revenue_cents', label: 'Booked revenue', num: true, render: (r) => $(r.revenue_cents) }]} />
      </Card>
      <Card title={`Follow-ups due (${s.follow_ups.length})`} testId="sales-follow-ups">
        {s.follow_ups.length ? <ul className="ad-list">{s.follow_ups.map((f) => (
          <li key={f.booking_number}><span>{num(f.booking_number)} {f.renter ?? ''}</span><span className={late(f.due_at) ? 'ad-late' : 'small'}>{f.step}{f.due_at ? `, by ${t(f.due_at)}` : ''}</span>
            <span className="ad-sub">{f.vehicle} · pickup {t(f.pickup_at)}</span></li>))}</ul>
          : <p className="small muted">Nothing to follow up. Every deal {own ? 'of yours ' : ''}is confirmed or closed.</p>}
      </Card>
      <Card title="Deals" testId="sales-deals">
        <Table<SalesDeal & Record<string, unknown>> caption="Deals" rows={s.deals as Array<SalesDeal & Record<string, unknown>>} rowKey={(r) => r.booking_number} empty="No deals in the last 180 days." cols={[
          { key: 'booking_number', label: 'Booking', render: (r) => num(r.booking_number) },
          { key: 'status', label: 'Status', render: (r) => <Badge s={r.status} /> },
          { key: 'how', label: 'Credit', className: 'wrap', render: (r) => creditWords(r, own) },
          { key: 'at', label: 'Since', render: (r) => d(r.at) },
          { key: 'renter', label: 'Renter' }, { key: 'vehicle', label: 'Car', className: 'wrap' },
          { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) },
          { key: 'rental_cents', label: 'Rental charge', num: true, render: (r) => $(r.rental_cents) },
          { key: 'revenue_cents', label: 'Counted', num: true, render: (r) => r.credited ? $(r.revenue_cents) : <span className="muted">not credited</span> },
          { key: 'commission', label: 'Commission', num: true, render: (r) => r.commission ? `${$(r.commission.amount_cents)} (${pctBps(r.commission.rate_bps)})` : <span className="muted">none</span> },
          ...(dealAction ? [{ key: 'act', label: 'Actions', render: (r: SalesDeal & Record<string, unknown>) => dealAction(r) }] : [])]} />
      </Card>
      <Card title="How it is counted">
        <ul className="small">
          <li>A deal is credited to the person who created the quote or added the rental. A request that came in from the website is credited to whoever sent its first offer. An Admin can give a deal to someone else.</li>
          <li>Sourced: the person chose &quot;I sourced this client&quot; when entering it (or it came from a field staff referral link, or an Admin credited it). Only sourced deals earn a commission.</li>
          <li>Quotes created, offers sent and rentals added count by the day they happened. Bookings confirmed and booked revenue count by the day the booking was confirmed.</li>
          <li>Conversion: of the deals credited in the period, the share confirmed so far.</li>
          <li>Booked revenue: the rental charge before tax, after discounts. A cancelled booking counts only what was kept, and refunds come off.</li>
          <li>Commissions are counted on rentals completed and paid in full, and paid only after an Admin approves them.</li>
        </ul>
      </Card>
    </>
  );
}
