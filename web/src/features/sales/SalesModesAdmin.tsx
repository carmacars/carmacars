import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { Card, Table } from '@/features/admin/ui';
import { pctBps } from '@/features/sales/Commissions';
import { MODE_LABEL, type Replies, type SalesMode, type SalesProgress } from '@/features/sales/RemoteDuties';

// Admin > Settings > Staff: the Sales staff and their work mode (migration 0174, admin_read sales_modes): in person or
// remote, this month's rate and the rate the month would end at, and for remote the touches against the minimum, this
// week's peak-hour cover and the reply time. The mode is set here (admin_do staff_sales_mode_set); the rates are in
// Settings > Program settings, Staff commissions.
export interface SalesModes {
  settings: { in_person: number[]; remote: number[]; mid_days: number; high_days: number; min_touches: number; drop_tiers: number; floor_bps: number; cover_hours: number; reply_minutes: number };
  people: Array<{ id: string; name: string; email: string; status: string; mode: SalesMode; progress: SalesProgress; touches: number | null; cover_hours: number | null; replies: Replies | null }>;
}

export const MODE_OPTIONS: Array<[string, string]> = [['in_person', 'In person (Toronto): 10%, 15%, 20%'], ['remote', 'Remote (worldwide contractor): 5%, 10%, 15%, with remote duties']];

export function SalesModeAct({ staff, mode, refresh, testId }: { staff: string; mode: SalesMode | null; refresh: string[]; testId?: string }) {
  return <Act action="staff_sales_mode_set" payload={{ staff }} label="Work mode" testId={testId} refresh={refresh} done="Saved. Months already approved keep the mode they were approved in."
    fields={[{ name: 'mode', label: 'Works', type: 'select', options: MODE_OPTIONS, required: true, value: mode ?? 'in_person' }, { name: 'reason', label: 'Reason (kept in the log)', type: 'text' }]} />;
}

export function SalesModesCard({ data }: { data: SalesModes }) {
  const s = data.settings;
  type Row = SalesModes['people'][number] & Record<string, unknown>;
  return (
    <Card title="Sales staff: in person or remote" testId="sales-modes">
      <p className="small muted">In person: {s.in_person.map(pctBps).join(', ')} at under {s.mid_days}, from {s.mid_days} and from {s.high_days} rental days a month; credit for walk-ins, handovers, partner visits and the rentals they source.
        Remote: {s.remote.map(pctBps).join(', ')}; only the rentals they source; {s.cover_hours} peak hours a week Thursday to Sunday afternoons, replies within {s.reply_minutes} minutes,
        the daily checklist and {s.min_touches} touches a month ({s.drop_tiers > 0 ? `under it the month's rate drops ${s.drop_tiers === 1 ? 'one tier' : `${s.drop_tiers} tiers`}, at least ${pctBps(s.floor_bps)}` : 'no drop'}).
        Change the rates in <Link prefetch={false} className="link" href="/admin/settings/program">Program settings</Link>.</p>
      <Table<Row> testId="sales-modes-table" caption="Sales staff and their work mode" rows={data.people as Row[]} rowKey={(r) => r.id} empty="No Sales staff yet." cols={[
        { key: 'name', label: 'Name', render: (r) => <Link prefetch={false} className="link" href={`/admin/staff/${r.id}/sales`}>{r.name}</Link> },
        { key: 'mode', label: 'Mode', render: (r) => <span data-testid={`sales-mode-${r.email}`}>{MODE_LABEL[r.mode]}</span> },
        { key: 'rate', label: 'Rate now', num: true, render: (r) => `${pctBps(r.progress.rate_bps)} (${r.progress.days} days)` },
        { key: 'projected', label: 'Month ends at', num: true, render: (r) => <span className={r.progress.projected_bps < r.progress.rate_bps ? 'va-warn' : undefined}>{pctBps(r.progress.projected_bps)}</span> },
        { key: 'touches', label: 'Touches', num: true, render: (r) => (r.mode === 'remote' ? `${r.touches ?? 0} of ${r.progress.min_touches}` : '') },
        { key: 'cover', label: 'Peak hours this week', num: true, render: (r) => (r.mode === 'remote' ? `${r.cover_hours ?? 0} of ${s.cover_hours}` : '') },
        { key: 'reply', label: 'Replies on time', num: true, render: (r) => (r.mode === 'remote' && r.replies ? (r.replies.count ? `${r.replies.within} of ${r.replies.count}${r.replies.median_minutes !== null ? `, median ${r.replies.median_minutes} min` : ''}` : 'none yet') : '') },
        { key: 'act', label: 'Actions', render: (r) => <SalesModeAct staff={r.id} mode={r.mode} refresh={['/admin/settings/staff']} testId={`sales-mode-set-${r.email}`} /> }]} />
    </Card>
  );
}
