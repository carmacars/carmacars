'use client';
import { useEffect, useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { salesAskCommission, salesInviteOwner } from '@/server/actions/sales-owners';
import type { OwnerRequest } from './SalesOwners';

// The buttons of Owners you bring in (migration 0340): invite an owner, copy the personal link, ask for a commission. Each
// form opens in a dialog and says what happened in a line under the button.
type Res = { ok: true; data: unknown } | { ok: false; message: string; fieldErrors?: Record<string, string> } | null;

function Dialog({ open, title, idp, close, children }: { open: boolean; title: string; idp: string; close: () => void; children: React.ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { const el = ref.current; if (!el) return; if (open && !el.open) el.showModal(); if (!open && el.open) el.close(); }, [open]);
  return (
    <dialog ref={ref} className="ad-dialog so-dialog" aria-labelledby={`${idp}-t`} onClose={close}>
      <h2 className="d4" id={`${idp}-t`}>{title}</h2>
      {children}
    </dialog>
  );
}

function Field({ id, label, err, hint, children }: { id: string; label: string; err?: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className={`field${err ? ' has-error' : ''}`}>
      <label className="label" htmlFor={id}>{label}</label>{children}
      {hint && <p className="hint" id={`${id}-h`}>{hint}</p>}
      <p className="error" role="alert" id={`${id}-e`}>{err ?? ''}</p>
    </div>
  );
}

export function InviteOwner() {
  const idp = `inv-${useId().replace(/[^\w-]/g, '')}`;
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [v, setV] = useState({ name: '', email: '', phone: '', asked: false });
  const [res, setRes] = useState<Res>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const err = (k: string) => (res && !res.ok ? res.fieldErrors?.[k] : undefined);
  const send = () => start(async () => {
    const r = await salesInviteOwner(v);
    setRes(r as Res);
    if (r.ok) { setOpen(false); setDone(`Invitation sent to ${r.data.email}.`); setV({ name: '', email: '', phone: '', asked: false }); router.refresh(); }
  });
  return (
    <>
      <button type="button" className="btn btn--sm btn--primary" aria-haspopup="dialog" onClick={() => { setRes(null); setDone(null); setOpen(true); }} data-testid="so-invite-open">Invite an owner</button>
      {done && <span className="small so-done" role="status" data-testid="so-invite-done">{done}</span>}
      <Dialog open={open} title="Invite an owner" idp={idp} close={() => setOpen(false)}>
        <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); send(); }} data-testid="so-invite-form">
          <p className="small muted">They get an email with your link to apply. The application is credited to you.</p>
          <div className="ad-fields">
            <Field id={`${idp}-n`} label="Owner's name" err={err('name')}><input className="input" id={`${idp}-n`} autoComplete="off" value={v.name} onChange={(e) => setV({ ...v, name: e.target.value })} data-testid="so-invite-name" aria-describedby={`${idp}-n-e`} /></Field>
            <Field id={`${idp}-e`} label="Email" err={err('email')}><input className="input" id={`${idp}-e`} type="email" inputMode="email" autoComplete="off" value={v.email} onChange={(e) => setV({ ...v, email: e.target.value })} data-testid="so-invite-email" aria-describedby={`${idp}-e-e`} /></Field>
            <Field id={`${idp}-p`} label="Phone (optional)"><input className="input" id={`${idp}-p`} type="tel" inputMode="tel" autoComplete="off" value={v.phone} onChange={(e) => setV({ ...v, phone: e.target.value })} data-testid="so-invite-phone" /></Field>
          </div>
          <label className={`check${err('asked') ? ' has-error' : ''}`} htmlFor={`${idp}-a`}><input type="checkbox" id={`${idp}-a`} checked={v.asked} onChange={(e) => setV({ ...v, asked: e.target.checked })} data-testid="so-invite-asked" />
            <span>The owner asked me to send it</span></label>
          {err('asked') && <p className="error" role="alert">{err('asked')}</p>}
          {res && !res.ok && !res.fieldErrors && <p className="alert alert--error" role="alert"><span>{res.message}</span></p>}
          <div className="row"><button className="btn btn--sm btn--primary" type="submit" disabled={pending} data-testid="so-invite-send">{pending ? 'Sending' : 'Send the invitation'}</button>
            <button className="btn btn--sm btn--ghost" type="button" onClick={() => setOpen(false)}>Cancel</button></div>
        </form>
      </Dialog>
    </>
  );
}

export function CopyLink({ url }: { url: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button type="button" className="btn btn--sm btn--ghost" data-testid="so-copy-link" title={url}
      onClick={() => { void navigator.clipboard?.writeText(url).then(() => { setCopied(true); setTimeout(() => setCopied(false), 2500); }); }}>
      {copied ? 'Link copied' : 'Copy my owner link'}
    </button>
  );
}

const money = (c: number | null | undefined) => (c ? (c / 100).toFixed(2).replace(/\.00$/, '') : '');
const pct = (b: number | null | undefined) => (b ? String(b / 100) : '');

export function AskCommission({ ownerId, ownerName, current }: { ownerId: string; ownerName: string; current: OwnerRequest | null }) {
  const idp = `ask-${useId().replace(/[^\w-]/g, '')}`;
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState<'flat' | 'percent'>(current?.kind ?? 'flat');
  const [amount, setAmount] = useState(money(current?.amount_cents));
  const [rate, setRate] = useState(pct(current?.rate_bps));
  const [base, setBase] = useState<string>(current?.base ?? 'company_share');
  const [duration, setDuration] = useState<'months' | 'while'>(current?.while_enrolled ? 'while' : 'months');
  const [months, setMonths] = useState(current?.months ? String(current.months) : '');
  const [note, setNote] = useState(current?.note ?? '');
  const [res, setRes] = useState<Res>(null);
  const [pending, start] = useTransition();
  const send = () => start(async () => {
    const n = (s: string) => Number(s.replace(/[$,%\s]/g, ''));
    const r = await salesAskCommission(kind === 'flat'
      ? { owner_id: ownerId, kind, amount_cents: Math.round(n(amount) * 100), note }
      : { owner_id: ownerId, kind, rate_bps: Math.round(n(rate) * 100), base, duration, months: duration === 'months' ? n(months) : undefined, note });
    setRes(r as Res);
    if (r.ok) { setOpen(false); router.refresh(); }
  });
  return (
    <>
      <button type="button" className="btn btn--sm btn--ghost" aria-haspopup="dialog" onClick={() => { setRes(null); setOpen(true); }} data-testid={`so-ask-${ownerId}`}>{current ? 'Change my request' : 'Ask for a commission'}</button>
      <Dialog open={open} title={`Commission for ${ownerName}`} idp={idp} close={() => setOpen(false)}>
        <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); send(); }} data-testid="so-ask-form">
          <fieldset className="so-kind"><legend className="label">What you ask for</legend>
            <label className="check" htmlFor={`${idp}-f`}><input type="radio" id={`${idp}-f`} name={`${idp}-k`} checked={kind === 'flat'} onChange={() => setKind('flat')} data-testid="so-ask-flat" /><span>A flat amount</span></label>
            <label className="check" htmlFor={`${idp}-p`}><input type="radio" id={`${idp}-p`} name={`${idp}-k`} checked={kind === 'percent'} onChange={() => setKind('percent')} data-testid="so-ask-percent" /><span>A percent</span></label>
          </fieldset>
          <div className="ad-fields">
            {kind === 'flat' ? (
              <Field id={`${idp}-a`} label="Amount (CA$)" hint="Paid once, at the owner's first paid rental."><input className="input" id={`${idp}-a`} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} data-testid="so-ask-amount" aria-describedby={`${idp}-a-h`} /></Field>
            ) : (<>
              <Field id={`${idp}-r`} label="Percent (%)"><input className="input" id={`${idp}-r`} inputMode="decimal" value={rate} onChange={(e) => setRate(e.target.value)} data-testid="so-ask-rate" /></Field>
              <Field id={`${idp}-b`} label="Of"><select className="select" id={`${idp}-b`} value={base} onChange={(e) => setBase(e.target.value)} data-testid="so-ask-base">
                <option value="company_share">The company&apos;s share of their cars&apos; rentals</option><option value="car_revenue">Their cars&apos; rental revenue</option></select></Field>
              <Field id={`${idp}-d`} label="For how long"><select className="select" id={`${idp}-d`} value={duration} onChange={(e) => setDuration(e.target.value as 'months' | 'while')} data-testid="so-ask-duration">
                <option value="months">A number of months</option><option value="while">As long as the car is with us</option></select></Field>
              {duration === 'months' && <Field id={`${idp}-m`} label="Months"><input className="input" id={`${idp}-m`} inputMode="numeric" value={months} onChange={(e) => setMonths(e.target.value)} data-testid="so-ask-months" /></Field>}
            </>)}
          </div>
          <Field id={`${idp}-o`} label="Note for the Admin (optional)"><textarea className="input ad-textarea" rows={2} maxLength={1000} id={`${idp}-o`} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
          {res && !res.ok && <p className="alert alert--error" role="alert" data-testid="so-ask-error"><span>{res.message}</span></p>}
          <div className="row"><button className="btn btn--sm btn--primary" type="submit" disabled={pending} data-testid="so-ask-send">{pending ? 'Sending' : current ? 'Update my request' : 'Send to an Admin'}</button>
            <button className="btn btn--sm btn--ghost" type="button" onClick={() => setOpen(false)}>Cancel</button></div>
        </form>
      </Dialog>
    </>
  );
}
