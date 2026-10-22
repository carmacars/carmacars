import { notFound } from 'next/navigation';
import { tierPage } from '@/features/vehicles/data';
import { TierView, tierMeta } from '@/features/vehicles/deep';

// A trim in one of our cities (migration 0097): /cars/<make>/<model>/<year>/<trim>/<city>. On demand, never at build. "/colour" alone is not a page (the colour pages are /colour/<colour>).
// rendered on demand with no ISR entry: no KV write per page (millions of pages); the Worker's edge copy keeps it
// (src/lib/edge/page-cache.ts, PROGRAMMATIC) for 6 hours
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ slug: string; model: string; year: string; trim: string; city: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug, model, year, trim, city } = await params;
  if (city === 'colour') notFound();
  return tierMeta(await tierPage(slug, model, year, trim, city, null));
}
export default async function Page({ params }: Params) {
  const { slug, model, year, trim, city } = await params;
  if (city === 'colour') notFound();
  return <TierView p={await tierPage(slug, model, year, trim, city, null)} />;
}
