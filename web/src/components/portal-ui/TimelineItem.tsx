import type { ReactNode } from 'react';

const fmtDay = (iso: string) => {
  const d = new Date(iso.length <= 10 ? `${iso}T12:00:00Z` : iso);
  const tz = iso.length <= 10 ? 'UTC' : 'America/Toronto';
  return { day: new Intl.DateTimeFormat('en-CA', { day: 'numeric', timeZone: tz }).format(d), month: new Intl.DateTimeFormat('en-CA', { month: 'short', timeZone: tz }).format(d).replace('.', '') };
};

/** One dated step on a timeline: done (filled), now (red) or future (dashed). The date is in words for screen readers. */
export function TimelineItem({ date, title, amount, meta, state = 'future', dateLabel, testId }: {
  date: string; title: ReactNode; amount?: ReactNode; meta?: ReactNode; state?: 'done' | 'now' | 'future'; dateLabel?: string; testId?: string;
}) {
  const d = fmtDay(date);
  return (
    <li className={`pu-tl pu-tl--${state}`} data-testid={testId}>
      <span className="pu-tl__when" aria-hidden={dateLabel ? true : undefined}><b>{d.day}</b><span>{d.month}</span></span>
      <div className="pu-tl__body">
        {dateLabel && <span className="vh">{dateLabel}: </span>}
        <span className="pu-tl__title"><span>{title}</span>{amount !== undefined && <span className="pu-tl__amount">{amount}</span>}</span>
        {meta && <span className="pu-tl__meta">{meta}</span>}
      </div>
    </li>
  );
}

export function Timeline({ children, label, testId }: { children: ReactNode; label: string; testId?: string }) {
  return <ol className="pu-timeline" aria-label={label} data-testid={testId}>{children}</ol>;
}
