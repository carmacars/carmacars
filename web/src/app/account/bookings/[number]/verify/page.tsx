import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { when } from '@/features/agreement/model';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { UploadCard } from '@/features/portal/UploadCard';
import { CoverageUpload } from '@/features/portal/CoverageUpload';
import { CardCoverage } from '@/features/portal/CardCoverage';
import { cardCoverageState } from '@/server/actions/portal';
import { myBooking } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Licence, selfie and coverage', path: '/account/bookings', noindex: true, description: 'Upload your licence, a selfie and proof of coverage before pickup.' });

const MISSING: Record<string, string> = { identity: 'Licence photos and selfie for every driver', coverage: 'Proof of coverage', additional_driver_acceptance: 'Each additional driver accepts the agreement', deposit: 'Deposit, taken at pickup', calendar_switch: 'Final check by our team', agreement: 'Signed agreement', pickup_condition_report: 'Condition Report, done at pickup' };

// Identity and coverage (02 section 7.3, 08-forms.md section 7): three photos per driver and the proof
// for the chosen coverage option, each reviewed by our team. Status from booking_readiness.
export default async function VerifyPage({ params }: { params: Promise<{ number: string }> }) {
  const { b } = await myBooking((await params).number, 'verify');
  if (!['pending_payment', 'confirmed'].includes(b.status)) redirect(bookingPath(b.booking_number));
  const up = (kind: string, driver: string | null) => b.uploads.filter((u) => u.kind === kind && u.driver_id === driver).pop();
  const missing = b.readiness?.missing ?? [];
  const cov = b.coverage_option;
  const cc = cov === 2 ? await cardCoverageState(b.booking_number) : null;
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <header className="stack">
        <h1 className="d2">Licence, selfie and coverage</h1>
        <p className="lead">Needed by {when(new Date(new Date(b.pickup_at).getTime() - 24 * 3600e3).toISOString())}, 24 hours before pickup.</p>
      </header>
      <p className="pt-note">You agreed to identity verification when you signed. Our staff who verify drivers, and our insurer where required, see these images. We delete licence and face photos 90 days after your rental ends.</p>
      {b.readiness && (
        <section className="pt-card" aria-labelledby="pt-ready" data-testid="readiness"><h2 className="d4" id="pt-ready">Before pickup</h2>
          <ol className="pt-steps">{Object.keys(MISSING).filter((k) => k !== 'agreement').map((k) => <li key={k} className={missing.includes(k) ? '' : 'is-done'}>{MISSING[k]}<span className="vh">{missing.includes(k) ? ', to do' : ', done'}</span></li>)}</ol>
        </section>
      )}
      {b.drivers.map((d) => (
        <section key={d.id} className="stack" aria-labelledby={`pt-drv-${d.id}`}>
          <h2 className="pt-section-title" id={`pt-drv-${d.id}`}>{d.full_name}{d.identity_verified_on ? ' · verified' : ''}</h2>
          <div className="pt-uploads">
            {([['licence_front', 'Licence, front', 'Lay the licence on a dark surface. All four corners visible, no glare.'], ['licence_back', 'Licence, back', 'The back of the same licence, all four corners visible.'], ['selfie', 'Selfie with your licence', 'Hold the licence beside your face. Use the front camera.']] as const).map(([k, t, h]) => {
              const u = up(k, d.driver_id);
              return <UploadCard key={k} number={b.booking_number} kind={k} driverId={d.driver_id} title={t} hint={h} status={u?.status} reason={u?.reject_reason} />;
            })}
          </div>
        </section>
      ))}
      <section className="stack" aria-labelledby="pt-cov">
        <h2 className="pt-section-title" id="pt-cov">Coverage for damage to the car</h2>
        {cov === 1 || cov === 2 ? (
          <div className="pt-card"><p>{cov === 1 ? 'Option 1: your own auto policy with the OPCF 27 endorsement. Upload the policy page or your insurer\u2019s letter with the insurer, policy number and expiry; our team checks it before pickup.' : 'Option 2: rental coverage on your credit card. It must be the credit card you pay with.'}</p>
            {cov === 2 && cc && <CardCoverage number={b.booking_number} s={cc} />}
            {cov === 2 && <p className="small muted">Optional, and it helps: a photo or PDF of your card\u2019s benefits certificate.</p>}
            <CoverageUpload number={b.booking_number} option={cov} status={up('coverage_proof', null)?.status} reason={up('coverage_proof', null)?.reject_reason} /></div>
        ) : <div className="pt-card"><p>{cov === 3 ? 'You chose the CarmaCars Protection Plan. We send you its terms before pickup.' : 'Tell us how you will cover damage to the car: call or message us.'}</p></div>}
      </section>
    </>
  );
}
