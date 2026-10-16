import Link from 'next/link';
import { notFound } from 'next/navigation';
import { rpc } from '@/lib/db/repo';
import { PackageSignForm } from '@/features/signing/PackageSignForm';
import { SignProgress, SignSummary, type SummaryRow } from '@/features/signing/Progress';
import { signPortalPackage } from '@/server/actions/signing';
import { viewAs } from '@/server/view-as';

// The signing pages of the investor, VA and Field portals (migrations 0044 and 0049): every document waiting for the
// person's signature in one package (a generated agreement shows the key values it was filled with, each with a Fix
// note), one signature for all of them, and what is already signed. A single document has its own page too.
type Open = { id: string; doc_type: string; title: string; document_id: string; sent_at: string; extra?: { summary?: SummaryRow[]; generated?: boolean } };
type Signed = { id: string; doc_type: string; title: string; document_id: string | null; signed_document_id?: string | null; method: string; signed_on: string; awaiting_countersignature?: boolean };
type Facts = { id: string; doc_type: string; title: string; status: string; signer_name: string; document_id: string; document_sha256: string; signed_at: string | null; method: string | null;
  signed_document_id: string | null; agreement_number: string | null; extra?: { summary?: SummaryRow[]; generated?: boolean } };
const SR = { role: 'service_role' as const };
const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(iso.length === 10 ? `${iso}T12:00:00` : iso));
const portalOf = (base: string) => (base.startsWith('/investor') ? 'investor' as const : 'staff' as const);
const consent = (n: number) => `By pressing Sign you sign ${n > 1 ? `these ${n} documents` : 'this document'} electronically, with the same effect as signing on paper. We record the time, your IP address and device with your signature.`;

export async function signCount(userId: string): Promise<number> {
  const r = (await rpc('my_sign_requests', { p_by: userId }, SR).catch(() => null)) as unknown as { open: Open[] } | null;
  return r?.open.length ?? 0;
}

export async function SignList({ userId, base }: { userId: string; base: string }) {
  const r = (await rpc('my_sign_requests', { p_by: userId }, SR)) as unknown as { open: Open[]; signed: Signed[] };
  const facts = (await Promise.all(r.open.map((x) => rpc('sign_request_facts', { p_by: userId, p_id: x.id }, SR).catch(() => null)))) as unknown as Array<Facts | null>;
  const open = facts.filter((f): f is Facts => !!f && f.status === 'sent');
  const viewing = !!(await viewAs());
  const summary = open.flatMap((f) => (f.extra?.summary ?? []).map((row) => ({ ...row, label: open.length > 1 ? `${f.title}: ${row.label}` : row.label })));
  return (
    <div className="stack-lg">
      <header className="stack"><h1 className="d2">Documents to sign</h1>
        <p className="muted">{open.length ? `Everything is filled in from your record. Check the values, then sign ${open.length > 1 ? 'once for all of them' : 'it'}. It takes about a minute.` : 'Nothing is waiting for your signature.'}</p></header>
      <SignProgress items={[...r.signed.map((x) => ({ key: x.id, label: x.title, done: true, note: x.method === 'paper' ? 'signed on paper' : null })),
        ...open.map((x) => ({ key: x.id, label: x.title, done: false, here: true }))]} />
      {open.length > 0 && (
        <div className="pt-split">
          <div className="stack-lg">
            <SignSummary rows={summary} />
            <section className="pt-card stack" aria-labelledby="sg-open"><h2 className="d4" id="sg-open">The documents ({open.length})</h2>
              <ul className="ow-rows" data-testid="sign-open">{open.map((x) => (
                <li key={x.id}><span><b>{x.title}</b>{x.agreement_number ? `, ${x.agreement_number}` : ''}</span>
                  <span className="ow-meta"><a className="link" href={`/sign-document/${x.document_id}`} target="_blank" rel="noreferrer" data-testid="sign-read">Read the PDF</a></span></li>))}</ul>
              <p className="small muted">Questions before you sign? Reply to the email it came with, or call us.</p></section>
          </div>
          <aside className="pt-split__aside">
            <section className="pt-card" aria-labelledby="sg-sign"><h2 className="d4" id="sg-sign">Sign</h2>
              {viewing ? <p className="small muted">Read only.</p> : (
                <PackageSignForm docs={open.map((x) => ({ key: x.id, title: x.title }))} signerName={open[0]!.signer_name} investment={open.some((x) => x.doc_type === 'investment_agreement')}
                  initials={open.some((x) => x.doc_type === 'investment_agreement')} statementsLegend="Risk acknowledgment (Schedule C)"
                  statements={open.some((x) => x.doc_type === 'investment_agreement') ? [{ code: 'schedule_c', text: 'I have read the risk acknowledgment in Schedule C and I initial each statement in it.' }] : []}
                  consent={consent(open.length)} button={open.length > 1 ? `Sign all ${open.length}` : 'Sign'} testId="portal-sign-form"
                  action={signPortalPackage.bind(null, { requests: open.map((x) => ({ id: x.id, sha: x.document_sha256, title: x.title, doc_type: x.doc_type })), portal: portalOf(base), next: base })} />
              )}
            </section>
          </aside>
        </div>
      )}
      <section className="stack" aria-labelledby="sg-done"><h2 className="pt-section-title" id="sg-done">Signed</h2>
        {r.signed.length ? <ul className="ow-rows" data-testid="sign-done">{r.signed.map((x) => (
          <li key={x.id}><span><b>{x.title}</b></span><span className="ow-meta"><span>Signed {x.method === 'paper' ? 'on paper' : 'here'} on {day(x.signed_on)}</span>{x.awaiting_countersignature && <span data-testid="awaiting-countersignature">Awaiting countersignature by CarmaCars</span>}
            {(x.signed_document_id ?? x.document_id) && <a className="link" href={`/sign-document/${x.signed_document_id ?? x.document_id}`}>{x.method === 'paper' ? 'Scan' : 'Signed copy'}</a>}</span></li>))}</ul>
          : <p className="pt-empty muted">Nothing signed yet.</p>}
      </section>
    </div>
  );
}

export async function SignOne({ userId, base, id }: { userId: string; base: string; id: string }) {
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const f = (await rpc('sign_request_facts', { p_by: userId, p_id: id }, SR).catch(() => null)) as unknown as Facts | null;
  if (!f) notFound();
  const viewing = !!(await viewAs());
  const inv = f.doc_type === 'investment_agreement';
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
          <SignSummary rows={f.extra?.summary ?? []} />
          <section className="pt-card stack" aria-labelledby="sg-read"><h2 className="d4" id="sg-read">Read the document</h2>
            <p><a className="btn btn--ghost" href={`/sign-document/${f.document_id}`} target="_blank" rel="noreferrer" data-testid="sign-read">Open the PDF</a></p>
            <p className="small muted">It opens in a new tab. Questions before you sign? Reply to the email it came with, or call us.</p></section>
          <section className="pt-card stack" aria-labelledby="sg-sign"><h2 className="d4" id="sg-sign">Sign</h2>
            {viewing ? <p className="small muted">Read only.</p>
              : <PackageSignForm docs={[{ key: f.id, title: f.title }]} signerName={f.signer_name} investment={inv} initials={inv} statementsLegend="Risk acknowledgment (Schedule C)"
                  statements={inv ? [{ code: 'schedule_c', text: 'I have read the risk acknowledgment in Schedule C and I initial each statement in it.' }] : []}
                  consent={consent(1)} button="Sign" testId="portal-sign-form"
                  action={signPortalPackage.bind(null, { requests: [{ id: f.id, sha: f.document_sha256, title: f.title, doc_type: f.doc_type }], portal: portalOf(base), next: base })} />}</section>
        </>
      )}
    </div>
  );
}
