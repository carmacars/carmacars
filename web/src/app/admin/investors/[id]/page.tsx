import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { monthOf } from '@/features/owner/Blocks';
import { $, Badge, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Investor', path: '/admin/investors', noindex: true, description: 'One investor.' });
type R = Record<string, unknown>;
export default async function Investor({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/investors/${id}`);
  const i = await read<(R & { investments: R[]; returns: R[]; documents: R[]; payouts: R[] }) | null>('investor', { id });
  if (!i) notFound();
  return (<>
    <PageHead kicker={<Link className="link" href="/admin/investors">Investors</Link>} title={<>{String(i.legal_name)} <Badge s={String(i.status)} /></>} />
    <div className="ad-cols ad-cols--2">
      <Card title="Record"><Kv rows={[['Type', String(i.investor_type ?? '')], ['Email', String(i.email ?? '')], ['Phone', String(i.phone ?? '')], ['Address', String(i.address ?? '')], ['Tax resident in Canada', i.tax_resident_canada ? 'Yes' : 'No'], ['Identity verified', t(i.identification_verified_at)]]} /></Card>
      <Card title="Investments"><Table rows={i.investments} empty="None." cols={[{ key: 'investment_date', label: 'Date', render: (r) => d(r.investment_date) }, { key: 'principal_cents', label: 'Principal', num: true, render: (r) => $(r.principal_cents) }, { key: 'yearly_bps', label: 'Yearly', num: true, render: (r) => `${Number(r.yearly_bps) / 100}%` }, { key: 'lockup_end_date', label: 'Lock-up ends', render: (r) => d(r.lockup_end_date) }, { key: 'status', label: 'Status' }]} /></Card>
      <Card title="Returns"><Table rows={i.returns} empty="None." cols={[{ key: 'return_month', label: 'Month', render: (r) => monthOf(String(r.return_month)) }, { key: 'return_cents', label: 'Return', num: true, render: (r) => $(r.return_cents) }, { key: 'disposition', label: 'Paid or reinvested' }, { key: 'status', label: 'Status' }]} /></Card>
      <Card title="Documents and payouts"><Table rows={i.documents} empty="No documents." cols={[{ key: 'title', label: 'Document' }, { key: 'kind', label: 'Kind' }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} />
        <Table rows={i.payouts} empty="No payouts." cols={[{ key: 'kind', label: 'Payout' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status' }, { key: 'paid_at', label: 'Paid', render: (r) => t(r.paid_at) }]} /></Card>
    </div>
  </>);
}
