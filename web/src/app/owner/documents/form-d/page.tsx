import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { AgreementView } from '@/features/agreement/AgreementView';
import { FormDSignForm } from '@/features/owner/FormDSignForm';
import type { WForm } from '@/features/owner/WitnessedForms';
import { FORM_TITLE, screenFormDBlocks, witnessStatement } from '@/features/owner-agreement/witnessed';
import { signFormD } from '@/server/actions/form-c';
import { requireOwner } from '@/server/owner/data';
import { companySigners, findOpen, formDFacts, formDSpec } from '@/server/signing/prepare';
import { PrepareDocs } from '@/features/signing/PrepareDocs';
import { viewAs } from '@/server/view-as';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign Form D on screen', path: '/owner/documents', noindex: true, description: 'Form D of your Title Agreement, signed on screen with your two witnesses beside you.' });

// Form D on screen (0720, the owner's decision of November 7, 2026: no paper signature for anyone): filled from the
// owner's records, signed by the owner with the signing steps of every signature, the two witnesses typing their names
// and the statement on the same device; Part 2 is signed for CarmaCars from its stored signatures (Program settings).
// Every owner route that has Form D, the fleet supplier's included.
export default async function FormDScreen() {
  const { user, home } = await requireOwner('/owner/documents/form-d');
  const forms = ((await rpc('owner_witnessed_forms', { p_by: user.id }, { role: 'service_role' }).catch(() => [])) ?? []) as unknown as WForm[];
  const f = forms.find((x) => x.code === 'D1');
  if (!f) notFound();
  if (f.status === 'approved' || f.status === 'uploaded') {
    return (<><Back href="/owner/documents">Documents</Back><header className="stack"><h1 className="d2">{FORM_TITLE.D1}</h1></header>
      <section className="ow-status ow-status--paid" data-testid="form-d-done"><h2 className="d3">{f.status === 'approved' ? 'Signed' : 'Waiting for our review'}</h2>
        <p>Nothing else to do for this form.</p><p><Link prefetch={false} className="btn btn--ghost" href="/owner/documents">Back to Documents</Link></p></section></>);
  }
  const [facts, signers] = await Promise.all([formDFacts(user.id), companySigners()]);
  if (!facts) notFound();
  const viewing = !!(await viewAs());
  const spec = await formDSpec(user.id, home.owner.id, facts, signers);
  const open = viewing ? null : (await findOpen(user.id, [spec])).get(spec.key) ?? null;
  return (
    <>
      <Back href="/owner/documents">Documents</Back>
      <header className="stack"><h1 className="d2">{FORM_TITLE.D1}</h1>
        <p className="muted">Filled in from your records. Sign it here with your two witnesses beside you on the same device. CarmaCars signs Part 2 at the same moment.</p></header>
      <div className="stack-lg" style={{ maxWidth: '48rem' }}>
        <AgreementView blocks={screenFormDBlocks(facts, signers)} id="form-d" label={FORM_TITLE.D1} />
        {open ? <section className="pt-card stack" aria-labelledby="fd-sign"><h2 className="d4" id="fd-sign">Sign Form D</h2>
          <FormDSignForm ownerName={facts.owner.legal_name} statement={witnessStatement(facts.owner.legal_name)}
            esign={{ kind: 'documents', role: 'owner', docs: [{ kind: 'request', ref: open.id, sha: open.sha, title: FORM_TITLE.D1 }] }} action={signFormD.bind(null, open.id, open.sha)} /></section>
          : viewing ? <p className="small muted">Read only.</p> : <PrepareDocs targets={[spec.target]} titles={[spec.title]} />}
      </div>
    </>
  );
}
