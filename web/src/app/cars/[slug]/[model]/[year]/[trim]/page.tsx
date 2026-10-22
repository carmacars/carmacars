import { trimPage } from '@/features/vehicles/data';
import { TrimView, trimMeta } from '@/features/vehicles/views';

// A Canadian trim's vehicle page (migration 0092): its own powertrains and fuel use, cost of driving, how it differs
// from the other trims of the year, its other years, our cars. On demand with the page cache, never at build.
export const revalidate = 3600;
export const dynamicParams = true;
export async function generateStaticParams() { return []; }
type Params = { params: Promise<{ slug: string; model: string; year: string; trim: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug, model, year, trim } = await params;
  return trimMeta(await trimPage(slug, model, year, trim));
}
export default async function Page({ params }: Params) {
  const { slug, model, year, trim } = await params;
  return <TrimView p={await trimPage(slug, model, year, trim)} />;
}
