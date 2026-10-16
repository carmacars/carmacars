import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Card, PageHead, Table } from '@/features/admin/ui';
import { DeleteSampleCars } from '@/features/supply/DeleteCar';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sample cars', path: '/admin/vehicles/samples', noindex: true, description: 'The sample cars the site started with, and deleting them.' });

type S = { id: string; name: string; plate: string | null; blockers: string[] };

// The sample cars (vehicles.is_sample, 0035) and "Delete all sample cars" (0046): each one with nothing tied to money goes.
export default async function SampleCars() {
  const { user } = await page('/admin/vehicles/samples');
  const rows = await door<S[]>(user.id, 'ops_read', 'sample_cars');
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/admin/vehicles">Vehicles</Link>} title="Sample cars" />
      <Card title={`${rows.length} sample car${rows.length === 1 ? '' : 's'}`} testId="sample-cars">
        <Table<S> rows={rows} empty="No sample cars left." rowKey={(r) => r.id} cols={[
          { key: 'name', label: 'Car', render: (r) => <Link prefetch={false} className="link" href={`/admin/vehicles/${r.id}`}>{r.name}</Link> }, { key: 'plate', label: 'Plate' },
          { key: 'blockers', label: 'Can be deleted', render: (r) => r.blockers.length ? `No: ${r.blockers.join(', ')}` : 'Yes' }]} />
        {rows.length > 0 && <DeleteSampleCars count={rows.length} />}
      </Card>
    </>
  );
}
