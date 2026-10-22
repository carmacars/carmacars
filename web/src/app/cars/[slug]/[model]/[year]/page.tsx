import { yearPage } from '@/features/vehicles/data';
import { YearView, yearMeta } from '@/features/vehicles/views';

// A model year's vehicle page (migration 0092): its EPA powertrains, cost of driving, Canadian trims, what changed
// from the year before, the other years, similar models, our cars. On demand with the page cache, never at build.
export const revalidate = 3600;
export const dynamicParams = true;
export async function generateStaticParams() { return []; }
type Params = { params: Promise<{ slug: string; model: string; year: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug, model, year } = await params;
  return yearMeta(await yearPage(slug, model, year));
}
export default async function Page({ params }: Params) {
  const { slug, model, year } = await params;
  return <YearView p={await yearPage(slug, model, year)} />;
}
