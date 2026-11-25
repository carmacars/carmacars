import Link from '@/components/Link';
import { Card } from '@/features/admin/ui';
import { BUCKETS, BUCKET_TONE, WHY_WORDS, byBucket, dayWords, dueIn, type Bucket, type Queue as Q } from './model';
import './checkins.css';

// The check-in visit queue (release 50, migration 4000): the same for an Admin, customer service, Fleet and field work.
// Booked, due, overdue (soft: a suggestion to the renter, never a fee) and done in the last 30 days, then the long rentals
// whose next visit is still ahead. Each visit opens its checklist.
export function CheckinQueue({ q, base, show }: { q: Q; base: string; show?: string }) {
  const groups = byBucket(q.visits);
  const tab = (BUCKETS.find(([k]) => k === show)?.[0] ?? null) as Bucket | null;
  const shown = tab ? BUCKETS.filter(([k]) => k === tab) : BUCKETS;
  return (
    <div className="stack" data-testid="checkin-queue" data-guide="checkin-queue">
      {!q.settings.enabled && <p className="alert alert--warn" role="status"><span>Check-in visits are off in Program settings: no new visits or reminders.</span></p>}
      <p className="small muted">For rentals of {q.settings.min_days} days or more, long-term weekly rentals and rideshare drivers: about every {q.settings.interval_days} days, the renter reminded {q.settings.lead_days} days before. A suggestion to the renter, never a requirement or a fee.</p>
      <nav className="ci-tabs" aria-label="Show">
        <Link prefetch={false} className={`btn btn--sm ${tab ? 'btn--ghost' : 'btn--primary'}`} href={`${base}/check-ins`}>All</Link>
        {BUCKETS.map(([k, l]) => <Link key={k} prefetch={false} className={`btn btn--sm ${tab === k ? 'btn--primary' : 'btn--ghost'}`} href={`${base}/check-ins?show=${k}`} data-testid={`checkin-tab-${k}`}>{l} ({groups[k].length})</Link>)}
      </nav>
      {shown.map(([k, label]) => (
        <Card key={k} title={`${label} (${groups[k].length})`} testId={`checkin-bucket-${k}`}>
          {groups[k].length === 0 ? <p className="small muted">None.</p> : (
            <ul className="ci-list">{groups[k].map((v) => (
              <li key={v.id} className="ci-row" data-testid="checkin-row">
                <span className="stack" style={{ gap: 0 }}>
                  <b>{v.vehicle_name}{v.plate ? ` (${v.plate})` : ''}</b>
                  <span className="small">{v.renter_name ?? 'Renter'}, booking {v.booking_number}</span>
                  <span className="small muted">{v.status === 'done' ? `Done ${v.done_at ? dayWords(v.done_at.slice(0, 10)) : ''}${v.odometer_km ? `, ${v.odometer_km.toLocaleString('en-CA')} km` : ''}${v.damage_found ? ', damage found' : ''}`
                    : v.status === 'skipped' ? `Skipped: ${v.closed_reason ?? ''}` : `${v.time_words} (${dueIn(v.due_on, q.today)})`}</span>
                </span>
                <span className="row" style={{ gap: 'var(--s-2)' }}>
                  <span className={`ad-b ${BUCKET_TONE[v.bucket]}`}>{BUCKETS.find(([x]) => x === v.bucket)?.[1]}</span>
                  <Link prefetch={false} className={`btn btn--sm ${v.status === 'done' || v.status === 'skipped' ? 'btn--ghost' : 'btn--primary'}`} href={`${base}/check-ins/${v.id}`} data-testid="checkin-open" data-guide="checkin-open">{v.status === 'done' || v.status === 'skipped' ? 'View' : 'Do the visit'}</Link>
                </span>
              </li>))}
            </ul>)}
        </Card>
      ))}
      {!tab && q.upcoming.length > 0 && (
        <Card title={`Coming up (${q.upcoming.length})`} testId="checkin-upcoming">
          <ul className="ci-list">{q.upcoming.map((u) => (
            <li key={u.booking_id} className="ci-row"><span className="small"><b>{u.vehicle_name}</b>, {u.renter_name ?? 'Renter'}, booking {u.booking_number}: around {dayWords(u.next_on)} ({WHY_WORDS[u.why]})</span></li>))}
          </ul>
        </Card>
      )}
    </div>
  );
}
