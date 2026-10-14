import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { SimilarityTable, type Flag } from '@/features/admin/Similarity';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Similar cars', path: '/admin/similar-cars', noindex: true, description: 'Possible duplicate vehicles and listings, for review before publishing.' });

// Possible duplicates across the fleet (migration 0040): open first, then what was decided in the last 30 days.
export default async function SimilarCars() {
  const { read } = await page('/admin/similar-cars');
  const rows = await read<Flag[]>('similar_cars');
  const open = rows.filter((r) => r.status === 'open');
  return (
    <>
      <PageHead title="Similar cars" kicker={`${open.filter((r) => r.blocking).length} stop publishing, ${open.filter((r) => !r.blocking).length} for information`} />
      <p className="small muted">Checked when a car is added, when listing photos are uploaded and when its listing text is drafted or edited. Clear a flag when the cars are different; confirm it when they are the same car.</p>
      <SimilarityTable rows={rows} base="/admin" refresh={['/admin/similar-cars']} />
    </>
  );
}
