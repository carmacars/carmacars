import Link from 'next/link';
import { PuIcon } from '@/components/portal-ui/icons';
import { STATE_WORDS, CAR_STATES, countStates, torontoDay, type CarRow, type CarState } from './carboard';

// Fleet's day (October 25, 2026): today's handovers, returns and moves as one timeline by the clock, and every car's
// state now as a board. Styles in styles/va.css.
type R = Record<string, unknown>;
const clock = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)).replace('a.m.', 'AM').replace('p.m.', 'PM');
const OUT = ['handover', 'delivery'];
const BACK = ['return_check_in', 'pickup_from_renter'];
export const jobWord = (kind: string) => (OUT.includes(kind) ? 'Handover' : BACK.includes(kind) ? 'Return' : kind.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase()));

/** Today's jobs (and any still open from before), by the clock. */
export function todaysJobs(jobs: R[], now: number): R[] {
  const today = torontoDay(now);
  return jobs.filter((j) => !['done', 'cancelled'].includes(String(j.status)) && (torontoDay(Date.parse(String(j.scheduled_at))) === today || Date.parse(String(j.scheduled_at)) < now))
    .sort((a, b) => String(a.scheduled_at).localeCompare(String(b.scheduled_at)));
}

export function DayTimeline({ jobs, now, testId = 'va-day', title = 'Today: handovers, returns and moves' }: { jobs: R[]; now: number; testId?: string; title?: string }) {
  const rows = todaysJobs(jobs, now);
  return (
    <section className="va-section pu-panel" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <div className="va-section__head"><h2 className="va-section__title" id={`${testId}-h`}>{title}</h2>
        <p className="va-section__note">{rows.length ? `${rows.length} job${rows.length === 1 ? '' : 's'} left today` : 'Nothing left today'}</p></div>
      {rows.length ? (
        <ol className="va-day">{rows.map((j) => {
          const at = Date.parse(String(j.scheduled_at));
          const late = at < now;
          const nobody = !j.assigned_to;
          const unack = !nobody && !j.acknowledged_at;
          const kind = String(j.kind);
          return (
            <li key={String(j.id)} className={`va-day__item${late ? ' is-late' : ''}${OUT.includes(kind) ? ' is-out' : BACK.includes(kind) ? ' is-back' : ' is-move'}`}>
              <time className="va-day__time" dateTime={String(j.scheduled_at)}>{clock(String(j.scheduled_at))}</time>
              <span className="va-day__dot" aria-hidden="true" />
              <span className="va-day__body">
                <span className="va-day__title"><b>{jobWord(kind)}</b> {String(j.vehicle_name ?? '')}{j.booking_number ? <> · <Link prefetch={false} className="link" href={`/staff/bookings/${encodeURIComponent(String(j.booking_number))}`}>{String(j.booking_number)}</Link></> : null}</span>
                <span className="va-day__meta">
                  {j.place ? <span>{String(j.place)}</span> : null}
                  <span className={nobody ? 'va-warn' : undefined}>{nobody ? 'Nobody assigned' : `${String(j.assignee_name ?? '')}${unack ? ', not acknowledged' : ''}`}</span>
                  {late && <span className="va-warn">Past its time</span>}
                </span>
              </span>
            </li>);
        })}</ol>
      ) : <p className="va-empty-line"><PuIcon name="check" /> No handover, return or move left today.</p>}
    </section>
  );
}

const TONE: Record<CarState, string> = { late: 'accent', out_today: 'ready', back_today: 'ready', on_rent: 'live', blocked: 'service', turo: 'muted', free: 'muted' };

export function CarBoard({ rows, now, testId = 'va-cars', compact = false, carHref }: { rows: CarRow[]; now: number; testId?: string; compact?: boolean; carHref?: (id: string) => string }) {
  const n = countStates(rows);
  const shown = compact ? rows.filter((r) => ['late', 'out_today', 'back_today'].includes(r.state)).slice(0, 6) : rows;
  return (
    <section className="va-section pu-panel" aria-labelledby={`${testId}-h`} data-testid={testId} id="cars">
      <div className="va-section__head"><h2 className="va-section__title" id={`${testId}-h`}>Cars right now</h2>
        <p className="va-section__note">{rows.length} car{rows.length === 1 ? '' : 's'}</p></div>
      <ul className="va-carstates" aria-label="Cars by state">
        {CAR_STATES.map((s) => <li key={s} className={`va-carstate va-carstate--${s}`} data-state={s}><b>{n[s]}</b><span>{STATE_WORDS[s]}</span></li>)}
      </ul>
      {shown.length ? (
        <ul className="va-cars">{shown.map((r) => (
          <li key={r.id} className="va-car">
            <span className={`pu-pill pu-pill--${TONE[r.state]}`}>{STATE_WORDS[r.state]}</span>
            <span className="va-car__name">{carHref ? <Link prefetch={false} className="link" href={carHref(r.id)}>{r.label}</Link> : r.label}{r.plate ? <span className="va-car__plate">{r.plate}</span> : null}</span>
            <span className="va-car__when">{r.at ? `${r.state === 'out_today' ? 'out' : r.state === 'free' ? '' : 'until'} ${clock(r.at)}${torontoDay(Date.parse(r.at)) !== torontoDay(now) ? `, ${new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' }).format(new Date(r.at))}` : ''}` : r.note ?? ''}
              {r.booking ? <> · <Link prefetch={false} className="link" href={`/staff/bookings/${encodeURIComponent(r.booking)}`}>{r.booking}</Link></> : null}</span>
          </li>))}</ul>
      ) : compact ? <p className="va-empty-line"><PuIcon name="check" /> No car goes out or comes back today.</p> : <p className="va-empty-line">No cars.</p>}
    </section>
  );
}
