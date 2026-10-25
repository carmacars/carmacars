'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { when } from '@/features/agreement/model';
import { AddressLookup } from '@/features/forms/AddressFields';
import { editRenter } from '@/server/actions/offers';

// Correct a renter's details (migration 0132), from the renter's page or any booking: the name, email, phone, date of
// birth, home address (with the address lookup), licence and a staff note. A new email goes to the sign-in at once; the
// renter can be sent a link to set a password there. Another renter with that email is refused by name; the same phone
// is a warning. Each correction is kept with who, when and what changed.
export interface RenterForm {
  renter_id: string; may_edit: boolean;
  now: Record<'full_name' | 'email' | 'mobile' | 'date_of_birth' | 'address_line1' | 'address_line2' | 'city' | 'province' | 'postal_code' | 'licence_number' | 'licence_class' | 'licence_issuer' | 'licence_expiry' | 'staff_note', string | null>;
  edits: Array<{ at: string; by: string | null; reason: string | null; fields: string[]; before: Record<string, unknown>; after: Record<string, unknown> }>;
}
type K = keyof RenterForm['now'];
const LABEL: Record<K, string> = { full_name: 'Full legal name', email: 'Email', mobile: 'Phone', date_of_birth: 'Date of birth', address_line1: 'Home address', address_line2: 'Unit or line 2',
  city: 'City', province: 'Province', postal_code: 'Postal code', licence_number: 'Licence number', licence_class: 'Licence class', licence_issuer: 'Licence issued by', licence_expiry: 'Licence expiry', staff_note: 'Staff note' };

export function RenterEdit({ x, startOpen = false }: { x: RenterForm; startOpen?: boolean }) {
  const router = useRouter();
  const [open, setOpen] = useState(startOpen);
  const init = Object.fromEntries((Object.keys(LABEL) as K[]).map((k) => [k, x.now[k] ?? ''])) as Record<K, string>;
  const [f, setF] = useState<Record<K, string>>(init);
  const [reason, setReason] = useState('');
  const [sendLink, setSendLink] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  if (!x.may_edit && !x.edits.length) return null;
  const save = () => run(async () => {
    setMsg(null);
    const changed = (Object.keys(LABEL) as K[]).filter((k) => (f[k] ?? '').trim() !== (init[k] ?? '').trim());
    if (!changed.length) { setMsg({ ok: false, text: 'Nothing changed yet.' }); return; }
    const p: Record<string, unknown> = { renter: x.renter_id, reason: reason.trim() || undefined, send_link: sendLink };
    for (const k of changed) p[k] = f[k].trim();
    const r = await editRenter(p);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    const w = r.data.warnings?.length ? ` Note: ${r.data.warnings.map((y) => y.name).join(', ')} has the same phone.` : '';
    setMsg({ ok: true, text: `Saved.${r.data.email_changed ? ` The email is now ${r.data.email}${r.data.signin === 'updated' ? ', on the sign-in too' : ''}.${r.data.link_sent ? ' The renter has a link to set a password.' : ''}${r.data.signin?.startsWith('not') ? ` The sign-in was ${r.data.signin}.` : ''}` : ''}${w}` });
    setOpen(false); router.refresh();
  });
  const input = (k: K, type = 'text') => (
    <div className="field ad-field" key={k}><label className="label" htmlFor={`re-${k}`}>{LABEL[k]}</label>
      <input className="input" id={`re-${k}`} type={type} value={f[k]} onChange={(e) => setF((s) => ({ ...s, [k]: e.target.value }))} data-testid={`re-${k}`} /></div>);
  return (
    <section className="pt-card ad-card stack" aria-labelledby="re-h" data-testid="renter-edit">
      <div className="pt-card__head"><h2 className="d4" id="re-h">Renter details</h2>
        {x.may_edit && !open && <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(true)} data-testid="re-open">Edit renter</button>}</div>
      {!open && <p className="small">{x.now.full_name} · {x.now.email ?? 'no email'} · {x.now.mobile ?? 'no phone'}{x.now.staff_note ? ` · Note: ${x.now.staff_note}` : ''}</p>}
      {open && <div className="stack">
        <div className="ad-fields">
          {input('full_name')}{input('email', 'email')}{input('mobile', 'tel')}{input('date_of_birth', 'date')}
          {input('licence_number')}{input('licence_expiry', 'date')}{input('licence_class')}{input('licence_issuer')}
          <AddressLookup idp="re-home" label="Find the home address" onParts={(pp) => setF((s) => ({ ...s, ...(pp.street ? { address_line1: pp.street } : {}), ...(pp.unit ? { address_line2: `Unit ${pp.unit}` } : {}), ...(pp.city ? { city: pp.city } : {}), ...(pp.postal_code ? { postal_code: pp.postal_code } : {}) }))} />
          {input('address_line1')}{input('address_line2')}{input('city')}{input('province')}{input('postal_code')}
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="re-staff_note">Staff note (staff only)</label>
            <textarea className="input ad-textarea" id="re-staff_note" value={f.staff_note} onChange={(e) => setF((s) => ({ ...s, staff_note: e.target.value }))} data-testid="re-staff_note" /></div>
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="re-reason">Why (optional)</label><input className="input" id="re-reason" value={reason} onChange={(e) => setReason(e.target.value)} data-testid="re-reason" /></div>
        </div>
        {f.email.trim() !== (init.email ?? '') && <label className="check" htmlFor="re-link"><input id="re-link" type="checkbox" checked={sendLink} onChange={(e) => setSendLink(e.target.checked)} data-testid="re-link" /> <span>Email the renter a link to set a password at the new address</span></label>}
        <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={save} data-testid="re-save">{pending ? 'Saving' : 'Save the renter'}</button>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setOpen(false); setF(init); }}>Cancel</button></div>
      </div>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="re-msg"><span>{msg.text}</span></p>}
      {x.edits.length > 0 && <details data-testid="re-edits"><summary className="link small">Corrections ({x.edits.length})</summary>
        <ul className="stack small">{x.edits.map((e, i) => <li key={i}>{when(e.at)}{e.by ? `, ${e.by}` : ''}: {e.fields.map((k) => `${LABEL[k as K] ?? k} ${String(e.before[k] ?? 'none')} to ${String(e.after[k] ?? 'none')}`).join('; ')}{e.reason ? ` (${e.reason})` : ''}</li>)}</ul></details>}
    </section>
  );
}
