import '@/styles/field.css';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { door } from '@/server/door';
import { Checklist } from '@/features/field/Checklist';
import type { FieldJob } from '@/features/field/types';
import { when } from '@/features/agreement/model';

// Check-out or check-in from the booking page (migration 0130): the field portal's checklist, run by an Admin or an
// assistant on the job the database assigned to them (app.handover_open). The same screens, the same rules: the ready
// check, the readings, the photo set with its upload queue, damage marks, signatures; the database completes it.
export async function HandoverRun({ userId, aal, job, number, base }: { userId: string; aal?: 'aal1' | 'aal2' | null; job: string; number: string; base: string }) {
  if (!/^[0-9a-f-]{36}$/.test(job)) notFound();
  const j = await door<FieldJob | null>(userId, 'field_read', 'job', { id: job }, aal).catch(() => null);
  if (!j || !j.booking || j.booking.booking_number !== number) notFound();
  const pickup = j.report_kind === 'pickup';
  return (
    <div className="stack fd-staff" data-testid="handover-run">
      <p><Link prefetch={false} className="link" href={base}>Booking {number}</Link></p>
      <header className="fd-card" data-testid="job-head">
        <p className="pt-kicker">{pickup ? 'Check out (pickup)' : 'Check in (return)'} · due {when(pickup ? j.booking.pickup_at : j.booking.return_at)}</p>
        <h1 className="d3">{j.vehicle.name}</h1>
        <p><b className="fd-big">{j.vehicle.plate}</b>{j.vehicle.colour ? ` · ${j.vehicle.colour}` : ''}</p>
        <p>{j.booking.renter?.name}{j.booking.renter?.mobile ? <> · <a className="link" href={`tel:${j.booking.renter.mobile.replace(/[^\d+]/g, '')}`}>{j.booking.renter.mobile}</a></> : null}</p>
        {j.job.place && <p className="small">{j.job.place}</p>}
      </header>
      {j.job.status === 'done'
        ? <div className="fd-card stack"><p className="fd-line is-ok" data-testid="job-done"><span aria-hidden="true">✓</span> Done {j.job.completed_at ? when(j.job.completed_at) : ''}</p>
            <Link prefetch={false} className="btn btn--primary" href={`${base}/report`}>See the photo report</Link></div>
        : <Checklist j={j} back={`${base}/report`} backLabel="See the photo report" />}
    </div>
  );
}
