import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, PageHead, Table, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Investors', path: '/admin/investors', noindex: true, description: 'Investor records and returns.' });
type R = Record<string, unknown>;
export default async function Investors() {
  const { list } = await page('/admin/investors');
  const { rows } = await list('investors', { order: 'legal_name', asc: true, limit: 300 });
  const last = new Date(); last.setUTCDate(1); last.setUTCMonth(last.getUTCMonth() - 1);
  return (<>
    <PageHead title="Investors"><Act action="investor_returns_accrue" label="Accrue returns for a month" fields={[{ name: 'month', label: 'Month (first day)', type: 'date', required: true, value: last.toISOString().slice(0, 10) }]} refresh={['/admin/investors']} /></PageHead>
    <Table<R> testId="investors" rows={rows} empty="No investors on file." cols={[{ key: 'legal_name', label: 'Investor', render: (r) => <Link className="link" href={`/admin/investors/${String(r.id)}`}>{String(r.legal_name)}</Link> }, { key: 'investor_type', label: 'Type' }, { key: 'email', label: 'Email' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'identification_verified_at', label: 'Identity verified', render: (r) => t(r.identification_verified_at) }]} />
  </>);
}
