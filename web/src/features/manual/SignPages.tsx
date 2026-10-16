import Link from 'next/link';
import { notFound } from 'next/navigation';
import { rpc } from '@/lib/db/repo';
import { PortalSignForm } from './PortalSignForm';
import { SIGN_STATEMENT } from './constants';
import { viewAs } from '@/server/view-as';

// The signing pages of the investor, VA and Field portals (migration 0044): the documents an Admin sent to sign, and
// those already signed (in the portal or on paper). One document: read the PDF, then sign with the built-in signature.
type Open = { id: string; doc_type: string; title: string; document_id: string; sent_at: string };
type Signed = { id: string; doc_type: string; title: string; document_id: string | null; signed_document_id?: string | null; method: string; signed_on: string };
const SR = { role: 'service_role' as const };
const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(iso.length === 10 ? `${iso}T12:00:00` : iso));

export async function signCount(userId: string): Promise<number> {
  const r = (await rpc('my_sign_requests', { p_by: userId }, SR).catch(() => null)) as unknown as { open: Open[] } | null;
  return r?.open.length ?? 0;
}

export async function SignList({ userId, base }: { userId: string; base: string }) {
  const r = (await rpc('my_sign_requests', { p_by: userId }, SR)) as unknown as { open: Open[]; signed: Signed[] };
  return (
    <div className="stack-lg">
      <header className="stack"><h1 className="d2">Documents to sign</h1><p className="muted">Read each document, then sign it here. You get the signed copy right away.</p></header>
      <section className="stack" aria-labelledby="sg-open"><h2 className="pt-section-title" id="sg-open">Waiting for your signature</h2>
        {r.open.length ? <ul className="ow-rows" data-testid="sign-open">{r.open.map((x) => (
          <li key={x.id}><Link prefetch={false} className="ow-row-link" href={`${base}/${x.id}`}>{x.title}</Link><span className="ow-meta"><span>Sent {day(x.sent_at)}</span></span></li>))}</ul>
          : <p className="pt-empty muted">Nothing to sign right now.</p>}
      </section>
      <section className="stack" aria-labelledby="sg-done"><h2 className="pt-section-title" id="sg-done">Signed</h2>
        {r.signed.length ? <ul className="ow-rows" data-testid="sign-done">{r.signed.map((x) => (
          <li key={x.id}><span><b>{x.title}</b></span><span className="ow-meta"><span>Signed {x.method === 'paper' ? 'on paper' : 'here'} on {day(x.signed_on)}</span>
            {(x.signed_document_id ?? x.document_id) && <a className="link" href={`/sign-document/${x.signed_document_id ?? x.document_id}`}>{x.method === 'paper' ? 'Scan' : 'Signed copy'}</a>}</span></li>))}</ul>
          : <p className="pt-empty muted">Nothing signed yet.</p>}
      </section>
    </div>
  );
}

type Facts = { id: string; doc_type: string; title: string; status: string; signer_name: string; document_id: string; document_sha256: string; signed_at: string | null; method: string | null; signed_document_id: string | null; agreement_number: string | null };

export async function SignOne({ userId, base, id }: { userId: string; base: string; id: string }) {
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const f = (await rpc('sign_request_facts', { p_by: userId, p_id: id }, SR).catch(() => null)) as unknown as Facts | null;
  if (!f) notFound();
  const viewing = !!(await viewAs());
  return (
    <div className="stack-lg">
      <p><Link prefetch={false} className="link" href={base}>Documents to sign</Link></p>
      <header className="stack"><h1 className="d2">{f.title}</h1>{f.agreement_number && <p className="muted">Agreement {f.agreement_number}</p>}</header>
      {f.status === 'signed' ? (
        <section className="ow-status ow-status--paid" data-testid="sign-one-signed"><h2 className="d3">Signed</h2>
          <p>Signed {f.method === 'paper' ? 'on paper' : 'here'}{f.signed_at ? ` on ${day(f.signed_at)}` : ''}.</p>
          <p><a className="btn btn--ghost" href={`/sign-document/${f.signed_document_id ?? f.document_id}`}>Open the signed copy</a></p></section>
      ) : f.status !== 'sent' ? (
        <p className="pt-empty muted">This document was withdrawn. Nothing to sign.</p>
      ) : (
        <>
          <section className="pt-card stack" aria-labelledby="sg-read"><h2 className="d4" id="sg-read">1. Read the document</h2>
            <p><a className="btn btn--ghost" href={`/sign-document/${f.document_id}`} target="_blank" rel="noreferrer" data-testid="sign-read">Open the PDF</a></p>
            <p className="small muted">It opens in a new tab. Questions before you sign? Reply to the email it came with, or call us.</p></section>
          <section className="pt-card stack" aria-labelledby="sg-sign"><h2 className="d4" id="sg-sign">2. Sign</h2>
            {viewing ? <p className="small muted">Read only.</p>
              : <PortalSignForm id={f.id} sha={f.document_sha256} signerName={f.signer_name} statement={SIGN_STATEMENT} investment={f.doc_type === 'investment_agreement'} done="Signed. The signed copy is in your documents." />}</section>
        </>
      )}
    </div>
  );
}
