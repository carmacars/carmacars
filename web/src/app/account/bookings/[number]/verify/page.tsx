import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { when } from '@/features/agreement/model';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { UploadCard } from '@/features/portal/UploadCard';
import { CoverageSection } from '@/features/portal/CoverageSection';
import { myBooking, myCoverage } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Licence, selfie and coverage', path: '/account/bookings', noindex: true, description: 'Upload your licence, a selfie and proof of coverage before pickup.' });

const MISSING: Record<string, string> = { identity: 'Licence photos and selfie for every driver', coverage: 'Proof of coverage', additional_driver_acceptance: 'Each additional driver accepts the agreement', deposit: 'Deposit, taken at pickup', calendar_switch: 'Final check by our team', agreement: 'Signed agreement', pickup_condition_report: 'Condition Report, done at pickup' };

// Identity and coverage (02 section 7.3, 08-forms.md section 7): three photos per driver and the proof
// for the chosen coverage option, each reviewed by our team. Status from booking_readiness.
export default async function VerifyPage({ params }: { params: Promise<{ number: string }> }) {
  const { b, user } = await myBooking((await params).number, 'verify');
  // licence photos, the selfie and the coverage proof: before pickup, or while a rental added already underway is out (0074)
  if (!['pending_payment', 'confirmed'].includes(b.status) && !(b.status === 'on_rent' && b.added_mode === 'in_progress')) redirect(bookingPath(b.booking_number));
  const up = (kind: string, driver: string | null) => b.uploads.filter((u) => u.kind === kind && u.driver_id === driver).pop();
  const missing = b.readiness?.missing ?? [];
  const cov = await myCoverage(user, b.id).catch(() => null);
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
        <div className="pt-card">{cov ? <CoverageSection number={b.booking_number} c={cov} /> : <p>Tell us how you will cover damage to the car: call or message us.</p>}</div>
      </section>
    </>
  );
}
