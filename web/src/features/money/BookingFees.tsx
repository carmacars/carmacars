'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { offersDo } from '@/server/actions/offers';
import { cents } from '@/features/offers/model';
import { BalanceActions } from './BalanceActions';

// The fees of a booking, each changeable on its own (migration 0132): young driver, Protection Plan, delivery and pickup,
// winter tires, baby seats, each add-on. Before or after confirmation; the change is recorded with who, when, before and
// after, and the booking's money follows (more to collect, or less). An Admin, and customer service and sales while
// Program settings let staff change fees; the database decides and refuses with the reason.
export interface Fees {
  booking_number: string; status: string; may_edit: boolean; total_cents: number; open_cents: number;
  lines: Array<{ key: string; label: string; amount_cents: number; hst_cents: number; set_by_hand: boolean; reason: string | null; paid: boolean }>;
  addable: Array<{ key: string; label: string; suggested_cents?: number | null }>;
  parts?: { rental: number; fees: number; balance: number }; card?: { brand: string; last4: string } | null; renter_reach?: { email: boolean; mobile: boolean } | null;
  history: Array<{ label: string; before_cents: number | null; after_cents: number | null; reason: string | null; status: string; by: string | null; at: string }>;
}
const fmt = (c: number | null | undefined) => (c === null || c === undefined ? 'none' : money(Number(c), { cents: true }));

export function BookingFees({ x }: { x: Fees }) {
  const router = useRouter();
  const [edit, setEdit] = useState(false);
  const [typed, setTyped] = useState<Record<string, string>>({});
  const [add, setAdd] = useState('');
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const [own, setOwn] = useState({ label: '', amount: '', hst: true });
  const [why, setWhy] = useState<string | undefined>(undefined);
  const addOwn = () => run(async () => {
    setMsg(null);
    const r = await offersDo<{ total_cents: number; open_cents: number }>('booking_custom_fee', { booking: x.booking_number, label: own.label, amount_cents: cents(own.amount), hst: own.hst, reason: reason.trim() || undefined });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setWhy(`${own.label} added`); setMsg({ ok: true, text: `Added. Total ${fmt(r.data.total_cents)}.` }); setOwn({ label: '', amount: '', hst: true }); router.refresh();
  });
  const changed = Object.entries(typed).filter(([, v]) => v.trim() !== '' && cents(v) !== null);
  const save = () => run(async () => {
    setMsg(null);
    if (!changed.length) { setMsg({ ok: false, text: 'Type the new amount of at least one fee.' }); return; }
    const lines = Object.fromEntries(changed.map(([k, v]) => [k, cents(v)]));
    const r = await offersDo<{ changes: unknown[]; total_cents: number; total_before_cents: number; open_cents: number }>('booking_fees_change', { booking: x.booking_number, lines, reason: reason.trim() || undefined });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Saved. Total ${fmt(r.data.total_before_cents)} to ${fmt(r.data.total_cents)}; ${r.data.open_cents > 0 ? `${fmt(r.data.open_cents)} to collect.` : 'nothing more to collect.'}` });
    setWhy(changed.map(([k, v]) => `${rows.find((l) => l.key === k)?.label ?? k} ${fmt(cents(v))}`).join(', '));
    setTyped({}); setReason(''); setEdit(false); setAdd(''); router.refresh();
  });
  const reset = (k: string) => run(async () => {
    const r = await offersDo('booking_fees_change', { booking: x.booking_number, lines: { [k]: null }, reason: 'Back to the computed amount' });
    setMsg(r.ok ? { ok: true, text: 'Back to the computed amount.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  const rows = [...x.lines, ...(add ? [{ key: add, label: x.addable.find((a) => a.key === add)?.label ?? add, amount_cents: 0, hst_cents: 0, set_by_hand: false, reason: null, paid: false }] : [])];
  return (
    <section className="pt-card ad-card stack" aria-labelledby="bf-h" data-testid="booking-fees">
      <div className="pt-card__head"><h2 className="d4" id="bf-h">Fees</h2>
        {x.may_edit && !edit && <button className="btn btn--ghost btn--sm" type="button" onClick={() => setEdit(true)} data-testid="bf-edit">Change or add a fee</button>}</div>
      {rows.length === 0 ? <p className="small muted">No fees on this booking.</p> : (
        <table className="ad-table" data-testid="bf-lines"><caption className="sr-only">Fees</caption>
          <thead><tr><th scope="col">Fee</th><th scope="col" className="num">Amount</th>{edit && <th scope="col">New amount ($)</th>}</tr></thead>
          <tbody>{rows.map((l) => (
            <tr key={l.key} data-testid={`bf-line-${l.key}`}>
              <td>{l.label}{l.set_by_hand ? <span className="small muted"> (set by hand{l.reason ? `: ${l.reason}` : ''})</span> : null}{l.paid ? <span className="small muted"> · paid</span> : null}
                {edit && l.set_by_hand && <> <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => reset(l.key)}>Back to computed</button></>}</td>
              <td className="num">{fmt(l.amount_cents)}</td>
              {edit && <td><input className="input input--sm" inputMode="decimal" aria-label={`${l.label}: new amount ($)`} placeholder={(l.amount_cents / 100).toFixed(2)} value={typed[l.key] ?? ''}
                onChange={(e) => setTyped((t) => ({ ...t, [l.key]: e.target.value }))} data-testid={`bf-fee-${l.key}`} /></td>}
            </tr>))}</tbody></table>)}
      {edit && <div className="stack">
        {x.addable.length > 0 && !add && <div className="field"><label className="label" htmlFor="bf-add">Add a fee not on the booking</label>
          <select className="select" id="bf-add" value={add} onChange={(e) => { const k = e.target.value; setAdd(k); const sug = x.addable.find((a) => a.key === k)?.suggested_cents; if (k && sug) setTyped((t) => ({ ...t, [k]: (sug / 100).toFixed(2) })); }} data-testid="bf-add"><option value="">Choose</option>{x.addable.map((a) => <option key={a.key} value={a.key}>{a.label}{a.suggested_cents ? ` (${fmt(a.suggested_cents)} for these dates)` : ''}</option>)}</select></div>}
        <fieldset className="stack" data-testid="bf-own"><legend className="small"><b>Or a charge of its own</b> (the renter sees what you type)</legend>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="bf-own-label">What it is for</label><input className="input" id="bf-own-label" value={own.label} onChange={(e) => setOwn((o) => ({ ...o, label: e.target.value }))} data-testid="bf-own-label" /></div>
            <div className="field ad-field"><label className="label" htmlFor="bf-own-amount">Amount before HST ($)</label><input className="input" id="bf-own-amount" inputMode="decimal" value={own.amount} onChange={(e) => setOwn((o) => ({ ...o, amount: e.target.value }))} data-testid="bf-own-amount" /></div>
          </div>
          <label className="check" htmlFor="bf-own-hst"><input id="bf-own-hst" type="checkbox" checked={own.hst} onChange={(e) => setOwn((o) => ({ ...o, hst: e.target.checked }))} /> <span>Plus HST</span></label>
          <p><button className="btn btn--ghost btn--sm" type="button" disabled={pending || !own.label.trim() || !cents(own.amount)} onClick={addOwn} data-testid="bf-own-add">Add the charge</button></p>
        </fieldset>
        <div className="field"><label className="label" htmlFor="bf-reason">Reason (optional)</label><input className="input" id="bf-reason" value={reason} onChange={(e) => setReason(e.target.value)} data-testid="bf-reason" /></div>
        <p className="small muted">Amounts before HST. {['confirmed', 'on_rent', 'returned'].includes(x.status) ? 'The booking is confirmed: a higher fee is more to collect on the Money tab; a lower one leaves a credit to refund.' : 'The offer and the price follow.'}</p>
        <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={save} data-testid="bf-save">{pending ? 'Saving' : 'Save the fees'}</button>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setEdit(false); setTyped({}); setAdd(''); }}>Cancel</button></div></div>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="bf-msg"><span>{msg.text}</span></p>}
      {x.parts && <BalanceActions booking={x.booking_number} open={x.parts.balance} rental={x.parts.rental} fees={x.parts.fees} card={x.card} reach={x.renter_reach} why={why} />}
      {x.history.length > 0 && <details data-testid="bf-history"><summary className="link small">Changes to the fees ({x.history.length})</summary>
        <ul className="stack small">{x.history.map((h, i) => <li key={i}>{when(h.at)}: {h.label} {fmt(h.before_cents)} to {fmt(h.after_cents)}{h.by ? `, by ${h.by}` : ''}{h.reason ? ` (${h.reason})` : ''}, booking {h.status.replace(/_/g, ' ')}</li>)}</ul></details>}
    </section>
  );
}
