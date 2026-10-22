'use client';
import { useEffect, useRef, useState } from 'react';
import { browserRpc } from '@/lib/browser-rpc';
import { clock, shortDate, torontoInstant } from '@/lib/dates';
import { money, plural } from '@/lib/format';

// PriceBreakdown (docs/blueprint/00-overview.md section 6): shows exactly the lines
// public.quote_booking returns. No arithmetic on money here; the labels only describe the lines.
export interface QuoteLine { charge_type: string; label: string; description?: string; amount_cents: number; quantity: number; unit_amount_cents: number; detail: Record<string, unknown> }
export interface Quote {
  lines: QuoteLine[]; hst_cents: number; total_cents: number; deposit_cents: number; deposit_method: string; billable_days: number;
  km_allowance_total: number; overage_cents_per_km: number; available: boolean; problems: { code: string; message: string }[];
  coverage: { option: number | null; priced_in_offer: boolean; price_note: string | null };
  promo?: { code: string; applied: boolean; problem: string | null } | null;
}
export interface QuoteInput { vehicleId: string; from: string; to: string; tf: string; tt: string; options: Record<string, unknown> }

/** Live visitors (0086): the price shown for their dates, for the beacon (sent only with analytics consent). */
function priceShown(q: Quote) {
  const d: Record<string, string> = { days: String(q.billable_days), total: String(Math.round(q.total_cents / 100)), avail: q.available ? '1' : '0' };
  if (q.lines.some((l) => l.charge_type === 'delivery')) d.deliv = '1';
  if (q.lines.some((l) => l.charge_type === 'additional_driver')) d.xdrv = '1';
  window.dispatchEvent(new CustomEvent('cc:track', { detail: { k: 'quote_seen', d } }));
}

export function useQuote(input: QuoteInput | null) {
  const [res, setRes] = useState<{ key: string; q: Quote | null; error: string } | null>(null);
  const key = input ? JSON.stringify(input) : '';
  const first = useRef(true);
  useEffect(() => {
    if (!input) return;
    let live = true;
    // 0102: the first price of the page is asked at once; later changes wait for the typing to settle
    const t = setTimeout(() => {
      browserRpc<Quote>('quote_booking', { p_vehicle: input.vehicleId, p_pickup: torontoInstant(input.from, input.tf), p_return: torontoInstant(input.to, input.tt), p_options: input.options })
        .then((r) => { if (live) { setRes({ key, q: r, error: '' }); priceShown(r); } })
        .catch((e: Error) => { if (live) setRes({ key, q: null, error: e.message }); });
    }, first.current ? 0 : 300);
    first.current = false;
    return () => { live = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  if (!input) return { q: null, error: '', loading: false };
  const current = res && res.key === key;
  // while a new quote loads, the last one stays on screen (no layout shift)
  return { q: res?.q ?? null, error: current ? res.error : '', loading: !current };
}

export interface LabelTokens { nonRef: string; addDrvPct: string }
function describe(l: QuoteLine, t: LabelTokens): { k: string; note?: string } {
  const d = l.detail ?? {};
  const perDay = typeof d.per_day_cents === 'number' ? money(d.per_day_cents, { cents: true }) : '';
  const cap = typeof d.cap_cents === 'number' ? `, up to ${money(d.cap_cents)}` : ', no maximum';
  const distance = d.needs_distance ? 'Plus distance from our location, priced in your offer' : typeof d.distance_km === 'number' ? `${d.distance_km} km from our location` : undefined;
  const airport = d.kind === 'airport';
  // 0066: an add-on line (the old baby seat and winter tire codes included) names itself
  if (typeof d.pricing_unit === 'string' && typeof d.unit_price_cents === 'number') {
    const each = money(d.unit_price_cents, { cents: true });
    const upTo = typeof d.cap_cents === 'number' ? `, up to ${money(d.cap_cents)}` : '';
    const note = d.status === 'pending' ? 'We confirm it in your offer'
      : d.pricing_unit === 'per_day' ? `${each} a day${upTo}${l.quantity > 1 ? ' each' : ''}` : d.pricing_unit === 'per_hour' ? `${each} an hour${upTo}` : undefined;
    return { k: (l.description ?? l.label).replace(/ \(to be confirmed\)$/, ''), note };
  }
  switch (l.charge_type) {
    case 'rental_charge': return { k: 'Rental charge', note: `${String(d.rate_rule ?? '')}${d.capped ? ', capped' : ''}`.replace(/^./, (c) => c.toUpperCase()) };
    case 'non_refundable_discount': return { k: `Non-refundable booking, ${t.nonRef} off` };
    case 'delivery': return { k: airport ? `Delivery to ${String(d.airport_name ?? 'the airport')}` : 'Delivery to you', note: distance && (airport ? `${distance}. An airport surcharge may apply` : distance) };
    case 'pickup': return { k: airport ? `Pickup at ${String(d.airport_name ?? 'the airport')} at the end` : 'Pickup from you at the end', note: distance };
    case 'young_driver_18_20': return { k: 'Young driver fee, ages 18 to 20', note: perDay && `${perDay} a day${cap}` };
    case 'young_driver_21_25': return { k: 'Young driver fee, ages 21 to 25', note: perDay && `${perDay} a day${cap}` };
    case 'additional_driver': return { k: 'Additional driver', note: perDay && `${perDay} a day, ${t.addDrvPct} of the daily rate` };
    case 'winter_tire': return { k: 'Winter tires', note: perDay && `${perDay} a day${cap}` };
    case 'baby_seat': return { k: typeof d.seats === 'number' && d.seats > 1 ? `Baby seats (${d.seats})` : 'Baby seat', note: perDay && `${perDay} a day each${cap} each` };
    case 'coverage_sold': return { k: 'Protection Plan' };
    case 'promo_discount': return { k: 'Promo code', note: 'Off the rental charge' };
    default: return { k: l.label };
  }
}

function Tween({ cents }: { cents: number }) {
  const [shown, setShown] = useState(cents);
  const from = useRef(cents);
  useEffect(() => {
    const start = from.current; from.current = cents;
    if (start === cents || window.matchMedia('(prefers-reduced-motion: reduce)').matches) { setShown(cents); return; }
    const t0 = performance.now(); let raf = 0;
    const step = (now: number) => { const k = 1 - Math.pow(1 - Math.min(1, (now - t0) / 380), 3); setShown(Math.round(start + (cents - start) * k)); if (k < 1) raf = requestAnimationFrame(step); };
    raf = requestAnimationFrame(step); return () => cancelAnimationFrame(raf);
  }, [cents]);
  return <b>{money(shown, { cents: true })}</b>;
}

export function Estimate({ q, error, loading, from, to, tf, tt, rates, hst, maxDays, labels, problem, coverageChosen }: {
  q: Quote | null; error: string; loading: boolean; from: string; to: string; tf: string; tt: string; hst: string; maxDays: number;
  rates: { daily: number; weekend: number; weekly: number; monthly: number; multi?: number | null }; labels: LabelTokens; problem?: string; coverageChosen?: boolean;
}) {
  if (!from || !to) {
    return (
      <div className="estimate" aria-live="polite">
        <p className="estimate__empty">Pick your pickup and return dates to see the price for this car.</p>
        <table className="spec spec--num"><tbody>
          {rates.multi ? <>
            <tr><th scope="row">1 to 2 days, a day</th><td>{money(rates.daily)}</td></tr>
            <tr><th scope="row">3 to 6 days, a day</th><td>{money(rates.multi)}</td></tr>
            <tr><th scope="row">7 days or more, a day</th><td>{money(Math.round(rates.weekly / 7))}</td></tr>
          </> : <>
          <tr><th scope="row">Daily</th><td>{money(rates.daily)}</td></tr>
          <tr><th scope="row">Weekend day (Fri, Sat)</th><td>{money(rates.weekend)}</td></tr>
          <tr><th scope="row">Weekly</th><td>{money(rates.weekly)}</td></tr>
          </>}
          <tr><th scope="row">Monthly ({maxDays} days)</th><td>{money(rates.monthly)}</td></tr>
        </tbody></table>
      </div>
    );
  }
  return (
    <div className="estimate" aria-live="polite" aria-busy={loading || undefined}>
      {problem && <p className="alert alert--warn"><span className="alert__title">Check the times</span><span>{problem}</span></p>}
      <div className="estimate__dates">
        <div><span className="xs muted">Pickup</span><b>{shortDate(from)}</b><span className="small">{clock(tf)}</span></div>
        <div><span className="xs muted">Return</span><b>{shortDate(to)}</b><span className="small">{clock(tt)}</span></div>
        <div className="estimate__days"><b className="num">{q?.billable_days ?? ''}</b><span className="xs">{q ? (q.billable_days === 1 ? 'day' : 'days') : ''}</span></div>
      </div>
      {error && <p className="alert alert--warn"><span className="alert__title">We could not price these dates</span><span>Send the request and we will confirm the price.</span></p>}
      {q && q.problems.map((p) => <p key={p.code} className="alert alert--warn"><span>{p.message}</span></p>)}
      {!q && !error && <div className="skeleton sk-line" style={{ height: '8rem' }} aria-hidden="true" />}
      {q && (
        <>
          <table className="estimate__lines">
            <tbody>
              {q.lines.map((l, i) => { const d = describe(l, labels); return <tr key={i}><th scope="row">{d.k}{d.note && <small>{d.note}</small>}</th><td className="num">{money(l.amount_cents, { cents: true })}</td></tr>; })}
              {(coverageChosen ?? q.coverage.option === 3) && q.coverage.priced_in_offer && <tr><th scope="row">Protection Plan<small>By car and driver age</small></th><td>{q.coverage.price_note ?? 'Priced in your offer'}</td></tr>}
              <tr><th scope="row">HST ({hst})</th><td className="num">{money(q.hst_cents, { cents: true })}</td></tr>
            </tbody>
            <tfoot><tr><th scope="row">Estimated total<small>Due when you approve, sign and pay. Nothing now.</small></th><td className="num"><Tween cents={q.total_cents} /></td></tr></tfoot>
          </table>
          <dl className="estimate__after">
            <div><dt>Deposit before pickup</dt><dd className="num">{money(q.deposit_cents)} <small>{q.deposit_method === 'card_hold' ? 'card hold' : 'charged, then refunded'}</small></dd></div>
            <div><dt>Kilometres included</dt><dd className="num">{q.km_allowance_total.toLocaleString('en-CA')} km <small>then {money(q.overage_cents_per_km, { cents: true })} per km</small></dd></div>
          </dl>
        </>
      )}
    </div>
  );
}

export const daysLabel = (n: number) => plural(n, 'day');
