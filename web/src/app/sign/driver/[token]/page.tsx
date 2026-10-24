import '@/styles/portal.css';
import { notFound } from 'next/navigation';
import { rpc } from '@/lib/db/repo';
import { pageMeta } from '@/features/seo/meta';
import { consents } from '@/features/agreement/model';
import { AgreementView } from '@/features/agreement/AgreementView';
import { SignForm } from '@/features/portal/SignForm';
import { readToken } from '@/server/links';
import { agreementFacts, blocksFor, unsignedFacts } from '@/server/portal/agreement';
import { DriverLicence } from '@/features/portal/DriverLicence';
import type { LicenceStatus } from '@/features/handover/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Accept the rental agreement', path: '/sign/driver', noindex: true, description: 'Additional driver: read and accept the rental agreement.' });

// Additional driver acceptance (02 section 5): no account needed, the signed link names the driver's
// signer row and a version, valid until its expiry (Program settings). They read the same agreement, tick consents 1 to 3 and sign.
export default async function DriverSign({ params }: { params: Promise<{ token: string }> }) {
  const t = await readToken<{ s: string; v?: number }>('driver-sign', (await params).token);
  // a link is valid until its expiry and while it is the newest one made (migration 0040)
  if (!t || (await rpc('server_driver_link_valid', { p_signer: t.s, p_version: t.v ?? 1 }, { role: 'service_role' })) !== true) return (
    <section className="section"><div className="wrap stack" style={{ maxWidth: '40rem' }} data-testid="driver-link-expired"><h1 className="d2">This link has expired</h1><p>Signing links work for a few days, and a newer link replaces an older one. Ask the renter to send you a new link from their booking, or call us.</p></div></section>
  );
  const s = (await rpc('driver_signing', { p_signer: t.s }, { role: 'service_role' })) as unknown as { signer_name: string; signed_at: string | null; signer_role: string; agreement_status: string; booking_id: string; booking_number: string; booking_status: string; document_sha256: string } | null;
  if (!s || s.signer_role !== 'additional_driver') notFound();
  const renter = (await rpc('server_booking_payment_facts', { p_booking: s.booking_id }, { role: 'service_role' })) as unknown as { renter_user_id: string };
  const facts = await agreementFacts(s.booking_id, renter.renter_user_id);
  const open = s.agreement_status !== 'voided' && ['pending_payment', 'confirmed'].includes(s.booking_status);
  // their licence (0130): uploaded here, on their own link
  const lic = (await rpc('server_driver_licence_state', { p_signer: t.s }, { role: 'service_role' }).catch(() => null)) as unknown as { licence: LicenceStatus; selfie_required: boolean } | null;
  const token = (await params).token;
  return (
    <div className="pt"><div className="wrap pt__body">
      <header className="stack"><p className="pt-kicker">Booking {s.booking_number}</p><h1 className="d2">Accept the rental agreement, {s.signer_name.split(' ')[0]}</h1>
        <p className="muted">You are an additional driver on this booking. Read the agreement, tick the three statements and sign.</p></header>
      {open && lic && <DriverLicence token={token} l={lic.licence} selfie={lic.selfie_required} />}
      {s.signed_at ? <p className="alert alert--ok" role="status"><span className="alert__title">Already accepted</span><span>{lic && !lic.licence.complete ? 'Thank you. Add your licence above if you have not yet.' : 'Thank you. Nothing more to do here.'}</span></p>
        : !open ? <p className="alert alert--warn" role="status"><span>This agreement is no longer open for signing. The renter will send a new link.</span></p> : (
        <div className="pt-split">
          <AgreementView blocks={blocksFor(unsignedFacts(facts))} />
          <aside className="pt-split__aside"><section className="pt-card" aria-labelledby="pt-dsign"><h2 className="d4" id="pt-dsign">Accept and sign</h2>
            <SignForm token={(await params).token} sha={s.document_sha256} consents={consents().filter((c) => c.n <= 3)} legalName={s.signer_name} button="Accept and sign" />
          </section></aside>
        </div>
      )}
    </div></div>
  );
}
