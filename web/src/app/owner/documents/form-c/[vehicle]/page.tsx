import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { AgreementView } from '@/features/agreement/AgreementView';
import { FormCSignForm } from '@/features/owner/FormCSignForm';
import type { WForm } from '@/features/owner/WitnessedForms';
import { FORM_TITLE, screenFormCBlocks, witnessStatement } from '@/features/owner-agreement/witnessed';
import { signFormC } from '@/server/actions/form-c';
import { requireOwner } from '@/server/owner/data';
import { findOpen, formCFacts, formCSpec } from '@/server/signing/prepare';
import { PrepareDocs } from '@/features/signing/PrepareDocs';
import { viewAs } from '@/server/view-as';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign Form C on screen', path: '/owner/documents', noindex: true, description: 'Form C of your Title Agreement, signed on screen with your witness beside you.' });

// Form C on screen (the legal review, migration 0053): filled from the owner's records for one financed or leased car,
// signed and initialled by the owner with the signing steps of every signature (0181), with the witness typing their name
// and the statement on the same device.
export default async function FormCScreen({ params }: { params: Promise<{ vehicle: string }> }) {
  const vehicle = (await params).vehicle;
  if (!/^[0-9a-f-]{36}$/.test(vehicle)) notFound();
  const { user, home } = await requireOwner(`/owner/documents/form-c/${vehicle}`);
  const forms = ((await rpc('owner_witnessed_forms', { p_by: user.id }, { role: 'service_role' }).catch(() => [])) ?? []) as unknown as WForm[];
  const f = forms.find((x) => x.code === 'C' && x.vehicle_id === vehicle);
  if (!f) notFound();
  if (f.status === 'approved' || f.status === 'uploaded') {
    return (<><Back href="/owner/documents">Documents</Back><header className="stack"><h1 className="d2">{FORM_TITLE.C}</h1></header>
      <section className="ow-status ow-status--paid" data-testid="form-c-done"><h2 className="d3">{f.status === 'approved' ? 'Signed' : 'Waiting for our review'}</h2>
        <p>{f.vehicle_name}. Nothing else to do for this form.</p><p><Link prefetch={false} className="btn btn--ghost" href="/owner/documents">Back to Documents</Link></p></section></>);
  }
  const facts = await formCFacts(user.id, vehicle);
  if (!facts) notFound();
  const viewing = !!(await viewAs());
  // no PDF is made on this page (0077): the open request with the same content, or the browser prepares it
  const spec = await formCSpec(user.id, home.owner.id, vehicle, facts);
  const open = viewing ? null : (await findOpen(user.id, [spec])).get(spec.key) ?? null;
  const blocks = screenFormCBlocks(facts);
  const acks = (blocks.find((b) => b.t === 'table' && b.head[0] === 'I acknowledge') as { rows: string[][] } | undefined)?.rows.map((r) => r[0]!) ?? [];
  return (
    <>
      <Back href="/owner/documents">Documents</Back>
      <header className="stack"><p className="pt-kicker">{f.vehicle_name}</p><h1 className="d2">{FORM_TITLE.C}</h1>
        <p className="muted">Filled in from your records. Sign it here with your witness beside you on the same device, or print it and sign on paper from <Link prefetch={false} className="link" href="/owner/documents">Documents</Link>.</p></header>
      <div className="stack-lg" style={{ maxWidth: '48rem' }}>
        <AgreementView blocks={blocks} id="form-c" label={FORM_TITLE.C} />
        {open ? <section className="pt-card stack" aria-labelledby="fc-sign"><h2 className="d4" id="fc-sign">Sign Form C</h2>
          <FormCSignForm ownerName={facts.owner.legal_name} acknowledgments={acks} statement={witnessStatement(facts.owner.legal_name)}
            esign={{ kind: 'documents', role: 'owner', docs: [{ kind: 'request', ref: open.id, sha: open.sha, title: FORM_TITLE.C }] }} action={signFormC.bind(null, open.id, open.sha)} /></section>
          : viewing ? <p className="small muted">Read only.</p> : <PrepareDocs targets={[spec.target]} titles={[spec.title]} />}
      </div>
    </>
  );
}
