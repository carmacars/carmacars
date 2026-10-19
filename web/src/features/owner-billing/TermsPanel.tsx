'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { money } from '@/lib/format';
import { saveTerms, scheduleChange, type TermsInput } from '@/server/actions/owner-billing';
import { SOURCE_LABEL, dollars, pctOf, toCents } from './shared';

// Negotiated terms (migration 0067): the owner's default for their cars, and each car's own exact amounts, each with
// the date they apply from. A car whose Vehicle Schedule is signed gets an updated schedule for the owner to sign
// (one click after the warning); its current terms apply until then.
type T = { insurance_fee_cents: number | null; tracker_fee_cents: number | null; revenue_share_bps: number | null; install_fee_cents: number | null; first_last_cents: number | null;
  one_off_fees?: Array<{ description: string; amount_cents: number; hst: boolean }>; effective_from?: string; effective_to?: string | null; note?: string | null; id?: string };
export interface CarTerms { vehicle_id: string; name: string; mode: string; billing_case: string;
  resolved: T & { sources: Record<string, string>; standard: T };
  rows: T[]; schedule: (T & { schedule_number: string; signed_at: string | null; first_last_set: boolean }) | null;
  awaiting: { change_id: string; effective_from: string; text: string; new: T; created_at: string } | null;
  versions: Array<{ schedule_number: string; signed_at: string | null; insurance_fee_cents: number; revenue_share_bps: number; superseded_at: string | null }> }
export interface TermsData { owner: { rows: T[]; current: T | null }; standard: T | null; cars: CarTerms[] }

const day = (iso?: string | null) => (iso ? new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' }) : '');
const FIELDS: Array<[keyof T, string, 'money' | 'pct']> = [['insurance_fee_cents', 'Insurance Fee a month ($)', 'money'], ['tracker_fee_cents', 'Tracker Fee a month ($)', 'money'],
  ['revenue_share_bps', 'Revenue Share (%)', 'pct'], ['install_fee_cents', 'Install Fee ($)', 'money'], ['first_last_cents', 'First and last month amount ($)', 'money']];

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

function Awaiting({ c, paths, today }: { c: NonNullable<CarTerms['awaiting']>; paths: string[]; today: string }) {
  const router = useRouter();
  const a = useAct<Record<string, unknown>>();
  const uid = `aw-${useId().replace(/[^\w-]/g, '')}`;
  const [on, setOn] = useState(today);
  const [reason, setReason] = useState('');
  return (
    <div className="ow-warn stack" data-testid="terms-awaiting"><b>Updated Vehicle Schedule waiting for the owner&apos;s signature (from {day(c.effective_from)})</b>
      <pre className="small ob-text">{c.text}</pre>
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'end' }}>
        <div className="field"><label className="label" htmlFor={`${uid}-on`}>Signed on paper on</label><input className="input" type="date" id={`${uid}-on`} value={on} max={today} onChange={(e) => setOn(e.target.value)} /></div>
        <button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} onClick={() => a.run(() => scheduleChange({ change_id: c.change_id, do: 'paper', signed_on: on }, paths), (r) => { if (r.ok) router.refresh(); })}>Record signed on paper</button>
        <div className="field"><label className="label" htmlFor={`${uid}-r`}>Reason to withdraw</label><input className="input" id={`${uid}-r`} value={reason} onChange={(e) => setReason(e.target.value)} /></div>
        <button type="button" className="btn btn--quiet btn--sm" disabled={a.pending} onClick={() => a.run(() => scheduleChange({ change_id: c.change_id, do: 'cancel', reason }, paths), (r) => { if (r.ok) router.refresh(); })}>Withdraw it</button>
      </div>
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
    </div>
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
      {data.cars.filter((c) => !['turo_only', 'shareholder'].includes(c.billing_case)).map((c) => {
        const r = c.resolved;
        const base: T = c.schedule ? { ...c.schedule, first_last_cents: c.schedule.first_last_set ? c.schedule.first_last_cents : null } : { ...r, first_last_cents: r.sources.first_last_cents === 'two_months' ? null : r.first_last_cents };
        return (
          <section key={c.vehicle_id} className="pt-card stack" aria-label={`Terms of ${c.name}`} data-testid="terms-car">
            <div className="pt-card__head"><h2 className="d4">{c.name}</h2><span className="badge badge--outline">{c.schedule ? (c.schedule.signed_at ? `${c.schedule.schedule_number} signed ${day(c.schedule.signed_at)}` : `${c.schedule.schedule_number}, not signed`) : 'Terms not set'}</span></div>
            <p className="small">{c.schedule ? 'On the Vehicle Schedule' : 'Would apply'}: {money(base.insurance_fee_cents)} insurance, {money(base.tracker_fee_cents)} tracker, {pctOf(base.revenue_share_bps)}% Revenue Share, {money(base.install_fee_cents)} install, {money(base.first_last_cents ?? (base.insurance_fee_cents ?? 0) * 2, { cents: true })} first and last.
              {!c.schedule && <> From: {Object.entries(r.sources).map(([k, s]) => `${k.replace(/_cents|_bps/g, '').replace(/_/g, ' ')} ${SOURCE_LABEL[s] ?? s}`).join('; ')}.</>}</p>
            {c.awaiting && <Awaiting c={c.awaiting} paths={paths} today={today} />}
            <details><summary className="link">Change this car&apos;s terms</summary>
              <TermsForm base={base} scope="car" ownerId={ownerId} vehicleId={c.vehicle_id} today={today} paths={paths} signed={!!c.schedule?.signed_at} testId="terms-car-form" /></details>
            {c.versions.length > 1 && <p className="small muted">Versions: {c.versions.map((x) => `${x.schedule_number} (${money(x.insurance_fee_cents)}, ${pctOf(x.revenue_share_bps)}%${x.signed_at ? `, signed ${day(x.signed_at)}` : ''})`).join(' · ')}</p>}
          </section>
        );
      })}
    </div>
  );
}
