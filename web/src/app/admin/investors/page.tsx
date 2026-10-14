import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, PageHead, Table, t } from '@/features/admin/ui';
import { InviteRecordButton, PasswordLinkButton } from '@/features/admin/AccountTools';
import { ViewAsButton } from '@/features/admin/ViewAs';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Investors', path: '/admin/investors', noindex: true, description: 'Investor records and returns.' });
type R = Record<string, unknown>;
export default async function Investors() {
  const { list } = await page('/admin/investors');
  const { rows } = await list('investors', { order: 'legal_name', asc: true, limit: 300 });
  const last = new Date(); last.setUTCDate(1); last.setUTCMonth(last.getUTCMonth() - 1);
  return (<>
    <PageHead title="Investors"><Act action="investor_returns_accrue" label="Accrue returns for a month" fields={[{ name: 'month', label: 'Month (first day)', type: 'date', required: true, value: last.toISOString().slice(0, 10) }]} refresh={['/admin/investors']} /></PageHead>
    <Table<R> testId="investors" rows={rows} empty="No investors on file." cols={[{ key: 'legal_name', label: 'Investor', render: (r) => <Link prefetch={false} className="link" href={`/admin/investors/${String(r.id)}`}>{String(r.legal_name)}</Link> }, { key: 'investor_type', label: 'Type' }, { key: 'email', label: 'Email' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'identification_verified_at', label: 'Identity verified', render: (r) => t(r.identification_verified_at) },
      { key: 'signin', label: 'Sign-in', render: (r) => r.user_id
        ? (['active', 'exited'].includes(String(r.status)) ? <span className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}><ViewAsButton user={String(r.user_id)} portal="investor" testId={`view-as-investor-${String(r.id)}`} /><PasswordLinkButton userId={String(r.user_id)} /></span> : <PasswordLinkButton userId={String(r.user_id)} />)
        : String(r.status) === 'refused' ? '' : <InviteRecordButton role="investor" recordId={String(r.id)} email={(r.email as string | null) ?? null} name={String(r.legal_name)} testId={`invite-investor-${String(r.id)}`} /> }]} />
  </>);
}
