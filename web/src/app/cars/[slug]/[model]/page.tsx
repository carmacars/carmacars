import { modelPage } from '@/features/vehicles/data';
import { ModelView, modelMeta } from '@/features/vehicles/views';

// A model's vehicle page (migration 0092): every year with its fuel use and trims, similar models, our cars of the
// model. It replaces the model hub (/rent/<make-model> answers 301). On demand with the page cache, never at build.
export const revalidate = 3600;
export const dynamicParams = true;
export async function generateStaticParams() { return []; }
type Params = { params: Promise<{ slug: string; model: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug, model } = await params;
  return modelMeta(await modelPage(slug, model));
}
export default async function Page({ params }: Params) {
  const { slug, model } = await params;
  return <ModelView p={await modelPage(slug, model)} />;
}
