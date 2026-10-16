import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { AgreementView } from '@/features/agreement/AgreementView';
import { PackageSignForm } from '@/features/signing/PackageSignForm';
import { signOwnerPackage } from '@/server/actions/signing';
import { partnerAgreementBlocks, PARTNER_AGREEMENT_TITLE } from '@/features/partner/agreement';
import { requireOwner } from '@/server/owner/data';
import { openPartnerAgreement, partnerFacts } from '@/server/sign-requests';
import { viewAs } from '@/server/view-as';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partner agreement', path: '/owner/partner-agreement', noindex: true, description: 'Your partner agreement with CarmaCars, signed on screen.' });

type State = { status: string; method: string | null; signed_at: string | null; document_id: string | null } | null;

// The partner agreement (migration 0046): a partner rental company reads it, filled from its record, and signs it here.
// CarmaCars countersigns automatically. Signed on paper instead? Staff record it and it counts the same.
export default async function PartnerAgreementPage() {
  const { user } = await requireOwner('/owner/partner-agreement');
  const state = (await rpc('partner_agreement_state', { p_by: user.id }, { role: 'service_role' })) as unknown as State;
  if (!state) notFound();
  const facts = await partnerFacts(user.id);
  if (!facts) notFound();
  if (state.status === 'signed') {
    return (
      <>
        <Back href="/owner">Home</Back>
        <header className="stack"><h1 className="d2">{PARTNER_AGREEMENT_TITLE}</h1></header>
        <section className="ow-status ow-status--paid" data-testid="partner-agreement-signed"><h2 className="d3">Signed</h2>
          <p>Signed {state.method === 'paper' ? 'on paper' : 'on screen'}{state.signed_at ? ` on ${new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(state.signed_at))}` : ''}. Nothing else to do.</p>
          {state.document_id && <p><a className="btn btn--ghost" href={`/owner/documents/${state.document_id}`}>Open the signed copy</a></p>}</section>
      </>
    );
  }
  const viewing = !!(await viewAs());
  const open = viewing ? null : await openPartnerAgreement(user.id);
  return (
    <>
      <Back href="/owner">Home</Back>
      <header className="stack"><p className="pt-kicker">Partner {facts.partner_number}</p><h1 className="d2">{PARTNER_AGREEMENT_TITLE}</h1>
        <p className="muted">Filled in from your partner record. Read it, then sign at the bottom. Something wrong? Tell us before you sign and we fix it.</p></header>
      <div className="stack-lg" style={{ maxWidth: '48rem' }}>
        <AgreementView blocks={partnerAgreementBlocks(facts)} id="partner-agreement" label={PARTNER_AGREEMENT_TITLE} />
        {open ? <section className="pt-card stack" aria-labelledby="pa-sign"><h2 className="d4" id="pa-sign">Sign the partner agreement</h2>
          <PackageSignForm docs={[{ key: 'partner', title: PARTNER_AGREEMENT_TITLE }]} signerName={facts.partner.signer_name} fixNameHref="/owner/profile"
            consent="By pressing Sign you sign the partner agreement electronically, with the same effect as signing on paper. We record the time, your IP address and device. CarmaCars countersigns at the same moment."
            button="Sign" action={signOwnerPackage.bind(null, { packet: [], requests: [{ id: open.id, sha: open.sha, title: PARTNER_AGREEMENT_TITLE }], next: '/owner/partner-agreement' })} testId="portal-sign-form" /></section>
          : <p className="small muted">Read only.</p>}
        <p className="small muted">Prefer paper? Ask us for a copy, sign it and send us the scan. We record it and it counts the same. Your documents are in <Link prefetch={false} className="link" href="/owner/documents">Documents</Link>.</p>
      </div>
    </>
  );
}
