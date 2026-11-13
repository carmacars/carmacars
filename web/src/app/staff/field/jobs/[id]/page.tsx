import Link from '@/components/Link';
import { notFound, redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { Checklist } from '@/features/field/Checklist';
import { StartChecklist } from '@/features/field/StartChecklist';
import { FieldButton } from '@/features/field/FieldButton';
import { JobChecklist } from '@/features/field/JobChecklist';
import { ListingCapture, type Capture } from '@/features/listing/ListingCapture';
import { ListingSteps, type Steps } from '@/features/listing/ListingProgress';
import { StartListing } from '@/features/listing/StartListing';
import { LicenceReview } from '@/features/field/LicenceReview';
import type { FieldJob, LicenceCard } from '@/features/field/types';
import { when } from '@/features/agreement/model';
import { Plate } from '@/features/field/Plate';
import { FdIcon } from '@/features/field/icons';
import { KIND, STATUS, clock, maps } from '@/features/field/format';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { HandoverOverride } from '@/features/handover/HandoverOverride';
import { JobCardSteps } from '@/features/field-portal/JobCardSteps';
import type { Card } from '@/features/field-portal/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Job', path: '/staff/field', noindex: true, description: 'One field job and its checklist.' });


// One job (06-field.md section 3): the header, then Start, then the checklist for its kind. A job that is
// not the user's, cancelled or outside its window reads as not found.
export default async function FieldJobPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await requireStaff('field', `/staff/field/jobs/${id}`);
  const j = await door<FieldJob | null>(user.id, 'field_read', 'job', { id }).catch(() => null);
  // a job that is no longer theirs (passed to someone else, or removed) opens My jobs: a phone alert can still link to it
  if (!j) redirect('/staff/field');
  const b = j.booking;
  // 0162: the renter's licence waits for a decision on this job's booking: field staff review it here too
  const lic = b && j.job.status !== 'done'
    ? (await door<LicenceCard[]>(user.id, 'field_read', 'licences').catch(() => [] as LicenceCard[])).find((l) => l.booking_id === b.id) ?? null : null;
  const checklist = !j.checklist && (j.report_kind === 'pickup' || j.report_kind === 'return');
  const done = j.job.status === 'done';
  // a photo shoot (procedure 17): the listing capture of the car, as owners and Fleet use it (migration 0032)
  const cap = j.job.kind === 'photo_shoot' && j.checklist?.listing && j.job.status === 'in_progress'
    ? await door<Capture>(user.id, 'ops_read', 'listing_capture', { intake: j.checklist.listing.intake_id }).catch(() => null) : null;
  const steps = cap ? await door<Steps>(user.id, 'ops_read', 'listing_steps', { intake: cap.intake_id }).catch(() => null) : null;
  const listing = j.job.kind !== 'photo_shoot' ? null : cap ? <>{steps && <ListingSteps initial={steps} refresh={[`/staff/field/jobs/${id}`]} />}<ListingCapture initial={cap} refresh={[`/staff/field/jobs/${id}`]} /></>
    : j.checklist?.listing?.submitted_at ? <p className="fd-line is-ok">Submitted for listing.</p> : <StartListing vehicleId={j.vehicle.id} label="Start the listing photos" />;
  const c = clock(j.job.scheduled_at);
  // r35 part X (0930): the card's own steps on the job screen: the clean check and the add-ons ticked as in the car
  const card = (j.report_kind === 'pickup' || j.report_kind === 'return') ? await door<Card | null>(user.id, 'field_read', 'job_card', { id }).catch(() => null) : null;
  return (
    <div className="stack fd-job">
      <p><Link prefetch={false} className="fd-back" href="/staff/field"><FdIcon name="back" />Today</Link></p>
      <header className="fd-next fd-jobhead" data-testid="job-head">
        <div className="fd-next__when">
          <p className="fd-next__time">{c.time}<span className="fd-next__half">{c.half}</span></p>
          <p className="fd-next__rel">{when(j.job.scheduled_at, false)}</p>
        </div>
        <p className="fd-next__kind">{KIND[j.job.kind] ?? j.job.kind.replace(/_/g, ' ')}<span className={`fd-chip is-${j.job.status}`}>{STATUS[j.job.status] ?? j.job.status.replace(/_/g, ' ')}</span></p>
        <h1 className="fd-next__car">{j.vehicle.name}</h1>
        <div className="fd-next__id">{j.vehicle.plate && <Plate plate={j.vehicle.plate} big />}{j.vehicle.colour ? <span className="small">{j.vehicle.colour}</span> : null}</div>
        {j.job.place && <p className="fd-next__place"><FdIcon name="pin" /><span>{j.job.place}</span></p>}
        {(j.job.place || b?.renter?.mobile) && <div className="fd-next__go">
          {j.job.place && <a className="btn fd-go" href={maps(j.job.place)} target="_blank" rel="noreferrer"><FdIcon name="pin" />Open in maps</a>}
          {b?.renter?.mobile && <ContactButtons phone={b.renter.mobile} name={b.renter.name} booking={b.booking_number} btnClass="btn fd-go" testId="fd-renter">Call {b.renter.name.split(' ')[0]}</ContactButtons>}
        </div>}
        {j.job.instructions && <p className="fd-bring small">{j.job.instructions}</p>}
        {/* the booking's facts: open before the job starts, folded away under the checklist once it runs */}
        {b && <details className="fd-more" open={j.job.status !== 'in_progress' || undefined}><summary>Booking {b.booking_number}</summary><dl className="fd-facts">
          {b.renter && <div><dt>Renter</dt><dd>{b.renter.name}{b.renter.mobile ? <>, <ContactButtons phone={b.renter.mobile} name={b.renter.name} booking={b.booking_number} look="link" testId="fd-renter-num">{b.renter.mobile}</ContactButtons></> : null}</dd></div>}
          {b.card?.last4 && <div><dt>Card on File</dt><dd>{b.card.brand ?? 'card'} ending {b.card.last4}</dd></div>}
          {b.drivers.map((d) => <div key={d.name}><dt>{d.role === 'renter' ? 'Driver' : d.role.replace(/_/g, ' ')}</dt><dd>{d.name}: licence {d.licence_number ?? ''}, class {d.licence_class ?? ''}, expires {d.licence_expiry ?? ''}</dd></div>)}
        </dl></details>}
        {b?.unattended && <p className="small"><b>Unattended handover approved.</b></p>}
        {j.walkthrough && j.report_kind !== 'ready' && <p className={`fd-walk small${j.walkthrough.read >= j.walkthrough.of ? ' is-ok' : ''}`} data-testid="job-walkthrough">
          <b>Renter&apos;s walkthrough:</b> read {j.walkthrough.read} of {j.walkthrough.of} steps{j.walkthrough.read < j.walkthrough.of ? '. Walk them through the rest at the car: what to bring, the walk-around, the road rules and the return.' : '.'}</p>}
      </header>
      {b?.addons && b.addons.length > 0 && !(card?.leg === 'pickup' && (card.addons?.length ?? 0) > 0 && !b.prepaid_fuel) && (
        <section className="fd-card fd-bring" aria-labelledby="addons-t" data-testid="job-addons">
          <h2 className="fd-bring__h" id="addons-t"><FdIcon name="bag" />{j.report_kind === 'return' ? 'Add-ons on this rental: check each came back' : 'Prepare: put in the car'}</h2>
          <ul className="small">{b.addons.map((a) => <li key={a.name}><b>{a.quantity} x {a.name}</b>{a.hours ? `, ${+a.hours} hours` : ''}{a.handover_note ? `: ${a.handover_note}` : ''}</li>)}</ul>
          {b.prepaid_fuel && <p className="pt-note small" data-testid="job-prepaid-fuel"><b>Prepaid fuel.</b> The renter may return the car at any fuel level. Do not charge for fuel.</p>}
        </section>
      )}
      {card && <JobCardSteps c={card} />}
      {b && !done && <p><Link prefetch={false} className="btn btn--ghost fd-wide" href={`/staff/field/help/${b.booking_number}`} data-testid="job-help"><FdIcon name="help" />Help the renter: pay, deposit, ID, sign</Link></p>}
      {/* 0770: a check stops the pickup or the return and the trip must go ahead: ask an Admin from here (one tap for them) */}
      {b && !done && (j.report_kind === 'pickup' || j.report_kind === 'return') && <HandoverOverride booking={b.id} userId={user.id} refresh={[`/staff/field/jobs/${id}`]} />}
      {lic && (
        <section className="fd-card" aria-labelledby="lic-t" data-testid="job-licence">
          <h2 className="fd-section-h" id="lic-t">Check the licence</h2>
          <p className="small">{lic.waiting} image{lic.waiting === 1 ? '' : 's'} of the renter&apos;s licence wait for a decision.</p>
          <LicenceReview job={id} waiting={lic.waiting} />
        </section>
      )}
      {/* release 42: with the car already? One tap acknowledges, starts and opens the one-screen checklist */}
      {j.job.status === 'scheduled' && <div className="fd-nextstep"><p className="small">{checklist ? 'With the car now? Start it in one tap. Not there yet? Press Acknowledge so the office knows you have this job.' : 'Press Acknowledge so the office knows you have this job. Start comes next, when you are with the car.'}</p>
        {checklist && <StartChecklist job={id} status={j.job.status} label={j.report_kind === 'pickup' ? 'Start the check-in now' : 'Start the check-out now'} testId="start-now" />}
        <FieldButton action="acknowledge" payload={{ job: id }} label="Acknowledge" primary={!checklist} testId="acknowledge" /></div>}
      {j.job.status === 'acknowledged' && <div className="fd-nextstep"><p className="small">With the car? Start opens the checklist.</p><FieldButton action="start" payload={{ job: id }} label="Start" primary testId="start" /></div>}
      {/* the rental agreement still waits for a signature: the renter (or a driver) signs on this phone (0130) */}
      {b && !done && (j.ready?.signed === false || b.drivers.some((d) => d.role !== 'renter' && !d.accepted)) && (
        <p><Link prefetch={false} className="btn btn--ghost fd-wide" href={`/staff/field/jobs/${id}/sign-now`} data-testid="field-sign-now">Sign now on this device</Link></p>)}
      {/* the deposit at pickup (0129) is taken from the ready check now, with e-Transfer and cash when allowed (0151) */}
      {j.job.status === 'in_progress' && checklist && <Checklist j={j} />}
      {j.job.status === 'in_progress' && j.checklist && <JobChecklist j={j} listing={listing} />}
      {done && <p className="fd-line is-ok fd-line--big" data-testid="job-done"><span aria-hidden="true">✓</span> Done {j.job.completed_at ? when(j.job.completed_at) : ''}</p>}
      {done && j.report_kind === 'return' && (
        <section className="fd-card" aria-labelledby="late-t">
          <h2 className="fd-section-h" id="late-t">Damage found later</h2>
          <p className="small">Found after the return, for example while cleaning: Fleet tells the renter.</p>
          <FieldButton action="late_damage" payload={{ job: id }} label="Record the damage" sheet={{ confirm: 'Save the damage' }} testId="late-damage" fields={[{ name: 'location', label: 'Where', required: true }, { name: 'description', label: 'What it is', required: true }, { name: 'size_cm', label: 'Size (cm)', numeric: true }]} />
        </section>
      )}
    </div>
  );
}
