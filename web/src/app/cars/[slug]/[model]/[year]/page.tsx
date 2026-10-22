import { yearPage } from '@/features/vehicles/data';
import { YearView, yearMeta } from '@/features/vehicles/views';

// A model year's vehicle page (migration 0097): its EPA powertrains, cost of driving, Canadian trims, what changed
// from the year before, the other years, similar models, our cars. On demand, never at build.
// rendered on demand with no ISR entry: no KV write per page (millions of pages); the Worker's edge copy keeps it
// (src/lib/edge/page-cache.ts, PROGRAMMATIC) for 6 hours
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ slug: string; model: string; year: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug, model, year } = await params;
  return yearMeta(await yearPage(slug, model, year));
}
export default async function Page({ params }: Params) {
  const { slug, model, year } = await params;
  return <YearView p={await yearPage(slug, model, year)} />;
}
