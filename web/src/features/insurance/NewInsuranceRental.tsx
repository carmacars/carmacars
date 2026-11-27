'use client';
import './insurance.css';
import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { TypedInput } from '@/components/DateInput';
import { instantOfTorontoInput } from '@/lib/dates';
import { draftClose, draftSave } from '@/server/actions/supply';
import { insuranceDo, insuranceParse } from '@/server/actions/insurance';
import { PARSED_LABEL, type Parsed } from './model';

type Car = { id: string; name: string; plate: string | null; retired: boolean };
type Insurer = { id: string; name: string };
/** The short form's fields, all text as typed: saved as the draft (rental_drafts, data.form = 'insurer'). */
export type InsF = Partial<Record<'renter_name' | 'renter_phone' | 'renter_email' | 'insurer_id' | 'insurer_name' | 'claim_number' | 'adjuster_name' | 'adjuster_email' | 'adjuster_phone'
  | 'pickup_at' | 'return_at' | 'car_mode' | 'vehicle_id' | 'car_year' | 'car_make' | 'car_model' | 'car_plate' | 'daily_rate' | 'authorized_days' | 'pays' | 'bypass' | 'notes', string>>;
export interface InsDraft { id: string; data: { form?: string; f?: InsF } }

const money = (s: string | undefined) => { const n = Number(String(s ?? '').replace(/[$,\s]/g, '')); return s && Number.isFinite(n) ? Math.round(n * 100) : undefined; };
const NEW = '__new__';

// Insurance replacements, Add (5120): only the renter's name, the insurer and claim, and the dates are needed. The car is
// one of the fleet or typed in. Paste text reads an adjuster's email or a claim notice into the fields, for the person to
// check first. Saved as a draft as it is typed (it never vanishes: Unfinished rentals, and a discarded draft can be restored).
export function NewInsuranceRental({ cars, insurers, base, draft }: { cars: Car[]; insurers: Insurer[]; base: '/admin' | '/staff'; draft: InsDraft | null }) {
  const router = useRouter();
  const [f, setF] = useState<InsF>(() => ({ car_mode: 'fleet', pays: 'insurer', ...(draft?.data.f ?? {}) }));
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [text, setText] = useState('');
  const [found, setFound] = useState<{ found: Parsed; ai: boolean } | null>(null);
  const [draftId, setDraftId] = useState<string | null>(draft?.id ?? null);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  const idRef = useRef<string | null>(draft?.id ?? null);
  const first = useRef(JSON.stringify(f));
  const queue = useRef<Promise<unknown>>(Promise.resolve());
  const set = (k: keyof InsF) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const outside = f.car_mode === 'outside';
  // off the calendar and owner notices: always for a car not in the fleet; a choice for a fleet car (off by default)
  const bypass = outside || f.bypass === 'yes';

  // the draft, saved 1.5 s after the last change, one save at a time, each with the latest id
  const save = () => {
    const title = [f.renter_name, f.claim_number ? `claim ${f.claim_number}` : null].filter(Boolean).join(', ') || 'Insurance replacement';
    const data = { form: 'insurer', f };
    const run = queue.current.then(async () => {
      const r = await draftSave({ id: idRef.current, kind: 'rental', data, title });
      if (r.ok) { idRef.current = r.data.id; setDraftId(r.data.id); setSavedAt(r.data.updated_at); }
      return r;
    });
    queue.current = run.catch(() => undefined);
    return run;
  };
  const key = JSON.stringify(f);
  useEffect(() => {
    if (key === first.current) return;
    if (!(f.renter_name ?? '').trim() && !(f.claim_number ?? '').trim()) return;
    const t = setTimeout(() => { void save(); }, 1500);
    return () => clearTimeout(t);
  }, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  const read = () => start(async () => {
    setErr(null);
    const r = await insuranceParse(text, insurers.map((i) => i.name));
    if (!r.ok) { setErr(r.message); return; }
    setFound(r.data);
  });
  const use = () => {
    if (!found) return;
    const p = found.found;
    const ins = p.insurer_name ? insurers.find((i) => i.name.toLowerCase() === p.insurer_name!.toLowerCase()) : undefined;
    setF((x) => ({ ...x,
      ...(p.renter_name ? { renter_name: p.renter_name } : {}), ...(p.renter_phone ? { renter_phone: p.renter_phone } : {}), ...(p.renter_email ? { renter_email: p.renter_email } : {}),
      ...(p.claim_number ? { claim_number: p.claim_number } : {}),
      ...(ins ? { insurer_id: ins.id, insurer_name: '' } : p.insurer_name ? { insurer_id: NEW, insurer_name: p.insurer_name } : {}),
      ...(p.adjuster_name ? { adjuster_name: p.adjuster_name } : {}), ...(p.adjuster_email ? { adjuster_email: p.adjuster_email } : {}), ...(p.adjuster_phone ? { adjuster_phone: p.adjuster_phone } : {}),
      ...(p.pickup_date ? { pickup_at: `${p.pickup_date}T10:00` } : {}), ...(p.return_date ? { return_at: `${p.return_date}T10:00` } : {}),
      ...(p.authorized_days ? { authorized_days: String(p.authorized_days) } : {}), ...(p.daily_rate_cents ? { daily_rate: (p.daily_rate_cents / 100).toFixed(2) } : {}),
      ...(p.car_make ? { car_mode: 'outside', car_year: p.car_year ? String(p.car_year) : x.car_year, car_make: p.car_make, car_model: p.car_model ?? x.car_model, car_plate: p.car_plate ?? x.car_plate } : {}) }));
    setFound(null);
    setText('');
  };

  const submit = () => start(async () => {
    setErr(null);
    const from = instantOfTorontoInput(f.pickup_at); const to = instantOfTorontoInput(f.return_at);
    if (!(f.renter_name ?? '').trim()) { setErr('Type the renter\'s name.'); return; }
    if (!f.insurer_id || (f.insurer_id === NEW && !(f.insurer_name ?? '').trim())) { setErr('Choose the insurer, or Not listed and type its name.'); return; }
    if (!(f.claim_number ?? '').trim()) { setErr('Type the claim number.'); return; }
    if (!from || !to) { setErr('Give the pickup and the return.'); return; }
    if (!outside && !f.vehicle_id) { setErr('Choose the car, or Not in the fleet and type it.'); return; }
    if (outside && !(f.car_year && f.car_make && f.car_model && f.car_plate)) { setErr('The car not in the fleet: its year, make, model and plate.'); return; }
    const r = await insuranceDo<{ booking_number: string }>('insurer_rental_create', {
      renter_name: f.renter_name, renter_phone: f.renter_phone || undefined, renter_email: f.renter_email || undefined,
      ...(f.insurer_id === NEW ? { insurer_name: f.insurer_name } : { insurer_id: f.insurer_id }), claim_number: f.claim_number,
      adjuster_name: f.adjuster_name || undefined, adjuster_email: f.adjuster_email || undefined, adjuster_phone: f.adjuster_phone || undefined,
      pickup_at: from, return_at: to,
      ...(outside ? { car: { year: Number(f.car_year), make: f.car_make, model: f.car_model, plate: f.car_plate || undefined } } : { vehicle_id: f.vehicle_id }),
      daily_rate_cents: money(f.daily_rate), authorized_days: f.authorized_days ? Number(f.authorized_days) : undefined, pays: f.pays, bypass, notes: f.notes || undefined,
      ...(idRef.current ? { draft_id: idRef.current } : {}) });
    if (!r.ok) { setErr(r.message); return; }
    router.push(`${base}/insurance-replacements/${encodeURIComponent(r.data.booking_number)}?added=1`);
  });
  const discard = () => start(async () => {
    if (!draftId) return;
    if (!window.confirm('Discard this unfinished rental? You can restore it from its link afterwards.')) return;
    await draftClose(draftId, 'discarded');
    router.push(`${base}/insurance-replacements/new`);
    router.refresh();
  });

  const field = (k: keyof InsF, label: string, o: { type?: string; req?: boolean; inputMode?: 'numeric' | 'decimal' | 'tel' | 'email'; hint?: string; wide?: boolean } = {}) => (
    <label className={`ins-field${o.wide ? ' ins-grid--wide' : ''}`} key={k}>
      <span>{label}{o.req ? <span className="ins-req" aria-hidden="true"> *</span> : null}</span>
      <TypedInput className="input" type={o.type ?? 'text'} inputMode={o.inputMode} value={f[k] ?? ''} onChange={set(k)} required={o.req} data-testid={`ins-${k}`} />
      {o.hint ? <span className="small muted">{o.hint}</span> : null}
    </label>);

  return (
    <div className="stack" data-testid="ins-form">
      <section className="pt-card stack" aria-labelledby="ins-paste-h">
        <h2 className="d4" id="ins-paste-h">Paste text</h2>
        <div className="ins-paste">
          <label className="ins-field"><span>The adjuster&apos;s email or the claim notice</span>
            <textarea className="input" value={text} onChange={(e) => setText(e.target.value)} data-testid="ins-paste" placeholder="Paste it here: the fields fill themselves after you check them." /></label>
          <div className="ins-actions"><button className="btn btn--ghost btn--sm" type="button" onClick={read} disabled={pending || text.trim().length < 10} data-testid="ins-read">Read it</button></div>
          {found && (
            <div className="ins-found" role="status" data-testid="ins-found">
              {Object.keys(found.found).length ? <>
                <p className="small"><b>Found{found.ai ? ' (some by AI)' : ''}.</b> Check each value, then use them. Nothing is saved until you add the rental.</p>
                <dl>{(Object.entries(found.found) as Array<[keyof Parsed, unknown]>).map(([k, v]) => <div key={k} style={{ display: 'contents' }}><dt>{PARSED_LABEL[k]}</dt>
                  <dd>{k === 'daily_rate_cents' ? `$${(Number(v) / 100).toFixed(2)}` : String(v)}</dd></div>)}</dl>
                <div className="ins-actions"><button className="btn btn--primary btn--sm" type="button" onClick={use} data-testid="ins-use">Use these</button>
                  <button className="btn btn--quiet btn--sm" type="button" onClick={() => setFound(null)}>Not now</button></div>
              </> : <p className="small">Nothing recognisable was found. Type the fields below.</p>}
            </div>)}
        </div>
      </section>

      <section className="pt-card stack" aria-labelledby="ins-claim-h">
        <h2 className="d4" id="ins-claim-h">Renter and claim</h2>
        <div className="ins-grid">
          {field('renter_name', 'Renter\'s name', { req: true })}
          {field('renter_phone', 'Renter\'s phone', { type: 'tel', inputMode: 'tel' })}
          {field('renter_email', 'Renter\'s email', { type: 'email', inputMode: 'email', hint: 'Optional: without one, the renter gets no email.' })}
          <label className="ins-field"><span>Insurer<span className="ins-req" aria-hidden="true"> *</span></span>
            <select className="input" value={f.insurer_id ?? ''} onChange={set('insurer_id')} data-testid="ins-insurer_id" required>
              <option value="">Choose</option>{insurers.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}<option value={NEW}>Not listed (type it)</option></select></label>
          {f.insurer_id === NEW && field('insurer_name', 'The insurer\'s name', { req: true })}
          {field('claim_number', 'Claim number', { req: true })}
          {field('adjuster_name', 'Adjuster')}
          {field('adjuster_email', 'Adjuster\'s email', { type: 'email', inputMode: 'email' })}
          {field('adjuster_phone', 'Adjuster\'s phone', { type: 'tel', inputMode: 'tel' })}
        </div>
      </section>

      <section className="pt-card stack" aria-labelledby="ins-car-h">
        <h2 className="d4" id="ins-car-h">Car and dates</h2>
        <div className="ins-grid">
          {field('pickup_at', 'Pickup', { type: 'datetime-local', req: true })}
          {field('return_at', 'Return', { type: 'datetime-local', req: true, hint: 'As authorized: extend it later from the rental.' })}
        </div>
        <fieldset className="ins-seg" aria-label="The car">
          <label className="ins-line__tax"><input type="radio" name="ins-car" checked={!outside} onChange={() => setF((x) => ({ ...x, car_mode: 'fleet' }))} data-testid="ins-car-fleet" /> A car of the fleet</label>
          <label className="ins-line__tax"><input type="radio" name="ins-car" checked={outside} onChange={() => setF((x) => ({ ...x, car_mode: 'outside' }))} data-testid="ins-car-outside" /> Not in the fleet (type it)</label>
        </fieldset>
        <div className="ins-grid">
          {!outside ? <label className="ins-field"><span>Car<span className="ins-req" aria-hidden="true"> *</span></span>
            <select className="input" value={f.vehicle_id ?? ''} onChange={set('vehicle_id')} data-testid="ins-vehicle_id">
              <option value="">Choose</option>{cars.filter((c) => !c.retired).map((c) => <option key={c.id} value={c.id}>{c.name}{c.plate ? ` (${c.plate})` : ''}</option>)}</select></label>
            : <>{field('car_year', 'Year', { inputMode: 'numeric', req: true })}{field('car_make', 'Make', { req: true })}{field('car_model', 'Model', { req: true })}{field('car_plate', 'Plate', { req: true })}</>}
          {field('daily_rate', 'The insurer pays a day ($)', { inputMode: 'decimal', hint: outside ? 'Empty: type the invoice lines later.' : 'Empty: the insurer\'s rate sheet.' })}
          {field('authorized_days', 'Days authorized', { inputMode: 'numeric' })}
          <label className="ins-field"><span>The insurer pays</span>
            <select className="input" value={f.pays ?? 'insurer'} onChange={set('pays')} data-testid="ins-pays">
              <option value="insurer">The rental and the fees</option><option value="split">The rental only</option></select></label>
        </div>
        <label className="ins-line__tax" data-testid="ins-bypass-label">
          <input type="checkbox" checked={bypass} disabled={outside} onChange={(e) => setF((x) => ({ ...x, bypass: e.target.checked ? 'yes' : 'no' }))} data-testid="ins-bypass" />
          Off the calendar and owner notices{outside ? ': always, for a car not in the fleet' : ''}</label>
        {field('notes', 'Notes', { wide: true })}
      </section>

      {err && <p className="alert alert--error" role="alert" data-testid="ins-error"><span>{err}</span></p>}
      <div className="ins-actions">
        <button className="btn btn--primary" type="button" onClick={submit} disabled={pending} data-testid="ins-submit">Add the rental</button>
        <button className="btn btn--ghost btn--sm" type="button" onClick={() => start(async () => { await save(); })} disabled={pending} data-testid="ins-save-draft">Save draft</button>
        {draftId && <button className="btn btn--quiet btn--sm" type="button" onClick={discard} disabled={pending} data-testid="ins-discard">Discard</button>}
        <span className="small muted" role="status" aria-live="polite" data-testid="ins-draft-status">{savedAt ? `Saved as a draft at ${new Date(savedAt).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' })}.` : 'Saved as a draft as you type.'}</span>
      </div>
    </div>
  );
}
