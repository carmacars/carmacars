'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { addCosigner, countersignInvestment, removeCosigner, resendCosigner } from '@/server/actions/legal';

// The legal review (migration 0053): every Owner named in the Title Schedule signs with their own link, and an investment
// agreement is countersigned by the signing officer here, never automatically.
export interface CosignerRow { id: string; name: string; email: string; status: 'pending' | 'signed'; link_sent_at: string | null; link_sent_count: number; signed_at: string | null }
const day = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso)) : '');

export function Cosigners({ ownerId, ownerName, rows, locked }: { ownerId: string; ownerName: string; rows: CosignerRow[]; locked: boolean }) {
  const router = useRouter();
  const a = useAct();
  const uid = `cs-${useId().replace(/[^\w-]/g, '')}`;
  const [open, setOpen] = useState(false);
  return (
    <div className="stack" data-testid="owner-cosigners">
      <p className="small">{ownerName} signs in the owner portal. Each other Owner named in the Title Schedule (a co-owner, or the person beside an Owner Corporation) signs with their own link, sent by email when the documents open. The agreements take effect when the last Owner signs.</p>
      {rows.length ? <ul className="small">{rows.map((r) => (
        <li key={r.id} data-testid="cosigner-row">{r.name} ({r.email}): {r.status === 'signed' ? `signed ${day(r.signed_at)}` : r.link_sent_at ? `link sent ${day(r.link_sent_at)}${r.link_sent_count > 1 ? `, ${r.link_sent_count} times` : ''}` : 'link not sent yet (sent when the documents open)'}
          {r.status === 'pending' && <> <button type="button" className="btn btn--quiet btn--sm" disabled={a.pending} onClick={() => a.run(() => resendCosigner(ownerId, r.id), () => router.refresh())}>Send the link again</button>
            <button type="button" className="btn btn--quiet btn--sm" disabled={a.pending} onClick={() => { const why = window.prompt(`Why is ${r.name} removed?`); if (why) a.run(() => removeCosigner(ownerId, r.id, why), () => router.refresh()); }}>Remove</button></>}
        </li>))}</ul> : <p className="small muted">No other Owner on file.</p>}
      {!locked && (open ? (
        <form className="stack pt-sheet" noValidate aria-label="Add an Owner" onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); a.run(() => addCosigner(ownerId, fd), (r) => { if (r.ok) { setOpen(false); router.refresh(); } }); }}>
          <div className="field-row">
            <div className={`field${a.err('name') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-n`}>Full legal name</label><input className="input" id={`${uid}-n`} name="name" autoComplete="off" /><p className="error" role="alert">{a.err('name') ?? ''}</p></div>
            <div className={`field${a.err('email') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-e`}>Email</label><input className="input" id={`${uid}-e`} name="email" type="email" autoComplete="off" /><p className="error" role="alert">{a.err('email') ?? ''}</p></div>
          </div>
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending} data-testid="cosigner-add">{a.pending ? 'Adding' : 'Add the Owner'}</button><button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button></div>
        </form>) : <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)} data-testid="cosigner-open">Add an Owner</button>)}
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
    </div>
  );
}

export interface CountersignRow { agreement_id: string; agreement_number: string; status: string; company_signed_at: string | null; awaiting_countersignature: boolean; signing_officer: string | null; may_countersign: boolean }

export function InvestmentCountersign({ investorId, rows }: { investorId: string; rows: CountersignRow[] }) {
  const router = useRouter();
  const a = useAct();
  if (!rows.length) return null;
  return (
    <div className="stack" data-testid="investment-countersign">
      {rows.map((r) => (
        <p key={r.agreement_id} className="small">Agreement {r.agreement_number}: {r.awaiting_countersignature
          ? <><b data-testid="awaiting-countersignature">Awaiting countersignature</b> by the signing officer{r.signing_officer ? ` (${r.signing_officer})` : ''}. It is fully signed only then. {r.may_countersign && (
            <button type="button" className="btn btn--primary btn--sm" disabled={a.pending} data-testid="countersign"
              onClick={() => { if (window.confirm(`Countersign agreement ${r.agreement_number} for the company${r.signing_officer ? `, as ${r.signing_officer}` : ''}?`)) a.run(() => countersignInvestment(investorId, r.agreement_id), () => router.refresh()); }}>Countersign</button>)}</>
          : r.company_signed_at ? <span data-testid="countersigned">Countersigned on {day(r.company_signed_at)}. Fully signed.</span> : r.status === 'sent' ? 'Sent to the investor to sign.' : r.status}</p>
      ))}
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
    </div>
  );
}
