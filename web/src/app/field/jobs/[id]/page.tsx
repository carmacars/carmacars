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

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Job', path: '/field', noindex: true, description: 'One field job and its checklist.' });

const maps = (p: string) => `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(p)}`;

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
  return (
    <div className="stack">
      <p><Link prefetch={false} className="link" href="/field">My jobs</Link></p>
      <header className="fd-card" data-testid="job-head">
        <p className="pt-kicker">{j.job.kind.replace(/_/g, ' ')} · {when(j.job.scheduled_at)} · {j.job.status.replace(/_/g, ' ')}</p>
        <h1 className="d3">{j.vehicle.name}</h1>
        <p><b className="fd-big">{j.vehicle.plate}</b>{j.vehicle.colour ? ` · ${j.vehicle.colour}` : ''}</p>
        {j.job.place && <p>{j.job.place} · <a className="link" href={maps(j.job.place)} target="_blank" rel="noreferrer">Open in maps</a></p>}
        {j.job.instructions && <p className="pt-note small">{j.job.instructions}</p>}
        {b && <>
          <p>{b.booking_number} · {b.renter?.name}{b.renter?.mobile ? <> · <a className="link" href={`tel:${b.renter.mobile.replace(/[^\d+]/g, '')}`}>{b.renter.mobile}</a></> : null}</p>
          {b.card?.last4 && <p className="small">Card on File: {b.card.brand ?? 'card'} ending {b.card.last4}</p>}
          {b.unattended && <p className="small"><b>Unattended handover approved.</b></p>}
          {b.drivers.length > 0 && <ul className="small">{b.drivers.map((d) => <li key={d.name}>{d.name}, {d.role.replace(/_/g, ' ')}: licence {d.licence_number ?? ''}, class {d.licence_class ?? ''}, expires {d.licence_expiry ?? ''}</li>)}</ul>}
        </>}
      </header>
      {b?.addons && b.addons.length > 0 && (
        <section className="fd-card" aria-labelledby="addons-t" data-testid="job-addons">
          <h2 className="d4" id="addons-t">{j.report_kind === 'return' ? 'Add-ons on this rental' : 'Put in the car'}</h2>
          <ul className="small">{b.addons.map((a) => <li key={a.name}><b>{a.quantity > 1 ? `${a.quantity} x ` : ''}{a.name}</b>{a.hours ? `, ${+a.hours} hours` : ''}{a.handover_note ? `: ${a.handover_note}` : ''}</li>)}</ul>
          {b.prepaid_fuel && <p className="pt-note small" data-testid="job-prepaid-fuel"><b>Prepaid fuel.</b> The renter may return the car at any fuel level. Do not charge for fuel.</p>}
        </section>
      )}
      {j.job.status === 'scheduled' && <FieldButton action="acknowledge" payload={{ job: id }} label="Acknowledge" primary testId="acknowledge" />}
      {j.job.status === 'acknowledged' && <FieldButton action="start" payload={{ job: id }} label="Start" primary testId="start" />}
      {/* the rental agreement still waits for a signature: the renter (or a driver) signs on this phone (0130) */}
      {b && !done && (j.ready?.signed === false || b.drivers.some((d) => d.role !== 'renter' && !d.accepted)) && (
        <p><Link prefetch={false} className="btn btn--ghost fd-wide" href={`/field/jobs/${id}/sign-now`} data-testid="field-sign-now">Sign now on this device</Link></p>)}
      {/* the deposit at pickup (0129) is taken from the ready check now, with e-Transfer and cash when allowed (0151) */}
      {j.job.status === 'in_progress' && checklist && <Checklist j={j} />}
      {j.job.status === 'in_progress' && j.checklist && <JobChecklist j={j} listing={listing} />}
      {done && <p className="fd-line is-ok" data-testid="job-done"><span aria-hidden="true">✓</span> Done {j.job.completed_at ? when(j.job.completed_at) : ''}</p>}
      {done && j.report_kind === 'return' && (
        <section className="fd-card" aria-labelledby="late-t">
          <h2 className="d4" id="late-t">Damage found later</h2>
          <p className="small">Found after the return, for example while cleaning: Fleet tells the renter.</p>
          <FieldButton action="late_damage" payload={{ job: id }} label="Record the damage" testId="late-damage" fields={[{ name: 'location', label: 'Where', required: true }, { name: 'description', label: 'What it is', required: true }, { name: 'size_cm', label: 'Size (cm)', numeric: true }]} />
        </section>
      )}
    </div>
  );
}
