import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { FieldButton } from '@/features/field/FieldButton';
import { StartChecklist } from '@/features/field/StartChecklist';
import { Plate } from '@/features/field/Plate';
import { FdIcon } from '@/features/field/icons';
import { LicenceReview } from '@/features/field/LicenceReview';
import { CHECK, KIND, STATUS, clock, dayLabel, fromNow, maps, tel } from '@/features/field/format';
import type { FieldCard, FieldJob, FieldList, LicenceCard } from '@/features/field/types';
import { when } from '@/features/agreement/model';
import { getTokens } from '@/lib/site';
import { signCount } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My jobs', path: '/field', noindex: true, description: 'Today\'s and tomorrow\'s field jobs.' });

const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric' }).format(new Date());

// Today and tomorrow (06-field.md section 2): the field staff member's own jobs in time order. The next job is the
// big card at the top (its time, the car's plate, the place with Maps and a call to the renter, what to bring and the
// one button that starts it); the rest follow as a timeline. Vehicle moves below. (2026-10-25 design pass.)
export default async function Field({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireStaff('field', '/field'), searchParams]);
  // 0162: the licences of the renters on their upcoming jobs (today and the next 7 days) that wait for a decision
  const [d, tk, toSign, licences] = await Promise.all([door<FieldList>(user.id, 'field_read', 'jobs'), getTokens(), signCount(user.id),
    door<LicenceCard[]>(user.id, 'field_read', 'licences').catch(() => [] as LicenceCard[])]);
  const day = sp.day === 'tomorrow' ? 'tomorrow' : 'today';
  const jobs = d[day];
  const next = jobs.find((j) => !['done'].includes(j.status));
  // the next job's details (the renter's phone, what goes in the car, the office's note): the same read as the job page
  const nj = next ? await door<FieldJob | null>(user.id, 'field_read', 'job', { id: next.field_job_id }).catch(() => null) : null;
  const rest = jobs.filter((j) => j !== next);
  const done = jobs.filter((j) => j.status === 'done').length;
  return (
    <>
      <header className="fd-home">
        <h1 className="fd-home__h">My jobs{d.name ? <span className="fd-home__name">, {d.name.split(' ')[0]}</span> : ''}</h1>
        <p className="fd-home__sub">{today()}{d.today.length ? <>. {done && day === 'today' ? `${done} of ${d.today.length} done` : `${d.today.length} today`}</> : null}</p>
      </header>
      {toSign > 0 && <p className="alert alert--warn" role="status" data-testid="field-to-sign"><span>You have {toSign === 1 ? 'a document' : `${toSign} documents`} to sign. <Link prefetch={false} className="link" href="/field/sign">Read and sign</Link></span></p>}
      {licences.length > 0 && <section className="fd-licences" aria-labelledby="lic-t" data-testid="field-licences">
        <h2 className="fd-section-h" id="lic-t">Licences to check <span className="fd-days__n">{licences.length}</span></h2>
        <p className="small">The renter's licence and selfie on your next jobs wait for a decision. Look at them and approve, or reject with a reason.</p>
        <ul className="fd-lic-list">{licences.map((l) => <li key={l.field_job_id} className="fd-lic-card" data-testid="licence-card">
          <p className="fd-lic-card__when">{dayLabel(l.scheduled_at)}, {clock(l.scheduled_at).time} {clock(l.scheduled_at).half}<span className="small"> · {KIND[l.kind] ?? l.kind}</span></p>
          <p className="fd-lic-card__car">{l.vehicle_label}</p>
          <div className="fd-lic-card__id">{l.plate && <Plate plate={l.plate} small />}<span className="small">{[l.renter_first_name, l.booking_number].filter(Boolean).join(', ')}, {l.waiting} image{l.waiting === 1 ? '' : 's'} waiting</span></div>
          <LicenceReview job={l.field_job_id} waiting={l.waiting} />
        </li>)}</ul>
      </section>}
      <nav className="fd-days" aria-label="Day">
        <Link prefetch={false} href="/field" aria-current={day === 'today' ? 'page' : undefined}>Today <span className="fd-days__n">{d.today.length}</span></Link>
        <Link prefetch={false} href="/field?day=tomorrow" aria-current={day === 'tomorrow' ? 'page' : undefined}>Tomorrow <span className="fd-days__n">{d.tomorrow.length}</span></Link>
      </nav>
      {!jobs.length && <div className="fd-empty" data-testid="no-jobs"><FdIcon name="car" className="fd-empty__ico" /><p className="fd-empty__h">No jobs {day}.</p><p className="small">{day === 'today' ? 'New jobs show up here as CarmaCars books them. Tomorrow shows what is coming.' : 'Jobs for tomorrow show up here as they are booked.'}</p></div>}
      {next && <NextJob j={next} detail={nj} />}
      {rest.length > 0 && <section aria-labelledby="later-t" className="fd-later">
        <h2 className="fd-section-h" id="later-t">{next ? (day === 'today' ? 'Also today' : 'Also tomorrow') : 'Done'}</h2>
        <ol className="fd-tl">{rest.map((j) => <TimelineJob key={j.field_job_id} j={j} />)}</ol>
      </section>}
      {/* vehicle moves: shown when there is a car to move or a move to end (an empty card with nothing to press is clutter) */}
      {(d.vehicles.length > 0 || d.moves.length > 0) && <section className="fd-card fd-moves" aria-labelledby="moves-t">
        <h2 className="fd-section-h" id="moves-t">Vehicle moves</h2>
        {d.moves.map((m) => <div key={m.id} className="fd-move">
          <p className="fd-move__what"><FdIcon name="car" /><span><b>{m.vehicle_name}</b><span className="small"> on the move since {when(m.started_at)}{m.from_place ? `, from ${m.from_place}` : ''}</span></span></p>
          <FieldButton action="move_end" payload={{ move: m.id }} label="End the move" sheet={{ confirm: 'End the move now', title: `End the move: ${m.vehicle_name}` }} primary testId="move-end" fields={[{ name: 'to_place', label: 'Now at', address: true }, { name: 'odometer', label: 'Odometer (km)', numeric: true }]} /></div>)}
        {d.vehicles.length > 0 && <FieldButton action="move_start" payload={{}} label="Start a move" sheet={{ confirm: 'Start the move now', title: 'Start a move' }} testId="move-start" fields={[{ name: 'vehicle', label: 'Car', options: d.vehicles.map((v) => [v.id, v.name] as [string, string]) },
          { name: 'purpose', label: 'Why', options: [['repositioning', 'Reposition'], ['service', 'Service or repair'], ['detail', 'To the detailer'], ['other', 'Other']] }, { name: 'from_place', label: 'From', address: true }, { name: 'odometer', label: 'Odometer (km)', numeric: true }]} />}
      </section>}
      {tk.phone && <a className="btn btn--ghost fd-wide fd-call" href={tel(tk.phone)}><FdIcon name="phone" />Call CarmaCars, {tk.phone}</a>}
    </>
  );
}

// The job to do next: everything needed to get there and start, in reading order, with the button at the bottom.
function NextJob({ j, detail }: { j: FieldCard; detail: FieldJob | null }) {
  const c = clock(j.scheduled_at);
  const rel = fromNow(j.scheduled_at, detail?.now ?? new Date());
  const check = CHECK[j.kind];
  const b = detail?.booking ?? null;
  const bring = [...(b?.addons ?? []).map((a) => `${a.quantity > 1 ? `${a.quantity} x ` : ''}${a.name}${a.handover_note ? `: ${a.handover_note}` : ''}`), ...(b?.prepaid_fuel ? ['Prepaid fuel: no fuel charge at the return'] : [])];
  return (
    <section className={`fd-next is-${j.status}`} aria-labelledby={`j-${j.field_job_id}`} data-testid="job-card">
      <div className="fd-next__when">
        <p className="fd-next__time"><span className="vh">Next job at </span>{c.time}<span className="fd-next__half">{c.half}</span></p>
        <p className={`fd-next__rel${rel.late && j.status !== 'in_progress' ? ' is-late' : ''}`}>{j.status === 'in_progress' ? 'In progress' : rel.text}</p>
      </div>
      <p className="fd-next__kind">{KIND[j.kind] ?? j.kind}<span className={`fd-chip is-${j.status}`}>{STATUS[j.status] ?? j.status.replace(/_/g, ' ')}</span></p>
      <h2 className="fd-next__car" id={`j-${j.field_job_id}`}>{j.vehicle_label}</h2>
      <div className="fd-next__id">{j.plate && <Plate plate={j.plate} />}<span className="small">{[j.renter_first_name, j.booking_number].filter(Boolean).join(', ')}</span></div>
      {j.place && <p className="fd-next__place"><FdIcon name="pin" /><span>{j.place}</span></p>}
      {(j.place || b?.renter?.mobile) && <div className="fd-next__go">
        {j.place && <a className="btn fd-go" href={maps(j.place)} target="_blank" rel="noreferrer"><FdIcon name="pin" />Open in maps</a>}
        {b?.renter?.mobile && <a className="btn fd-go" href={tel(b.renter.mobile)}><FdIcon name="phone" />Call {j.renter_first_name ?? 'the renter'}</a>}
      </div>}
      {(bring.length > 0 || detail?.job.instructions) && <div className="fd-bring">
        <p className="fd-bring__h"><FdIcon name="bag" />{bring.length ? 'Put in the car' : 'From the office'}</p>
        {bring.length > 0 && <ul>{bring.map((x) => <li key={x}>{x}</li>)}</ul>}
        {detail?.job.instructions && <p className="small">{detail.job.instructions}</p>}
      </div>}
      {j.status === 'scheduled' && <p className="fd-next__ack">Please acknowledge this job.</p>}
      <div className="fd-next__do">
        {/* a check-out or a check-in: one tap starts the job and opens its photo checklist (0130) */}
        {check && <StartChecklist job={j.field_job_id} status={j.status} label={check} testId={check === 'Check out (pickup)' ? 'field-checkout' : 'field-checkin'} />}
        {j.status === 'scheduled' && <FieldButton action="acknowledge" payload={{ job: j.field_job_id }} label="Acknowledge" primary={!check} testId="acknowledge" />}
        <Link prefetch={false} className={`btn ${j.status === 'scheduled' || check ? 'btn--ghost' : 'btn--primary'} fd-wide`} href={`/field/jobs/${j.field_job_id}`} data-testid="open-job">Open the job</Link>
      </div>
    </section>
  );
}

// One more job of the day: its time on the rail, the car and the place, and its own buttons.
function TimelineJob({ j }: { j: FieldCard }) {
  const c = clock(j.scheduled_at);
  const check = CHECK[j.kind];
  const isDone = j.status === 'done';
  return (
    <li className={`fd-tl__item is-${j.status}`}>
      <p className="fd-tl__time">{c.time}<span>{c.half}</span></p>
      <section className="fd-tl__card" aria-labelledby={`j-${j.field_job_id}`} data-testid="job-card">
        <p className="fd-tl__kind">{KIND[j.kind] ?? j.kind}<span className={`fd-chip is-${j.status}`}>{isDone ? <><FdIcon name="check" />Done</> : STATUS[j.status] ?? j.status.replace(/_/g, ' ')}</span></p>
        <h3 className="fd-tl__car" id={`j-${j.field_job_id}`}>{j.vehicle_label}</h3>
        <div className="fd-next__id">{j.plate && <Plate plate={j.plate} small />}<span className="small">{[j.renter_first_name, j.booking_number].filter(Boolean).join(', ')}</span></div>
        {j.place && <p className="fd-tl__place"><FdIcon name="pin" /><span>{j.place}</span> <a className="link" href={maps(j.place)} target="_blank" rel="noreferrer">Open in maps</a></p>}
        {!isDone && <div className="fd-tl__do">
          {check && <StartChecklist job={j.field_job_id} status={j.status} label={check} testId={check === 'Check out (pickup)' ? 'field-checkout' : 'field-checkin'} />}
          {j.status === 'scheduled' && <><p className="small"><b>Please acknowledge this job.</b></p><FieldButton action="acknowledge" payload={{ job: j.field_job_id }} label="Acknowledge" primary={!check} testId="acknowledge" /></>}
          <Link prefetch={false} className="btn btn--ghost fd-wide" href={`/field/jobs/${j.field_job_id}`} data-testid="open-job">Open the job</Link>
        </div>}
        {isDone && <Link prefetch={false} className="link small" href={`/field/jobs/${j.field_job_id}`} data-testid="open-job">Open the job</Link>}
      </section>
    </li>
  );
}
