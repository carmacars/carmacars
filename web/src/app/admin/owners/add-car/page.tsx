import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { AddOwnerCar } from '@/features/owner-billing/AddOwnerCar';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a car for an owner', path: '/admin/owners/add-car', noindex: true, description: 'Add a car for an owner, so the owner does not fill the application.' });

// Add a car for an owner (migration 0067), from the owner page ("Add another car"), Owners, and Cars > Add a car >
// A program owner's car.
export default async function AddCarForOwner({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/owners/add-car'), searchParams]);
  const owner = /^[0-9a-f-]{36}$/.test(sp.owner ?? '') ? sp.owner! : null;
  const facts = await door<Parameters<typeof AddOwnerCar>[0]['initial']>(user.id, 'ops_read', 'owner_add_car_facts', { owner_id: owner });
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href={owner ? `/admin/owners/${owner}` : '/admin/owners'}>{facts.owner ? facts.owner.legal_name : 'Owners'}</Link>} title={facts.owner ? 'Add another car' : 'Add a car for an owner'} />
      <p className="small muted" style={{ maxWidth: '48rem' }}>Everything the owner would enter in their application, entered for them. The owner gets one email to review the details, correct anything and sign; or they sign on paper and you record it.</p>
      <div style={{ maxWidth: '60rem' }}><AddOwnerCar initial={facts} base="/admin" /></div>
    </>
  );
}
