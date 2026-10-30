'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { offersDo } from '@/server/actions/offers';
import { InsurerFeesFields } from './InsurerFeesFields';
import { INSURER_FEES, insurerFeesPayload, rateProblem, typedFrom } from './fees';

// The booking's charges to the insurer (migration 0191), on its Insurance replacement card: each with its rate a day, the
// days and the amount; staff change them here (before or after confirmation, until the booking is closed). The database
// records each change and reprices the booking and the insurer's share.
export interface InsurerFeeRow { code: string; label: string; rate_cents: number | null; days: number; amount_cents: number | null; hst_cents: number | null }

export function InsurerFeesCard({ booking, fees, editable }: { booking: string; fees: InsurerFeeRow[]; editable: boolean }) {
  const router = useRouter();
  const before = Object.fromEntries(fees.filter((f) => f.rate_cents).map((f) => [f.code, f.rate_cents!]));
  const [edit, setEdit] = useState(false);
  const [typed, setTyped] = useState<Record<string, string>>(() => typedFrom(before));
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const fmt = (c: number) => money(c, { cents: true });
  const days = fees[0]?.days ?? 0;
  const on = fees.filter((f) => f.rate_cents);
  const save = () => run(async () => {
    setMsg(null);
    if (INSURER_FEES.some((f) => rateProblem(typed[f.code]))) { setMsg({ ok: false, text: 'Type each rate a day in dollars and cents, or leave it empty.' }); return; }
    const p = insurerFeesPayload(typed, before);
    if (!Object.keys(p).length) { setMsg({ ok: false, text: 'Nothing changed yet.' }); return; }
    const r = await offersDo<{ total_cents: number; total_before_cents: number }>('insurer_fees_set', { booking, fees: p, reason: reason.trim() || undefined }, [`/admin/bookings/${booking}`]);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Saved. Total ${fmt(r.data.total_before_cents)} to ${fmt(r.data.total_cents)}.` });
    setEdit(false); setReason(''); router.refresh();
  });
  return (
    <div className="stack" data-testid="booking-insurer-fees">
      <h3 className="small"><b>Charges to the insurer</b></h3>
      {on.length === 0 ? <p className="small muted">None on this booking (VLF, LDW, T&amp;LDW, PAP/PEC, Waiver Saver).</p> : (
        <table className="ad-table"><caption className="sr-only">Charges to the insurer</caption>
          <thead><tr><th scope="col">Charge</th><th scope="col" className="num">A day</th><th scope="col" className="num">Days</th><th scope="col" className="num">Amount</th></tr></thead>
          <tbody>{on.map((f) => <tr key={f.code} data-testid={`booking-insurer-fee-${f.code}`}><td>{f.label}</td><td className="num">{fmt(f.rate_cents!)}</td><td className="num">{f.days}</td>
            <td className="num">{fmt(f.amount_cents ?? 0)}</td></tr>)}</tbody></table>)}
      {editable && !edit && <p><button className="btn btn--ghost btn--sm" type="button" onClick={() => { setTyped(typedFrom(before)); setEdit(true); }} data-testid="booking-insurer-fees-edit">{on.length ? 'Change the charges' : 'Add a charge'}</button></p>}
      {edit && <div className="stack">
        <div className="ad-fields"><InsurerFeesFields idPrefix="bi" value={typed} onChange={(k, x) => setTyped((t) => ({ ...t, [k]: x }))} days={days} disabled={pending} /></div>
        <div className="field"><label className="label" htmlFor="bi-fee-reason">Reason (optional)</label><input className="input" id="bi-fee-reason" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
        <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={save} data-testid="booking-insurer-fees-save">{pending ? 'Saving' : 'Save the charges'}</button>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setEdit(false); setMsg(null); }}>Cancel</button></div></div>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
