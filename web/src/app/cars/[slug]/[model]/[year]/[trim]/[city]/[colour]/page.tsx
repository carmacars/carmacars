import { tierPage } from '@/features/vehicles/data';
import { TierView, tierMeta } from '@/features/vehicles/deep';

// A trim in a city and a colour, /cars/<make>/<model>/<year>/<trim>/<city>/<colour>, or in a colour alone,
// /cars/<make>/<model>/<year>/<trim>/colour/<colour> (migration 0097). On demand, never at build.
// rendered on demand with no ISR entry: no KV write per page (millions of pages); the Worker's edge copy keeps it
// (src/lib/edge/page-cache.ts, PROGRAMMATIC) for 6 hours
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ slug: string; model: string; year: string; trim: string; city: string; colour: string }> };
const args = (p: Awaited<Params['params']>) => [p.slug, p.model, p.year, p.trim, p.city === 'colour' ? null : p.city, p.colour] as const;

export async function generateMetadata({ params }: Params) {
  return tierMeta(await tierPage(...args(await params)));
}
export default async function Page({ params }: Params) {
  return <TierView p={await tierPage(...args(await params))} />;
}
