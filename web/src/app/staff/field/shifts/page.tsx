import { requestNow } from '@/features/va/lanes';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { FieldButton } from '@/features/field/FieldButton';
import { money } from '@/lib/format';
import { hoursText } from '@/features/field-pay/model';
import { cardTitle, clockText, isLate, jobsText, shiftText, type ShiftJobs } from '@/features/field-portal/model';
import { SpendReceipt } from '@/features/field-portal/SpendReceipt';
import Link from '@/components/Link';
import { ShiftWeek, type CalItem } from '@/features/field-portal/ShiftWeek';
import { StandingShifts } from '@/features/field-portal/StandingShifts';
import { AvailabilityGrid } from '@/features/field-portal/AvailabilityGrid';
import { availabilityWords, minimumWords, type Availability, type Rules, type Standing } from '@/features/field-portal/shift-picker';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My shifts', path: '/staff/field/shifts', noindex: true, description: 'Claim shifts, give one up, swap, and what you did on each.' });

type Slot = { id: string; starts_at: string; ends_at: string; note: string | null; jobs?: ShiftJobs; people?: number; /** 1770 */ standing?: boolean; fits?: boolean };
type Planned = { cards: Array<{ type: string; leg: string | null; kind: string | null; at: string | null; vehicle: string; booking: string | null }> };
interface Shifts {
  locked: boolean; mine: Slot[]; open: Array<Slot & { capacity: number; taken: number; mine: boolean }>;
  planned: Record<string, Planned>; offers: Array<{ id: string; slot_id: string; starts_at: string; ends_at: string; from: string; jobs?: ShiftJobs; fits?: boolean }>;
  /** r35 SP (1770) */ standing?: Standing[]; availability?: Availability; rules?: Rules;
  swaps: Array<{ id: string; incoming: boolean; theirs: { starts_at: string; ends_at: string }; mine: { starts_at: string; ends_at: string }; who: string }>;
  others: Array<{ id: string; starts_at: string; ends_at: string; who: string }>; late_cancels: number;
  past: Array<{ day: string; minutes: number; jobs: Array<{ kind: string; vehicle: string; booking: string | null }>; photos: number; spent_cents: number;
    spends: Array<{ id: string; description: string; amount_cents: number; status: string; receipt: boolean }> }>;
}
type Spend = { id: string; kind: string; spent_on: string; description: string; amount_cents: number; status: string; receipt: boolean; vehicle: string | null; note: string | null };
const SPEND_STATUS: Record<string, string> = { submitted: 'Waiting for Finance', approved: 'Approved', refused: 'Refused', reimbursed: 'Paid back' };
const pastDay = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(`${d}T12:00:00Z`));

// My shifts (r35 part X; 0880, 0931): the shifts you hold with the work planned so far, the shifts free to claim (given up by
// someone, first to claim takes it, and the open ones), swaps asked of you, and the past shifts with what you did on each.
export default async function MyShifts({ searchParams }: { searchParams: Promise<{ view?: string; week?: string }> }) {
  const q = await searchParams;
  const list = q.view === 'list';
  const week = Math.min(2, Math.max(0, Number(q.week) || 0));
  const { user } = await requireStaff('field', '/staff/field/shifts');
  const [s, spends] = await Promise.all([door<Shifts>(user.id, 'field_read', 'my_shifts'), door<Spend[]>(user.id, 'field_read', 'my_spends').catch(() => [] as Spend[])]);
  const now = requestNow();
  // a slot with a given-up shift on it shows once, as the offer
  const openSlots = s.open.filter((o) => !o.mine && o.taken < o.capacity && !s.offers.some((x) => x.slot_id === o.id));
  const noReceipt = spends.filter((x) => !x.receipt && x.status !== 'refused');
  // r35 SP (1770): the week view's items, the minimum
  const cal: CalItem[] = [
    ...s.mine.map((x) => ({ kind: 'mine' as const, id: x.id, starts_at: x.starts_at, ends_at: x.ends_at, standing: x.standing, jobs: x.jobs, note: x.note })),
    ...s.offers.map((o) => ({ kind: 'offer' as const, id: o.id, starts_at: o.starts_at, ends_at: o.ends_at, from: o.from, jobs: o.jobs, fits: o.fits })),
    ...(s.locked ? [] : openSlots.map((o) => ({ kind: 'open' as const, id: o.id, starts_at: o.starts_at, ends_at: o.ends_at, free: o.capacity - o.taken, capacity: o.capacity, jobs: o.jobs, fits: o.fits }))),
    ...s.swaps.filter((x) => x.incoming).map((x) => ({ kind: 'swap' as const, id: x.id, swapId: x.id, starts_at: x.theirs.starts_at, ends_at: x.theirs.ends_at, from: x.who, theirs: shiftText(x.mine.starts_at, x.mine.ends_at) }))];
  const min = minimumWords(s.rules);
  return (
    <>
      <header className="fp-hello"><h1>My shifts</h1><p>{s.mine.length} coming up</p></header>
      {s.locked && <p className="alert alert--warn" role="status"><span>Pass the academy (Training) to claim shifts.</span></p>}
      {!min.off && <div className={`sp-min${min.met ? ' is-met' : ''}`} data-testid="shift-minimum"><p className="sp-min__n">{min.text}</p>
        <p className="small">{min.met ? 'You hold the minimum. Claim more any time.' : 'Claim shifts below or set a standing weekly shift. Until then you get a reminder each day.'}</p></div>}
      <nav className="sp-tabs" aria-label="View"><Link prefetch={false} href="/staff/field/shifts" aria-current={list ? undefined : 'page'} data-testid="view-week">Week</Link>
        <Link prefetch={false} href="/staff/field/shifts?view=list" aria-current={list ? 'page' : undefined} data-testid="view-list">List</Link></nav>
      {!list && <ShiftWeek items={cal} now={now} week={week} />}
      {list && <>
      {s.swaps.filter((x) => x.incoming).map((x) => <section key={x.id} className="fp-shiftcard is-offer fp-stack" data-testid="swap-incoming">
        <p className="fp-shift__label">{x.who} asks to swap</p>
        <p className="fp-shiftcard__when">You take {shiftText(x.theirs.starts_at, x.theirs.ends_at)}</p>
        <p className="small">They take yours: {shiftText(x.mine.starts_at, x.mine.ends_at)}</p>
        <FieldButton action="swap_answer" payload={{ id: x.id, accept: true }} label="Accept the swap" primary testId={`swap-accept-${x.id}`} />
        <FieldButton action="swap_answer" payload={{ id: x.id, accept: false }} label="Decline" testId={`swap-decline-${x.id}`} />
      </section>)}
      {(s.offers.length > 0 || openSlots.length > 0) && <>
        <h2 className="fp-group-h">Free to claim<span className="small">{s.offers.length + openSlots.length}</span></h2>
        <div className="fp-stack">
          {s.offers.map((o) => <section key={o.id} className="fp-shiftcard is-offer" data-testid="offer">
            <p className="fp-shiftcard__when">{shiftText(o.starts_at, o.ends_at)}</p>
            <p className="small">Given up by {o.from}. First to claim takes it.</p>
            {jobsText(o.jobs) && <p className="small" data-testid="shift-jobs"><b>On it:</b> {jobsText(o.jobs)}</p>}
            <FieldButton action="offer_claim" payload={{ id: o.id }} label="Claim this shift" primary testId={`claim-${o.id}`} /></section>)}
          {openSlots.map((o) => <section key={o.id} className="fp-shiftcard" data-testid="open-shift">
            <p className="fp-shiftcard__when">{shiftText(o.starts_at, o.ends_at)}</p>
            <p className="small">{o.capacity - o.taken} of {o.capacity} place{o.capacity === 1 ? '' : 's'} free{o.note ? `. ${o.note}` : ''}</p>
            {jobsText(o.jobs) && <p className="small" data-testid="shift-jobs"><b>On it:</b> {jobsText(o.jobs)}</p>}
            <FieldButton action="shift_take" payload={{ slot: o.id }} label="Claim this shift" primary testId={`take-${o.id}`} /></section>)}
        </div>
      </>}
      <h2 className="fp-group-h">Coming up</h2>
      {s.mine.length ? <div className="fp-stack" data-testid="field-shifts">{s.mine.map((x) => {
        const plan = s.planned[x.id]?.cards ?? [];
        const late = isLate(x.starts_at, now);
        const asked = s.swaps.find((w) => !w.incoming && w.theirs.starts_at === x.starts_at);
        return <section key={x.id} id={`s-${x.id}`} className="fp-shiftcard" data-testid="my-shift">
          <p className="fp-shiftcard__when">{shiftText(x.starts_at, x.ends_at)}</p>{x.standing && <p className="small"><b>Standing shift</b></p>}{x.note && <p className="small">{x.note}</p>}
          {jobsText(x.jobs) && <p className="small" data-testid="shift-jobs"><b>The shift&apos;s jobs:</b> {jobsText(x.jobs)}{(x.people ?? 1) > 1 ? ', shared with the others on it' : ''}</p>}
          {plan.length ? <><p className="small"><b>Planned so far</b></p><ul className="fp-plan">{plan.map((c, i) => <li key={i}>{c.at ? `${clockText(c.at)} ` : ''}{c.type === 'prep' ? 'Onboarding prep' : cardTitle({ type: 'job', kind: c.kind ?? undefined })}: {c.vehicle}{c.booking ? `, ${c.booking}` : ''}</li>)}</ul></>
            : <p className="small">Nothing planned for you yet. Jobs are put on shifts as bookings come in.</p>}
          {asked && <p className="small">You asked {asked.who} to swap.</p>}
          {new Date(x.starts_at).getTime() > now && <>
            {s.others.length > 0 && !asked && <FieldButton action="swap_ask" payload={{ mine: x.id }} label="Swap with someone" sheet={{ confirm: 'Ask for the swap', title: 'Swap this shift' }} testId={`swap-${x.id}`}
              fields={[{ name: 'theirs', label: 'Their shift', options: s.others.filter((o) => o.starts_at !== x.starts_at).map((o) => [o.id, `${o.who}: ${shiftText(o.starts_at, o.ends_at)}`] as [string, string]) }]} />}
            <FieldButton action="shift_cancel" payload={{ id: x.id }} label="Give this shift up" sheet={{ confirm: late ? 'Give it up (marked late)' : 'Give it up', title: late ? 'Under 24 hours: this is marked late on your record' : 'It is offered to everyone free then' }}
              testId={`drop-${x.id}`} fields={[{ name: 'reason', label: 'Why you cannot work it', required: true }]} />
          </>}
        </section>;
      })}</div> : <p className="small fp-stack">You have no shifts yet. Jobs are put on shifts: claim one above and its jobs are yours.</p>}
      {s.late_cancels > 0 && <p className="small">Late give-ups in the last 90 days: {s.late_cancels}.</p>}
      </>}
      <StandingShifts list={s.standing ?? []} locked={s.locked} />
      <details className="fp-shiftcard fp-more" style={{ marginTop: 'var(--s-3)' }} data-testid="shifts-availability"><summary>When you can work: {availabilityWords(s.availability?.slots)}</summary>
        <AvailabilityGrid value={s.availability ?? null} testId="shifts-availability-grid" /></details>
      <h2 className="fp-group-h" id="spending">Money you spent</h2>
      {spends.length ? <div className="fp-stack">{spends.slice(0, 15).map((x) => <section key={x.id} className="fp-shiftcard is-past" data-testid="spend">
        <p className="fp-card__time" style={{ fontSize: '1.5rem' }}>{money(x.amount_cents, { cents: true })}</p>
        <p><b>{x.description}</b></p><p className="small">{pastDay(x.spent_on)}{x.vehicle ? `, ${x.vehicle}` : ''}. {SPEND_STATUS[x.status] ?? x.status}{x.note ? `: ${x.note}` : ''}.</p>
        {!x.receipt && x.status !== 'refused' && <SpendReceipt id={x.id} />}</section>)}</div> : <p className="small fp-stack">Nothing yet. Use Add on Today when you spend money for the company.</p>}
      {noReceipt.length > 0 && <p className="small">{noReceipt.length} without a receipt: add the photo above.</p>}
      <h2 className="fp-group-h">Past shifts</h2>
      {s.past.length ? <div className="fp-stack">{s.past.map((d) => <section key={d.day} className="fp-shiftcard is-past" data-testid="past-shift">
        <p className="fp-shiftcard__when">{pastDay(d.day)}</p>
        <div className="fp-facts"><div><b>{hoursText(d.minutes)}</b><span>hours</span></div><div><b>{d.jobs.length}</b><span>jobs</span></div><div><b>{d.photos}</b><span>photos</span></div><div><b>{money(d.spent_cents)}</b><span>spent</span></div></div>
        {d.jobs.length > 0 && <ul className="fp-plan">{d.jobs.map((j, i) => <li key={i}>{cardTitle({ type: 'job', kind: j.kind })}: {j.vehicle}{j.booking ? `, ${j.booking}` : ''}</li>)}</ul>}
      </section>)}</div> : <p className="small">Your past shifts of the last 30 days show here with what you did.</p>}
    </>
  );
}
