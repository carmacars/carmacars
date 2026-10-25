'use client';
import { Fragment, useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { carTermsCancel, carTermsChange, scheduleChange, type CarTermsInput, type CarTermsPlan } from '@/server/actions/owner-billing';
import { MODE_LABEL } from '@/features/owner/types';
import { dollars, pctOf, toCents } from './shared';
import './car-terms.css';

// Owner terms per car (migration 0135): one row per car with its Insurance Fee and Tracker Fee a month, management fee
// (Revenue Share), Install Fee and Management Mode, and since when they apply. Edit turns the row into fields; Review
// asks the database what would happen (nothing saved); Confirm applies it. Before signing the numbers apply at once;
// once signed, lower amounts from today or a chosen date, higher ones by written notice (and the owner's signature for
// a higher management fee). History lists every period and every change, with the notice and Cancel for what has not
// started. The same component serves the owner page (every car) and the car page (one car).
import { fmtDay, m, pc, sinceLine, stateLine, STATUS_TEXT, type CarTermsData, type CarTermsRow } from './terms-shared';
export type { CarTermsData, CarTermsRow } from './terms-shared';

type Vals = { ins: string; trk: string; share: string; inst: string; mode: string; method: string };
const valsOf = (c: CarTermsRow): Vals => ({ ins: dollars(c.current.insurance_fee_cents), trk: dollars(c.current.tracker_fee_cents), share: pctOf(c.current.revenue_share_bps),
  inst: dollars(c.current.install_fee_cents), mode: c.mode, method: c.method ?? '' });

function History({ c, today, paths }: { c: CarTermsRow; today: string; paths: string[] }) {
  const router = useRouter();
  const a = useAct<Record<string, unknown>>();
  const uid = `ch-${useId().replace(/[^\w-]/g, '')}`;
  const [cancel, setCancel] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [paper, setPaper] = useState(today);
  return (
    <div className="ct-history stack" data-testid="car-terms-history">
      <h3 className="d5">Terms over time</h3>
      {c.periods.length ? (
        <ul className="ct-periods">{c.periods.map((p, i) => (
          <li key={i} className={p.current ? 'is-current' : undefined} data-testid="car-terms-period">
            <span className="ct-when">{p.from ? `From ${fmtDay(p.from)}` : 'From the Enrollment Date'}{p.to ? ` to ${fmtDay(p.to)}` : ''}{p.current ? ' (in force)' : p.future ? ' (coming)' : ''}</span>
            <span>{m(p.insurance_fee_cents)} insurance, {m(p.tracker_fee_cents)} tracker, {pc(p.revenue_share_bps)} management fee{p.install_fee_cents !== undefined && p.install_fee_cents !== null ? `, ${m(p.install_fee_cents)} install` : ''}</span>
            <span className="small muted">{p.label}</span>
          </li>))}</ul>
      ) : <p className="small muted">No terms agreed for this car yet: the owner&apos;s terms or the standard grid apply.</p>}
      <h3 className="d5">Changes and notices</h3>
      {c.changes.length ? (
        <ul className="ct-changes">{c.changes.map((x) => (
          <li key={x.id} data-testid="car-terms-change">
            <span><b>{x.label}</b> · {STATUS_TEXT[x.status] ?? x.status}</span>
            <span className="small">Notice {fmtDay(x.notice_on)}, from {fmtDay(x.effective_from)}: {[
              x.before.insurance_fee_cents !== x.after.insurance_fee_cents && `insurance ${m(x.before.insurance_fee_cents)} to ${m(x.after.insurance_fee_cents)}`,
              x.before.tracker_fee_cents !== x.after.tracker_fee_cents && `tracker ${m(x.before.tracker_fee_cents)} to ${m(x.after.tracker_fee_cents)}`,
              x.before.revenue_share_bps !== x.after.revenue_share_bps && `management fee ${pc(x.before.revenue_share_bps)} to ${pc(x.after.revenue_share_bps)}`].filter(Boolean).join(', ') || 'same amounts'}.
              {x.reason ? ` Why: ${x.reason}.` : ''}{x.cancelled_reason ? ` Cancelled: ${x.cancelled_reason}.` : ''}{x.owner_signed_at ? ` Signed ${x.signed_method === 'paper' ? 'on paper' : 'in the portal'} ${fmtDay(x.owner_signed_at)}.` : ''}</span>
            <span className="row ct-actions">
              {x.notice && <a className="link small" href={`/files/terms_notice/${x.id}`} target="_blank" rel="noopener" data-testid="car-terms-notice">Notice (PDF)</a>}
              {x.status === 'awaiting_signature' && (
                <span className="row ct-inline">
                  <label className="vh" htmlFor={`${uid}-p-${x.id}`}>Signed on paper on</label>
                  <input className="input input--sm" type="date" id={`${uid}-p-${x.id}`} value={paper} max={today} onChange={(e) => setPaper(e.target.value)} />
                  <button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} data-testid="car-terms-paper"
                    onClick={() => a.run(() => scheduleChange({ change_id: x.id, do: 'paper', signed_on: paper }, paths), (r) => { if (r.ok) router.refresh(); })}>Record signed on paper</button>
                </span>)}
              {x.can_cancel && cancel !== x.id && <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setCancel(x.id); setReason(''); }} data-testid="car-terms-cancel">{x.status === 'awaiting_signature' ? 'Withdraw it' : 'Cancel'}</button>}
            </span>
            {cancel === x.id && (
              <form className="row ct-inline" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => carTermsCancel({ change_id: x.id, reason }, paths), (r) => { if (r.ok) { setCancel(null); router.refresh(); } }); }}>
                <div className="field"><label className="label" htmlFor={`${uid}-r-${x.id}`}>Reason</label>
                  <input className="input" id={`${uid}-r-${x.id}`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="car-terms-cancel-reason" /></div>
                <button type="submit" className="btn btn--primary btn--sm" disabled={a.pending} data-testid="car-terms-cancel-confirm">{x.status === 'awaiting_signature' ? 'Withdraw' : 'Cancel the change'}</button>
                <button type="button" className="btn btn--quiet btn--sm" onClick={() => setCancel(null)}>Keep it</button>
              </form>)}
          </li>))}</ul>
      ) : <p className="small muted">No change since the terms were agreed.</p>}
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
    </div>
  );
}

function Row({ c, data, paths }: { c: CarTermsRow; data: CarTermsData; paths: string[] }) {
  const router = useRouter();
  const a = useAct<CarTermsPlan>();
  const uid = `ct-${useId().replace(/[^\w-]/g, '')}`;
  const [edit, setEdit] = useState(false);
  const [hist, setHist] = useState(false);
  const [v, setV] = useState<Vals>(() => valsOf(c));
  const [plan, setPlan] = useState<CarTermsPlan | null>(null);
  const [lower, setLower] = useState(data.today);
  const [raise, setRaise] = useState(data.earliest_raise);
  const [reason, setReason] = useState('');
  const [done, setDone] = useState<string[] | null>(null);
  const ed = c.editable ?? { fees: false, install: false, mode: false };
  const cols = 8;
  const input = (): CarTermsInput | null => {
    const t: CarTermsInput = { vehicle_id: c.vehicle_id };
    const cents = (s: string) => toCents(s);
    t.insurance_fee_cents = cents(v.ins); t.tracker_fee_cents = cents(v.trk); t.install_fee_cents = cents(v.inst);
    t.revenue_share_bps = /^\d+(\.\d{0,2})?$/.test(v.share.trim()) ? Math.round(Number(v.share) * 100) : Number.NaN;
    if ([t.insurance_fee_cents, t.tracker_fee_cents, t.install_fee_cents, t.revenue_share_bps].some((x) => !Number.isFinite(x))) return null;
    if (ed.mode) { t.management_mode = v.mode; t.onboarding_method = v.method || undefined; }
    if (c.state === 'signed') { t.lower_from = lower; t.raise_from = raise; t.reason = reason.trim() || undefined; }
    else if (reason.trim()) t.reason = reason.trim();
    return t;
  };
  const [bad, setBad] = useState(false);
  const review = (over?: Partial<CarTermsInput>) => {
    const t = input(); setBad(!t); if (!t) return;
    a.run(() => carTermsChange({ ...t, ...over, preview: true }, paths), (r) => { if (r.ok) setPlan(r.data); });
  };
  const confirm = () => {
    const t = input(); if (!t) return;
    a.run(() => carTermsChange(t, paths), (r) => { if (r.ok) { setDone(r.data.steps); setEdit(false); setPlan(null); router.refresh(); } });
  };
  const setMode = (mode: string) => {
    const opts = c.options?.[mode] ?? [];
    const method = mode === 'turo_only' ? 'none' : opts.some((o) => o.method === v.method) ? v.method : opts.find((o) => o.recommended)?.method ?? opts[0]?.method ?? '';
    setV({ ...v, mode, method, share: mode === 'self_managed' ? '0' : v.share, ...(mode === 'turo_only' ? { ins: '0.00', trk: '0.00', inst: '0.00' } : {}) });
    setPlan(null);
  };
  const cell = (k: keyof Vals, lbl: string, on: boolean, show: string, testId: string, hint?: string) => (
    <td data-label={lbl} className="num">
      {edit && on ? <><label className="vh" htmlFor={`${uid}-${k}`}>{lbl}</label>
        <input className="input input--sm ct-input" id={`${uid}-${k}`} inputMode="decimal" value={v[k]} onChange={(e) => { setV({ ...v, [k]: e.target.value }); setPlan(null); }} data-testid={`car-terms-${testId}`} aria-describedby={hint} /></>
        : <span data-testid={`car-terms-${testId}-value`}>{show}</span>}
    </td>);
  const higher = plan?.fields.some((f) => f.direction === 'higher' && f.field !== 'install_fee_cents');
  const lowerAny = plan?.fields.some((f) => f.direction === 'lower' && f.field !== 'install_fee_cents');
  return (
    <>
      <tr data-testid="car-terms-row" data-vehicle={c.vehicle_id}>
        <th scope="row" data-label="Car"><span className="ct-car"><b>{c.name}</b>{c.plate ? <span className="small muted"> {c.plate}</span> : null}</span>
          <span className="small ct-state" data-testid="car-terms-state">{stateLine(c)}{c.awaiting ? ' · updated schedule waiting for the owner' : ''}{c.scheduled.length ? ` · change from ${fmtDay(c.scheduled[0]!.from)}` : ''}</span></th>
        {cell('ins', 'Insurance Fee a month ($)', ed.fees, m(c.current.insurance_fee_cents), 'insurance')}
        {cell('trk', 'Tracker Fee a month ($)', ed.fees, m(c.current.tracker_fee_cents), 'tracker')}
        {cell('share', 'Management fee (Revenue Share, %)', ed.fees, pc(c.current.revenue_share_bps), 'share')}
        {cell('inst', 'Install Fee ($)', ed.install, m(c.current.install_fee_cents), 'install')}
        <td data-label="Management Mode">
          {edit && ed.mode ? <span className="stack ct-mode">
            <label className="vh" htmlFor={`${uid}-mode`}>Management Mode</label>
            <select className="select select--sm" id={`${uid}-mode`} value={v.mode} onChange={(e) => setMode(e.target.value)} data-testid="car-terms-mode">
              {Object.entries(MODE_LABEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
            {(c.options?.[v.mode] ?? []).length > 0 && <><label className="vh" htmlFor={`${uid}-method`}>Onboarding Method</label>
              <select className="select select--sm" id={`${uid}-method`} value={v.method} onChange={(e) => { setV({ ...v, method: e.target.value }); setPlan(null); }} data-testid="car-terms-method">
                {(c.options?.[v.mode] ?? []).map((o) => <option key={o.method} value={o.method}>{o.label}{o.recommended ? ' (recommended)' : ''}</option>)}</select></>}
          </span> : <span data-testid="car-terms-mode-value">{MODE_LABEL[c.mode] ?? c.mode}</span>}
        </td>
        <td data-label="Since">{sinceLine(c)}</td>
        <td data-label="Actions" className="ct-buttons">
          {ed.fees && !edit && <button type="button" className="btn btn--ghost btn--sm" onClick={() => { setV(valsOf(c)); setEdit(true); setDone(null); setPlan(null); }} data-testid="car-terms-edit" aria-label={`Edit the terms of ${c.name}`}>Edit</button>}
          <button type="button" className="btn btn--quiet btn--sm" aria-expanded={hist} onClick={() => setHist(!hist)} data-testid="car-terms-history-toggle" aria-label={`History of ${c.name}`}>History</button>
        </td>
      </tr>
      {(edit || done) && (
        <tr className="ct-panel-row"><td colSpan={cols} data-label="">
          {done && !edit && <div className="alert alert--ok stack" role="status" data-testid="car-terms-done"><span className="alert__title">Saved</span>{done.map((s, i) => <span key={i}>{s}</span>)}</div>}
          {edit && (
            <div className="stack ct-panel" data-testid="car-terms-panel">
              <p className="small" id={`${uid}-hint`}>{c.state === 'signed'
                ? `Signed: lower amounts apply from today or the date you choose; higher amounts need ${data.notice_days} days' written notice, and a higher management fee the owner's signature. The Install Fee and the mode are on the signed schedule.`
                : c.state === 'pending' ? 'Not signed yet: the numbers apply at once and the documents are made again, so the owner signs these numbers.'
                : 'Not approved yet: kept for this car; the Approve step starts from them.'}</p>
              {plan && c.state === 'signed' && (lowerAny || higher) && (
                <div className="field-row">
                  {lowerAny && c.enrolled && <div className="field"><label className="label" htmlFor={`${uid}-lower`}>Lower amounts from</label>
                    <input className="input" type="date" id={`${uid}-lower`} value={lower} min={data.today} onChange={(e) => { setLower(e.target.value); review({ lower_from: e.target.value }); }} data-testid="car-terms-lower-from" /></div>}
                  {higher && c.enrolled && <div className="field"><label className="label" htmlFor={`${uid}-raise`}>Higher amounts from</label>
                    <input className="input" type="date" id={`${uid}-raise`} value={raise} min={data.earliest_raise} onChange={(e) => { setRaise(e.target.value); review({ raise_from: e.target.value }); }} data-testid="car-terms-raise-from" />
                    <p className="hint">{data.notice_days} days&apos; notice: {fmtDay(data.earliest_raise)} at the earliest.</p></div>}
                  {higher && <div className="field"><label className="label" htmlFor={`${uid}-why`}>Reason (the owner reads it)</label>
                    <input className="input" id={`${uid}-why`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="car-terms-reason" /></div>}
                </div>)}
              {plan && (
                <div className="ct-plan stack" data-testid="car-terms-plan" aria-live="polite">
                  {plan.fields.length > 0 && <ul className="ct-fields">{plan.fields.map((f) => (
                    <li key={f.field}><span>{f.label}</span><span><s>{f.before_text}</s> to <b>{f.after_text}</b></span>
                      <span className={`badge ${f.direction === 'higher' ? 'badge--outline' : 'badge--grey'}`}>{f.direction === 'lower' ? 'Lower' : f.direction === 'higher' ? 'Higher' : 'Changed'}</span></li>))}</ul>}
                  {plan.steps.length > 0 && <ul className="ct-steps">{plan.steps.map((s, i) => <li key={i}>{s}</li>)}</ul>}
                  {plan.blocked && <p className="alert alert--error" role="alert" data-testid="car-terms-blocked"><span>{plan.blocked}</span></p>}
                </div>)}
              {bad && <p className="alert alert--error" role="alert"><span>Check the amounts: dollars and cents (for example 450.00) and the management fee in % (for example 30).</span></p>}
              {a.res && !a.res.ok && <p className="alert alert--error" role="alert" data-testid="car-terms-error"><span>{a.res.message}</span></p>}
              <div className="row ct-actions">
                {!plan || plan.blocked ? <button type="button" className="btn btn--primary btn--sm" disabled={a.pending} onClick={() => review()} data-testid="car-terms-review">{a.pending ? 'Checking' : 'Review'}</button>
                  : <button type="button" className="btn btn--primary btn--sm" disabled={a.pending || (higher && !reason.trim())} onClick={confirm} data-testid="car-terms-confirm">{a.pending ? 'Saving' : c.state === 'signed' ? 'Confirm and notify the owner' : 'Save'}</button>}
                <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setEdit(false); setPlan(null); a.setRes(null); }}>Cancel</button>
              </div>
            </div>)}
        </td></tr>)}
      {hist && <tr className="ct-panel-row"><td colSpan={cols} data-label=""><History c={c} today={data.today} paths={paths} /></td></tr>}
    </>
  );
}

export function CarTermsTable({ data, paths, title = 'Cars and terms', testId = 'car-terms' }: { data: CarTermsData; paths: string[]; title?: string; testId?: string }) {
  const cars = data.cars;
  return (
    <section className="pt-card stack ct" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <div className="pt-card__head"><h2 className="d4" id={`${testId}-h`}>{title}</h2></div>
      <p className="small muted">Each car&apos;s own terms. Press Edit to change a car; Review shows what happens before anything is saved. History has every period and notice.</p>
      {cars.length ? (
        <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label={title}>
          <table className="ad-table ad-table--dense ad-table--cards ct-table">
            <thead><tr><th scope="col">Car</th><th scope="col" className="num">Insurance a month</th><th scope="col" className="num">Tracker a month</th><th scope="col" className="num">Management fee</th>
              <th scope="col" className="num">Install Fee</th><th scope="col">Mode</th><th scope="col">Since</th><th scope="col"><span className="vh">Actions</span></th></tr></thead>
            <tbody>{cars.map((c) => <Fragment key={c.vehicle_id}><Row c={c} data={data} paths={paths} /></Fragment>)}</tbody>
          </table>
        </div>
      ) : <p className="pt-empty muted">No cars yet.</p>}
    </section>
  );
}
