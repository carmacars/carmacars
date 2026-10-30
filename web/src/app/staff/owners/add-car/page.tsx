import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { AddOwnerCar } from '@/features/owner-billing/AddOwnerCar';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a car for an owner', path: '/staff/owners/add-car', noindex: true, description: 'Add a car for an owner.' });

// Customer service and fleet add a car for an owner (migration 0067). An Admin approves the terms and first invoices
// they propose; the owner then gets one email.
export default async function VaAddCar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/staff/owners/add-car', ['cs', 'fleet']), searchParams]);
  const owner = /^[0-9a-f-]{36}$/.test(sp.owner ?? '') ? sp.owner! : null;
  const facts = await read<Parameters<typeof AddOwnerCar>[0]['initial']>('owner_add_car_facts', { owner_id: owner });
  return (
    <>
      <PageHead title={facts.owner ? `Add another car for ${facts.owner.legal_name}` : 'Add a car for an owner'} />
      <p className="small muted" style={{ maxWidth: '48rem' }}>Enter everything for the owner. An Admin checks the terms and first invoice, then approves; the owner gets one email to review and sign.</p>
      <div style={{ maxWidth: '60rem' }}><AddOwnerCar initial={facts} base="/staff" /></div>
    </>
  );
}
