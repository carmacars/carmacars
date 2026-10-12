import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { Back } from '@/features/portal/Blocks';
import { AgreementView } from '@/features/agreement/AgreementView';
import { OwnerSignForm } from '@/features/owner/OwnerSignForm';
import { CONFIRMATIONS } from '@/features/owner-agreement/model';
import { requireOwner } from '@/server/owner/data';
import { openOwnerPacket } from '@/server/owner/agreements';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign your agreements', path: '/owner/sign', noindex: true, description: 'Read and sign the Vehicle Enrollment Agreement and the Vehicle Schedule.' });

// Signing (04-owner.md section 3, step 5): every document still to sign is rendered from the owner's
// records, stored and opened with its SHA-256; the owner reads them, initials the three confirmations
// and signs once. The same signing system as the rental agreement.
export default async function OwnerSign() {
  const { user, home } = await requireOwner('/owner/sign');
  const { facts, docs } = await openOwnerPacket(home.owner.id, user.id);
  if (!docs.length) {
    return (
      <>
        <Back href="/owner">Owner portal</Back>
        <div className="pt-empty"><h1 className="d3">Nothing to sign</h1><p className="muted">{home.vehicles.some((v) => v.onboarding_status === 'intake') ? 'We are preparing the terms for your vehicles. We email you when your agreements are ready.' : 'Your signed agreements are in Documents.'}</p><Link className="btn btn--primary" href="/owner/documents">Documents</Link></div>
      </>
    );
  }
  return (
    <>
      <Back href="/owner">Owner portal</Back>
      <header className="stack">
        <p className="pt-kicker">Agreements · {docs.length} to sign</p>
        <h1 className="d2">Read and sign</h1>
        <p className="muted">Signed once, for {facts.owner.owner_type === 'corporation' ? `${facts.owner.corporation_name ?? facts.owner.legal_name}, by ${facts.owner.signer_name}` : facts.owner.signer_name}. Each vehicle&apos;s fees and Revenue Share are in its Vehicle Schedule entry.</p>
      </header>
      <div className="pt-split">
        <div className="stack-lg">
          {docs.map((d, i) => (
            <section key={d.key} className="stack" aria-labelledby={`ow-doc-${i}`}>
              <h2 className="d4" id={`ow-doc-${i}`}>{i + 1}. {d.title}</h2>
              <AgreementView blocks={d.blocks} id={`ow-doc-${d.key}`} label={d.title} />
            </section>
          ))}
        </div>
        <aside className="pt-split__aside">
          <section className="pt-card" aria-labelledby="ow-sign"><h2 className="d4" id="ow-sign">Sign</h2>
            <OwnerSignForm docs={docs.map((d) => ({ key: d.key, sha: d.sha, title: d.title }))} confirmations={docs.some((d) => d.key === 'enrollment') ? CONFIRMATIONS.map((c) => ({ code: c.code, text: c.text })) : []} signerName={facts.owner.signer_name} />
          </section>
        </aside>
      </div>
    </>
  );
}
