import Link from 'next/link';
import type { ReactNode } from 'react';
import { PuIcon } from '@/components/portal-ui/icons';
import { WaitTimer } from '@/components/portal-ui/WaitTimer';
import { Act } from '@/features/admin/Act';
import { taskHref, type Task } from './tasks';
import type { Lane } from './lanes';

// The pieces of the assistant's "My queue" home (October 25, 2026): the next thing to do, the lanes as big tiles with
// their counts and live timers, and the replies waiting against the first reply target. Styles in styles/va.css and
// components/portal-ui/queue.css.

/** The single most urgent task, as a dark card: what it is, how long it has waited, and the action in one click. */
export function NextUp({ task, lane, now, target, userId }: { task: Task | null; lane: Lane | null; now: number; target: number; userId: string }) {
  if (!task || !lane) {
    return (
      <section className="va-next va-next--clear" aria-labelledby="va-next-h" data-testid="va-next">
        <span className="va-next__icon" aria-hidden="true"><PuIcon name="check" /></span>
        <div className="va-next__body">
          <h2 className="va-next__kicker" id="va-next-h">Next up</h2>
          <p className="va-next__title">Nothing is waiting for you</p>
          <p className="va-next__meta">New work appears here by itself. This page checks every 30 seconds.</p>
        </div>
      </section>
    );
  }
  const href = taskHref(task);
  const record = task.booking_number ?? task.plate ?? task.vehicle_name ?? null;
  return (
    <section className="va-next" aria-labelledby="va-next-h" data-testid="va-next">
      <span className="va-next__icon" aria-hidden="true"><PuIcon name={lane.icon} /></span>
      <div className="va-next__body">
        <h2 className="va-next__kicker" id="va-next-h">Next up: {lane.label.toLowerCase()}</h2>
        <p className="va-next__title">{task.title}</p>
        <p className="va-next__meta">
          {record && <span>{record}</span>}
          {task.renter_first_name && <span>{task.renter_first_name}</span>}
          {task.escalated && <span className="va-next__flag">Escalated</span>}
          {task.priority === 'urgent' && !task.escalated && <span className="va-next__flag">Urgent</span>}
        </p>
      </div>
      <div className="va-next__timer"><WaitTimer since={task.created_at} targetMin={lane.reply ? target : undefined} now={now} bar={!!lane.reply} testId="va-next-timer" /></div>
      <div className="va-next__actions">
        <Link prefetch={false} className="btn btn--primary" href={href} data-testid="va-next-open">{lane.verb}</Link>
        {task.assigned_to !== userId && <Act action="task_take" payload={{ id: task.id }} label="Take it" refresh={['/va']} testId="va-next-take" done="It is yours." />}
      </div>
    </section>
  );
}

/** One lane as a tile: the count large, what it is, what to do, and the oldest item's live timer. */
function LaneTile({ lane, now, target }: { lane: Lane; now: number; target: number }) {
  return (
    <li className={`va-lane va-lane--h${lane.heat}`} data-testid={`va-lane-${lane.key}`} data-count={lane.count}>
      <Link prefetch={false} href={lane.href} className="va-lane__link">
        <span className="va-lane__top">
          <span className="va-lane__icon" aria-hidden="true"><PuIcon name={lane.icon} /></span>
          <span className="va-lane__count">{lane.count}</span>
        </span>
        <span className="va-lane__label">{lane.label}</span>
        <span className="va-lane__verb">{lane.count ? lane.verb : 'All clear'}</span>
      </Link>
      {lane.count > 0 && lane.since ? (
        <span className="va-lane__foot">
          <span className="va-lane__oldest">Oldest</span>
          <WaitTimer since={lane.since} targetMin={lane.reply ? target : undefined} now={now} bar={!!lane.reply} />
          {lane.overdue > 0 && <span className="va-lane__late">{lane.overdue} overdue</span>}
        </span>
      ) : <span className="va-lane__foot va-lane__foot--quiet">{lane.count ? 'Waiting' : 'Nothing waiting'}</span>}
    </li>
  );
}

export function LaneBoard({ lanes, now, target, title = 'Your lanes, most urgent first' }: { lanes: Lane[]; now: number; target: number; title?: string }) {
  return (
    <section className="va-section" aria-labelledby="va-lanes-h" data-testid="va-lanes">
      <div className="va-section__head"><h2 className="va-section__title" id="va-lanes-h">{title}</h2>
        <p className="va-section__note">Replies are timed against the {target}-minute first reply target.</p></div>
      <ul className="va-lanes">{lanes.map((l) => <LaneTile key={l.key} lane={l} now={now} target={target} />)}</ul>
    </section>
  );
}

export interface WaitingItem { key: string; what: string; who: ReactNode; detail?: ReactNode; since: string; href: string; cta: string; testId?: string }

/** Everything waiting for a first reply, the longest wait first, each with its timer and the reply in one click. */
export function ReplyBoard({ items, now, target, more }: { items: WaitingItem[]; now: number; target: number; more?: ReactNode }) {
  const late = items.filter((i) => now - Date.parse(i.since) > target * 60_000).length;
  return (
    <section className="va-section pu-panel" aria-labelledby="va-replies-h" data-testid="va-replies">
      <div className="va-section__head">
        <h2 className="va-section__title" id="va-replies-h">Waiting for a reply</h2>
        <p className="va-section__note">{items.length ? `${items.length} waiting${late ? `, ${late} past ${target} minutes` : ''}. Oldest first.` : `Every renter has a reply. Target: ${target} minutes.`}</p>
      </div>
      {items.length ? (
        <ul className="va-replies">{items.map((i) => (
          <li key={i.key} className="va-reply" data-testid={i.testId}>
            <WaitTimer since={i.since} targetMin={target} now={now} bar />
            <span className="va-reply__text"><span className="va-reply__what">{i.what}</span><span className="va-reply__who">{i.who}{i.detail ? <span className="va-reply__detail">{i.detail}</span> : null}</span></span>
            <Link prefetch={false} className={`btn btn--sm ${now - Date.parse(i.since) > target * 60_000 ? 'btn--primary' : 'btn--ghost'} va-reply__cta`} href={i.href}>{i.cta}</Link>
          </li>))}
        </ul>
      ) : <p className="va-empty-line"><PuIcon name="check" /> Inbox clear.</p>}
      {more}
    </section>
  );
}

/** A figure that opens its list: the count, what it is, and a line under it. */
export function FigureLinks({ items, label, testId }: { items: Array<{ k: string; v: number | string; sub?: string; href: string; warn?: boolean; testId?: string }>; label: string; testId?: string }) {
  return (
    <ul className="va-figs" aria-label={label} data-testid={testId}>
      {items.map((i) => (
        <li key={i.k} data-testid={i.testId}><Link prefetch={false} href={i.href} className={`va-fig${i.warn ? ' va-fig--warn' : ''}`}>
          <b className="va-fig__v">{i.v}</b><span className="va-fig__k">{i.k}</span>{i.sub && <span className="va-fig__s">{i.sub}</span>}
        </Link></li>))}
    </ul>
  );
}

/** The keyboard, in one quiet line. */
export function Keys({ items }: { items: Array<[string, string]> }) {
  return (
    <p className="va-keys" data-testid="va-keys"><span className="vh">Keyboard shortcuts: </span>
      {items.map(([k, v]) => <span key={k}><kbd>{k}</kbd> {v}</span>)}
    </p>
  );
}
