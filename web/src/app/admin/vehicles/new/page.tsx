import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { adminOwners } from '@/server/admin/data';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { AddCarForm } from '@/features/supply/AddCarForm';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a car', path: '/admin/vehicles/new', noindex: true, description: 'Add a program owner\'s car, a CarmaCars-owned car or a partner\'s car.' });

type Partner = { id: string; business_name: string; status: string; commission_effective_bps: number };

// Admin > Vehicles > Add a car (migration 0046).
export default async function AddCar() {
  const { user } = await page('/admin/vehicles/new');
  const [owners, partners, s] = await Promise.all([adminOwners(user), door<Partner[]>(user.id, 'ops_read', 'partners'),
    door<{ partner_commission_bps: number }>(user.id, 'ops_read', 'supply_settings')]);
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/admin/vehicles">Vehicles</Link>} title="Add a car" />
      <div style={{ maxWidth: '52rem' }}>
        <AddCarForm owners={owners.map((o) => ({ id: o.owner_id, name: o.legal_name }))}
          partners={partners.filter((p) => p.status !== 'ended').map((p) => ({ id: p.id, name: p.business_name, note: `${p.commission_effective_bps / 100}% commission` }))}
          defaultCommission={s.partner_commission_bps} />
      </div>
    </>
  );
}
