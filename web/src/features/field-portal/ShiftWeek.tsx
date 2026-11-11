import '@/styles/shift-picker.css';
import Link from '@/components/Link';
import { FieldButton } from '@/features/field/FieldButton';
import { clockText, jobsText, type ShiftJobs } from './model';
import { WEEKDAYS, WEEKDAYS_SHORT, buildWeek, type WeekItem } from './shift-picker';

// My shifts as a week (r35 part SP, 1770): seven days side by side, swiped on a phone (scroll snap; the day strip above jumps to a
// day without JavaScript), each day with my shifts, the shifts free to claim (one tap), offers and swaps asked of me. The card
// list stays as the List tab, the fallback.
export type CalItem = WeekItem & { jobs?: ShiftJobs; note?: string | null; free?: number; capacity?: number; from?: string; swapId?: string; theirs?: string };
const dayNum = (d: string) => Number(d.slice(8, 10));
const month = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'short' }).format(new Date(`${d}T12:00:00Z`));

export function ShiftWeek({ items, now, week }: { items: CalItem[]; now: number; week: number }) {
  const days = buildWeek(items, now, week);
  const first = days[0]!.day, last = days[6]!.day;
  return (
    <section aria-labelledby="sp-week-h" data-testid="shift-week">
      <h2 className="vh" id="sp-week-h">Week of {month(first)} {dayNum(first)} to {month(last)} {dayNum(last)}</h2>
      <nav className="sp-weeks" aria-label="Weeks">{[0, 1, 2].map((w) => <Link key={w} prefetch={false} href={`/staff/field/shifts?view=week&week=${w}`} aria-current={w === week ? 'page' : undefined} data-testid={`week-${w}`}>
        {w === 0 ? 'This week' : w === 1 ? 'Next week' : 'In 2 weeks'}</Link>)}</nav>
      <nav className="sp-daynav" aria-label="Days">{days.map((d) => <a key={d.day} href={`#d-${d.day}`} className={d.today ? 'is-today' : undefined} aria-label={`${WEEKDAYS[d.dow - 1]} ${month(d.day)} ${dayNum(d.day)}: ${d.items.length} item${d.items.length === 1 ? '' : 's'}`}>
        <span aria-hidden="true">{WEEKDAYS_SHORT[d.dow - 1]}</span><b aria-hidden="true">{dayNum(d.day)}</b>
        <i aria-hidden="true" className={d.items.some((x) => x.kind === 'mine') ? 'is-mine' : d.items.some((x) => x.kind !== 'mine') ? 'is-open' : undefined} /></a>)}</nav>
      <div className="sp-week" tabIndex={0} aria-label="The week, swipe for the next day">
        {days.map((d) => <article key={d.day} id={`d-${d.day}`} className={`sp-day${d.today ? ' is-today' : ''}`} data-testid="week-day" aria-labelledby={`h-${d.day}`}>
          <h3 id={`h-${d.day}`}>{WEEKDAYS[d.dow - 1]} {dayNum(d.day)}<small>{d.today ? 'Today' : month(d.day)}</small></h3>
          {d.items.length === 0 && <p className="sp-empty">Nothing on this day.</p>}
          {d.items.map((x) => <Item key={`${x.kind}-${x.id}`} x={x as CalItem} now={now} />)}
        </article>)}
      </div>
    </section>
  );
}

function Item({ x, now }: { x: CalItem; now: number }) {
  const time = `${clockText(x.starts_at)} to ${clockText(x.ends_at)}`;
  const jobs = jobsText(x.jobs);
  if (x.kind === 'mine') return <div className="sp-item is-mine" data-testid="week-mine">
    <p className="sp-item__tag">{x.standing ? 'Yours, standing' : 'Yours'}</p><p className="sp-item__time">{time}</p>
    {jobs && <p className="small">On it: {jobs}</p>}{x.note && <p className="small">{x.note}</p>}
    {new Date(x.starts_at).getTime() > now && <Link prefetch={false} className="small link" href={`/staff/field/shifts?view=list#s-${x.id}`} style={{ color: 'inherit' }}>Give up or swap</Link>}</div>;
  if (x.kind === 'swap') return <div className="sp-item is-swap" data-testid="week-swap">
    <p className="sp-item__tag">{x.from} asks to swap</p><p className="sp-item__time">{time}</p><p className="small">They take yours: {x.theirs}</p>
    <FieldButton action="swap_answer" payload={{ id: x.swapId, accept: true }} label="Accept the swap" primary testId={`week-swap-accept-${x.swapId}`} />
    <FieldButton action="swap_answer" payload={{ id: x.swapId, accept: false }} label="Decline" testId={`week-swap-decline-${x.swapId}`} /></div>;
  const offer = x.kind === 'offer';
  return <div className={`sp-item ${offer ? 'is-offer' : 'is-open'}`} data-testid={offer ? 'week-offer' : 'week-open'}>
    <p className="sp-item__tag">{offer ? `Given up by ${x.from}` : `${x.free} of ${x.capacity} free`}{x.fits ? ' · fits your times' : ''}</p>
    <p className="sp-item__time">{time}</p>{jobs && <p className="small">On it: {jobs}</p>}
    <FieldButton action={offer ? 'offer_claim' : 'shift_take'} payload={offer ? { id: x.id } : { slot: x.id }} label="Claim" primary testId={`week-claim-${x.id}`} /></div>;
}
