'use client';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Calendar } from '@/features/calendar/Calendar';
import { TimeSelect } from '@/features/calendar/TimeSelect';
import { blocksFromCalendar, clash, timeProblem, type Block } from '@/features/calendar/availability';
import { Estimate, useQuote, type LabelTokens } from '@/features/booking/Estimate';
import { browserRpc } from '@/lib/browser-rpc';
import { addDays, shortDate, torontoMinutesNow, torontoToday, validIso, validTime } from '@/lib/dates';
import { money } from '@/lib/format';
import { AddonPicker, useAddonOptions } from '@/features/addons/AddonPicker';
import { addonsPayload, type AddonChoice } from '@/features/addons/model';
import { SampleMatch } from '@/features/booking/SampleMatch';

export interface CarBookingProps {
  vehicleId: string; slug: string; name: string; deliveryFee: number; pickupFee: number;
  rates: { daily: number; weekend: number; weekly: number; monthly: number; multi?: number | null };
  maxDays: number; noticeMinutes: number; tokens: LabelTokens & { notice: string; turnaround: string; offerHours: string; hst: string; fullAge: string; youngA: string; youngB: string };
  allowsYoung: boolean;
  /** 0102: a sample (example) car offers the best real car free for the chosen dates */
  isSample?: boolean;
}

export const AGE_BANDS = { '26_plus': 'fullAge', '21_to_25': 'youngB', '18_to_20': 'youngA' } as const;
export type AgeBand = keyof typeof AGE_BANDS;

/** The car's unavailable stretches for the next six months (public_vehicle_calendar, anonymous). */
export function useBlocks(vehicleId: string | null) {
  const [got, setGot] = useState<{ id: string; blocks: Block[]; failed: boolean } | null>(null);
  useEffect(() => {
    if (!vehicleId) return;
    let live = true; const today = torontoToday();
    browserRpc<{ unavailable_from: string; unavailable_to: string }[]>('public_vehicle_calendar', { p_vehicle: vehicleId, p_from: today, p_to: addDays(today, 183) })
      .then((rows) => { if (live) setGot({ id: vehicleId, blocks: blocksFromCalendar(rows), failed: false }); })
      .catch(() => { if (live) setGot({ id: vehicleId, blocks: [], failed: true }); });
    return () => { live = false; };
  }, [vehicleId]);
  const mine = got && got.id === vehicleId ? got : null;
  return { blocks: useMemo(() => mine?.blocks ?? [], [mine]), failed: mine?.failed ?? false };
}

export function CarBooking(p: CarBookingProps) {
  const sp = useSearchParams();
  const today = torontoToday();
  const { blocks, failed } = useBlocks(p.vehicleId);
  const [from, setFrom] = useState(() => (validIso(sp.get('from')) && sp.get('from')! >= today ? sp.get('from')! : ''));
  const [to, setTo] = useState(() => (validIso(sp.get('to')) && from ? sp.get('to')! : ''));
  const [tf, setTf] = useState(validTime(sp.get('tf')) ? sp.get('tf')! : '10:00');
  const [tt, setTt] = useState(validTime(sp.get('tt')) ? sp.get('tt')! : '10:00');
  const [deliver, setDeliver] = useState(!!sp.get('deliver'));
  const [collect, setCollect] = useState(!!sp.get('collect'));
  const [age, setAge] = useState<AgeBand>(() => { const a = sp.get('age') as AgeBand | null; return a && a in AGE_BANDS ? a : '26_plus'; });
  const [clashNote, setClashNote] = useState('');
  // 0066: add-ons chosen here are priced live and carried to the request (?addons=code:count:hours)
  const [addons, setAddons] = useState<AddonChoice[]>(() => (sp.get('addons') ?? '').split(',').map((x) => x.split(':'))
    .filter(([c]) => /^[a-z0-9_]{2,40}$/.test(c ?? '')).map(([c, n, h]) => ({ code: c!, quantity: Math.min(Math.max(Number(n) || 1, 1), 20), hours: h ? Number(h) || null : null })));
  const checked = useRef(false);

  // dates carried from the fleet that this car cannot do are cleared, with a note
  useEffect(() => {
    if (checked.current || !blocks.length || !from || !to) return;
    checked.current = true;
    if (clash(from, tf, to, tt, blocks)) {
      // the calendar arrived after the page: the carried dates are taken, so clear them once
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setClashNote(`This car is booked for part of ${shortDate(from)} to ${shortDate(to)}. Pick other dates below, or look at similar cars.`);
      setFrom(''); setTo('');
    }
  }, [blocks, from, to, tf, tt]);

  const ready = !!(from && to);
  const options = useMemo(() => ({
    pickup_method: deliver ? 'delivered' : 'collected', return_method: collect ? 'picked_up' : 'returned',
    ...(deliver ? { pickup_location: { kind: 'delivery' } } : {}), ...(collect ? { return_location: { kind: 'delivery' } } : {}),
    drivers: [{ role: 'renter', age_band: age }], addons: addonsPayload(addons)
  }), [deliver, collect, age, addons]);
  const { options: addonOptions } = useAddonOptions(p.vehicleId, ready ? from : undefined, ready ? to : undefined, tf, tt);
  const { q, error, loading } = useQuote(ready ? { vehicleId: p.vehicleId, from, to, tf, tt, options } : null);
  const problem = ready ? timeProblem({ name: p.name, from, tf, to, tt, blocks, todayIso: today, nowMinutes: torontoMinutesNow(), noticeMinutes: p.noticeMinutes, noticeText: p.tokens.notice, turnaroundText: p.tokens.turnaround }) : '';

  const query = new URLSearchParams();
  if (ready) { query.set('from', from); query.set('to', to); query.set('tf', tf); query.set('tt', tt); }
  if (deliver) query.set('deliver', '1'); if (collect) query.set('collect', '1'); if (age !== '26_plus') query.set('age', age);
  const chosen = addons.filter((c) => c.quantity > 0);
  if (chosen.length) query.set('addons', chosen.map((c) => [c.code, c.quantity, c.hours ?? ''].join(':').replace(/:$/, '')).join(','));
  const href = `/book/${p.slug}${query.size ? '?' + query : ''}`;

  useEffect(() => {
    const s = query.toString();
    window.history.replaceState(null, '', `/cars/${p.slug}${s ? '?' + s : ''}${window.location.hash}`);
    window.dispatchEvent(new CustomEvent('cc:estimate', { detail: { href, total: q && ready ? q.total_cents : null, days: q?.billable_days ?? null, from, to } }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [href, q, ready]);

  return (
    <section className="car-sec" aria-labelledby="h-dates">
      <h2 className="d2" id="h-dates">Dates and price</h2>
      {clashNote && <p className="alert alert--warn"><span className="alert__title">Those dates are taken</span><span>{clashNote}</span></p>}
      {failed && <p className="alert alert--warn"><span className="alert__title">Live availability is not loading</span><span>You can still send a request and we will confirm.</span></p>}
      <div className="booking">
        <div className="booking__cal">
          <Calendar months={1} min={today} today={today} maxDays={p.maxDays} blocks={blocks} from={from} to={to}
            onChange={(v) => { setFrom(v.from); setTo(v.to); if (v.to) setClashNote(''); }} />
          <div className="field-row booking__times">
            <TimeSelect id="car-tf" label="Pickup time" value={tf} onChange={setTf} />
            <TimeSelect id="car-tt" label="Return time" value={tt} onChange={setTt} />
          </div>
          <div className="stack booking__opts">
            {p.deliveryFee > 0 && <label className="check"><input type="checkbox" name="deliver" checked={deliver} onChange={(e) => setDeliver(e.target.checked)} /><span>Deliver it to me <span className="muted num">+{money(p.deliveryFee)} plus distance</span></span></label>}
            {p.pickupFee > 0 && <label className="check"><input type="checkbox" name="collect" checked={collect} onChange={(e) => setCollect(e.target.checked)} /><span>Pick it up from me at the end <span className="muted num">+{money(p.pickupFee)} plus distance</span></span></label>}
            <div className="field">
              <label className="label" htmlFor="car-age">Driver’s age at pickup</label>
              <select className="select" id="car-age" value={age} onChange={(e) => setAge(e.target.value as AgeBand)}>
                <option value="26_plus">{p.tokens.fullAge} or older</option>
                <option value="21_to_25">{p.tokens.youngB}</option>
                {p.allowsYoung && <option value="18_to_20">{p.tokens.youngA}</option>}
              </select>
            </div>
            {addonOptions.length > 0 && (
              <details className="booking__addons" open={addons.length > 0} data-testid="car-addons">
                <summary className="label">Add-ons <span className="opt">optional</span>{addons.length ? <span className="muted"> ({addons.length} chosen)</span> : null}</summary>
                <AddonPicker idPrefix="car" compact options={addonOptions} value={addons} onChange={setAddons} />
              </details>
            )}
            <p className="small muted">Pickup and return any time, day or night, with at least {p.tokens.notice}’ notice. You choose the place in your request.</p>
          </div>
        </div>
        <div className="booking__est">
          <h3 className="d4">Your estimate</h3>
          {p.isSample && ready && <SampleMatch vehicleId={p.vehicleId} name={p.name} from={from} to={to} tf={tf} tt={tt}
            href={(slug) => `/book/${slug}?${new URLSearchParams({ from, to, tf, tt }).toString()}`} />}
          <Estimate q={q} error={error} loading={loading} from={ready ? from : ''} to={ready ? to : ''} tf={tf} tt={tt} rates={p.rates} hst={p.tokens.hst} maxDays={p.maxDays} labels={p.tokens} problem={problem} />
          <Link className="btn btn--primary btn--lg btn--block" href={href} data-book><span>Request to book</span></Link>
          <p className="small muted booking__assure"><b>No payment now.</b> We confirm the car and send the final price as an offer, open for {p.tokens.offerHours} hours. The car is booked only when you approve, sign and pay. If someone else pays for it first, we offer another car or other dates.</p>
        </div>
      </div>
    </section>
  );
}

// The sticky Request to book bar: appears once the car header has scrolled away, hides while the
// estimate's own button is on screen; carries the total from the estimate.
export function BookBar({ name, daily, slug }: { name: string; daily: number; slug: string }) {
  const [state, setState] = useState<{ href: string; total: number | null; days: number | null; from: string; to: string }>({ href: `/book/${slug}`, total: null, days: null, from: '', to: '' });
  const [on, setOn] = useState(false);
  const bar = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const h = (e: Event) => setState((e as CustomEvent).detail);
    window.addEventListener('cc:estimate', h);
    return () => window.removeEventListener('cc:estimate', h);
  }, []);
  useEffect(() => {
    const top = document.querySelector('.car-top');
    if (!top || !('IntersectionObserver' in window)) return;
    let past = false; let ctaIn = false; let raf = 0; let tries = 0;
    const io = new IntersectionObserver((es) => {
      es.forEach((e) => { if (e.target === top) past = !e.isIntersecting && e.boundingClientRect.top < 0; else ctaIn = e.isIntersecting; });
      setOn(past && !ctaIn);
    }, { threshold: 0 });
    io.observe(top);
    // the booking panel renders in the browser after this bar: watch its button once it exists
    const findCta = () => { const cta = document.querySelector('.booking__est [data-book]'); if (cta) io.observe(cta); else if (tries++ < 600) raf = requestAnimationFrame(findCta); };
    findCta();
    return () => { cancelAnimationFrame(raf); io.disconnect(); document.documentElement.style.setProperty('--bar-h', '0px'); };
  }, []);
  useEffect(() => { document.documentElement.style.setProperty('--bar-h', on && bar.current ? bar.current.offsetHeight + 'px' : '0px'); }, [on]);
  const ready = state.total !== null && state.days !== null && state.from && state.to;
  return (
    <div className={`bookbar${on ? ' is-on' : ''}`} role="region" aria-label="Request to book" ref={bar} inert={!on}>
      <div className="wrap bookbar__in">
        <div className="bookbar__car"><b>{name}</b></div>
        <div className="bookbar__price">
          <b className="num">{ready ? money(state.total!, { cents: true }) : `From ${money(daily)}`}</b>
          <span className="xs muted">{ready ? `${state.days} ${state.days === 1 ? 'day' : 'days'}, ${shortDate(state.from).split(', ')[1]} to ${shortDate(state.to).split(', ')[1]}, with HST` : 'a day. Pick dates for a total'}</span>
        </div>
        <a className="btn btn--quiet btn--sm bookbar__dates" href="#dates">Change dates</a>
        <Link className="btn btn--primary" href={state.href}>Request to book</Link>
      </div>
    </div>
  );
}
