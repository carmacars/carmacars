import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Badge, Card, PageHead, Table, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partners', path: '/admin/settings/partners', noindex: true, description: 'Partner companies and their CRMs.' });

type Link0147 = { connected: boolean; enabled: boolean; last_sync_at: string | null; last_sync_ok: boolean | null; last_error: string | null; location_id: string | null } | null;
type Row = { id: string; business_name: string; status: string; partner_number: string; cars: number; link: Link0147 };

// Admin > Settings > Partners (migration 0147): every partner company and its CRM link.
export default async function PartnersSettings() {
  const { read } = await page('/admin/settings/partners');
  const r = await read<{ partners: Row[]; shareable: number }>('partner_crm');
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="Partners" />
      <p className="small muted">Connect a partner company&apos;s CRM so they see the cars we can rent them ({r.shareable} on the site now: CarmaCars&apos; own and program owners&apos; cars, never a partner&apos;s), and their cars come to us. The partner record itself (contacts, commission, insurance, payouts) is in People &gt; Partners.</p>
      <Card title={`Partner companies (${r.partners.length})`} testId="crm-partners">
        <Table rows={r.partners as unknown as Array<Record<string, unknown>>} rowKey={(x) => String(x.id)} empty="No partners yet. Add one in People > Partners." cols={[
          { key: 'business_name', label: 'Partner', render: (x) => <Link prefetch={false} className="link" href={`/admin/settings/partners/${String(x.id)}`} data-testid={`crm-partner-${String(x.business_name).toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}>{String(x.business_name)}</Link> },
          { key: 'cars', label: 'Their cars here', num: true },
          { key: 'link', label: 'CRM', render: (x) => { const l = x.link as Link0147; return !l?.connected ? 'Not connected' : !l.enabled ? 'Paused' : <><Badge s={l.last_sync_ok === false ? 'failed' : 'active'}>{l.last_sync_ok === false ? 'Failing' : 'Connected'}</Badge>{l.last_sync_at ? <span className="ad-sub">Last sync {t(l.last_sync_at)}</span> : null}</>; } }
        ]} />
      </Card>
    </>
  );
}
