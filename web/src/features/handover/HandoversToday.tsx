import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { when } from '@/features/agreement/model';
import { fmtDuration } from './late';

type Row = { booking_number: string; kind: 'pickup' | 'return'; at: string; vehicle: string; renter: string | null; late: boolean; minutes_late?: number };

// Today's check-outs and check-ins on the staff Today list (migration 0130): each opens its checklist in one tap.
export async function HandoversToday({ userId, aal, base }: { userId: string; aal?: 'aal1' | 'aal2' | null; base: '/admin' | '/va' }) {
  const rows = await door<Row[]>(userId, 'ops_read', 'handovers_today', {}, aal).catch(() => [] as Row[]);
  return (
    <Card title={`Check-outs and check-ins today (${rows.length})`} testId="handovers-today">
      {rows.length ? <ul className="ad-list">{rows.map((r) => {
        const b = `${base}/bookings/${encodeURIComponent(r.booking_number)}`;
        return (
          <li key={`${r.kind}-${r.booking_number}`}>
            <span>{when(r.at)} <Link prefetch={false} className="link" href={b}>{r.booking_number}</Link> {r.renter ?? ''}</span>
            <span className={r.late ? 'small ad-late' : 'small'}>{r.kind === 'pickup' ? 'check-out' : r.late ? `overdue by ${fmtDuration(r.minutes_late ?? 0)}` : 'check-in'}</span>
            <span className="ad-sub">{r.vehicle}</span>
            <Act ops action="handover_open" payload={{ booking: r.booking_number, kind: r.kind }} label={r.kind === 'pickup' ? 'Check out' : 'Check in'} variant="primary"
              go={`${b}/handover/{job}`} testId={`today-${r.kind}-${r.booking_number}`} />
          </li>);
      })}</ul> : <p className="small muted">No check-out or check-in due today.</p>}
    </Card>
  );
}
