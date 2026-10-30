import '@/styles/portal.css';
import { rpc } from '@/lib/db/repo';
import { pageMeta } from '@/features/seo/meta';
import { AgreementView } from '@/features/agreement/AgreementView';
import { PackageSignForm } from '@/features/signing/PackageSignForm';
import { CONFIRMATIONS, documentBlocks, OWNER_SIGN_STATEMENT, TITLES, type PacketKey } from '@/features/owner-agreement/model';
import { ownerAgreementFacts } from '@/server/owner/agreements';
import { signAsCosigner } from '@/server/actions/cosign';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign your owner documents', path: '/sign/owner', noindex: true, description: 'An Owner named in the Title Schedule reads and signs the CarmaCars owner documents.' });

interface Facts {
  cosigner: { id: string; name: string; status: string; signed_at: string | null };
  owner: { id: string; legal_name: string; user_id: string | null };
  documents: Array<{ key: PacketKey; signature_request_id: string; sha256: string; status: string }>;
  waiting_for: string[]; owner_signed: boolean;
}

// Every Owner named in the Title Schedule signs with their own link (the legal review, migration 0053). No account is
// needed: the link names the Owner. They read the same documents the portal owner reads and sign once for all of them,
// with the signing steps of every signature (0193): a code to their email, the reading, the confirmations initialled, the
// consents, the drawn signature.
export default async function CosignerSign({ params }: { params: Promise<{ token: string }> }) {
  const token = (await params).token;
  const f = /^[0-9a-f]{64}$/.test(token) ? ((await rpc('server_owner_cosigner_facts', { p_token: token }, { role: 'service_role' })) as unknown as Facts | null) : null;
  if (!f) return (
    <section className="section"><div className="wrap stack" style={{ maxWidth: '40rem' }} data-testid="cosign-link-invalid"><h1 className="d2">This link is not valid</h1><p>Ask CarmaCars to send you a new link, or call us.</p></div></section>
  );
  const first = f.cosigner.name.split(' ')[0];
  const facts = f.owner.user_id && f.documents.length ? await ownerAgreementFacts(f.owner.id, f.owner.user_id) : null;
  const docs = facts ? f.documents.map((d) => ({ key: d.key, title: TITLES[d.key], blocks: documentBlocks(facts, d.key) })) : [];
  const enrollment = f.documents.some((d) => d.key === 'enrollment');
  return (
    <div className="pt"><div className="wrap pt__body">
      <header className="stack"><p className="pt-kicker">Owner documents of {f.owner.legal_name}</p><h1 className="d2">Read and sign, {first}</h1>
        <p className="muted">You are named as an Owner. Every Owner signs with their own link; the agreements take effect when the last one signs.</p></header>
      {f.cosigner.status === 'signed' ? <p className="alert alert--ok" role="status" data-testid="cosign-done"><span className="alert__title">Signed</span><span>Thank you. Nothing more to do here.</span></p>
        : !docs.length ? <p className="alert alert--warn" role="status"><span>Nothing is waiting for your signature right now. We email you when the documents are ready.</span></p> : (
        <div className="pt-split">
          <div className="stack-lg">{docs.map((d) => <details key={d.key} open={docs.length === 1}><summary>{d.title}</summary><AgreementView blocks={d.blocks} id={`co-doc-${d.key}`} label={d.title} /></details>)}</div>
          <aside className="pt-split__aside"><section className="pt-card" aria-labelledby="co-sign"><h2 className="d4" id="co-sign">Sign</h2>
            <PackageSignForm docs={docs.map((d) => ({ key: d.key, title: d.title }))} signerName={f.cosigner.name} esign={{ kind: 'cosigner', token }}
              statements={[{ code: 'statement', text: OWNER_SIGN_STATEMENT }, ...(enrollment ? CONFIRMATIONS.map((c) => ({ code: c.code, text: c.text })) : [])]}
              consent={`By pressing Sign you sign ${docs.length > 1 ? `these ${docs.length} documents` : 'this document'} electronically, with the same effect as signing on paper. We record the time, your IP address and device.${f.waiting_for.length || !f.owner_signed ? ' The agreements take effect when every Owner has signed.' : ' You are the last Owner to sign: CarmaCars countersigns at the same moment.'}`}
              button={docs.length > 1 ? `Sign all ${docs.length}` : 'Sign'} action={signAsCosigner.bind(null, token)} testId="cosign-form" />
          </section></aside>
        </div>
      )}
    </div></div>
  );
}
