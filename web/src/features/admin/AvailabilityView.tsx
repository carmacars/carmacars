'use client';
import Link from '@/components/Link';
import { DateInput } from '@/components/DateInput';
import { useRouter, useSearchParams } from 'next/navigation';
import { useId, useState, useTransition } from 'react';
import { money } from '@/lib/format';
import './availability.css';

// Release 44 (2792): which cars are free for the customer's dates, above the calendar of every portal that books cars
// (Admin, customer service, Sales; fleet reads it too). Pick the pickup and the return: every car is Available or Not
// available with the reason and the next free start for the same length; available cars first, filtered by class, seats
// and price a day. "Offer these dates" opens Send an offer with the car and the dates filled in. The database decides
// (app.fleet_availability: the same rule the booking checks); no renter is named here.

export interface AvailReason { kind: string; label: string; booking: string | null; from: string | null; to: string | null }
export interface AvailCar { id: string; label: string; fleet_number: string | null; plate: string | null; class: string | null; seats: number | null;
  daily_rate_cents: number | null; listed: boolean; available: boolean; reasons: AvailReason[]; next_free: string | null }
export interface AvailData { from: string; to: string; cars: AvailCar[] }

export const AVAIL_CLASSES = ['economy', 'standard', 'premium', 'suv', 'luxury', 'exotic'];
const fmt = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)) : '');
const BLOCKING = new Set(['booked', 'on_rent', 'placeholder', 'maintenance', 'blocked', 'out_of_service', 'exit']);

export function AvailabilityView({ data, from, to, base, canOffer, error }: { data: AvailData | null; from: string; to: string; base: '/admin' | '/staff'; canOffer: boolean; error?: string | null }) {
  const router = useRouter();
  const sp = useSearchParams();
  const id = useId();
  const [pending, start] = useTransition();
  const [f, setF] = useState({ af: from, at: to, ac: sp.get('ac') ?? '', as: sp.get('as') ?? '', ap: sp.get('ap') ?? '' });
  const [onlyFree, setOnlyFree] = useState(sp.get('free') === '1');
  const go = (next: typeof f) => {
    setF(next);
    if (!next.af || !next.at || next.at <= next.af) return;
    const q = new URLSearchParams(sp.toString());
    for (const [k, v] of Object.entries(next)) { if (v) q.set(k, v); else q.delete(k); }
    start(() => router.replace(`?${q.toString()}`, { scroll: false }));
  };
  const cars = (data?.cars ?? []).filter((c) => !onlyFree || c.available);
  const free = (data?.cars ?? []).filter((c) => c.available).length;
  return (
    <section className="av" aria-labelledby={`${id}-h`} data-testid="availability">
      <h2 className="av__h" id={`${id}-h`}>Which cars are free</h2>
      <div className="av__form">
        <label className="av__f"><span>Pickup</span><DateInput className="input" type="datetime-local" value={f.af} onChange={(e) => go({ ...f, af: e.target.value })} data-testid="av-from" /></label>
        <label className="av__f"><span>Return</span><DateInput className="input" type="datetime-local" value={f.at} min={f.af} onChange={(e) => go({ ...f, at: e.target.value })} data-testid="av-to" /></label>
        <label className="av__f"><span>Class</span><select className="select" value={f.ac} onChange={(e) => go({ ...f, ac: e.target.value })} data-testid="av-class">
          <option value="">Every class</option>{AVAIL_CLASSES.map((c) => <option key={c} value={c}>{c === 'suv' ? 'SUV' : c[0]!.toUpperCase() + c.slice(1)}</option>)}</select></label>
        <label className="av__f"><span>Seats at least</span><select className="select" value={f.as} onChange={(e) => go({ ...f, as: e.target.value })} data-testid="av-seats">
          <option value="">Any</option>{[4, 5, 7, 8].map((n) => <option key={n} value={n}>{n}</option>)}</select></label>
        <label className="av__f"><span>Price a day up to</span><select className="select" value={f.ap} onChange={(e) => go({ ...f, ap: e.target.value })} data-testid="av-price">
          <option value="">Any</option>{[60, 80, 100, 150, 200, 300].map((n) => <option key={n} value={n * 100}>{money(n * 100)}</option>)}</select></label>
        <label className="av__chk"><input type="checkbox" checked={onlyFree} onChange={(e) => setOnlyFree(e.target.checked)} data-testid="av-only-free" /> <span>Available only</span></label>
      </div>
      {f.at && f.af && f.at <= f.af && <p className="alert alert--warn small" role="alert"><span>The return must be after the pickup.</span></p>}
      {error && <p className="alert alert--error small" role="alert"><span>{error}</span></p>}
      <p className="small muted" role="status" aria-live="polite">{pending ? 'Checking the fleet...' : data ? `${free} of ${data.cars.length} cars available for these dates.` : ''}</p>
      <ul className="av__list" aria-busy={pending || undefined}>
        {cars.map((c) => {
          const holds = c.reasons.filter((r) => BLOCKING.has(r.kind));
          const notes = c.reasons.filter((r) => !BLOCKING.has(r.kind));
          return (
            <li key={c.id} className={`av__car ${c.available ? 'is-free' : 'is-taken'}`} data-testid="av-car" data-available={c.available ? 'yes' : 'no'}>
              <div className="av__main">
                <b className="av__badge">{c.available ? 'Available' : 'Not available'}</b>
                <span className="av__name"><b>{c.label}</b><span className="small muted">{[c.fleet_number, c.class === 'suv' ? 'SUV' : c.class, c.seats ? `${c.seats} seats` : null, c.daily_rate_cents ? `${money(c.daily_rate_cents)} a day` : null, c.listed ? null : 'not on the website'].filter(Boolean).join(' · ')}</span></span>
              </div>
              {holds.length > 0 && <ul className="av__why">{holds.map((r, i) => <li key={i}>{r.label}{r.booking ? ` ${r.booking}` : ''}{r.from ? `: ${fmt(r.from)}${r.to ? ` to ${fmt(r.to)}` : ', open ended'}` : ''}</li>)}</ul>}
              {notes.length > 0 && <ul className="av__why av__why--note">{notes.map((r, i) => <li key={i}>{r.label}{r.booking ? ` ${r.booking}` : ''}</li>)}</ul>}
              <p className="av__acts">
                {!c.available && <span className="small">{c.next_free ? <>Next free for the same length: <b>{fmt(c.next_free)}</b></> : 'Not free in the next 120 days'}</span>}
                {canOffer && c.available && <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}/offers/new?car=${c.id}&from=${encodeURIComponent(f.af)}&to=${encodeURIComponent(f.at)}`} data-testid="av-offer">Offer these dates</Link>}
              </p>
            </li>
          );
        })}
        {data && cars.length === 0 && <li className="av__none">No car matches. Change the dates or the filters.</li>}
      </ul>
    </section>
  );
}
