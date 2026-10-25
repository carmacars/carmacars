import '@/styles/portal.css';
import { notFound } from 'next/navigation';
import { rpc } from '@/lib/db/repo';
import { pageMeta } from '@/features/seo/meta';
import { when } from '@/features/agreement/model';
import { keyTerms, loadBundle } from '@/server/agreements/bundle';
import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { VersionSign } from '@/features/signing/VersionSign';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign the new version of your rental agreement', path: '/sign/agreement', noindex: true, description: 'Your booking changed: read what changed and sign the new version of the rental agreement.' });

interface Link {
  signer_id: string; role: string; name: string; status: string; signed_at: string | null;
  version: { id: string; version_no: number; kind: string; status: string; changes: Array<{ label: string; before: string; after: string; material: boolean }>; carmacars_sha256: string; blindspot_sha256: string | null; created_at: string };
  booking: { id: string; booking_number: string; renter_user_id: string | null };
}

// A new version of the rental agreement (migration 0154): the booking changed in a way the renter (and the drivers it
// affects) sign again. Each signer has their own link (email and text). Opened on a staff member's device with
// ?in_person=1, the record says it was signed in person with them.
export default async function VersionSignPage({ params, searchParams }: { params: Promise<{ token: string }>; searchParams: Promise<{ in_person?: string }> }) {
  const token = (await params).token;
  if (!/^[0-9a-f-]{36}$/.test(token)) notFound();
  const l = (await rpc('server_agreement_version_link', { p_token: token }, { role: 'service_role' }).catch(() => null)) as unknown as Link | null;
  if (!l) notFound();
  let inPerson = false;
  if ((await searchParams).in_person === '1') {
    const u = await currentUser();
    const r = u ? await rolesOf(u.id) : null;
    inPerson = !!(r && (r.admin || r.va || r.field));
  }
  const open = l.status === 'waiting' && l.version.status === 'awaiting_signature';
  const bundle = open && l.booking.renter_user_id ? await loadBundle(l.booking.id, l.booking.renter_user_id).catch(() => null) : null;
  return (
    <div className="pt"><div className="wrap pt__body stack-lg" style={{ maxWidth: '52rem' }}>
      <header className="stack"><p className="pt-kicker">Booking {l.booking.booking_number}</p>
        <h1 className="d2">Version {l.version.version_no} of your rental agreement</h1>
        <p className="muted">{l.name.split(' ')[0]}, the booking changed in a way you sign again. Read what changed, then sign. Until every signature is in, the earlier version applies.</p></header>
      {!open ? <p className="alert alert--ok" role="status" data-testid="version-closed"><span className="alert__title">{l.status === 'signed' ? 'Signed' : 'Nothing to sign'}</span>
          <span>{l.status === 'signed' ? `You signed this version on ${when(l.signed_at)}. Your copy is in your booking's documents.` : 'This version is no longer waiting for a signature: a newer one replaced it, or it was signed.'}</span></p> : <>
        <section className="pt-card stack" aria-labelledby="vs-changes">
          <h2 className="d4" id="vs-changes">What changed</h2>
          <div className="table-scroll" tabIndex={0} role="region" aria-label="What changed">
            <table className="data"><thead><tr><th scope="col">Item</th><th scope="col">Before</th><th scope="col">Now</th></tr></thead>
              <tbody>{l.version.changes.map((c, i) => <tr key={i}><th scope="row">{c.label}</th><td>{c.before}</td><td>{c.after}</td></tr>)}</tbody></table>
          </div>
          <p className="small"><a className="link" href={`/api/agreement-version/${token}/carmacars`} target="_blank" rel="noopener" data-testid="version-pdf">CarmaCars rental agreement, version {l.version.version_no} (PDF)</a>
            {l.version.blindspot_sha256 && <> · <a className="link" href={`/api/agreement-version/${token}/blindspot`} target="_blank" rel="noopener" data-testid="version-bs-pdf">Blind Spot rental agreement (PDF)</a></>}</p>
        </section>
        <section className="pt-card" aria-labelledby="vs-sign"><h2 className="d4" id="vs-sign">Sign version {l.version.version_no}</h2>
          <VersionSign token={token} inPerson={inPerson} ccSha={l.version.carmacars_sha256} bsSha={l.version.blindspot_sha256} terms={bundle ? keyTerms(bundle) : []} two={!!l.version.blindspot_sha256} />
        </section>
      </>}
    </div></div>
  );
}
