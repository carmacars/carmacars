import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { ProfitExtras } from '@/features/profit-extras/ProfitExtras';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Kickbacks and repairs', path: '/admin/money/kickbacks', noindex: true, description: 'Partner kickbacks and repair costs in the profit numbers, by owner and by car.' });

// Company > Kickbacks and repairs (release 29, C2; migration 0581): the business level of the profit lines Body shop,
// Tow and Storage kickback and Repair costs, by owner and by car, for a period, with the CSV. Finance has the same under
// Money > Kickbacks and repairs.
export default async function Kickbacks({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/money/kickbacks'), searchParams]);
  return (<>
    <PageHead title="Kickbacks and repairs" />
    <ProfitExtras userId={user.id} level="business" sp={sp} base="/admin/money/kickbacks" carLink={(v) => `/admin/vehicles/${v}?tab=profit`} />
  </>);
}
