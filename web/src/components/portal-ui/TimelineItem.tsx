import Link from 'next/link';
import type { ReactNode } from 'react';

const fmtDay = (iso: string) => {
  const d = new Date(iso.length <= 10 ? `${iso}T12:00:00Z` : iso);
  const tz = iso.length <= 10 ? 'UTC' : 'America/Toronto';
  return { day: new Intl.DateTimeFormat('en-CA', { day: 'numeric', timeZone: tz }).format(d), month: new Intl.DateTimeFormat('en-CA', { month: 'short', timeZone: tz }).format(d).replace('.', '') };
};

/**
 * One step on a timeline: done (filled), now (red) or future (dashed). With `date`, the day and month on the left (in
 * words for screen readers); without, a plain list of stages (the renter's booking progress). `current` and `todo` are
 * the same as `now` and `future`; `href` links a step still to do.
 */
export function TimelineItem({ date, title, amount, meta, state = 'future', dateLabel, testId, href }: {
  date?: string; title: ReactNode; amount?: ReactNode; meta?: ReactNode; state?: 'done' | 'now' | 'future' | 'current' | 'todo'; dateLabel?: string; testId?: string; href?: string;
}) {
  const st = state === 'current' ? 'now' : state === 'todo' ? 'future' : state;
  const d = date ? fmtDay(date) : null;
  const words = st === 'done' ? ', done' : st === 'now' ? ', next' : ', to do';
  return (
    <li className={`pu-tl pu-tl--${st}${d ? '' : ' pu-tl--nodate'}`} data-testid={testId} aria-current={st === 'now' && !d ? 'step' : undefined}>
      {d && <span className="pu-tl__when" aria-hidden={dateLabel ? true : undefined}><b>{d.day}</b><span>{d.month}</span></span>}
      <div className="pu-tl__body">
        {dateLabel && <span className="vh">{dateLabel}: </span>}
        <span className="pu-tl__title"><span>{href && st !== 'done' ? <Link prefetch={false} className="link" href={href}>{title}</Link> : title}{!d && <span className="vh">{words}</span>}</span>{amount !== undefined && <span className="pu-tl__amount">{amount}</span>}</span>
        {meta && <span className="pu-tl__meta">{meta}</span>}
      </div>
    </li>
  );
}

export function Timeline({ children, label, testId }: { children: ReactNode; label: string; testId?: string }) {
  return <ol className="pu-timeline" aria-label={label} data-testid={testId}>{children}</ol>;
}
