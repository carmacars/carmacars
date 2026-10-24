import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { FieldButton } from '@/features/field/FieldButton';
import { StartChecklist } from '@/features/field/StartChecklist';
import type { FieldCard, FieldList } from '@/features/field/types';
import { when } from '@/features/agreement/model';
import { getTokens } from '@/lib/site';
import { signCount } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My jobs', path: '/field', noindex: true, description: 'Today\'s and tomorrow\'s field jobs.' });

const KIND: Record<string, string> = { handover: 'Handover', delivery: 'Delivery', return_check_in: 'Return check-in', pickup_from_renter: 'Pickup from renter', detail: 'Detail', photo_shoot: 'Photo shoot', tracker_install: 'Tracker install', tracker_removal: 'Tracker removal', registry_run: 'Registry run', recovery: 'Recovery', other: 'Other' };
const CHECK: Record<string, string> = { handover: 'Check out (pickup)', delivery: 'Check out (pickup)', return_check_in: 'Check in (return)', pickup_from_renter: 'Check in (return)' };
const maps = (p: string) => `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(p)}`;

// Today and tomorrow (06-field.md section 2): the field staff member's own jobs in time order, the next one
// first and open; acknowledge and start from the card; vehicle moves.
export default async function Field({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireStaff('field', '/field'), searchParams]);
  const [d, tk, toSign] = await Promise.all([door<FieldList>(user.id, 'field_read', 'jobs'), getTokens(), signCount(user.id)]);
  const day = sp.day === 'tomorrow' ? 'tomorrow' : 'today';
  const jobs = d[day];
  const next = jobs.find((j) => !['done'].includes(j.status));
  return (
    <>
      <h1 className="d3">My jobs{d.name ? `, ${d.name.split(' ')[0]}` : ''}</h1>
      {toSign > 0 && <p className="alert alert--warn" role="status" data-testid="field-to-sign"><span>You have {toSign === 1 ? 'a document' : `${toSign} documents`} to sign. <Link prefetch={false} className="link" href="/field/sign">Read and sign</Link></span></p>}
      <nav className="fd-days" aria-label="Day"><Link prefetch={false} href="/field" aria-current={day === 'today' ? 'page' : undefined}>Today ({d.today.length})</Link><Link prefetch={false} href="/field?day=tomorrow" aria-current={day === 'tomorrow' ? 'page' : undefined}>Tomorrow ({d.tomorrow.length})</Link></nav>
      {!jobs.length && <div className="pt-empty" data-testid="no-jobs"><p>No jobs {day}.</p><p className="small muted">{day === 'today' ? 'New jobs show up here as CarmaCars books them. Tomorrow shows what is coming.' : 'Jobs for tomorrow show up here as they are booked.'}</p></div>}
      {jobs.map((j: FieldCard) => (
        <section key={j.field_job_id} className={`fd-card${j === next ? ' is-next' : ''}`} aria-labelledby={`j-${j.field_job_id}`} data-testid="job-card">
          <p className="pt-kicker">{when(j.scheduled_at)} · {j.status.replace(/_/g, ' ')}</p>
          <h2 className="d4" id={`j-${j.field_job_id}`}>{KIND[j.kind] ?? j.kind}: {j.vehicle_label}</h2>
          <p className="small">{j.plate ?? ''}{j.renter_first_name ? ` · ${j.renter_first_name}` : ''}{j.booking_number ? ` · ${j.booking_number}` : ''}</p>
          {j.place && <p className="small">{j.place} · <a className="link" href={maps(j.place)} target="_blank" rel="noreferrer">Open in maps</a></p>}
          {/* a check-out or a check-in: one tap starts the job and opens its photo checklist (0130) */}
          {CHECK[j.kind] && j.status !== 'done' && <StartChecklist job={j.field_job_id} status={j.status} label={CHECK[j.kind]!} testId={CHECK[j.kind] === 'Check out (pickup)' ? 'field-checkout' : 'field-checkin'} />}
          {j.status === 'scheduled' && <><p className="small"><b>Please acknowledge this job.</b></p><FieldButton action="acknowledge" payload={{ job: j.field_job_id }} label="Acknowledge" primary={!CHECK[j.kind]} testId="acknowledge" /></>}
          <Link prefetch={false} className={`btn ${j.status === 'scheduled' || CHECK[j.kind] ? 'btn--ghost' : 'btn--primary'} fd-wide`} href={`/field/jobs/${j.field_job_id}`} data-testid="open-job">Open the job</Link>
        </section>
      ))}
      {/* vehicle moves: shown when there is a car to move or a move to end (an empty card with nothing to press is clutter) */}
      {(d.vehicles.length > 0 || d.moves.length > 0) && <section className="fd-card" aria-labelledby="moves-t">
        <h2 className="d4" id="moves-t">Vehicle moves</h2>
        {d.moves.map((m) => <div key={m.id} className="stack"><p className="small">{m.vehicle_name}, since {when(m.started_at)}{m.from_place ? ` from ${m.from_place}` : ''}</p>
          <FieldButton action="move_end" payload={{ move: m.id }} label="End the move" testId="move-end" fields={[{ name: 'to_place', label: 'Now at', address: true }, { name: 'odometer', label: 'Odometer (km)', numeric: true }]} /></div>)}
        {d.vehicles.length > 0 && <FieldButton action="move_start" payload={{}} label="Start a move" testId="move-start" fields={[{ name: 'vehicle', label: 'Car', options: d.vehicles.map((v) => [v.id, v.name] as [string, string]) },
          { name: 'purpose', label: 'Why', options: [['repositioning', 'Reposition'], ['service', 'Service or repair'], ['detail', 'To the detailer'], ['other', 'Other']] }, { name: 'from_place', label: 'From', address: true }, { name: 'odometer', label: 'Odometer (km)', numeric: true }]} />}
      </section>}
      {tk.phone && <p className="small"><a className="link" href={`tel:${tk.phone.replace(/[^\d+]/g, '')}`}>Call CarmaCars, {tk.phone}</a></p>}
    </>
  );
}
