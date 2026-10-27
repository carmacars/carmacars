import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { AgreementView } from '@/features/agreement/AgreementView';
import { PackageSignForm } from '@/features/signing/PackageSignForm';
import { signOwnerPackage } from '@/server/actions/signing';
import { screenFormBlocks, SCREEN_FORM_TITLE } from '@/features/owner-agreement/screen-forms';
import { requireOwner } from '@/server/owner/data';
import { findOpen, formABFacts, formSpec } from '@/server/signing/prepare';
import { PrepareDocs } from '@/features/signing/PrepareDocs';
import { viewAs } from '@/server/view-as';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign a form', path: '/owner/documents', noindex: true, description: 'Form A or Form B of your Title Agreement, signed on screen.' });

type ScreenForm = { code: 'A' | 'B'; title: string; status: 'needed' | 'signed'; document_id: string | null; signed_at: string | null; method: string | null };

// Forms A and B of the Title-Holding and Lease Agreement (migration 0044): filled from your records, read on screen
// and signed with the same signature as your agreements. No witness is needed. Signed on paper instead? We record it.
export default async function ScreenForm({ params }: { params: Promise<{ code: string }> }) {
  const code = (await params).code.toUpperCase();
  if (code !== 'A' && code !== 'B') notFound();
  const { user } = await requireOwner(`/owner/documents/screen/${code.toLowerCase()}`);
  const forms = (await rpc('owner_screen_forms', { p_by: user.id }, { role: 'service_role' })) as unknown as ScreenForm[];
  const f = forms.find((x) => x.code === code);
  if (!f) notFound();
  const facts = await formABFacts(user.id, code);
  const title = SCREEN_FORM_TITLE[code];
  if (f.status === 'signed') {
    return (
      <>
        <Back href="/owner/documents">Documents</Back>
        <header className="stack"><h1 className="d2">{title}</h1></header>
        <section className="ow-status ow-status--paid" data-testid="screen-form-signed"><h2 className="d3">Signed</h2>
          <p>Signed {f.method === 'paper' ? 'on paper' : 'on screen'}{f.signed_at ? ` on ${new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(f.signed_at))}` : ''}. Nothing else to do for this form.</p>
          {f.document_id && <p><a className="btn btn--ghost" href={`/owner/documents/${f.document_id}`}>Open the signed copy</a></p>}</section>
      </>
    );
  }
  // viewing as the owner (read only): show the form without opening it for signature
  const viewing = !!(await viewAs());
  // no PDF is made on this page (0077): the open request with the same content, or the browser prepares it
  const spec = await formSpec(user.id, code, facts);
  const open = viewing ? null : (await findOpen(user.id, [spec])).get(spec.key) ?? null;
  return (
    <>
      <Back href="/owner/documents">Documents</Back>
      <header className="stack"><p className="pt-kicker">Title-Holding and Lease Agreement</p><h1 className="d2">{title}</h1>
        <p className="muted">Filled in from your records. Read it, then sign at the bottom. No witness is needed for this form. Several documents to sign? <Link prefetch={false} className="link" href="/owner/sign">Sign them all at once</Link>.</p></header>
      <div className="stack-lg" style={{ maxWidth: '48rem' }}>
        <AgreementView blocks={screenFormBlocks(facts)} id={`form-${code.toLowerCase()}`} label={title} />
        {open ? <section className="pt-card stack" aria-labelledby="sf-sign"><h2 className="d4" id="sf-sign">Sign {title}</h2>
          <PackageSignForm docs={[{ key: `form-${code}`, title }]} signerName={facts.owner.signer_name}
            esign={{ kind: 'documents', role: 'owner', docs: [{ kind: 'request', ref: open.id, sha: open.sha, title }] }}
            consent={`By pressing Sign you sign ${title} electronically, with the same effect as signing on paper. We record the time, your IP address and device. CarmaCars countersigns at the same moment.`}
            button="Sign" action={signOwnerPackage.bind(null, { packet: [], requests: [{ id: open.id, sha: open.sha, title }], next: `/owner/documents/screen/${code.toLowerCase()}` })} testId="portal-sign-form" /></section>
          : viewing ? <p className="small muted">Read only.</p> : <PrepareDocs targets={[spec.target]} titles={[spec.title]} />}
        <p className="small muted">Prefer paper? Print it from <Link prefetch={false} className="link" href="/owner/documents">Documents</Link>, sign it and send us the scan. We record it and it counts the same.</p>
      </div>
    </>
  );
}
