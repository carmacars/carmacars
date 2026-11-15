import { Card, t, $ } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { rollingWords, type RollingState } from './model';

// A long-term rental paid weekly (release 48, migration 2981): on the booking page for Admin and staff. On: the car stays
// out on the calendar until the renter gives notice; each week's payment moves the return 7 days; near the return with
// the next week unpaid, the renter gets the pay link and an Admin a To do. End rental on sets the last day.
export function RollingCard({ booking, x, refresh }: { booking: string; x: RollingState; refresh: string[] }) {
  const w = rollingWords(x);
  return (
    <Card title="Long-term, paid weekly" testId="rolling-weekly" aside={<span className="small" data-testid="rolling-weekly-state">{x.on ? 'On' : 'Off'}</span>}>
      <p className="small">{w.line}</p>
      {x.on && x.next && <p className="small" data-testid="rolling-weekly-next">Next week: {$(x.next.total_cents)}, to {t(x.next.new_return_at)}.{x.next.link_sent ? ' The pay link is sent.' : ''}</p>}
      {x.may_change && (
        <span className="ad-actions">
          {(x.on || x.may_turn_on) && <Act ops action="rolling_weekly_set" payload={{ booking, on: !x.on }} label={x.on ? 'Turn off' : 'Turn on'} testId="rolling-weekly-toggle" refresh={refresh}
            done={x.on ? 'No longer long-term weekly.' : 'Long-term, paid weekly: the car stays out until the renter gives notice.'}
            confirm={x.on ? 'Turn off long-term weekly? The car shows free after the current return again.' : 'Make this a long-term rental paid weekly? The car stays out on the calendar until the renter gives notice.'} />}
          {x.on && <Act ops action="rolling_weekly_end" payload={{ booking }} label={x.end_at ? 'Change the end date' : 'End rental on'} testId="rolling-weekly-end" refresh={refresh} done="End date saved."
            fields={[{ name: 'end_on', label: 'Last day (empty: until notice)', type: 'date', value: x.end_at ? x.end_at.slice(0, 10) : undefined,
              hint: 'The renter gave notice: the rental ends that day, at the time of the current return. The car shows free after it.' }]} />}
        </span>)}
    </Card>
  );
}
