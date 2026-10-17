import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { PageHead, Table } from '@/features/admin/ui';
import { PARTNER_FIELDS } from '@/features/supply/partner-fields';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partners', path: '/admin/partners', noindex: true, description: 'Partner rental companies whose cars CarmaCars rents out on commission.' });

type P = { id: string; partner_number: string; business_name: string; contact_name: string | null; email: string | null; status: string; vehicles: number;
  commission_effective_bps: number; commission_is_default: boolean; agreement_status: string; insurance_warning: string | null; has_portal: boolean };

// Admin > Partners (migration 0046): every partner rental company, its cars, commission, agreement and insurance.
export default async function Partners() {
  const { user } = await page('/admin/partners');
  const rows = await door<P[]>(user.id, 'ops_read', 'partners');
  return (
    <>
      <PageHead title="Partners" kicker={`${rows.length} partner rental compan${rows.length === 1 ? 'y' : 'ies'}`}>
        <Act ops action="partner_save" label="Add a partner" variant="primary" testId="partner-add" go="/admin/partners/{id}" fields={PARTNER_FIELDS({})} />
      </PageHead>
      <p className="small muted">A partner rental company supplies cars that CarmaCars rents out. CarmaCars keeps its commission; the partner gets the rest on a monthly statement and payout, like an owner but with no fees. Partners may use the owner portal to see their cars, bookings, statements and payouts and to sign the partner agreement.</p>
      <Table<P> testId="partners" rows={rows} rowKey={(r) => r.id} empty="No partners yet. Press Add a partner to add a rental company whose cars CarmaCars rents out." cols={[
        { key: 'business_name', label: 'Partner', render: (r) => <Link prefetch={false} className="link" href={`/admin/partners/${r.id}`}>{r.business_name}</Link> },
        { key: 'partner_number', label: 'No.' }, { key: 'contact_name', label: 'Contact' },
        { key: 'vehicles', label: 'Cars', num: true },
        { key: 'commission_effective_bps', label: 'Commission', num: true, render: (r) => `${r.commission_effective_bps / 100}%${r.commission_is_default ? ' (default)' : ''}` },
        { key: 'agreement_status', label: 'Agreement', render: (r) => r.agreement_status.replace(/_/g, ' ') },
        { key: 'insurance_warning', label: 'Insurance', render: (r) => r.insurance_warning ? <span className="ad-flag ad-flag--red">{r.insurance_warning}</span> : 'On file' },
        { key: 'has_portal', label: 'Portal', render: (r) => (r.has_portal ? 'Yes' : 'No') }, { key: 'status', label: 'Status' }]} />
    </>
  );
}
