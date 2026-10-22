import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { monthOf } from '@/features/owner/Blocks';
import { $, Badge, BookingLink, Card, Kv, PageHead, Table, d, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner statement', path: '/admin/statements', noindex: true, description: 'One owner statement, per vehicle.' });
type R = Record<string, unknown>;
type Veh = R & { vehicle: string; plate: string | null; lines: R[] };

export default async function Statement({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/statements/${id}`);
  const s = await read<(R & { vehicles: Veh[]; owner_lines: R[]; row: R }) | null>('owner_statement', { id });
  if (!s?.row) notFound();
  const r = s.row; const status = String(r.status);
  const R = [`/admin/statements/${id}`, '/admin/statements'];
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/statements">Owner statements</Link> · {String(r.owner_name)}</>} title={<>{monthOf(String(r.statement_month))} statement, v{String(r.version)} <Badge s={status} /></>}>
      <a className="btn btn--ghost btn--sm" href={`/files/owner_statement/${id}`} data-testid="statement-pdf">{status === 'draft' ? 'Preview PDF' : 'PDF'}</a>
      <a className="btn btn--ghost btn--sm" href={`/admin/reports/export?kind=owner_statement&id=${id}`}>CSV</a>
      {status === 'draft' && <Act action="statement_build" payload={{ owner: r.owner_id, month: r.statement_month }} label="Rebuild" refresh={R} />}
      {status === 'draft' && <Act action="statement_approve" payload={{ id }} label="Approve" variant="primary" testId="statement-approve" confirm="Approve the statement: the payout is prepared for approval and the Owner can see it." refresh={R} />}
      {['approved', 'paid'].includes(status) && !r.sent_at && <Act action="statement_issue" payload={{ id }} label="Issue to the owner" refresh={R} />}
      {status === 'approved' && <Act action="statement_reissue" payload={{ id }} label="Reissue" variant="danger" fields={[{ name: 'reason', label: 'Reason', required: true }]} go="/admin/statements/{id}" />}
    </PageHead>
    <Kv rows={[['Owner Revenue', $(r.owner_revenue_cents)], ['Management fee (Revenue Share)', $(r.revenue_share_cents)], ['Deductions', $(r.deductions_cents)], ['Credits', $(r.credits_cents)], ['Balance brought forward', $(r.balance_brought_forward_cents)], ['Payout', <b key="p" data-testid="statement-payout">{$(r.payout_cents)}</b>], ['Payout date', d(r.payout_date)], ['Approved', r.approved_at ? `${d(r.approved_at)}` : ''], ['Issued', d(r.sent_at)]]} />
    {s.vehicles.map((v) => (
      <Card key={String(v.vehicle_id)} title={`${v.vehicle} ${v.plate ?? ''}`} aside={<span className="small">{label(v.management_mode)} · payable {$(v.payable_cents)}</span>}>
        <Kv rows={[['Owner Revenue', $(v.owner_revenue_cents)], ['Management fee (Revenue Share)', $(v.revenue_share_cents)], ['Fees deducted', $(v.fees_deducted_cents)], ['Owner costs', $(v.owner_costs_deducted_cents)], ['Credits', $(v.credits_cents)]]} />
        <Table rows={v.lines} rowKey={(_, i) => String(i)} empty="No activity this month." cols={[{ key: 'line_type', label: 'Line' }, { key: 'description', label: 'Description', className: 'wrap' }, { key: 'booking_number', label: 'Booking', render: (x) => x.booking_number ? <BookingLink n={x.booking_number} /> : null }, { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }]} />
      </Card>))}
    {s.owner_lines?.length > 0 && <Card title="Owner lines"><Table rows={s.owner_lines} rowKey={(_, i) => String(i)} cols={[{ key: 'line_type', label: 'Line' }, { key: 'description', label: 'Description', className: 'wrap' }, { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }]} /></Card>}
  </>);
}
