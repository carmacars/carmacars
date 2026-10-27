import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { Badge, Filters, MoreFilters, Table, t, label } from '@/features/admin/ui';
import { PortalHero } from '@/components/portal-ui/PortalHero';
import { StatCard } from '@/components/portal-ui/StatCard';
import { ProgressRing } from '@/components/portal-ui/ProgressRing';
import { WaitTimer } from '@/components/portal-ui/WaitTimer';
import { taskHref, type Task } from '@/features/va/tasks';
import { QueueLive } from '@/features/va/QueueLive';
import { buildLanes, laneOf, LANES, OTHER, requestNow, type Fn } from '@/features/va/lanes';
import { FigureLinks, Keys, LaneBoard, NextUp, ReplyBoard, type WaitingItem } from '@/features/va/QueueHome';
import { CarBoard, DayTimeline } from '@/features/va/FleetDay';
import { carBoard, type CalVehicle } from '@/features/va/carboard';
import { pctBps, type StaffCommissions } from '@/features/sales/Commissions';
import type { SalesFollowUp } from '@/features/va/SalesBoard';
import { signCount } from '@/features/manual/SignPages';
import { RemoteDuties, type SalesDuties } from '@/features/sales/RemoteDuties';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'To do', path: '/va', noindex: true, description: 'The assistant\'s work queue.' });

type Digest = { open: number; overdue: number; due_today: number; escalated: number; done_today: number; mine: number };
type Req = { id: string; booking_number: string; status: string; state: string; vehicle: string; renter: string; returning: boolean; waiting_minutes: number };
type R = Record<string, unknown>;
// 0169: the bookings with a licence image or selfie waiting, for Sales
type LicenceWaiting = { booking_number: string; status: string; vehicle_label: string; renter_first_name: string | null; waiting: number; waiting_since: string };
type Board = { payments_failed: R[]; deposits_due: R[]; deposits_to_take: R[]; refunds: R[]; cancellations: R[]; owner_invoices: R[]; statements: R[] };
const REPLY: Record<string, { what: string; cta: string }> = {
  renter_message: { what: 'Renter message', cta: 'Reply' }, phone_missed_call: { what: 'Missed call', cta: 'Call back' }, account_phone_review: { what: 'Text to check', cta: 'Open' },
  live_chat_waiting: { what: 'Live chat', cta: 'Answer' }, chat_request: { what: 'Chat request', cta: 'Answer' }, chat_contact: { what: 'Chat contact', cta: 'Answer' }
};
const QUICK: Record<Fn, Array<[string, string]>> = {
  cs: [['/va/offers/new', 'Send an offer'], ['/va/bookings/new', 'Add a rental'], ['/va/renters', 'Find a renter']],
  sales: [['/va/quotes/new', 'New quote'], ['/va/offers/new', 'Send an offer'], ['/va/my-sales', 'My sales']],
  finance: [['/va/payments', 'Payments by day'], ['/va/money', 'Deposits and refunds'], ['/va/reconciliation', 'Reconciliation']],
  fleet: [['/va/fleet', 'Field jobs'], ['/va/checks', 'Daily checks'], ['/va/calendar', 'Calendar']]
};

// My queue (05-va.md section 1.1; redesigned October 25, 2026, the owner: "extremely easy to use"): the next thing to do,
// the function's lanes as tiles with counts and live timers against the first reply target, the replies waiting (customer
// service and Sales), the function's own panel, then every open task by priority and due time. Each task opens the
// screen where it is done.
export default async function Queue({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, fn, user, aal }, sp] = await Promise.all([vaPage('/va'), searchParams]);
  const talk = fn === 'cs' || fn === 'sales';
  const now = requestNow();
  const [all, toSign, dg, target, reqs, chat, sales, board, jobs, cal, licences, duties] = await Promise.all([
    read<Task[]>('queue'), signCount(user.id),
    read<Digest>('digest').catch(() => null),
    door<{ minutes: number; words: string }>(user.id, 'ops_read', 'reply_target', {}, aal).catch(() => ({ minutes: 5, words: '5 minutes' })),
    talk ? read<Req[]>('requests').catch(() => [] as Req[]) : Promise.resolve([] as Req[]),
    talk ? read<{ waiting: number }>('chat_counts').catch(() => ({ waiting: 0 })) : Promise.resolve({ waiting: 0 }),
    fn === 'sales' ? read<{ commissions: StaffCommissions; follow_ups: SalesFollowUp[] }>('my_sales', { period: 'month' }).catch(() => null) : Promise.resolve(null),
    fn === 'finance' ? read<Board>('finance_board').catch(() => null) : Promise.resolve(null),
    fn === 'fleet' ? read<{ jobs: R[] }>('fleet_board').then((b) => b.jobs).catch(() => [] as R[]) : Promise.resolve([] as R[]),
    fn === 'fleet' ? read<{ vehicles: CalVehicle[] }>('calendar', { from: new Date(now - 86_400_000).toISOString(), to: new Date(now + 2 * 86_400_000).toISOString() }).then((c) => c.vehicles).catch(() => [] as CalVehicle[]) : Promise.resolve([] as CalVehicle[]),
    fn === 'sales' ? read<LicenceWaiting[]>('licences_waiting').catch(() => [] as LicenceWaiting[]) : Promise.resolve([] as LicenceWaiting[]),
    // 0174: in person or remote; a remote rep's checklist, touches, cover and reply time
    fn === 'sales' ? read<SalesDuties>('sales_duties').catch(() => null) : Promise.resolve(null)
  ]);
  const tm = target.minutes;
  const waiting = reqs.filter((r) => r.status === 'requested');
  const sinceOf = (min: number) => new Date(now - min * 60_000).toISOString();
  const oldestReq = waiting.reduce((m, r) => Math.max(m, r.waiting_minutes), -1);
  const lanes = buildLanes(fn, all, now, tm, {
    ...(talk ? { requests: { count: waiting.length, since: oldestReq >= 0 ? sinceOf(oldestReq) : null }, chat: { count: chat.waiting } } : {})
  });
  const top = lanes.find((l) => l.first) ?? null;
  const done = dg?.done_today ?? 0;

  // the replies waiting: requests from the requests read, messages, calls and chats from the queue
  const replies: WaitingItem[] = talk ? [
    ...waiting.map((r): WaitingItem => ({ key: `r-${r.id}`, what: 'Booking request', who: <>{r.renter} <span className="muted">{r.returning ? 'returning' : 'new'}</span></>, detail: `${r.vehicle} · ${r.booking_number}`,
      since: sinceOf(r.waiting_minutes), href: `/va/bookings/${encodeURIComponent(r.booking_number)}`, cta: 'Send an offer', testId: `va-reply-${r.booking_number}` })),
    ...all.filter((x) => REPLY[x.task_type]).map((x): WaitingItem => ({ key: x.id, what: REPLY[x.task_type]!.what, who: x.renter_first_name ?? x.title, detail: x.booking_number ?? undefined,
      since: x.created_at, href: taskHref(x), cta: REPLY[x.task_type]!.cta }))
  ].sort((a, b) => a.since.localeCompare(b.since)) : [];

  // the full list below, filtered as before, and by lane
  const tab = sp.tab ?? 'all';
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date(now));
  const day = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date(iso)) : '');
  const laneDef = sp.lane ? [...LANES[fn], OTHER].find((l) => l.key === sp.lane) ?? null : null;
  const rows = all.filter((r) => (tab === 'all' || r.bucket === tab)
    && (!sp.only || (sp.only === 'overdue' ? r.overdue : sp.only === 'escalated' ? r.escalated : sp.only === 'today' ? day(r.due_at) === today : true))
    && (!sp.type || r.task_type === sp.type)
    && (!laneDef || laneOf(fn, r.task_type) === laneDef.key));
  const types = [...new Set(all.map((r) => r.task_type))].sort();
  const count = (b: string) => all.filter((r) => r.bucket === b).length;
  const dateWords = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric' }).format(new Date(now));
  const needs = lanes.reduce((n, l) => n + l.count, 0);
  const late = lanes.filter((l) => l.heat >= 2).length;
  const m = sales?.commissions.month;

  return (
    <div className="va-home">
      <QueueLive open={all.length} />
      <PortalHero testId="va-hero" titleId="va-title" kicker={<>{FN_LABEL[fn]} <span aria-hidden="true">/</span> {dateWords}, Toronto time</>} title="To do"
        lead={needs ? `${needs} ${needs === 1 ? 'thing needs' : 'things need'} you${late ? `, ${late === 1 ? 'one lane is' : `${late} lanes are`} running late` : ''}. Start at Next up and work down.` : 'Your queue is clear. New work appears here by itself.'}
        stats={dg ? <>
          <StatCard label="Open" value={dg.open} testId="va-stat-open" />
          <StatCard label="Overdue" value={dg.overdue} testId="va-stat-overdue" sub={dg.overdue ? 'do these first' : 'none late'} />
          <StatCard label="Done today" value={done} testId="va-stat-done" sub={`${dg.due_today} due today`} />
        </> : undefined}
        actions={<>{QUICK[fn].map(([href, text], i) => <Link key={href} prefetch={false} className={`btn btn--sm ${i === 0 ? 'btn--primary' : 'btn--ghost'}`} href={href}>{text}</Link>)}
          <Link prefetch={false} className="btn btn--sm btn--ghost" href="/va/today">Today at a glance</Link></>}
        media={m && m.scheme === 'sales_tier' ? (
          <Link prefetch={false} href="/va/my-sales" className="va-hero-ring" data-testid="va-commission-ring">
            <ProgressRing value={m.days} max={m.target_days} size={132} stroke={11} accent label={`${m.days}`} sub={`of ${m.target_days} days`} title={`Rental days this month: ${m.days} of ${m.target_days}. Your rate now ${pctBps(m.rate_bps)}.`} />
            <span className="va-hero-ring__text"><b>{pctBps(m.rate_bps)} commission now</b>{duties?.mode ? <span data-testid="va-sales-mode">{duties.mode === 'remote' ? 'Remote' : 'In person'}</span> : null}<span>{m.next ? `${m.next.to_go} more rental days to ${pctBps(m.next.bps)}` : 'Top tier this month'}</span><span className="va-hero-ring__more">Open My sales</span></span>
          </Link>) : undefined} />

      {toSign > 0 && <p className="alert alert--warn" role="status" data-testid="va-to-sign"><span>You have {toSign === 1 ? 'a document' : `${toSign} documents`} to sign. <Link prefetch={false} className="link" href="/va/sign">Read and sign</Link></span></p>}

      <NextUp task={top?.first ?? null} lane={top} now={now} target={tm} userId={user.id} />
      <LaneBoard lanes={lanes} now={now} target={tm} />

      {duties?.mode === 'remote' && <RemoteDuties d={duties} own />}

      <div className="va-cols">
        {talk && <ReplyBoard items={replies.slice(0, 8)} now={now} target={tm} more={replies.length > 8 ? <p className="small"><Link prefetch={false} className="link" href="/va/requests">See all {replies.length}</Link></p> : null} />}
        {fn === 'sales' && (
          <section className="va-section pu-panel" aria-labelledby="va-lic-h" data-testid="va-licences">
            <div className="va-section__head"><h2 className="va-section__title" id="va-lic-h">Licences to check</h2><p className="va-section__note">{licences.length ? `${licences.length} ${licences.length === 1 ? 'booking' : 'bookings'} with a licence or selfie waiting` : 'Nothing waiting'}</p></div>
            {licences.length ? <ul className="va-replies">{licences.slice(0, 8).map((l) => (
              <li key={l.booking_number} className="va-reply" data-testid={`va-licence-${l.booking_number}`}>
                <WaitTimer since={l.waiting_since} now={now} label="Waiting" />
                <span className="va-reply__text"><span className="va-reply__what">{l.waiting} {l.waiting === 1 ? 'image' : 'images'} to check</span><span className="va-reply__who">{l.renter_first_name ?? 'Renter'}<span className="va-reply__detail">{l.vehicle_label} · {l.booking_number}</span></span></span>
                <Link prefetch={false} className="btn btn--sm btn--primary va-reply__cta" href={`/va/verify/${encodeURIComponent(l.booking_number)}`}>Review the licence</Link>
              </li>))}</ul> : <p className="va-empty-line">Every licence sent is decided.</p>}
          </section>)}
        {fn === 'sales' && sales && (
          <section className="va-section pu-panel" aria-labelledby="va-fu-h" data-testid="va-followups">
            <div className="va-section__head"><h2 className="va-section__title" id="va-fu-h">Follow-ups due</h2><p className="va-section__note">{sales.follow_ups.length ? `${sales.follow_ups.length} deals to move on` : 'Nothing to follow up'}</p></div>
            {sales.follow_ups.length ? <ul className="va-replies">{sales.follow_ups.slice(0, 6).map((f) => (
              <li key={f.booking_number} className="va-reply">
                {f.due_at ? <WaitTimer since={f.due_at} now={now} label="Due since" /> : <span className="pu-timer pu-timer--calm"><span className="pu-timer__clock">open</span></span>}
                <span className="va-reply__text"><span className="va-reply__what">{f.step}</span><span className="va-reply__who">{f.renter ?? 'Renter'}<span className="va-reply__detail">{f.vehicle} · {f.booking_number}</span></span></span>
                <Link prefetch={false} className="btn btn--sm btn--ghost va-reply__cta" href={`/va/bookings/${encodeURIComponent(f.booking_number)}`}>Open</Link>
              </li>))}</ul> : <p className="va-empty-line">Every deal is confirmed or closed.</p>}
          </section>)}
        {fn === 'finance' && board && (
          <section className="va-section pu-panel" aria-labelledby="va-money-h" data-testid="va-money">
            <div className="va-section__head"><h2 className="va-section__title" id="va-money-h">Money today</h2><Link prefetch={false} className="link small" href="/va/money">Open the money board</Link></div>
            <FigureLinks label="Money to handle" items={[
              { k: 'Failed payments', v: board.payments_failed.length, sub: 'last 30 days', href: '/va/money#failed', warn: board.payments_failed.length > 0 },
              { k: 'Deposits to take', v: board.deposits_to_take.length, sub: 'pickups in two days', href: '/va/money#deposits' },
              { k: 'Deposits due back', v: board.deposits_due.length, sub: 'this week', href: '/va/money#deposits-back', warn: board.deposits_due.length > 0 },
              { k: 'Refunds to request', v: board.cancellations.length, sub: 'after a cancellation', href: '/va/money#refunds', warn: board.cancellations.length > 0 },
              { k: 'Refunds waiting', v: board.refunds.length, sub: 'in progress or to decide', href: '/va/money#refunds-progress' },
              { k: 'Owner statements', v: board.statements.length, sub: 'drafts to prepare', href: '/va/money#statements' }]} />
          </section>)}
        {fn === 'fleet' && <DayTimeline jobs={jobs} now={now} />}
        {fn === 'fleet' && <CarBoard rows={carBoard(cal, now)} now={now} compact carHref={(id) => `/va/vehicles/${id}`} />}
        <section className="va-section pu-panel" aria-labelledby="va-find-h" data-testid="va-find">
          <div className="va-section__head"><h2 className="va-section__title" id="va-find-h">{fn === 'sales' ? 'Find a car' : 'Find a renter'}</h2><p className="va-section__note">Press <kbd>/</kbd> to search from anywhere on this page.</p></div>
          <form className="va-find" action={fn === 'sales' ? '/va/cars' : '/va/renters'} role="search">
            <label className="vh" htmlFor="va-find-q">{fn === 'sales' ? 'Car code, plate, VIN or name' : 'Name, email or booking number'}</label>
            <input className="input" id="va-find-q" name="q" type="search" minLength={3} placeholder={fn === 'sales' ? 'Car code, plate, VIN or name' : 'Name, email or booking number'} data-shortcut="/" />
            <button className="btn btn--primary btn--sm" type="submit">Find</button>
          </form>
          <p className="small muted">{fn === 'sales' ? 'At least 3 characters. Send an offer from the car you find.' : 'Every search is logged. At least 3 characters.'}</p>
        </section>
      </div>

      <section className="va-section" aria-labelledby="va-all-h">
        <div className="va-section__head"><h2 className="va-section__title" id="va-all-h">Every open task</h2>
          <p className="va-section__note">{all.length} open, most urgent first. Open a task to do it, or take one nobody has yet.</p></div>
        {laneDef && <p className="va-chip" data-testid="va-lane-filter">Showing {laneDef.label.toLowerCase()} <Link prefetch={false} className="link" href="/va">Show every task</Link></p>}
        <Filters base="/va" name="tab" value={tab} sp={sp} options={[['all', `All (${all.length})`], ['mine', `Mine (${count('mine')})`], ['unassigned', `Unassigned (${count('unassigned')})`], ['waiting', `Waiting (${count('waiting')})`]]} />
        <MoreFilters active={!!(sp.only || sp.type)}>
          <Filters base="/va" name="only" value={sp.only ?? ''} sp={sp} options={[['', 'Any time'], ['overdue', 'Overdue'], ['today', 'Due today'], ['escalated', 'Escalated']]} />
          {types.length > 1 && <Filters base="/va" name="type" value={sp.type ?? ''} sp={sp} options={[['', 'Every type'], ...types.map((x) => [x, label(x)] as [string, string])]} />}
        </MoreFilters>
        <Table<Task & Record<string, unknown>> testId="queue" caption="Open tasks" rows={rows as Array<Task & Record<string, unknown>>} empty={all.length ? 'No task matches these filters. Choose All to see every open task.' : 'Queue clear: nothing is waiting for you. New tasks appear here as they come in.'} cols={[
          { key: 'priority', label: 'Priority', render: (r) => <Badge s={r.priority === 'urgent' ? 'failed' : r.priority === 'high' ? 'needs_review' : 'open'}>{r.priority}</Badge> },
          { key: 'title', label: 'Task', className: 'wrap', render: (r) => <><Link prefetch={false} className="link" href={taskHref(r)} data-testid={`task-${r.task_type}`}>{r.title}</Link>{r.escalated ? <span className="ad-flag ad-flag--red">escalated</span> : null}</> },
          { key: 'record', label: 'Record', render: (r) => r.booking_number ?? r.plate ?? r.vehicle_name ?? '' },
          { key: 'due_at', label: 'Due', render: (r) => <span className={r.overdue ? 'ad-late' : undefined}>{t(r.due_at)}</span> },
          { key: 'created_at', label: 'Waiting', render: (r) => <WaitTimer since={r.created_at} now={now} /> },
          { key: 'assignee_name', label: 'Assigned to', render: (r) => r.assigned_to === user.id ? 'me' : (r.assignee_name ?? '') },
          { key: 'procedure_no', label: 'Procedure', render: (r) => r.procedure_no ? `P${r.procedure_no}` : '' },
          { key: 'act', label: 'Actions', render: (r) => <span className="ad-actions"><Link prefetch={false} className="btn btn--ghost btn--sm" href={`/va/tasks/${r.id}`}>Sheet</Link>
            {r.assigned_to !== user.id && <Act action="task_take" payload={{ id: r.id }} label="Take it" refresh={['/va']} />}</span> }]} />
      </section>
      <Keys items={[['/', fn === 'sales' ? 'find a car' : 'find a renter'], ['g t', 'To do'], ...(talk ? [['g r', 'Requests'] as [string, string]] : []), ['g c', 'Calendar']]} />
    </div>
  );
}
