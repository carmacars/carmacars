'use client';
import { useEffect, useId, useRef, useState } from 'react';
import { publicRead } from '@/lib/browser-rpc';
import { motionOK } from '@/lib/motion';
import { money } from '@/lib/format';
import { YearMakeModel } from '@/features/vin/VinEntry';
import type { CarEdits } from '@/features/vin/entry';
import { cleanVin } from '@/features/vin/vin';
import { lookupVin } from '@/server/actions/apply';
import { DAYS, SHARE, estimate, rateFor, type CalcData } from './earnings';

// The earnings calculator (migration 0354, docs/changes/2026-11-06-owner-earnings-calculator.md): on List your car near
// the top, and compact at the start of the application. Every number is worked out here from the page's small JSON
// (public.owner_calc_data; the application reads it once from the database API, kept for the tab): moving a slider asks
// nothing of the server. The car by year, make and model (the lists of Add a car) or by its VIN (one look-up).

const KEY = 'cc_owner_calc';
const dollars = (cents: number) => money(Math.round(cents / 100) * 100);

/** A number that runs to its new value (never under reduced motion). */
function useRunning(target: number) {
  const [shown, setShown] = useState(target);
  const from = useRef(target);
  useEffect(() => {
    const start = from.current; from.current = target;
    if (start === target || !motionOK()) { setShown(target); return; }
    const t0 = performance.now(); let raf = 0;
    const step = (now: number) => { const k = 1 - Math.pow(1 - Math.min(1, (now - t0) / 450), 3); setShown(Math.round(start + (target - start) * k)); if (k < 1) raf = requestAnimationFrame(step); };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [target]);
  return shown;
}
function Running({ cents, className, testId }: { cents: number; className?: string; testId?: string }) {
  const v = useRunning(cents);
  return <b className={className} data-testid={testId} data-value={Math.round(cents / 100)} data-moving={v !== cents || undefined}>{dollars(v)}</b>;
}

export function EarningsCalculator({ data: given = null, compact = false }: { data?: CalcData | null; compact?: boolean }) {
  const uid = useId().replace(/[^\w-]/g, '');
  const [data, setData] = useState<CalcData | null>(given);
  const [car, setCar] = useState<CarEdits>({});
  const [by, setBy] = useState<'list' | 'vin'>('list');
  const [vin, setVin] = useState('');
  const [vinMsg, setVinMsg] = useState('');
  const [body, setBody] = useState<string | null>(null);
  const [days, setDays] = useState<number>(DAYS.start);
  const [share, setShare] = useState<number>(SHARE.start);
  const [insurance, setInsurance] = useState(false);

  // the application reads the numbers once (the database API with the anon key: no Worker work), kept for the tab
  useEffect(() => {
    if (given) return;
    let live = true;
    let kept: CalcData | null = null;
    try { const c = JSON.parse(sessionStorage.getItem(KEY) ?? 'null') as { at: number; v: CalcData } | null; if (c && Date.now() - c.at < 30 * 60_000) kept = c.v; } catch { /* none */ }
    void (kept ? Promise.resolve(kept) : publicRead<CalcData>('owner_calc_data', {})).then((v) => {
      if (!live || !v) return;
      setData(v);
      if (!kept) { try { sessionStorage.setItem(KEY, JSON.stringify({ at: Date.now(), v })); } catch { /* none */ } }
    }).catch(() => undefined);
    return () => { live = false; };
  }, [given]);

  const lookUp = async () => {
    const v = cleanVin(vin);
    if (v.length !== 17) { setVinMsg('A VIN has 17 letters and numbers.'); return; }
    setVinMsg('Looking up your VIN');
    const r = await lookupVin(v);
    if (!r.ok) { setVinMsg(r.message); return; }
    const d = r.data.decode as { year?: number | null; make?: string | null; model?: string | null; trim?: string | null; body_class?: string | null } | null;
    if (!d?.make) { setVinMsg('We could not look this VIN up. Choose the year, make and model instead.'); setBy('list'); return; }
    setCar({ year: String(d.year ?? ''), make: d.make ?? '', model: d.model ?? '', trim: d.trim ?? '' });
    setBody(d.body_class ?? null);
    setVinMsg(`Found it: ${[d.year, d.make, d.model, d.trim].filter(Boolean).join(' ')}.`);
  };

  const chosen = !!(car.make && car.model);
  const rate = data && chosen ? rateFor(data, { year: Number(car.year) || null, make: car.make, model: car.model, trim: car.trim ?? null, body }) : null;
  const fees = data?.fees ?? { insurance_cents: null, tracker_cents: null };
  const e = rate?.cents ? estimate({ rateCents: rate.cents, days, sharePct: share, fees }) : null;
  const low = rate?.cents ? estimate({ rateCents: rate.cents, days: DAYS.low, sharePct: share, fees }) : null;
  const fill = (v: number, min: number, max: number) => ({ ['--fill' as string]: `${((v - min) / (max - min)) * 100}%` });

  return (
    <section className={`ecalc${compact ? ' ecalc--compact' : ''}`} aria-labelledby={`${uid}-h`} data-testid="earnings-calculator">
      <div className="ecalc__in">
        <div className="ecalc__inputs stack">
          <h2 className={compact ? 'd4' : 'd2'} id={`${uid}-h`}>{compact ? 'What your car could earn' : 'What could your car earn?'}</h2>
          {!compact && <p className="muted">Pick your car, then the days it is rented and your share. The rate comes from cars like yours on CarmaCars today.</p>}
          <div className="seg ecalc__by" role="radiogroup" aria-label="Your car by">
            <label><input type="radio" name={`${uid}-by`} checked={by === 'list'} onChange={() => setBy('list')} /><span>Make and model</span></label>
            <label><input type="radio" name={`${uid}-by`} checked={by === 'vin'} onChange={() => setBy('vin')} data-testid="ecalc-by-vin" /><span>VIN</span></label>
          </div>
          {by === 'list'
            ? <YearMakeModel value={car} onChange={(c) => { setCar(c); setBody(null); }} prefix="ecalc" />
            : <div className="field">
                <label className="label" htmlFor={`${uid}-vin`}>VIN</label>
                <div className="row ecalc__vin">
                  <input className="input" id={`${uid}-vin`} value={vin} maxLength={20} autoComplete="off" spellCheck={false} onChange={(e) => setVin(e.target.value.toUpperCase())}
                    onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void lookUp(); } }} aria-describedby={`${uid}-vin-m`} data-testid="ecalc-vin" />
                  <button type="button" className="btn" onClick={() => void lookUp()}>Look up</button>
                </div>
                <p className="hint" id={`${uid}-vin-m`} aria-live="polite">{vinMsg || 'On the ownership permit or the insurance slip.'}</p>
              </div>}
          <div className="field ecalc__slider">
            <div className="ecalc__lab"><label className="label" htmlFor={`${uid}-days`}>Days rented a month</label><output htmlFor={`${uid}-days`} className="num" data-testid="ecalc-days-out">{days} days</output></div>
            <input className="range" type="range" id={`${uid}-days`} min={DAYS.min} max={DAYS.max} step={1} value={days} style={fill(days, DAYS.min, DAYS.max)}
              onChange={(e) => setDays(Number(e.target.value))} aria-valuetext={`${days} days`} data-testid="ecalc-days" />
          </div>
          <div className="field ecalc__slider">
            <div className="ecalc__lab"><label className="label" htmlFor={`${uid}-share`}>Your share <span className="opt">set in your agreement</span></label><output htmlFor={`${uid}-share`} className="num" data-testid="ecalc-share-out">{share}%</output></div>
            <input className="range" type="range" id={`${uid}-share`} min={SHARE.min} max={SHARE.max} step={5} value={share} style={fill(share, SHARE.min, SHARE.max)}
              onChange={(e) => setShare(Number(e.target.value))} aria-valuetext={`${share} percent`} data-testid="ecalc-share" />
          </div>
          <label className="switch ecalc__ins"><input type="checkbox" checked={insurance} onChange={(e) => setInsurance(e.target.checked)} data-testid="ecalc-insurance" /><span>Just cheaper insurance</span></label>
        </div>

        <div className="ecalc__out on-dark" aria-live="polite" data-testid="ecalc-result">
          {!data && <p className="muted">Loading the rates</p>}
          {data && !chosen && <><p className="ecalc__kicker">Your estimate</p><p className="ecalc__big ecalc__big--wait">Pick your car</p><p className="small ecalc__note">Year, make and model, or the VIN.</p></>}
          {data && chosen && !e && <><p className="ecalc__kicker">Your estimate</p><p className="ecalc__wait">We have no rate for this car yet. Apply and we quote it with you.</p></>}
          {e && rate && <>
            <p className="ecalc__kicker">{rate.label} · {dollars(rate.cents!)} a day{rate.source === 'model' ? `, the average of ${rate.n} like it` : rate.source === 'class' ? `, our ${rate.label.toLowerCase()} average` : ', our rate card'}</p>
            <p className="ecalc__big"><Running cents={e.net} testId="ecalc-month" /> <span>a month{e.beforeFees ? ', before fees' : ''}</span></p>
            <p className="ecalc__year"><Running cents={e.yearly} testId="ecalc-year" /> <span>a year</span></p>
            <dl className="ecalc__lines">
              <div><dt>Rental revenue</dt><dd className="num"><Running cents={e.revenue} /></dd></div>
              <div><dt>Your {share}% share</dt><dd className="num"><Running cents={e.share} /></dd></div>
              <div><dt>Insurance and tracker fees</dt><dd data-testid="ecalc-fees">{e.fees !== null ? <>−<Running cents={e.fees} /></> : 'quoted in your agreement'}</dd></div>
            </dl>
            {insurance && <div className="ecalc__ins-box" data-testid="ecalc-insurance-box">
              <p><b>On our fleet policy:</b> {fees.insurance_cents !== null ? <>{dollars(fees.insurance_cents)} a month for insurance{fees.tracker_cents !== null ? <>, plus {dollars(fees.tracker_cents)} for the tracker</> : null}.</> : 'the insurance fee is quoted in your agreement.'}</p>
              <p>Rented only {DAYS.low} days a month, your share is <b className="num" data-testid="ecalc-low">{dollars(low!.share)}</b>{low!.fees !== null ? <>, {low!.net >= 0 ? `${dollars(low!.net)} after fees` : `${dollars(-low!.net)} short of the fees`}</> : ' before fees'}.</p>
            </div>}
            <p className="small ecalc__note">An estimate, not a promise: what you earn depends on the bookings.</p>
          </>}
        </div>
      </div>
    </section>
  );
}
