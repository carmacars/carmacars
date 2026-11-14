import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { when } from '@/features/agreement/model';

export type MissingRow = { booking_id: string; booking_number: string; kind: 'pickup' | 'return'; status: string; at: string; car: string | null; renter: string | null;
  state: 'missing' | 'details_pending'; assigned_to: string | null; mine: boolean };

// r44 (2815): the past check-ins and check-outs still missing their photos and readings (a rental recorded after the fact,
// a pickup recorded with the details later, a closed booking). Field staff see the bookings they handled or were given and
// add the photos and readings there; an Admin and Fleet see every one and give it to a field staff member.
export async function MissingHandovers({ userId, aal, mode, base }: { userId: string; aal?: 'aal1' | 'aal2' | null; mode: 'admin' | 'fleet' | 'field'; base: '/admin' | '/staff' }) {
  const rows = await door<MissingRow[]>(userId, 'ops_read', 'handover_missing', {}, aal).catch(() => [] as MissingRow[]);
  const assign = mode !== 'field';
  const staff = assign ? (await door<{ staff: Array<{ id: string; name: string }> }>(userId, 'ops_read', 'field_staff', {}, aal).catch(() => ({ staff: [] }))).staff : [];
  const word = (k: MissingRow['kind']) => (k === 'pickup' ? 'Check-in' : 'Check-out');
  return (
    <Card title={`Missing check-in and check-out (${rows.length})`} testId="missing-handovers">
      <p className="small muted">{mode === 'field' ? 'Past rentals you handled or were given: add the photos, the odometer and the fuel of each.' : 'Past rentals with no photos and readings for their check-in or check-out. Give each to a field staff member, or add them yourself.'}</p>
      {rows.length ? <ul className="ad-list">{rows.map((r) => {
        const href = mode === 'field' ? `/staff/field/jobs/{job}` : `${base}/bookings/${encodeURIComponent(r.booking_number)}/handover/{job}`;
        return (
          <li key={`${r.kind}-${r.booking_id}`} data-testid={`missing-${r.kind}-${r.booking_number}`}>
            <span>{word(r.kind)} {when(r.at)} {mode === 'field' ? <b>{r.booking_number}</b> : <Link prefetch={false} className="link" href={`${base}/bookings/${encodeURIComponent(r.booking_number)}`}>{r.booking_number}</Link>} {r.renter ?? ''}</span>
            <span className="ad-sub">{r.car ?? ''}{r.state === 'details_pending' ? ', started, details to add' : ''}{r.assigned_to ? `, given to ${r.assigned_to}` : ''}</span>
            <span className="ad-actions">
              <Act ops action="handover_open" payload={{ booking: r.booking_id, kind: r.kind }} label="Add the photos and readings" variant="primary" go={href} testId={`missing-open-${r.kind}-${r.booking_number}`} />
              {assign && staff.length > 0 && <Act ops action="handover_missing_assign" payload={{ booking: r.booking_id, kind: r.kind }} label="Give to field staff" refresh={[]}
                done="Given. It is on their list." testId={`missing-assign-${r.kind}-${r.booking_number}`}
                fields={[{ name: 'staff', label: 'Field staff member', type: 'select', required: true, options: staff.map((s) => [s.id, s.name] as [string, string]) }]} />}
            </span>
          </li>);
      })}</ul> : <p className="small muted">{mode === 'field' ? 'Nothing missing on your past rentals.' : 'Every past check-in and check-out has its photos and readings.'}</p>}
    </Card>
  );
}
