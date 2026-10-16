'use client';
import { useId, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { createSignRequest, voidSignRequest } from '@/server/actions/manual-records';

// An Admin sends a PDF to an investor (their investment agreement) or a staff member (their agreement) to sign in their
// portal with the built-in signature, and sees what was sent and signed (migration 0044).
export function SendToSign({ docType, who, defaultTitle, refresh }: { docType: 'investment_agreement' | 'staff_agreement'; who: string; defaultTitle: string; refresh: string[] }) {
  const router = useRouter();
  const a = useAct<{ id: string }>();
  const [open, setOpen] = useState(false);
  const form = useRef<HTMLFormElement>(null);
  const uid = `sts-${useId().replace(/[^\w-]/g, '')}`;
  if (!open) return <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(true)} data-testid="send-to-sign">Send a PDF to sign</button>;
  return (
    <form ref={form} className="stack pt-sheet" noValidate aria-label="Send a document to sign" data-testid="send-to-sign-form"
      onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); a.run(() => createSignRequest(fd), (r) => { if (r.ok) { router.refresh(); form.current?.reset(); setOpen(false); } }); }}>
      <input type="hidden" name="doc_type" value={docType} />
      <input type="hidden" name={docType === 'investment_agreement' ? 'investor_id' : 'staff_user_id'} value={who} />
      <input type="hidden" name="refresh" value={refresh.join(',')} />
      <div className="field"><label className="label" htmlFor={`${uid}-t`}>Title</label><input className="input" id={`${uid}-t`} name="title" defaultValue={defaultTitle} /></div>
      {docType === 'investment_agreement' && (
        <div className="field-row">
          <div className="field"><label className="label" htmlFor={`${uid}-ex`}>Exemption</label>
            <select className="select" id={`${uid}-ex`} name="exemption_category" defaultValue="accredited_investor"><option value="accredited_investor">Accredited investor</option><option value="offering_memorandum_eligible">Offering memorandum, eligible investor</option></select></div>
          <div className="field"><label className="label" htmlFor={`${uid}-par`}>Paragraph (optional)</label><input className="input" id={`${uid}-par`} name="exemption_paragraph" /></div>
        </div>
      )}
      <div className={`field${a.err('file') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-f`}>The PDF to sign</label>
        <input className="input" id={`${uid}-f`} name="file" type="file" accept="application/pdf" aria-describedby={`${uid}-f-hint`} />
        <p className="hint" id={`${uid}-f-hint`}>They read it and sign it in their portal. The signed copy is filed with their documents.</p>
        <p className="error" role="alert">{a.err('file') ?? ''}</p></div>
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending}>{a.pending ? 'Sending' : 'Send to sign'}</button><button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button></div>
    </form>
  );
}

export interface SignRequestRow { id: string; title: string; status: string; signer_name: string; sent_at: string; signed_at: string | null; method: string | null; document_id: string | null; signed_document_id: string | null; void_reason: string | null }
const when = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso)) : '');

export function SignRequestList({ rows, refresh }: { rows: SignRequestRow[]; refresh: string[] }) {
  if (!rows.length) return null;
  return (
    <ul className="mr-list" data-testid="sign-requests">
      {rows.map((r) => (
        <li key={r.id} className={r.status === 'voided' ? 'is-void' : undefined}>
          <span><b>{r.title}</b>: {r.status === 'signed' ? `signed ${r.method === 'paper' ? 'on paper' : 'in the portal'} ${when(r.signed_at)}` : r.status === 'sent' ? `sent ${when(r.sent_at)}, waiting for ${r.signer_name}` : `withdrawn${r.void_reason ? `: ${r.void_reason}` : ''}`}</span>
          {(r.signed_document_id ?? r.document_id) && <a className="link small" href={`/admin/documents/${r.signed_document_id ?? r.document_id}`} target="_blank" rel="noreferrer">{r.signed_document_id ? 'Signed copy' : 'Document'}</a>}
          {r.status === 'sent' && <Withdraw id={r.id} refresh={refresh} />}
        </li>
      ))}
    </ul>
  );
}

function Withdraw({ id, refresh }: { id: string; refresh: string[] }) {
  const router = useRouter();
  const a = useAct<null>();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const uid = `wd-${useId().replace(/[^\w-]/g, '')}`;
  if (!open) return <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(true)}>Withdraw</button>;
  return (
    <form className="row mr-void" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => voidSignRequest(id, reason, refresh), (r) => { if (r.ok) router.refresh(); }); }}>
      <label className="vh" htmlFor={uid}>Why is it withdrawn?</label>
      <input className="input" id={uid} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Why? For example: sent the wrong version" />
      <button className="btn btn--ghost btn--sm" type="submit" disabled={a.pending}>Withdraw</button>
      {a.res && !a.res.ok && <p className="error" role="alert">{a.res.fieldErrors?.reason ?? a.res.message}</p>}
    </form>
  );
}
