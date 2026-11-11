import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';

// Field staff working today (migration 2250): every office role and the Admins see who is in the field today, their hours,
// phone and whether they are on now. On the Schedule page and the staff home (Today).
export type FieldTodayRow = { user_id: string; name: string; phone: string | null; starts_at: string; ends_at: string; shifts: number; state: 'on' | 'later' | 'done' };

const hm = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' });
const STATE: Record<FieldTodayRow['state'], string> = { on: 'On shift now', later: 'Later today', done: 'Done for today' };

export function FieldTodayCard({ rows }: { rows: FieldTodayRow[] }) {
  return (
    <Card title={`Field staff working today (${rows.length})`} testId="field-today">
      {rows.length ? <ul className="ad-list">{rows.map((r) => (
        <li key={r.user_id} data-testid={`field-today-${r.user_id}`}>
          <span><b>{r.name}</b> · {hm(r.starts_at)} to {hm(r.ends_at)}{r.phone ? <> · <a className="link" href={`tel:${r.phone}`}>{r.phone}</a></> : null}</span>
          <span className="ad-sub">{STATE[r.state]}</span>
        </li>))}</ul>
        : <p className="small muted">No field staff have a shift today.</p>}
    </Card>
  );
}

export async function FieldToday({ userId, aal }: { userId: string; aal?: 'aal1' | 'aal2' | null }) {
  const v = await door<{ field_today?: FieldTodayRow[] }>(userId, 'ops_read', 'staff_schedules', {}, aal).catch(() => ({ field_today: [] as FieldTodayRow[] }));
  return <FieldTodayCard rows={v.field_today ?? []} />;
}
