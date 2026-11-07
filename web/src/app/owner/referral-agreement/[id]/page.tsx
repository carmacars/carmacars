import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { AgreementView } from '@/features/agreement/AgreementView';
import { PackageSignForm } from '@/features/signing/PackageSignForm';
import { signOwnerPackage } from '@/server/actions/signing';
import { referralAgreementBlocks, REFERRAL_AGREEMENT_TITLE } from '@/features/referral-agreement/agreement';
import { requireOwner } from '@/server/owner/data';
import { findOpen, referralFacts, referralSpec } from '@/server/signing/prepare';
import { PrepareDocs } from '@/features/signing/PrepareDocs';
import { viewAs } from '@/server/view-as';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Referral Override Agreement', path: '/owner/referral-agreement', noindex: true, description: 'Your Referral Override Agreement with CarmaCars, signed on screen.' });

type Row = { link_id: string; referred: string; status: string; signed_at: string | null; document_id: string | null };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// The Referral Override Agreement (migration 0640): the owner who referred another owner reads it, filled from the
// referral link an Admin set, and signs it here. The Company countersigns at once. Signed on paper instead? Staff keep the scan.
export default async function ReferralAgreementPage({ params }: { params: Promise<{ id: string }> }) {
  const [{ id }, { user }] = await Promise.all([params, requireOwner('/owner/referral-agreement')]);
  if (!UUID.test(id)) notFound();
  const rows = (await rpc('server_referral_agreements', { p_by: user.id }, { role: 'service_role' })) as unknown as Row[];
  const state = rows.find((r) => r.link_id === id);
  if (!state) notFound();
  const facts = await referralFacts(user.id, id);
  if (!facts) notFound();
  if (state.status === 'signed') {
    return (
      <>
        <Back href="/owner">Home</Back>
        <header className="stack"><h1 className="d2">{REFERRAL_AGREEMENT_TITLE}</h1><p className="muted">The cars of {state.referred}.</p></header>
        <section className="ow-status ow-status--paid" data-testid="referral-agreement-signed"><h2 className="d3">Signed</h2>
          <p>Signed{state.signed_at ? ` on ${new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(state.signed_at))}` : ''}. Nothing else to do.</p>
          {state.document_id && <p><a className="btn btn--ghost" href={`/owner/documents/${state.document_id}`}>Open the signed copy</a></p>}</section>
      </>
    );
  }
  const viewing = !!(await viewAs());
  const spec = await referralSpec(user.id, facts);
  const open = viewing ? null : (await findOpen(user.id, [spec])).get(spec.key) ?? null;
  const next = `/owner/referral-agreement/${id}`;
  return (
    <>
      <Back href="/owner">Home</Back>
      <header className="stack"><p className="pt-kicker">The cars of {state.referred}</p><h1 className="d2">{REFERRAL_AGREEMENT_TITLE}</h1>
        <p className="muted">Filled in from the referral we agreed. Read it, then sign at the bottom. Something wrong? Tell us before you sign and we fix it.</p></header>
      <div className="stack-lg" style={{ maxWidth: '48rem' }}>
        <AgreementView blocks={referralAgreementBlocks(facts)} id="referral-agreement" label={REFERRAL_AGREEMENT_TITLE} />
        {open ? <section className="pt-card stack" aria-labelledby="ra-sign"><h2 className="d4" id="ra-sign">Sign the Referral Override Agreement</h2>
          <PackageSignForm docs={[{ key: 'referral', title: REFERRAL_AGREEMENT_TITLE }]} signerName={facts.referrer.signer_name}
            esign={{ kind: 'documents', role: 'owner', docs: [{ kind: 'request', ref: open.id, sha: open.sha, title: REFERRAL_AGREEMENT_TITLE }] }}
            consent="By pressing Sign you sign the Referral Override Agreement electronically, with the same effect as signing on paper. We record the time, your IP address and device. The Company countersigns at the same moment."
            button="Sign" action={signOwnerPackage.bind(null, { packet: [], requests: [{ id: open.id, sha: open.sha, title: REFERRAL_AGREEMENT_TITLE }], next })} testId="portal-sign-form" /></section>
          : viewing ? <p className="small muted">Read only.</p> : <PrepareDocs targets={[spec.target]} titles={[spec.title]} />}
        <p className="small muted">Prefer paper? Ask us for a copy, sign it and send us the scan. Your documents are in <Link prefetch={false} className="link" href="/owner/documents">Documents</Link>.</p>
      </div>
    </>
  );
}
