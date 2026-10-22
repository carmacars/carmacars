'use client';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Calendar } from '@/features/calendar/Calendar';
import { TimeSelect } from '@/features/calendar/TimeSelect';
import { timeProblem } from '@/features/calendar/availability';
import { useBlocks } from '@/features/car/CarBooking';
import { AddressInput } from '@/features/forms/AddressInput';
import { FAKE_TOKEN, Turnstile, freshTurnstileToken } from '@/features/forms/Turnstile';
import { publicEnv } from '@/lib/public-env';
import { clock, longDate, MONTHS, torontoMinutesNow, torontoToday, validIso, validTime } from '@/lib/dates';
import { money } from '@/lib/format';
import { photoUrl } from '@/lib/photo';
import { loadRequestDraft, requestAccount, saveRequestDraft, submitBookingRequest } from '@/server/actions/booking';
import { formatPhone } from '@/features/auth/phone';
import { AddonPicker, useAddonOptions } from '@/features/addons/AddonPicker';
import { addonsPayload } from '@/features/addons/model';
import { useBookingGame } from '@/features/games/BookingGame';
import { Estimate, useQuote, type LabelTokens } from './Estimate';
import { CaptureNote, SavedAsYouType, useCapture } from '@/features/capture/useCapture';
import { ageOn, checkRequest, dobIso, emptyRequest, migrateExtras, stepOfKey, type RequestData, type RequestRules } from './schema';

// Request to book: five steps (0066: add-ons have their own), autosaved to form_drafts (and this device) and resumable, one schema
// checked here and again on the server, Turnstile, and one call to submit_booking_request with an
// idempotency key. No card and no payment at this step.
export interface WizardCar { slug: string; vehicleId: string; name: string; year: number | null; trim: string | null; daily: number; weekend: number; weekly: number; monthly: number;
  /** 0093: the 3+ day rate; insurance included; no credit card needed */
  multi?: number | null; insuranceIncluded?: boolean; noCreditCard?: boolean; delivery: number; pickup: number; ownerLocation: boolean; allowsYoung: boolean; cover: { path: string; alt: string } | null }
export interface WizardProps {
  cars: WizardCar[]; initialSlug: string | null; rules: RequestRules; airports: { code: string; name: string; surcharge_cents: number | null }[];
  tokens: LabelTokens & Record<'notice' | 'turnaround' | 'offerHours' | 'hst' | 'minAge' | 'licence' | 'addDrvPct' | 'cEarly' | 'c2' | 'nonRef' | 'winter' | 'winterCap' | 'baby' | 'babyCap' | 'maxDays' | 'brand', string>;
  marketingText: string; agreeLine: string; ourAddress: string | null;
}

const KEY = 'cc.request.v2';
const STEPS = [['Dates', ' and delivery'], ['Driver', ' details'], ['Licence', ' and coverage'], ['Add-ons', ' for your trip'], ['Review', ' and send']] as const;
const LAST = STEPS.length;
/** add-ons carried from the car page: ?addons=baby_seat:2,chauffeur:1:4 */
const addonsFromQuery = (q: string | null) => (q ?? '').split(',').map((x) => x.split(':')).filter(([c]) => /^[a-z0-9_]{2,40}$/.test(c ?? ''))
  .map(([c, n, h]) => ({ code: c!, quantity: Math.min(Math.max(Number(n) || 1, 1), 20), hours: h ? Number(h) || null : null })).slice(0, 30);
type Store = { data: RequestData; step: number; token: string | null; draftId: string | null; key: string; at: number };
const readStore = (): Store | null => { try { return JSON.parse(localStorage.getItem(KEY) ?? 'null') as Store | null; } catch { return null; } };
const writeStore = (s: Store) => { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch { /* private mode */ } };
const newKey = () => `web-${crypto.randomUUID()}`;
const band = (age: number | null) => (age === null ? '26_plus' : age < 21 ? '18_to_20' : age < 26 ? '21_to_25' : '26_plus');

export function RequestWizard(p: WizardProps) {
  const router = useRouter();
  const sp = useSearchParams();
  const today = torontoToday();
  const [d, setD] = useState<RequestData>(() => ({ ...emptyRequest(), car: p.initialSlug ?? '' }));
  const [step, setStep] = useState(1);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [restored, setRestored] = useState(false);
  const [saved, setSaved] = useState(false);
  const [sending, setSending] = useState(false);
  const [failure, setFailure] = useState('');
  const meta = useRef<{ token: string | null; draftId: string | null; key: string }>({ token: null, draftId: null, key: '' });
  const ready = useRef(false);
  const form = useRef<HTMLFormElement>(null);
  // contact capture (0090): the name, email and phone are saved as each becomes valid, with this draft
  const cap = useCapture('booking_request', () => ({ ref: meta.current.draftId, draftToken: meta.current.token }));
  const { relink } = cap;
  // signed in (0091): the account's verified phone and email fill the form; an account made by phone may leave the email
  const [account, setAccount] = useState<{ signedIn: boolean; email: string | null; phone: string | null } | null>(null);
  useEffect(() => {
    requestAccount().then((r) => { if (r.ok) setAccount(r.data); }).catch(() => undefined);
  }, []);
  useEffect(() => {
    if (!account?.signedIn || !ready.current) return;
    setD((x) => ({ ...x, phone: x.phone || (account.phone ? formatPhone(account.phone) : ''), email: x.email || (account.email ?? '') }));
  }, [account, step]);
  const emailOptional = !!account?.signedIn && !account.email;

  // start: the link's car and dates win over a saved draft for a different car or dates
  useEffect(() => {
    const s = readStore();
    const linkCar = p.initialSlug; const linkFrom = sp.get('from');
    const fresh = (linkCar && s && s.data.car !== linkCar) || (validIso(linkFrom) && s && linkFrom !== s.data.from);
    meta.current = { token: s?.token ?? null, draftId: s?.draftId ?? null, key: s?.key || newKey() };
    const fromLink: Partial<RequestData> = {};
    if (linkCar) fromLink.car = linkCar;
    if (validIso(linkFrom) && linkFrom >= today && validIso(sp.get('to'))) { fromLink.from = linkFrom; fromLink.to = sp.get('to')!; }
    if (validTime(sp.get('tf'))) fromLink.tf = sp.get('tf')!;
    if (validTime(sp.get('tt'))) fromLink.tt = sp.get('tt')!;
    if (sp.get('deliver')) fromLink.pickupAt = sp.get('deliver') === 'airport' ? 'airport' : 'delivery';
    if (sp.get('collect')) fromLink.returnAt = sp.get('collect') === 'airport' ? 'airport' : 'delivery';
    if (sp.get('addons')) fromLink.addons = addonsFromQuery(sp.get('addons'));
    // a promo code from the link (?promo=), or the code a discount game gave on this device (0066)
    const linkPromo = sp.get('promo');
    if (linkPromo && /^[A-Za-z0-9-]{3,40}$/.test(linkPromo)) fromLink.promo = linkPromo.toUpperCase();
    else { try { const g = JSON.parse(localStorage.getItem('cc_game') ?? 'null') as { code?: string } | null; if (g?.code && /^[A-Z0-9-]{3,40}$/.test(g.code)) fromLink.promo = g.code; } catch { /* private mode */ } }
    const apply = (base: RequestData, st: number, was: boolean) => {
      const next = migrateExtras({ ...base, ...fromLink });
      if (next.from && next.from < today) { next.from = ''; next.to = ''; }
      setD(next); setStep(fresh ? 1 : Math.min(Math.max(st, 1), LAST)); setRestored(was && !fresh); ready.current = true;
    };
    if (s && !fresh) apply({ ...emptyRequest(), ...s.data }, s.step, true);
    else {
      // another device: a signed-in person's draft, or the token kept here
      loadRequestDraft(meta.current.token).then((r) => {
        if (r.ok && r.data && !fresh) { meta.current.draftId = r.data.draftId; apply({ ...emptyRequest(), ...r.data.data }, r.data.step, true); }
        else apply({ ...emptyRequest(), car: p.initialSlug ?? '' }, 1, false);
      }).catch(() => apply(emptyRequest(), 1, false));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // autosave: this device at once, the server after a pause
  useEffect(() => {
    if (!ready.current) return;
    writeStore({ data: d, step, ...meta.current, at: Date.now() });
    const t = setTimeout(() => {
      saveRequestDraft({ data: d, step, token: meta.current.token }).then((r) => {
        if (r.ok) { meta.current.token = r.data.token; meta.current.draftId = r.data.draftId; writeStore({ data: d, step, ...meta.current, at: Date.now() }); setSaved(true); relink(); }
      }).catch(() => setSaved(true));
    }, 800);
    return () => clearTimeout(t);
  }, [d, step, relink]);

  const car = p.cars.find((c) => c.slug === d.car) ?? null;
  const { blocks } = useBlocks(car?.vehicleId ?? null);
  const set = <K extends keyof RequestData>(k: K, v: RequestData[K]) => { setD((x) => ({ ...x, [k]: v })); setErrors((e) => { const n = { ...e }; delete n[k as string]; if (k === 'from' || k === 'to') delete n.dates; if (String(k).startsWith('dob')) delete n.dob; return n; }); };

  const age = ageOn(d.dobY, d.dobM, d.dobD, d.from || today);
  const far = (k: string) => k === 'delivery' || k === 'airport';
  const options = useMemo(() => ({
    booking_type: d.bookingType, coverage_option: d.coverage ? Number(d.coverage) : undefined,
    pickup_method: far(d.pickupAt) ? 'delivered' : 'collected', return_method: far(d.returnAt) ? 'picked_up' : 'returned',
    pickup_location: d.pickupAt === 'airport' ? { kind: 'airport', airport_code: d.pickupAirport } : d.pickupAt === 'delivery' ? { kind: 'delivery' } : undefined,
    return_location: d.returnAt === 'airport' ? { kind: 'airport', airport_code: d.returnAirport } : d.returnAt === 'delivery' ? { kind: 'delivery' } : undefined,
    drivers: [{ role: 'renter', age_band: band(age) }, ...d.drivers.map((x) => ({ role: 'additional', age_band: band(ageOn(x.dobY, x.dobM, x.dobD, d.from || today)) }))],
    addons: addonsPayload(d.addons),
    promo_code: /^[A-Za-z0-9-]{3,40}$/.test(d.promo) ? d.promo.toUpperCase() : undefined
  }), [d.bookingType, d.coverage, d.pickupAt, d.returnAt, d.pickupAirport, d.returnAirport, age, d.drivers, d.from, d.addons, today, d.promo]);
  const haveDates = !!(car && d.from && d.to);
  const { options: addonOptions } = useAddonOptions(car?.vehicleId ?? null, haveDates ? d.from : undefined, haveDates ? d.to : undefined, d.tf, d.tt);
  const { q, error: qErr, loading } = useQuote(haveDates ? { vehicleId: car!.vehicleId, from: d.from, to: d.to, tf: d.tf, tt: d.tt, options } : null);
  // discount games (0081): the offer on the add-ons and review steps; a won code goes in the promo code box
  const promoText = !d.promo ? '' : !q ? 'The price beside the form is being updated.' : q.promo?.applied
    ? `Code ${q.promo.code} applied: ${money(-(q.lines.find((l) => l.charge_type === 'promo_discount')?.amount_cents ?? 0), { cents: true })} off the rental charge.`
    : q.promo?.problem ? `${q.promo.problem}. The code stays yours until it expires.` : '';
  const game = useBookingGame({ step, steps: [4, 5], first: d.first, email: d.email, phone: d.phone, promoApplied: !!(d.promo && q?.promo?.applied), applied: promoText,
    onCode: (code) => set('promo', code) });
  const problem = haveDates ? timeProblem({ name: car!.name, from: d.from, tf: d.tf, to: d.to, tt: d.tt, blocks, todayIso: today, nowMinutes: torontoMinutesNow(), noticeMinutes: p.rules.noticeMinutes, noticeText: p.tokens.notice, turnaroundText: p.tokens.turnaround }) : '';

  function validate(n: number): boolean {
    const all = checkRequest(d, p.rules, { todayIso: today, nowMinutes: torontoMinutesNow(), knownCar: !!car, emailOptional, insuranceIncluded: !!car?.insuranceIncluded });
    if (n === 1 && problem && !all.dates) all.dates = problem;
    const mine = Object.fromEntries(Object.entries(all).filter(([k]) => stepOfKey(k) === n));
    setErrors(mine);
    if (Object.keys(mine).length) {
      requestAnimationFrame(() => {
        const el = form.current?.querySelector<HTMLElement>('.has-error input, .has-error select, .has-error textarea, .has-error button');
        el?.focus(); el?.closest('.field')?.scrollIntoView({ block: 'center' });
      });
      return false;
    }
    return true;
  }
  function show(n: number) {
    // the step that appears comes in from the side it is on (src/styles/motion.css)
    form.current?.setAttribute('data-dir', n < step ? 'back' : 'next');
    setStep(n);
    requestAnimationFrame(() => {
      const h = form.current?.querySelector<HTMLElement>(`[data-step="${n}"] h2`); h?.focus({ preventScroll: true });
      form.current?.closest('.req')?.scrollIntoView({ block: 'start', behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
    });
  }
  async function send(e: React.FormEvent) {
    e.preventDefault(); setFailure('');
    for (let n = 1; n <= LAST; n++) if (!validate(n)) { if (n !== step) show(n); setTimeout(() => validate(n), 0); return; }
    setSending(true);
    // a fresh security-check token just before sending (single use, 5 minutes: a long form or a second try outlives one)
    const token = form.current ? await freshTurnstileToken(form.current) : (publicEnv.turnstileMode !== 'cloudflare' ? FAKE_TOKEN : null);
    if (!token) { setSending(false); setFailure('Our security check did not load in this browser (a content blocker or a privacy setting such as iCloud Private Relay can block it). Turn it off for carmacars.ca or try another browser; your request is kept.'); return; }
    // a request sent before the autosave's pause still closes its draft: the draft is saved first when it has no id yet
    if (!meta.current.draftId) {
      const sv = await saveRequestDraft({ data: d, step, token: meta.current.token }).catch(() => null);
      if (sv?.ok) { meta.current.token = sv.data.token; meta.current.draftId = sv.data.draftId; }
    }
    let r = await submitBookingRequest({ data: d, requestKey: meta.current.key, token, draftId: meta.current.draftId }).catch(() => null);
    if (r && !r.ok && r.code === 'turnstile' && form.current) {
      const again = await freshTurnstileToken(form.current);
      if (again) r = await submitBookingRequest({ data: d, requestKey: meta.current.key, token: again, draftId: meta.current.draftId }).catch(() => null);
    }
    setSending(false);
    if (!r) { setFailure('We could not reach the server. Check your connection and send again.'); return; }
    if (!r.ok) {
      if (r.fieldErrors) { const first = Math.min(...Object.keys(r.fieldErrors).map(stepOfKey)); setErrors(Object.fromEntries(Object.entries(r.fieldErrors).filter(([k]) => stepOfKey(k) === first))); show(first); }
      setFailure(r.message); return;
    }
    try {
      sessionStorage.setItem('cc.lastRequest', JSON.stringify({ number: r.data.bookingNumber, car: car ? [car.year, car.name].filter(Boolean).join(' ') : '', from: d.from, to: d.to, tf: d.tf, tt: d.tt, deliver: far(d.pickupAt), total: q?.total_cents ?? r.data.totalCents, deposit: q?.deposit_cents ?? r.data.depositCents, days: q?.billable_days ?? null, email: d.email, first: d.first, coverage: d.coverage }));
      localStorage.removeItem(KEY);
    } catch { /* ignore */ }
    router.push(`/book/sent/${encodeURIComponent(r.data.bookingNumber)}`);
  }

  const err = (k: string) => errors[k];
  const fieldCls = (k: string, extra = '') => `field${err(k) ? ' has-error' : ''}${extra ? ' ' + extra : ''}`;
  const aria = (k: string, id: string, hint = false) => ({ 'aria-invalid': err(k) ? true : undefined, 'aria-describedby': [hint ? `${id}-hint` : '', err(k) ? `${id}-err` : ''].filter(Boolean).join(' ') || undefined });
  const errEl = (k: string, id: string) => <p className="error" role="alert" id={`${id}-err`}>{err(k) ?? ''}</p>;
  const fee = car ? money(car.delivery) : '';
  const airportName = (code: string) => p.airports.find((a) => a.code === code)?.name ?? '';
  const placeText = (k: string, addr: string, ap: string, verb: string) => (k === 'delivery' ? `${verb} ${addr || 'your address'}` : k === 'airport' ? `at ${airportName(ap)}` : k === 'owner' ? 'at the car owner’s location' : 'at our location');
  const covText: Record<string, string> = { '1': 'Option 1: OPCF 27 on my own auto policy', '2': 'Option 2: my credit card rental coverage', '3': `Option 3: buy the ${p.tokens.brand} Protection Plan, priced in your offer` };

  const renderPlace = (kind: 'pickup' | 'return') => {
    const k = kind === 'pickup' ? 'pickupAt' : 'returnAt';
    const val = d[k];
    const opt = (v: typeof val, title: React.ReactNode, body: React.ReactNode, hidden = false) => hidden ? null : (
      <label className="option"><input type="radio" name={k} value={v} checked={val === v} onChange={() => set(k, v)} /><span className="option__title">{title}</span><span className="option__body">{body}</span></label>
    );
    const addrKey = kind === 'pickup' ? 'pickupAddress' : 'returnAddress'; const apKey = kind === 'pickup' ? 'pickupAirport' : 'returnAirport';
    const id = kind === 'pickup' ? 'rq-addr1' : 'rq-addr2'; const apId = kind === 'pickup' ? 'rq-airport1' : 'rq-airport2';
    return (
      <fieldset className="stack"><legend className="label">{kind === 'pickup' ? 'Where do you want to get the car?' : 'Where will you return it?'}</legend>
        {opt('ours', <>At our location <span className="muted">No charge</span></>, p.ourAddress ?? 'We send the address with your offer.')}
        {opt('owner', <>At the car owner’s location <span className="muted">No charge</span></>, 'Offered for this car. We send the address with your offer.', !car?.ownerLocation)}
        {opt('delivery', <>{kind === 'pickup' ? 'Deliver it to an address' : 'Pick it up from an address'} <span className="muted num">+{fee || 'the car’s fee'} plus distance</span></>, kind === 'pickup' ? 'Home, office or hotel, anywhere. We hand it over in person.' : 'Leave it with our driver instead of bringing it back.')}
        {val === 'delivery' && (
          <div className={fieldCls(addrKey)}>
            <label className="label" htmlFor={id}>{kind === 'pickup' ? 'Delivery address' : 'Pickup address'}{kind === 'return' && d.pickupAt === 'delivery' && <> <span className="opt">optional</span></>}</label>
            <AddressInput id={id} name={addrKey} value={d[addrKey]} onChange={(v) => set(addrKey, v)} invalid={!!err(addrKey)} describedBy={aria(addrKey, id, true)['aria-describedby']} />
            <p className="hint" id={`${id}-hint`}>{kind === 'return' && d.pickupAt === 'delivery' ? 'Leave empty if it is the same as the delivery address.' : 'Start typing and choose your address.'}</p>
            {errEl(addrKey, id)}
          </div>
        )}
        {opt('airport', <>At the airport <span className="muted num">+{fee || 'the car’s fee'} plus distance</span></>, `${p.airports.map((a) => a.name).join(' and ')}. An airport surcharge may apply.`)}
        {val === 'airport' && (
          <div className={fieldCls(apKey)}>
            <label className="label" htmlFor={apId}>Airport</label>
            <select className="select" id={apId} value={d[apKey]} onChange={(e) => set(apKey, e.target.value)} {...aria(apKey, apId)}>
              <option value="">Choose an airport</option>{p.airports.map((a) => <option key={a.code} value={a.code}>{a.name}</option>)}
            </select>
            <p className="hint">Add your flight number in the notes on step 3.</p>{errEl(apKey, apId)}
          </div>
        )}
      </fieldset>
    );
  };

  const renderDob = ({ prefix, y, m, dd, k, onChange, label = 'Date of birth' }: { prefix: string; y: string; m: string; dd: string; k: string; onChange: (part: 'dobY' | 'dobM' | 'dobD', v: string) => void; label?: string }) => (
    <fieldset className={fieldCls(k)}><legend className="label">{label}</legend>
      <div className="dob">
        <div><label className="xs muted" htmlFor={`${prefix}m`}>Month</label><select className="select" id={`${prefix}m`} value={m} autoComplete={prefix === 'rq-dob' ? 'bday-month' : 'off'} onChange={(e) => onChange('dobM', e.target.value)} {...aria(k, prefix)}><option value="">Month</option>{MONTHS.map((x, i) => <option key={x} value={String(i + 1)}>{x}</option>)}</select></div>
        <div><label className="xs muted" htmlFor={`${prefix}d`}>Day</label><input className="input" id={`${prefix}d`} inputMode="numeric" maxLength={2} placeholder="DD" value={dd} autoComplete={prefix === 'rq-dob' ? 'bday-day' : 'off'} onChange={(e) => onChange('dobD', e.target.value.replace(/\D/g, ''))} {...aria(k, prefix)} /></div>
        <div><label className="xs muted" htmlFor={`${prefix}y`}>Year</label><input className="input" id={`${prefix}y`} inputMode="numeric" maxLength={4} placeholder="YYYY" value={y} autoComplete={prefix === 'rq-dob' ? 'bday-year' : 'off'} onChange={(e) => onChange('dobY', e.target.value.replace(/\D/g, ''))} {...aria(k, prefix)} /></div>
      </div>
      {errEl(k, prefix)}
    </fieldset>
  );

  const reviewRows: [string, string, number][] = [
    ['Car', car ? [car.year, car.name].filter(Boolean).join(' ') : '', 1],
    ['Pickup', d.from ? `${longDate(d.from)}, ${clock(d.tf)}, ${placeText(d.pickupAt, d.pickupAddress.label, d.pickupAirport, 'delivered to')}` : '', 1],
    ['Return', d.to ? `${longDate(d.to)}, ${clock(d.tt)}, ${placeText(d.returnAt, d.returnAddress.label || d.pickupAddress.label, d.returnAirport, 'we pick it up from')}` : '', 1],
    ['Driver', `${d.first} ${d.last}${age !== null ? `, ${age} at pickup` : ''}`, 2], ['Contact', `${d.email}, ${d.phone}`, 2],
    ['Additional drivers', d.drivers.length ? d.drivers.map((x) => `${x.first} ${x.last}`).join(', ') : 'None', 2],
    ['Licence', d.licClass === 'other' ? `Other (${d.licIssuer}), for review` : d.licClass ? `Ontario class ${d.licClass}` : '', 3], ['Coverage', car?.insuranceIncluded ? 'Insurance included with the car' : covText[d.coverage] ?? '', 3],
    ...(car?.noCreditCard ? [['Card', 'No credit card needed: a credit or debit card in your name', 3] as [string, string, number]] : []),
    ['Booking type', d.bookingType === 'non_refundable' ? `Non-refundable, ${p.tokens.nonRef} off the rental charge` : 'Standard, refund by cancellation tier', 3],
    ['Add-ons', d.addons.filter((c) => c.quantity > 0).map((c) => { const o = addonOptions.find((x) => x.code === c.code); const n = o?.name ?? c.code.replace(/_/g, ' ');
      return `${c.quantity > 1 ? `${c.quantity} x ` : ''}${n}${c.hours ? `, ${c.hours} hours` : ''}`; }).join(', ') || 'None', 4]
  ];
  const [sumOpen, setSumOpen] = useState(false);
  useEffect(() => { const mq = window.matchMedia('(min-width: 64rem)'); const f = () => { if (mq.matches) setSumOpen(true); }; f(); mq.addEventListener('change', f); return () => mq.removeEventListener('change', f); }, []);

  return (
    <div data-page="request" className="req">
      <div className="wrap req__head">
        <p className="small muted"><Link className="link" href="/cars">Fleet</Link> / Request to book</p>
        <h1 className="d2">Request to book</h1>
        <p className="req__assure"><b>No payment and no card at this stage.</b> We confirm the car and the price first. The car is booked only when you approve, sign and pay.</p>
        <ol className="steps" aria-label="Progress">
          {STEPS.map(([b, rest], i) => {
            const n = i + 1;
            return (
              <li key={b} className={n === step ? 'is-current' : n < step ? 'is-done' : undefined} aria-current={n === step ? 'step' : undefined}>
                <b>{n < step ? <button type="button" onClick={() => show(n)}>{b}<span className="vh">, done. Edit</span></button> : b}</b><span>{rest}</span>
              </li>
            );
          })}
        </ol>
        <p className="req__meta small"><span className="strong">Step {step} of {LAST}</span>{saved && <span className="muted">Saved</span>}
          <button type="button" className="link" onClick={() => { try { localStorage.removeItem(KEY); } catch { /* ignore */ } meta.current = { token: null, draftId: null, key: newKey() }; setD({ ...emptyRequest(), car: d.car }); setErrors({}); setRestored(false); show(1); }}>Start over</button></p>
        {restored && <p className="alert alert--ok"><span className="alert__title">We kept your place</span><span>Your earlier answers are filled in. Change anything you like.</span></p>}
      </div>

      <div className="wrap req__layout">
        <form className="req__form" noValidate aria-label="Request to book" ref={form} onSubmit={send}>
          {failure && <p className="alert alert--error" role="alert"><span className="alert__title">Not sent yet</span><span>{failure}</span></p>}
          <section data-step="1" className="req__step stack-lg" aria-labelledby="rs1" hidden={step !== 1}>
            <h2 className="d3" id="rs1" tabIndex={-1}>Your dates</h2>
            <div className={fieldCls('car')}><label className="label" htmlFor="rq-car">Car</label>
              <select className="select" id="rq-car" value={d.car} onChange={(e) => { const c = p.cars.find((x) => x.slug === e.target.value); setD((x) => ({ ...x, car: e.target.value, pickupAt: !c?.ownerLocation && x.pickupAt === 'owner' ? 'ours' : x.pickupAt, returnAt: !c?.ownerLocation && x.returnAt === 'owner' ? 'ours' : x.returnAt })); setErrors((er) => { const n = { ...er }; delete n.car; return n; }); }} {...aria('car', 'rq-car')}>
                <option value="">Choose a car</option>{p.cars.map((c) => <option key={c.slug} value={c.slug}>{c.name}, from {money(c.daily)} a day</option>)}
              </select>{errEl('car', 'rq-car')}</div>
            <div className={fieldCls('dates')}>
              <span className="label">Pickup and return dates</span>
              <p className="hint">Tap the pickup date, then the return date. Hatched days are already booked. One booking covers up to {p.tokens.maxDays} days.</p>
              <div className="req__cal"><Calendar months={2} min={today} today={today} maxDays={p.rules.maxDays} blocks={blocks} from={d.from} to={d.to} onChange={(v) => { set('from', v.from); set('to', v.to); }} /></div>
              <p className="error" role="alert">{err('dates') ?? ''}</p>
            </div>
            <div className="field-row"><TimeSelect id="rq-tf" label="Pickup time" value={d.tf} onChange={(v) => set('tf', v)} /><TimeSelect id="rq-tt" label="Return time" value={d.tt} onChange={(v) => set('tt', v)} /></div>
            <p className="hint">Any time, day or night, with at least {p.tokens.notice}’ notice. Each car needs {p.tokens.turnaround} between bookings, so a day next to another booking may only be free for part of it.</p>
            {renderPlace('pickup')}
            {renderPlace('return')}
            <div className="req__nav"><span></span><button type="button" className="btn btn--primary btn--lg" onClick={() => { if (validate(1)) show(2); }}>Continue to driver details</button></div>
          </section>

          <section data-step="2" className="req__step stack-lg" aria-labelledby="rs2" hidden={step !== 2} onBlur={() => cap.capture({ name: `${d.first} ${d.last}`.trim(), email: d.email, phone: d.phone })}>
            <h2 className="d3" id="rs2" tabIndex={-1}>The driver</h2>
            <div className="field-row">
              <div className={fieldCls('first')}><label className="label" htmlFor="rq-first">First name</label><input className="input" id="rq-first" autoComplete="given-name" value={d.first} onChange={(e) => set('first', e.target.value)} {...aria('first', 'rq-first')} />{errEl('first', 'rq-first')}</div>
              <div className={fieldCls('last')}><label className="label" htmlFor="rq-last">Last name</label><input className="input" id="rq-last" autoComplete="family-name" value={d.last} onChange={(e) => set('last', e.target.value)} {...aria('last', 'rq-last')} />{errEl('last', 'rq-last')}</div>
            </div>
            <div className="field-row">
              <div className={fieldCls('email')}><label className="label" htmlFor="rq-email">Email{emailOptional && <> <span className="opt">optional</span></>}</label><input className="input" id="rq-email" type="email" autoComplete="email" value={d.email} onChange={(e) => set('email', e.target.value)} {...aria('email', 'rq-email', true)} /><p className="hint" id="rq-email-hint">{emailOptional ? 'We send the confirmed price here. You can also add it before you pay.' : 'We send the confirmed price here.'}</p>{errEl('email', 'rq-email')}</div>
              <div className={fieldCls('phone')}><label className="label" htmlFor="rq-phone">Mobile number</label><input className="input" id="rq-phone" type="tel" autoComplete="tel" value={d.phone} onChange={(e) => set('phone', e.target.value)} {...aria('phone', 'rq-phone', true)} /><p className="hint" id="rq-phone-hint">For questions about this request only.</p>{errEl('phone', 'rq-phone')}</div>
            </div>
            <CaptureNote reply={cap.reply} />
            <SavedAsYouType />
            {renderDob({ prefix: 'rq-dob', y: d.dobY, m: d.dobM, dd: d.dobD, k: 'dob', onChange: (part, v) => set(part, v) })}
            <p className="hint">Drivers must be {p.tokens.minAge} or older at pickup. Age sets the young driver fee.</p>
            <div className={fieldCls('drivers')}>
              <span className="label" id="rq-add-l">Additional drivers</span>
              <p className="hint">{p.tokens.addDrvPct} of the car’s daily rate, a day, for each one. Each one needs a {p.tokens.licence} licence and signs the agreement.</p>
              <div className="qty">
                <button type="button" aria-label="Fewer additional drivers" disabled={!d.drivers.length} onClick={() => set('drivers', d.drivers.slice(0, -1))}>−</button>
                <output aria-labelledby="rq-add-l">{d.drivers.length}</output>
                <button type="button" aria-label="More additional drivers" disabled={d.drivers.length >= p.rules.maxAdditional} onClick={() => set('drivers', [...d.drivers, { first: '', last: '', email: '', licClass: '', dobY: '', dobM: '', dobD: '' }])}>+</button>
              </div>
              <p className="error" role="alert">{err('drivers') ?? ''}</p>
            </div>
            {d.drivers.map((x, i) => {
              const upd = (k: keyof typeof x, v: string) => { const n = d.drivers.slice(); n[i] = { ...x, [k]: v }; set('drivers', n); setErrors((e) => { const c = { ...e }; for (const kk of Object.keys(c)) if (kk.startsWith(`drivers.${i}.`)) delete c[kk]; return c; }); };
              return (
                <fieldset className="panel stack" key={i}><legend className="label">Additional driver {i + 1}</legend>
                  <div className="field-row">
                    <div className={fieldCls(`drivers.${i}.name`)}><label className="label" htmlFor={`rq-ad${i}-first`}>First name</label><input className="input" id={`rq-ad${i}-first`} value={x.first} onChange={(e) => upd('first', e.target.value)} {...aria(`drivers.${i}.name`, `rq-ad${i}-first`)} />{errEl(`drivers.${i}.name`, `rq-ad${i}-first`)}</div>
                    <div className="field"><label className="label" htmlFor={`rq-ad${i}-last`}>Last name</label><input className="input" id={`rq-ad${i}-last`} value={x.last} onChange={(e) => upd('last', e.target.value)} /></div>
                  </div>
                  <div className={fieldCls(`drivers.${i}.email`)}><label className="label" htmlFor={`rq-ad${i}-email`}>Email</label><input className="input" id={`rq-ad${i}-email`} type="email" value={x.email} onChange={(e) => upd('email', e.target.value)} {...aria(`drivers.${i}.email`, `rq-ad${i}-email`)} />{errEl(`drivers.${i}.email`, `rq-ad${i}-email`)}</div>
                  {renderDob({ prefix: `rq-ad${i}-dob`, y: x.dobY, m: x.dobM, dd: x.dobD, k: `drivers.${i}.dob`, onChange: (part, v) => upd(part, v) })}
                </fieldset>
              );
            })}
            <div className="field"><label className="label" htmlFor="rq-ref">Did someone refer you? <span className="opt">optional</span></label><input className="input" id="rq-ref" value={d.referrer} onChange={(e) => set('referrer', e.target.value)} aria-describedby="rq-ref-hint" /><p className="hint" id="rq-ref-hint">Their name, if so.</p></div>
            <div className="req__nav"><button type="button" className="btn btn--ghost" onClick={() => show(1)}>Back</button><button type="button" className="btn btn--primary btn--lg" onClick={() => { if (validate(2)) show(3); }}>Continue to licence</button></div>
          </section>

          <section data-step="3" className="req__step stack-lg" aria-labelledby="rs3" hidden={step !== 3}>
            <h2 className="d3" id="rs3" tabIndex={-1}>Licence and coverage</h2>
            <fieldset className={fieldCls('licClass')}><legend className="label">Licence class</legend>
              <div className="seg">
                {[...p.rules.licenceClasses].sort().map((c) => <label key={c}><input type="radio" name="licClass" value={c} checked={d.licClass === c} onChange={() => set('licClass', c)} />Ontario {c}</label>)}
                {p.rules.otherLicence && <label><input type="radio" name="licClass" value="other" checked={d.licClass === 'other'} onChange={() => set('licClass', 'other')} />Something else</label>}
              </div>
              <p className="hint">Licences from outside Ontario are reviewed by a person before we confirm. No photos yet: we ask for your licence after you approve the price.</p><p className="error" role="alert">{err('licClass') ?? ''}</p>
            </fieldset>
            {d.licClass === 'other' && (
              <div className={fieldCls('licIssuer')}><label className="label" htmlFor="rq-issuer">Where was it issued?</label><input className="input" id="rq-issuer" value={d.licIssuer} onChange={(e) => set('licIssuer', e.target.value)} placeholder="Quebec, New York, United Kingdom" {...aria('licIssuer', 'rq-issuer')} />{errEl('licIssuer', 'rq-issuer')}</div>
            )}
            {car?.insuranceIncluded ? (
              <div className="alert alert--ok" data-testid="coverage-included-step"><span className="alert__title">Insurance included</span>
                <span>This car comes with its insurance: no personal auto policy, OPCF 27 or credit card coverage needed.{car.noCreditCard ? ' No credit card needed either: a debit card in your name is accepted.' : ''}</span></div>
            ) : (
            <fieldset className={fieldCls('coverage')}><legend className="label">How will the car be covered?</legend>
              <p className="hint">Liability coverage is included. This is about damage to the car. You can change your choice any time before pickup.</p>
              <div className="stack">
                {(['1', '2', '3'] as const).map((v) => (
                  <label className="option" key={v}><input type="radio" name="coverage" value={v} checked={d.coverage === v} onChange={() => set('coverage', v)} />
                    <span className="option__title">{covText[v]!.replace(', priced in your offer', '')}</span>
                    <span className="option__body">{v === '1' ? 'You will send the policy page or an insurer letter showing OPCF 27.' : v === '2' ? 'You will pay with that card and send its benefits certificate.' : 'Priced in your offer, for your car and the driver’s age. We send the Protection Plan’s terms before you buy.'}</span></label>
                ))}
              </div><p className="error" role="alert">{err('coverage') ?? ''}</p>
            </fieldset>
            )}
            <fieldset className="field"><legend className="label">Booking type</legend>
              <div className="stack">
                <label className="option"><input type="radio" name="bookingType" value="standard" checked={d.bookingType === 'standard'} onChange={() => set('bookingType', 'standard')} /><span className="option__title">Standard</span><span className="option__body">Cancel {p.tokens.cEarly} hours or more before pickup for {p.tokens.c2} back. <Link className="link" href="/cancellation-policy">All tiers</Link>.</span></label>
                <label className="option"><input type="radio" name="bookingType" value="non_refundable" checked={d.bookingType === 'non_refundable'} onChange={() => set('bookingType', 'non_refundable')} /><span className="option__title">Non-refundable, {p.tokens.nonRef} off the rental charge</span><span className="option__body">Cheaper, but no refund if you cancel, miss pickup or return early.</span></label>
              </div>
            </fieldset>
            <div className={fieldCls('notes')}><label className="label" htmlFor="rq-notes">Anything we should know? <span className="opt">optional</span></label><textarea className="textarea" id="rq-notes" maxLength={p.rules.noteMax} value={d.notes} onChange={(e) => set('notes', e.target.value)} placeholder="Flight number, a trip outside Ontario, a pet coming along" aria-describedby="rq-notes-hint" /><p className="hint" id="rq-notes-hint">Trips outside Ontario and pets need our approval first, so mention them here.</p>{errEl('notes', 'rq-notes')}</div>
            <div className="req__nav"><button type="button" className="btn btn--ghost" onClick={() => show(2)}>Back</button><button type="button" className="btn btn--primary btn--lg" onClick={() => { if (validate(3)) show(4); }}>Continue to add-ons</button></div>
          </section>

          <section data-step="4" className="req__step stack-lg" aria-labelledby="rs4" hidden={step !== 4}>
            <h2 className="d3" id="rs4" tabIndex={-1}>Add-ons</h2>
            <p className="hint">Optional extras for your trip. The estimate shows the price as you choose. Anything that needs our confirmation is confirmed in your offer.</p>
            {!car ? <p className="muted">Choose a car first.</p> : <AddonPicker idPrefix="rq" options={addonOptions} value={d.addons} onChange={(v) => set('addons', v)} />}
            {game.card(4)}
            <div className="req__nav"><button type="button" className="btn btn--ghost" onClick={() => show(3)}>Back</button><button type="button" className="btn btn--primary btn--lg" onClick={() => { if (validate(4)) show(5); }}>Review request</button></div>
          </section>

          <section data-step="5" className="req__step stack-lg" aria-labelledby="rs5" hidden={step !== 5}>
            <h2 className="d3" id="rs5" tabIndex={-1}>Check it and send</h2>
            <table className="spec req__review"><tbody>
              {reviewRows.map(([k, v, n]) => <tr key={k}><th scope="row">{k}</th><td>{v}</td><td><button type="button" className="link small" onClick={() => show(n)}>Edit<span className="vh"> {k}</span></button></td></tr>)}
            </tbody></table>
            {game.card(5)}
            <div className={fieldCls('promo')}>
              <label className="label" htmlFor="rq-promo">Promo code <span className="opt">optional</span></label>
              <input className="input" id="rq-promo" name="promo" autoComplete="off" autoCapitalize="characters" spellCheck={false} maxLength={40} value={d.promo}
                onChange={(e) => set('promo', e.target.value.toUpperCase().replace(/\s+/g, ''))} aria-describedby="rq-promo-hint" data-testid="promo-code" />
              <p className="hint" id="rq-promo-hint" role="status" data-testid="promo-status">{!d.promo ? 'One code per booking. It comes off the rental charge.' : !q ? '' : q.promo?.applied
                ? `Code ${q.promo.code} applied: ${money(-(q.lines.find((l) => l.charge_type === 'promo_discount')?.amount_cents ?? 0), { cents: true })} off the rental charge.`
                : q.promo?.problem ?? ''}</p>
              {errEl('promo', 'rq-promo')}
            </div>
            <div className="alert"><span className="alert__title">What sending this does</span><span>It asks us to check the car and price. It does not book or hold the car, and it takes no payment. We send the final price as an offer that stays open for {p.tokens.offerHours} hours. The car is booked only when you approve, sign and pay. If someone else pays for the same car and dates first, we tell you and offer another car or other dates.</span></div>
            <div className={fieldCls('agree')}>
              <label className="check"><input type="checkbox" name="agree" checked={d.agree} onChange={(e) => set('agree', e.target.checked)} aria-invalid={err('agree') ? true : undefined} aria-describedby={err('agree') ? 'rq-agree-err' : undefined} /><span>{p.agreeLine.replace(/Terms of use and Privacy policy\.$/, '')}<Link className="link" href="/terms">Terms of use</Link> and <Link className="link" href="/privacy">Privacy policy</Link>.</span></label>
              <p className="error" role="alert" id="rq-agree-err">{err('agree') ?? ''}</p>
            </div>
            <label className="check"><input type="checkbox" name="marketing" checked={d.marketing} onChange={(e) => set('marketing', e.target.checked)} /><span className="small">{p.marketingText}</span></label>
            <Turnstile action="booking_request" />
            <div className="req__nav"><button type="button" className="btn btn--ghost" onClick={() => show(4)}>Back</button><button type="submit" className="btn btn--primary btn--lg" disabled={sending}>{sending ? 'Sending' : 'Send request'}</button></div>
            <p className="small muted">No payment now. No card needed.</p>
          </section>
        </form>

        <aside className="req__side" aria-label="Your request">
          <details className="req__sum" open={sumOpen} onToggle={(e) => setSumOpen((e.target as HTMLDetailsElement).open)}>
            <summary><span className="d4">Your request</span><b className="num">{q && haveDates ? money(q.total_cents, { cents: true }) : car ? `From ${money(car.daily)} a day` : ''}</b></summary>
            <div className="req__car">
              {car ? (
                <>
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  {car.cover && <img src={photoUrl(car.cover.path)} alt="" width={1800} height={1200} loading="lazy" />}
                  <div><b>{[car.year, car.name].filter(Boolean).join(' ')}</b><span className="small muted">{car.trim}</span></div>
                </>
              ) : <p className="muted">Choose a car to see the estimate.</p>}
            </div>
            {car && <Estimate q={q} error={qErr} loading={loading} from={haveDates ? d.from : ''} to={haveDates ? d.to : ''} tf={d.tf} tt={d.tt} hst={p.tokens.hst} maxDays={p.rules.maxDays}
              rates={{ daily: car.daily, weekend: car.weekend, weekly: car.weekly, monthly: car.monthly, multi: car.multi ?? null }} labels={p.tokens} problem={problem} coverageChosen={d.coverage === '3' && !car.insuranceIncluded} />}
          </details>
        </aside>
      </div>
      {game.popup}
    </div>
  );
}

export { dobIso };
