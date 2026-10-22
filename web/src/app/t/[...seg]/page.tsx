import { seoMeta } from '@/features/seo/meta';
import { TermIndex, TwinView, termTree, twinMeta, twinPage } from '@/features/vehicles/twin';
import { fill, getTokens } from '@/lib/site';

// A search term's twin of every vehicle page (migration 0097): /t/<term>/<make>[/<model>[/<year>[/<trim>[/<place>[/<colour>]]]]]
// ("car hire", "financing", "ceramic coating", "bumper repair": the active search terms), and /t/<term> listing the
// makes. Rendered on demand with no ISR entry; the Worker's edge copy keeps it for 6 hours.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ seg: string[] }> };

export async function generateMetadata({ params }: Params) {
  const [term, ...rest] = (await params).seg;
  const tree = await termTree(term ?? '');
  if (!rest.length) {
    const t = await getTokens();
    return seoMeta({ title: fill(`${tree.term!.name}: every make, model, year and trim | {{brand}}`, t), path: tree.base,
      description: fill(`${tree.term!.name} for every car, by make, model, year and trim, with its EPA and NHTSA figures, in every place {{brand}} serves.`, t) });
  }
  return twinMeta(await twinPage(tree, rest));
}
export default async function Page({ params }: Params) {
  const [term, ...rest] = (await params).seg;
  const tree = await termTree(term ?? '');
  if (!rest.length) return <TermIndex tree={tree} />;
  return <TwinView {...await twinPage(tree, rest)} />;
}
