'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useDoor } from '@/features/admin/door';

// The insurer and adjuster on a booking at any status (migration 0183): an insurer replacement rental often starts as
// an ordinary booking and the claim arrives after pickup. Switching who pays prices the booking again.
export interface InsurerClaimData {
  booking: string; bill_to: string; insurer_id: string | null; claim_number: string | null; adjuster_name: string | null; adjuster_email: string | null;
  adjuster_phone: string | null; policy_number: string | null; policy_province: string | null; authorized_days: number | null; authorized_until: string | null;
  authorized_daily_rate_cents: number | null;
  /** 0195: the VLF a day of this booking (null: the program setting, vlf_default_cents) */
  vlf_daily_cents?: number | null; vlf_default_cents?: number | null;
}
type K = 'bill_to' | 'insurer_id' | 'claim_number' | 'adjuster_name' | 'adjuster_email' | 'adjuster_phone' | 'policy_number' | 'policy_province' | 'authorized_days' | 'authorized_until' | 'authorized_daily_rate' | 'vlf_daily';
const BILL: Array<[string, string]> = [['renter', 'Renter'], ['insurer', 'Insurer pays rental and fees'], ['split', 'Insurer pays the rental only']];

export function InsurerClaimEdit({ x, insurers }: { x: InsurerClaimData; insurers: Array<{ id: string; name: string }> }) {
  const router = useRouter();
  const { act } = useDoor();
  const init: Record<K, string> = {
    bill_to: x.bill_to, insurer_id: x.insurer_id ?? '', claim_number: x.claim_number ?? '', adjuster_name: x.adjuster_name ?? '', adjuster_email: x.adjuster_email ?? '',
    adjuster_phone: x.adjuster_phone ?? '', policy_number: x.policy_number ?? '', policy_province: x.policy_province ?? '', authorized_days: x.authorized_days?.toString() ?? '',
    authorized_until: x.authorized_until ?? '', authorized_daily_rate: x.authorized_daily_rate_cents == null ? '' : (x.authorized_daily_rate_cents / 100).toFixed(2),
    vlf_daily: x.vlf_daily_cents == null ? '' : (x.vlf_daily_cents / 100).toFixed(2),
  };
  const [open, setOpen] = useState(false);
  const [f, setF] = useState(init);
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const set = (k: K) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));
  const save = () => run(async () => {
    setMsg(null);
    const changed = (Object.keys(init) as K[]).filter((k) => f[k].trim() !== init[k].trim());
    if (!changed.length) { setMsg({ ok: false, text: 'Nothing changed yet.' }); return; }
    const p: Record<string, unknown> = { booking: x.booking };
    for (const k of changed) {
      if (k === 'authorized_daily_rate') p.authorized_daily_rate_cents = f[k].trim() ? Math.round(Number(f[k]) * 100) : '';
      else if (k === 'vlf_daily') p.vlf_daily_cents = f[k].trim() ? Math.round(Number(f[k]) * 100) : '';
      else p[k] = f[k].trim();
    }
    if (changed.includes('bill_to') || changed.includes('insurer_id')) p.insurer_id = f.insurer_id;
    if (reason.trim()) p.reason = reason.trim();
    const r = await act('booking_insurer_save', p, [`/admin/bookings/${x.booking}`]);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: 'Saved.' }); setOpen(false); router.refresh();
  });
  const input = (k: K, l: string, type = 'text') => (
    <div className="field ad-field" key={k}><label className="label" htmlFor={`ic-${k}`}>{l}</label>
      <input className="input" id={`ic-${k}`} type={type} value={f[k]} onChange={set(k)} data-testid={`ic-${k}`} /></div>);
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
        {x.claim_number ? ` Claim ${x.claim_number}.` : ''}
        {x.bill_to !== 'renter' && (x.vlf_daily_cents ?? x.vlf_default_cents) ? ` VLF $${((x.vlf_daily_cents ?? x.vlf_default_cents ?? 0) / 100).toFixed(2)} a day.` : ''}{x.adjuster_name ? ` Adjuster ${x.adjuster_name}` : ''}{x.adjuster_phone ? `, ${x.adjuster_phone}` : ''}{x.adjuster_email ? `, ${x.adjuster_email}` : ''}
        {!x.claim_number && !x.adjuster_name && x.bill_to === 'renter' ? ' No claim recorded.' : ''}</p>}
      {open && <div className="stack">
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="ic-bill_to">Bill to</label>
            <select className="input" id="ic-bill_to" value={f.bill_to} onChange={set('bill_to')} data-testid="ic-bill_to">{BILL.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
          <div className="field ad-field"><label className="label" htmlFor="ic-insurer_id">Insurer</label>
            <select className="input" id="ic-insurer_id" value={f.insurer_id} onChange={set('insurer_id')} data-testid="ic-insurer_id">
              <option value="">Choose</option>{insurers.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}</select></div>
          {input('claim_number', 'Claim number')}
          {input('adjuster_name', 'Adjuster')}
          {input('adjuster_phone', 'Adjuster phone', 'tel')}
          {input('adjuster_email', 'Adjuster email', 'email')}
          {input('policy_number', 'Policy number')}
          {input('policy_province', 'Policy province')}
          {input('authorized_daily_rate', 'Authorized daily rate ($, empty: the rate sheet)', 'number')}
          {input('authorized_days', 'Authorized days', 'number')}
          {f.bill_to !== 'renter' && input('vlf_daily', `VLF a day ($, billed to the insurer; empty: the default${x.vlf_default_cents ? ` $${(x.vlf_default_cents / 100).toFixed(2)}` : ', none'})`, 'number')}
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
