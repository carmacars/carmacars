import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import type { DataIssue } from './model';

// r48 FE (3197): every open data issue per person (staff, owners, renters with a booking in the last 90 days), with Send
// reminder: a staff alert to a staff member; for an owner or a renter the pop-up comes back at once, even if dismissed.
type Row = { user_id: string; name: string; email: string | null; issues: DataIssue[]; reminded_at: string | null };
const WHO: Record<string, string> = { staff: 'Staff', owner: 'Owners', renter: 'Renters' };

export async function DataIssuesCard({ userId, audience, refresh }: { userId: string; audience: 'staff' | 'owner' | 'renter'; refresh: string }) {
  const rows = await door<Row[]>(userId, 'admin_read', 'data_issues', { audience }).catch(() => [] as Row[]);
  return (
    <Card title={`${WHO[audience]}: data to check (${rows.length})`} testId={`data-issues-${audience}`}>
      {!rows.length ? <p className="small muted">Nothing looks wrong on anyone&apos;s record. Each person sees a pop-up with the fix when something does.</p> : (
        <ul className="ow-rows">{rows.map((r) => (
          <li key={r.user_id} data-testid={`data-issues-${r.user_id}`}>
            <span><b>{r.name}</b>{r.email ? ` (${r.email})` : ''}
              {r.issues.map((i) => <span key={i.key} className="small"><br />{i.severity === 'blocking' ? 'Blocking: ' : ''}{i.message}</span>)}
              {r.reminded_at && <span className="small muted"><br />Reminded {r.reminded_at.slice(0, 16).replace('T', ' ')}</span>}</span>
            <span className="ad-actions"><Act action="data_check_remind" payload={{ user: r.user_id }} label="Send reminder" refresh={[refresh]} done="Sent." testId={`data-remind-${r.user_id}`} /></span>
          </li>))}</ul>)}
    </Card>
  );
}
