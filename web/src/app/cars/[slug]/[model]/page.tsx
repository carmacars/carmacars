import { modelPage } from '@/features/vehicles/data';
import { ModelView, modelMeta } from '@/features/vehicles/views';

// A model's vehicle page (migration 0092): every year with its fuel use and trims, similar models, our cars of the
// model. It replaces the model hub (/rent/<make-model> answers 301). On demand, never at build.
// rendered on demand with no ISR entry: no KV write per page (millions of pages); the Worker's edge copy keeps it
// (src/lib/edge/page-cache.ts, PROGRAMMATIC) for 6 hours
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ slug: string; model: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug, model } = await params;
  return modelMeta(await modelPage(slug, model));
}
export default async function Page({ params }: Params) {
  const { slug, model } = await params;
  return <ModelView p={await modelPage(slug, model)} />;
}
