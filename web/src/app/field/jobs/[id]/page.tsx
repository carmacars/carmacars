import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { Checklist } from '@/features/field/Checklist';
import { FieldButton } from '@/features/field/FieldButton';
import { JobChecklist } from '@/features/field/JobChecklist';
import { ListingCapture, type Capture } from '@/features/listing/ListingCapture';
import { StartListing } from '@/features/listing/StartListing';
import type { FieldJob } from '@/features/field/types';
import { when } from '@/features/agreement/model';
import { Plate } from '@/features/field/Plate';
import { FdIcon } from '@/features/field/icons';
import { KIND, STATUS, clock, maps, tel } from '@/features/field/format';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Job', path: '/field', noindex: true, description: 'One field job and its checklist.' });


// One job (06-field.md section 3): the header, then Start, then the checklist for its kind. A job that is
// not the user's, cancelled or outside its window reads as not found.
export default async function FieldJobPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await requireStaff('field', `/field/jobs/${id}`);
  const j = await door<FieldJob | null>(user.id, 'field_read', 'job', { id }).catch(() => null);
  if (!j) notFound();
  const b = j.booking;
  const checklist = !j.checklist && (j.report_kind === 'pickup' || j.report_kind === 'return');
  const done = j.job.status === 'done';
  // a photo shoot (procedure 17): the listing capture of the car, as owners and Fleet use it (migration 0032)
  const cap = j.job.kind === 'photo_shoot' && j.checklist?.listing && j.job.status === 'in_progress'
    ? await door<Capture>(user.id, 'ops_read', 'listing_capture', { intake: j.checklist.listing.intake_id }).catch(() => null) : null;
  const listing = j.job.kind !== 'photo_shoot' ? null : cap ? <ListingCapture initial={cap} refresh={[`/field/jobs/${id}`]} />
    : j.checklist?.listing?.submitted_at ? <p className="fd-line is-ok">Submitted for listing.</p> : <StartListing vehicleId={j.vehicle.id} label="Start the listing photos" />;
  const c = clock(j.job.scheduled_at);
  return (
    <div className="stack fd-job">
      <p><Link prefetch={false} className="fd-back" href="/field"><FdIcon name="back" />My jobs</Link></p>
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
          {b?.renter?.mobile && <a className="btn fd-go" href={tel(b.renter.mobile)}><FdIcon name="phone" />Call {b.renter.name.split(' ')[0]}</a>}
        </div>}
        {j.job.instructions && <p className="fd-bring small">{j.job.instructions}</p>}
        {/* the booking's facts: open before the job starts, folded away under the checklist once it runs */}
        {b && <details className="fd-more" open={j.job.status !== 'in_progress' || undefined}><summary>Booking {b.booking_number}</summary><dl className="fd-facts">
          {b.renter && <div><dt>Renter</dt><dd>{b.renter.name}{b.renter.mobile ? <>, <a className="link" href={tel(b.renter.mobile)}>{b.renter.mobile}</a></> : null}</dd></div>}
          {b.card?.last4 && <div><dt>Card on File</dt><dd>{b.card.brand ?? 'card'} ending {b.card.last4}</dd></div>}
          {b.drivers.map((d) => <div key={d.name}><dt>{d.role === 'renter' ? 'Driver' : d.role.replace(/_/g, ' ')}</dt><dd>{d.name}: licence {d.licence_number ?? ''}, class {d.licence_class ?? ''}, expires {d.licence_expiry ?? ''}</dd></div>)}
        </dl></details>}
        {b?.unattended && <p className="small"><b>Unattended handover approved.</b></p>}
      </header>
      {b?.addons && b.addons.length > 0 && (
        <section className="fd-card fd-bring" aria-labelledby="addons-t" data-testid="job-addons">
          <h2 className="fd-bring__h" id="addons-t"><FdIcon name="bag" />{j.report_kind === 'return' ? 'Add-ons on this rental' : 'Put in the car'}</h2>
          <ul className="small">{b.addons.map((a) => <li key={a.name}><b>{a.quantity > 1 ? `${a.quantity} x ` : ''}{a.name}</b>{a.hours ? `, ${+a.hours} hours` : ''}{a.handover_note ? `: ${a.handover_note}` : ''}</li>)}</ul>
          {b.prepaid_fuel && <p className="pt-note small" data-testid="job-prepaid-fuel"><b>Prepaid fuel.</b> The renter may return the car at any fuel level. Do not charge for fuel.</p>}
        </section>
      )}
      {j.job.status === 'scheduled' && <div className="fd-nextstep"><p className="small">Press Acknowledge so the office knows you have this job. Start comes next, when you are with the car.</p><FieldButton action="acknowledge" payload={{ job: id }} label="Acknowledge" primary testId="acknowledge" /></div>}
      {j.job.status === 'acknowledged' && <div className="fd-nextstep"><p className="small">With the car? Start opens the checklist.</p><FieldButton action="start" payload={{ job: id }} label="Start" primary testId="start" /></div>}
      {/* the rental agreement still waits for a signature: the renter (or a driver) signs on this phone (0130) */}
      {b && !done && (j.ready?.signed === false || b.drivers.some((d) => d.role !== 'renter' && !d.accepted)) && (
        <p><Link prefetch={false} className="btn btn--ghost fd-wide" href={`/field/jobs/${id}/sign-now`} data-testid="field-sign-now">Sign now on this device</Link></p>)}
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
