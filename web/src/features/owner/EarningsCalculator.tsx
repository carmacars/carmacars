'use client';
import { useEffect, useId, useRef, useState } from 'react';
import { publicRead } from '@/lib/browser-rpc';
import { motionOK } from '@/lib/motion';
import { money } from '@/lib/format';
import { YearMakeModel } from '@/features/vin/VinEntry';
import { VinScan } from '@/features/vin/VinScan';
import type { CarEdits } from '@/features/vin/entry';
import { cleanVin } from '@/features/vin/vin';
import { lookupVin } from '@/server/actions/apply';
import { DAYS, SHARE, rateFor, seasonal, startDays, type CalcData } from './earnings';
import { applyHref } from './apply-schema';

// The earnings calculator (migration 0354, docs/changes/2026-11-06-owner-earnings-calculator.md): on List your car near
// the top, and compact at the start of the application. Every number is worked out here from the page's small JSON
// (public.owner_calc_data; the application reads it once from the database API, kept for the tab): moving a slider asks
// nothing of the server. The car by year, make and model (the lists of Add a car) or by its VIN (one look-up).
// r48 ops (3291, the owner, Nov 20): the numbers were too optimistic. Now conservative and seasonal: the days are those of
// an average month and start at 12 (Program settings), each rented day earns the listed rate less the typical discount,
// a year is its twelve months added up over the GTA season (summer busiest, winter slow, the shoulder months slowest), and
// the result says plainly that it is a rough estimate, not a promise.

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
  const [days, setDays] = useState<number>(() => startDays(given));
  const touched = useRef(false);
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
      if (!touched.current) setDays(startDays(v));
      if (!kept) { try { sessionStorage.setItem(KEY, JSON.stringify({ at: Date.now(), v })); } catch { /* none */ } }
    }).catch(() => undefined);
    return () => { live = false; };
  }, [given]);

  const lookUp = async (typed?: string) => {
    const v = cleanVin(typed ?? vin);
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
  const e = rate?.cents ? seasonal({ rateCents: rate.cents, days, sharePct: share, fees, season: data?.season, discountPct: data?.discount_pct }) : null;
  const peak = e ? Math.max(1, ...e.months.map((m) => m.days)) : 1;
  const fill = (v: number, min: number, max: number) => ({ ['--fill' as string]: `${((v - min) / (max - min)) * 100}%` });

  return (
    <section className={`ecalc${compact ? ' ecalc--compact' : ''}`} aria-labelledby={`${uid}-h`} data-testid="earnings-calculator">
      <div className="ecalc__in">
        <div className="ecalc__inputs stack">
          <h2 className={compact ? 'd4' : 'd2'} id={`${uid}-h`}>{compact ? 'What your car could earn' : 'What could your car earn?'}</h2>
          {!compact && <p className="muted">Pick your car, then the days it is rented in an average month and your share. The rate comes from cars like yours on CarmaCars today, and the year follows Toronto&apos;s rental season.</p>}
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
                {/* release 28: the VIN from the door-jamb barcode or a photo, then looked up at once */}
                <VinScan prefix="ecalc" compact onVin={(v) => { setVin(v); void lookUp(v); }} />
                <p className="hint" id={`${uid}-vin-m`} aria-live="polite">{vinMsg || 'On the ownership permit or the insurance slip.'}</p>
              </div>}
          <div className="field ecalc__slider">
            <div className="ecalc__lab"><label className="label" htmlFor={`${uid}-days`}>Days rented in an average month</label><output htmlFor={`${uid}-days`} className="num" data-testid="ecalc-days-out">{days} days</output></div>
            <input className="range" type="range" id={`${uid}-days`} min={DAYS.min} max={DAYS.max} step={1} value={days} style={fill(days, DAYS.min, DAYS.max)}
              onChange={(e) => { touched.current = true; setDays(Number(e.target.value)); }} aria-valuetext={`${days} days`} aria-describedby={`${uid}-days-h`} data-testid="ecalc-days" />
            <p className="hint" id={`${uid}-days-h`}>Summer months run above this, winter under it, and spring and fall are the slowest. A new car takes a few months to fill.</p>
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
          {data && chosen && !e && <><p className="ecalc__kicker">Your estimate</p><p className="ecalc__wait">We have no rate for this car yet. Apply and we quote it with you.</p>
            {!compact && <p><a className="btn btn--primary" href={applyHref({ year: Number(car.year) || undefined, make: car.make, model: car.model, vin: by === 'vin' ? cleanVin(vin) : undefined })} data-testid="ecalc-apply">Apply with this car</a></p>}</>}
          {e && rate && <>
            <p className="ecalc__kicker">{rate.label} · {dollars(rate.cents!)} a day listed{rate.source === 'model' ? `, the average of ${rate.n} like it` : rate.source === 'class' ? `, our ${rate.label.toLowerCase()} average` : ', our rate card'}{e.discountPct > 0 ? <>; worked at {dollars(e.dayCents)} after weekly rates and offers</> : null}</p>
            <p className="ecalc__big"><Running cents={e.average} testId="ecalc-monthly" /> <span>a month on average{e.beforeFees ? ', before fees' : ''}</span></p>
            <p className="ecalc__year"><Running cents={e.yearly} testId="ecalc-yearly" /> <span>over a year</span></p>
            <p className="ecalc__range" data-testid="ecalc-range">From <b className="num">{dollars(e.slow.net)}</b> in a slow month ({e.slow.name}) to <b className="num">{dollars(e.busy.net)}</b> in a busy one ({e.busy.name}).</p>
            {/* the year by month: the GTA season. The bars are for the eye; the sentence above and the list under them say the same */}
            <div className="ecalc__season" data-testid="ecalc-season">
              <p className="ecalc__season-h">Rented days by month</p>
              <ol className="ecalc__bars" aria-label="Rented days by month">{e.months.map((m) => (
                <li key={m.key} className={m.key === e.busy.key ? 'is-busy' : m.key === e.slow.key ? 'is-slow' : undefined} style={{ ['--h' as string]: `${Math.round((m.days / peak) * 100)}%` }}>
                  <span className="ecalc__bar" aria-hidden="true" /><span className="ecalc__bar-n num">{m.days}</span><abbr title={m.name}>{m.name.slice(0, 1)}</abbr><span className="vh">: {m.days} days, {dollars(m.net)}</span></li>))}</ol>
            </div>
            <dl className="ecalc__lines">
              <div><dt>Rental revenue, an average month</dt><dd className="num"><Running cents={e.revenueAverage} /></dd></div>
              <div><dt>Your {share}% share</dt><dd className="num"><Running cents={e.shareAverage} /></dd></div>
              <div><dt>Insurance and tracker fees, every month</dt><dd data-testid="ecalc-fees">{e.fees !== null ? <>−<Running cents={e.fees} /></> : 'quoted in your agreement'}</dd></div>
            </dl>
            {insurance && <div className="ecalc__ins-box" data-testid="ecalc-insurance-box">
              <p><b>On our fleet policy:</b> {fees.insurance_cents !== null ? <>{dollars(fees.insurance_cents)} a month for insurance{fees.tracker_cents !== null ? <>, plus {dollars(fees.tracker_cents)} for the tracker</> : null}.</> : 'the insurance fee is quoted in your agreement.'}</p>
              <p>In your slowest month ({e.slow.name}, {e.slow.days} days rented) your share is <b className="num" data-testid="ecalc-low">{dollars(e.slow.share)}</b>{e.fees !== null ? <>, {e.slow.net >= 0 ? `${dollars(e.slow.net)} after fees` : `${dollars(-e.slow.net)} short of the fees`}</> : ' before fees'}.</p>
            </div>}
            {e.short > 0 && <p className="ecalc__warn" data-testid="ecalc-short">At these numbers your share does not cover the monthly fees in {e.short} of 12 months.</p>}
            <div className="ecalc__disclaimer" role="note" data-testid="ecalc-disclaimer">
              <b>A rough estimate, not a promise.</b>
              <span>We lean low on purpose. What you really earn depends on the bookings your car gets, the season, its price, its condition and how many days it is available. Some months a car earns little or nothing, and the fees are due every month, rented or not.</span>
            </div>
            {/* 0344: the application starts with this car and estimate, and its lead carries them */}
            {!compact && <p><a className="btn btn--primary" href={applyHref({ year: Number(car.year) || undefined, make: car.make, model: car.model, vin: by === 'vin' ? cleanVin(vin) : undefined, estimate_cents: e.average > 0 ? e.average : undefined })} data-testid="ecalc-apply">Apply with this car</a></p>}
          </>}
        </div>
      </div>
    </section>
  );
}
