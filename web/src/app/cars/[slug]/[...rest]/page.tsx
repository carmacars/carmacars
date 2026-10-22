import { notFound } from 'next/navigation';
import { modelPage, tierPage, trimPage, yearPage } from '@/features/vehicles/data';
import { TierView, tierMeta } from '@/features/vehicles/deep';
import { ModelView, TrimView, YearView, modelMeta, trimMeta, yearMeta } from '@/features/vehicles/views';

// The vehicle pages below a make (migration 0097), one route for every depth (one route file keeps the Worker small):
//   /cars/<make>/<model>                                   a model: its years, similar models, our cars (replaces /rent/<hub>)
//   /cars/<make>/<model>/<year>                            a model year: powertrains, cost of driving, trims, changes
//   /cars/<make>/<model>/<year>/<trim>                     a Canadian trim: its powertrains, how it differs, our cars
//   /cars/<make>/<model>/<year>/<trim>/<place>             the trim in a place
//   /cars/<make>/<model>/<year>/<trim>/<place>/<colour>    the trim in a place and a colour
//   /cars/<make>/<model>/<year>/<trim>/colour/<colour>     the trim in a colour
// Rendered on demand with no ISR entry (no KV write per page: millions of pages); the Worker's edge copy keeps it
// (src/lib/edge/page-cache.ts, PROGRAMMATIC) for 6 hours.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ slug: string; rest: string[] }> };

type Page =
  | { kind: 'model'; p: Awaited<ReturnType<typeof modelPage>> }
  | { kind: 'year'; p: Awaited<ReturnType<typeof yearPage>> }
  | { kind: 'trim'; p: Awaited<ReturnType<typeof trimPage>> }
  | { kind: 'tier'; p: Awaited<ReturnType<typeof tierPage>> };

async function load(slug: string, rest: string[]): Promise<Page> {
  const [model, year, trim, place, colour] = rest;
  switch (rest.length) {
    case 1: return { kind: 'model', p: await modelPage(slug, model!) };
    case 2: return { kind: 'year', p: await yearPage(slug, model!, year!) };
    case 3: return { kind: 'trim', p: await trimPage(slug, model!, year!, trim!) };
    // "/colour" alone is not a page (the colour pages are /colour/<colour>)
    case 4: if (place === 'colour') notFound(); return { kind: 'tier', p: await tierPage(slug, model!, year!, trim!, place!, null) };
    case 5: return { kind: 'tier', p: await tierPage(slug, model!, year!, trim!, place === 'colour' ? null : place!, colour!) };
    default: notFound();
  }
}

export async function generateMetadata({ params }: Params) {
  const { slug, rest } = await params;
  const x = await load(slug, rest);
  switch (x.kind) {
    case 'model': return modelMeta(x.p);
    case 'year': return yearMeta(x.p);
    case 'trim': return trimMeta(x.p);
    case 'tier': return tierMeta(x.p);
  }
}
export default async function Page({ params }: Params) {
  const { slug, rest } = await params;
  const x = await load(slug, rest);
  switch (x.kind) {
    case 'model': return <ModelView p={x.p} />;
    case 'year': return <YearView p={x.p} />;
    case 'trim': return <TrimView p={x.p} />;
    case 'tier': return <TierView p={x.p} />;
  }
}
