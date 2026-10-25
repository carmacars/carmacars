'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { money } from '@/lib/format';
import { chooseFirstLast, saveTerms, type FirstLastAction, type TermsInput } from '@/server/actions/owner-billing';
import { METHODS } from './ApproveStep';
import { dollars, pctOf, toCents } from './shared';

// Negotiated terms (migration 0067): the owner's default for their cars, and each car's own exact amounts, each with
// the date they apply from. A car whose Vehicle Schedule is signed gets an updated schedule for the owner to sign
// (one click after the warning); its current terms apply until then.
type T = { insurance_fee_cents: number | null; tracker_fee_cents: number | null; revenue_share_bps: number | null; install_fee_cents: number | null; first_last_cents: number | null;
  one_off_fees?: Array<{ description: string; amount_cents: number; hst: boolean }>; effective_from?: string; effective_to?: string | null; note?: string | null; id?: string };
export interface CarTerms { vehicle_id: string; name: string; mode: string; billing_case: string;
  resolved: T & { sources: Record<string, string>; standard: T };
  rows: T[]; schedule: (T & { schedule_number: string; signed_at: string | null; first_last_set: boolean }) | null;
  awaiting: { change_id: string; effective_from: string; text: string; new: T; created_at: string } | null;
  versions: Array<{ schedule_number: string; signed_at: string | null; insurance_fee_cents: number; revenue_share_bps: number; superseded_at: string | null }>;
  first_last?: FirstLast }
export interface FirstLast { choice: FirstLastAction | null; amount_cents: number | null; at: string | null; by: string | null; default_cents: number | null; needed: boolean;
  invoice: { invoice_number: string; status: string; total_cents: number } | null }

const CHOICES: Array<[FirstLastAction, string]> = [['send', 'Send invoice now'], ['draft', 'Draft only'], ['paid', 'Already paid'], ['none', 'No invoice']];

// The first and last month invoice of one car (0077): never made by itself. The Admin's choice, the amount (default
// 2 x the Insurance Fee) and what happens: sent now, kept as a draft, recorded as paid, or no invoice at all.
function FirstLastChoice({ c, paths, today }: { c: CarTerms; paths: string[]; today: string }) {
  const router = useRouter();
  const a = useAct<{ choice: string; invoice: { invoice_number: string; status: string } | null }>();
  const uid = `fl-${useId().replace(/[^\w-]/g, '')}`;
  const st = c.first_last!;
  const [action, setAction] = useState<FirstLastAction | ''>('');
  const [amount, setAmount] = useState(dollars(st.amount_cents ?? st.default_cents));
  const [method, setMethod] = useState('e_transfer');
  const [on, setOn] = useState(today);
  const [ref, setRef] = useState('');
  const label = CHOICES.find(([k]) => k === st.choice)?.[1];
  const submit = () => {
    if (!action) return;
    a.run(() => chooseFirstLast({ vehicle_id: c.vehicle_id, action, amount_cents: action === 'none' ? undefined : toCents(amount),
      payment: action === 'paid' ? { method, received_on: on, reference: ref || undefined, note: method === 'other' ? ref : undefined } : undefined }, paths), (r) => { if (r.ok) router.refresh(); });
  };
  return (
    <div className="stack" data-testid="first-last-choice">
      <p className="small"><b>First and last month invoice:</b>{' '}
        {st.invoice ? <>invoice {st.invoice.invoice_number} ({st.invoice.status}, {money(st.invoice.total_cents, { cents: true })}). Change it on the invoice screen.</>
          : label ? <>{label}{st.choice !== 'none' && st.amount_cents ? `, ${money(st.amount_cents, { cents: true })}` : ''}{st.by ? ` (${st.by})` : ''}.</>
          : <span className="ow-warn" data-testid="first-last-undecided">not decided. Nothing is invoiced until you choose.</span>}</p>
      {!st.invoice && st.choice !== 'none' && (
        <form className="stack" noValidate aria-label="First and last month invoice" onSubmit={(e) => { e.preventDefault(); submit(); }}>
          <div className="row" role="radiogroup" aria-label="What to do" style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}>
            {CHOICES.map(([k, l]) => <label key={k} className="check" htmlFor={`${uid}-${k}`}><input type="radio" id={`${uid}-${k}`} name={`${uid}-a`} checked={action === k} onChange={() => setAction(k)} data-testid={`first-last-${k}`} /><span>{l}</span></label>)}
          </div>
          {action && action !== 'none' && <div className="field"><label className="label" htmlFor={`${uid}-amt`}>Amount before HST ($)</label>
            <input className="input" id={`${uid}-amt`} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} data-testid="first-last-amount" />
            <p className="hint">Default 2 x the Insurance Fee; any exact amount.</p></div>}
          {action === 'paid' && <div className="field-row">
            <div className="field"><label className="label" htmlFor={`${uid}-m`}>Paid by</label><select className="select" id={`${uid}-m`} value={method} onChange={(e) => setMethod(e.target.value)}>{METHODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
            <div className="field"><label className="label" htmlFor={`${uid}-d`}>Date received</label><input className="input" type="date" id={`${uid}-d`} value={on} max={today} onChange={(e) => setOn(e.target.value)} /></div>
            <div className="field"><label className="label" htmlFor={`${uid}-r`}>{method === 'cheque' ? 'Cheque number' : 'Reference'}{['cash', 'other'].includes(method) ? ' (optional)' : ''}</label><input className="input" id={`${uid}-r`} value={ref} onChange={(e) => setRef(e.target.value)} data-testid="first-last-reference" /></div>
          </div>}
          {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending || !action} data-testid="first-last-save">{a.pending ? 'Saving' : action === 'send' ? 'Send the invoice' : 'Save the choice'}</button></div>
        </form>)}
    </div>
  );
}
export interface TermsData { owner: { rows: T[]; current: T | null }; standard: T | null; cars: CarTerms[] }

const day = (iso?: string | null) => (iso ? new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' }) : '');
const FIELDS: Array<[keyof T, string, 'money' | 'pct']> = [['insurance_fee_cents', 'Insurance Fee a month ($)', 'money'], ['tracker_fee_cents', 'Tracker Fee a month ($)', 'money'],
  ['revenue_share_bps', 'Management fee (Revenue Share, %)', 'pct'], ['install_fee_cents', 'Install Fee ($)', 'money'], ['first_last_cents', 'First and last month amount ($)', 'money']];

function TermsForm({ base, scope, ownerId, vehicleId, today, paths, signed, testId }: { base: T; scope: 'owner' | 'car'; ownerId: string; vehicleId?: string; today: string; paths: string[]; signed?: boolean; testId: string }) {
  const router = useRouter();
  const a = useAct<{ saved: string | null; needs_resign: boolean; message?: string; note?: string }>();
  const uid = `tf-${useId().replace(/[^\w-]/g, '')}`;
  const [v, setV] = useState<Record<string, string>>(() => Object.fromEntries(FIELDS.map(([k, , kind]) => [k, kind === 'pct' ? pctOf(base[k] as number | null) : dollars(base[k] as number | null)])));
  const [from, setFrom] = useState(today);
  const [note, setNote] = useState('');
  const [fees, setFees] = useState<Array<{ description: string; amount: string; hst: boolean }>>((base.one_off_fees ?? []).map((f) => ({ description: f.description, amount: dollars(f.amount_cents), hst: f.hst })));
  const [warn, setWarn] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const payload = (confirm: boolean): TermsInput => {
    const t: TermsInput = { owner_id: scope === 'owner' ? ownerId : undefined, vehicle_id: vehicleId, effective_from: from, note, confirm_resign: confirm,
      one_off_fees: fees.filter((f) => f.description.trim()).map((f) => ({ description: f.description.trim(), amount_cents: toCents(f.amount), hst: f.hst })) };
    for (const [k, , kind] of FIELDS) {
      const raw = (v[k] ?? '').trim();
      (t as Record<string, unknown>)[k] = raw === '' ? null : kind === 'pct' ? Math.round(Number(raw) * 100) : toCents(raw);
    }
    return t;
  };
  const submit = (confirm: boolean) => { setDone(null); a.run(() => saveTerms(payload(confirm), paths), (r) => {
    if (!r.ok) return;
    if (r.data.needs_resign && !r.data.saved) { setWarn(r.data.message ?? 'The Vehicle Schedule is signed: the owner must sign an updated one.'); return; }
    setWarn(null); setDone(r.data.note ?? 'Saved.'); router.refresh();
  }); };
  return (
    <form className="stack" noValidate aria-label={scope === 'owner' ? 'The owner\'s terms' : 'This car\'s terms'} data-testid={testId} onSubmit={(e) => { e.preventDefault(); submit(false); }}>
      <div className="ad-fields ob-terms">
        {FIELDS.map(([k, l, kind]) => (
          <div key={k} className="field"><label className="label" htmlFor={`${uid}-${k}`}>{l}</label>
            <input className="input" id={`${uid}-${k}`} inputMode="decimal" value={v[k] ?? ''} onChange={(e) => setV({ ...v, [k]: e.target.value })} data-testid={`terms-${k}`}
              placeholder={k === 'first_last_cents' ? '2 x the Insurance Fee' : scope === 'owner' ? 'Not negotiated' : ''} aria-describedby={kind === 'pct' ? undefined : `${uid}-hint`} /></div>))}
        <div className="field"><label className="label" htmlFor={`${uid}-from`}>Applies from</label>
          <input className="input" id={`${uid}-from`} type="date" value={from} onChange={(e) => setFrom(e.target.value)} data-testid="terms-from" /></div>
      </div>
      <p className="hint" id={`${uid}-hint`}>{scope === 'owner' ? 'Leave a field empty to keep the standard grid for it. These apply to the owner\'s cars whose terms are set from that date.' : 'Exact amounts to the cent. The first and last month amount, when empty, is 2 x the Insurance Fee.'}</p>
      <fieldset className="stack"><legend className="label">One-off fees agreed (optional)</legend>
        {fees.map((f, i) => (
          <div key={i} className="row ob-fee" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
            <label className="vh" htmlFor={`${uid}-fd${i}`}>Description</label><input className="input" id={`${uid}-fd${i}`} value={f.description} placeholder="For example: registration fee" onChange={(e) => setFees(fees.map((x, j) => (j === i ? { ...x, description: e.target.value } : x)))} />
            <label className="vh" htmlFor={`${uid}-fa${i}`}>Amount ($)</label><input className="input input--sm" id={`${uid}-fa${i}`} inputMode="decimal" value={f.amount} placeholder="0.00" onChange={(e) => setFees(fees.map((x, j) => (j === i ? { ...x, amount: e.target.value } : x)))} />
            <label className="check" htmlFor={`${uid}-fh${i}`}><input type="checkbox" id={`${uid}-fh${i}`} checked={f.hst} onChange={(e) => setFees(fees.map((x, j) => (j === i ? { ...x, hst: e.target.checked } : x)))} /><span>HST</span></label>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => setFees(fees.filter((_, j) => j !== i))}>Remove</button>
          </div>))}
        <div className="row"><button type="button" className="btn btn--ghost btn--sm" onClick={() => setFees([...fees, { description: '', amount: '', hst: true }])}>Add a one-off fee</button></div>
      </fieldset>
      <div className="field"><label className="label" htmlFor={`${uid}-note`}>Note (staff only, optional)</label><input className="input" id={`${uid}-note`} value={note} onChange={(e) => setNote(e.target.value)} /></div>
      {warn && (
        <div className="alert alert--warn stack" role="alert" data-testid="terms-resign-warning"><span className="alert__title">The owner must sign an updated Vehicle Schedule</span><span>{warn}</span>
          <div className="row"><button type="button" className="btn btn--primary btn--sm" disabled={a.pending} onClick={() => submit(true)} data-testid="terms-resign">Create the updated schedule and email the owner to sign</button>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => setWarn(null)}>Cancel</button></div></div>)}
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {done && <p className="alert alert--ok" role="status" data-testid="terms-saved"><span>{done}</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending} data-testid="terms-save">{a.pending ? 'Saving' : signed ? 'Change the terms' : 'Save the terms'}</button></div>
    </form>
  );
}

export function TermsPanel({ data, ownerId, today }: { data: TermsData; ownerId: string; today: string }) {
  const paths = [`/admin/owners/${ownerId}`];
  const cur = data.owner.current;
  return (
    <div className="stack-lg" data-testid="terms-panel">
      <section className="pt-card stack" aria-labelledby="tp-owner"><h2 className="d4" id="tp-owner">The owner&apos;s terms (default for their cars)</h2>
        <p className="small">{cur ? `In force from ${day(cur.effective_from)}${cur.effective_to ? ` to ${day(cur.effective_to)}` : ''}.` : 'Nothing negotiated: the standard grid applies.'}{data.standard ? ` Standard grid: ${money(data.standard.insurance_fee_cents)} insurance, ${money(data.standard.tracker_fee_cents)} tracker, ${pctOf(data.standard.revenue_share_bps)}% share.` : ''}</p>
        <TermsForm base={cur ?? { insurance_fee_cents: null, tracker_fee_cents: null, revenue_share_bps: null, install_fee_cents: null, first_last_cents: null }} scope="owner" ownerId={ownerId} today={today} paths={paths} testId="terms-owner-form" />
        {data.owner.rows.length > 0 && <ul className="ad-list small">{data.owner.rows.map((r) => <li key={r.id}><span>From {day(r.effective_from)}{r.effective_to ? ` to ${day(r.effective_to)}` : ''}</span>
          <span>{[r.insurance_fee_cents !== null && `${money(r.insurance_fee_cents)} insurance`, r.tracker_fee_cents !== null && `${money(r.tracker_fee_cents)} tracker`, r.revenue_share_bps !== null && `${pctOf(r.revenue_share_bps)}% share`,
            r.install_fee_cents !== null && `${money(r.install_fee_cents)} install`, r.first_last_cents !== null && `${money(r.first_last_cents, { cents: true })} first and last`].filter(Boolean).join(', ') || 'grid'}{r.note ? ` · ${r.note}` : ''}</span></li>)}</ul>}
      </section>
      {data.cars.filter((c) => !['turo_only', 'shareholder'].includes(c.billing_case) && (c.first_last?.needed || c.versions.length > 1)).map((c) => (
        // each car's own terms are edited in the table Cars and terms (0135); here: its first and last month invoice and its versions
        <section key={c.vehicle_id} className="pt-card stack" aria-label={`First and last month of ${c.name}`} data-testid="terms-car">
          <div className="pt-card__head"><h2 className="d4">{c.name}</h2><span className="badge badge--outline">{c.schedule ? (c.schedule.signed_at ? `${c.schedule.schedule_number} signed ${day(c.schedule.signed_at)}` : `${c.schedule.schedule_number}, not signed`) : 'Terms not set'}</span></div>
          {c.first_last?.needed && <FirstLastChoice c={c} paths={paths} today={today} />}
          {c.versions.length > 1 && <p className="small muted">Vehicle Schedule versions: {c.versions.map((x) => `${x.schedule_number} (${money(x.insurance_fee_cents)}, ${pctOf(x.revenue_share_bps)}%${x.signed_at ? `, signed ${day(x.signed_at)}` : ''})`).join(' · ')}</p>}
        </section>
      ))}
    </div>
  );
}
