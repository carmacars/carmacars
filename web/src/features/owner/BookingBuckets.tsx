'use client';
import { useState, type ReactNode } from 'react';
import Link from '@/components/Link';
import { BUCKETS, bookingsHref, type Bucket } from './bookings';

// On a trip / Upcoming / Past (r48 ops): three tabs over lists the server already rendered, so switching is instant.
// The address keeps the choice (?when=), so a link or a reload opens the same list. Arrow keys move between the tabs.
// Above them, the filter by car: every car a chip (a link: the server filters the lists, the timeline and the history),
// which keeps the list you are on.
export function BookingBuckets({ initial, counts, panels, cars, car }: { initial: Bucket; counts: Record<Bucket, number>; panels: Record<Bucket, ReactNode>;
  cars: Array<{ vehicle_id: string; name: string }>; car: string | null }) {
  const [at, setAt] = useState<Bucket>(initial);
  const pick = (b: Bucket) => {
    setAt(b);
    try { const u = new URL(window.location.href); u.searchParams.set('when', b); window.history.replaceState(null, '', u); } catch { /* the tabs still work */ }
  };
  const onKey = (e: React.KeyboardEvent) => {
    const i = BUCKETS.findIndex(([k]) => k === at);
    const n = e.key === 'ArrowRight' ? (i + 1) % BUCKETS.length : e.key === 'ArrowLeft' ? (i + BUCKETS.length - 1) % BUCKETS.length : -1;
    if (n < 0) return;
    e.preventDefault(); pick(BUCKETS[n]![0]);
    (e.currentTarget.querySelectorAll<HTMLElement>('[role="tab"]')[n])?.focus();
  };
  return (
    <div className="ob-buckets" data-testid="owner-bookings">
      {cars.length > 1 && (
        <nav className="ob-cars" aria-label="Filter by car" data-testid="owner-bookings-cars">
          <Link prefetch={false} scroll={false} className="ob-chip" href={bookingsHref({ when: at })} aria-current={!car ? 'true' : undefined}>All cars</Link>
          {cars.map((c) => <Link prefetch={false} scroll={false} key={c.vehicle_id} className="ob-chip" href={bookingsHref({ when: at, car: c.vehicle_id })} aria-current={car === c.vehicle_id ? 'true' : undefined} data-testid="owner-bookings-car">{c.name}</Link>)}
        </nav>)}
      <div className="ob-tabs" role="tablist" aria-label="Bookings by when" onKeyDown={onKey}>
        {BUCKETS.map(([k, label]) => (
          <button key={k} type="button" role="tab" id={`ob-tab-${k}`} aria-selected={at === k} aria-controls={`ob-panel-${k}`} tabIndex={at === k ? 0 : -1} className="ob-tab" onClick={() => pick(k)} data-testid={`owner-bookings-tab-${k}`}>
            <span>{label}</span><span className="ob-tab__n" data-zero={counts[k] ? undefined : 'yes'}>{counts[k]}</span></button>))}
      </div>
      {BUCKETS.map(([k]) => <div key={k} role="tabpanel" id={`ob-panel-${k}`} aria-labelledby={`ob-tab-${k}`} hidden={at !== k} className="ob-panel" data-testid={`owner-bookings-panel-${k}`}>{panels[k]}</div>)}
    </div>
  );
}
