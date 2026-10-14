import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { SimilarityTable, type Flag } from '@/features/admin/Similarity';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Similar cars', path: '/va/similar-cars', noindex: true, description: 'Possible duplicate vehicles and listings, for review before publishing.' });

export default async function VaSimilarCars() {
  const { read } = await vaPage('/va/similar-cars', ['fleet', 'cs']);
  const rows = await read<Flag[]>('similar_cars');
  const open = rows.filter((r) => r.status === 'open');
  return (
    <>
      <PageHead title="Similar cars" kicker={`${open.filter((r) => r.blocking).length} stop publishing, ${open.filter((r) => !r.blocking).length} for information`} />
      <p className="small muted">Compare the permit, the plate and the photos. Clear a flag with a note when they are different cars; confirm it when they are the same car.</p>
      <SimilarityTable rows={rows} base="/va" refresh={['/va/similar-cars']} />
    </>
  );
}
