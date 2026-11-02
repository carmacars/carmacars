'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useDoor } from '@/features/admin/door';
import { TypedInput } from '@/components/DateInput';

// The insurer and adjuster on a booking at any status (migration 0183): an insurer replacement rental often starts as
// an ordinary booking and the claim arrives after pickup. Switching who pays prices the booking again.
// 0234: the insurer is picked or added by name; the adjuster is picked from the insurer's saved adjusters or added (a new
// one is saved with the insurer, so the next booking can pick them).
export interface InsurerClaimData {
  booking: string; bill_to: string; insurer_id: string | null; claim_number: string | null; adjuster_name: string | null; adjuster_email: string | null;
  adjuster_phone: string | null; policy_number: string | null; policy_province: string | null; authorized_days: number | null; authorized_until: string | null;
  authorized_daily_rate_cents: number | null;
  /** 0234: the insurer's adjuster this booking is billed to */
  adjuster_id?: string | null;
}
export type AdjusterOpt = { id: string; insurer_id: string; name: string | null; email: string | null; phone: string | null };
type K = 'bill_to' | 'insurer_id' | 'claim_number' | 'adjuster_name' | 'adjuster_email' | 'adjuster_phone' | 'policy_number' | 'policy_province' | 'authorized_days' | 'authorized_until' | 'authorized_daily_rate';
const BILL: Array<[string, string]> = [['renter', 'Renter'], ['insurer', 'Insurer pays rental and fees'], ['split', 'Insurer pays the rental only']];

export function InsurerClaimEdit({ x, insurers, adjusters = [] }: { x: InsurerClaimData; insurers: Array<{ id: string; name: string }>; adjusters?: AdjusterOpt[] }) {
  const router = useRouter();
  const { act } = useDoor();
  const init: Record<K, string> = {
    bill_to: x.bill_to, insurer_id: x.insurer_id ?? '', claim_number: x.claim_number ?? '', adjuster_name: x.adjuster_name ?? '', adjuster_email: x.adjuster_email ?? '',
    adjuster_phone: x.adjuster_phone ?? '', policy_number: x.policy_number ?? '', policy_province: x.policy_province ?? '', authorized_days: x.authorized_days?.toString() ?? '',
    authorized_until: x.authorized_until ?? '', authorized_daily_rate: x.authorized_daily_rate_cents == null ? '' : (x.authorized_daily_rate_cents / 100).toFixed(2),
  };
  const [open, setOpen] = useState(false);
  const [f, setF] = useState(init);
  const [reason, setReason] = useState('');
  const [insName, setInsName] = useState('');
  const initAdj = x.adjuster_id ?? (x.adjuster_name || x.adjuster_email ? 'new' : '');
  const [adj, setAdj] = useState<string>(initAdj);
  const mine = adjusters.filter((a) => a.insurer_id === f.insurer_id);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const set = (k: K) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));
  const save = () => run(async () => {
    setMsg(null);
    const changed = (Object.keys(init) as K[]).filter((k) => f[k].trim() !== init[k].trim());
    if (!changed.length && adj === initAdj && f.insurer_id !== 'new') { setMsg({ ok: false, text: 'Nothing changed yet.' }); return; }
    const p: Record<string, unknown> = { booking: x.booking };
    for (const k of changed) {
      if (k === 'authorized_daily_rate') p.authorized_daily_rate_cents = f[k].trim() ? Math.round(Number(f[k]) * 100) : '';
      else p[k] = f[k].trim();
    }
    if (changed.includes('bill_to') || changed.includes('insurer_id')) p.insurer_id = f.insurer_id;
    if (f.insurer_id === 'new') { if (!insName.trim()) { setMsg({ ok: false, text: 'Type the insurer\'s name.' }); return; } p.insurer_id = 'new'; p.insurer_name = insName.trim(); }
    // a saved adjuster goes by id (the booking takes their details); a new one by the fields typed
    if (adj && adj !== 'new') { p.adjuster_id = adj; delete p.adjuster_name; delete p.adjuster_email; delete p.adjuster_phone; }
    else if (adj === '' && initAdj !== '') { p.adjuster_id = ''; }
    if (reason.trim()) p.reason = reason.trim();
    const r = await act('booking_insurer_save', p, [`/admin/bookings/${x.booking}`]);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: 'Saved.' }); setOpen(false); router.refresh();
  });
  const input = (k: K, l: string, type = 'text') => (
    <div className="field ad-field" key={k}><label className="label" htmlFor={`ic-${k}`}>{l}</label>
      <TypedInput className="input" id={`ic-${k}`} type={type} value={f[k]} onChange={set(k)} data-testid={`ic-${k}`} /></div>);
  const insurerName = insurers.find((i) => i.id === x.insurer_id)?.name;
  // a booking billed to the renter: only the way to start billing an insurer, no card
  if (x.bill_to === 'renter' && !open) {
    return <p className="small"><button className="btn btn--ghost btn--sm" type="button" onClick={() => { setOpen(true); setF((s) => ({ ...s, bill_to: 'insurer' })); }} data-testid="ic-bill-insurer">Bill an insurer instead</button></p>;
  }
  return (
    <section className="pt-card ad-card stack" aria-labelledby="ic-h" data-testid="insurer-claim-edit">
      <div className="pt-card__head"><h2 className="d4" id="ic-h">Insurance claim and adjuster</h2>
        {!open && <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(true)} data-testid="ic-open">Edit</button>}</div>
      {!open && <p className="small">
        {x.bill_to === 'renter' ? 'Billed to the renter.' : `Billed to ${insurerName ?? 'the insurer'}${x.bill_to === 'split' ? ' (the rental only)' : ''}.`}
        {x.claim_number ? ` Claim ${x.claim_number}.` : ''}{x.adjuster_name ? ` Adjuster ${x.adjuster_name}` : ''}{x.adjuster_phone ? `, ${x.adjuster_phone}` : ''}{x.adjuster_email ? `, ${x.adjuster_email}` : ''}
        {!x.claim_number && !x.adjuster_name && x.bill_to === 'renter' ? ' No claim recorded.' : ''}</p>}
      {open && <div className="stack">
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="ic-bill_to">Bill to</label>
            <select className="input" id="ic-bill_to" value={f.bill_to} onChange={set('bill_to')} data-testid="ic-bill_to">{BILL.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
          <div className="field ad-field"><label className="label" htmlFor="ic-insurer_id">Insurer</label>
            <select className="input" id="ic-insurer_id" value={f.insurer_id} onChange={set('insurer_id')} data-testid="ic-insurer_id">
              <option value="">Choose</option>{insurers.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}<option value="new">Not listed: add it</option></select></div>
          {f.insurer_id === 'new' && <div className="field ad-field"><label className="label" htmlFor="ic-insurer_name">Insurer&apos;s name</label>
            <input className="input" id="ic-insurer_name" value={insName} onChange={(e) => setInsName(e.target.value)} data-testid="ic-insurer_name" /></div>}
          {input('claim_number', 'Claim number')}
          <div className="field ad-field"><label className="label" htmlFor="ic-adjuster">Adjuster</label>
            <select className="input" id="ic-adjuster" value={adj} onChange={(e) => setAdj(e.target.value)} data-testid="ic-adjuster">
              <option value="">None yet</option>{mine.map((a) => <option key={a.id} value={a.id}>{a.name ?? a.email}{a.name && a.email ? ` (${a.email})` : ''}</option>)}
              <option value="new">{mine.length ? 'Another adjuster: add them' : 'Add the adjuster'}</option></select></div>
          {adj === 'new' && <>{input('adjuster_name', 'Adjuster\'s name')}{input('adjuster_phone', 'Adjuster\'s phone', 'tel')}{input('adjuster_email', 'Adjuster\'s email', 'email')}</>}
          {input('policy_number', 'Policy number')}
          {input('policy_province', 'Policy province')}
          {input('authorized_daily_rate', 'Authorized daily rate ($, empty: the rate sheet)', 'number')}
          {input('authorized_days', 'Authorized days', 'number')}
          {input('authorized_until', 'Authorized until', 'date')}
          <div className="field ad-field"><label className="label" htmlFor="ic-reason">Reason (needed when the rate differs from the rate sheet)</label>
            <input className="input" id="ic-reason" value={reason} onChange={(e) => setReason(e.target.value)} data-testid="ic-reason" /></div>
        </div>
        {f.bill_to !== init.bill_to && <p className="small" role="note">Changing who pays prices the booking again: the insurer&apos;s share and the renter&apos;s share are recalculated.</p>}
        <div className="row"><button className="btn btn--sm" type="button" disabled={pending} onClick={save} data-testid="ic-save">Save</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setF(init); setOpen(false); setMsg(null); }}>Cancel</button></div>
      </div>}
      {msg && <p className={`small${msg.ok ? '' : ' form-error'}`} role="status" data-testid="ic-msg">{msg.text}</p>}
    </section>
  );
}
